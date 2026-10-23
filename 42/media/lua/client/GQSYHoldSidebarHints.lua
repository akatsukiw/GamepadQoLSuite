-- Gamepad QoL Suite: hold-Y direction glyphs beside the vanilla sidebar panel icons.
--
-- While a Y gesture is active in world focus, each mapped panel icon gets the
-- configured D-pad glyph immediately to its right, so the player can see which
-- direction opens which panel without leaving the world view. Nothing is drawn
-- unless Y is held, and no sidebar button, image or click handler is replaced.
--
-- Positions are read from the live ISButton children of ISEquippedItem, so
-- resolution, UI scale, split screen and the sidebar size option all follow
-- automatically. Glyph size scales with the current sidebar icon height.

pcall(require, "ISUI/ISEquippedItem")

local Equipped = rawget(_G, "ISEquippedItem")
if type(Equipped) ~= "table" or type(Equipped.prerender) ~= "function"
        or Equipped._gqsHoldSidebarHintsInstalled then
    return
end

local originalPrerender = Equipped.prerender

-- Sidebar button -> Y shortcut actions anchored to it.
-- Health and PlayerInfo both live in the player-info window, so they share the
-- heart icon and are drawn side by side on one row, in the order listed below.
-- Fitness has no sidebar icon and is intentionally not shown.
local ANCHORS = {
    { button = "healthBtn",   actions = { "health", "playerInfo" } },
    { button = "invBtn",      actions = { "inventory" } },
    { button = "buildBtn",    actions = { "building" } },
    { button = "craftingBtn", actions = { "crafting" } },
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

-- Declaration order is also the left-to-right order when one icon carries more
-- than one direction.
local DIRECTION_OPTIONS = {
    { name = "Up", option = "yShortcutUp", textures = { "DPadUp", "DpadUp", "UpArrow" } },
    { name = "Down", option = "yShortcutDown", textures = { "DPadDown", "DpadDown", "DownArrow" } },
    { name = "Left", option = "yShortcutLeft", textures = { "DPadLeft", "DpadLeft", "LeftArrow" } },
    { name = "Right", option = "yShortcutRight", textures = { "DPadRight", "DpadRight", "RightArrow" } },
}

local KNOWN_PROMPT_KEYS = {
    YButton = true,
    AButton = true,
    BButton = true,
    XButton = true,
    RBumper = true,
    LBumper = true,
}

local GLYPH_HEIGHT_RATIO = 0.8
local GLYPH_MIN_SIZE = 16
local GLYPH_ALPHA = 0.96

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

local function getConfiguredAction(optionKey)
    local options = getOptions()
    local index = tonumber(readOption(options and safeIndex(options, optionKey)))
    if not index then index = DEFAULT_INDEX[optionKey] end
    return ACTION_BY_INDEX[index] or "disabled"
end

-- The gesture state machine stays the single source of truth: it already knows
-- about the master switch, the Y+D-pad switch, tutorial mode, world-map focus and
-- whether a direction has been consumed for this press.
local function isHintActive(playerNum)
    local module = rawget(_G, "GQSPanelQuickSelect")
    local query = module and safeIndex(module, "isYShortcutHintActive") or nil
    if type(query) ~= "function" then return false end
    local ok, active = pcall(query, playerNum)
    return ok and active == true
end

local function getDirectionsForActions(actions)
    if type(actions) ~= "table" or #actions == 0 then return nil end
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

local function getPlayerNumFor(self)
    local playerNum = tonumber(safeIndex(self, "playerNum"))
    if playerNum then return playerNum end
    local chr = safeIndex(self, "chr")
    if chr and type(safeIndex(chr, "getPlayerNum")) == "function" then
        local ok, value = pcall(function() return chr:getPlayerNum() end)
        if ok then return tonumber(value) end
    end
    return nil
end

local function drawAnchorGlyphs(self, button, actions)
    local directions = getDirectionsForActions(actions)
    if not directions then return end

    local textures = {}
    for _, item in ipairs(directions) do
        local texture = getNativeTexture(item.textures)
        if texture then textures[#textures + 1] = texture end
    end
    if #textures == 0 then return end

    local bx = tonumber(safeCall(button, "getX")) or 0
    local by = tonumber(safeCall(button, "getY")) or 0
    local bw = tonumber(safeCall(button, "getWidth")) or 0
    local bh = tonumber(safeCall(button, "getHeight")) or 0
    if bh <= 0 then return end

    -- Scale with the sidebar size option so the glyph keeps the same visual
    -- weight as the panel icon it belongs to. Multiple directions on one icon are
    -- laid out on a single row to the right, separated by a small gap.
    local size = math.max(GLYPH_MIN_SIZE, math.floor(bh * GLYPH_HEIGHT_RATIO))
    local gapX = math.max(4, math.floor(size * 0.15))
    local x = bx + bw + gapX
    local y = by + math.floor((bh - size) / 2)

    local draw = safeIndex(self, "drawTextureScaled")
    if type(draw) ~= "function" then return end
    for _, texture in ipairs(textures) do
        pcall(draw, self, texture, x, y, size, size, GLYPH_ALPHA, 1, 1, 1)
        x = x + size + gapX
    end
end

local function drawHints(self)
    -- Vanilla returns early from prerender while the sidebar is still building;
    -- invBtn is the first panel button and therefore a reliable readiness marker.
    if safeIndex(self, "invBtn") == nil then return end
    if safeCall(self, "isVisible") == false then return end

    local playerNum = getPlayerNumFor(self)
    if not playerNum then return end
    if not isHintActive(playerNum) then return end

    for _, anchor in ipairs(ANCHORS) do
        local button = safeIndex(self, anchor.button)
        if type(button) == "table" and type(safeIndex(button, "getX")) == "function" then
            drawAnchorGlyphs(self, button, anchor.actions)
        end
    end
end

Equipped.prerender = function(self, ...)
    local result = originalPrerender(self, ...)
    local ok, err = pcall(drawHints, self)
    if not ok then
        local logger = rawget(_G, "GQSLog")
        if logger and type(logger.error) == "function" then
            logger.error("yHoldSidebar", "Unable to draw hold-Y sidebar hints: " .. tostring(err))
        end
    end
    return result
end

Equipped._gqsHoldSidebarHintsInstalled = true
GQSYHoldSidebarHints = GQSYHoldSidebarHints or {}
GQSYHoldSidebarHints.VERSION = "1.5.1.33"
return GQSYHoldSidebarHints
