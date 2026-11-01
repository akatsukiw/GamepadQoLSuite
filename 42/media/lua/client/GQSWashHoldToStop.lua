-- Gamepad QoL Suite: hold B to stop washing (v1.5.10.6).
--
-- Vanilla cancels any running timed action the moment B is down for one frame.
-- Two different places do it, and both fire on the very first frame:
--   * CharacterJoypadButtonBinding.CancelAction is polled by the engine every
--     frame -> StopAllActionQueue(), regardless of which panel has focus.
--   * ISInventoryPage:onJoypadDown checks isPlayerDoingActionThatCanBeCancelled
--     BEFORE it does anything else, so pressing B inside an open container also
--     kills the wash even though the panel should own that press.
--
-- Washing yourself or a piece of clothing is a long timed action, so a single
-- stray B press wipes out all progress. This module gives the wash the same
-- treatment as fishing (see GQSFishingHoldToStop.lua):
--
--   1. While a wash action is the current action, the CancelAction binding is
--      suspended, so the engine can no longer cancel it on a B tap. Panels are
--      unaffected -- they read the raw Joypad.BButton event, not the binding.
--   2. With world focus, B has to be held for HOLD_MS before the wash stops.
--      The stop itself goes through the vanilla CancelAction() global.
--   3. With panel focus B belongs to that panel: nothing here reacts, and the
--      inventory page no longer cancels the wash either.
--
-- A "hold B to stop" prompt is drawn in the bottom-right corner while washing,
-- with a segment ring filling around the B icon as the hold progresses.

pcall(require, "ISUI/ISButtonPrompt")
pcall(require, "TimedActions/ISTimedActionQueue")

local HOLD_MS = 500
local TAG = "[GQS WashHold]"

-- Actions that count as "washing": your own body or a piece of clothing.
local WASH_CLASSES = { "ISWashYourself", "ISWashClothing", "ISWringClothing" }

-- CancelAction is one global binding shared by every joypad, so suspend and
-- restore are reference counted across players.
local suspendCount = 0
local states = {}

local function log(message)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and logger.log
    if type(fn) == "function" then fn("washHold", message) end
end

-- Always-visible diagnostics: only used for abnormal paths, so the volume stays
-- low and a report can be read without flipping a debug category first.
local function warn(message)
    print(TAG .. " " .. tostring(message))
end

local function isEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.washHoldToStopEnabled
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

local function stateFor(playerNum)
    local state = states[playerNum]
    if not state then
        state = { washing = false, holdStart = nil, progress = nil }
        states[playerNum] = state
    end
    return state
end

local function joypadIdFor(player)
    local bind = safeCall(player, "getJoypadBind")
    if type(bind) == "number" and bind >= 0 then return bind end
    return nil
end

local function isBDown(joypadId)
    local buttons = rawget(_G, "JoypadButton")
    local bButton = buttons and buttons.B
    if not bButton then return false end
    local ok, down = pcall(function() return bButton:isDown(joypadId) end)
    return ok and down == true
end

-- Any focused UI element means the B press belongs to that panel.
local function hasPanelFocus(playerNum)
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok and focus ~= nil then return true end
    end
    local players = rawget(_G, "JoypadState") and JoypadState.players
    local data = players and players[playerNum + 1]
    return data ~= nil and data.focus ~= nil
end

-- ---------------------------------------------------------------------------
-- Current action inspection
-- ---------------------------------------------------------------------------
local function currentAction(player)
    local queueClass = rawget(_G, "ISTimedActionQueue")
    if type(queueClass) ~= "table" then return nil end
    local ok, queue = pcall(queueClass.getTimedActionQueue, player)
    if not ok or type(queue) ~= "table" then return nil end
    local list = queue.queue
    if type(list) ~= "table" then return nil end
    return list[1]
end

-- ISBaseObject:derive() stamps every Lua action class with a Type string and
-- instances inherit it through __index, so Type is the reliable identity here.
-- The *global* instanceof() is the Java one: it only knows Java classes and
-- returns false for these Lua tables (ISBaseObject has its own instanceof for
-- them), which is exactly why the first version never detected a wash.
local function actionType(action)
    if action == nil then return nil end
    local kind = action.Type
    if type(kind) ~= "string" then return nil end
    return kind
end

local function isWashAction(action)
    local kind = actionType(action)
    if kind == nil then return false end
    for index = 1, #WASH_CLASSES do
        if kind == WASH_CLASSES[index] then return true end
    end
    return false
end

local function isWashingPlayer(playerNum)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if not player then return false end
    return isWashAction(currentAction(player))
end

-- ---------------------------------------------------------------------------
-- CancelAction binding suspend / restore
-- ---------------------------------------------------------------------------
local function cancelBinding()
    local bindings = rawget(_G, "CharacterJoypadButtonBinding")
    return bindings and bindings.CancelAction or nil
end

-- The button CancelAction pointed at before we suspended it. Restoring the
-- recorded object (instead of setDefault()) keeps a player's custom binding.
local savedCancelButton = nil

local function suspendCancelBinding()
    suspendCount = suspendCount + 1
    if suspendCount > 1 then return end

    local binding = cancelBinding()
    if not binding then
        suspendCount = 0
        warn("CharacterJoypadButtonBinding.CancelAction is unavailable; the wash cannot be protected")
        return
    end

    local okGet, button = pcall(function() return binding:getJoypadButton() end)
    savedCancelButton = okGet and button or nil

    -- setBinding(nil) makes JoypadButtonBinding.isDown() return false forever
    -- (it null-checks the button), which is exactly what we want: the engine
    -- can no longer cancel the wash on a B tap.
    local ok = pcall(function() binding:setBinding(nil) end)
    if not ok then
        suspendCount = 0
        savedCancelButton = nil
        warn("could not suspend the CancelAction binding; B still cancels the wash")
        return
    end
end

local function restoreCancelBinding()
    if suspendCount <= 0 then return end
    suspendCount = suspendCount - 1
    if suspendCount > 0 then return end

    local binding = cancelBinding()
    if not binding then return end

    local ok = false
    if savedCancelButton ~= nil then
        ok = pcall(function() binding:setBinding(savedCancelButton) end)
    end
    -- Fallback: setDefault() passes no argument at all, so it cannot fail on
    -- Kahlua arity even if the recorded button object went stale.
    if not ok then
        ok = pcall(function() binding:setDefault() end)
    end
    savedCancelButton = nil
    if ok then
        log("CancelAction binding restored")
    else
        warn("could not restore the CancelAction binding; B may stop working until restart")
    end
end

-- ---------------------------------------------------------------------------
-- Per-tick state machine
-- ---------------------------------------------------------------------------
local function clearHold(state)
    state.holdStart = nil
    state.progress = nil
end

local function stopWash(playerNum)
    local cancel = rawget(_G, "CancelAction")
    if type(cancel) == "function" then
        local ok = pcall(cancel, playerNum)
        if ok then return true end
    end
    -- Fallback: the Lua global is defined in MainScreen.lua, but it bails out
    -- when the pause menu is up. Stop the queue directly in that case.
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if player then
        local ok = pcall(function() player:StopAllActionQueue() end)
        if ok then return true end
    end
    return false
end

local function updatePlayer(playerNum)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if not player then return end

    local state = stateFor(playerNum)
    local washing = isEnabled() and isWashAction(currentAction(player))

    if not washing then
        if state.washing then
            state.washing = false
            restoreCancelBinding()
        end
        clearHold(state)
        return
    end

    if not state.washing then
        state.washing = true
        local kind = actionType(currentAction(player))
        suspendCancelBinding()
        -- Normal path: routed through the washHold debug category, silent by
        -- default. Flip it on in GQSDebugLog.lua when a report needs tracing.
        log("wash detected: " .. tostring(kind) .. " -> CancelAction binding suspended")
    end

    local joypadId = joypadIdFor(player)
    if joypadId == nil then
        clearHold(state)
        return
    end

    -- Guard 1: a focused panel owns B. Never read it as "stop washing".
    if hasPanelFocus(playerNum) then
        clearHold(state)
        return
    end

    if not isBDown(joypadId) then
        clearHold(state)
        return
    end

    -- Guard 2: require a deliberate hold.
    local now = getTimestampMs()
    if state.holdStart == nil then
        state.holdStart = now
        state.progress = 0
        return
    end

    local elapsed = now - state.holdStart
    state.progress = math.min(1, elapsed / HOLD_MS)
    if elapsed < HOLD_MS then return end

    clearHold(state)
    log("hold B reached " .. tostring(HOLD_MS) .. "ms, stopping the wash (player=" .. tostring(playerNum) .. ")")
    if not stopWash(playerNum) then
        warn("failed to stop the wash (player=" .. tostring(playerNum) .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- Inventory page: B belongs to the panel while a wash is running
-- ---------------------------------------------------------------------------
-- Vanilla ISInventoryPage:onJoypadDown cancels the running action before it
-- expands/collapses the pane, which is why an open container killed the wash.
-- While washing, hand B straight to the pane instead.
local function wrapPageClass(pageClass)
    if type(pageClass) ~= "table" then return end
    local original = pageClass.onJoypadDown
    if type(original) ~= "function" then return end
    -- Another mod (CleanUI, or our own multi-select module reloaded later) may
    -- have replaced the handler; only skip when OUR wrapper is still in place.
    if pageClass._gqsWashWrapper ~= nil and original == pageClass._gqsWashWrapper then
        return
    end

    local wrapper = function(self, button, ...)
        if isEnabled() then
            local joypad = rawget(_G, "Joypad")
            local bButton = joypad and (joypad.BButton or joypad.B) or nil
            if bButton ~= nil and button == bButton
                and isWashingPlayer(tonumber(self.player) or 0) then
                -- Vanilla sets this on every joypad press; the panel handlers
                -- read it, so keep it in sync before short-circuiting.
                local contextMenu = rawget(_G, "ISContextMenu")
                if contextMenu then contextMenu.globalPlayerContext = self.player end
                local pane = self.inventoryPane
                if pane and type(pane.doJoypadExpandCollapse) == "function" then
                    pane:doJoypadExpandCollapse()
                end
                return
            end
        end
        return original(self, button, ...)
    end

    pageClass.onJoypadDown = wrapper
    pageClass._gqsWashWrapper = wrapper
end

-- ---------------------------------------------------------------------------
-- Bottom-right prompt with a hold ring
-- ---------------------------------------------------------------------------
-- Same geometry as the fishing prompt (GQSFishingHoldToStop.lua): one row above
-- the vanilla RB prompt, right-aligned with the native A/B column.
local ROW_HGT = 32
local BUTTON_WID = 32
local TEXT_PAD_X = 11
local RIGHT_MARGIN = 16
local PROMPT_ICON_SIZE = 28
local PROMPT_ROW_OFFSET = 2

local RING_SEGMENTS = 28
local RING_RADIUS = PROMPT_ICON_SIZE / 2 + PROMPT_ROW_OFFSET
local RING_DOT = 2.6

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

local function viewportFor(playerNum)
    local left = type(getPlayerScreenLeft) == "function" and tonumber(getPlayerScreenLeft(playerNum)) or nil
    local top = type(getPlayerScreenTop) == "function" and tonumber(getPlayerScreenTop(playerNum)) or nil
    local width = type(getPlayerScreenWidth) == "function" and tonumber(getPlayerScreenWidth(playerNum)) or nil
    local height = type(getPlayerScreenHeight) == "function" and tonumber(getPlayerScreenHeight(playerNum)) or nil
    if not width or width <= 0 or not height or height <= 0 then
        local core = rawget(_G, "getCore") and getCore() or nil
        width = core and tonumber(safeCall(core, "getScreenWidth")) or 1280
        height = core and tonumber(safeCall(core, "getScreenHeight")) or 720
        left, top = 0, 0
    end
    return tonumber(left) or 0, tonumber(top) or 0, width, height
end

local function drawWashPrompt(element)
    if not isEnabled() then return end

    -- ISButtonPrompt.player is the player *number*, not an IsoPlayer.
    local playerNum = tonumber(element.player)
    if playerNum == nil then return end

    local state = states[playerNum]
    if not state or not state.washing then return end

    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if not player then return end

    local joypadId = joypadIdFor(player)
    -- Keyboard players have no B button; the prompt would be misleading.
    if joypadId == nil then return end

    -- With a focused panel B belongs to that panel, so the world prompt hides.
    if hasPanelFocus(playerNum) then return end

    local font = rawget(_G, "UIFont") and (UIFont.NewLarge or UIFont.Small) or nil
    if not font then return end
    local lineHeight = fontHeight(font)

    local texture = getJoypadTexture("BButton")
    local iconW, iconH = textureSize(texture, PROMPT_ICON_SIZE)
    local label = getText("UI_GQOS_WashHoldToStop")
    if label == "UI_GQOS_WashHoldToStop" or label == nil or label == "" then
        label = "长按退出清洗"
    end

    local screenLeft, screenTop, screenWidth, screenHeight = viewportFor(playerNum)

    local y1 = screenTop + (screenHeight - 64) - 16
    local rowTop = y1 - ROW_HGT * 2
    local iconX = screenLeft + screenWidth - RIGHT_MARGIN - BUTTON_WID

    local originX = tonumber(safeCall(element, "getAbsoluteX")) or 0
    local originY = tonumber(safeCall(element, "getAbsoluteY")) or 0
    local drawX = iconX - originX
    local drawTop = rowTop - originY

    local iconY = drawTop + math.floor((ROW_HGT - iconH) / 2)
    local textY = drawTop + math.floor((ROW_HGT - lineHeight) / 2)

    if texture then
        pcall(element.drawTextureScaled, element, texture, drawX, iconY, iconW, iconH, 1, 1, 1, 1)
    else
        pcall(element.drawText, element, "B", drawX, textY, 1, 1, 1, 1, font)
    end
    pcall(element.drawTextRight, element, label, drawX - TEXT_PAD_X, textY, 0.90, 0.90, 0.90, 1, font)

    local progress = state.progress
    if type(progress) == "number" and progress > 0 then
        drawHoldRing(element, drawX + iconW / 2, iconY + iconH / 2, progress)
    end
end

local function installPrompt()
    local promptClass = rawget(_G, "ISButtonPrompt")
    if type(promptClass) ~= "table" or type(promptClass.prerender) ~= "function" then
        return false
    end
    if promptClass._gqsWashHoldPromptInstalled then return true end

    local originalPrerender = promptClass.prerender
    promptClass.prerender = function(self, ...)
        local result = { originalPrerender(self, ...) }
        pcall(drawWashPrompt, self)
        return unpack(result)
    end
    promptClass._gqsWashHoldPromptInstalled = true
    log("wash hold prompt installed on ISButtonPrompt:prerender")
    return true
end

-- ---------------------------------------------------------------------------
-- Install / retry
-- ---------------------------------------------------------------------------
local function install()
    wrapPageClass(rawget(_G, "ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Clean_ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPage"))
    installPrompt()
end

local function resetAll()
    states = {}
    if suspendCount > 0 then
        suspendCount = 1
        restoreCancelBinding()
    end
end

-- Safety net: if a Lua error ever strands the binding in the suspended state,
-- put it back instead of leaving the player without B until a restart.
local guardCounter = 0
local function guardBindingLeak()
    if suspendCount > 0 then return end
    local binding = cancelBinding()
    if not binding then return end
    local ok, button = pcall(function() return binding:getJoypadButton() end)
    if ok and button == nil then
        warn("CancelAction binding was left suspended with no active wash; restoring it")
        savedCancelButton = nil
        pcall(function() binding:setDefault() end)
    end
end

install()
log("loaded: hold B " .. tostring(HOLD_MS) .. "ms to stop washing")
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() resetAll(); install() end) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end

if Events and Events.OnTick then
    Events.OnTick.Add(function()
        local total = activePlayerCount()
        for playerNum = 0, total - 1 do
            pcall(updatePlayer, playerNum)
        end

        -- Vanilla reloads the page classes when the UI is rebuilt; re-hook then.
        wrapPageClass(rawget(_G, "ISInventoryPage"))
        local promptClass = rawget(_G, "ISButtonPrompt")
        if promptClass and not promptClass._gqsWashHoldPromptInstalled then installPrompt() end

        guardCounter = guardCounter + 1
        if guardCounter >= 60 then
            guardCounter = 0
            pcall(guardBindingLeak)
        end
    end)
end
