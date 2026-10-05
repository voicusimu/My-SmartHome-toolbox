-- devices ids
local solarSwitch = 139
local boostSwitch = 140
local boilerSensor = 134
local boilerThermostat = 89
local boilerHysteresis = 2.0
local weatherProvider = 3
local gridPowerMeter = 810
local cloudiness = 569

-- local vars
local display = "0 W"
local switchCommand = "turnOn"

function QuickApp:loopActionForRefreshEverySecond()
    self.setpoint = self:getVariable("setpoint")
    self.antiLegionella = self:getVariable("legMode")
    self.autoMode = self:getVariable("autoMode")
    self.isHeating = hub.getValue(solarSwitch, "value") or hub.getValue(boostSwitch, "value")
    self.boilerMidSensorValue = hub.getValue(boilerSensor, "value")

    self:updateValues()
    self:updateLogDisplay()
    self:updateThermostat()
    self:autoUpdateThermostatMode()

    fibaro.setTimeout(18*1000, function() 
        self:loopActionForRefreshEverySecond() 
    end)
end

function QuickApp:loopActionForRefreshEvery6Hours()
    self:updateDayPart()
    self:updateAntiLegionellaMode()
    fibaro.setTimeout(60*60*6*1000, function() 
        self:loopActionForRefreshEvery6Hours()
    end)
end

function QuickApp:setThermostatMode(mode)
    self:updateProperty("thermostatMode", mode)
end

function QuickApp:updateLogDisplay()
    isSolarOn = hub.getValue(solarSwitch, "value")
    isBoostOn = hub.getValue(boostSwitch, "value")

    if isSolarOn then
        if isBoostOn then
            display = "2190 W"
        else 
            display = "390 W"
        end
    else 
        if isBoostOn then
            display = "1800 W"
        else 
            display = "0 W"
        end
    end
    self:updateProperty("log", display)
end

-- handle action for setting set point for heating
function QuickApp:setHeatingThermostatSetpoint(value)
    self:setVariable("setpoint", tostring(value))
    self.setpoint = tostring(value)
    local setpointText = "Setpoint: "..value.." °C"
    self:updateView("slider_temp","value", tostring(self.setpoint))
    self:debug("Boiler ", setpointText)
end

function QuickApp:onInit()
    self:debug("onInit")

    -- set supported modes for thermostat
    self:updateProperty("supportedThermostatModes", {"Off", "Solar", "Electric", "Boost"})
    self.solarAutoconsumptionModeRunning = false
    standardSetpoint = self:getVariable("stdSetpoint")
    self:setHeatingThermostatSetpoint(standardSetpoint)
    
    -- setup default values
    self:updateProperty("thermostatMode", "Solar")
    self:updateView("slider_temp","max","65")
    self:updateView("slider_temp","min","30")
    self.solarTemperaturePoint = 6
    self.boostTemperaturePoint = 3
    self.electricTemperaturePoint = -3
    self:updateDayPart()
    self:loopActionForRefreshEvery6Hours()
    self:loopActionForRefreshEverySecond()
end

function QuickApp:updateValues()
    if self.antiLegionella == "true" then 
        self:updateView("leg_label", "text", "BOILER ANTI-LEGIONELLA: ON")
    else
        self:updateView("leg_label", "text", "BOILER ANTI-LEGIONELLA: OFF")
    end

    if self.autoMode == "true" then 
        self:updateView("auto_label", "text", "BOILER AUTO MODE: ON")
    else
        self:updateView("auto_label", "text", "BOILER AUTO MODE: OFF")
    end
    self:updateView("slider_temp","value", tostring(self.setpoint))
end

-- UI Actions
function QuickApp:sliderChanged(event)
    tempValue = event.values[1]
    self:debug("Slider set to value: ", tempValue)
    self:setHeatingThermostatSetpoint(tempValue)
end

function QuickApp:autoOnBtnPressed(event)
    self:setVariable("autoMode", "true")
    self:updateView("auto_label", "text", "BOILER AUTO MODE: ON")
end

function QuickApp:autoOffBtnPressed(event)
    self:setVariable("autoMode", "false")
    self:updateView("auto_label", "text", "BOILER AUTO MODE: OFF")
end

function QuickApp:legOnBtnPressed(event)
    self:setVariable("legMode", "true")
    self:updateView("leg_label", "text", "BOILER ANTI-LEGIONELLA: ON")
end

function QuickApp:legOffBtnPressed(event)
    self:setVariable("legMode", "false")
    self:updateView("leg_label", "text", "BOILER ANTI-LEGIONELLA: OFF")
end

-- public functions for updating the Thermostat mode
function QuickApp:setMode(value)
    modeSetInternally = false
    self:updateProperty("thermostatMode", value)
    modeSetInternally = true
    self:debug("setValue", value)
end

-- thermostat logic

function QuickApp:setSwitchPositionsIfNeeded(solar, electric)
    local solarOn = false
    local electricOn = false

    if solar == "turnOn" then
        solarOn = true
    end

    if electric == "turnOn" then
        electricOn = true
    end

    if hub.getValue(solarSwitch, "value") ~= solarOn then
        hub.call(solarSwitch, solar)
    end

    if hub.getValue(boostSwitch, "value") ~= electricOn then
        hub.call(boostSwitch, electric)
    end

    hub.trace("Solar sw state: ", hub.getValue(solarSwitch, "value"))
    hub.trace("Boiler middle measured value: ", hub.getValue(boilerSensor, "value"))
    hub.trace("Boiler setpoint", self.setpoint)
    hub.trace("Thermostat mode", hub.getValue(boilerThermostat, "thermostatMode"))
    hub.trace("Boiler is heating: ", self.isHeating)

    hub.trace("Solar SW state", hub.getValue(solarSwitch, "value"))
    hub.trace("Electric SW state", hub.getValue(boostSwitch, "value"))
end

-- Histerezis logic
function QuickApp:updateThermostat()
    if self.isHeating then 
        if self.boilerMidSensorValue >= tonumber(self.setpoint) then
            switchCommand = "turnOff"
        end
    else 
        if self.setpoint - self.boilerMidSensorValue >= boilerHysteresis then
            switchCommand = "turnOn"
        else
            switchCommand = "turnOff"
        end
    end

    -- Boiler modes logic
    if hub.getValue(89, "thermostatMode") == "Off" then 
        self:setSwitchPositionsIfNeeded("turnOff", "turnOff")
        hub.debug("The boiler is in off mode so it will not be triggered by the temperature change command")
    end

    if hub.getValue(89, "thermostatMode") == "Solar" then 
        self:setSwitchPositionsIfNeeded(switchCommand, "turnOff")
        hub.debug("The boiler is in Solar mode so the compressor will", switchCommand)
    end

    if hub.getValue(89, "thermostatMode") == "Electric" then
        self:setSwitchPositionsIfNeeded("turnOff", switchCommand) 
        hub.debug("The boiler is in Electric mode so the coil will", switchCommand)
    end

    if hub.getValue(89, "thermostatMode") == "Boost" then 
        self:setSwitchPositionsIfNeeded(switchCommand, switchCommand) 
        hub.debug("The boiler is in Boost mode so both the compressor and the coil will", switchCommand)   
    end
end


-- Auto Mode logic

function QuickApp:autoUpdateThermostatMode()
    self.antiLegionellaDay = os.date("*t").day == 3 or os.date("*t").day == 9 or os.date("*t").day == 18 or os.date("*t").day == 27
    self.antiLegionella = self:getVariable("legMode")
    self.autoMode = self:getVariable("autoMode")
    local outsideTemperature = hub.getValue(weatherProvider, "Temperature")
    local weatherCondition = hub.getValue(weatherProvider, "WeatherCondition")
    local boilerCurrentMode = hub.getValue(89, "thermostatMode")
    local gridValue = hub.getValue(gridPowerMeter, "value")
    local cloudPercentValue = hub.getValue(cloudiness, "value")
    local boilerAutomaticMode = ""

    if self.autoMode == "true" then
        if antiLegionellaDay then
            self:updateAntiLegionellaMode()
        else
            if self.solarAutoconsumptionModeRunning == false then
                if gridValue < -2190 then
                    self.solarAutoconsumptionModeRunning = true
                    legionellaSetpoint = self:getVariable("legSetpoint")
                    self:setHeatingThermostatSetpoint(legionellaSetpoint)
                    boilerAutomaticMode = "Boost"

                    hub.debug("Setpoint changed to: ", legionellaSetpoint)
                    hub.debug("Solar AUTO Mode is: ", self.solarAutoconsumptionModeRunning)
                end
            else
                if gridValue > -300 then
                    self.solarAutoconsumptionModeRunning = false
                    standardSetpoint = self:getVariable("stdSetpoint")
                    self:setHeatingThermostatSetpoint(standardSetpoint)

                    hub.debug("Setpoint changed to: ", standardSetpoint)
                    hub.debug("Solar AUTO Mode is: ", self.solarAutoconsumptionModeRunning)
                end
            end
        end

        if os.date("*t").day == 3 or os.date("*t").day == 9 or os.date("*t").day == 18 or os.date("*t").day == 27 then
            self.solarTemperaturePoint = 10
            self.boostTemperaturePoint = 5
            self.electricTemperaturePoint = 0
        else
            self.solarTemperaturePoint = 5
            self.boostTemperaturePoint = 0
            self.electricTemperaturePoint = -5
        end

        hub.debug("Anti legionella day: ", self.antiLegionellaDay)
        hub.debug("Auto mode: ", self.autoMode)
        hub.debug("Outside temperature: ", outsideTemperature)
        hub.debug("Weather Condition: ", weatherCondition)
        hub.debug("Cloud percentage: ", cloudPercentValue)
        hub.debug("Day part: ", self.dayPartIndex)
        hub.debug("solar temp point: ", self.solarTemperaturePoint)
        hub.debug("boost temp point: ", self.boostTemperaturePoint)
        hub.debug("electric temp point: ", self.electricTemperaturePoint)
        hub.debug("Boiler setpoint: ", self.setpoint)

        if self.solarAutoconsumptionModeRunning == true then
            boilerAutomaticMode = "Boost"
        else 
            if outsideTemperature > self.solarTemperaturePoint then  -- if temperature is higher than compressor point
                boilerAutomaticMode = "Solar"
            else
                if outsideTemperature > self.boostTemperaturePoint then -- if temperature is higher than boost point 
                    if (self.dayPartIndex < 7 or self.dayPartIndex > 14) then -- at night time
                        boilerAutomaticMode = "Boost"
                    else -- during the day
                        if cloudPercentValue < 30 then 
                            boilerAutomaticMode = "Solar"
                        else 
                            boilerAutomaticMode = "Boost"
                        end
                    end
                else 
                    if outsideTemperature > self.electricTemperaturePoint then
                        if (self.dayPartIndex < 7 or self.dayPartIndex > 14) then -- at night time
                            boilerAutomaticMode = "Electric"
                        else -- during the day
                            if cloudPercentValue < 30 then 
                                boilerAutomaticMode = "Boost"
                            else
                                boilerAutomaticMode = "Electric" 
                            end
                        end
                    else
                        boilerAutomaticMode = "Electric"
                    end
                end
            end
        end

        if boilerAutomaticMode == boilerCurrentMode then
            -- Do nothing
        else
            hub.trace("Boiler current mode", boilerCurrentMode)
            hub.trace("Outside temperature", outsideTemperature)
            hub.trace("Curent weather", weatherCondition)
            self:setThermostatMode(boilerAutomaticMode)
        end
    end
end

-- Anti-Legionella Mode logic

function QuickApp:updateAntiLegionellaMode()
    self.antiLegionella = self:getVariable("legMode")
    self.antiLegionellaDay = os.date("*t").day == 3 or os.date("*t").day == 9 or os.date("*t").day == 18 or os.date("*t").day == 27
    if self.antiLegionella == "true" then
        if self.antiLegionellaDay then
            legionellaSetpoint = self:getVariable("legSetpoint")
            self:setHeatingThermostatSetpoint(legionellaSetpoint)
        else 
            if self.autoMode == "true" then
                standardSetpoint = self:getVariable("stdSetpoint")
                self:setHeatingThermostatSetpoint(standardSetpoint)
                self.solarAutoconsumptionModeRunning = false
            end
        end
    end
end

--helpers

function QuickApp:updateDayPart()
    jsonString = hub.getValue(426,"userDescription")
    decodedValue = json.decode(jsonString)
    self.dayPartIndex = decodedValue.dayPartIndex
end
