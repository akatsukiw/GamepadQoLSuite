-- Gamepad QoL Suite: hold B to stop fishing (v1.5.7).
--
-- Vanilla stops fishing the moment B is down for a single frame:
--   Fishing.Utils.isStopFishingButtonPressed(joypad) -> JoypadButton.B:isDown(joypad)
-- FishingManager:update() polls that every tick, so pressing B to close any panel
-- while fishing also cancels the fishing state -- and because the state is not
-- "Idle" at that point, it additionally runs fishingRod:damageLine() and eats rod
-- durability.
--
-- This module replaces that one function (it has exactly one caller, see
-- FishingManager.lua) and adds two guards:
--   1. If any UI element holds joypad focus, B belongs to that panel. Fishing
--      ignores it completely, so closing the health or build panel is free.
--   2. With world focus, B has to be held for HOLD_MS before fishing stops.
--
-- A "hold B to stop" prompt is drawn in the bottom-right corner while fishing,
-- with a segment ring filling around the B icon as the hold progresses.

pcall(require, "ISUI/ISButtonPrompt")

local HOLD_MS = 500

-- Per-joypad hold bookkeeping. Keyed by controller id, because split screen runs
-- one FishingManager per local player and each has its own joypad binding.
local holdStart = {}
local holdProgress = {}

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then fn("panelInfo", message) end
end

local function isEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.fishingHoldToStopEnabled
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok then return value == true end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Small helpers (kept local so this module has no cross-module dependencies)
-- ---------------------------------------------------------------------------
local function safeCall(object, methodName, ...)
    if object == nil then return nil end
    local okMethod, method = pcall(function() return object[methodName] end)
    if not okMethod or type(method) ~= "function" then return nil end
    local ok, result = pcall(method, object, ...)
    if ok then return result end
    return nil
end

local function getJoypadTexture(name)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    return textures and textures[name] or nil
end

local function textureSize(texture, maxSize)
    local width, height = maxSize, maxSize
    if texture then
        local okW, w = pcall(function() return texture:getWidth() end)
        local okH, h = pcall(function() return texture:getHeight() end)
        if okW and okH and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            local ratio = maxSize / math.max(w, h)
            width, height = w * ratio, h * ratio
        end
    end
    return width, height
end

local function measureText(text, font)
    local ok, width = pcall(function() return getTextManager():MeasureStringX(font, text) end)
    if ok and type(width) == "number" then return width end
    return #tostring(text or "") * 8
end

local function fontHeight(font)
    local ok, height = pcall(function() return getTextManager():getFontHeight(font) end)
    if ok and type(height) == "number" then return height end
    return 14
end

local function activePlayerCount()
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then return value end
    end
    return 1
end

local function playerNumForJoypad(joypadId)
    for playerNum = 0, activePlayerCount() - 1 do
        local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
        if player and type(player.getJoypadBind) == "function" then
            local ok, bind = pcall(player.getJoypadBind, player)
            if ok and bind == joypadId then return playerNum end
        end
    end
    return nil
end

-- Any focused UI element means the B press is meant for that panel. Fishing must
-- not interpret it as "stop" -- that is the whole bug being fixed here.
local function hasPanelFocus(joypadId)
    local playerNum = playerNumForJoypad(joypadId)
    if playerNum == nil then return false end
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok and focus ~= nil then return true end
    end
    local players = rawget(_G, "JoypadState") and JoypadState.players
    local data = players and players[playerNum + 1]
    return data ~= nil and data.focus ~= nil
end

local function getManagerForPlayer(player)
    if not player then return nil end
    local fishing = rawget(_G, "Fishing")
    local managers = fishing and fishing.ManagerInstances
    if type(managers) ~= "table" then return nil end

    local index = safeCall(player, "getPlayerNum")
    if type(isMultiplayer) == "function" then
        local ok, multiplayer = pcall(isMultiplayer)
        if ok and multiplayer == true then
            local username = safeCall(player, "getUsername")
            if username ~= nil then index = username end
        end
    end
    if index == nil then return nil end
    return managers[index]
end

local function isFishingActive(manager)
    if type(manager) ~= "table" or not manager.state or type(manager.states) ~= "table" then
        return false
    end
    return manager.state ~= manager.states["None"]
end

local function clearHold(joypadId)
    holdStart[joypadId] = nil
    holdProgress[joypadId] = nil
end

-- ---------------------------------------------------------------------------
-- Replacement for Fishing.Utils.isStopFishingButtonPressed
-- ---------------------------------------------------------------------------
local function installStopGuard()
    local fishing = rawget(_G, "Fishing")
    local utils = fishing and fishing.Utils
    if type(utils) ~= "table" or type(utils.isStopFishingButtonPressed) ~= "function" then
        return false
    end
    if utils._gqsHoldToStopInstalled then return true end

    local original = utils.isStopFishingButtonPressed
    utils._gqsOriginalStopFishingButtonPressed = original

    utils.isStopFishingButtonPressed = function(joypad)
        -- Keyboard players stop with movement / melee / cancel keys, never B, and
        -- they cannot close a panel by accident the same way. Leave them alone.
        if joypad == nil or joypad == -1 then
            return original(joypad)
        end
        if not isEnabled() then
            clearHold(joypad)
            return original(joypad)
        end

        local buttons = rawget(_G, "JoypadButton")
        local bButton = buttons and buttons.B
        local down = false
        if bButton and type(bButton.isDown) == "function" then
            local ok, value = pcall(bButton.isDown, bButton, joypad)
            down = ok and value == true
        end

        if not down then
            clearHold(joypad)
            return false
        end

        -- Guard 1: a focused panel owns B. Never treat it as "stop fishing".
        if hasPanelFocus(joypad) then
            clearHold(joypad)
            return false
        end

        -- Guard 2: require a deliberate hold.
        local now = getTimestampMs()
        local start = holdStart[joypad]
        if start == nil then
            holdStart[joypad] = now
            holdProgress[joypad] = 0
            return false
        end

        local elapsed = now - start
        holdProgress[joypad] = math.min(1, elapsed / HOLD_MS)
        return elapsed >= HOLD_MS
    end

    utils._gqsHoldToStopInstalled = true
    log("fishing stop guard installed: hold B for " .. tostring(HOLD_MS) .. "ms, ignored while a panel has focus")
    return true
end

-- ---------------------------------------------------------------------------
-- Bottom-right prompt with a hold ring
-- ---------------------------------------------------------------------------
local RING_SEGMENTS = 28
local RING_RADIUS = 12
local RING_DOT = 2.6
local PROMPT_ICON_SIZE = 18
local PROMPT_GAP = 5
local PROMPT_RIGHT_PADDING = 10
local PROMPT_BOTTOM_PADDING = 7

-- PZ has no arc primitive, so the ring is a circle of small filled squares. At
-- this radius/segment count the dots touch, which reads as a solid ring.
local function drawHoldRing(element, centerX, centerY, progress)
    for index = 1, RING_SEGMENTS do
        local t = (index - 1) / RING_SEGMENTS
        local angle = t * math.pi * 2 - math.pi / 2
        local x = centerX + math.cos(angle) * RING_RADIUS
        local y = centerY + math.sin(angle) * RING_RADIUS
        local r, g, b, a
        if t < progress then
            r, g, b, a = 1.0, 0.85, 0.25, 1.0
        else
            r, g, b, a = 0.55, 0.55, 0.55, 0.30
        end
        pcall(element.drawRect, element,
            x - RING_DOT / 2, y - RING_DOT / 2, RING_DOT, RING_DOT, a, r, g, b)
    end
end

local function drawFishingPrompt(element)
    if not isEnabled() then return end

    local player = element.player
    if not player then return end
    local manager = getManagerForPlayer(player)
    if not isFishingActive(manager) then
        -- Nothing is being fished: drop any half-finished hold so the ring does
        -- not linger on screen.
        local bind = safeCall(player, "getJoypadBind")
        if type(bind) == "number" then clearHold(bind) end
        return
    end

    local playerNum = tonumber(safeCall(player, "getPlayerNum")) or 0
    local joypadId = tonumber(safeCall(player, "getJoypadBind")) or -1

    local font = rawget(_G, "UIFont") and UIFont.Small or nil
    if not font then return end
    local lineHeight = fontHeight(font)
    local rowHeight = math.max(PROMPT_ICON_SIZE, lineHeight)

    local texture = getJoypadTexture("BButton")
    local iconW, iconH = textureSize(texture, PROMPT_ICON_SIZE)
    local label = getText("UI_GQOS_FishingHoldToStop")
    if label == "UI_GQOS_FishingHoldToStop" or label == nil or label == "" then
        label = "长按退出"
    end
    local textWidth = measureText(label, font)

    -- ISButtonPrompt is anchored at the viewport origin, but stay defensive and
    -- convert absolute coordinates the same way the other HUD hints do.
    local promptX = tonumber(safeCall(element, "getAbsoluteX")) or tonumber(element.x) or 0
    local promptY = tonumber(safeCall(element, "getAbsoluteY")) or tonumber(element.y) or 0
    local screenLeft = type(getPlayerScreenLeft) == "function" and (tonumber(getPlayerScreenLeft(playerNum)) or 0) or 0
    local screenTop = type(getPlayerScreenTop) == "function" and (tonumber(getPlayerScreenTop(playerNum)) or 0) or 0
    local screenWidth = type(getPlayerScreenWidth) == "function" and (tonumber(getPlayerScreenWidth(playerNum)) or 0) or 0
    local screenHeight = type(getPlayerScreenHeight) == "function" and (tonumber(getPlayerScreenHeight(playerNum)) or 0) or 0
    if screenWidth <= 0 or screenHeight <= 0 then
        local core = rawget(_G, "getCore") and getCore() or nil
        screenWidth = core and (tonumber(safeCall(core, "getScreenWidth")) or 0) or 0
        screenHeight = core and (tonumber(safeCall(core, "getScreenHeight")) or 0) or 0
    end

    local rightEdge = screenLeft + screenWidth - PROMPT_RIGHT_PADDING - promptX
    local rowTop = screenTop + screenHeight - rowHeight - PROMPT_BOTTOM_PADDING - promptY
    local leftX = rightEdge - (iconW + PROMPT_GAP + textWidth)

    local iconY = rowTop + math.floor((rowHeight - iconH) / 2)
    local textY = rowTop + math.floor((rowHeight - lineHeight) / 2)

    if texture then
        pcall(element.drawTextureScaled, element, texture, leftX, iconY, iconW, iconH, 1, 1, 1, 1)
    else
        pcall(element.drawText, element, "B", leftX, textY, 1, 1, 1, 1, font)
    end
    pcall(element.drawText, element, label, leftX + iconW + PROMPT_GAP, textY, 0.90, 0.90, 0.90, 1, font)

    local progress = joypadId >= 0 and holdProgress[joypadId] or nil
    if type(progress) == "number" and progress > 0 then
        drawHoldRing(element, leftX + iconW / 2, iconY + iconH / 2, progress)
    end
end

local function installPrompt()
    local promptClass = rawget(_G, "ISButtonPrompt")
    if type(promptClass) ~= "table" or type(promptClass.prerender) ~= "function" then
        return false
    end
    if promptClass._gqsFishingHoldPromptInstalled then return true end

    local originalPrerender = promptClass.prerender
    promptClass.prerender = function(self, ...)
        local result = { originalPrerender(self, ...) }
        pcall(drawFishingPrompt, self)
        return unpack(result)
    end
    promptClass._gqsFishingHoldPromptInstalled = true
    log("fishing hold prompt installed on ISButtonPrompt:prerender")
    return true
end

-- ---------------------------------------------------------------------------
-- Install / retry
-- ---------------------------------------------------------------------------
local function install()
    local guardReady = installStopGuard()
    local promptReady = installPrompt()
    return guardReady and promptReady
end

install()
if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        local fishing = rawget(_G, "Fishing")
        local utils = fishing and fishing.Utils
        if not utils or not utils._gqsHoldToStopInstalled then installStopGuard() end
        local promptClass = rawget(_G, "ISButtonPrompt")
        if promptClass and not promptClass._gqsFishingHoldPromptInstalled then installPrompt() end
    end)
end
