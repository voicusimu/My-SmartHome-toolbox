-- Smart Meter QuickApp for Fibaro HC3
-- Device: Double Digital Meter (双路电流互感计量器 WiFi版)
-- Protocol: Tuya LAN v3.5 (AES-128-GCM, 3-step session key negotiation)
--
-- DPS map:
--   103 device_state1         enum    (monitor / working)
--   105 cur_power1            value   /10    → W
--   106 cur_current1          value   /1000  → A
--   107 cur_voltage1          value   /10    → V
--   108 total_energy1         value   /1000  → kWh
--   109 today_acc_energy1     value   /1000  → kWh
--   113 device_state2         enum
--   115 cur_power2            value   /10    → W
--   116 cur_current2          value   /1000  → A
--   117 cur_voltage2          value   /10    → V
--   118 total_energy2         value   /1000  → kWh
--   119 today_acc_energy2     value   /1000  → kWh
--   123 all_energy            value   /1000  → kWh
--   124 net_state             enum    (cloud_net / …)
--
-- Required QuickApp variables:
--   devID, devKEY, devVER, ip, timeout, enableDebug
--
-- Optional QuickApp variables:
--   reconnectDelay     seconds, default 5
--   queryInterval      seconds, default 25
--   heartbeatInterv  seconds, default 12
--   sessionWatchdog    seconds, default 8
--
-- Auto-created child IDs:
--   power1Child, energy1Child, power2Child, energy2Child, totalEnergyChild
--
-- UI labels : labelStatus, labelCh1, labelCh2, labelTotalEnergy, labelNetState
-- UI buttons: btn_connect, btn_disconnect, btn_refresh

-- ─── Child device classes ─────────────────────────────────────────────────────
class 'Meter'(QuickAppChild)
function Meter:__init(device)
    QuickAppChild.__init(self, device)
end

class 'PowerSensor'(QuickAppChild)
function PowerSensor:__init(device)
    QuickAppChild.__init(self, device)
end

-- ─── Per-channel state ────────────────────────────────────────────────────────
local ch1 = { state="—", voltage=0, current=0, power=0, energy=0, today=0 }
local ch2 = { state="—", voltage=0, current=0, power=0, energy=0, today=0 }

-- ─── Debug helpers ────────────────────────────────────────────────────────────
function QuickApp:dbg(...)
    if self.enableDebug then self:debug(...) end
end

function QuickApp:toHex(data)
    if not data then return "<nil>" end
    local bytes = {}
    for i = 1, #data do
        bytes[i] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(bytes, " ")
end

function QuickApp:cmdName(cb)
    local n = {
        [3]  = "BIND/SESS_START",
        [4]  = "RENAME_GW/SESS_RESP",
        [5]  = "RENAME_DEV/SESS_FINISH",
        [7]  = "CONTROL",
        [8]  = "STATUS",
        [9]  = "HEART_BEAT",
        [10] = "DP_QUERY",
        [13] = "CONTROL_NEW",
        [16] = "DP_QUERY_NEW",
        [18] = "DP_REFRESH",
    }
    return n[cb] or ("?(" .. tostring(cb) .. ")")
end

function QuickApp:formatClock(ts)
    if not ts then return "—" end
    return os.date("%H:%M:%S", ts)
end

function QuickApp:setStatus(message)
    local req = self.last_request_ts and self:formatClock(self.last_request_ts) or "—"
    local rx  = self.last_rx_ts and self:formatClock(self.last_rx_ts) or "—"
    self:updateView("labelStatus", "text", string.format("%s\nLast req: %s | Last rx: %s", message, req, rx))
end

function QuickApp:touchLastRx()
    self.last_rx_ts = os.time()
end

function QuickApp:touchLastRequest()
    self.last_request_ts = os.time()
    local stateText = "Connected (v3.5)"
    if self.session_state == "negotiating" then
        stateText = "Negotiating session…"
    elseif self.session_state == "connecting" then
        stateText = "Connecting…"
    elseif self.session_state == "idle" then
        stateText = "Disconnected"
    end
    self:setStatus(stateText)
end

function QuickApp:clearTimer(name)
    local id = self[name]
    if id ~= nil then
        clearTimeout(id)
        self[name] = nil
    end
end

function QuickApp:clearAllTimers()
    self:clearTimer("reconnectTimer")
    self:clearTimer("pollTimer")
    self:clearTimer("heartbeatTimer")
    self:clearTimer("sessionWatchdogTimer")
end

-- ─── Init ─────────────────────────────────────────────────────────────────────
function QuickApp:onInit()
    self:debug("SmartMeter onInit (v3.5 patched)")

    self.childs = {}
    self:createChildDevices()

    self.enabled           = api.get("/devices/" .. self.id).enabled
    self.enableDebug       = (self:getVariable("enableDebug") == "true")
    self.read_timeout_ms   = tonumber(self:getVariable("timeout") or "30") * 1000
    self.reconnect_delay_ms = tonumber(self:getVariable("reconnectDelay") or "5") * 1000
    self.query_interval_ms  = tonumber(self:getVariable("queryInterval") or "25") * 1000
    self.heartbeat_interval_ms = tonumber(self:getVariable("heartbeatInterv") or "12") * 1000
    self.session_watchdog_ms = tonumber(self:getVariable("sessionWatchdog") or "8") * 1000

    self.devID             = self:getVariable("devID")
    self.real_local_key    = self:getVariable("devKEY")
    self.devVER            = self:getVariable("devVER")
    self.ip                = self:getVariable("ip")
    self.port              = 6668

    self.sock              = nil
    self.sequenceN         = 1

    self.session_state     = "idle" -- idle | connecting | negotiating | ready
    self.session_key       = nil
    self.local_nonce       = nil
    self.remote_nonce      = nil
    self.last_request_ts   = nil
    self.last_rx_ts        = nil
    self.pending_query     = false

    self:debug(string.format(
        "Config: ip=%s ver=%s debug=%s timeout=%ss reconnect=%ss query=%ss heartbeat=%ss watchdog=%ss",
        tostring(self.ip), tostring(self.devVER), tostring(self.enableDebug),
        tostring(self.read_timeout_ms / 1000), tostring(self.reconnect_delay_ms / 1000),
        tostring(self.query_interval_ms / 1000), tostring(self.heartbeat_interval_ms / 1000),
        tostring(self.session_watchdog_ms / 1000)
    ))

    self:updateView("labelCh1", "text", "Channel 1: —")
    self:updateView("labelCh2", "text", "Channel 2: —")
    self:updateView("labelTotalEnergy", "text", "Total energy: —")
    self:updateView("labelNetState", "text", "Network: —")
    self:setStatus("Initialising…")

    self:connect()
end

-- ─── Child devices ────────────────────────────────────────────────────────────
function QuickApp:childDeviceExist(deviceId)
    if deviceId == nil then return false end
    local dev = api.get("/devices/" .. tostring(deviceId))
    if dev == nil then return false end
    return dev.parentId == self.id
end

function QuickApp:initChildDevice(varName, devName, devType, cls)
    local childId = self:getVariable(varName)
    if not self:childDeviceExist(childId) then
        local child = self:createChildDevice({ name=devName, type=devType }, cls)
        childId = child.id
        self:setVariable(varName, childId)
        self:trace(devName, "created:", child.id)
    end
    return self.childDevices[childId]
end

function QuickApp:createChildDevices()
    self:initChildDevices({
        ["com.fibaro.energyMeter"] = Meter,
        ["com.fibaro.powerMeter"]  = PowerSensor,
    })

    self.childs.power1Child = self:initChildDevice(
        "power1Child", "Meter Ch1 Power", "com.fibaro.powerMeter", PowerSensor)
    self.childs.power1Child:updateProperty("rateType", "consumption")
    pcall(function() self.childs.power1Child:updateProperty("unit", "W") end)

    self.childs.energy1Child = self:initChildDevice(
        "energy1Child", "Meter Ch1 Energy", "com.fibaro.energyMeter", Meter)
    self.childs.energy1Child:updateProperty("rateType", "consumption")
    pcall(function() self.childs.energy1Child:updateProperty("unit", "kWh") end)

    self.childs.power2Child = self:initChildDevice(
        "power2Child", "Meter Ch2 Power", "com.fibaro.powerMeter", PowerSensor)
    self.childs.power2Child:updateProperty("rateType", "consumption")
    pcall(function() self.childs.power2Child:updateProperty("unit", "W") end)

    self.childs.energy2Child = self:initChildDevice(
        "energy2Child", "Meter Ch2 Energy", "com.fibaro.energyMeter", Meter)
    self.childs.energy2Child:updateProperty("rateType", "consumption")
    pcall(function() self.childs.energy2Child:updateProperty("unit", "kWh") end)

    self.childs.totalEnergyChild = self:initChildDevice(
        "totalEnergyChild", "Meter Total Energy", "com.fibaro.energyMeter", Meter)
    self.childs.totalEnergyChild:updateProperty("rateType", "consumption")
    pcall(function() self.childs.totalEnergyChild:updateProperty("unit", "kWh") end)
end

-- ─── Button handlers ──────────────────────────────────────────────────────────
function QuickApp:connectPressed()
    if self.session_state ~= "idle" then
        self:debug("connectPressed: already busy (state=" .. self.session_state .. ")")
        return
    end
    self:debug("connectPressed: initiating connection")
    self:connect()
end

function QuickApp:disconnectPressed()
    self:debug("disconnectPressed: forcing disconnect")
    self:disconnect("Disconnected")
end

function QuickApp:refreshPressed()
    self:debug("refreshPressed: reconnecting now")
    self:disconnect("Refreshing…")
    fibaro.setTimeout(250, function() self:connect() end)
end

-- ─── Socket / reconnect helpers ───────────────────────────────────────────────
function QuickApp:closeSocket()
    if self.sock then
        tools.try(function() self.sock:close() end, function() end)
        self.sock = nil
    end
end

function QuickApp:resetSession()
    self.session_state = "idle"
    self.session_key   = nil
    self.local_nonce   = nil
    self.remote_nonce  = nil
    self.sequenceN     = 1
    self.pending_query = false
end

function QuickApp:disconnect(statusText)
    self:clearAllTimers()
    self:closeSocket()
    self:resetSession()
    self:setStatus(statusText or "Disconnected")
end

function QuickApp:scheduleReconnect(reason, delay_ms)
    local delay = delay_ms or self.reconnect_delay_ms
    self:debug(string.format("Scheduling reconnect in %.1fs (%s)", delay / 1000, tostring(reason)))
    self:clearTimer("reconnectTimer")
    self:clearTimer("pollTimer")
    self:clearTimer("heartbeatTimer")
    self:clearTimer("sessionWatchdogTimer")
    self:closeSocket()
    self:resetSession()
    self:setStatus(reason or "Reconnecting…")
    self.reconnectTimer = fibaro.setTimeout(delay, function()
        self.reconnectTimer = nil
        self:connect()
    end)
end

-- ─── TCP connection ───────────────────────────────────────────────────────────
function QuickApp:connect()
    if not self.enabled then return end
    if self.ip == "changeme" or self.ip == "" or self.ip == nil then
        self:debug("connect: ip not configured")
        self:setStatus("IP not configured")
        return
    end
    if self.session_state ~= "idle" then
        self:dbg("connect: already in state=" .. self.session_state)
        return
    end

    self:clearAllTimers()
    self:closeSocket()
    self:resetSession()

    self.session_state = "connecting"
    self.sock = net.TCPSocket()

    self:dbg("TCP connecting to " .. self.ip .. ":" .. self.port)
    self:setStatus("Connecting…")

    self.sock:connect(self.ip, self.port, {
        success = function()
            self:debug("TCP connected — starting v3.5 session")
            self.session_state = "negotiating"
            self:setStatus("Negotiating session…")
            self:waitForData()
            self:armSessionWatchdog("Waiting for CMD4")
            self:sendSessionStart()
        end,
        error = function(err)
            self:debug("TCP connect error: " .. tostring(err))
            self:scheduleReconnect("Connect failed", self.reconnect_delay_ms)
        end,
    })
end

function QuickApp:armSessionWatchdog(label)
    self:clearTimer("sessionWatchdogTimer")
    self.sessionWatchdogTimer = fibaro.setTimeout(self.session_watchdog_ms, function()
        self.sessionWatchdogTimer = nil
        if self.session_state ~= "ready" then
            self:debug("Session watchdog expired: " .. tostring(label))
            self:scheduleReconnect("Session timeout", self.reconnect_delay_ms)
        end
    end)
end

-- ─── Session negotiation ──────────────────────────────────────────────────────
function QuickApp:sendSessionStart()
    self.local_nonce = gcmlib.random_bytes(16)
    self:dbg("local_nonce: " .. self:toHex(self.local_nonce))

    local pkt = tuyAPI.encode35({
        data        = self.local_nonce,
        key         = self.real_local_key,
        commandByte = tuyAPI.tuyaCommandType.BIND,
        sequenceN   = self.sequenceN,
    })
    self.sequenceN = self.sequenceN + 1

    self:dbg("Sending CMD3 (SESS_START): " .. self:toHex(pkt))
    self.sock:write(pkt, {
        success = function()
            self:dbg("CMD3 write OK — waiting for CMD4")
            self:armSessionWatchdog("CMD3 sent, waiting for CMD4")
        end,
        error = function(err)
            self:debug("CMD3 write failed: " .. tostring(err))
            self:scheduleReconnect("Session start failed", self.reconnect_delay_ms)
        end,
    })
end

function QuickApp:handleSessionCmd4(plaintext)
    self:dbg("CMD4 raw plaintext (" .. #plaintext .. " bytes): " .. self:toHex(plaintext))

    if #plaintext < 52 then
        self:debug("CMD4 payload too short: " .. #plaintext .. " bytes (expected 52)")
        self:scheduleReconnect("Bad CMD4 payload", self.reconnect_delay_ms)
        return
    end

    local remote_nonce = string.sub(plaintext, 5, 20)
    local recv_hmac    = string.sub(plaintext, 21, 52)

    local expected_hmac = sha256lib.hmac(self.real_local_key, self.local_nonce)
    local match = true
    for i = 1, 32 do
        if string.byte(recv_hmac, i) ~= string.byte(expected_hmac, i) then
            match = false
            break
        end
    end

    if not match then
        self:debug("CMD4 HMAC mismatch — wrong key or rogue device")
        self:scheduleReconnect("CMD4 HMAC mismatch", self.reconnect_delay_ms)
        return
    end

    self:dbg("CMD4 HMAC OK")
    self.remote_nonce = remote_nonce
    self:dbg("remote_nonce: " .. self:toHex(self.remote_nonce))

    local xor_parts = {}
    for i = 1, 16 do
        xor_parts[i] = string.char(string.byte(self.local_nonce, i) ~ string.byte(self.remote_nonce, i))
    end
    local xor_nonces = table.concat(xor_parts)
    local gcm_out    = gcmlib.encrypt(self.real_local_key, string.sub(self.local_nonce, 1, 12), xor_nonces, "")
    self.session_key = string.sub(gcm_out, 1, 16)
    self:dbg("session_key derived: " .. self:toHex(self.session_key))

    local hmac5 = sha256lib.hmac(self.real_local_key, self.remote_nonce)
    local pkt5  = tuyAPI.encode35({
        data        = hmac5,
        key         = self.real_local_key,
        commandByte = tuyAPI.tuyaCommandType.RENAME_DEVICE,
        sequenceN   = self.sequenceN,
    })
    self.sequenceN = self.sequenceN + 1

    self:dbg("Sending CMD5 (SESS_FINISH): " .. self:toHex(pkt5))
    self.sock:write(pkt5, {
        success = function()
            self:debug("CMD5 write OK — session established with session_key")
            self:clearTimer("sessionWatchdogTimer")
            self.session_state = "ready"
            self:setStatus("Connected (v3.5)")
            fibaro.setTimeout(250, function()
                if self.session_state == "ready" then
                    self:requestData("post-handshake")
                    self:startLoops()
                end
            end)
        end,
        error = function(err)
            self:debug("CMD5 write failed: " .. tostring(err))
            self:scheduleReconnect("Session finish failed", self.reconnect_delay_ms)
        end,
    })
end

-- ─── Write helpers ────────────────────────────────────────────────────────────
function QuickApp:sendPacket(payload, commandByte, label)
    if self.session_state ~= "ready" or not self.sock or not self.session_key then
        self:dbg("sendPacket skipped: not ready for " .. tostring(label))
        return false
    end

    local pkt = tuyAPI.encode35({
        data        = payload,
        key         = self.session_key,
        commandByte = commandByte,
        sequenceN   = self.sequenceN,
    })
    local sn = self.sequenceN
    self.sequenceN = self.sequenceN + 1

    self:dbg(string.format("Sending %s (cmd=%d sn=%d)", tostring(label), tonumber(commandByte), sn))
    self.sock:write(pkt, {
        success = function()
            self:dbg(tostring(label) .. " write OK")
        end,
        error = function(err)
            self:debug(tostring(label) .. " write failed: " .. tostring(err))
            self:scheduleReconnect("Write failed", self.reconnect_delay_ms)
        end,
    })
    return true
end

-- ─── Query / heartbeat loop ───────────────────────────────────────────────────
function QuickApp:startLoops()
    self:clearTimer("pollTimer")
    self:clearTimer("heartbeatTimer")
    self:scheduleNextQuery()
    self:scheduleNextHeartbeat()
end

function QuickApp:scheduleNextQuery()
    self:clearTimer("pollTimer")
    self.pollTimer = fibaro.setTimeout(self.query_interval_ms, function()
        self.pollTimer = nil
        if self.session_state == "ready" then
            self:requestData("periodic")
            self:scheduleNextQuery()
        end
    end)
end

function QuickApp:scheduleNextHeartbeat()
    self:clearTimer("heartbeatTimer")
    self.heartbeatTimer = fibaro.setTimeout(self.heartbeat_interval_ms, function()
        self.heartbeatTimer = nil
        if self.session_state == "ready" then
            self:sendHeartbeat()
            self:scheduleNextHeartbeat()
        end
    end)
end

function QuickApp:requestData(reason)
    if self.session_state ~= "ready" then return false end

    local payload_data = json.encode({
        gwId  = self.devID,
        devId = self.devID,
        uid   = self.devID,
        t     = tostring(os.time()),
    })

    self.pending_query = true
    self:touchLastRequest()
    self:dbg("requestData reason=" .. tostring(reason or "manual") .. " payload=" .. payload_data)
    return self:sendPacket(payload_data, tuyAPI.tuyaCommandType.DP_QUERY_NEW, "DP_QUERY_NEW")
end

function QuickApp:sendHeartbeat()
    if self.session_state ~= "ready" then return false end
    self:dbg("sendHeartbeat")
    return self:sendPacket("", tuyAPI.tuyaCommandType.HEART_BEAT, "HEART_BEAT")
end

-- ─── Data loop ────────────────────────────────────────────────────────────────
function QuickApp:waitForData()
    if not self.sock then return end

    self.sock:read({
        success = function(data)
            if not data or #data == 0 then
                self:waitForData()
                return
            end

            self:touchLastRx()
            self:dbg(string.format("Packet received: %d bytes", #data))
            self:dbg("Raw hex: " .. self:toHex(data))

            local okPrefix, prefix = pcall(function() return string.unpack(">I4", data, 1) end)
            if not okPrefix then
                self:debug("Unable to unpack packet prefix")
                self:waitForData()
                return
            end

            if prefix == 0x00006699 then
                local ct, aad, iv, cmd, seqno, err = tuyAPI.parsePacket35(data)
                if err then
                    self:debug("parsePacket35 error: " .. tostring(err))
                    self:waitForData()
                    return
                end

                self:dbg(string.format("v3.5 header — seq=%d cmd=%d (%s) ct_len=%d",
                    seqno or 0, cmd or 0, self:cmdName(cmd), #ct))

                local dkey
                if cmd == tuyAPI.tuyaCommandType.RENAME_GW then
                    dkey = self.real_local_key
                elseif self.session_key then
                    dkey = self.session_key
                else
                    dkey = self.real_local_key
                end

                local plaintext, perr = tuyAPI.getPayload35(ct, aad, iv, dkey)
                if perr or not plaintext then
                    self:debug("getPayload35 error: " .. tostring(perr))
                    self:waitForData()
                    return
                end

                self:dbg("Decrypted (" .. #plaintext .. " bytes): " .. self:toHex(plaintext))

                if cmd == tuyAPI.tuyaCommandType.RENAME_GW then
                    self:handleSessionCmd4(plaintext)

                elseif cmd == tuyAPI.tuyaCommandType.STATUS or
                       cmd == tuyAPI.tuyaCommandType.CONTROL_NEW or
                       cmd == tuyAPI.tuyaCommandType.DP_QUERY or
                       cmd == tuyAPI.tuyaCommandType.DP_QUERY_NEW or
                       cmd == tuyAPI.tuyaCommandType.DP_REFRESH then
                    self:handleDataPayload(plaintext, cmd)

                elseif cmd == tuyAPI.tuyaCommandType.HEART_BEAT then
                    self:dbg("HEART_BEAT ack")
                    self:setStatus("Connected (v3.5)")

                else
                    self:debug("Unhandled v3.5 cmd=" .. tostring(cmd))
                end

            elseif prefix == 0x000055AA then
                self:debug("Received v3.3 packet (55AA) — device may not be fully in v3.5 mode")
                local ok, payload = pcall(function()
                    return tuyAPI.parse(data, self.real_local_key, self.devVER)
                end)
                if ok and type(payload) == "table" and payload.dps then
                    self:handleDps(payload.dps)
                end
            else
                self:debug(string.format("Unknown packet prefix 0x%08X", prefix))
            end

            self:waitForData()
        end,

        error = function(err)
            self:debug("Socket read error: " .. tostring(err))
            if err == "End of file" then
                self:scheduleReconnect("Socket closed by device", self.reconnect_delay_ms)
            else
                self:scheduleReconnect("Connection error", self.reconnect_delay_ms)
            end
        end,

        timeout = self.read_timeout_ms
    })
end

-- ─── Data payload handler ─────────────────────────────────────────────────────
function QuickApp:handleDataPayload(plaintext, cmd)
    self:dbg(string.format("handleDataPayload cmd=%d (%s) len=%d", cmd, self:cmdName(cmd), #plaintext))

    local json_str = plaintext
    if #plaintext >= 4 then
        local rc = string.unpack(">I4", plaintext, 1)
        if rc == 0 then
            json_str = string.sub(plaintext, 5)
            self:dbg("Skipped 4-byte retcode=0")
        end
    end

    if #json_str >= 3 and string.sub(json_str, 1, 1) == "3" then
        local maybe_ver = string.sub(json_str, 1, 3)
        if maybe_ver:match("^3%.[0-9]") then
            json_str = string.sub(json_str, 4)
            self:dbg("Stripped version prefix '" .. maybe_ver .. "'")
        end
    end

    self:dbg("JSON string to decode: " .. json_str)

    local ok, result = pcall(json.decode, json_str)
    if not ok then
        self:debug("JSON decode failed: " .. tostring(result))
        self:debug("Raw payload hex: " .. self:toHex(plaintext))
        return
    end

    local dps = nil
    if type(result) == "table" then
        if result.dps then
            dps = result.dps
        elseif result.data and type(result.data) == "table" and result.data.dps then
            dps = result.data.dps
        end
    end

    if dps then
        self.pending_query = false
        self:dbg("DPS: " .. json.encode(dps))
        self:handleDps(dps)
        self:setStatus("Connected (v3.5)")
    else
        self:debug("No DPS in payload — result: " .. json.encode(result))
    end
end

-- ─── DPS handler ─────────────────────────────────────────────────────────────
function QuickApp:handleDps(resp)
    self:dbg("handleDps called")

    -- Channel 1
    if resp['103'] ~= nil then ch1.state   = tostring(resp['103']) end
    if resp['107'] ~= nil then ch1.voltage = resp['107'] / 10 end
    if resp['106'] ~= nil then ch1.current = resp['106'] / 1000 end
    if resp['105'] ~= nil then
        ch1.power = resp['105'] / 10
        if self.childs.power1Child then
            self.childs.power1Child:updateProperty("value", ch1.power)
            pcall(function() self.childs.power1Child:updateProperty("unit", "W") end)
        end
    end
    if resp['108'] ~= nil then
        ch1.energy = resp['108'] / 1000
        if self.childs.energy1Child then
            self.childs.energy1Child:updateProperty("value", ch1.energy)
            pcall(function() self.childs.energy1Child:updateProperty("unit", "kWh") end)
        end
    end
    if resp['109'] ~= nil then ch1.today = resp['109'] / 1000 end

    -- Channel 2
    if resp['113'] ~= nil then ch2.state   = tostring(resp['113']) end
    if resp['117'] ~= nil then ch2.voltage = resp['117'] / 10 end
    if resp['116'] ~= nil then ch2.current = resp['116'] / 1000 end
    if resp['115'] ~= nil then
        ch2.power = resp['115'] / 10
        if self.childs.power2Child then
            self.childs.power2Child:updateProperty("value", ch2.power)
            pcall(function() self.childs.power2Child:updateProperty("unit", "W") end)
        end
    end
    if resp['118'] ~= nil then
        ch2.energy = resp['118'] / 1000
        if self.childs.energy2Child then
            self.childs.energy2Child:updateProperty("value", ch2.energy)
            pcall(function() self.childs.energy2Child:updateProperty("unit", "kWh") end)
        end
    end
    if resp['119'] ~= nil then ch2.today = resp['119'] / 1000 end

    -- Combined
    if resp['123'] ~= nil then
        local kwh = resp['123'] / 1000
        self:updateView("labelTotalEnergy", "text", string.format("Total energy: %.3f kWh", kwh))
        if self.childs.totalEnergyChild then
            self.childs.totalEnergyChild:updateProperty("value", kwh)
            pcall(function() self.childs.totalEnergyChild:updateProperty("unit", "kWh") end)
        end
    end
    if resp['124'] ~= nil then
        self:updateView("labelNetState", "text", "Network: " .. tostring(resp['124']))
    end

    self:dbg(string.format(
        "Ch1: state=%s U=%.1fV I=%.3fA P=%.1fW E=%.3fkWh today=%.3fkWh",
        ch1.state, ch1.voltage, ch1.current, ch1.power, ch1.energy, ch1.today))
    self:dbg(string.format(
        "Ch2: state=%s U=%.1fV I=%.3fA P=%.1fW E=%.3fkWh today=%.3fkWh",
        ch2.state, ch2.voltage, ch2.current, ch2.power, ch2.energy, ch2.today))

    self:updateView("labelCh1", "text", string.format(
        "Channel 1 [%s]\n" ..
        "  Voltage: %.1f V\n" ..
        "  Current: %.3f A\n" ..
        "  Power:   %.1f W\n" ..
        "  Total:   %.3f kWh\n" ..
        "  Today:   %.3f kWh",
        ch1.state, ch1.voltage, ch1.current, ch1.power, ch1.energy, ch1.today))

    self:updateView("labelCh2", "text", string.format(
        "Channel 2 [%s]\n" ..
        "  Voltage: %.1f V\n" ..
        "  Current: %.3f A\n" ..
        "  Power:   %.1f W\n" ..
        "  Total:   %.3f kWh\n" ..
        "  Today:   %.3f kWh",
        ch2.state, ch2.voltage, ch2.current, ch2.power, ch2.energy, ch2.today))
end
