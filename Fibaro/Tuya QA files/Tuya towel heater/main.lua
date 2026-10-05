-- Thermostat auto should handle actions: setThermostatMode, setCoolingThermostatSetpoint, setHeatingThermostatSetpoint
-- Proeprties that should be updated:
-- * supportedThermostatModes - array of modes supported by the thermostat eg. {"Off", "Heat"}
-- * thermostatMode - current mode of the thermostat
-- * heatingThermostatSetpoint - set point for heating, supported units: "C" - Celsius, "F" - Fahrenheit

-- To update controls you can use method self:updateView(<component ID>, <component property>, <desired value>). Eg:  
-- self:updateView("slider", "value", "55") 
-- self:updateView("button1", "text", "MUTE") 
-- self:updateView("label", "text", "TURNED ON") 

-- This is QuickApp inital method. It is called right after your QuickApp starts (after each save or on gateway startup). 
-- Here you can set some default values, setup http connection or get QuickApp variables.
-- To learn more, please visit: 
--    * https://manuals.fibaro.com/home-center-3/
--    * https://manuals.fibaro.com/home-center-3-quick-apps/

local currentThermostatMode = "Off"
local currentTemp = 0
local workState = "standby"
local mode = "CF"
local pendingRefresh = false
local lastForcedModeChangeTime = nil
local lastWorkStateChangeTime = nil

function QuickApp:onInit()
    self:debug("onInit")

    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Off", "Heat"})
    self:updateProperty("heatingThermostatSetpointCapabilitiesMax", 35)
    self:updateProperty("heatingThermostatSetpointCapabilitiesMin", 5)
    self:updateProperty("heatingThermostatSetpointStep", { C = 1 })
    self:updateProperty("heatingThermostatSetpoint", { value= 22, unit= "C" })
    self.childs = {}
    self:createChildDevices()

    self:debug("onInit")
    self.enabled = api.get("/devices/"..self.id).enabled
    self.showdebug = true
    self.connect_timeout = tonumber(self:getVariable("timeout")) * 1000
    self.devID = self:getVariable("devID")
    self.devKEY = self:getVariable("devKEY")
    self.devVER = self:getVariable("devVER")
    self.ip = self:getVariable("ip")
    self.port = 6668 -- tonumber(self:getVariable("port"))
    self.sock = net.TCPSocket()
    self.stateloopID = nil
    self.sockloopID = nil
    self.dataloopID = nil
    self.pingloopID = nil
    self.sequenceN = 1
    self:connect()
end

-- handle action for mode change
function QuickApp:setThermostatMode(mode)
    currentThermostatMode = mode
    if mode == "Off" then
        if self.enabled then
            local chandata = {
                    ['1'] = false
            }
            if self.ip ~= "changeme" then
                self:sendCommand(chandata, function()
                    self:updateProperty("thermostatMode", mode)
                    self.childs.currentPowerChild:updateProperty("value", 0)
                    self:updateProperty("power", 0)
                end)
            end
        end
    else
        if self.enabled then
            local chandata = {
                    ['1'] = true
            }
            if self.ip ~= "changeme" then
                self:sendCommand(chandata, function()
                    self:updateProperty("thermostatMode", mode)
                    self:updateConsumption()
                end)
            end
        end
    end
end

function QuickApp:setHeatingMode(value) 
    if self.enabled then
        local chandata = {
                ['4'] = value
        }
        if self.ip ~= "changeme" then
            self:sendCommand(chandata, function()
                self:updateConsumption()
            end)
        end
    end
end

-- called when user changes setpoint in HC3 UI / scenes
function QuickApp:setHeatingThermostatSetpoint(value)
    if not self.enabled or self.ip == "changeme" then return end

    local v = tonumber(value)
    if not v then return end
    v = math.floor(v)

    local chandata = { ['2'] = v }  -- or ['3'] depending on your DPS

    self:sendCommand(chandata, function()
        self:_updateHeatingSetpointFromDevice(v)  -- reuse same logic
    end)
end

function QuickApp:_updateHeatingSetpointFromDevice(v)
    self:updateProperty("heatingThermostatSetpoint", { value = v, unit = "C" })
    self:updateConsumption()
end

function QuickApp:updateConsumption()
    local heatSetpoint = self.properties.heatingThermostatSetpoint.value
    if self.showdebug then 
        self:debug("Towel heater mode: ", currentThermostatMode) 
        self:debug("Towel heater work state: ", workState)
    end

    if workState == "working" then
        self.childs.currentPowerChild:updateProperty("value", 500)
        self:updateProperty("power", 500)
        self:updateProperty("log", "500 W")
    else
        self.childs.currentPowerChild:updateProperty("value", 0)
        self:updateProperty("power", 0)
        self:updateProperty("log", "0 W")
    end
end

function QuickApp:updateEnergyValues()
    local energyMeterId = self:getVariable("totalEnergyChild")
    local totalConsumption = hub.getValue(energyMeterId, "value")
    local newConsumption = totalConsumption
    local energyValue = 0
    if workState == "working" then
        energyValue = 500 / 3600000 * 32
        newConsumption = totalConsumption + energyValue
        self.childs.totalEnergyChild:updateProperty("value", newConsumption)
        if self.showdebug then self:debug("Total Consumption: ", totalConsumption, "New total consumption: ", newConsumption) end
    end
end

function QuickApp:childDeviceExist(deviceId)
    if deviceId == nil then
        return false
    end

    local dev = api.get('/devices/' .. tostring(deviceId))

    if dev == nil then
        return false
    end

    return dev.parentId == self.id
end

function QuickApp:initChildDevice(variableName, deviceName, type, class)
    local childId = self:getVariable(variableName)

    if(self:childDeviceExist(childId) == false) then
        local child = self:createChildDevice({
            name = deviceName,
            type = type
        }, class)
        childId = child.id
        self:setVariable(variableName, childId)
    
        self:trace(deviceName, "created:", child.id)
    end

    return self.childDevices[childId]
end

function QuickApp:createChildDevices()
    self:initChildDevices({
        ["com.fibaro.energyMeter"] = Meter,
        ["com.fibaro.powerMeter"] = PowerSensor,
    })
    
    -- total energy consumed (kWh)
    self.childs.totalEnergyChild = self:initChildDevice("totalEnergyChild", "Towel heater energy consumption", "com.fibaro.energyMeter", Meter)
    self.childs.totalEnergyChild:updateProperty("rateType", "consumption")

    -- current consumption (W)
    self.childs.currentPowerChild = self:initChildDevice("currentPowerChild", "Towel heater power consumption", "com.fibaro.powerMeter", PowerSensor)
    self.childs.currentPowerChild:updateProperty("rateType", "consumption")
end

function QuickApp:setChildVisibility(childName, visible)
    local child = self.childs[childName]

    if child == nil then
        self:warning(string.format("Child %s not found", childName))
        return
    end

    local previousVisible = child:getVariable("visible")

    if previousVisible ~= visible then
        child:setVisible(visible)
        child:setVariable("visible", visible)
        self:debug(string.format("Changing visibility of the child device (id:%d). Visible value: %s", child.id, visible))
    end
end

function QuickApp:thermostatModePressed()
    self:setHeatingMode("CF")
end

function QuickApp:ecoModePressed()
    self:setHeatingMode("EC")
end

function QuickApp:p1ModePressed()
    self:setHeatingMode("P1")
end

function QuickApp:p2ModePressed()
    self:setHeatingMode("P2")
end

function QuickApp:p3ModePressed()
    self:setHeatingMode("P3")
end

function QuickApp:antifreezeModePressed()
    self:setHeatingMode("AF")
end

function QuickApp:scheduleModePressed()
    self:setHeatingMode("ST")
end

function QuickApp:mode2hPressed()
    self:setHeatingMode("D2")
end

function QuickApp:mode3hPressed()
    self:setHeatingMode("D3")
end

function QuickApp:mode4hPressed()
    self:setHeatingMode("D4")
end

function QuickApp:connect()
    if self.enabled then
        if self.ip ~= "changeme" then
            local ts = os.time()
            payloadKeys = {gwId = 1, devId = 2, t = 3, uid = 4}
            payloadMax  = 4
            local payloaddata = {
                gwId = self.devID,
                devId = self.devID,
                t = ts,
                uid = self.devID
            }  
            local myoptions = {
                data = tools.prettyJson(payloaddata),
                key = self.devKEY, 
                version = self.devVER,
                --encrypted =  true, -- this one only for version = "3.1" 
                commandByte = tuyAPI.tuyaCommandType.DP_QUERY
            }
            local payload = tuyAPI.tuyaEncode(myoptions)
            self.sock:connect(self.ip, self.port, {
                success = function()
                    self.sock:write(payload)
                    -- ping every 60 seconds
                    self.pingloopID = setInterval(function() self:pingTuya() end, 60000)
                    self:waitForData()
                    self:updateEnergyValues()
                end,
                error = function(err)
                    self.sock:close()
                    self.sequenceN = 1
                    self:disconnect()
                    self:updateView("labelStatus", "text", "Connection lost")
                    self.sockloopID = fibaro.setTimeout(self.connect_timeout, function() self:connect() end)
                end,
            })
        end
    end
end

function QuickApp:disconnect()
    if self.ip ~= "changeme" then
        tools.try(function() 
                if self.stateloopID ~= nil then clearTimeout(self.stateloopID) end
                if self.sockloopID ~= nil then clearTimeout(self.sockloopID) end
                if self.pingloopID ~= nil then clearInterval(self.pingloopID) end
                if self.dataloopID ~= nil then clearTimeout(self.dataloopID) end
        end, function(e) 
                if self.showdebug then print(self.pingloopID,self.stateloopID,self.sockloopID,self.dataloopID) end
                if self.stateloopID ~= nil then clearTimeout(self.stateloopID) end
                if self.sockloopID ~= nil then clearTimeout(self.sockloopID) end
                if self.pingloopID ~= nil then clearInterval(self.pingloopID) end
                if self.dataloopID ~= nil then clearTimeout(self.dataloopID) end
        end)
        self.sock:close()
        self:updateView("labelStatus", "text", "Connection lost")
        self.sequenceN = 1
    end
end 

function QuickApp:waitForData()
    if self.enabled then
        self.sock:read({
            success = function(data)
                -- ignore invalid packets
                if (string.sub(data,0,4) == string.pack(">I",0x000055AA)) then
                    self:updateView("labelStatus", "text", "Connected successfully")
                    local payload, commandByte, sequenceN = tuyAPI.parse(data,self.devKEY,self.devVER)
                    if self.showdebug then print(json.encode(payload)) end
                    if self.showdebug then print("CB" ..tostring(commandByte)) end
                    if self.showdebug then print("SN" ..tostring(sequenceN)) end
                    if (tonumber(commandByte) == tuyAPI.tuyaCommandType.DP_QUERY or tonumber(commandByte) == tuyAPI.tuyaCommandType.STATUS) then
                        if payload then resp = payload.dps
                            local dpTimestamp = payload.t
                            if resp and resp['1'] ~= nil and resp['1'] == false then 
                                self:updateProperty("thermostatMode", "Off")
                            elseif resp and resp['1'] ~= nil and resp['1'] == true then 
                                self:updateProperty("thermostatMode", "Heat")
                            end
                            if resp and resp['2'] ~= nil then 
                                local desiredTemp = tonumber(resp['2'])
                                if desiredTemp then
                                    self:_updateHeatingSetpointFromDevice(desiredTemp)  -- ✅ state update only
                                end
                            end
                            if resp and resp['3'] ~= nil then
                                currentTemp = resp['3']
                                local currentTempString = "Current temperature: "..tostring(currentTemp).." °C"
                                hub.call(488, "setTemperature", resp['3'])
                                self:updateView("labelCurrentTemperature", "text", currentTempString)
                            end
                            if resp and resp['4'] ~= nil then
                            local dp4 = resp['4']
                                local newMode = resp['4']
                                if mode ~= newMode then
                                    mode = newMode
                                    lastForcedModeChangeTime = dpTimestamp or os.time()
                                else
                                    mode = newMode
                                end
                                if time4 then lastForcedModeTime = time4 end
                                local ageText = lastForcedModeChangeTime and (" (" .. self:formatSinceTs(lastForcedModeChangeTime) .. ")") or ""
                                local currentModeString = ""
                                if mode == "CF" then
                                    currentModeString = "Thermostat mode"..ageText
                                elseif mode == "EC" then
                                    currentModeString = "Eco mode"..ageText
                                elseif mode == "P1" then
                                    currentModeString = "P1 mode"..ageText
                                elseif mode == "P2" then
                                    currentModeString = "P2 mode"..ageText
                                elseif mode == "P3" then
                                    currentModeString = "P3 mode"..ageText
                                elseif mode == "AF" then
                                    currentModeString = "Anti freeze mode"..ageText                                
                                elseif mode == "ST" then
                                    currentModeString = "Schedule mode"..ageText 
                                elseif mode == "D2" then
                                    currentModeString = "2 hours dry mode"..ageText
                                elseif mode == "D3" then
                                    currentModeString = "3 hours dry mode"..ageText
                                elseif mode == "D4" then
                                    currentModeString = "4 hours dry mode"..ageText
                                end
                                self:updateView("labelCurrentMode", "text", currentModeString)
                            end
                            if resp['11'] ~= nil then
                                local newState = resp['11']
                                if workState ~= newState then
                                    workState = newState
                                    lastWorkStateChangeTime = dpTimestamp or os.time()
                                else
                                    workState = newState
                                end
                                local workStateString = (workState == "working") and "Heating" or "Standby"
                                local ageText = lastWorkStateChangeTime and (" (" .. self:formatSinceTs(lastWorkStateChangeTime) .. ")") or ""
                                self:updateView("labelWorkState", "text", workStateString .. ageText)
                            end
                        end
                    elseif (tonumber(commandByte) == tuyAPI.tuyaCommandType.HEART_BEAT) then
                        self:updateView("labelStatus", "text", "Connected successfully")
                    end
                    self:updateConsumption()                    
                end
                self:waitForData()
            end,
            error = function()
                if self.showdebug then self:debug("tuya QA - data response error") end
                self.sock:close()
                self.sequenceN = 1
                self:disconnect()
                self:updateView("labelStatus", "text", "Connection error")
                self.dataloopID = fibaro.setTimeout(self.connect_timeout, function() self:connect() end)
            end
        })
    end
end
 
function QuickApp:pingTuya()
    if self.enabled then
        local myoptions = {
            data = json.encode({}),
            commandByte = tuyAPI.tuyaCommandType.HEART_BEAT,
            sequenceN = self.sequenceN
        }
        -- don't increase sequenceN for pings
        --self.sequenceN = self.sequenceN + 1
        local payload = tuyAPI.tuyaEncode(myoptions)
        self.sock:write(payload, {
            success = function()
                if self.showdebug then self:debug("tuya QA - HEART_BEAT sent") end
                self:updateView("labelStatus", "text", "Connected successfully")
                fibaro.setTimeout(60000, function() self:updateTuyaState() end)
            end,
            error = function(err)
                if self.showdebug then self:debug("tuya QA - error while sending HEART_BEAT") end
                self:disconnect()
                self:updateView("labelStatus", "text", "Connection lost")
                self.sockloopID = fibaro.setTimeout(self.connect_timeout, function() self:connect() end)
            end
        })
    end
end

function QuickApp:updateTuyaState()
    if self.enabled then
        payloadKeys = {gwId = 1, devId = 2, t = 3, dps = 4, uid = 5}
        payloadMax  = 5
        local ts = os.time()
        local payloaddata = {
            gwId = self.devID,
            devId = self.devID,
            t = ts,
            dps = {},
            uid = ''
        }
        local myoptions = {
            data = tools.prettyJson(payloaddata),
            key = self.devKEY, 
            version = self.devVER,
            --encrypted =  true, -- this one only for version = "3.1"
            commandByte = tuyAPI.tuyaCommandType.DP_QUERY,
            sequenceN = self.sequenceN
        }

        self.sequenceN = self.sequenceN + 1
        local payload = tuyAPI.tuyaEncode(myoptions)
        self.sock:write(payload, {
            success = function()
                if self.showdebug then self:debug("tuya QA - DP_Query sent") end
            end,
            error = function(err)
                if self.showdebug then self:debug("tuya QA - error while sending DP_Query") end
                self:disconnect()
                self:updateView("labelStatus", "text", "Connection lost")
                self.sockloopID = fibaro.setTimeout(self.connect_timeout, function() self:connect() end)
            end
        })
    end
end

function QuickApp:sendCommand(query, successCallback)
    if self.enabled then
        payloadKeys = {gwId = 2, devId = 1, t = 4, uid = 3, dps = 5}
        payloadMax  = 5
        local ts = os.time()
        local payloaddata = {
            devId = self.devID,
            gwId = self.devID,
            uid = '',
            t = ts,
            dps = query
        } 
        local myoptions = {
            data = tools.prettyJson(payloaddata),
            key = self.devKEY, 
            version = self.devVER,
            --encrypted =  true, -- this one only for version = "3.1"
            commandByte = tuyAPI.tuyaCommandType.CONTROL,
            sequenceN = self.sequenceN
        }
        self.sequenceN = self.sequenceN + 1
        local payload = tuyAPI.tuyaEncode(myoptions)
        self.sock:write(payload, {
            success = function()
                if self.showdebug then self:debug("tuya QA - CONTROL sent") end
                if not pendingRefresh then
                    pendingRefresh = true
                    fibaro.setTimeout(2000, function()
                        pendingRefresh = false
                        self:updateTuyaState()
                    end)
                end
                if successCallback then
                    successCallback() 
                end
            end,
            error = function(err)
                self:disconnect()
                self.sockloopID = fibaro.setTimeout(self.connect_timeout, function() self:connect() end)
                if self.showdebug then self:debug("tuya QA - error while sending CONTROL") end
            end
        })
    end
end

function QuickApp:formatSinceTs(ts)
    -- ts can be:
    --  * nil      -> return ""
    --  * seconds  -> ~1.7e9 range
    --  * ms       -> ~1.7e12 range
    if not ts then return "" end

    local tsNum = tonumber(ts)
    if not tsNum then return "" end

    -- If it's very large, assume milliseconds and convert to seconds
    if tsNum > 2000000000 then  -- > ~2033-05-18 in seconds
        tsNum = math.floor(tsNum / 1000)
    end

    local nowSec = os.time()
    local diff = nowSec - tsNum
    if diff < 0 then diff = 0 end

    local s = diff % 60
    local m = math.floor(diff / 60) % 60
    local h = math.floor(diff / 3600) % 24
    local d = math.floor(diff / 86400)

    if d > 0 then
        return string.format("%dd %dh ago", d, h)
    elseif h > 0 then
        return string.format("%dh %dm ago", h, m)
    elseif m > 0 then
        return string.format("%dm %ds ago", m, s)
    else
        return string.format("%ds ago", s)
    end
end