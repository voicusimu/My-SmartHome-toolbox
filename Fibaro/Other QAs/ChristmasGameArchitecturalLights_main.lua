-- Binary switch type should handle actions turnOn, turnOff
-- To update binary switch state, update property "value" with boolean
local frontLight1 = 324
local frontLight2 = 326
local frontLight3 = 480
local backLight1 = 330
local backLight2 = 332
local backLight3 = 536
local architecturalLights = 419
local lightAnimationOn = false


function setRandomColorTo(id)
    local randomR = math.random(255)
    local randomG = math.random(255)
    local randomB = math.random(255)
    local randomW = math.random(255)
    hub.call(id, 'setColor', randomR or 0, randomG or 0, randomB or 0, randomW or 0)
    hub.debug("Random light:", randomR, randomB, randomG, randomW)
end

function performColorAnimation()
    setRandomColorTo(frontLight1)
    setRandomColorTo(frontLight2)
    setRandomColorTo(frontLight3)
    setRandomColorTo(backLight1)
    setRandomColorTo(backLight2)
    setRandomColorTo(backLight3)
    if lightAnimationOn == true then
        fibaro.setTimeout(500, function() 
            performColorAnimation()
        end)
    end
end

function QuickApp:turnOn()
    self:debug("Architectural lights Christmas animation turned on")
    self:updateProperty("value", true)
    lightAnimationOn = true
    performColorAnimation()
end

function QuickApp:turnOff()
    self:debug("Architectural lights Christmas animation turned off")
    self:updateProperty("value", false)
    lightAnimationOn = false
    fibaro.setTimeout(1000, function() 
        hub.call(architecturalLights, 'setColor', 255, 255, 255, 255)
    end) 
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
