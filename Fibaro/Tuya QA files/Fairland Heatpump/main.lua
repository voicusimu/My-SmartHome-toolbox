-- Thermostat auto should handle actions: setThermostatMode, setCoolingThermostatSetpoint, setHeatingThermostatSetpoint
-- Proeprties that should be updated:
-- * supportedThermostatModes - array of modes supported by the thermostat eg. {"Auto", "Off", "Heat", "Cool"}
-- * thermostatMode - current mode of the thermostat
-- * coolingThermostatSetpoint - set point for cooling, supported units: "C" - Celsius, "F" - Fahrenheit
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

local currentThermostatMode = "Auto"
local currentTemp = 0
local currentPercentage = 0
local pendingRefresh = false
local hasFault1 = false
local hasFault2 = false

local fault1Map = {
    [4]  = { code = "E3", desc = "No water protection" },
    [8]  = { code = "E5", desc = "Power supply excesses operation range" },
    [16] = { code = "E6", desc = "Excessive temp difference between inlet and outlet water (insufficient water flow protection)" },
    [32] = { code = "Eb", desc = "Ambient temperature too high or too low protection" },
    [64] = { code = "Ed", desc = "Anti-freezing reminder" },
}

local fault2Map = {
    [1]        = { code = "E1", desc = "High pressure protection" },
    [2]        = { code = "E2", desc = "Low pressure protection" },
    [4]        = { code = "E4", desc = "3 phase sequence protection (three phase only)" },
    [8]        = { code = "E7", desc = "Water outlet temp too high or too low protection" },
    [16]       = { code = "E8", desc = "High exhaust temp protection" },
    [32]       = { code = "EA", desc = "Evaporator overheat protection (cooling mode only)" },
    [64]       = { code = "P0", desc = "Controller communication failure" },
    [128]      = { code = "P1", desc = "Water inlet temp sensor failure" },
    [256]      = { code = "P2", desc = "Water outlet temp sensor failure" },
    [512]      = { code = "P3", desc = "Gas exhaust temp sensor failure" },
    [1024]     = { code = "P4", desc = "Evaporator coil pipe temp sensor failure" },
    [2048]     = { code = "P5", desc = "Gas return temp sensor failure" },
    [4096]     = { code = "P6", desc = "Cooling coil pipe temp sensor failure" },
    [8192]     = { code = "P7", desc = "Ambient temp sensor failure" },
    [16384]    = { code = "P8", desc = "Cooling plate sensor failure" },
    [32768]    = { code = "P9", desc = "Current sensor failure" },
    [65536]    = { code = "PA", desc = "Restart memory failure" },
    [131072]   = { code = "F1", desc = "Compressor drive module failure" },
    [262144]   = { code = "F2", desc = "PFC module failure" },
    [524288]   = { code = "F3", desc = "Compressor start failure" },
    [1048576]  = { code = "F4", desc = "Compressor running failure" },
    [2097152]  = { code = "F5", desc = "Inverter board over current protection" },
    [4194304]  = { code = "F6", desc = "Inverter board overheat protection" },
    [8388608]  = { code = "F7", desc = "Current protection" },
    [16777216] = { code = "F8", desc = "Cooling plate overheat protection" },
    [33554432] = { code = "F9", desc = "Fan motor failure" },
    [67108864] = { code = "Fb", desc = "Power filter plate No-power protection" },
    [134217728]= { code = "FA", desc = "PFC module over current protection" }
}

function QuickApp:onInit()
    self:debug("onInit") 
    -- Amazing debug snippet to show all the available properties in a JSON
    -- local dev = api.get("/devices/" .. self.id)
    -- self:debug("Props:", json.encode(dev.properties))
    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Auto", "Off", "Heat", "Cool"})
    self:updateProperty("heatingThermostatSetpointCapabilitiesMin", 12)
    self:updateProperty("heatingThermostatSetpointCapabilitiesMax", 40)
    self:updateProperty("heatingThermostatSetpointStep", { C = 1 })
    self:updateProperty("coolingThermostatSetpointCapabilitiesMin", 12)
    self:updateProperty("coolingThermostatSetpointCapabilitiesMax", 40)
    self:updateProperty("coolingThermostatSetpointStep", { C = 1 })
    self:updateProperty("autoThermostatSetpointCapabilitiesMin", 12)
    self:updateProperty("autoThermostatSetpointCapabilitiesMax", 40)
    self:updateProperty("autoThermostatSetpointStep", { C = 1 })
    self:updateProperty("autoThermostatSetpoint", { value= 36, unit= "C" })
    self:updateProperty("heatingThermostatSetpoint", { value= 37, unit= "C" })
    self:updateProperty("coolingThermostatSetpoint", { value= 30, unit= "C" })
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
    if not self.enabled or self.ip == "changeme" then return end

    currentThermostatMode = mode

    local chandata1 = { ['1'] = (mode ~= "Off") }
    local tuyaMode = "smart"
    if mode == "Heat" then tuyaMode = "warm" end
    if mode == "Cool" then tuyaMode = "cool" end

    local chandata2 = { ['105'] = tuyaMode }

    -- send ON/OFF
    self:sendCommand(chandata1, function()
        self:_updateThermostatModeFromDevice(mode)
    end)

    -- send operation mode
    self:sendCommand(chandata2, function()
        self:_updateThermostatModeFromDevice(mode)
    end)

    -- delayed refresh only (NO immediate pingTuya!)
    if not pendingRefresh then
        pendingRefresh = true
        fibaro.setTimeout(2000, function()
            pendingRefresh = false
            self:updateTuyaState()
        end)
    end
end

-- handle action for setting set point for cooling
function QuickApp:setautoThermostatSetpoint(value)
    self:debug("Auto setpoint changed to:", value)
    if not self.enabled or self.ip == "changeme" then return end

    local v = math.floor(tonumber(value or 0))

    local chandata = { ['106'] = v }

    self:sendCommand(chandata, function()
        self:_updateAutoSetpointFromDevice(v)
        self:updateConsumption()
    end)
end

-- handle action for setting set point for cooling
function QuickApp:setHeatingThermostatSetpoint(value)
    if currentThermostatMode ~= "Auto" then
        self:debug("Heating setpoint changed to:", value)
        if not self.enabled or self.ip == "changeme" then return end

        local v = math.floor(tonumber(value or 0))

        local chandata = { ['106'] = v }

        self:sendCommand(chandata, function()
            self:_updateHeatingSetpointFromDevice(v)
            self:updateConsumption()
        end)
    end
end

function QuickApp:setCoolingThermostatSetpoint(value)
    if currentThermostatMode ~= "Auto" then
        self:debug("Cooling setpoint changed to:", value)
        if not self.enabled or self.ip == "changeme" then return end

        local v = math.floor(tonumber(value or 0))

        local chandata = { ['106'] = v }

        self:sendCommand(chandata, function()
            self:_updateCoolingSetpointFromDevice(v)
            self:updateConsumption()
        end)
    end
end

-- INTERNAL: update mode from device
function QuickApp:_updateThermostatModeFromDevice(mode)
    self:updateProperty("thermostatMode", mode)
    currentThermostatMode = mode
    self:updateConsumption()
end

-- INTERNAL: update auto setpoint from device
function QuickApp:_updateAutoSetpointFromDevice(v)
    self:updateProperty("autoThermostatSetpoint", { value = v, unit="C" })
end

-- INTERNAL: update heating setpoint from device
function QuickApp:_updateHeatingSetpointFromDevice(v)
    self:updateProperty("heatingThermostatSetpoint", { value = v, unit = "C" })
end

-- INTERNAL: update cooling setpoint from device
function QuickApp:_updateCoolingSetpointFromDevice(v)
    self:updateProperty("coolingThermostatSetpoint", { value = v, unit = "C" })
end

function QuickApp:updateConsumption()
    if currentPercentage == 0 then
        self:updateProperty("power", 0)
        self:updateProperty("log", "0 W")
        self.childs.currentPowerChild:setValue(0)
    else 
        local powerValue = currentPercentage * 28
        local powerValueString = tostring(powerValue).." W"
        self:updateProperty("power", powerValue)
        self:updateProperty("log", "2800 W")
        self.childs.currentPowerChild:setValue(powerValue)
    end
end

function QuickApp:updateEnergyValues()
    local energyMeterId = self:getVariable("totalEnergyChild")
    local totalConsumption = hub.getValue(energyMeterId, "value")
    local newConsumption = totalConsumption

    if currentThermostatMode ~= "Off" then
        local energyValue = currentPercentage * 28 / 60000
        newConsumption = totalConsumption + energyValue
        self:debug("Total Consumption: ", totalConsumption, "New total consumption: ", newConsumption)
        self.childs.totalEnergyChild:setValue(newConsumption)
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
    
        self:debug(deviceName, "created:", child.id)
    end

    return self.childDevices[childId]
end

function QuickApp:createChildDevices()
    self:initChildDevices({
        ["com.fibaro.energyMeter"] = Meter,
        ["com.fibaro.powerMeter"] = PowerSensor,
    })
    
    -- total energy consumed (kWh)
    self.childs.totalEnergyChild = self:initChildDevice("totalEnergyChild", "Heatpump energy consumption", "com.fibaro.energyMeter", Meter)
    self.childs.totalEnergyChild:updateProperty("rateType", "consumption")

    -- current consumption (W)
    self.childs.currentPowerChild = self:initChildDevice("currentPowerChild", "Heatpump power consumption", "com.fibaro.powerMeter", PowerSensor)
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
                            if resp['1'] ~= nil and resp['1'] == false then 
                                self:_updateThermostatModeFromDevice("Off")
                            elseif resp['1'] ~= nil and resp['1'] == true then 
                                if resp['105'] ~= nil then
                                    if resp['105'] == "warm" then
                                        self:_updateThermostatModeFromDevice("Heat")
                                    elseif resp['105'] == "cool" then
                                        self:_updateThermostatModeFromDevice("Cool")
                                    elseif resp['105'] == "smart" then
                                        self:_updateThermostatModeFromDevice("Auto")
                                    end
                                end
                            end
                            if resp['102'] ~= nil then
                                currentTemp = resp['102']
                                local currentTemp = tostring(resp['102']).." °C"
                                hub.call(468, "setTemperature", resp['102'])
                                self:updateView("labelCurrentTemperature", "text", "Current temperature: "..currentTemp)
                            end
                            if resp['106'] ~= nil then 
                                local t = tonumber(resp['106'])
                                if t then
                                    if currentThermostatMode == "Auto" then
                                        self:_updateAutoSetpointFromDevice(t)
                                    elseif currentThermostatMode == "Heat" then
                                        self:_updateHeatingSetpointFromDevice(t)
                                    elseif currentThermostatMode == "Cool" then
                                        self:_updateCoolingSetpointFromDevice(t)
                                    end
                                end
                            end
                            if resp['104'] ~= nil then
                                currentPercentage = tonumber(resp['104'])
                                local currentPercString = "Power: "..tostring(resp['104']).." %"
                                self:updateView("labelPercentage", "text", currentPercString)
                            end
                            if resp['115'] ~= nil then
                                local f1 = tonumber(resp['115'])
                                local fault1String = ""
                                local list1 = self:decodeBitmapByMask(f1, fault1Map)
                                if #list1 > 0 then
                                    fault1String = "Fault1: " .. table.concat(list1, ", ")
                                end
                                self:debug(fault1String)
                                if fault1String ~= "" then
                                    hasFault1 = true
                                    self:updateProperty("log", fault1String)
                                else 
                                    hasFault1 = false
                                end
                                self:updateView("labelFault1", "text", fault1String)
                            end
                            if resp['116'] ~= nil then
                                local f2 = tonumber(resp['116'])
                                local fault2String = ""
                                local list2 = self:decodeBitmapByMask(f2, fault2Map)
                                if #list2 > 0 then
                                    fault2String = "Fault2: " .. table.concat(list2, ", ")
                                end
                                if fault2String ~= "" then
                                    hasFault2 = true
                                    self:updateProperty("log", fault12String)
                                else 
                                    hasFault2 = false
                                end
                                self:updateView("labelFault2", "text", fault2String)
                            end
                        end
                    elseif (tonumber(commandByte) == tuyAPI.tuyaCommandType.HEART_BEAT) then
                        self:updateView("labelStatus", "text", "Connected successfully")
                    end
                    if not hasFault1 and not hasFault2 then self:updateConsumption() end
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

function QuickApp:decodeBitmapByMask(value, map)
    local faults = {}
    for mask, info in pairs(map) do
        if bit32.band(value, mask) ~= 0 then
            faults[#faults+1] = string.format("%s (%s)", info.code, info.desc)
        end
    end
    return faults
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