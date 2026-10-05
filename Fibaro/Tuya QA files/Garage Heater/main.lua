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
local currentPowerMode = "Low"
local currentTemp = 0
local pendingRefresh = false

function QuickApp:onInit()
    self:debug("onInit")
    -- Amazing debug snippet to show all the available properties in a JSON
    -- local dev = api.get("/devices/" .. self.id)
    -- self:debug("Props:", json.encode(dev.properties))
    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Off", "Heat"})
    self:updateProperty("heatingThermostatSetpointCapabilitiesMax", 30)
    self:updateProperty("heatingThermostatSetpointCapabilitiesMin", 5)
    self:updateProperty("heatingThermostatSetpointStep", { C = 1 })
    self:updateProperty("heatingThermostatSetpoint", { value= 12, unit= "C" })
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

    local chandata = { ['1'] = (mode == "Heat") }

    self:sendCommand(chandata, function()
        self:_updateThermostatModeFromDevice(mode)
        self:updateConsumption()
    end)

    -- delayed refresh, prevents storms
    if not pendingRefresh then
        pendingRefresh = true
        fibaro.setTimeout(2000, function()
            pendingRefresh = false
            self:updateTuyaState()
        end)
    end
end

-- handle action for setting set point for heating
function QuickApp:setHeatingThermostatSetpoint(value)
    if not self.enabled or self.ip == "changeme" then return end

    local v = math.floor(tonumber(value or 0))

    local chandata = { ['3'] = v }

    self:sendCommand(chandata, function()
        self:_updateHeatingSetpointFromDevice(v)
        self:updateConsumption()
    end)

    if not pendingRefresh then
        pendingRefresh = true
        fibaro.setTimeout(2000, function()
            pendingRefresh = false
            self:updateTuyaState()
        end)
    end
end

function QuickApp:modeLow()
    if self.enabled then
        local chandata = {
                ['7'] = "Low",
        }
        if self.ip ~= "changeme" then
            self:sendCommand(chandata, function()
                self:_updatePowerModeFromDevice("Low")
                self:updateConsumption()
            end)
        end
    end
end

function QuickApp:modeHigh()
    if self.enabled then
        local chandata = {
                ['7'] = "High",
        }
        if self.ip ~= "changeme" then
            self:sendCommand(chandata, function()
                self:_updatePowerModeFromDevice("High")
                self:updateConsumption()
            end)
        end
    end
end

function QuickApp:_updateThermostatModeFromDevice(mode)
    if mode ~= self.properties.thermostatMode then
        self:updateProperty("thermostatMode", mode)
    end
    currentThermostatMode = mode
end

-- INTERNAL: heating setpoint from device
function QuickApp:_updateHeatingSetpointFromDevice(v)
    self:updateProperty("heatingThermostatSetpoint", { value = v, unit = "C" })
end

-- INTERNAL: power mode from device
function QuickApp:_updatePowerModeFromDevice(mode)
    currentPowerMode = mode
    self:updateView("modeLabel", "text", "Current mode: "..mode)
end

-- INTERNAL: update currentTemp
function QuickApp:_updateCurrentTempFromDevice(v)
    currentTemp = v
    hub.call(577, "setTemperature", v)
    self:updateView("labelCurrentTemperature", "text", "Current temperature: ".. tostring(v) .. " °C")
end

function QuickApp:updateConsumption()
    local heatSetpoint = self.properties.heatingThermostatSetpoint.value
    if self.showDebug then self:debug("Garage heater mode: ", currentThermostatMode) end
    if currentThermostatMode == "Heat" then
        if self.showDebug then
            self:debug("Heat Setpoint: ", heatSetpoint)
            self:debug("Current temperature: ", currentTemp)
        end
        if heatSetpoint > currentTemp then
            if currentPowerMode == "Low" then
                self.childs.currentPowerChild:updateProperty("value", 1000)
                self:updateProperty("power", 1000)
                self:updateProperty("log", "1000 W")
            else 
                self.childs.currentPowerChild:updateProperty("value", 2000)
                self:updateProperty("power", 2000)
                self:updateProperty("log", "2000 W")
            end
        else
            self.childs.currentPowerChild:updateProperty("value", 0)
            self:updateProperty("power", 0)
            self:updateProperty("log", "0 W")
        end
    else
        self.childs.currentPowerChild:updateProperty("value", 0)
        self:updateProperty("power", 0)
        self:updateProperty("log", "0 W")
    end   
end

function QuickApp:updateEnergyValues()
    if self.showDebug then self:debug("Garage heater mode: ", currentThermostatMode) end
    local heatSetpoint = self.properties.heatingThermostatSetpoint.value
    local energyMeterId = self:getVariable("totalEnergyChild")
    local totalConsumption = hub.getValue(energyMeterId, "value")
    local newConsumption = totalConsumption
    local energyValue = 0
    if currentThermostatMode == "Heat" then
        if self.showDebug then
            self:debug("Heat Setpoint: ", heatSetpoint)
            self:debug("Current temperature: ", currentTemp)
        end
        if currentPowerMode == "Low" then
            -- this QA recconects every 37 secconds, and then it is the perfect time to update the energy value
            energyValue = 1000 / 3600000 * 37
        else 
            energyValue = 2000 / 3600000 * 37
        end
        newConsumption = totalConsumption + energyValue
        if self.showDebug then self:debug("Total Consumption: ", totalConsumption, "New total consumption: ", newConsumption) end
        self.childs.totalEnergyChild:updateProperty("value", newConsumption)
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
    self.childs.totalEnergyChild = self:initChildDevice("totalEnergyChild", "Garage heater energy consumption", "com.fibaro.energyMeter", Meter)
    self.childs.totalEnergyChild:updateProperty("rateType", "consumption")

    -- current consumption (W)
    self.childs.currentPowerChild = self:initChildDevice("currentPowerChild", "Garage heater power consumption", "com.fibaro.powerMeter", PowerSensor)
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
                -- encrypted =  true, -- this one only for version = "3.1" 
                commandByte = tuyAPI.tuyaCommandType.DP_QUERY
            }
            local payload = tuyAPI.tuyaEncode(myoptions)
            self.sock:connect(self.ip, self.port, {
                success = function()
                    self.sock:write(payload)
                    -- ping every 60 seconds
                    self.pingloopID = setInterval(function() self:pingTuya() end, 60000)
                    self:updateEnergyValues()
                    self:waitForData()
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
                            if resp['1'] ~= nil then
                                if resp['1'] == false then
                                    self:_updateThermostatModeFromDevice("Off")
                                else
                                    self:_updateThermostatModeFromDevice("Heat")
                                end
                            end
                            if resp['3'] ~= nil then
                                local desiredTemp = tonumber(resp['3'])
                                self:_updateHeatingSetpointFromDevice(desiredTemp)
                            end

                            if resp['4'] ~= nil then
                                self:_updateCurrentTempFromDevice(resp['4'])
                            end

                            if resp['7'] ~= nil then
                                self:_updatePowerModeFromDevice(resp['7'])
                            end
                        end
                    elseif (tonumber(commandByte) == tuyAPI.tuyaCommandType.HEART_BEAT) then
                        self:updateView("labelStatus", "text", "Connected successfully")
                    end
                    self:updateConsumption()
                end
                self:waitForData()
            end,
            error = function(error)
                if self.showdebug then 
                    self:debug("tuya QA - data response error") 
                    self:debug(error)
                end
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
            -- encrypted =  true, -- this one only for version = "3.1"
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
            -- encrypted =  true, -- this one only for version = "3.1"
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