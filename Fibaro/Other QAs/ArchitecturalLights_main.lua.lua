-- Color controller type should handle actions: turnOn, turnOff, setValue, setColor
-- To update color controller state, update property color with a string in the following format: "r,g,b,w" eg. "200,10,100,255"
-- To update brightness, update property "value" with integer 0-99

local frontLightOne = 324
local frontLightTwo = 326
local frontLightThree = 480
local backLightOne = 330
local backLightTwo = 332
local backLightThree = 536

function QuickApp:turnOn()
    self:debug("color controller turned on")
    self:updateProperty("value", 99)

    hub.call(frontLightOne, 'turnOn')
    hub.call(frontLightTwo, 'turnOn')
    hub.call(frontLightThree, 'turnOn')
    hub.call(backLightOne, 'turnOn')
    hub.call(backLightTwo, 'turnOn')
    hub.call(backLightThree, 'turnOn')
end

function QuickApp:turnOff()
    self:debug("color controller turned off")
    self:updateProperty("value", 0)

    hub.call(frontLightOne, 'turnOff')
    hub.call(frontLightTwo, 'turnOff')
    hub.call(frontLightThree, 'turnOff')
    hub.call(backLightOne, 'turnOff')
    hub.call(backLightTwo, 'turnOff')
    hub.call(backLightThree, 'turnOff')    
end

-- Value is type of integer (0-99)
function QuickApp:setValue(value)
    self:debug("color controller value set to: ", value)
    self:updateProperty("value", value)

    hub.call(frontLightOne, 'setValue', value) 
    hub.call(frontLightTwo, 'setValue', value) 
    hub.call(frontLightThree, 'setValue', value) 
    hub.call(backLightOne, 'setValue', value) 
    hub.call(backLightTwo, 'setValue', value) 
    hub.call(backLightThree, 'setValue', value) 
end

-- Color is type of table, with format [r,g,b,w]
-- Eg. relaxing forest green, would look like this: [34,139,34,150]
function QuickApp:setColor(r,g,b,w)
    local color = string.format("%d,%d,%d,%d", r or 0, g or 0, b or 0, w or 0) 
    self:debug("color controller color set to: ", color)
    self:updateProperty("color", color)

    hub.call(frontLightOne, 'setColor', r or 0, g or 0, b or 0, w or 0)
    hub.call(frontLightTwo, 'setColor', r or 0, g or 0, b or 0, w or 0)
    hub.call(frontLightThree, 'setColor', r or 0, g or 0, b or 0, w or 0)
    hub.call(backLightOne, 'setColor', r or 0, g or 0, b or 0, w or 0)
    hub.call(backLightTwo, 'setColor', r or 0, g or 0, b or 0, w or 0)
    hub.call(backLightThree, 'setColor', r or 0, g or 0, b or 0, w or 0)
end
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
end
