-- Gamepad QoL Suite: colour-code CleanUI's weight column by item weight.
--
-- CleanUI draws each weight value with a dedicated right-aligned text call using a
-- fixed grey (0.75, 0.75, 0.75, 0.9). We hook ISInventoryPane:drawTextRight and,
-- when a call matches that signature and the text is a plain number, substitute
-- a tier colour. Everything else is passed through untouched, so this stays
-- inert when CleanUI's weight column is off (or when CleanUI is not installed).
--
-- Tiers: <2 native grey, 2-4.99 pale yellow, 5-9.99 amber, 10+ deep orange-red.

local CGUI = require("GQSModOptions")

local WeightColor = rawget(_G, "GamepadQoLWeightColor") or {}
_G.GamepadQoLWeightColor = WeightColor

local NATIVE_R, NATIVE_G, NATIVE_B, NATIVE_A = 0.75, 0.75, 0.75, 0.9
local COLOUR_TOLERANCE = 0.01

local function debugPrint(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("weightColor", message)
    end
end

local function optionEnabled()
    local option = CGUI and CGUI.weightColorEnabled
    if not option or type(option.getValue) ~= "function" then
        -- The option defaults to true; if the options module is unavailable yet
        -- (early load order), behave as enabled rather than silently disabling.
        return true
    end
    local ok, value = pcall(option.getValue, option)
    return ok and value == true
end

local function near(a, b)
    return type(a) == "number" and math.abs(a - b) <= COLOUR_TOLERANCE
end

--- Return the tier colour for a weight, or nil to keep the native grey.
---@param weight number
local function colourForWeight(weight)
    if type(weight) ~= "number" then return nil end
    if weight ~= weight or weight < 0 then return nil end -- NaN / negative
    if weight < 2 then return nil end
    if weight < 5 then return 1.00, 0.93, 0.60, 0.95 end
    if weight < 10 then return 1.00, 0.72, 0.20, 0.95 end
    return 1.00, 0.40, 0.12, 0.95
end

--- Recognise CleanUI's weight-column draw call and extract the weight.
---@return number? weight
local function weightFromDraw(text, r, g, b, a)
    if type(text) ~= "string" then return nil end
    if not (near(r, NATIVE_R) and near(g, NATIVE_G) and near(b, NATIVE_B)
            and near(a, NATIVE_A)) then
        return nil
    end
    local value = tonumber(text)
    if type(value) ~= "number" or value < 0 then return nil end
    return value
end

local function wrapPane(paneClass)
    if type(paneClass) ~= "table" then return end
    local current = paneClass.drawTextRight
    if type(current) ~= "function" then return end

    -- Reference comparison, not a one-shot flag: CleanUI may replace methods
    -- after us, and a stale flag would bury our hook forever.
    if paneClass._gqsWeightColorWrapper == current then return end

    local wrapper = function(self, text, x, y, r, g, b, a, font, ...)
        if optionEnabled() then
            local weight = weightFromDraw(text, r, g, b, a)
            if weight then
                local nr, ng, nb, na = colourForWeight(weight)
                if nr then
                    r, g, b, a = nr, ng, nb, na
                    debugPrint(string.format("weight %.2f -> %.2f/%.2f/%.2f", weight, nr, ng, nb))
                end
            end
        end
        return current(self, text, x, y, r, g, b, a, font, ...)
    end

    paneClass.drawTextRight = wrapper
    paneClass._gqsWeightColorWrapper = wrapper
end

local function install()
    wrapPane(rawget(_G, "ISInventoryPane"))
    wrapPane(rawget(_G, "CleanUI_Clean_ISInventoryPane"))
    wrapPane(rawget(_G, "CleanUI_Vanilla_ISInventoryPane"))
end

-- Exported for the sandbox test harness.
WeightColor.colourForWeight = colourForWeight
WeightColor.weightFromDraw = weightFromDraw
WeightColor.install = install

install()
if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(install) end
    if Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end
    if Events.OnTick then
        local frames = 0
        Events.OnTick.Add(function()
            frames = frames + 1
            if frames % 30 == 0 then install() end
        end)
    end
end

return WeightColor
