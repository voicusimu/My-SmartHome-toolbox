--[[
SolarAssistant Bridge QA for Fibaro HC3

Recommended parent QA type:
- com.fibaro.multilevelSensor

Child device types:
- Power children:  com.fibaro.powerMeter
- Energy children: com.fibaro.energyMeter
- SOC child:       com.fibaro.multilevelSensor

Quick App variables:
- BridgeUrl        default: http://192.168.1.204:8787/status
- PollSeconds      default: 3
- PowerThresholdW  default: 30

Auto-created internal variables:
- child_<key>_id
  These store child device IDs so children are not recreated on QA restart.

Optional UI labels this code updates if they already exist:
lblHeader, lblStatus, lblFlow, lblPV, lblLoad, lblBattery, lblGrid, lblEnergy, lblUpdated
]]--

class 'MetricChild'(QuickAppChild)

function MetricChild:__init(device)
  QuickAppChild.__init(self, device)
end

function MetricChild:updateValue(value)
  if value == nil then return end
  self:updateProperty("value", value)
end

function QuickApp:onInit()
  self.CHILDREN = {
    -- Power meters, W
    { key = "pv_production",        name = "PV Production",             unit = "W",   type = "com.fibaro.powerMeter" },
    { key = "load_essential",       name = "Essential Load",            unit = "W",   type = "com.fibaro.powerMeter" },
    { key = "load_nonessential",    name = "Non-Essential Load",        unit = "W",   type = "com.fibaro.powerMeter" },
    { key = "load_total",           name = "Total Load",                unit = "W",   type = "com.fibaro.powerMeter" },
    { key = "battery_power",        name = "Battery Power",             unit = "W",   type = "com.fibaro.powerMeter" },
    { key = "grid_power",           name = "Grid Power",                unit = "W",   type = "com.fibaro.powerMeter" },

    -- Generic sensor, %
    { key = "battery_soc",          name = "Battery SOC",               unit = "%",   type = "com.fibaro.multilevelSensor" },

    -- PV energy meters, kWh
    { key = "energy_day",           name = "Daily Energy Produced",     unit = "kWh", type = "com.fibaro.energyMeter" },
    { key = "energy_month",         name = "Month Energy Produced",     unit = "kWh", type = "com.fibaro.energyMeter" },
    { key = "energy_year",          name = "Year Energy Produced",      unit = "kWh", type = "com.fibaro.energyMeter" },
    { key = "energy_total",         name = "Total Energy Produced",     unit = "kWh", type = "com.fibaro.energyMeter" },

    -- Grid import/consumption energy meters, kWh
    { key = "grid_energy_day",       name = "Day Grid Energy",           unit = "kWh", type = "com.fibaro.energyMeter" },
    { key = "grid_energy_month",     name = "Monthly Grid Energy",       unit = "kWh", type = "com.fibaro.energyMeter" },
    { key = "grid_energy_total",     name = "Total Grid Energy",         unit = "kWh", type = "com.fibaro.energyMeter" },
  }

  self.nameToKey = {}
  self.defByKey = {}

  for _, def in ipairs(self.CHILDREN) do
    self.nameToKey[def.name] = def.key
    self.defByKey[def.key] = def
  end

  self.bridgeUrl = self:getVar("BridgeUrl", "http://192.168.1.204:8787/status")
  self.pollSeconds = tonumber(self:getVar("PollSeconds", "3")) or 3
  self.powerThresholdW = tonumber(self:getVar("PowerThresholdW", "30")) or 30

  self.http = net.HTTPClient({ timeout = 7000 })
  self.childByKey = {}

  self:ensureChildren()

  self:updateProperty("unit", "W")
  self:updateProperty("value", 0)

  self:debug("SolarAssistant Bridge QA started")
  self:debug("Bridge URL: " .. self.bridgeUrl)

  self:updateDashboard({
    status = "Starting...",
    flowText = "Waiting for data",
    pv = 0,
    loadTotal = 0,
    essential = 0,
    nonessential = 0,
    batteryPower = 0,
    batterySoc = 0,
    gridPower = 0,
    energyDay = 0,
    energyMonth = 0,
    energyYear = 0,
    energyTotal = 0,
    gridEnergyDay = 0,
    gridEnergyMonth = 0,
    gridEnergyTotal = 0,
    batteryDirection = "idle",
    gridDirection = "idle",
    updatedIso = "-"
  })

  self:scheduleNextPoll(1000)
end

function QuickApp:getVar(name, defaultValue)
  local ok, value = pcall(function() return self:getVariable(name) end)
  if ok and value ~= nil and value ~= "" then return value end
  return defaultValue
end

function QuickApp:setVar(name, value)
  pcall(function() self:setVariable(name, tostring(value)) end)
end

function QuickApp:getNumberVar(name, defaultValue)
  local value = tonumber(self:getVar(name, ""))
  if value == nil then return defaultValue end
  return value
end

function QuickApp:round(value, decimals)
  if value == nil then return nil end
  local p = 10 ^ (decimals or 0)
  return math.floor(value * p + 0.5) / p
end

function QuickApp:safeLabel(id, text)
  pcall(function() self:updateView(id, "text", tostring(text)) end)
end

function QuickApp:childVarName(key)
  return "child_" .. key .. "_id"
end

function QuickApp:getDeviceById(id)
  if id == nil then return nil end
  local numericId = tonumber(id)
  if numericId == nil then return nil end

  local ok, dev = pcall(function()
    return api.get("/devices/" .. tostring(numericId))
  end)

  if ok and dev and dev.id then
    return dev
  end

  return nil
end

function QuickApp:findRuntimeChildById(id)
  local numericId = tonumber(id)
  if numericId == nil then return nil end

  for _, child in pairs(self.childDevices or {}) do
    if tonumber(child.id) == numericId then
      return child
    end
  end

  return nil
end

function QuickApp:findExistingChildByName(name)
  for _, child in pairs(self.childDevices or {}) do
    if child.name == name then
      return child
    end
  end

  return nil
end

function QuickApp:bindChildFromStoredId(def)
  local varName = self:childVarName(def.key)
  local storedId = tonumber(self:getVar(varName, ""))

  if storedId == nil then
    return nil
  end

  local dev = self:getDeviceById(storedId)

  if dev == nil then
    self:warning("Stored child ID for " .. def.key .. " does not exist anymore: " .. tostring(storedId))
    return nil
  end

  local runtimeChild = self:findRuntimeChildById(storedId)

  if runtimeChild ~= nil then
    self.childByKey[def.key] = runtimeChild
    return runtimeChild
  end

  local proxy = {
    id = storedId,
    name = dev.name,
    updateValue = function(_, value)
      if value == nil then return end
      pcall(function()
        api.put("/devices/" .. tostring(storedId), {
          properties = {
            value = value
          }
        })
      end)
    end
  }

  self.childByKey[def.key] = proxy
  self:debug("Using stored child by API only: " .. def.name .. " id=" .. tostring(storedId))
  return proxy
end

function QuickApp:rebuildChildIndex()
  self.childByKey = {}

  -- 1. PRIORITATE ABSOLUTĂ: ID-urile salvate în variabile.
  for _, def in ipairs(self.CHILDREN) do
    self:bindChildFromStoredId(def)
  end

  -- 2. Fallback pentru instalări vechi fără variabile salvate.
  for _, child in pairs(self.childDevices or {}) do
    local key = self.nameToKey[child.name]

    if key and self.childByKey[key] == nil then
      self.childByKey[key] = child
      self:setVar(self:childVarName(key), child.id)
      self:debug("Bound existing child by name: " .. child.name .. " id=" .. tostring(child.id))
    end
  end
end

function QuickApp:ensureChildren()
  self:rebuildChildIndex()

  for _, def in ipairs(self.CHILDREN) do
    local child = self.childByKey[def.key]

    if child == nil then
      child = self:bindChildFromStoredId(def)
    end

    if child == nil then
      child = self:findExistingChildByName(def.name)

      if child ~= nil then
        self.childByKey[def.key] = child
        self:setVar(self:childVarName(def.key), child.id)
        self:debug("Found existing child by name: " .. def.name .. " id=" .. tostring(child.id))
      end
    end

    if child == nil then
      self:warning("Creating missing child: " .. def.name .. " type=" .. def.type)

      local created = self:createChildDevice({
        name = def.name,
        type = def.type,
        initialProperties = {
          value = 0,
          unit = def.unit
        },
        initialInterfaces = {}
      }, MetricChild)

      if created ~= nil and created.id ~= nil then
        self.childByKey[def.key] = created
        self:setVar(self:childVarName(def.key), created.id)
        self:debug("Created child: " .. def.name .. " id=" .. tostring(created.id))
      else
        self:error("Failed to create child: " .. def.name)
      end
    end
  end
end

function QuickApp:updateChild(key, value)
  local child = self.childByKey[key]

  if child == nil then
    local def = self.defByKey and self.defByKey[key]
    if def ~= nil then
      child = self:bindChildFromStoredId(def)
    end
  end

  if child and value ~= nil then
    if child.updateValue ~= nil then
      child:updateValue(value)
    else
      child:updateProperty("value", value)
    end
  end
end

function QuickApp:scheduleNextPoll(delayMs)
  setTimeout(function() self:poll() end, delayMs)
end

function QuickApp:poll()
  self.http:request(self.bridgeUrl, {
    options = {
      method = 'GET',
      headers = {
        ['Accept'] = 'application/json'
      }
    },
    success = function(resp)
      self:handleResponse(resp)
      self:scheduleNextPoll(self.pollSeconds * 1000)
    end,
    error = function(err)
      self:error("HTTP error: " .. tostring(err))

      self:updateDashboard({
        status = "Bridge HTTP error",
        flowText = tostring(err),
        pv = 0,
        loadTotal = 0,
        essential = 0,
        nonessential = 0,
        batteryPower = 0,
        batterySoc = 0,
        gridPower = 0,
        energyDay = self:getNumberVar("energy_day_last", 0),
        energyMonth = self:getNumberVar("energy_month_last", 0),
        energyYear = self:getNumberVar("energy_year_last", 0),
        energyTotal = self:getNumberVar("energy_total_last", 0),
        gridEnergyDay = self:getNumberVar("grid_energy_day_last", 0),
        gridEnergyMonth = self:getNumberVar("grid_energy_month_last", 0),
        gridEnergyTotal = self:getNumberVar("grid_energy_total_last", 0),
        batteryDirection = "idle",
        gridDirection = "idle",
        updatedIso = "-"
      })

      self:scheduleNextPoll(math.max(5, self.pollSeconds) * 1000)
    end
  })
end

function QuickApp:parseJson(data)
  local ok, parsed = pcall(function() return json.decode(data) end)
  if ok then return parsed end
  return nil
end

function QuickApp:num(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

function QuickApp:getTopicValue(topics, topic)
  if topics and topics[topic] and topics[topic].value ~= nil then
    return topics[topic].value
  end

  return nil
end

function QuickApp:max0(v)
  if v == nil then return nil end
  if v < 0 then return 0 end
  return v
end

function QuickApp:computePvEnergyCounters(totalEnergy)
  totalEnergy = self:num(totalEnergy)
  if totalEnergy == nil then return nil, nil, nil end

  local todayKey = os.date("%Y-%m-%d")
  local monthKey = os.date("%Y-%m")
  local yearKey = os.date("%Y")

  local dayStoredKey = self:getVar("energy_day_key", "")
  local monthStoredKey = self:getVar("energy_month_key", "")
  local yearStoredKey = self:getVar("energy_year_key", "")

  local dayBaseline = self:getNumberVar("energy_day_baseline", nil)
  local monthBaseline = self:getNumberVar("energy_month_baseline", nil)
  local yearBaseline = self:getNumberVar("energy_year_baseline", nil)

  if dayStoredKey ~= todayKey or dayBaseline == nil then
    dayBaseline = totalEnergy
    self:setVar("energy_day_key", todayKey)
    self:setVar("energy_day_baseline", dayBaseline)
  end

  if monthStoredKey ~= monthKey or monthBaseline == nil then
    monthBaseline = totalEnergy
    self:setVar("energy_month_key", monthKey)
    self:setVar("energy_month_baseline", monthBaseline)
  end

  if yearStoredKey ~= yearKey or yearBaseline == nil then
    yearBaseline = totalEnergy
    self:setVar("energy_year_key", yearKey)
    self:setVar("energy_year_baseline", yearBaseline)
  end

  local dayEnergy = self:round(self:max0(totalEnergy - dayBaseline), 2)
  local monthEnergy = self:round(self:max0(totalEnergy - monthBaseline), 2)
  local yearEnergy = self:round(self:max0(totalEnergy - yearBaseline), 2)

  self:setVar("energy_day_last", dayEnergy)
  self:setVar("energy_month_last", monthEnergy)
  self:setVar("energy_year_last", yearEnergy)
  self:setVar("energy_total_last", self:round(totalEnergy, 2))

  return dayEnergy, monthEnergy, yearEnergy
end

function QuickApp:computeGridEnergyCounters(totalGridEnergy)
  totalGridEnergy = self:num(totalGridEnergy)
  if totalGridEnergy == nil then return nil, nil end

  local todayKey = os.date("%Y-%m-%d")
  local monthKey = os.date("%Y-%m")

  local dayStoredKey = self:getVar("grid_energy_day_key", "")
  local monthStoredKey = self:getVar("grid_energy_month_key", "")

  local dayBaseline = self:getNumberVar("grid_energy_day_baseline", nil)
  local monthBaseline = self:getNumberVar("grid_energy_month_baseline", nil)

  if dayStoredKey ~= todayKey or dayBaseline == nil then
    dayBaseline = totalGridEnergy
    self:setVar("grid_energy_day_key", todayKey)
    self:setVar("grid_energy_day_baseline", dayBaseline)
  end

  if monthStoredKey ~= monthKey or monthBaseline == nil then
    monthBaseline = totalGridEnergy
    self:setVar("grid_energy_month_key", monthKey)
    self:setVar("grid_energy_month_baseline", monthBaseline)
  end

  local dayGridEnergy = self:round(self:max0(totalGridEnergy - dayBaseline), 2)
  local monthGridEnergy = self:round(self:max0(totalGridEnergy - monthBaseline), 2)

  self:setVar("grid_energy_day_last", dayGridEnergy)
  self:setVar("grid_energy_month_last", monthGridEnergy)
  self:setVar("grid_energy_total_last", self:round(totalGridEnergy, 2))

  return dayGridEnergy, monthGridEnergy
end

function QuickApp:getFlowLabels(pv, loadTotal, batteryPower, gridPower)
  local th = self.powerThresholdW or 30

  local gridDirection = "idle"

  if gridPower ~= nil then
    if gridPower > th then
      gridDirection = "importing"
    elseif gridPower < -th then
      gridDirection = "exporting"
    end
  end

  -- For SolarAssistant/Deye in your bridge:
  -- negative battery power = charging, positive = discharging.
  local batteryDirection = "idle"

  if batteryPower ~= nil then
    if batteryPower < -th then
      batteryDirection = "charging"
    elseif batteryPower > th then
      batteryDirection = "discharging"
    end
  end

  local sources, sinks = {}, {}

  if pv ~= nil and pv > th then table.insert(sources, "PV") end
  if batteryDirection == "discharging" then table.insert(sources, "Battery") end
  if gridDirection == "importing" then table.insert(sources, "Grid") end

  if loadTotal ~= nil and loadTotal > th then table.insert(sinks, "Load") end
  if batteryDirection == "charging" then table.insert(sinks, "Battery") end
  if gridDirection == "exporting" then table.insert(sinks, "Grid") end

  local flowText = "Idle"

  if #sources > 0 or #sinks > 0 then
    local left = (#sources > 0) and table.concat(sources, " + ") or "Unknown"
    local right = (#sinks > 0) and table.concat(sinks, " + ") or "Unknown"
    flowText = left .. " → " .. right
  end

  return gridDirection, batteryDirection, flowText
end

function QuickApp:updateDashboard(m)
  self:safeLabel("lblHeader", "SolarAssistant Energy Dashboard")
  self:safeLabel("lblStatus", "Status: " .. (m.status or "Unknown"))
  self:safeLabel("lblFlow", "Flow: " .. (m.flowText or "Unknown"))
  self:safeLabel("lblPV", string.format("PV: %s W", tostring(m.pv or 0)))

  self:safeLabel(
    "lblLoad",
    string.format(
      "Load: total %s W | essential %s W | non-essential %s W",
      tostring(m.loadTotal or 0),
      tostring(m.essential or 0),
      tostring(m.nonessential or 0)
    )
  )

  self:safeLabel(
    "lblBattery",
    string.format(
      "Battery: %s W | SOC %s%% | %s",
      tostring(m.batteryPower or 0),
      tostring(m.batterySoc or 0),
      tostring(m.batteryDirection or "idle")
    )
  )

  self:safeLabel(
    "lblGrid",
    string.format(
      "Grid: %s W | %s | day %s kWh | month %s kWh | total %s kWh",
      tostring(m.gridPower or 0),
      tostring(m.gridDirection or "idle"),
      tostring(m.gridEnergyDay or 0),
      tostring(m.gridEnergyMonth or 0),
      tostring(m.gridEnergyTotal or 0)
    )
  )

  self:safeLabel(
    "lblEnergy",
    string.format(
      "PV energy: day %s kWh | month %s kWh | year %s kWh | total %s kWh",
      tostring(m.energyDay or 0),
      tostring(m.energyMonth or 0),
      tostring(m.energyYear or 0),
      tostring(m.energyTotal or 0)
    )
  )

  self:safeLabel("lblUpdated", "Updated: " .. (m.updatedIso or "-"))
end

function QuickApp:handleResponse(resp)
  if tonumber(resp.status) ~= 200 then
    self:error("Bridge returned HTTP " .. tostring(resp.status))
    return
  end

  local data = self:parseJson(resp.data)

  if not data then
    self:error("Could not parse JSON from bridge")
    return
  end

  local normalized = data.normalized or {}
  local raw = data.raw or {}
  local topics = raw.topics or {}

  local pv = self:num(normalized.pv_power)
  local totalLoad = self:num(normalized.load_power)
  local batteryPower = self:num(normalized.battery_power)
  local gridPower = self:num(normalized.grid_power)
  local batterySoc = self:num(normalized.battery_soc)

  local essential = self:num(self:getTopicValue(topics, "solar_assistant/inverter_1/load_power_essential/state"))
  local nonessential = self:num(self:getTopicValue(topics, "solar_assistant/inverter_1/load_power_non-essential/state"))

  if totalLoad == nil and essential ~= nil and nonessential ~= nil then
    totalLoad = essential + nonessential
  end

  -- PV energy: cumulative produced energy from SolarAssistant.
  local totalEnergy = self:num(self:getTopicValue(topics, "solar_assistant/total/pv_energy/state"))
  local dayEnergy, monthEnergy, yearEnergy = self:computePvEnergyCounters(totalEnergy)

  -- Grid consumption/import energy.
  -- SolarAssistant topic:
  --   grid_energy_in  = import / consumption from grid
  --   grid_energy_out = export to grid
  local totalGridEnergy = self:num(self:getTopicValue(topics, "solar_assistant/total/grid_energy_in/state"))
  local dayGridEnergy, monthGridEnergy = self:computeGridEnergyCounters(totalGridEnergy)

  local gridDirection, batteryDirection, flowText = self:getFlowLabels(pv, totalLoad, batteryPower, gridPower)

  local statusParts = {}

  if normalized.ok then
    table.insert(statusParts, tostring(normalized.status or "OK"))
  else
    table.insert(statusParts, "Bridge not ready")
  end

  if gridDirection ~= "idle" then table.insert(statusParts, "Grid " .. gridDirection) end
  if batteryDirection ~= "idle" then table.insert(statusParts, "Battery " .. batteryDirection) end

  local prettyStatus = table.concat(statusParts, " | ")

  self:updateChild("pv_production",        self:round(pv or 0, 0))
  self:updateChild("load_essential",       self:round(essential or 0, 0))
  self:updateChild("load_nonessential",    self:round(nonessential or 0, 0))
  self:updateChild("load_total",           self:round(totalLoad or 0, 0))
  self:updateChild("battery_power",        self:round(batteryPower or 0, 0))
  self:updateChild("grid_power",           self:round(gridPower or 0, 0))
  self:updateChild("battery_soc",          self:round(batterySoc or 0, 0))

  self:updateChild("energy_day",           self:round(dayEnergy or 0, 2))
  self:updateChild("energy_month",         self:round(monthEnergy or 0, 2))
  self:updateChild("energy_year",          self:round(yearEnergy or 0, 2))
  self:updateChild("energy_total",         self:round(totalEnergy or 0, 2))

  self:updateChild("grid_energy_day",      self:round(dayGridEnergy or 0, 2))
  self:updateChild("grid_energy_month",    self:round(monthGridEnergy or 0, 2))
  self:updateChild("grid_energy_total",    self:round(totalGridEnergy or 0, 2))

  self:updateProperty("value", self:round(totalLoad or pv or 0, 0))
  pcall(function() self:updateProperty("log", prettyStatus) end)

  self:updateDashboard({
    status = prettyStatus,
    flowText = flowText,
    pv = self:round(pv or 0, 0),
    loadTotal = self:round(totalLoad or 0, 0),
    essential = self:round(essential or 0, 0),
    nonessential = self:round(nonessential or 0, 0),
    batteryPower = self:round(batteryPower or 0, 0),
    batterySoc = self:round(batterySoc or 0, 0),
    batteryDirection = batteryDirection,
    gridPower = self:round(gridPower or 0, 0),
    gridDirection = gridDirection,
    energyDay = self:round(dayEnergy or 0, 2),
    energyMonth = self:round(monthEnergy or 0, 2),
    energyYear = self:round(yearEnergy or 0, 2),
    energyTotal = self:round(totalEnergy or 0, 2),
    gridEnergyDay = self:round(dayGridEnergy or 0, 2),
    gridEnergyMonth = self:round(monthGridEnergy or 0, 2),
    gridEnergyTotal = self:round(totalGridEnergy or 0, 2),
    updatedIso = normalized.last_message_iso or raw.last_message_iso or "-"
  })
end