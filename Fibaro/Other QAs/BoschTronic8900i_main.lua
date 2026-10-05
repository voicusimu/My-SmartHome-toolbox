-- Thermostat heat should handle actions: setThermostatMode, setHeatingThermostatSetpoint
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

function QuickApp:onInit()
    self:debug("onInit")

    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Off", "Heat"})

    -- setup default values
    self:updateProperty("thermostatMode", "Heat")
    self:setHeatingThermostatSetpoint(20)
end


---------------------------------------------------------------------------------------------------------------------

-----------------------------------------
-- Bosch HomeCom Easy - Fibaro HC3 QA
-- Verbose debug with debugEnabled=1
-- Always logs essential values + errors even with debugEnabled=0
-----------------------------------------

local TOKEN_URL = "https://singlekey-id.com/auth/connect/token"
local API_BASE  = "https://pointt-api.bosch-thermotechnology.com/pointt-api/api/v1"
local CLIENT_ID = "762162C0-FA2D-4540-AE66-6489F189FADC"

local UI = {
  sliderTemp = "sldTemp",

  btnHandWash = "btnHandWash",
  btnShower   = "btnShower",
  btnBath     = "btnBath",
  btnDishWash = "btnDishWash",
  btn60       = "btn60",

  lblMode       = "lblMode",
  lblSetpoint   = "lblSetpoint",
  lblInlet      = "lblInlet",
  lblOutlet     = "lblOutlet",
  lblFlow       = "lblFlow",
  lblWaterTotal = "lblWaterTotal",
  lblPowerKW    = "lblPowerKW",
  lblPowerPct   = "lblPowerPct",
  lblStarts     = "lblStarts",
  lblOpHours    = "lblOpHours",
  lblEnergy     = "lblEnergy",
}

---------------- Utils ------------------

local function urlEncode(str)
  if str == nil then return "" end
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w%-%_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function jsonDecodeSafe(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, res = pcall(function() return json.decode(s) end)
  if ok then return res end
  return nil
end

local function safeStr(x)
  if x == nil then return "-" end
  return tostring(x)
end

local function fmtNum(x, decimals)
  local n = tonumber(x)
  if n == nil then return "-" end
  decimals = decimals or 1
  return string.format("%." .. tostring(decimals) .. "f", n)
end

local function now()
  return os.time()
end

local function truthy(v)
  v = tostring(v or ""):lower()
  return (v == "1" or v == "true" or v == "yes" or v == "on")
end

local function mask(s, head, tail)
  s = tostring(s or "")
  head = head or 8
  tail = tail or 4
  if #s <= head + tail then return s end
  return string.sub(s, 1, head) .. "…" .. string.sub(s, #s - tail + 1)
end

local function headStr(s, n)
  s = tostring(s or "")
  n = n or 200
  return string.sub(s, 1, n)
end

----------------------------------------
-- INIT
----------------------------------------

function QuickApp:onInit()

    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Off", "Heat"})
    self:updateProperty("heatingThermostatSetpointCapabilitiesMin", 30)
    self:updateProperty("heatingThermostatSetpointCapabilitiesMax", 60)

    -- setup default values
    self:updateProperty("thermostatMode", "Heat")
    self:updateView(UI.sliderTemp, "text", "SETPOINT")

    self:debug("Bosch HomeCom QA started")

    self.http = net.HTTPClient({ timeout = 30000 })

    self.debugEnabled = truthy(self:getVariable("debugEnabled") or "0")

    -- auth
    self.token = self:getVariable("accessToken") or ""
    self.tokenExp = tonumber(self:getVariable("tokenExp") or "0")
    self.authInProgress = false
    self.authWaiters = {}
    self.tokenFailCount = 0

    -- slider debounce
    self.sliderTimer = nil
    self.sliderPending = nil

    -- presets
    self.presets = nil
    self.minSetpoint = 20
    self.maxSetpoint = 60

    -- cache to reduce “essential logs spam” if unchanged (still logs errors always)
    self.lastEss = {}

    -- children
    self:initChildren()

    -- polling
    self.pollMs = (tonumber(self:getVariable("pollSeconds") or "30") or 30) * 1000
    self.pollStarted = false

    self:dbg("debugEnabled=" .. tostring(self.debugEnabled))
    self:dbg("pollSeconds=" .. tostring(self.pollMs / 1000))
    self:dbg("tokenExp=" .. tostring(self.tokenExp))

    self:refreshStatus()
end

----------------------------------------
-- LOGGING
----------------------------------------

function QuickApp:dbg(msg)
  if self.debugEnabled then
    self:debug("[DBG] " .. tostring(msg))
  end
end

function QuickApp:dbgObj(label, obj)
  if not self.debugEnabled then return end
  local ok, s = pcall(function() return json.encode(obj) end)
  if ok then
    self:debug("[DBG] " .. tostring(label) .. "=" .. headStr(s, 600))
  else
    self:debug("[DBG] " .. tostring(label) .. "=<encode failed>")
  end
end

function QuickApp:dbgs(label, secret)
  if self.debugEnabled then
    self:debug("[DBG] " .. tostring(label) .. "=" .. mask(secret))
  end
end

-- Always-on essential value log (prints only when changed, unless force=true)
function QuickApp:ess(key, value, force)
  local v = tostring(value)
  if force or self.lastEss[key] ~= v then
    self.lastEss[key] = v
    self:debug(key .. ": " .. v)
  end
end

-- Always-on errors
function QuickApp:errCtx(ctx, status, raw)
  self:error(ctx .. " status=" .. tostring(status) .. " head=" .. headStr(raw, 220))
end

----------------------------------------
-- CHILD DEVICES
----------------------------------------

function QuickApp:initChildren()
  self.childrenMap = self.childrenMap or {}

  local function loadId(key)
    local v = tonumber(self:getVariable("child_" .. key) or "")
    if v then self.childrenMap[key] = v end
  end

  loadId("inlet")
  loadId("outlet")
  loadId("flow")
  loadId("waterTotal")
  loadId("powerW")
  loadId("powerPct")
  loadId("starts")
  loadId("opHours")
  loadId("energyKWh")

  local function ensure(key, name, type)
    local id = self.childrenMap[key]
    if id and fibaro.getType(id) then return id end
    local child = self:createChildDevice({ name = name, type = type })
    self.childrenMap[key] = child.id
    self:setVariable("child_" .. key, tostring(child.id))
    self:dbg("Created child " .. key .. " id=" .. tostring(child.id) .. " type=" .. tostring(type))
    return child.id
  end

  ensure("inlet",      "DHW Inlet",         "com.fibaro.temperatureSensor")
  ensure("outlet",     "DHW Outlet",        "com.fibaro.temperatureSensor")
  ensure("flow",       "DHW Flow",          "com.fibaro.multilevelSensor")
  ensure("waterTotal", "DHW Water Total",   "com.fibaro.multilevelSensor")

  -- Power: powerMeter (W)
  ensure("powerW",     "DHW Power",         "com.fibaro.powerMeter")

  ensure("powerPct",   "DHW Power (%)",     "com.fibaro.multilevelSensor")
  ensure("starts",     "DHW Starts",        "com.fibaro.multilevelSensor")
  ensure("opHours",    "DHW Op Hours",      "com.fibaro.multilevelSensor")

  -- Energy: energyMeter (kWh, integrated from real power)
  ensure("energyKWh",  "DHW Energy",        "com.fibaro.energyMeter")

  -- units (best-effort; some device types ignore)
  self:setChildUnit("flow", "l/min")
  self:setChildUnit("waterTotal", "l")
  self:setChildUnit("powerPct", "%")
  self:setChildUnit("opHours", "h")
end

function QuickApp:setChildValue(key, value)
  local id = self.childrenMap and self.childrenMap[key]
  if not id then return end
  fibaro.call(id, "updateProperty", "value", tonumber(value) or value)
end

function QuickApp:setChildUnit(key, unit)
  local id = self.childrenMap and self.childrenMap[key]
  if not id or not unit then return end
  pcall(function()
    fibaro.call(id, "updateProperty", "unit", tostring(unit))
  end)
end

----------------------------------------
-- UI HELPERS
----------------------------------------

function QuickApp:setLabel(id, text)
  pcall(function()
    self:updateView(id, "text", tostring(text))
  end)
end

function QuickApp:setSliderValue(val)
  pcall(function()
    self:updateView(UI.sliderTemp, "value", toString(val))
  end)
end

----------------------------------------
-- AUTH
----------------------------------------

function QuickApp:isTokenValid()
  return self.token ~= "" and self.tokenExp > (os.time() + 30)
end

function QuickApp:fetchToken(cb)
  local refresh = self:getVariable("refreshToken") or ""
  refresh = tostring(refresh):gsub("%s+", "")
  if refresh == "" then
    self:error("refreshToken lipsă! Pune-l în QuickApp Variables.")
    if cb then cb(false) end
    return
  end

  self:dbgs("refreshToken", refresh)

  local body =
    "grant_type=refresh_token" ..
    "&refresh_token=" .. urlEncode(refresh) ..
    "&client_id=" .. urlEncode(CLIENT_ID)

  self:dbg("TOKEN POST bodyLen=" .. tostring(#body))

  self.http:request(TOKEN_URL, {
    options = {
      method = "POST",
      headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Accept"] = "application/json, text/plain, */*",
        ["User-Agent"] = "Mozilla/5.0",
        ["Connection"] = "keep-alive",
      },
      data = body
    },
    success = function(resp)
      self:dbg("TOKEN status=" .. tostring(resp.status))
      if resp.headers then self:dbgObj("TOKEN headers", resp.headers) end

      local raw = tostring(resp.data or "")
      if self.debugEnabled and raw ~= "" then
        self:dbg("TOKEN rawHead=" .. headStr(raw, 280))
      end

      if tonumber(resp.status) ~= 200 then
        self:error("Token HTTP status=" .. tostring(resp.status))
        if raw ~= "" then self:error("Token RAW head: " .. headStr(raw, 220)) end

        if raw:find("invalid_grant") then
          self:error("Refresh token invalid/revoked. Re-login required.")
          self.tokenFailCount = 0
          if cb then cb(false) end
          return
        end

        self.tokenFailCount = (self.tokenFailCount or 0) + 1
        if self.tokenFailCount <= 2 then
          self:dbg("Token failed, retry #" .. tostring(self.tokenFailCount))
          setTimeout(function() self:fetchToken(cb) end, 1500 * self.tokenFailCount)
          return
        end
        self.tokenFailCount = 0
        if cb then cb(false) end
        return
      end

      local data = jsonDecodeSafe(raw)
      if not data or not data.access_token then
        self:error("Token decode/missing access_token")
        if cb then cb(false) end
        return
      end

      self.tokenFailCount = 0
      self.token = data.access_token
      local expires = tonumber(data.expires_in or "3600")
      self.tokenExp = os.time() + expires

      self:setVariable("accessToken", self.token)
      self:setVariable("tokenExp", tostring(self.tokenExp))

      self:dbgs("accessToken", self.token)
      self:dbg("tokenExp=" .. tostring(self.tokenExp))

      -- refresh token rotation
      if data.refresh_token and data.refresh_token ~= "" then
        local newRt = tostring(data.refresh_token):gsub("%s+", "")
        local oldRt = tostring(self:getVariable("refreshToken") or ""):gsub("%s+", "")
        if newRt ~= oldRt then
          self:setVariable("refreshToken", newRt)
          self:dbg("refreshToken rotated")
          self:dbgs("newRefreshToken", newRt)
        else
          self:dbg("refreshToken not rotated")
        end
      end

      if cb then cb(true) end
    end,
    error = function(err)
      self:error("Token HTTP error: " .. tostring(err))
      if cb then cb(false) end
    end
  })
end

function QuickApp:ensureAuth(cb)
  if self:isTokenValid() then
    cb(true)
    return
  end

  if self.authInProgress then
    table.insert(self.authWaiters, cb)
    return
  end

  self.authInProgress = true
  table.insert(self.authWaiters, cb)

  self:fetchToken(function(ok)
    self.authInProgress = false
    local waiters = self.authWaiters
    self.authWaiters = {}
    for _, fn in ipairs(waiters) do
      pcall(fn, ok)
    end
  end)
end

----------------------------------------
-- API
----------------------------------------

function QuickApp:apiRequest(method, path, body, cb)
  local t0 = now()
  self:ensureAuth(function(ok)
    if not ok then
      if cb then cb(false, nil, 0, nil) end
      return
    end

    if self.debugEnabled then
      self:dbg(method .. " " .. path)
      if body then self:dbg("REQ body=" .. headStr(json.encode(body), 240)) end
    end

    self.http:request(API_BASE .. path, {
      options = {
        method = method,
        headers = {
          ["Authorization"] = "Bearer " .. self.token,
          ["Content-Type"] = "application/json",
          ["Accept"] = "application/json",
        },
        data = body and json.encode(body) or nil
      },
      success = function(resp)
        local raw = tostring(resp.data or "")
        local data = jsonDecodeSafe(raw)

        if self.debugEnabled then
          self:dbg("RESP " .. tostring(resp.status) .. " dt=" .. tostring(now() - t0) .. "s")
          if resp.headers then self:dbgObj("RESP headers", resp.headers) end
          if raw ~= "" then self:dbg("RESP rawHead=" .. headStr(raw, 240)) end
        end

        if cb then cb(true, data, resp.status, raw) end
      end,
      error = function(err)
        self:error("HTTP error " .. method .. " " .. path .. " -> " .. tostring(err))
        if cb then cb(false, nil, err, nil) end
      end
    })
  end)
end

----------------------------------------
-- DISCOVERY
----------------------------------------

function QuickApp:getGateways()
  self:apiRequest("GET", "/gateways/", nil, function(ok, data, status, raw)
    if not ok or type(data) ~= "table" then
      self:errCtx("GET gateways failed", status, raw)
      return
    end

    if #data == 1 and data[1].deviceId then
      local id = tostring(data[1].deviceId)
      self:setVariable("gatewayId", id)
      self:dbg("Auto-set gatewayId=" .. id)
      self:refreshStatus()
    else
      self:error("Multiple gateways found; set gatewayId manually.")
      if self.debugEnabled then self:dbgObj("Gateways", data) end
    end
  end)
end

----------------------------------------
-- PATH HELPERS
----------------------------------------

local function dhwPath(gw, dhwId, leaf)
  return string.format("/gateways/%s/resource/dhwCircuits/%s/%s", gw, dhwId, leaf)
end

local function hsPath(gw, leaf)
  return string.format("/gateways/%s/resource/heatSources/hs1/%s", gw, leaf)
end

local function sysPath(gw, leaf)
  return string.format("/gateways/%s/resource/system/%s", gw, leaf)
end

----------------------------------------
-- READERS
----------------------------------------

function QuickApp:readHolidayMode(gw)
  local path = sysPath(gw, "holidayMode")
  self:apiRequest("GET", path, nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or type(d) ~= "table" then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("holidayMode failed", st, raw) end
      return
    end

    local v = tostring(d.value or "")
    local isHoliday = (v == "on" or v == "true" or v == "1")

    self:setLabel(UI.lblHoliday, "Holiday: " .. (isHoliday and "ON (Off)" or "OFF (Heat)"))
    self:ess("holiday", isHoliday and "ON" or "OFF")

    -- map to “Heat/Off” (pentru UI / viitor thermostat)
    local mode = isHoliday and "Off" or "Heat"
    self:updateProperty("thermostatMode", mode)
  end)
end

function QuickApp:readOperationSetpoints(gw, dhwId)
  local path = string.format("/gateways/%s/resource/dhwCircuits/%s/operationSetpoints", gw, dhwId)
  self:apiRequest("GET", path, nil, function(ok, data, st, raw)
    if not ok or tonumber(st) ~= 200 or not data or type(data.values) ~= "table" then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("operationSetpoints failed", st, raw) end
      return
    end

    local map = {}
    for _, kv in ipairs(data.values) do
      map[kv.key] = tonumber(kv.value)
    end
    self.presets = map

    self:debug(string.format(
      "Presets: handWash=%s°C, shower=%s°C, bath=%s°C, dishWash=%s°C",
      safeStr(map.handWash), safeStr(map.shower), safeStr(map.bath), safeStr(map.dishWash)
    ))
  end)
end

function QuickApp:readWaterTotalConsumption(gw)
  local path = string.format("/gateways/%s/resource/dhwCircuits/waterTotalConsumption", gw)
  self:apiRequest("GET", path, nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d or d.value == nil then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("waterTotalConsumption failed", st, raw) end
      return
    end

    self:setChildValue("waterTotal", d.value)
    self:setLabel(UI.lblWaterTotal, "Water total: " .. fmtNum(d.value, 0) .. " " .. safeStr(d.unitOfMeasure or "l"))

    -- essential log
    self:ess("waterTotal", fmtNum(d.value, 0) .. " " .. safeStr(d.unitOfMeasure or "l"))
  end)
end

function QuickApp:readHsMonitorValues(gw)
  local path = hsPath(gw, "monitorValues")
  self:apiRequest("GET", path, nil, function(ok, data, st, raw)
    if not ok or tonumber(st) ~= 200 or not data or type(data.references) ~= "table" then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("hs monitorValues failed", st, raw) end
      return
    end

    local m = {}
    for _, r in ipairs(data.references) do
      m[r.id] = r
    end

    local pkw    = m["/heatSources/hs1/actualPower"]
    local ppct   = m["/heatSources/hs1/powerPercentage"]
    local starts = m["/heatSources/hs1/numberOfStarts"]
    local hours  = m["/heatSources/hs1/operationHours"]

    if pkw and pkw.value ~= nil then
      local watts = (tonumber(pkw.value) or 0) * 1000.0
      self:setChildValue("powerW", watts)
      self:setLabel(UI.lblPowerKW, "Power: " .. fmtNum(pkw.value, 2) .. " " .. safeStr(pkw.unitOfMeasure or "kW"))

      self:ess("power", fmtNum(pkw.value, 2) .. " kW / " .. fmtNum(watts, 0) .. " W")
    end

    if ppct and ppct.value ~= nil then
      self:setChildValue("powerPct", ppct.value)
      self:setLabel(UI.lblPowerPct, "Power %: " .. fmtNum(ppct.value, 0) .. safeStr(ppct.unitOfMeasure or "%"))
      self:ess("powerPct", fmtNum(ppct.value, 0) .. "%")
    end

    if starts and starts.value ~= nil then
      self:setChildValue("starts", starts.value)
      self:setLabel(UI.lblStarts, "Starts: " .. fmtNum(starts.value, 0))
      self:ess("starts", fmtNum(starts.value, 0))
    end

    if hours and hours.value ~= nil then
      self:setChildValue("opHours", hours.value)
      self:setLabel(UI.lblOpHours, "Op hours: " .. fmtNum(hours.value, 1) .. " " .. safeStr(hours.unitOfMeasure or "hour"))
      self:ess("opHours", fmtNum(hours.value, 1) .. " h")
    end
  end)
end

function QuickApp:readElectricityTotalConsumption(gw)
  local path = string.format("/gateways/%s/resource/heatSources/electricityTotalConsumption", gw)

  self:apiRequest("GET", path, nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or type(d) ~= "table" or d.value == nil then
      if tonumber(st) and tonumber(st) >= 400 then
        self:errCtx("electricityTotalConsumption failed", st, raw)
      end
      return
    end

    -- value is likely kWh, but use unitOfMeasure if provided
    local val = tonumber(d.value)
    local unit = tostring(d.unitOfMeasure or "kWh")

    -- update child energy meter with REAL total
    if val ~= nil then
      self:setChildValue("energyKWh", val)
      self:setLabel(UI.lblEnergy, "Energy: " .. fmtNum(val, 3) .. " " .. unit)
      self:ess("energyTotal", fmtNum(val, 3) .. " " .. unit)
    end

    if self.debugEnabled then
      self:dbg("electricityTotalConsumption rawHead=" .. string.sub(tostring(raw or ""), 1, 180))
    end
  end)
end

----------------------------------------
-- MAIN REFRESH
----------------------------------------

function QuickApp:refreshStatus()
  local gw = self:getVariable("gatewayId") or ""
  if gw == "" then
    self:dbg("gatewayId missing -> discovering gateways")
    self:getGateways()
    return
  end

  local dhwId = self:getVariable("dhwId") or "dhw1"
  -- Holiday
    self:readHolidayMode(gw)

  -- Mode
  self:apiRequest("GET", dhwPath(gw, dhwId, "operationMode"), nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("operationMode failed", st, raw) end
      return
    end
    self:setLabel(UI.lblMode, "Mode: " .. safeStr(d.value))
    self:ess("mode", safeStr(d.value))
  end)

  -- Manual setpoint -> update base QA value
  self:apiRequest("GET", dhwPath(gw, dhwId, "manualsetpoint"), nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("manualsetpoint failed", st, raw) end
      return
    end

    local v = tonumber(d.value)
    self.minSetpoint = tonumber(d.minValue or self.minSetpoint) or self.minSetpoint
    self.maxSetpoint = tonumber(d.maxValue or self.maxSetpoint) or self.maxSetpoint

    pcall(function()
      self:updateView(UI.sliderTemp, "min", safeStr(d.minValue))
      self:updateView(UI.sliderTemp, "max", safeStr(d.maxValue))
      self:updateView(UI.sliderTemp, "value", safeStr(d.value))
    end)

    self:setLabel(UI.lblSetpoint, string.format("Manual setpoint: %s%s (min=%s max=%s)",
      safeStr(d.value), safeStr("°C"), safeStr(d.minValue), safeStr(d.maxValue)
    ))

    if v ~= nil then
      self:updateProperty("heatingThermostatSetpoint", { value= v, unit= unit or "C" })
      self:ess("setpoint", fmtNum(v, 0) .. " °C")
    end
  end)

  -- Inlet
  self:apiRequest("GET", dhwPath(gw, dhwId, "inletTemperature"), nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("inletTemperature failed", st, raw) end
      return
    end
    self:setChildValue("inlet", d.value)
    self:setLabel(UI.lblInlet, "Inlet: " .. fmtNum(d.value, 1) .. " " .. safeStr("°C"))
    self:ess("inlet", fmtNum(d.value, 1) .. " °C")
  end)

  -- Outlet
  self:apiRequest("GET", dhwPath(gw, dhwId, "outletTemperature"), nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("outletTemperature failed", st, raw) end
      return
    end
    self:setChildValue("outlet", d.value)
    self:setLabel(UI.lblOutlet, "Outlet: " .. fmtNum(d.value, 1) .. " " .. safeStr("°C"))
    self:ess("outlet", fmtNum(d.value, 1) .. " °C")
  end)

  -- Flow (leaf direct)
  self:apiRequest("GET", dhwPath(gw, dhwId, "sensor/waterFlow"), nil, function(ok, d, st, raw)
    if not ok or tonumber(st) ~= 200 or not d or d.value == nil then
      if tonumber(st) and tonumber(st) >= 400 then self:errCtx("waterFlow failed", st, raw) end
      return
    end
    self:setChildValue("flow", d.value)
    self:setLabel(UI.lblFlow, "Flow: " .. fmtNum(d.value, 2) .. " " .. safeStr(d.unitOfMeasure or "l/min"))
    self:ess("flow", fmtNum(d.value, 2) .. " l/min")
  end)

  -- Lifetime water
  self:readWaterTotalConsumption(gw)

  -- Heat source bulk (power/pct/starts/hours) + energy integration
  self:readHsMonitorValues(gw)

-- Total consumption
  self:readElectricityTotalConsumption(gw)

  -- Presets once
  if not self.presets then
    self:readOperationSetpoints(gw, dhwId)
  end

  -- Start polling once
  if self.pollMs > 0 and not self.pollStarted then
    self.pollStarted = true
    if not self.pollTimerStarted then
      self.pollTimerStarted = true
      self:scheduleNextPoll()
    end
  end
end

function QuickApp:getCurrentPollMs()
  local baseMs = self.pollMs or 30000
  if self.pollOverrideUntil and os.time() < self.pollOverrideUntil then
    return (self.pollOverrideSec or 10) * 1000
  end
  return baseMs
end

function QuickApp:scheduleNextPoll()
  local ms = self:getCurrentPollMs()
  setTimeout(function()
    self:refreshStatus()
    self:scheduleNextPoll()
  end, ms)
end

----------------------------------------
-- DEFAULT THERMOSTAT METHODS
----------------------------------------

-- handle action for mode change 
function QuickApp:setThermostatMode(mode)
    self:updateProperty("thermostatMode", mode)
    self:setHoliday(mode == "Off")
end

-- handle action for setting set point for heating
function QuickApp:setHeatingThermostatSetpoint(value, unit)
    self:updateProperty("heatingThermostatSetpoint", { value= value, unit= unit or "C" })
    self:setManualSetpoint(value)
end

----------------------------------------
-- CONTROL
----------------------------------------

function QuickApp:setHoliday(on)
  local gw = self:getVariable("gatewayId") or ""
  if gw == "" then return end

  local path = sysPath(gw, "holidayMode")
  local val = on and "on" or "off"

  self:apiRequest("PUT", path, { value = val }, function(ok, _, st, raw)
    self:debug("SET holidayMode=" .. val .. " status=" .. tostring(st))
    if tonumber(st) and tonumber(st) >= 400 then
      self:errCtx("SET holidayMode failed", st, raw)
      return
    end
    self:refreshStatus()
  end)
end

function QuickApp:setMode(mode)
  local gw = self:getVariable("gatewayId") or ""
  local dhwId = self:getVariable("dhwId") or "dhw1"
  if gw == "" then return end

  local path = dhwPath(gw, dhwId, "operationMode")
  self:apiRequest("PUT", path, { value = tostring(mode) }, function(ok, _, st, raw)
    self:debug("SET mode=" .. tostring(mode) .. " status=" .. tostring(st))
    if tonumber(st) and tonumber(st) >= 400 then
      self:errCtx("SET mode failed", st, raw)
    end
    self:refreshStatus()
  end)
end

function QuickApp:setManualSetpoint(tempC)
  self:debug("Set manual setpoint to: " .. tempC .."°C")
  local gw = self:getVariable("gatewayId") or ""
  local dhwId = self:getVariable("dhwId") or "dhw1"
  if gw == "" then return end

  local t = tonumber(tempC)
  if not t then return end
  if t < self.minSetpoint then t = self.minSetpoint end
  if t > self.maxSetpoint then t = self.maxSetpoint end

  self:setModeAndThen("manual", function()
    local path = dhwPath(gw, dhwId, "manualsetpoint")
    self:apiRequest("PUT", path, { value = t }, function(ok, _, st, raw)
      self:debug("SET manualsetpoint=" .. tostring(t) .. " status=" .. tostring(st))
      if tonumber(st) and tonumber(st) >= 400 then
        self:errCtx("SET manualsetpoint failed", st, raw)
      end
      self:refreshStatus()
    end)
  end)
end

function QuickApp:setModeAndThen(mode, nextFn)
  local gw = self:getVariable("gatewayId") or ""
  local dhwId = self:getVariable("dhwId") or "dhw1"
  if gw == "" then return end

  local path = dhwPath(gw, dhwId, "operationMode")
  self:apiRequest("PUT", path, { value = tostring(mode) }, function(ok, _, st, raw)
    self:debug("SET mode=" .. tostring(mode) .. " status=" .. tostring(st))
    if tonumber(st) and tonumber(st) >= 400 then
      self:errCtx("SET mode failed", st, raw)
      return
    end
    if nextFn then nextFn() end
  end)
end

function QuickApp:applyPreset(mode)
  self:setMode(mode)
  if self.presets and self.presets[mode] then
    self:setSliderValue(self.presets[mode])
  end
end

function QuickApp:boostPolling(newSeconds, durationSeconds)
  newSeconds = tonumber(newSeconds) or 10
  durationSeconds = tonumber(durationSeconds) or 120

  local oldMs = self.pollMs
  local oldSec = math.floor((oldMs or 30000) / 1000)

  self:debug("Boost polling: " .. tostring(oldSec) .. "s -> " .. tostring(newSeconds) .. "s for " .. tostring(durationSeconds) .. "s")

  -- IMPORTANT: setInterval can't be changed; we implement our own timer loop
  self.pollOverrideUntil = os.time() + durationSeconds
  self.pollOverrideSec = newSeconds

  -- kick immediate refresh
  self:refreshStatus()
end

----------------------------------------
-- UI HANDLERS
----------------------------------------

function QuickApp:btnBoost_onReleased()
  self:boostPolling(10, 120)
end

function QuickApp:sldTemp_onChanged(ev)
  -- ev = { elementName="sldTemp", eventType="onChanged", values={66}, ... }
  local v = nil
  if type(ev) == "table" and type(ev.values) == "table" then
    v = tonumber(ev.values[1])
  else
    v = tonumber(ev)
  end
  if not v then
    self:debug("sldTemp_onChanged: no value in event")
    return
  end

  self:dbg("slider changed -> " .. tostring(v))
  self.sliderPending = v

  self.sliderSeq = (self.sliderSeq or 0) + 1
  local mySeq = self.sliderSeq

  setTimeout(function()
    if self.sliderSeq ~= mySeq then return end
    if self.sliderPending == nil then return end
    self:debug("Slider commit -> setManualSetpoint(" .. tostring(self.sliderPending) .. ")")
    self:setManualSetpoint(self.sliderPending)
  end, 700)
end

function QuickApp:btnHandWash_onReleased() self:applyPreset("handWash") end
function QuickApp:btnShower_onReleased()   self:applyPreset("shower")   end
function QuickApp:btnBath_onReleased()     self:applyPreset("bath")     end
function QuickApp:btnDishWash_onReleased() self:applyPreset("dishWash") end
function QuickApp:btn60_onReleased()       self:setManualSetpoint(60)   end
