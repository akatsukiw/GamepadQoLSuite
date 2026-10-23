-- Gamepad QoL Suite: contextual Y + D-pad shortcut glyphs on vanilla Select-wheel
-- panel slices (Building / Crafting / PlayerInfo).
--
-- Mirrors GQSZoomRadialShortcutHints: the slice label reserves a second line by
-- appending "\n ", and a separate transparent always-on-top overlay draws the native
-- Y / D-pad glyphs on that line while the slice is selected. No input handling or
-- wheel command is replaced, and nothing is drawn outside the wheel.

pcall(require, "ISUI/ISBackButtonWheel")
pcall(require, "ISUI/ISPanel")

local Wheel = rawget(_G, "ISBackButtonWheel")
local Panel = rawget(_G, "ISPanel")
if type(Wheel) ~= "table" or type(Wheel.addCommands) ~= "function"
        or Wheel._gqsYShortcutWheelHintsInstalled then
    return
end

local originalAddCommands = Wheel.addCommands

-- Wheel command -> Y shortcut actions displayed on that slice.
-- Health is a sub-view of the player-info window, so it is surfaced on PlayerInfo
-- instead of getting a slice of its own. Inventory and Fitness have no vanilla
-- wheel slice, so they intentionally produce no hint here.
local SLICE_ACTIONS = {
    Building = { "building" },
    Crafting = { "crafting" },
    PlayerInfo = { "playerInfo", "health" },
}

-- Matches the option indices used by GQSModOptions / GQSPanelQuickSelect.
local ACTION_BY_INDEX = {
    [1] = "disabled",
    [2] = "building",
    [3] = "crafting",
    [4] = "playerInfo",
    [5] = "health",
    [6] = "inventory",
    [7] = "fitness",
}

-- Mirrors the defaults in GQSModOptions so the hint still works while the options
-- table is not ready yet.
local DEFAULT_INDEX = {
    yShortcutUp = 5,
    yShortcutDown = 6,
    yShortcutLeft = 2,
    yShortcutRight = 3,
}

local DIRECTION_OPTIONS = {
    { name = "Up", option = "yShortcutUp", textures = { "DPadUp", "DpadUp", "UpArrow" } },
    { name = "Down", option = "yShortcutDown", textures = { "DPadDown", "DpadDown", "DownArrow" } },
    { name = "Left", option = "yShortcutLeft", textures = { "DPadLeft", "DpadLeft", "LeftArrow" } },
    { name = "Right", option = "yShortcutRight", textures = { "DPadRight", "DpadRight", "RightArrow" } },
}

-- Joypad.Texture returns a proxy object even for unknown keys, so only accept the
-- keys that vanilla ISButtonPrompt itself resolves, or aliases that report a real
-- texture file path.
local KNOWN_PROMPT_KEYS = {
    YButton = true,
    AButton = true,
    BButton = true,
    XButton = true,
    RBumper = true,
    LBumper = true,
}

local activeWheels = {}
local overlays = {}

local function safeIndex(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function safeCall(object, methodName, ...)
    if object == nil then return nil end
    local method = safeIndex(object, methodName)
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method, object, ...)
    if ok then return value end
    return nil
end

local function readOption(option)
    if option == nil then return nil end
    local getter = safeIndex(option, "getValue")
    if type(getter) == "function" then
        local ok, value = pcall(getter, option)
        if ok and value ~= nil then return value end
    end
    return safeIndex(option, "value")
end

local function getOptions()
    return rawget(_G, "GamepadQoLSuiteOptions") or rawget(_G, "GQS")
end

local function readFlag(name, defaultValue)
    local options = getOptions()
    local value = readOption(options and safeIndex(options, name))
    if value == nil then return defaultValue end
    return not (value == false or value == 0 or value == "0" or value == "false")
end

local function isYShortcutEnabled()
    if not readFlag("yEnhancementEnabled", true) then return false end
    return readFlag("yShortcutEnabled", true)
end

local function getConfiguredAction(optionKey)
    local options = getOptions()
    local index = tonumber(readOption(options and safeIndex(options, optionKey)))
    if not index then index = DEFAULT_INDEX[optionKey] end
    return ACTION_BY_INDEX[index] or "disabled"
end

-- Resolve the configured direction(s) for one wheel slice. Recomputed every time
-- the wheel opens, so changing the mapping in Mod Options takes effect immediately.
local function getDirectionsForSlice(commandName)
    local actions = SLICE_ACTIONS[commandName]
    if not actions then return nil end
    if not isYShortcutEnabled() then return nil end

    local wanted = {}
    for _, action in ipairs(actions) do wanted[action] = true end

    local result = {}
    for _, item in ipairs(DIRECTION_OPTIONS) do
        local action = getConfiguredAction(item.option)
        if wanted[action] then result[#result + 1] = item end
    end
    if #result == 0 then return nil end
    return result
end

local function getNativeTexture(names)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and safeIndex(joypad, "Texture")
    if not textures then return nil end
    for _, name in ipairs(names or {}) do
        local texture = safeIndex(textures, name)
        if texture ~= nil then
            if KNOWN_PROMPT_KEYS[name] then return texture end
            local pathGetter = safeIndex(texture, "getTextureFilePath")
            if type(pathGetter) == "function" then
                local ok, path = pcall(pathGetter, texture)
                if ok and type(path) == "string" and path ~= "" then return texture end
            end
        end
    end
    return nil
end

local function currentSelectedSliceIndex(wheel)
    local javaObject = safeIndex(wheel, "javaObject")
    if not javaObject then return nil end
    local joyfocus = safeIndex(wheel, "joyfocus")
    local joypadId = joyfocus and safeIndex(joyfocus, "id") or nil
    if joypadId ~= nil then
        local selected = safeCall(javaObject, "getSliceIndexFromJoypad", joypadId)
        if type(selected) == "number" and selected >= 0 then return selected + 1 end
    end
    local mouseX = safeCall(wheel, "getMouseX")
    local mouseY = safeCall(wheel, "getMouseY")
    if type(mouseX) == "number" and type(mouseY) == "number" then
        local selected = safeCall(javaObject, "getSliceIndexFromMouse", mouseX, mouseY)
        if type(selected) == "number" and selected >= 0 then return selected + 1 end
    end
    return nil
end

local ICON_SIZE = 32
local ICON_GAP = 4
local SEPARATOR_WIDTH = 10
local PLUS_WIDTH = 12
-- Same offset as the zoom shortcut glyphs so both hint rows sit on the slice's
-- reserved second text line.
local ICON_ROW_Y_OFFSET = 8

local function drawTextCentered(self, text, centerX, y, font)
    local draw = safeIndex(self, "drawTextCentre")
    if type(draw) == "function" then
        pcall(draw, self, text, centerX, y, 1, 1, 1, 0.96, font)
    end
end

local function drawNativeTexture(self, texture, x, y)
    if not texture then return false end
    local draw = safeIndex(self, "drawTexture")
    if type(draw) ~= "function" then return false end
    return pcall(draw, self, texture, x, y, 0.96, 1, 1, 1)
end

local function drawSelectedShortcutIcons(overlay, wheel)
    local hints = safeIndex(wheel, "_gqsYHintSlices")
    if type(hints) ~= "table" then return end
    local index = currentSelectedSliceIndex(wheel)
    if not index then return end
    local directions = hints[index]
    if type(directions) ~= "table" or #directions == 0 then return end

    local yTexture = getNativeTexture({ "YButton" })
    if not yTexture then return end

    local textures = {}
    for _, item in ipairs(directions) do
        local texture = getNativeTexture(item.textures)
        if texture then textures[#textures + 1] = texture end
    end
    if #textures == 0 then return end

    local separatorCount = #textures - 1
    local width = ICON_SIZE + ICON_GAP + PLUS_WIDTH + ICON_GAP + (#textures * ICON_SIZE)
        + separatorCount * (SEPARATOR_WIDTH + ICON_GAP)
    local overlayWidth = tonumber(safeCall(overlay, "getWidth")) or tonumber(safeIndex(overlay, "width")) or 400
    local overlayHeight = tonumber(safeCall(overlay, "getHeight")) or tonumber(safeIndex(overlay, "height")) or 400
    local x = math.floor((overlayWidth - width) / 2)
    local y = math.floor(overlayHeight / 2 + ICON_ROW_Y_OFFSET)

    drawNativeTexture(overlay, yTexture, x, y)
    x = x + ICON_SIZE + ICON_GAP
    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil
    drawTextCentered(overlay, "+", x + PLUS_WIDTH / 2, y + 4, font)
    x = x + PLUS_WIDTH + ICON_GAP
    for iconIndex, texture in ipairs(textures) do
        if iconIndex > 1 then
            drawTextCentered(overlay, "/", x + SEPARATOR_WIDTH / 2, y + 4, font)
            x = x + SEPARATOR_WIDTH + ICON_GAP
        end
        drawNativeTexture(overlay, texture, x, y)
        x = x + ICON_SIZE
    end
end

local function setOverlayVisible(overlay, visible)
    if not overlay then return end

    -- Do not infer UIManager registration from isReallyVisible(): a freshly built
    -- ISUIElement can report itself visible before addToUIManager() has run.
    if visible then
        overlay.alwaysOnTop = true
        pcall(function() overlay:setAlwaysOnTop(true) end)
        pcall(function() overlay:setVisible(true) end)
        if not overlay._gqsYHintAddedToUIManager then
            local added = pcall(function() overlay:addToUIManager() end)
            if added then overlay._gqsYHintAddedToUIManager = true end
        end
        pcall(function() overlay:bringToTop() end)
    else
        pcall(function() overlay:setVisible(false) end)
        if overlay._gqsYHintAddedToUIManager then
            pcall(function() overlay:removeFromUIManager() end)
            overlay._gqsYHintAddedToUIManager = false
        end
    end
end

local function ensureOverlay(playerNum, wheel)
    local overlay = overlays[playerNum]
    if overlay or not Panel then return overlay end
    local x = tonumber(safeCall(wheel, "getX")) or tonumber(safeIndex(wheel, "x")) or 0
    local y = tonumber(safeCall(wheel, "getY")) or tonumber(safeIndex(wheel, "y")) or 0
    local w = tonumber(safeCall(wheel, "getWidth")) or tonumber(safeIndex(wheel, "width")) or 400
    local h = tonumber(safeCall(wheel, "getHeight")) or tonumber(safeIndex(wheel, "height")) or 400
    overlay = Panel:new(x, y, w, h)
    overlay:initialise()
    overlay.background = false
    overlay.border = false
    overlay.moveWithMouse = false
    overlay._gqsYHintPlayer = playerNum
    overlay.render = function(self)
        local activeWheel = activeWheels[self._gqsYHintPlayer]
        if activeWheel then drawSelectedShortcutIcons(self, activeWheel) end
    end
    overlays[playerNum] = overlay
    return overlay
end

local function wheelIsVisible(wheel)
    if not wheel then return false end
    local visible = safeCall(wheel, "isReallyVisible")
    if visible ~= nil then return visible == true end
    visible = safeCall(wheel, "getIsVisible")
    if visible ~= nil then return visible == true end
    visible = safeCall(wheel, "isVisible")
    if visible ~= nil then return visible == true end
    return safeIndex(wheel, "visible") == true
end

local function updateOverlays()
    for playerNum = 0, 3 do
        local wheel = activeWheels[playerNum]
        if wheelIsVisible(wheel) then
            local overlay = ensureOverlay(playerNum, wheel)
            if overlay then
                local x = tonumber(safeCall(wheel, "getX")) or tonumber(safeIndex(wheel, "x")) or 0
                local y = tonumber(safeCall(wheel, "getY")) or tonumber(safeIndex(wheel, "y")) or 0
                local w = tonumber(safeCall(wheel, "getWidth")) or tonumber(safeIndex(wheel, "width")) or 400
                local h = tonumber(safeCall(wheel, "getHeight")) or tonumber(safeIndex(wheel, "height")) or 400
                pcall(function() overlay:setX(x); overlay:setY(y); overlay:setWidth(w); overlay:setHeight(h) end)
                setOverlayVisible(overlay, true)
            end
        else
            setOverlayVisible(overlays[playerNum], false)
        end
    end
end

-- Reserve the second text line for every slice that has a configured shortcut and
-- remember which directions belong to which slice index.
local function prepareSliceHints(wheel)
    local slices = safeIndex(wheel, "slices")
    local setSliceText = safeIndex(wheel, "setSliceText")
    if type(slices) ~= "table" or type(setSliceText) ~= "function" then return end

    local hints = {}
    for index, slice in ipairs(slices) do
        local command = slice and slice.command
        local commandName = type(command) == "table" and command[3] or nil
        if commandName then
            local directions = getDirectionsForSlice(commandName)
            local label = slice and slice.text
            if directions and type(label) == "string" and label ~= "" then
                hints[index] = directions
                wheel:setSliceText(index, label .. "\n ")
            end
        end
    end
    wheel._gqsYHintSlices = hints
end

Wheel.addCommands = function(self, ...)
    local result = originalAddCommands(self, ...)
    local playerNum = tonumber(safeIndex(self, "playerNum")) or 0
    activeWheels[playerNum] = self
    local ok, err = pcall(prepareSliceHints, self)
    if not ok then
        local logger = rawget(_G, "GQSLog")
        if logger and type(logger.error) == "function" then
            logger.error("yShortcutWheel", "Unable to prepare Select-wheel Y shortcut hints: " .. tostring(err))
        end
    end
    return result
end

if Events and Events.OnTick then Events.OnTick.Add(updateOverlays) end
if Events and Events.OnResetLua then
    Events.OnResetLua.Add(function()
        activeWheels = {}
        for _, overlay in pairs(overlays) do pcall(function() overlay:removeFromUIManager() end) end
        overlays = {}
    end)
end

Wheel._gqsYShortcutWheelHintsInstalled = true
GQSYShortcutWheelHints = GQSYShortcutWheelHints or {}
GQSYShortcutWheelHints.VERSION = "1.5.1.32"
return GQSYShortcutWheelHints
