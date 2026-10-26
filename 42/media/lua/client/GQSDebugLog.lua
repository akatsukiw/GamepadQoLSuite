-- Gamepad QoL Suite: centralized debug log routing.
-- To inspect one feature, set its category to true below; set it back to false when done.

local DEFAULT_CATEGORIES = {
    multiSelect = false,
    panelQuickSelect = false,
    containerCycle = false,
    containerSwitch = false,
    dragTransfer = false,
    xTransfer = false,
    modOptions = false,
    nameColumn = false,
    fitnessUI = false,
    rbZoom = false, -- opt-in only: detailed RB+Y/A input diagnostics
    rbMoodles = false,
    rtBFocus = false,
    rightRadial = false,
    craftingFocus = false,
    containerPageNav = false,
    panelInfo = false,
    mixedAutoDrink = false,
    furnitureRotate = false, -- verified in game; enable to trace rotation decisions
    craftLogic = true, -- TEMPORARY: tracing leather drying rack material auto-add
}

local LABELS = {
    multiSelect = "MultiSelect",
    panelQuickSelect = "PanelQuickSelect",
    containerCycle = "ContainerCycle",
    containerSwitch = "ContainerSwitch",
    dragTransfer = "DragTransfer",
    xTransfer = "XTransfer",
    modOptions = "ModOptions",
    nameColumn = "NameColumn",
    fitnessUI = "Fitness UI",
    rbZoom = "RB Zoom",
    rbMoodles = "RB Moodle",
    rtBFocus = "RT+B Focus",
    rightRadial = "Right Radial",
    craftingFocus = "Crafting Focus",
    containerPageNav = "Container Page Navigation",
    panelInfo = "Panel Info Enhancement",
    mixedAutoDrink = "Mixed Auto Drink",
    furnitureRotate = "Furniture Rotate",
    craftLogic = "Craft Logic Panel",
}

local config = rawget(_G, "GQS_DEBUG_CONFIG")
if type(config) ~= "table" then config = {} end
if config.defaultEnabled == nil then config.defaultEnabled = false end
if type(config.categories) ~= "table" then config.categories = {} end
for category, enabled in pairs(DEFAULT_CATEGORIES) do
    if config.categories[category] == nil then
        config.categories[category] = enabled
    end
end
_G.GQS_DEBUG_CONFIG = config

local logger = rawget(_G, "GQSLog")
if type(logger) ~= "table" then logger = {} end

function logger.isEnabled(category)
    local value = config.categories[category]
    if value == nil then return config.defaultEnabled == true end
    return value == true
end

function logger.log(category, message)
    if not logger.isEnabled(category) then return false end
    local label = LABELS[category] or tostring(category or "General")
    print("[GQS " .. label .. "] " .. tostring(message))
    return true
end

function logger.error(category, message)
    if not logger.isEnabled(category) then return false end
    local label = LABELS[category] or tostring(category or "General")
    print("[GQS " .. label .. "][ERROR] " .. tostring(message))
    return true
end

function logger.setEnabled(category, enabled)
    config.categories[category] = enabled == true
end

_G.GQSLog = logger
