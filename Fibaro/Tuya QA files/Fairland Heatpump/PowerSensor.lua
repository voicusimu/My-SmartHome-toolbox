class 'PowerSensor' (QuickAppChild)

function PowerSensor:__init(device)
    QuickAppChild.__init(self, device)
    self:updateProperty("unit", "W")
end

function PowerSensor:setValue(value)
    self:updateProperty("value",  value)
    self:updateProperty("power",  value)
end