-- Gate CustomGamepadUI's extra Select-wheel entries using a GQS-owned setting.
local GQS = require("GQSModOptions")
local installed = false
local function install()
    if installed or not ISBackButtonWheel then return end
    local original = ISBackButtonWheel.addCommands
    if type(original) ~= "function" then return end
    ISBackButtonWheel.addCommands = function(self, ...)
        local enabled = GQS.selectWheelPvpOptionEnabled
            and type(GQS.selectWheelPvpOptionEnabled.getValue) == "function"
            and GQS.selectWheelPvpOptionEnabled:getValue() == true
        if enabled then return original(self, ...) end

        local addSlice = self.addSlice
        self.addSlice = function(wheel, text, texture, callback, target, command, ...)
            if callback == wheel.onCommand and target == wheel
                and (command == "SAFETY" or command == "USERPANEL" or command == "ADMINPANEL"
                    or command == "WARMANAGERPANEL" or command == "DEBUG") then
                return
            end
            if text == nil and texture == nil and callback == nil then return end
            return addSlice(wheel, text, texture, callback, target, command, ...)
        end
        local ok, err = pcall(original, self, ...)
        self.addSlice = addSlice
        if not ok then
            local logger = rawget(_G, "GQSLog")
            if logger then logger.error("modOptions", "Select-wheel filter failed: " .. tostring(err)) end
        end
    end
    installed = true
end
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(install) end
