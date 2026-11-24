-- Gamepad QoL Suite: hold B to stop a running exercise (v1.5.14.19).
--
-- A stray B press during an exercise cancels the whole workout instantly via
-- CharacterJoypadButtonBinding.CancelAction (polled by the engine every frame).
-- This module gives exercise the same treatment as washing/fishing:
--
--   1. While an ISFitnessAction is running, the CancelAction binding is
--      suspended (shared with the wash module through its exported functions).
--      This does NOT touch the fitness panel's own B key: while that panel has
--      focus, B keeps its vanilla Cancel behaviour exactly as before.
--   2. With world focus, B has to be held for HOLD_MS before the exercise stops.
--      The stop goes through the vanilla CancelAction() global.
--   3. With any other panel focused (inventory, etc.) B belongs to that panel:
--      nothing here reacts.
--
-- A "hold B to stop" prompt is drawn in the bottom-right corner while exercising,
-- with a segment ring filling around the B icon as the hold progresses.

pcall(require, "ISUI/ISButtonPrompt")
pcall(require, "TimedActions/ISTimedActionQueue")

local HOLD_MS = 500
local TAG = "[GQS FitnessHold]"

-- CancelAction is a single global binding shared with the wash module. Reuse
-- its exported suspend/restore so the two modules share one refcount and one
-- saved button; otherwise one restoring it could re-enable cancellation while
-- the other still needs it suspended.
--
-- Read the module at CALL time, never at load time: this file (GQS...) sorts
-- before GQSWashHoldToStop.lua, so a load-time rawget() would cache nil and
-- leave the binding unsuspended -- B would still cancel on a single tap.
local function washHoldModule()
    return rawget(_G, "GQSWashHoldToStop")
end

local states = {}

local function log(message)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and logger.log
    if type(fn) == "function" then fn("fitnessHold", message) end
end

-- Always-visible diagnostics: only used for abnormal paths, so the volume stays
-- low and a report can be read without flipping a debug category first.
local function warn(message)
    print(TAG .. " " .. tostring(message))
end

local function isEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.fitnessHoldToStopEnabled
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
        state = { exercising = false, holdStart = nil, progress = nil }
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
-- returns false for these Lua tables, so compare Type instead.
local function actionType(action)
    if action == nil then return nil end
    local kind = action.Type
    if type(kind) ~= "string" then return nil end
    return kind
end

-- A workout queues ISFitnessAction. addGetUpAndThen() may wrap it, so accept
-- both the direct action and a wrapper whose inner action is a fitness one.
local function isFitnessAction(action)
    if action == nil then return false end
    if actionType(action) == "ISFitnessAction" then return true end
    local inner = action.action
    if inner ~= nil and actionType(inner) == "ISFitnessAction" then return true end
    return false
end

local function isExercisingPlayer(playerNum)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if not player then return false end
    return isFitnessAction(currentAction(player))
end

-- ---------------------------------------------------------------------------
-- CancelAction binding suspend / restore (shared with the wash module)
-- ---------------------------------------------------------------------------
-- CancelAction is one global binding. GQSWashHoldToStop owns the refcount and
-- the saved button; delegate to it so a wash and a workout cannot undo each
-- other's suspension. If the wash module is absent, fall back to doing nothing
-- (an unprotected B tap still cancels the workout, i.e. vanilla behaviour).
local function suspendCancelBinding()
    local module = washHoldModule()
    local fn = module and module.suspendCancelBinding
    if type(fn) ~= "function" then
        warn("wash hold module not available yet; cannot protect the exercise")
        return false
    end
    local ok, err = pcall(fn)
    if not ok then
        warn("could not suspend the CancelAction binding: " .. tostring(err))
        return false
    end
    return true
end

local function restoreCancelBinding()
    local module = washHoldModule()
    local fn = module and module.restoreCancelBinding
    if type(fn) ~= "function" then return end
    pcall(fn)
end

-- ---------------------------------------------------------------------------
-- Per-tick state machine
-- ---------------------------------------------------------------------------
local function clearHold(state)
    state.holdStart = nil
    state.progress = nil
end

local function stopExercise(playerNum)
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
    local exercising = isEnabled() and isFitnessAction(currentAction(player))

    if not exercising then
        if state.exercising then
            state.exercising = false
            if state.suspended then
                restoreCancelBinding()
                state.suspended = false
            end
        end
        clearHold(state)
        return
    end

    if not state.exercising then
        state.exercising = true
        local kind = actionType(currentAction(player))
        -- Normal path: routed through the fitnessHold debug category, silent by
        -- default. Flip it on in GQSDebugLog.lua when a report needs tracing.
        log("exercise detected: " .. tostring(kind))
        state.suspended = false
    end

    -- Keep retrying until the binding is actually suspended. A single attempt
    -- on the detection frame can fail if the wash module's export is not ready
    -- yet (load order), which would leave B cancelling on one tap.
    if not state.suspended then
        state.suspended = suspendCancelBinding()
        if state.suspended then
            log("CancelAction binding suspended for exercise")
        end
    end

    local joypadId = joypadIdFor(player)
    if joypadId == nil then
        clearHold(state)
        return
    end

    -- Guard 1: a focused panel owns B. Never read it as "stop exercising".
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
    log("hold B reached " .. tostring(HOLD_MS) .. "ms, stopping the exercise (player=" .. tostring(playerNum) .. ")")
    if not stopExercise(playerNum) then
        warn("failed to stop the exercise (player=" .. tostring(playerNum) .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- Inventory page: B belongs to the panel while an exercise is running
-- ---------------------------------------------------------------------------
-- Vanilla ISInventoryPage:onJoypadDown cancels the running action before it
-- expands/collapses the pane, which is why an open container can kill a workout.
-- While exercising, hand B straight to the pane instead. The wash module wraps
-- this same method too; the separate marker keeps both wrappers coexisting.
local function wrapPageClass(pageClass)
    if type(pageClass) ~= "table" then return end
    local original = pageClass.onJoypadDown
    if type(original) ~= "function" then return end
    -- Another mod (CleanUI, or our own multi-select module reloaded later) may
    -- have replaced the handler; only skip when OUR wrapper is still in place.
    if pageClass._gqsFitnessHoldWrapper ~= nil and original == pageClass._gqsFitnessHoldWrapper then
        return
    end

    local wrapper = function(self, button, ...)
        if isEnabled() then
            local joypad = rawget(_G, "Joypad")
            local bButton = joypad and (joypad.BButton or joypad.B) or nil
            if bButton ~= nil and button == bButton
                and isExercisingPlayer(tonumber(self.player) or 0) then
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
    pageClass._gqsFitnessHoldWrapper = wrapper
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

local function drawFitnessHoldPrompt(element)
    if not isEnabled() then return end

    -- ISButtonPrompt.player is the player *number*, not an IsoPlayer.
    local playerNum = tonumber(element.player)
    if playerNum == nil then return end

    local state = states[playerNum]
    if not state or not state.exercising then return end

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
    local label = getText("UI_GQOS_FitnessHoldToStop")
    if label == "UI_GQOS_FitnessHoldToStop" or label == nil or label == "" then
        label = "长按退出锻炼"
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
    if promptClass._gqsFitnessHoldPromptInstalled then return true end

    local originalPrerender = promptClass.prerender
    promptClass.prerender = function(self, ...)
        local result = { originalPrerender(self, ...) }
        pcall(drawFitnessHoldPrompt, self)
        return unpack(result)
    end
    promptClass._gqsFitnessHoldPromptInstalled = true
    log("fitness hold prompt installed on ISButtonPrompt:prerender")
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
    -- If any player had a live suspension, give it back before forgetting the
    -- states; otherwise the shared refcount leaks and B stays disabled.
    for _, state in pairs(states) do
        if state.suspended then
            restoreCancelBinding()
            state.suspended = false
        end
    end
    states = {}
end

-- Binding-leak safety is owned by GQSWashHoldToStop (it holds the refcount and
-- the saved button), so no separate guard is needed here.

install()
log("loaded: hold B " .. tostring(HOLD_MS) .. "ms to stop an exercise")
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
        if promptClass and not promptClass._gqsFitnessHoldPromptInstalled then installPrompt() end
    end)
end
