--[[---------------------------------------------------------
  QuickApp: VeSync Levoit Dual 200S (Cloud) - final 2026-10-28
  Verified VeSync authentication profile; explicit humidity child initialization.

  Fixes based on your real device + plugin behavior:
    ✅ Target humidity setter:
        method = "setTargetHumidity"
        data   = { target_humidity = <int>, id = 0 }
        (NOT auto_target_humidity)

    ✅ Display setter:
        method = "setDisplay"
        data   = { state = <bool>, id = 0 }
        (NOT {display=false})

    ✅ Mode setter:
        method = "setHumidityMode"
        data   = { mode = "auto"/"manual" }
        (plugin uses "mode" key for old-format devices)

    ✅ Mist (Low/High) setter:
        method = "setVirtualLevel"
        data   = { level = 1/2, type = "mist", id = 0 }
        (NOT mist_level)

  Extra requested:
    ✅ All console debug logs behind variable showDebug (true/false)
       - warnings/errors ALWAYS visible
    ✅ New label: btnDispStatus (shows Display: On/Off)

  UI ids (you build in UI Builder):
    lblStatus      : label
    lblHumidity    : label
    btnDispStatus  : label  (requested)
    btnAuto        : button -> QuickApp:setAuto()
    btnLow         : button -> QuickApp:setLow()
    btnHigh        : button -> QuickApp:setHigh()
    sldTarget      : slider -> QuickApp:setTargetFromSlider(value) (visible only in Auto)
    btnDispOn      : button -> QuickApp:displayOn()
    btnDispOff     : button -> QuickApp:displayOff()

  Variables (QuickApp -> Variables):
    email        = VeSync email
    password     = VeSync password
    countryCode  = RO
    apiHost      = https://smartapi.vesync.com or https://smartapi.vesync.eu
    deviceName   = exact VeSync device name (recommended)
    pollSeconds  = 60
    showDebug    = true/false
    humidityChildId = (auto-managed)
-----------------------------------------------------------]]

local json = json or require("json") 

-- ---------- tiny md5 (pure lua) ----------
local md5 = (function()
  local function le2str(x)
    local a = x & 0xff
    local b = (x >> 8) & 0xff
    local c = (x >> 16) & 0xff
    local d = (x >> 24) & 0xff
    return string.char(a,b,c,d)
  end
  local function str2le(s, i)
    local a,b,c,d = s:byte(i,i+3)
    return (a or 0) + ((b or 0) << 8) + ((c or 0) << 16) + ((d or 0) << 24)
  end
  local function rol(x, n) return ((x << n) | (x >> (32-n))) & 0xffffffff end
  local function F(x,y,z) return (x & y) | ((~x) & z) end
  local function G(x,y,z) return (x & z) | (y & (~z)) end
  local function H(x,y,z) return x ~ y ~ z end
  local function I(x,y,z) return y ~ (x | (~z)) end

  local K = {
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
    0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
    0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
    0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
    0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
    0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
  }
  local S = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
  }

  local function sumhexa(msg)
    local orig_len = #msg
    msg = msg .. "\128"
    local pad = (56 - ((orig_len + 1) % 64)) % 64
    msg = msg .. string.rep("\0", pad)
    local bit_len = orig_len * 8
    msg = msg .. le2str(bit_len & 0xffffffff) .. le2str(math.floor(bit_len / 2^32) & 0xffffffff)

    local a0,b0,c0,d0 = 0x67452301,0xefcdab89,0x98badcfe,0x10325476

    for chunk=1,#msg,64 do
      local M = {}
      for i=0,15 do M[i] = str2le(msg, chunk + i*4) end

      local A,B,C,D = a0,b0,c0,d0
      for i=0,63 do
        local f,g
        if i < 16 then f,g = F(B,C,D), i
        elseif i < 32 then f,g = G(B,C,D), (5*i + 1) % 16 
        elseif i < 48 then f,g = H(B,C,D), (3*i + 5) % 16
        else f,g = I(B,C,D), (7*i) % 16 end

        local tmp = D
        D = C
        C = B
        local x = (A + f + K[i+1] + M[g]) & 0xffffffff
        B = (B + rol(x, S[i+1])) & 0xffffffff
        A = tmp
      end

      a0 = (a0 + A) & 0xffffffff
      b0 = (b0 + B) & 0xffffffff
      c0 = (c0 + C) & 0xffffffff
      d0 = (d0 + D) & 0xffffffff
    end

    local digest = le2str(a0)..le2str(b0)..le2str(c0)..le2str(d0)
    return (digest:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end

  return { sumhexa = sumhexa }
end)()
-- ---------- end md5 ----------

-- ---------- constants ----------
local LANG = "en"
local TIMEZONE = "Europe/Bucharest"
local AUTH_APP_VERSION = "5.6.60"
local AUTH_CLIENT_VERSION = "VeSync " .. AUTH_APP_VERSION
local AUTH_CLIENT_INFO = "pyvesync"
local AUTH_OS_INFO = "Android"
local BYPASS_UA = "okhttp/3.12.1"

local function randStr(n)
  local t = {}
  for i=1,n do t[i] = string.char(math.random(97, 122)) end
  return table.concat(t)
end

-- ------------------------------------------------------------
-- Debug helpers
-- ------------------------------------------------------------
function QuickApp:isDebug()
  local v = tostring(self.showDebug or ""):lower()
  return (v == "1" or v == "true" or v == "yes" or v == "on")
end
function QuickApp:dbg(msg) if self:isDebug() then self:debug(msg) end end
function QuickApp:inf(msg) if self:isDebug() then self:debug("INFO  " .. msg) end end
function QuickApp:wrn(msg) self:warning("WARN  " .. msg) end
function QuickApp:err(msg) self:error("ERROR " .. msg) end

function QuickApp:shortJson(v, maxLen)
  maxLen = maxLen or 500
  local s = ""
  local ok = pcall(function() s = json.encode(v) end)
  if not ok then return "<non-json>" end
  if #s > maxLen then return s:sub(1, maxLen) .. "...(" .. tostring(#s) .. " chars)" end
  return s
end

-- ------------------------------------------------------------
-- UI helpers
-- ------------------------------------------------------------
function QuickApp:safeUpdateView(el, prop, val)
  local ok = pcall(function() self:updateView(el, prop, val) end)
  self:dbg(("UI %s.%s = %s (%s)"):format(tostring(el), tostring(prop), tostring(val), ok and "OK" or "FAIL"))
  return ok
end

function QuickApp:setLog(text)
  local ok = pcall(function() self:updateProperty("log", text) end)
  self:dbg("updateProperty log = " .. tostring(text) .. " (" .. (ok and "OK" or "FAIL") .. ")")
end

function QuickApp:pushWarningUI(text)
  self:wrn(text)
  self:safeUpdateView("lblStatus", "text", "⚠ " .. text)
  self:setLog("⚠ " .. text)
end

-- ------------------------------------------------------------
-- Lifecycle
-- ------------------------------------------------------------
function QuickApp:onInit()
  math.randomseed(os.time())

  self.email       = self:getVariable("email")
  self.password    = self:getVariable("password")
  self.countryCode = (self:getVariable("countryCode") or "RO"):upper()
  self.baseUrl     = self:getVariable("apiHost") or "https://smartapi.vesync.com"
  self.deviceName  = self:getVariable("deviceName")
  self.pollSeconds = tonumber(self:getVariable("pollSeconds") or "60")
  self.showDebug   = self:getVariable("showDebug") or "false"

  self.http = net.HTTPClient({ timeout = 15000 })

  self.token = nil
  self.accountId = nil
  self.device = nil

  self._busyLogin = false
  self._polling = false

  self._lastTarget = nil
  self._lastMode = nil
  self._lastMist = nil
  self._lastDisplay = nil

  self.hChildId = tonumber(self:getVariable("humidityChildId") or "") or nil

  self:inf("QA init showDebug=" .. tostring(self.showDebug))
  self:inf("apiHost=" .. tostring(self.baseUrl) .. " countryCode=" .. tostring(self.countryCode))
  self:inf("deviceName=" .. tostring(self.deviceName) .. " pollSeconds=" .. tostring(self.pollSeconds))

  -- Initialize existing children explicitly before HC3's automatic fallback.
  self:initChildDevices({ ["com.fibaro.humiditySensor"] = QuickAppChild })
  self:ensureHumidityChild()

  self:safeUpdateView("lblStatus", "text", "Loading...")
  self:safeUpdateView("lblHumidity", "text", "—")
  self:safeUpdateView("btnDispStatus", "text", "Display: —")
  self:safeUpdateView("sldTarget", "visible", false)
  self:safeUpdateView("sldTarget", "min", "30")
  self:safeUpdateView("sldTarget", "max", "80")

  if not self.email or not self.password then
    self:err("Set QA Variables: email + password")
    self:pushWarningUI("Missing credentials")
    return
  end

  self:loginAndSelectDevice(function(ok)
    if not ok then return end
    self:poll()
  end)
end

-- ------------------------------------------------------------
-- Child humidity sensor
-- ------------------------------------------------------------
function QuickApp:ensureHumidityChild()
  local children = self.childDevices or {}
  local child = self.hChildId and children[self.hChildId] or nil
  if not child or child.type ~= "com.fibaro.humiditySensor" then
    child = nil
    for _, candidate in pairs(children) do
      if candidate.type == "com.fibaro.humiditySensor" then
        child = candidate
        break
      end
    end
  end

  if not child then
    self:inf("Creating humidity child device...")
    local props = {
      name = "Humidity",
      type = "com.fibaro.humiditySensor",
      initialProperties = { value = 0, unit = "%" }
    }
    local ok, result = pcall(function()
      return self:createChildDevice(props, QuickAppChild)
    end)
    if not ok or not result or not result.id then
      self.hChildId = nil
      self:wrn("Failed to create humidity child (continuing without).")
      return
    end
    child = result
  end

  self.hChildId = child.id
  self:setVariable("humidityChildId", tostring(child.id))
  self:inf("Humidity child id=" .. tostring(child.id))
end

function QuickApp:updateHumidityChild(val)
  local h = tonumber(val)
  if not h or h ~= h or h < 0 or h > 100 then return end
  local child = self.hChildId and self.childDevices and self.childDevices[self.hChildId]
  if not child then return end
  local ok, err = pcall(function() child:updateProperty("value", h) end)
  if not ok then self:wrn("Humidity child update failed: " .. tostring(err)) end
end

-- ------------------------------------------------------------
-- HTTP + Auth
-- ------------------------------------------------------------
local function headersAuth()
  return {
    ["Content-Type"] = "application/json; charset=UTF-8",
    ["User-Agent"] = BYPASS_UA,
  }
end

function QuickApp:headersApi()
  return {
    ["content-type"] = "application/json",
    ["accept-language"] = LANG,
    ["accountid"] = self.accountId or "",
    ["user-agent"] = "VeSync/5.6.60 (iPhone; iOS; Humidifier/5.00)",
    ["appversion"] = "VeSync 5.6.60",
    ["tz"] = TIMEZONE,
    ["tk"] = self.token or "",
  }
end

-- Redact before truncating: auth responses may contain reusable credentials.
local function safeLogValue(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    local name = tostring(k):lower()
    if name == "password" or name == "email" or name == "verifyemail"
      or name == "authorizecode" or name == "token" or name == "biztoken"
      or name == "accountid" then
      out[k] = "[redacted]"
    else
      out[k] = safeLogValue(v)
    end
  end
  return out
end

function QuickApp:newAuthTraceId(appID)
  self._authCallNumber = (self._authCallNumber or 0) + 1
  return ("APP%s%d-%05d"):format(appID, os.time(), self._authCallNumber)
end

function QuickApp:httpRequest(method, url, headers, body, cb)
  self:inf(("HTTP %s %s (loading)"):format(method, url))
  self:dbg("HTTP body: " .. self:shortJson(safeLogValue(body or {}), 1200))

  self.http:request(url, {
    options = {
      method = method,
      headers = headers,
      data = body and json.encode(body) or nil
    },
    success = function(resp)
      self:inf(("HTTP %s %s -> status=%s (success)"):format(method, url, tostring(resp.status)))
      local ok, decoded = pcall(function() return json.decode(resp.data) end)
      if ok then self:dbg("HTTP resp: " .. self:shortJson(safeLogValue(decoded), 1200)) end
      cb(true, resp.status, ok and decoded or nil, resp.data)
    end,
    error = function(err)
      self:err(("HTTP %s %s (error): %s"):format(method, url, tostring(err)))
      cb(false, 0, nil, err)
    end
  })
end

function QuickApp:authStep1(terminalId, appID, cb)
  local body = {
    email = self.email,
    method = "authByPWDOrOTM",
    password = md5.sumhexa(self.password),
    acceptLanguage = LANG,
    accountID = "",
    authProtocolType = "generic",
    clientInfo = AUTH_CLIENT_INFO,
    clientType = "vesyncApp",
    clientVersion = AUTH_CLIENT_VERSION,
    debugMode = false,
    osInfo = AUTH_OS_INFO,
    terminalId = terminalId,
    timeZone = TIMEZONE,
    token = "",
    userCountryCode = self.countryCode,
    appID = appID,
    sourceAppID = appID,
    traceId = self:newAuthTraceId(appID)
  }
  local url = self.baseUrl .. "/globalPlatform/api/accountAuth/v1/authByPWDOrOTM"
  self:httpRequest("POST", url, headersAuth(), body, function(ok, status, data, raw)
    if not ok or status ~= 200 or type(data) ~= "table"
      or data.code ~= 0 or type(data.result) ~= "table" then
      self:wrn(("Auth failed: HTTP=%s code=%s msg=%s"):format(
        tostring(status), tostring(type(data) == "table" and data.code or "?"),
        tostring(type(data) == "table" and data.msg or "Invalid/no JSON")))
      cb(false); return
    end
    cb(true, data.result)
  end)
end

function QuickApp:authStep2(authorizeCode, bizToken, terminalId, appID, cb)
  local body = {
    method = "loginByAuthorizeCode4Vesync",
    authorizeCode = authorizeCode,
    accountID = "",
    token = "",
    acceptLanguage = LANG,
    clientInfo = AUTH_CLIENT_INFO,
    clientType = "vesyncApp",
    clientVersion = AUTH_CLIENT_VERSION,
    debugMode = false,
    emailSubscriptions = false,
    osInfo = AUTH_OS_INFO,
    terminalId = terminalId,
    timeZone = TIMEZONE,
    userCountryCode = self.countryCode,
    traceId = self:newAuthTraceId(appID)
  }
  if bizToken then body.bizToken = bizToken end

  local url = self.baseUrl .. "/user/api/accountManage/v1/loginByAuthorizeCode4Vesync"
  self:httpRequest("POST", url, headersAuth(), body, function(ok, status, data, raw)
    if not ok or status ~= 200 or type(data) ~= "table"
      or data.code ~= 0 or type(data.result) ~= "table" then
      self:wrn(("Auth failed: HTTP=%s code=%s msg=%s"):format(
        tostring(status), tostring(type(data) == "table" and data.code or "?"),
        tostring(type(data) == "table" and data.msg or "Invalid/no JSON")))
      cb(false); return
    end
    cb(true, data.result)
  end)
end

function QuickApp:login(cb)
  if self._busyLogin then cb(false); return end
  self._busyLogin = true
  self:inf("Login started...")

  -- Match pyvesync's terminal format: prefix 2 plus 32 hex characters.
  -- Reuse the identity for subsequent logins during this QA run.
  if not self._authTerminalId then
    local hex = {}
    for i = 1, 32 do hex[i] = ("%x"):format(math.random(0, 15)) end
    self._authTerminalId = "2" .. table.concat(hex)
  end
  local terminalId = self._authTerminalId
  local appID = "eldodkfj"

  local authStarted = os.time()
  self:inf("Auth start UTC=" .. os.date("!%Y-%m-%dT%H:%M:%SZ", authStarted))
  self:authStep1(terminalId, appID, function(ok, r1)
    if not ok or type(r1) ~= "table" or type(r1.authorizeCode) ~= "string" or r1.authorizeCode == "" then
      self._busyLogin = false
      cb(false); return
    end

    self:inf(("Auth code received: length=%d; exchanging after %ds"):format(#r1.authorizeCode, os.time() - authStarted))
    -- Initial exchange has no region-change bizToken (matches pyvesync).
    self:authStep2(r1.authorizeCode, nil, terminalId, appID, function(ok2, r2)
      self._busyLogin = false
      if not ok2 or not r2 then cb(false); return end
      self.token = r2.token
      self.accountId = r2.accountID
      cb(self.token ~= nil and self.accountId ~= nil)
    end)
  end)
end

function QuickApp:fetchDevices(cb)
  local url = self.baseUrl .. "/cloud/v2/deviceManaged/devices"
  local body = {
    method = "devices",
    pageNo = 1,
    pageSize = 1000,
    appVersion = "VeSync 5.6.60",
    phoneBrand = "Apple",
    traceId = "APP" .. tostring(os.time()) .. "-00001",
    phoneOS = "iOS",
    acceptLanguage = LANG,
    timeZone = TIMEZONE,
    accountID = self.accountId,
    token = self.token
  }

  self:httpRequest("POST", url, self:headersApi(), body, function(ok, status, data, raw)
    if not ok or not data then cb(false, status, data, raw); return end
    cb(true, status, data, raw)
  end)
end

function QuickApp:selectDeviceFromList(data)
  if not data or not data.result or not data.result.list then return nil end
  local list = data.result.list
  if type(list) ~= "table" then return nil end

  local pick = nil
  for _, d in ipairs(list) do
    local name = d.deviceName or d.name
    if self.deviceName then
      if name == self.deviceName then pick = d break end
    else
      pick = d; break
    end
  end
  if not pick then return nil end

  return {
    name = pick.deviceName or pick.name,
    cid = pick.cid or pick.deviceCid,
    configModule = pick.configModule,
    region = pick.region or pick.deviceRegion
  }
end

function QuickApp:loginAndSelectDevice(cb)
  self:login(function(ok)
    if not ok then self:pushWarningUI("Login failed"); cb(false); return end
    self:fetchDevices(function(ok2, status, data, raw)
      if not ok2 then self:pushWarningUI("Devices fetch failed"); cb(false); return end
      local dev = self:selectDeviceFromList(data)
      if not dev or not dev.cid or not dev.configModule then
        self:pushWarningUI("Device not found (set deviceName)")
        cb(false); return
      end
      self.device = dev
      self:inf("Selected device: " .. tostring(dev.name))
      cb(true)
    end)
  end)
end

-- ------------------------------------------------------------
-- Retry logic (token expiry)
-- ------------------------------------------------------------
function QuickApp:isAuthError(status, data, raw)
  if status == 401 or status == 403 then return true end
  if type(data) == "table" and data.code and tonumber(data.code) ~= 0 then
    local msg = tostring(data.msg or data.message or ""):lower()
    if msg:find("token") or msg:find("login") or msg:find("unauthor") or msg:find("invalid") then
      return true
    end
  end
  if type(raw) == "string" then
    local r = raw:lower()
    if r:find("invalid token") or (r:find("token") and r:find("expire")) then return true end
  end
  return false
end

function QuickApp:withReloginRetry(fn, cb, label)
  label = label or "request"
  fn(function(ok, status, data, raw)
    if ok and not self:isAuthError(status, data, raw) then
      cb(ok, status, data, raw); return
    end

    if self:isAuthError(status, data, raw) then
      self:wrn(label .. ": token/auth issue -> re-login + retry once")
      self:safeUpdateView("lblStatus", "text", "Re-login...")
      self:setLog("Re-login...")

      self:loginAndSelectDevice(function(okLogin)
        if not okLogin then
          self:pushWarningUI(label .. ": re-login failed")
          cb(false, status, data, raw); return
        end
        fn(function(ok2, status2, data2, raw2)
          cb(ok2, status2, data2, raw2)
        end)
      end)
    else
      cb(ok, status, data, raw)
    end
  end)
end

-- ------------------------------------------------------------
-- bypassV2 core
-- ------------------------------------------------------------
function QuickApp:bypass(methodName, methodData, httpMethod, cb)
  if not self.device then cb(false, 0, nil, "No device selected"); return end

  local url = self.baseUrl .. "/cloud/v2/deviceManaged/bypassV2"
  local body = {
    method = "bypassV2",
    debugMode = false,
    deviceRegion = self.device.region,
    cid = self.device.cid,
    configModule = self.device.configModule,
    payload = {
      data = methodData or {},
      method = methodName,
      source = "APP"
    },
    appVersion = "VeSync 5.6.60",
    phoneBrand = "Apple",
    traceId = "APP" .. tostring(os.time()) .. "-00001",
    phoneOS = "iOS",
    acceptLanguage = LANG,
    timeZone = TIMEZONE,
    accountID = self.accountId,
    token = self.token
  }

  self:inf(("bypass %s (%s)"):format(tostring(methodName), tostring(httpMethod)))
  self:dbg("bypass data: " .. self:shortJson(methodData or {}, 250))

  self:httpRequest(httpMethod, url, self:headersApi(), body, function(ok, status, data, raw)
    cb(ok, status, data, raw)
  end)
end

-- ------------------------------------------------------------
-- Status + controls (aligned to plugin)
-- ------------------------------------------------------------
function QuickApp:getStatus(cb)
  self:withReloginRetry(function(done)
    self:bypass("getHumidifierStatus", {}, "POST", done)
  end, cb, "getStatus")
end

function QuickApp:setMode(mode, cb)
  -- mode: "auto" / "manual"
  self:withReloginRetry(function(done)
    self:bypass("setHumidityMode", { mode = mode }, "PUT", done)
  end, cb, "setMode(" .. tostring(mode) .. ")")
end

function QuickApp:setMistLevel(level, cb)
  -- Low/High -> setVirtualLevel with {level, type="mist", id=0}
  self:withReloginRetry(function(done)
    self:bypass("setVirtualLevel", { level = tonumber(level), type = "mist", id = 0 }, "PUT", done)
  end, cb, "setMistLevel(" .. tostring(level) .. ")")
end

function QuickApp:setTargetHumidity(target, cb)
  -- Important: old-format uses target_humidity
  self:withReloginRetry(function(done)
    self:bypass("setTargetHumidity", { target_humidity = target, id = 0 }, "PUT", done)
  end, cb, "setTargetHumidity(" .. tostring(target) .. ")")
end

function QuickApp:setDisplay(on, cb)
  -- Important: old-format uses state
  self:withReloginRetry(function(done)
    self:bypass("setDisplay", { state = (on and true or false), id = 0 }, "PUT", done)
  end, cb, "setDisplay(" .. tostring(on) .. ")")
end

function QuickApp:setSwitch(state, cb)
  -- Dual200S status uses "enabled"; old-format setter usually expects enabled + id=0
  self:withReloginRetry(function(done)
    self:bypass("setSwitch", { enabled = (state and true or false), id = 0 }, "PUT", done)
  end, cb, "setSwitch(" .. tostring(state) .. ")")
end

-- Optional HC3 switch actions
function QuickApp:turnOn()  self:setSwitch(true, function() self:pollOnce() end) end
function QuickApp:turnOff() self:setSwitch(false, function() self:pollOnce() end) end

-- ------------------------------------------------------------
-- UI Actions
-- ------------------------------------------------------------
function QuickApp:setAuto()
  self:inf("UI Action: setAuto()")
  self:safeUpdateView("lblStatus", "text", "Auto (setting...)")
  self:setLog("Auto (setting...)")
  self:setMode("auto", function(ok)
    if not ok then self:pushWarningUI("Failed to set Auto") return end
    self:pollOnce()
  end)
end

function QuickApp:setLow()
  self:inf("UI Action: setLow()")
  self:safeUpdateView("lblStatus", "text", "Low (setting...)")
  self:setLog("Low (setting...)")
  self:setMode("manual", function(ok)
    if not ok then self:pushWarningUI("Failed to set Manual") return end
    self:setMistLevel(1, function(ok2)
      if not ok2 then self:pushWarningUI("Failed to set Low") end
      self:pollOnce()
    end)
  end)
end

function QuickApp:setHigh()
  self:inf("UI Action: setHigh()")
  self:safeUpdateView("lblStatus", "text", "High (setting...)")
  self:setLog("High (setting...)")
  self:setMode("manual", function(ok)
    if not ok then self:pushWarningUI("Failed to set Manual") return end
    self:setMistLevel(2, function(ok2)
      if not ok2 then self:pushWarningUI("Failed to set High") end
      self:pollOnce()
    end)
  end)
end

function QuickApp:setTargetFromSlider(ev)
  local v = nil
  if type(ev) == "table" and type(ev.values) == "table" then
    v = tonumber(ev.values[1])
  else
    v = tonumber(ev)
  end
  self:inf("UI Action: setTargetFromSlider(" .. tostring(value) .. ")")
  if not v then self:pushWarningUI("Slider value invalid") return end

  -- Only meaningful in Auto
  self._lastTarget = v
  self:safeUpdateView("sldTarget", "visible", true)
  self:safeUpdateView("lblStatus", "text", "Auto")
  self:setLog(("Auto - Target %d%%"):format(v))

  self:setTargetHumidity(v, function(ok)
    if not ok then self:pushWarningUI("Failed to set target humidity") end
    self:pollOnce()
  end)
end

function QuickApp:displayOn()
  self:inf("UI Action: displayOn()")
  self:setDisplay(true, function(ok)
    if not ok then self:pushWarningUI("Failed: display ON") end
    self:pollOnce()
  end)
end

function QuickApp:displayOff()
  self:inf("UI Action: displayOff()")
  self:setDisplay(false, function(ok)
    if not ok then self:pushWarningUI("Failed: display OFF") end
    self:pollOnce()
  end)
end

-- ------------------------------------------------------------
-- Status -> UI mapping (based on your payload)
-- ------------------------------------------------------------
function QuickApp:extractStateFromResponse(data)
  if not data then return nil end
  if data.result and data.result.result and type(data.result.result) == "table" then return data.result.result end
  if type(data.result) == "table" and data.result.humidity ~= nil then return data.result end
  return nil
end

function QuickApp:computeModeText(mode, mistLevel, target)
  mode = tostring(mode or ""):lower()
  if mode == "auto" then
    local t = tonumber(target) or tonumber(self._lastTarget) or 0
    return "Auto", ("Auto - Target %d%%"):format(t)
  end
  if tonumber(mistLevel) == 2 then return "High", "High" end
  return "Low", "Low"
end

function QuickApp:applyStatusToUI(state)
  -- power/off handling
  local isOn = (state.enabled == true)
  pcall(function()
    self:updateProperty("value", isOn)
  end)

  if not isOn then
    -- UI + log when device is OFF
    self:safeUpdateView("lblStatus", "text", "Off")
    self:setLog("Off")
    self:safeUpdateView("sldTarget", "visible", false)
    return
  end

  -- humidity
  local hum = tonumber(state.humidity)
  if hum then
    self:safeUpdateView("lblHumidity", "text", ("%d%%"):format(hum))
    self:updateHumidityChild(hum)
  else
    self:safeUpdateView("lblHumidity", "text", "—")
  end

  -- display status (from top-level display OR configuration.display)
  local disp = nil
  if state.display ~= nil then disp = (state.display == true) end
  if disp == nil and state.configuration and state.configuration.display ~= nil then
    disp = (state.configuration.display == true)
  end
  if disp ~= nil then
    self._lastDisplay = disp
    self:safeUpdateView("btnDispStatus", "text", disp and "Display: On" or "Display: Off")
  else
    self:safeUpdateView("btnDispStatus", "text", "Display: —")
  end

  -- core: mode/mist/target
  local mode = state.mode
  local mist = tonumber(state.mist_level) or tonumber(state.mist_virtual_level)
  local target = nil
  if state.configuration and state.configuration.auto_target_humidity ~= nil then
    target = tonumber(state.configuration.auto_target_humidity)
  end

  self._lastTarget = target or self._lastTarget

  local t = tostring(target) or tostring(self._lastTarget)
  if t then
    self:safeUpdateView("sldTarget", "value", t)
  end

  local modeText, logText = self:computeModeText(mode, mist, target)

  -- slider visible only in Auto
  self:safeUpdateView("sldTarget", "visible", modeText == "Auto")

  -- warnings (must appear in lblStatus + log)
  local warns = {}
  if state.water_lacks == true then table.insert(warns, "Water low") end
  if state.water_tank_lifted == true then table.insert(warns, "Tank lifted") end

  if #warns > 0 then
    local w = table.concat(warns, " | ")
    self:safeUpdateView("lblStatus", "text", ("⚠ %s (%s)"):format(w, modeText))
    self:setLog(("⚠ %s | %s"):format(w, logText))
  else
    self:safeUpdateView("lblStatus", "text", modeText)
    self:setLog(logText)
  end

  self:inf(("Status applied: mode=%s mist=%s target=%s hum=%s display=%s")
    :format(tostring(mode), tostring(mist), tostring(target), tostring(hum), tostring(disp)))
end

-- ------------------------------------------------------------
-- Polling
-- ------------------------------------------------------------
function QuickApp:pollOnce()
  self:inf("Poll once...")
  self:getStatus(function(ok, status, data, raw)
    if not ok or not data then self:pushWarningUI("Poll failed") return end
    local state = self:extractStateFromResponse(data)
    if not state then
      self:pushWarningUI("Bad status payload shape")
      self:dbg("Raw resp: " .. tostring(raw))
      return
    end
    self:dbg("State: " .. self:shortJson(state, 900))
    self:applyStatusToUI(state)
  end)
end

function QuickApp:poll()
  if self._polling then self:wrn("Polling already running; ignoring.") return end
  self._polling = true
  self:inf("Polling started interval=" .. tostring(self.pollSeconds) .. "s")

  local function loop()
    self:pollOnce()
    fibaro.setTimeout(self.pollSeconds * 1000, loop)
  end

  loop()
end