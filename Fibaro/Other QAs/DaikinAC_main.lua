--------------------------------------------------
-- Daikin Onecta Duct HVAC PRO (HC3) - FINAL FULL
-- Thermostat: Off/Heat/Cool/Auto
-- Child toggle switches: Dry, FanOnly (mutually exclusive) ✅ turnOn/turnOff + setValue
-- Child fan slider: 1..3 ✅ setValue
-- Child temperature sensor: Actual room temp
-- Auto reauth on 401 + retry once
-- Refresh after SET: refreshDelaySec (default 30s) + second refresh at 60s
-- lblStatus: "Online | Heat | Room 24°C"
--------------------------------------------------

local json = json or require("json")

local API_BASE  = "https://api.onecta.daikineurope.com/v1"
local TOKEN_URL = "https://idp.onecta.daikineurope.com/v1/oidc/token"

--------------------------------------------------
-- Utils
--------------------------------------------------

local function urlEncode(str)
  return tostring(str or ""):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function formEncode(tbl)
  local parts={}
  for k,v in pairs(tbl) do table.insert(parts, urlEncode(k).."="..urlEncode(v)) end
  table.sort(parts)
  return table.concat(parts,"&")
end

local function clamp(x,a,b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function safeDecode(s)
  if not s or s=="" then return nil end
  local ok, v = pcall(json.decode, s)
  if ok then return v end
  return nil
end

local function unwrap(node)
  if type(node)=="table" and node.value~=nil then return node.value end
  return node
end

local function fmtTempC(t)
  if t == nil then return "-" end
  local n = tonumber(t); if not n then return "-" end
  if math.abs(n - math.floor(n)) < 0.001 then return string.format("%d°C", math.floor(n)) end
  return string.format("%.1f°C", n)
end

--------------------------------------------------
-- Child classes
--------------------------------------------------

class 'DaikinFanChild'(QuickAppChild)
function DaikinFanChild:__init(device) QuickAppChild.__init(self, device) end
function DaikinFanChild:setValue(v)
  v = tonumber(v) or 0
  self.parent:debugLog("FanChild:setValue "..tostring(v))
  self.parent:setFanFromPercent(v)
end

class 'DaikinModeSwitchChild'(QuickAppChild)
function DaikinModeSwitchChild:__init(device) QuickAppChild.__init(self, device) end

-- Some HC3 templates call turnOn/turnOff
function DaikinModeSwitchChild:turnOn()
  local modeKey = self.parent.childModeById and self.parent.childModeById[self.id]
  self.parent:debugLog("ModeSwitch:turnOn id="..tostring(self.id).." key="..tostring(modeKey))
  if not modeKey then
    self.parent:warning("ModeSwitch has no modeKey mapping.")
    return
  end
  self.parent:setSpecialMode(modeKey, true, "child")
end

function DaikinModeSwitchChild:turnOff()
  local modeKey = self.parent.childModeById and self.parent.childModeById[self.id]
  self.parent:debugLog("ModeSwitch:turnOff id="..tostring(self.id).." key="..tostring(modeKey))
  if not modeKey then
    self.parent:warning("ModeSwitch has no modeKey mapping.")
    return
  end
  self.parent:setSpecialMode(modeKey, false, "child")
end

-- Others call setValue(0/1) - keep as fallback
function DaikinModeSwitchChild:setValue(v)
  local on = (tonumber(v) == 1) or (v == true)
  local modeKey = self.parent.childModeById and self.parent.childModeById[self.id]
  self.parent:debugLog("ModeSwitch:setValue id="..tostring(self.id).." key="..tostring(modeKey).." -> "..tostring(on))
  if not modeKey then
    self.parent:warning("ModeSwitch has no modeKey mapping.")
    return
  end
  self.parent:setSpecialMode(modeKey, on, "child")
end

class 'DaikinRoomTempChild'(QuickAppChild)
function DaikinRoomTempChild:__init(device) QuickAppChild.__init(self, device) end

--------------------------------------------------
-- UI helpers
--------------------------------------------------

function QuickApp:debugLog(msg)
  if self.debugEnabled then self:trace(msg) end
end

function QuickApp:setStatus(text)
  self:updateView("lblStatus","text",text)
end

function QuickApp:setFanLabel(text)
  self:updateView("lblFan","text",text)
end

function QuickApp:setModeLog(text)
  pcall(function() self:updateProperty("log", text) end)
end

function QuickApp:updateStatusLine(isOnline, displayMode, roomTemp)
  local onlinePart = isOnline and "Online" or "Offline"
  local modePart = displayMode or "-"
  local tempPart = "Room " .. fmtTempC(roomTemp)
  self:setStatus(string.format("%s | %s | %s", onlinePart, modePart, tempPart))
end

--------------------------------------------------
-- Config
--------------------------------------------------

function QuickApp:getRefreshDelaySeconds()
  return tonumber(self:getVariable("refreshDelaySec") or "30") or 30
end

--------------------------------------------------
-- Init
--------------------------------------------------

function QuickApp:onInit()
  self.clientId     = self:getVariable("clientId") or ""
  self.clientSecret = self:getVariable("clientSecret") or ""
  self.redirectUri  = self:getVariable("redirectUri") or ""
  self.authCode     = self:getVariable("authCode") or ""
  self.refreshToken = self:getVariable("refreshToken") or ""
  self.deviceId     = self:getVariable("deviceId") or ""
  self.pollMinutes  = tonumber(self:getVariable("pollMinutes") or "15") or 15
  self.debugEnabled = (self:getVariable("debug") == "true")

  self._reauthInProgress = false
  self._retryOnce = {}

  -- robust mapping (childId -> modeKey)
  self.childModeById = {}

  self.http = net.HTTPClient({timeout=20000})

  -- Thermostat capabilities
  self:updateProperty("supportedModes",{"Off","Heat","Cool","Auto"})
  self:updateProperty("heatingThermostatSetpointCapabilitiesMin", 16)
  self:updateProperty("heatingThermostatSetpointCapabilitiesMax", 32)
  self:updateProperty("coolingThermostatSetpointCapabilitiesMin", 16)
  self:updateProperty("coolingThermostatSetpointCapabilitiesMax", 32)
  self:updateProperty("autoThermostatSetpointCapabilitiesMin", 12)
  self:updateProperty("autoThermostatSetpointCapabilitiesMax", 32)

  self:updateStatusLine(true, "Init", nil)
  self:setFanLabel("Fan: -")

  if self.clientId=="" or self.clientSecret=="" then
    self:error("Missing clientId/clientSecret.")
    self:updateStatusLine(false, "ERROR", nil)
    return
  end

  self:authorize(function(ok)
    if not ok then return end
    self:bootstrap(function(ok2)
      if not ok2 then return end
      self:createChildrenIfNeeded()
      self:startPolling()
    end)
  end)
end

--------------------------------------------------
-- OAuth
--------------------------------------------------

function QuickApp:authorize(cb)
  if self.refreshToken == "" and (self.authCode == "" or self.redirectUri == "") then
    self:error("No refreshToken and no authCode/redirectUri available.")
    cb(false); return
  end

  local params = { client_id=self.clientId, client_secret=self.clientSecret }
  if self.refreshToken ~= "" then
    params.grant_type="refresh_token"
    params.refresh_token=self.refreshToken
  else
    params.grant_type="authorization_code"
    params.code=self.authCode
    params.redirect_uri=self.redirectUri
  end

  self.http:request(TOKEN_URL, {
    options = {
      method = "POST",
      headers = { ["Accept"]="application/json", ["Content-Type"]="application/x-www-form-urlencoded" },
      data = formEncode(params)
    },
    success = function(resp)
      local status = tonumber(resp.status) or 0
      local data = safeDecode(resp.data)
      if self.debugEnabled then self:trace("AUTH HTTP "..tostring(status)) end
      if status<200 or status>=300 or not data or not data.access_token then
        self:error("Auth failed HTTP "..tostring(status))
        cb(false); return
      end
      self.accessToken = data.access_token
      if data.refresh_token and data.refresh_token ~= "" then
        self.refreshToken = data.refresh_token
        self:setVariable("refreshToken", data.refresh_token)
      end
      if self.authCode ~= "" then self:setVariable("authCode",""); self.authCode="" end
      cb(true)
    end,
    error = function(e)
      self:error("Auth error: "..tostring(e))
      cb(false)
    end
  })
end

--------------------------------------------------
-- API (401 reauth)
--------------------------------------------------

function QuickApp:api(method, path, body, cb)
  local url = API_BASE .. path
  local payload = body and json.encode(body) or nil

  local function doRequest()
    self.http:request(url, {
      options = {
        method = method,
        headers = {
          ["Accept"]="application/json",
          ["Authorization"]="Bearer " .. tostring(self.accessToken or ""),
          ["Content-Type"]="application/json",
        },
        data = payload
      },
      success = function(resp)
        local status = tonumber(resp.status) or 0
        local data = safeDecode(resp.data)
        if self.debugEnabled then self:trace(method.." "..url.." -> "..tostring(status)) end

        if status == 401 then
          local key = method.." "..path
          if self._retryOnce[key] then self._retryOnce[key]=nil; cb(nil,status,data,resp.data); return end
          self._retryOnce[key]=true

          self:warning("401 -> reauth + retry")

          if self._reauthInProgress then
            fibaro.setTimeout(1200, function() doRequest() end)
            return
          end

          self._reauthInProgress = true
          self:authorize(function(ok)
            self._reauthInProgress = false
            if not ok then cb(nil,status,data,resp.data); return end
            doRequest()
          end)
          return
        end

        cb(nil,status,data,resp.data)
      end,
      error = function(e) cb(tostring(e),0,nil,nil) end
    })
  end

  doRequest()
end

--------------------------------------------------
-- Bootstrap / Poll
--------------------------------------------------

function QuickApp:bootstrap(cb)
  self:api("GET","/gateway-devices", nil, function(err, status, list)
    if err or status~=200 or type(list)~="table" or #list==0 then
      self:error("Devices list failed. status="..tostring(status))
      self:updateStatusLine(false, "Devices", nil)
      cb(false); return
    end
    if self.deviceId=="" then
      self.deviceId = tostring(list[1].id or list[1]._id)
      self:setVariable("deviceId", self.deviceId)
    end
    self:refreshDevice(function(ok) cb(ok) end)
  end)
end

function QuickApp:startPolling()
  local intervalMs = math.max(1, self.pollMinutes)*60*1000
  if self.pollTimer then fibaro.clearTimeout(self.pollTimer); self.pollTimer=nil end
  local function loop()
    self:refreshDevice()
    self.pollTimer = fibaro.setTimeout(intervalMs, loop)
  end
  loop()
end

--------------------------------------------------
-- Extractors
--------------------------------------------------

function QuickApp:getMP(dev, embeddedId)
  if not dev or not dev.managementPoints then return nil end
  for _,mp in pairs(dev.managementPoints) do
    if mp.embeddedId == embeddedId then return mp end
  end
  return nil
end

function QuickApp:getPower(cc) return unwrap(cc.onOffMode) end
function QuickApp:getOperationMode(cc) return unwrap(cc.operationMode) end

function QuickApp:getRoomTemp(cc)
  local sd = unwrap(cc.sensoryData)
  if type(sd)~="table" then return nil end
  return tonumber(unwrap(sd.roomTemperature))
end

function QuickApp:getSetpoint(cc, modeKey)
  local tc = unwrap(cc.temperatureControl)
  if type(tc)~="table" then return nil end
  local ops = tc.operationModes
  if type(ops)~="table" then return nil end
  local m = ops[modeKey]
  if type(m)~="table" then return nil end
  return tonumber(unwrap(m.setpoints and m.setpoints.roomTemperature))
end

function QuickApp:getFanLevel(cc)
  local fc = unwrap(cc.fanControl)
  if type(fc)~="table" then return nil end
  local opMode = self:getOperationMode(cc) or "auto"
  local om = fc.operationModes and fc.operationModes[opMode]
  if type(om)~="table" then return nil end
  local fs = om.fanSpeed
  if type(fs)~="table" then return nil end
  local fixed = fs.modes and fs.modes.fixed
  if type(fixed)~="table" then return nil end
  return tonumber(unwrap(fixed))
end

--------------------------------------------------
-- Children
--------------------------------------------------

function QuickApp:createChildrenIfNeeded()
  self:createFanChildIfNeeded()
  self:createModeSwitchChildIfNeeded("dry", "Daikin Dry Mode")
  self:createModeSwitchChildIfNeeded("fanOnly", "Daikin Fan Only")
  self:createRoomTempChildIfNeeded()
end

function QuickApp:createFanChildIfNeeded()
  local children = self.childDevices or {}
  for _,c in pairs(children) do
    if c.name == "Daikin Fan" then self.fanChild=c; return end
  end
  self.fanChild = self:createChildDevice({
    name="Daikin Fan",
    type="com.fibaro.multilevelSwitch",
    className="DaikinFanChild"
  }, DaikinFanChild)
end

function QuickApp:createModeSwitchChildIfNeeded(modeKey, name)
  self.modeChildren = self.modeChildren or {}
  local children = self.childDevices or {}

  for _,c in pairs(children) do
    if c.name == name then
      self.modeChildren[modeKey] = c
      self.childModeById[c.id] = modeKey
      return
    end
  end

  local child = self:createChildDevice({
    name=name,
    type="com.fibaro.binarySwitch",
    className="DaikinModeSwitchChild"
  }, DaikinModeSwitchChild)

  self.modeChildren[modeKey] = child
  self.childModeById[child.id] = modeKey
end

function QuickApp:createRoomTempChildIfNeeded()
  local children = self.childDevices or {}
  for _,c in pairs(children) do
    if c.name == "Daikin Room Temperature" then self.roomTempChild=c; return end
  end
  self.roomTempChild = self:createChildDevice({
    name="Daikin Room Temperature",
    type="com.fibaro.temperatureSensor",
    className="DaikinRoomTempChild"
  }, DaikinRoomTempChild)
end

function QuickApp:updateRoomTempChild(t)
  if not self.roomTempChild or t==nil then return end
  self.roomTempChild:updateProperty("value", t)
end

--------------------------------------------------
-- Fan mapping
--------------------------------------------------

function QuickApp:fanLevelToPercent(level)
  if level == 1 then return 33 end
  if level == 2 then return 66 end
  if level == 3 then return 99 end
  return 0
end

function QuickApp:percentToFanLevel(p)
  p = tonumber(p) or 0
  if p <= 45 then return 1 end
  if p <= 80 then return 2 end
  return 3
end

function QuickApp:updateFanChildFromLevel(level)
  if not self.fanChild then return end
  if hub.getValue(635, "thermostatMode") == "Off" then 
    self.fanChild:updateProperty("value", 0)
  else 
    self.fanChild:updateProperty("value", self:fanLevelToPercent(level))
  end
end

function QuickApp:setFanFromPercent(pct)
  self:setFanLevel(self:percentToFanLevel(pct))
end

--------------------------------------------------
-- Switch sync (0/1)
--------------------------------------------------

function QuickApp:optimisticSetSpecialSwitches(dryOn, fanOn)
  local dryChild = self.modeChildren and self.modeChildren["dry"]
  local fanChild = self.modeChildren and self.modeChildren["fanOnly"]
  if dryChild then dryChild:updateProperty("value", dryOn and 1 or 0) end
  if fanChild then fanChild:updateProperty("value", fanOn and 1 or 0) end
end

function QuickApp:syncModeSwitches(power, opMode)
  local dryOn = (power=="on" and opMode=="dry")
  local fanOn = (power=="on" and opMode=="fanOnly")

  local dryChild = self.modeChildren and self.modeChildren["dry"]
  local fanChild = self.modeChildren and self.modeChildren["fanOnly"]
  if dryChild then dryChild:updateProperty("value", dryOn and 1 or 0) end
  if fanChild then fanChild:updateProperty("value", fanOn and 1 or 0) end

  if dryOn then self:setModeLog("Dry mode active")
  elseif fanOn then self:setModeLog("Fan only active")
  else self:setModeLog("") end
end

--------------------------------------------------
-- Refresh
--------------------------------------------------

function QuickApp:refreshDevice(cb)
  self:api("GET","/gateway-devices/"..self.deviceId, nil, function(err, status, dev)
    if err or status~=200 or type(dev)~="table" then
      self:error("refreshDevice failed status="..tostring(status))
      self:updateStatusLine(false, "Offline", nil)
      if cb then cb(false) end
      return
    end

    self.device = dev
    local cc = self:getMP(dev, "climateControl")
    if not cc then
      self:updateStatusLine(false, "NoMP", nil)
      if cb then cb(false) end
      return
    end

    local power = self:getPower(cc) or "off"
    local opMode = self:getOperationMode(cc) or "auto"
    local roomTemp = self:getRoomTemp(cc)

    local fibMode="Off"
    if power=="on" then
      if opMode=="heating" then fibMode="Heat"
      elseif opMode=="cooling" then fibMode="Cool"
      else fibMode="Auto" end
    end
    self:updateProperty("thermostatMode", fibMode)

    if roomTemp~=nil then
      self:updateProperty("temperature", roomTemp)
      self:updateRoomTempChild(roomTemp)
    end

    local heatSp = self:getSetpoint(cc,"heating")
    local coolSp = self:getSetpoint(cc,"cooling")
    local autoSp = self:getSetpoint(cc,"auto")
    if heatSp~=nil then self:updateProperty("heatingThermostatSetpoint", heatSp) end
    if coolSp~=nil then self:updateProperty("coolingThermostatSetpoint", coolSp) end
    if autoSp~=nil then self:updateProperty("autoThermostatSetpoint", autoSp) end

    if fibMode=="Heat" and heatSp~=nil then self:updateProperty("targetTemperature", heatSp)
    elseif fibMode=="Cool" and coolSp~=nil then self:updateProperty("targetTemperature", coolSp)
    elseif fibMode=="Auto" then
      local t = autoSp
      if t==nil and heatSp~=nil and coolSp~=nil then t=(heatSp+coolSp)/2 end
      if t~=nil then self:updateProperty("targetTemperature", t) end
    end

    local fan = self:getFanLevel(cc)
    if fan~=nil then
      self:setFanLabel("Fan: "..tostring(fan).." / 3")
      self:updateFanChildFromLevel(fan)
    else
      self:setFanLabel("Fan: -")
    end

    self:syncModeSwitches(power, opMode)

    local displayMode="Off"
    if power=="on" then
      if opMode=="heating" then displayMode="Heat"
      elseif opMode=="cooling" then displayMode="Cool"
      elseif opMode=="dry" then displayMode="Dry"
      elseif opMode=="fanOnly" then displayMode="FanOnly"
      else displayMode="Auto" end
    end
    self:updateStatusLine(true, displayMode, roomTemp)

    if cb then cb(true) end
  end)
end

--------------------------------------------------
-- PATCH helper (refreshDelaySec + 60s)
--------------------------------------------------

function QuickApp:patchCharacteristic(charName, body, onSuccess)
  local path = string.format(
    "/gateway-devices/%s/management-points/%s/characteristics/%s",
    self.deviceId, "climateControl", charName
  )

  self:api("PATCH", path, body, function(err, status)
    if err then self:error("PATCH "..charName.." err="..tostring(err)); return end
    if self.debugEnabled then self:trace("PATCH "..charName.." -> "..tostring(status).." body="..json.encode(body)) end

    if status>=200 and status<300 then
      if onSuccess then pcall(onSuccess) end
      fibaro.setTimeout(self:getRefreshDelaySeconds()*1000, function() self:refreshDevice() end)
      fibaro.setTimeout(60000, function() self:refreshDevice() end)
    else
      self:error("PATCH "..charName.." failed HTTP "..tostring(status))
    end
  end)
end

--------------------------------------------------
-- Thermostat controls
--------------------------------------------------

function QuickApp:setThermostatMode(mode)
  self:optimisticSetSpecialSwitches(false,false)
  self:setModeLog("")

  if mode=="Off" then
    self:patchCharacteristic("onOffMode",{value="off"}, function()
      self:updateProperty("thermostatMode","Off")
      self:updateStatusLine(true,"Off", self.properties and self.properties.temperature)
    end)
    return
  end

  self:patchCharacteristic("onOffMode",{value="on"})
  local m="auto"
  if mode=="Heat" then m="heating"
  elseif mode=="Cool" then m="cooling" end

  self:patchCharacteristic("operationMode",{value=m}, function()
    self:updateProperty("thermostatMode", mode)
    self:updateStatusLine(true, mode, self.properties and self.properties.temperature)
  end)
end

function QuickApp:setHeatingThermostatSetpoint(v)
  v = clamp(tonumber(v) or 16, 16, 32)
  self:patchCharacteristic("temperatureControl",{value=v, path="/operationModes/heating/setpoints/roomTemperature"})
end
function QuickApp:setCoolingThermostatSetpoint(v)
  v = clamp(tonumber(v) or 16, 16, 32)
  self:patchCharacteristic("temperatureControl",{value=v, path="/operationModes/cooling/setpoints/roomTemperature"})
end
function QuickApp:setAutoThermostatSetpoint(v)
  v = clamp(tonumber(v) or 12, 12, 32)
  self:patchCharacteristic("temperatureControl",{value=v, path="/operationModes/auto/setpoints/roomTemperature"})
end
function QuickApp:setTargetTemperature(v)
  v = tonumber(v); if not v then return end
  local mode = self.properties and self.properties.thermostatMode or "Auto"
  if mode=="Auto" then self:setAutoThermostatSetpoint(v)
  elseif mode=="Heat" then self:setHeatingThermostatSetpoint(v)
  elseif mode=="Cool" then self:setCoolingThermostatSetpoint(v)
  end
end

--------------------------------------------------
-- Special modes (Dry/FanOnly) optimistic UI
--------------------------------------------------

function QuickApp:setSpecialMode(modeKey, turnOn)
  if turnOn then
    if modeKey=="dry" then
      self:optimisticSetSpecialSwitches(true,false)
      self:setModeLog("Dry mode active")
      self:updateStatusLine(true,"Dry", self.properties and self.properties.temperature)
    else
      self:optimisticSetSpecialSwitches(false,true)
      self:setModeLog("Fan only active")
      self:updateStatusLine(true,"FanOnly", self.properties and self.properties.temperature)
    end
    self:patchCharacteristic("onOffMode",{value="on"})
    self:patchCharacteristic("operationMode",{value=modeKey})
  else
    self:optimisticSetSpecialSwitches(false,false)
    self:setModeLog("")
    self:patchCharacteristic("onOffMode",{value="off"}, function()
      self:updateProperty("thermostatMode","Off")
      self:updateStatusLine(true,"Off", self.properties and self.properties.temperature)
    end)
  end
end

--------------------------------------------------
-- Fan control
--------------------------------------------------

function QuickApp:setFanLevel(level)
  level = clamp(tonumber(level) or 1, 1, 3)
  local cc = self.device and self:getMP(self.device,"climateControl") or nil
  local opMode = cc and self:getOperationMode(cc) or "auto"

  if opMode=="dry" then
    self:warning("Fan fixed speed not available in DRY mode.")
    return
  end

  self:patchCharacteristic("fanControl",{value="fixed", path="/operationModes/"..opMode.."/fanSpeed/currentMode"})
  self:patchCharacteristic("fanControl",{value=level, path="/operationModes/"..opMode.."/fanSpeed/modes/fixed"}, function()
    self:setFanLabel("Fan: "..tostring(level).." / 3")
    self:updateFanChildFromLevel(level)
  end)
end

function QuickApp:fanLow() self:setFanLevel(1) end
function QuickApp:fanMedium() self:setFanLevel(2) end
function QuickApp:fanHigh() self:setFanLevel(3) end

function QuickApp:forceRefresh() self:refreshDevice() end