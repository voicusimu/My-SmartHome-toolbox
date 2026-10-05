class 'Meter' (QuickAppChild)

function Meter:__init(device)
    QuickAppChild.__init(self, device)
    self:updateProperty("unit", "kWh")
end

function Meter:setValue(value)
    -- print("updating", self.id, "value: ", value)
    self:updateProperty("value", tonumber(value))
end