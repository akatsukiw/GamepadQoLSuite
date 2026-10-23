-- Gamepad QoL Suite: contextual native-button glyphs on vanilla Select-wheel zoom slices.
-- The wheel's center label keeps the vanilla zoom percentage; a separate transparent
-- always-on-top overlay draws native shortcut glyphs only while a zoom slice is selected.
-- No input handling or zoom command is replaced.

pcall(require, "ISUI/ISBackButtonWheel")
pcall(require, "ISUI/ISPanel")

local Wheel = rawget(_G, "ISBackButtonWheel")
local Panel = rawget(_G, "ISPanel")
if type(Wheel) ~= "table" or type(Wheel.addCommands) ~= "function"
        or Wheel._gqsZoomRadialShortcutHintsInstalled then
    return
end

local originalAddCommands = Wheel.addCommands
local ZOOM_ACTION_BY_COMMAND = {
    ZoomMinus = "zoomOut",
    ZoomPlus = "zoomIn",
}
local DIRECTION_OPTIONS = {
    { name = "Left", option = "rbDpadLeftAction", textures = { "DPadLeft", "DpadLeft", "LeftArrow" } },
    { name = "Right", option = "rbDpadRightAction", textures = { "DPadRight", "DpadRight", "RightArrow" } },
}
local BUTTON_OPTIONS = {
    { name = "Y", option = "rbButtonYAction", texture = "YButton" },
    { name = "A", option = "rbButtonAAction", texture = "AButton" },
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

local function readEnabled(options)
    local value = readOption(options and safeIndex(options, "rbExtensionsEnabled"))
    if value == nil then return true end
    return not (value == false or value == 0 or value == "0" or value == "false")
end

local function getButtonAction(options, button)
    local shared = rawget(_G, "GQS_RBControls")
    local resolver = shared and safeIndex(shared, "getButtonAction")
    if type(resolver) == "function" then
        local ok, action = pcall(resolver, button)
        if ok and type(action) == "string" then return action end
    end
    local key = button == "Y" and "rbButtonYAction" or "rbButtonAAction"
    if not options or not readEnabled(options) then return "none" end
    local index = tonumber(readOption(safeIndex(options, key)))
    if index == 1 then return "none" end
    if index == 2 then return "zoomIn" end
    if index == 3 then return "zoomOut" end
    return button == "Y" and "zoomIn" or "zoomOut"
end

local function getDirectionAction(options, direction)
    local shared = rawget(_G, "GQS_RBControls")
    local resolver = shared and safeIndex(shared, "getAction")
    if type(resolver) == "function" then
        local ok, action = pcall(resolver, direction)
        if ok and type(action) == "string" then return action end
    end
    if not options or not readEnabled(options) then return "none" end
    local key = direction == "Left" and "rbDpadLeftAction" or "rbDpadRightAction"
    local index = tonumber(readOption(safeIndex(options, key)))
    if index == 1 then return "none" end
    if index == 2 then return "zoomIn" end
    if index == 3 then return "zoomOut" end
    if index == 4 or index == 5 then return direction == "Left" and "zoomOut" or "zoomIn" end
    return direction == "Left" and "zoomOut" or "zoomIn"
end

local function getConfiguredButtons(actionName)
    local result = {}
    local options = getOptions()
    if options and not readEnabled(options) then return result end
    -- The fallback defaults match GQSRBZoom when the settings table is not ready yet.
    for _, item in ipairs(BUTTON_OPTIONS) do
        local action = getButtonAction(options, item.name)
        if action == actionName then
            result[#result + 1] = { type = "button", name = item.name, textureNames = { item.texture } }
        end
    end
    for _, item in ipairs(DIRECTION_OPTIONS) do
        local action = getDirectionAction(options, item.name)
        if action == actionName then
            result[#result + 1] = { type = "direction", name = item.name, textureNames = item.textures }
        end
    end
    return result
end

local function getNativeTexture(names)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and safeIndex(joypad, "Texture")
    if not textures then return nil end
    for _, name in ipairs(names or {}) do
        local texture = safeIndex(textures, name)
        if texture ~= nil then
            -- Known vanilla prompt keys are valid getter objects; other aliases are
            -- used only if they resolve to a concrete texture path.
            if name == "RBumper" or name == "AButton" or name == "YButton" then return texture end
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

local function getSelectedZoomAction(wheel)
    local index = currentSelectedSliceIndex(wheel)
    if not index then return nil end
    local slices = safeIndex(wheel, "slices")
    local slice = type(slices) == "table" and slices[index] or nil
    local command = slice and safeIndex(slice, "command") or nil
    local commandName = type(command) == "table" and command[3] or nil
    return ZOOM_ACTION_BY_COMMAND[commandName]
end

local ICON_SIZE = 32
local ICON_GAP = 4
local SEPARATOR_WIDTH = 10
local PLUS_WIDTH = 12
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
    local ok = pcall(draw, self, texture, x, y, 0.96, 1, 1, 1)
    return ok
end

local function drawSelectedShortcutIcons(overlay, wheel)
    local actionName = getSelectedZoomAction(wheel)
    if not actionName then return end
    local configured = getConfiguredButtons(actionName)
    if #configured == 0 then return end

    local rbTexture = getNativeTexture({ "RBumper" })
    if not rbTexture then return end
    local textures = {}
    for _, item in ipairs(configured) do
        local tex = getNativeTexture(item.textureNames)
        if tex then textures[#textures + 1] = tex end
    end
    if #textures == 0 then return end

    local separatorCount = #textures - 1
    local width = ICON_SIZE + ICON_GAP + PLUS_WIDTH + ICON_GAP + (#textures * ICON_SIZE)
        + separatorCount * (SEPARATOR_WIDTH + ICON_GAP)
    local overlayWidth = tonumber(safeCall(overlay, "getWidth")) or tonumber(safeIndex(overlay, "width")) or 400
    local overlayHeight = tonumber(safeCall(overlay, "getHeight")) or tonumber(safeIndex(overlay, "height")) or 400
    local x = math.floor((overlayWidth - width) / 2)
    local y = math.floor(overlayHeight / 2 + ICON_ROW_Y_OFFSET)

    drawNativeTexture(overlay, rbTexture, x, y)
    x = x + ICON_SIZE + ICON_GAP
    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil
    drawTextCentered(overlay, "+", x + PLUS_WIDTH / 2, y + 4, font)
    x = x + PLUS_WIDTH + ICON_GAP
    for index, texture in ipairs(textures) do
        if index > 1 then
            drawTextCentered(overlay, "/", x + SEPARATOR_WIDTH / 2, y + 4, font)
            x = x + SEPARATOR_WIDTH + ICON_GAP
        end
        drawNativeTexture(overlay, texture, x, y)
        x = x + ICON_SIZE
    end
end

local function setOverlayVisible(overlay, visible)
    if not overlay then return end

    -- Do not use isReallyVisible() to infer UIManager registration. A freshly
    -- constructed ISUIElement can report itself visible before it is actually
    -- added to UIManager; doing so caused the overlay to skip addToUIManager()
    -- and made every contextual glyph disappear in-game.
    if visible then
        overlay.alwaysOnTop = true
        pcall(function() overlay:setAlwaysOnTop(true) end)
        pcall(function() overlay:setVisible(true) end)

        if not overlay._gqsZoomShortcutAddedToUIManager then
            local added = pcall(function() overlay:addToUIManager() end)
            if added then overlay._gqsZoomShortcutAddedToUIManager = true end
        end
        pcall(function() overlay:bringToTop() end)
    else
        pcall(function() overlay:setVisible(false) end)
        if overlay._gqsZoomShortcutAddedToUIManager then
            pcall(function() overlay:removeFromUIManager() end)
            overlay._gqsZoomShortcutAddedToUIManager = false
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
    overlay._gqsZoomWheelPlayer = playerNum
    overlay.render = function(self)
        local activeWheel = activeWheels[self._gqsZoomWheelPlayer]
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
        local visible = wheelIsVisible(wheel)
        if visible then
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

local function appendShortcutLine(wheel)
    if type(safeIndex(wheel, "slices")) ~= "table" or type(safeIndex(wheel, "setSliceText")) ~= "function" then return end
    for index, slice in ipairs(wheel.slices) do
        local command = slice and slice.command
        local commandName = type(command) == "table" and command[3] or nil
        local actionName = ZOOM_ACTION_BY_COMMAND[commandName]
        local label = slice and slice.text
        if actionName and type(label) == "string" and label ~= "" then
            if #getConfiguredButtons(actionName) > 0 then
                wheel:setSliceText(index, label .. "\n ")
            end
        end
    end
end

Wheel.addCommands = function(self, ...)
    local result = originalAddCommands(self, ...)
    local playerNum = tonumber(safeIndex(self, "playerNum")) or 0
    activeWheels[playerNum] = self
    local ok, err = pcall(appendShortcutLine, self)
    if not ok then
        local logger = rawget(_G, "GQSLog")
        if logger and type(logger.error) == "function" then
            logger.error("rbZoom", "Unable to prepare Select-wheel zoom shortcut icons: " .. tostring(err))
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

Wheel._gqsZoomRadialShortcutHintsInstalled = true
GQSZoomRadialShortcutHints = GQSZoomRadialShortcutHints or {}
GQSZoomRadialShortcutHints.VERSION = "1.5.1.27"
return GQSZoomRadialShortcutHints
