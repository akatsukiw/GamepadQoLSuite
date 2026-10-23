-- Gamepad QoL Suite: directional quick selection for visible UI windows.
-- Gesture: press Y while the left stick is neutral. Movement is blocked
-- immediately, without a hold timer. Nudge the stick to preview a window;
-- the first nudge selects by screen direction and later nudges navigate.
-- Releasing Y commits the preview, or replays the original focused UI's Y handler
-- when the selector was not used. This preserves native per-panel behavior.
-- No cursor movement and no separate selection menu are created.

pcall(require, "ISUI/ISPanel")

GQSPanelQuickSelect = GQSPanelQuickSelect or {}
local GQS = GQSPanelQuickSelect
GQS.states = GQS.states or {}
GQS.overlay = nil
GQS.DEADZONE_ON = 0.55
GQS.DEADZONE_OFF = 0.25
-- A neutral-stick Y press locks movement immediately. The first stick nudge
-- selects a panel; releasing Y commits the selection (or performs native Y if
-- there was no stick nudge).

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("panelQuickSelect", message)
    end
end

local function restoreTutorialInventoryBlinkMethod()
    local inventoryPage = rawget(_G, "ISInventoryPage")
    if type(inventoryPage) ~= "table" or type(inventoryPage.setBlinkingContainer) == "function" then
        return false
    end

    -- CleanUI's Build 42.19 branch rebuilds ISInventoryPage and omits this
    -- vanilla method. Tutorial/Steps.lua calls it after the loot page opens.
    -- Keep the tutorial's state fields without replacing any CleanUI behavior.
    inventoryPage.setBlinkingContainer = function(self, blinking, containerType)
        local enabled = blinking == true or blinking == 1
        self.blinkContainer = enabled
        self.blinkContainerType = enabled and containerType or nil
    end
    print("[GQS Tutorial Y] Restored missing ISInventoryPage:setBlinkingContainer for CleanUI compatibility")
    return true
end

restoreTutorialInventoryBlinkMethod()

local function safeCall(object, methodName, argument)
    if object == nil then return nil end
    local method = object[methodName]
    if type(method) ~= "function" then return nil end
    local ok, result
    if argument == nil then
        ok, result = pcall(method, object)
    else
        ok, result = pcall(method, object, argument)
    end
    if ok then return result end
    return nil
end
local function asNumber(value)
    if type(value) == "number" then return value end
    local ok, number = pcall(tonumber, value)
    if ok then return number end
    return nil
end

local function stateFor(playerNum)
    local state = GQS.states[playerNum]
    if not state then
        state = {
            playerNum = playerNum,
            wasYDown = false,
            pendingY = nil,
            selectorEligible = false,
            selectorArmed = false,
            selectorActive = false,
            usedSelector = false,
            selected = nil,
            axisLatched = false,
            candidateListLogged = false,
            movementLockActive = false,
            movementLockChanged = false,
            movementLockPrior = false,
            movementLockPlayer = nil,
            cancelNativeY = false,
            directionInput = false,
            focusAtYDown = nil,
            lastFocus = nil,
            lastFocusKnown = false,
            yInventoryFlagPrior = nil,
            yInventoryFlagChanged = false,
            prematureActionReverted = false,
            startedWithStickActive = false,
            inventoryVisibleAtYDown = nil,
            lootVisibleAtYDown = nil,
            usedShortcut = false,
            shortcutActionExecuted = false,
            shortcutActionName = nil,
            lastDpadDirection = nil,
            dpadDownAtYEvent = nil,
            ignoreYCombosForGesture = false,
            ignoredDpadLogged = false,
            -- Prevent a Y hold that began while the world map owned focus from
            -- becoming a fresh custom gesture if the map closes before release.
            suppressYUntilRelease = false,
        }
        GQS.states[playerNum] = state
    end
    return state
end

local function getControllerId(playerNum)
    if type(getJoypadData) == "function" then
        local ok, data = pcall(getJoypadData, playerNum)
        if ok and data and type(data.id) == "number" then return data.id end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerNum + 1]
    if data and type(data.id) == "number" then return data.id end
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if player and type(player.getJoypadBind) == "function" then
        local ok, id = pcall(function() return player:getJoypadBind() end)
        if ok and type(id) == "number" then return id end
    end
    return -1
end

-- RB+Y zoom owns this physical press only when the RB module confirms an
-- ordered, enabled world-focus chord. This small guard prevents the independent
-- Y+left-stick/D-pad gesture tracker from replaying ordinary Y on release.
local function isRBZoomButtonChordActive(playerNum, buttonName)
    local controls = rawget(_G, "GQS_RBControls")
    if not controls or type(controls.isButtonChordDown) ~= "function" then return false end
    local ok, active = pcall(controls.isButtonChordDown, playerNum, buttonName)
    return ok and active == true
end

local function isYDown(playerNum)
    local controllerId = getControllerId(playerNum)
    if controllerId < 0 then return false end

    local buttons = rawget(_G, "JoypadButton")
    local yButton = buttons and buttons.Y or nil
    if yButton and type(yButton.isDown) == "function" then
        local ok, down = pcall(yButton.isDown, yButton, controllerId)
        if ok then return down == true end
    end

    local joypad = rawget(_G, "Joypad")
    if type(isJoypadPressed) == "function" and joypad and joypad.YButton ~= nil then
        local ok, down = pcall(isJoypadPressed, controllerId, joypad.YButton)
        if ok then return down == true end
    end
    return false
end

local function isYButton(button)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad.YButton ~= nil and button == joypad.YButton then return true end
    local buttons = rawget(_G, "JoypadButton")
    if buttons and buttons.Y ~= nil and button == buttons.Y then return true end
    -- Compatibility with builds/mods that pass the enum rather than the legacy
    -- numeric Joypad.YButton value.
    local ok, text = pcall(tostring, button)
    if ok and type(text) == "string" then
        if text == "Y" or text == "JoypadButton.Y" or text == "zombie.input.JoypadButton.Y" then return true end
    end
    return false
end

local function isAnyDpadDown(controllerId)
    if controllerId == nil or controllerId < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    if not buttons then return false end
    local names = { "DPadUp", "DPadDown", "DPadLeft", "DPadRight" }
    for i = 1, #names do
        local button = buttons[names[i]]
        if button and type(button.isDown) == "function" then
            local ok, down = pcall(button.isDown, button, controllerId)
            if ok and down == true then return true end
        end
    end
    return false
end

local function getDpadDirection(controllerId)
    if controllerId == nil or controllerId < 0 then return nil end
    local buttons = rawget(_G, "JoypadButton")
    if not buttons then return nil end
    local names = {
        { key = "DPadUp", direction = "up" },
        { key = "DPadDown", direction = "down" },
        { key = "DPadLeft", direction = "left" },
        { key = "DPadRight", direction = "right" },
    }
    for i = 1, #names do
        local button = buttons[names[i].key]
        if button and type(button.isDown) == "function" then
            local ok, down = pcall(button.isDown, button, controllerId)
            if ok and down == true then return names[i].direction end
        end
    end
    return nil
end

local handleYShortcut
local isPanelQuickSelectEnabled -- forward declaration; used by beginYGesture before its definition

local function readUIVisible(object)
    if object == nil then return false end
    local visible = safeCall(object, "isReallyVisible")
    if visible == nil then visible = safeCall(object, "isVisible") end
    return visible == true or visible == 1
end

local function getStickAxes(playerNum)
    local controllerId = getControllerId(playerNum)
    if controllerId < 0 then return 0, 0 end
    local x, y = 0, 0
    if type(getJoypadMovementAxisX) == "function" then
        local ok, value = pcall(getJoypadMovementAxisX, controllerId)
        if ok and type(value) == "number" then x = value end
    end
    if type(getJoypadMovementAxisY) == "function" then
        local ok, value = pcall(getJoypadMovementAxisY, controllerId)
        if ok and type(value) == "number" then y = value end
    end
    return x, y
end

-- Do not use the player's animation variable or getMoveDelta() to decide
-- whether the selector may start. In Build 42 these can remain true briefly after
-- releasing the stick. Gate this gesture on the actual left-stick input at the
-- instant Y is pressed; a neutral stick allows immediate movement lock.

-- During a panel-selection gesture, use IsoPlayer's native movement block so
-- the left stick navigates UI windows instead of walking the character.
-- Preserve any pre-existing block state and restore it when Y is released.
local function setSelectorMovementLock(state, enabled)
    if enabled then
        if state.movementLockActive then return true end
        local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(state.playerNum) or nil
        if not player then
            log("cannot lock movement: player is unavailable")
            return false
        end
        local prior = safeCall(player, "isBlockMovement")
        if prior == nil then prior = false end
        local ok, err = pcall(function()
            player:setBlockMovement(true)
        end)
        if not ok then
            log("cannot lock movement with IsoPlayer:setBlockMovement: " .. tostring(err))
            return false
        end
        state.movementLockPlayer = player
        state.movementLockPrior = prior == true
        state.movementLockChanged = prior ~= true
        state.movementLockActive = true
        log("movement blocked while panel selector is armed")
        return true
    end

    if not state.movementLockActive then return true end
    local player = state.movementLockPlayer
    if state.movementLockChanged and player then
        local prior = state.movementLockPrior == true
        local ok, err = pcall(function()
            player:setBlockMovement(prior)
        end)
        if not ok then log("movement unlock failed: " .. tostring(err)) end
    end
    state.movementLockActive = false
    state.movementLockChanged = false
    state.movementLockPrior = false
    state.movementLockPlayer = nil
    log("movement block restored after panel selection")
    return true
end

local function beginYGesture(state, axisMagnitude, axisX, axisY, currentFocus)
    -- The Y-down callback records whether a D-pad button was already held at
    -- the actual button event. This is more reliable than checking current input
    -- on the next tick, when a valid Y-then-D-pad chord may already be in flight.
    local dpadWasDownAtY = state.dpadDownAtYEvent
    if dpadWasDownAtY == nil then
        dpadWasDownAtY = getDpadDirection(getControllerId(state.playerNum)) ~= nil
    end
    state.ignoreYCombosForGesture = dpadWasDownAtY == true
    state.ignoredDpadLogged = false

    state.wasYDown = true
    state.selectorEligible = isPanelQuickSelectEnabled()
        and axisMagnitude <= GQS.DEADZONE_OFF
        and not state.ignoreYCombosForGesture
    state.selectorArmed = false
    state.selectorActive = false
    state.usedSelector = false
    state.selected = nil
    state.axisLatched = false
    state.candidateListLogged = false
    state.cancelNativeY = false
    state.directionInput = false
    state.usedShortcut = false
    state.shortcutActionExecuted = false
    state.shortcutActionName = nil
    state.lastDpadDirection = nil
    state.prematureActionReverted = false
    state.startedWithStickActive = axisMagnitude > GQS.DEADZONE_OFF
    -- The live focus at the exact Y-down frame is authoritative. A remembered
    -- focus can be stale after a tab switch or the native PlayerInfo command.
    state.focusAtYDown = currentFocus or (state.lastFocusKnown and state.lastFocus or nil)

    local inv, loot = nil, nil
    if type(getPlayerInventory) == "function" then
        local ok, value = pcall(getPlayerInventory, state.playerNum)
        if ok then inv = value end
    end
    if type(getPlayerLoot) == "function" then
        local ok, value = pcall(getPlayerLoot, state.playerNum)
        if ok then loot = value end
    end
    state.inventoryVisibleAtYDown = readUIVisible(inv)
    state.lootVisibleAtYDown = readUIVisible(loot)

    local controllerId = getControllerId(state.playerNum)
    local dpadDirection = getDpadDirection(controllerId)
    if state.ignoreYCombosForGesture then
        -- Strict chord order: D-pad must be pressed AFTER Y. A direction that
        -- was already held when Y-down arrived is a separate input, not a combo.
        state.lastDpadDirection = dpadDirection
        log("Y began while D-pad was already held; rejecting Y+D-pad combo for this Y hold")
    end

    if state.selectorEligible then
        -- No hold timer: lock movement on the first tick where Y is detected.
        -- The normal Y action is deferred until release by the input hook.
        if setSelectorMovementLock(state, true) then
            state.selectorArmed = true
            log(string.format("Y press accepted while stick neutral (x=%.2f,y=%.2f); movement locked; move stick to switch focus live", axisX or 0, axisY or 0))
        else
            state.selectorEligible = false
            log("Y press could not lock movement; panel selector disabled for this Y press")
        end
    else
        -- Keep walk+Y out of the selector, and make the new toggle affect only
        -- panel navigation rather than the independent Y + D-pad shortcuts.
        if not isPanelQuickSelectEnabled() and axisMagnitude <= GQS.DEADZONE_OFF then
            log("Y+left-stick panel selection disabled in Mod Options; normal Y action deferred until release")
        else
            log(string.format("Y press began with active left-stick input (magnitude=%.2f); selector disabled; normal Y action deferred until release", axisMagnitude))
        end
    end
end

local function getCurrentFocus(playerNum)
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok then return focus end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerNum + 1]
    return data and data.focus or nil
end

local function isVisible(object)
    local visible = safeCall(object, "isReallyVisible")
    if visible == nil then visible = safeCall(object, "isVisible") end
    return visible == true or visible == 1
end

local getTypeName -- forward declaration used by the early-Y-action helpers

local function getPlayerInventorySafely(playerNum)
    if type(getPlayerInventory) == "function" then
        local ok, value = pcall(getPlayerInventory, playerNum)
        if ok then return value end
    end
    return nil
end

local function getPlayerLootSafely(playerNum)
    if type(getPlayerLoot) == "function" then
        local ok, value = pcall(getPlayerLoot, playerNum)
        if ok then return value end
    end
    return nil
end

local function isInventoryWindow(object, playerNum)
    if object == nil then return false end
    if object == getPlayerInventorySafely(playerNum) or object == getPlayerLootSafely(playerNum) then return true end
    local name = string.lower(getTypeName(object))
    return string.find(name, "isinventorypage", 1, true) ~= nil
        or string.find(name, "inventorypage", 1, true) ~= nil
end

local function isFitnessWindow(object)
    if object == nil then return false end
    local name = string.lower(getTypeName(object))
    return string.find(name, "isfitnessui", 1, true) ~= nil
        or string.find(name, "fitnessui", 1, true) ~= nil
end


local function restoreEarlyYAction(state)
    if state.usedSelector or state.usedShortcut or state.prematureActionReverted then return end
    local current = getCurrentFocus(state.playerNum)
    local baseline = state.focusAtYDown
    local inv = getPlayerInventorySafely(state.playerNum)
    local loot = getPlayerLootSafely(state.playerNum)
    local inventoryVisibilityChanged = (inv ~= nil and state.inventoryVisibleAtYDown ~= nil and readUIVisible(inv) ~= state.inventoryVisibleAtYDown)
    local lootVisibilityChanged = (loot ~= nil and state.lootVisibleAtYDown ~= nil and readUIVisible(loot) ~= state.lootVisibleAtYDown)
    if current == baseline and not inventoryVisibilityChanged and not lootVisibilityChanged then return end

    local shouldRestore = isInventoryWindow(current, state.playerNum)
        or isFitnessWindow(current)
        or (current == nil and isInventoryWindow(baseline, state.playerNum))
        or inventoryVisibilityChanged or lootVisibilityChanged
    if not shouldRestore then return end

    -- Y is meant to be deferred until release. If the game's global Y handler
    -- changed focus or revealed inventory before the UI callback intercepted it,
    -- revert both focus and inventory visibility to the state from Y-down.
    if isFitnessWindow(current) and type(current.removeFromUIManager) == "function" then
        pcall(function() current:removeFromUIManager() end)
    end
    if type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, state.playerNum, baseline)
        if not ok then log("could not revert early Y focus action: " .. tostring(err)) end
    end
    if inv and state.inventoryVisibleAtYDown ~= nil and type(inv.setVisible) == "function" then
        pcall(function() inv:setVisible(state.inventoryVisibleAtYDown) end)
    end
    if loot and state.lootVisibleAtYDown ~= nil and type(loot.setVisible) == "function" then
        pcall(function() loot:setVisible(state.lootVisibleAtYDown) end)
    end
    state.prematureActionReverted = true
    log("reverted early Y action; restored original focus/inventory visibility until release")
end

local function runDeferredNativeY(state)
    local pending = state.pendingY
    local baseline = state.focusAtYDown
    local currentFocus = getCurrentFocus(state.playerNum)
    local inv = getPlayerInventorySafely(state.playerNum)
    local loot = getPlayerLootSafely(state.playerNum)

    -- Most important: replay the exact native handler that received Y-down.
    -- Do not infer behavior from a possibly stale last-focused object and do not
    -- replace arbitrary panels' Y behavior with a forced inventory-open action.
    local original = nil
    local originalFocus = nil
    local originalButton = Joypad and Joypad.YButton or nil
    if pending and type(pending.original) == "function" and pending.focus ~= nil then
        original = pending.original
        originalFocus = pending.focus
        originalButton = pending.button or originalButton
    elseif baseline and type(baseline._gqsPanelQuickSelectOriginalDown) == "function" then
        original = baseline._gqsPanelQuickSelectOriginalDown
        originalFocus = baseline
    elseif currentFocus and type(currentFocus._gqsPanelQuickSelectOriginalDown) == "function" then
        original = currentFocus._gqsPanelQuickSelectOriginalDown
        originalFocus = currentFocus
    end

    if type(original) == "function" and originalFocus ~= nil then
        local ok, err = pcall(original, originalFocus, originalButton)
        if ok then
            log("replayed original native Y handler for " .. tostring(getTypeName(originalFocus) ~= "" and getTypeName(originalFocus) or originalFocus.Type or originalFocus.type or originalFocus.name or "focused UI"))
        else
            log("original native Y handler failed: " .. tostring(err))
        end
        return
    end

    -- If inventory itself had focus but no handler was captured, retain its
    -- vanilla-like close/defocus fallback. Do not use this fallback for other UI.
    local focus = baseline or currentFocus
    if focus == inv or focus == loot or isInventoryWindow(focus, state.playerNum) then
        if type(setJoypadFocus) == "function" then
            local ok, err = pcall(setJoypadFocus, state.playerNum, nil)
            if ok then log("inventory had no captured Y handler; cleared inventory focus as fallback")
            else log("could not clear inventory focus on Y release: " .. tostring(err)) end
        end
        return
    end

    -- A visible non-inventory panel without a capturable handler should keep its
    -- own/vanilla behavior; opening inventory here was the regression introduced
    -- by the selector's old fallback. Only use the backpack default when no UI
    -- panel owns focus (for example, focus is nil or the back-button wheel).
    if focus ~= nil then
        local focusName = string.lower(tostring(getTypeName(focus) or "") .. " " .. tostring(focus.Type or focus.type or focus.name or ""))
        if not string.find(focusName, "backbuttonwheel", 1, true) then
            log("no native Y handler captured for focused panel " .. focusName .. "; did not force-open inventory")
            return
        end
    end

    if inv and type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, state.playerNum, inv)
        if ok then log("opened inventory on Y release because no panel owned Y focus")
        else log("could not open inventory on Y release: " .. tostring(err)) end
    else
        log("deferred native Y had no focused handler or inventory API available")
    end
end

getTypeName = function(object)
    if object == nil then return "" end
    local name = object.Type or object.type or object.className or object.ClassName
    if name == nil then name = safeCall(object, "getUIName") end
    if name == nil then name = object.title or object.name end
    if name == nil then return "" end
    return tostring(name)
end

-- Detect map-related UI objects by type/name. Do not use this alone to decide
-- whether the world map is currently open: PZ can leave an old map object in
-- the joypad-focus slot after close().
local function isWorldMapObject(object)
    if object == nil then return false end
    local name = string.lower(
        tostring(getTypeName(object) or "") .. " " ..
        tostring(object.Type or object.type or object.className or object.ClassName or "")
    )
    return string.find(name, "isworldmap", 1, true) ~= nil
        or string.find(name, "worldmap", 1, true) ~= nil
end

-- In Build 42.21, ISWorldMap:close() hides/removes the UI and clears
-- ISWorldMap.instance. Use that live singleton plus parent identity instead of
-- relying on visibility methods, which may not reliably distinguish a stale
-- focus reference from an active map. This also recognizes map child panels.
local function isWorldMapFocus(object)
    if object == nil then return false end
    local mapClass = rawget(_G, "ISWorldMap")
    local activeMap = type(mapClass) == "table" and mapClass.instance or nil
    if activeMap == nil then return false end

    local current = object
    for _ = 1, 16 do
        if current == activeMap then return true end
        if current == nil then return false end

        local parent = nil
        pcall(function() parent = current.parent end)
        if parent == nil then parent = safeCall(current, "getParent") end
        if parent == current then return false end
        current = parent
    end
    return false
end

local function getRect(object)
    local x = asNumber(safeCall(object, "getAbsoluteX"))
    local y = asNumber(safeCall(object, "getAbsoluteY"))
    local w = asNumber(safeCall(object, "getWidth"))
    local h = asNumber(safeCall(object, "getHeight"))
    if x == nil then x = asNumber(safeCall(object, "getX")) or asNumber(object.x) end
    if y == nil then y = asNumber(safeCall(object, "getY")) or asNumber(object.y) end
    if w == nil then w = asNumber(object.width) end
    if h == nil then h = asNumber(object.height) end
    if x == nil or y == nil or w == nil or h == nil then return nil end
    if w < 1 or h < 1 then return nil end
    return { x = x, y = y, w = w, h = h, cx = x + w / 2, cy = y + h / 2 }
end

local function containsAny(text, words)
    local lower = string.lower(text or "")
    for i = 1, #words do
        if string.find(lower, words[i], 1, true) then return true end
    end
    return false
end

local excludedNames = {
    -- Multiplayer's persistent chat HUD may satisfy the generic window checks,
    -- but should not silently take world-input focus when the user is only
    -- attempting Y + left-stick panel selection with no real panel open.
    "gqspanelquickselectoverlay", "moodlesui", "speedcontrols", "radialmenu",
    "ischat", "tooltip", "istooltip", "hotbar", "minimap", "radarpanel", "clock",
    "actionprogressbar", "vehicle gauge", "vehiclegauge", "healthbar", "xpbar",
}

local windowNameHints = {
    "window", "panel", "inventory", "loot", "health", "fitness", "info",
    "skill", "map", "radio", "television", "tv", "craft", "container",
    "book", "mechanic", "vehicle", "character", "garment", "medical",
    "trading", "recipe", "forage", "debug", "smith", "workbench",
}

local function isWindowCandidate(object, playerNum, screenW, screenH, stats)
    local function reject(reason)
        if stats then stats[reason] = (stats[reason] or 0) + 1 end
        return false
    end
    if object == nil or object == GQS.overlay then return reject("nil_or_overlay") end
    -- UIManager.getUI() returns Java UIElement objects. collectWindows() converts
    -- each entry through getTable() first, so this must be the original Lua wrapper.
    if type(object) ~= "table" then return reject("not_lua_table") end
    if type(object.onJoypadDown) ~= "function" then return reject("no_joypad_handler") end
    if not isVisible(object) then return reject("not_visible") end

    local parent = safeCall(object, "getParent")
    if parent ~= nil then return reject("nested_child") end

    local name = getTypeName(object)
    if containsAny(name, excludedNames) then return reject("excluded_name") end
    if name == "ISPanel" or name == "ISPanelJoypad" or name == "ISUIElement" then return reject("generic_type") end

    local rect = getRect(object)
    if not rect or rect.w < 150 or rect.h < 90 then return reject("invalid_rect") end
    if screenW > 0 and screenH > 0 and rect.w >= screenW * 0.88 and rect.h >= screenH * 0.82 then
        return reject("full_screen")
    end

    local hasWindowSignal = containsAny(name, windowNameHints)
        or object.title ~= nil or object.titleBar ~= nil or object.closeButton ~= nil
        or object.resizable == true or object.moveWithMouse == true
    if not hasWindowSignal then return reject("not_window_like") end

    -- Skip interface elements explicitly assigned to a different local player.
    local owner = object.playerNum
    if owner == nil and type(object.player) == "number" then owner = object.player end
    if owner ~= nil and type(owner) == "number" and owner ~= playerNum then return reject("other_player") end

    rect.object = object
    rect.name = name ~= "" and name or "UI window"
    if stats then stats.accepted = (stats.accepted or 0) + 1 end
    return rect
end

local function unwrapUIObject(object)
    if object == nil then return nil end
    -- In Build 42 UIManager.getUI() contains zombie.ui.UIElement instances.
    -- ISUIElement:instantiate() stores its original Lua object table on that Java
    -- element, exposed by UIElement.getTable().
    local ok, luaObject = pcall(function() return object:getTable() end)
    if ok and luaObject ~= nil then return luaObject end
    -- Some modded UI lists may already contain Lua ISUIElement tables.
    if type(object) == "table" then return object end
    return nil
end

local function getScreenRect(playerNum)
    local left = 0
    local top = 0
    local width = 0
    local height = 0
    if type(getPlayerScreenLeft) == "function" then
        local ok, value = pcall(getPlayerScreenLeft, playerNum)
        if ok and type(value) == "number" then left = value end
    end
    if type(getPlayerScreenTop) == "function" then
        local ok, value = pcall(getPlayerScreenTop, playerNum)
        if ok and type(value) == "number" then top = value end
    end
    if type(getPlayerScreenWidth) == "function" then
        local ok, value = pcall(getPlayerScreenWidth, playerNum)
        if ok and type(value) == "number" then width = value end
    end
    if type(getPlayerScreenHeight) == "function" then
        local ok, value = pcall(getPlayerScreenHeight, playerNum)
        if ok and type(value) == "number" then height = value end
    end
    if width <= 0 or height <= 0 then
        local core = type(getCore) == "function" and getCore() or nil
        if core then
            if width <= 0 and type(core.getScreenWidth) == "function" then
                local ok, value = pcall(function() return core:getScreenWidth() end)
                if ok then width = asNumber(value) or width end
            end
            if height <= 0 and type(core.getScreenHeight) == "function" then
                local ok, value = pcall(function() return core:getScreenHeight() end)
                if ok then height = asNumber(value) or height end
            end
        end
    end
    return { x = left, y = top, w = width, h = height, cx = left + width / 2, cy = top + height / 2 }
end

local function isFocusableLuaPanel(object)
    return type(object) == "table" and type(object.onJoypadDown) == "function"
end

local function resolveActiveCharacterInfoView(infoWindow, playerNum)
    if not infoWindow then return nil, nil end
    -- Vanilla ISBackButtonWheel:onCommand("PlayerInfo") uses
    -- getPlayerInfoPanel(playerNum).panel:getActiveView().
    local tabPanel = infoWindow.panel or infoWindow.ISTabPanel or infoWindow.tabPanel or infoWindow.tabpanel
    local currentFocus = getCurrentFocus(playerNum)
    local currentFocusName = string.lower(getTypeName(currentFocus))

    local function usable(view)
        return isFocusableLuaPanel(view) and view ~= infoWindow
    end

    -- Use the exact remembered active view reported by the native tab panel.
    local vanillaActiveView = safeCall(tabPanel, "getActiveView")
    if usable(vanillaActiveView) then return vanillaActiveView, tabPanel end

    local function resolveViewKey(key, maps)
        for i = 1, #maps do
            local map = maps[i]
            if type(map) == "table" then
                local direct = map[key]
                if usable(direct) then return direct end
                for mapKey, value in pairs(map) do
                    if usable(value) and (tostring(mapKey) == tostring(key)
                        or tostring(value.viewName or value.name or "") == tostring(key)
                        or getTypeName(value) == tostring(key)) then
                        return value
                    end
                end
            end
        end
        return nil
    end

    if tabPanel then
        local maps = { tabPanel.viewList, tabPanel.views, tabPanel.panels, tabPanel.viewMap }
        local active = tabPanel.activeView or tabPanel.currentView or tabPanel.activePanel or tabPanel.selectedView
        if usable(active) then return active, tabPanel end
        if active ~= nil then
            local resolved = resolveViewKey(active, maps)
            if resolved then return resolved, tabPanel end
            if type(active) == "number" then
                for i = 1, #maps do
                    local map = maps[i]
                    if type(map) == "table" and usable(map[active]) then return map[active], tabPanel end
                end
            end
            local activeText = string.lower(tostring(active))
            for i = 1, #maps do
                local map = maps[i]
                if type(map) == "table" then
                    for key, value in pairs(map) do
                        if usable(value) and (string.lower(tostring(key)) == activeText
                            or string.find(string.lower(getTypeName(value)), activeText, 1, true)) then
                            return value, tabPanel
                        end
                    end
                end
            end
        end
        local methodView = safeCall(tabPanel, "getActiveView") or safeCall(tabPanel, "getCurrentView")
        if usable(methodView) then return methodView, tabPanel end
        if type(tabPanel.viewList) == "table" then
            local possible = {}
            for key, value in pairs(tabPanel.viewList) do
                if usable(value) and isVisible(value) then
                    possible[#possible + 1] = { key = tostring(key), value = value }
                end
            end
            if #possible == 1 then return possible[1].value, tabPanel end
            for i = 1, #possible do
                local item = possible[i]
                if string.find(currentFocusName, string.lower(item.key), 1, true) then return item.value, tabPanel end
            end
        end
        -- Some B42 versions keep each view as a named field on ISTabPanel.
        local possible = {}
        for key, value in pairs(tabPanel) do
            if usable(value) and isVisible(value) then
                local name = string.lower(tostring(key) .. " " .. getTypeName(value))
                if containsAny(name, { "character", "health", "protection", "temperature", "skill", "info", "xp", "garment" }) then
                    possible[#possible + 1] = { key = tostring(key), value = value, name = name }
                end
            end
        end
        if #possible == 1 then return possible[1].value, tabPanel end
        for i = 1, #possible do
            if currentFocus and (possible[i].value == currentFocus
                or string.find(currentFocusName, string.lower(possible[i].key), 1, true)) then
                return possible[i].value, tabPanel
            end
        end
    end

    -- If the focused object belongs to the character-info hierarchy, use it as
    -- the focus target; the enclosing window still supplies the selection rect.
    if usable(currentFocus) and string.find(currentFocusName, "ischaracterinfowindow", 1, true) then
        return currentFocus, tabPanel
    end
    return nil, tabPanel
end

local function appendCharacterInfoWindow(results, playerNum, screen, stats)
    if type(getPlayerInfoPanel) ~= "function" then return end
    local ok, infoWindow = pcall(getPlayerInfoPanel, playerNum)
    if not ok or not infoWindow or not readUIVisible(infoWindow) then return end

    local view, tabPanel = resolveActiveCharacterInfoView(infoWindow, playerNum)
    if not isFocusableLuaPanel(view) then
        if stats then stats.info_view_unresolved = (stats.info_view_unresolved or 0) + 1 end
        log("character-info window is visible but its active joypad view could not be resolved")
        return
    end

    local rect = getRect(infoWindow) or getRect(view)
    if not rect then
        if stats then stats.info_rect_invalid = (stats.info_rect_invalid or 0) + 1 end
        return
    end
    if rect.w < 150 or rect.h < 90 then return end

    local viewName = getTypeName(view)
    local candidateName = "ISCharacterInfoWindow." .. (viewName ~= "" and viewName or "ActiveTab")
    for i = #results, 1, -1 do
        local item = results[i]
        if item.object == infoWindow or string.find(string.lower(item.name or ""), "ischaracterinfowindow", 1, true) then
            table.remove(results, i)
        elseif item.object == view then
            return
        end
    end
    rect.object = view
    rect.name = candidateName
    rect.infoWindow = infoWindow
    rect.tabPanel = tabPanel
    results[#results + 1] = rect
    if stats then stats.accepted = (stats.accepted or 0) + 1; stats.character_info_added = 1 end
end

local function collectWindows(playerNum)
    local results = {}
    local stats = { raw = 0, converted = 0, accepted = 0 }
    if not UIManager or type(UIManager.getUI) ~= "function" then
        return results, getScreenRect(playerNum), stats
    end
    local ok, uiList = pcall(function() return UIManager.getUI() end)
    if not ok or uiList == nil then
        stats.list_error = 1
        return results, getScreenRect(playerNum), stats
    end

    local screen = getScreenRect(playerNum)
    -- Use direct Java method invocation rather than type-checking Java method
    -- wrappers, which can be reported differently by Kahlua.
    local okSize, listSize = pcall(function() return uiList:size() end)
    listSize = okSize and asNumber(listSize) or nil
    if listSize ~= nil then
        stats.raw = listSize
        for i = 0, listSize - 1 do
            local okItem, rawObject = pcall(function() return uiList:get(i) end)
            if okItem and rawObject then
                local object = unwrapUIObject(rawObject)
                if object then
                    stats.converted = stats.converted + 1
                    local candidate = isWindowCandidate(object, playerNum, screen.w, screen.h, stats)
                    if candidate then results[#results + 1] = candidate end
                else
                    stats.unwrap_failed = (stats.unwrap_failed or 0) + 1
                end
            end
        end
    elseif type(uiList) == "table" then
        stats.raw = #uiList
        for i = 1, #uiList do
            local object = unwrapUIObject(uiList[i])
            if object then
                stats.converted = stats.converted + 1
                local candidate = isWindowCandidate(object, playerNum, screen.w, screen.h, stats)
                if candidate then results[#results + 1] = candidate end
            else
                stats.unwrap_failed = (stats.unwrap_failed or 0) + 1
            end
        end
    else
        stats.list_read_failed = 1
    end
    -- The character-info panel's active page (health/skills/protection/etc.) is
    -- nested inside ISCharacterInfoWindow and is not a top-level UIManager entry.
    -- Add it explicitly using the outer window's screen rectangle.
    appendCharacterInfoWindow(results, playerNum, screen, stats)
    return results, screen, stats
end

local function quantizeDirection(axisX, axisY)
    local dx = 0
    local dy = 0
    if math.abs(axisX) >= 0.35 then dx = axisX > 0 and 1 or -1 end
    if math.abs(axisY) >= 0.35 then dy = axisY > 0 and 1 or -1 end
    if dx == 0 and dy == 0 then return nil, nil end
    local length = math.sqrt(dx * dx + dy * dy)
    return dx / length, dy / length
end

local function directionName(dx, dy)
    local horizontal = dx < -0.1 and "左" or (dx > 0.1 and "右" or "")
    local vertical = dy < -0.1 and "上" or (dy > 0.1 and "下" or "")
    if horizontal == "" then return vertical end
    if vertical == "" then return horizontal end
    return horizontal .. vertical
end

local function matchesSignedDirection(vx, vy, dirX, dirY)
    if dirX > 0 and vx <= 0 then return false end
    if dirX < 0 and vx >= 0 then return false end
    if dirY > 0 and vy <= 0 then return false end
    if dirY < 0 and vy >= 0 then return false end
    return true
end

local function chooseDirectional(windows, originX, originY, dirX, dirY, current)
    local best = nil
    local bestScore = nil
    for i = 1, #windows do
        local candidate = windows[i]
        if not (current and candidate.object == current.object) then
            local vx = candidate.cx - originX
            local vy = candidate.cy - originY
            local distance = math.sqrt(vx * vx + vy * vy)
            if distance > 12 and matchesSignedDirection(vx, vy, dirX, dirY) then
                local alignment = (vx * dirX + vy * dirY) / distance
                if alignment > 0.12 then
                    -- Direction fit is weighted more heavily than distance, while
                    -- distance breaks ties between multiple windows in one direction.
                    local score = (1 - alignment) * 1800 + distance * 0.24
                    if bestScore == nil or score < bestScore then
                        best = candidate
                        bestScore = score
                    end
                end
            end
        end
    end
    return best
end

local function chooseInitialDirectional(windows, screen, dirX, dirY)
    if #windows == 0 then return nil end
    -- Aim at a region of the screen in the stick direction. This is more robust
    -- than requiring a window center to lie strictly in one quadrant around the
    -- screen center (which can fail for wide/overlapping UI windows).
    local targetX = screen.cx + dirX * screen.w * 0.31
    local targetY = screen.cy + dirY * screen.h * 0.31
    local best, bestScore = nil, nil
    for i = 1, #windows do
        local candidate = windows[i]
        local vx = candidate.cx - screen.cx
        local vy = candidate.cy - screen.cy
        local distance = math.sqrt(vx * vx + vy * vy)
        local alignment = distance > 0 and ((vx * dirX + vy * dirY) / distance) or 0
        local dx = (candidate.cx - targetX) / math.max(1, screen.w)
        local dy = (candidate.cy - targetY) / math.max(1, screen.h)
        local score = math.sqrt(dx * dx + dy * dy)
        if not matchesSignedDirection(vx, vy, dirX, dirY) then score = score + 0.28 end
        score = score - alignment * 0.06
        if bestScore == nil or score < bestScore then
            best, bestScore = candidate, score
        end
    end
    return best
end

local function drawSelection(_state)
    -- Intentionally unused in Fix5: native setJoypadFocus() draws the game's
    -- normal green focus border directly on the selected window.
end

local function ensureOverlay()
    if GQS.overlay then return GQS.overlay end
    if type(ISPanel) ~= "table" then
        log("ISPanel is unavailable; cannot create highlight overlay")
        return nil
    end
    local Overlay = ISPanel:derive("GQSPanelQuickSelectOverlay")
    function Overlay:new(x, y, width, height)
        local o = ISPanel.new(self, x, y, width, height)
        setmetatable(o, self)
        self.__index = self
        o.background = false
        o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        o.targetRect = nil
        return o
    end
    function Overlay:render()
        if ISPanel.render then ISPanel.render(self) end
        local rect = self.targetRect
        if not rect then return end
        local x = rect.x - self.x
        local y = rect.y - self.y
        -- Strong multi-line orange outline with a cyan inner line, visible above
        -- the target window. The small attached tag is part of the outline, not
        -- a separate menu/window.
        self:drawRect(x, y, rect.w, rect.h, 0.045, 1.0, 0.68, 0.08)
        for inset = 0, 3 do
            self:drawRectBorder(x - inset, y - inset, rect.w + inset * 2, rect.h + inset * 2, 1.0, 1.0, 0.62, 0.04)
        end
        self:drawRectBorder(x + 1, y + 1, math.max(1, rect.w - 2), math.max(1, rect.h - 2), 1.0, 0.0, 0.92, 1.0)

        local name = tostring(rect.name or "窗口")
        if #name > 42 then name = string.sub(name, 1, 39) .. "..." end
        local label = "选择中: " .. name .. " | 松开 Y 确认"
        local labelW = 260
        if type(getTextManager) == "function" and UIFont and UIFont.Small then
            local ok, measured = pcall(function() return getTextManager():MeasureStringX(UIFont.Small, label) end)
            if ok and type(measured) == "number" then labelW = math.min(620, measured + 18) end
        end
        local labelX = math.max(0, math.min(self.width - labelW - 2, x))
        local labelY = math.max(0, y - 25)
        self:drawRect(labelX, labelY, labelW, 22, 0.94, 0.05, 0.05, 0.05)
        self:drawRectBorder(labelX, labelY, labelW, 22, 1.0, 1.0, 0.62, 0.04)
        if UIFont and UIFont.Small then
            self:drawText(label, labelX + 8, labelY + 4, 1.0, 1.0, 0.78, 1.0, UIFont.Small)
        end
    end

    local screenW, screenH = 0, 0
    local core = type(getCore) == "function" and getCore() or nil
    if core then
        if type(core.getScreenWidth) == "function" then
            local ok, value = pcall(function() return core:getScreenWidth() end)
            if ok then screenW = asNumber(value) or screenW end
        end
        if type(core.getScreenHeight) == "function" then
            local ok, value = pcall(function() return core:getScreenHeight() end)
            if ok then screenH = asNumber(value) or screenH end
        end
    end
    if screenW <= 0 then screenW = 1920 end
    if screenH <= 0 then screenH = 1080 end

    local ok, overlay = pcall(function()
        local instance = Overlay:new(0, 0, screenW, screenH)
        instance:initialise()
        instance:noBackground()
        if type(instance.setConsumeMouseEvents) == "function" then instance:setConsumeMouseEvents(false) end
        if type(instance.setCapture) == "function" then instance:setCapture(false) end
        if type(instance.setAlwaysOnTop) == "function" then instance:setAlwaysOnTop(true) end
        instance:setVisible(false)
        instance:addToUIManager()
        return instance
    end)
    if ok then
        GQS.overlay = overlay
        log("highlight overlay created")
    else
        log("highlight overlay creation failed: " .. tostring(overlay))
    end
    return GQS.overlay
end

local function logWindows(windows, screen, stats)
    local names = {}
    for i = 1, #windows do
        local item = windows[i]
        names[#names + 1] = string.format("%s(%.0f,%.0f %.0fx%.0f)", item.name, item.x, item.y, item.w, item.h)
    end
    local statText = ""
    if stats then
        local fields = { "raw", "converted", "accepted", "character_info_added", "info_view_unresolved", "info_rect_invalid", "not_lua_table", "no_joypad_handler", "not_visible", "nested_child", "excluded_name", "generic_type", "invalid_rect", "full_screen", "not_window_like", "other_player", "unwrap_failed", "list_read_failed", "list_error" }
        local parts = {}
        for i = 1, #fields do
            local key = fields[i]
            if stats[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(stats[key]) end
        end
        statText = " scan{" .. table.concat(parts, ",") .. "}"
    end
    log(string.format("visible candidates=%d; viewport=(%.0f,%.0f %.0fx%.0f);%s %s",
        #windows, screen.x, screen.y, screen.w, screen.h, statText, table.concat(names, "; ")))
end

local function activateCharacterInfoThroughVanilla(target, playerNum)
    local infoWindow = target and target.infoWindow or nil
    if not infoWindow and type(getPlayerInfoPanel) == "function" then
        local ok, value = pcall(getPlayerInfoPanel, playerNum)
        if ok then infoWindow = value end
    end
    if not infoWindow then
        log("cannot use vanilla PlayerInfo focus route: character-info window unavailable")
        return nil
    end

    -- Call the same PlayerInfo command used by the native Select/Back wheel.
    -- Its vanilla implementation opens the panel and focuses panel:getActiveView().
    local wheel = nil
    if type(getPlayerBackButtonWheel) == "function" then
        local ok, value = pcall(getPlayerBackButtonWheel, playerNum)
        if ok then wheel = value end
    end
    if wheel and type(wheel.onCommand) == "function" then
        local ok, err = pcall(wheel.onCommand, wheel, "PlayerInfo")
        if ok then
            local activeView = safeCall(infoWindow.panel, "getActiveView")
            if activeView and getCurrentFocus(playerNum) == activeView then
                log("character-info activated through vanilla ISBackButtonWheel:onCommand('PlayerInfo'); active tab=" .. getTypeName(activeView))
                return activeView
            end
            log("vanilla PlayerInfo command ran but current focus differs; applying native focus target directly")
        else
            log("vanilla PlayerInfo command failed: " .. tostring(err) .. "; applying its native steps directly")
        end
    end

    -- Fallback mirrors the PlayerInfo branch in ISBackButtonWheel:onCommand.
    safeCall(infoWindow, "setVisible", true)
    safeCall(infoWindow, "addToUIManager")
    local activeView = safeCall(infoWindow.panel, "getActiveView")
    if activeView and type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, playerNum, activeView)
        if ok then
            log("character-info activated through vanilla-equivalent path; active tab=" .. getTypeName(activeView))
            return activeView
        end
        log("vanilla-equivalent character-info focus failed: " .. tostring(err))
    end
    return nil
end

local Y_SHORTCUT_ACTIONS = {
    [1] = "disabled",
    [2] = "building",
    [3] = "crafting",
    [4] = "playerInfo",
    [5] = "health",
    [6] = "inventory",
    [7] = "fitness",
}

local Y_SHORTCUT_FIELD_BY_DIRECTION = {
    up = "yShortcutUp",
    down = "yShortcutDown",
    left = "yShortcutLeft",
    right = "yShortcutRight",
}

local function getYShortcutOptions()
    return rawget(_G, "GamepadQoLSuiteOptions")
end

local function getYShortcutOptionValue(name, fallback)
    local options = getYShortcutOptions()
    local option = options and options[name] or nil
    local value = safeCall(option, "getValue")
    if value == true then return true end
    if value == false then return false end
    local numeric = asNumber(value)
    if numeric ~= nil then return numeric end
    return fallback
end

local tutorialYBypassLogged = false
local function focusLooksLikeTutorialMessage(focus)
    if focus == nil then return false end
    local name = focus.Type or focus.type or focus.className or focus.ClassName or focus.name
    if name == nil then name = safeCall(focus, "getUIName") end
    return string.find(string.lower(tostring(name or "")), "tutorialmessage", 1, true) ~= nil
end

local function isTutorialMode()
    local core = type(getCore) == "function" and getCore() or nil
    if core and type(core.getGameMode) == "function" then
        local ok, mode = pcall(core.getGameMode, core)
        if ok and string.find(string.lower(tostring(mode or "")), "tutorial", 1, true) then
            if not tutorialYBypassLogged then
                tutorialYBypassLogged = true
                log("Tutorial mode detected; Y combo and hold enhancements bypassed, native Y preserved")
            end
            return true
        end
    end
    -- Some tutorial transitions temporarily clear getGameMode() or joypad focus.
    -- The TutorialMessage class is also a reliable signal to keep Y combos out.
    local playerCount = 1
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then playerCount = math.min(value, 4) end
    end
    for playerNum = 0, playerCount - 1 do
        if focusLooksLikeTutorialMessage(getCurrentFocus(playerNum)) then
            if not tutorialYBypassLogged then
                tutorialYBypassLogged = true
                log("TutorialMessage focus detected; Y combo and hold enhancements bypassed")
            end
            return true
        end
    end
    return false
end

-- In tutorial mode pass Y to the game immediately and suppress all GQS Y combos.
-- Outside tutorial mode, the master switch controls interception as usual.
local function isYEnhancementEnabled()
    if isTutorialMode() then return false end
    return getYShortcutOptionValue("yEnhancementEnabled", true) == true
end

local function isYShortcutEnabled()
    return isYEnhancementEnabled() and getYShortcutOptionValue("yShortcutEnabled", true) == true
end

-- Independent sub-switch: Y + left-stick panel navigation can be disabled without
-- disabling Y + D-pad shortcuts, unless the global master switch is off.
isPanelQuickSelectEnabled = function()
    return isYEnhancementEnabled() and getYShortcutOptionValue("panelQuickSelectEnabled", true) == true
end

local function getYShortcutAction(direction)
    local field = Y_SHORTCUT_FIELD_BY_DIRECTION[direction]
    if not field then return "disabled" end
    local fallback = ({ up = 5, right = 3, left = 2, down = 6 })[direction] or 1
    local value = getYShortcutOptionValue(field, fallback)
    if value == true then value = 1 end
    if value == false then value = 1 end
    return Y_SHORTCUT_ACTIONS[value] or "disabled"
end

local function isFocusWithin(focus, parent)
    local current = focus
    for _ = 1, 16 do
        if current == nil then return false end
        if current == parent then return true end
        current = current.parent or safeCall(current, "getParent")
    end
    return false
end

local function runNativeWheelCommand(playerNum, command)
    local wheel = nil
    if type(getPlayerBackButtonWheel) == "function" then
        local ok, value = pcall(getPlayerBackButtonWheel, playerNum)
        if ok then wheel = value end
    end
    if wheel and type(wheel.onCommand) == "function" then
        local ok, err = pcall(wheel.onCommand, wheel, command)
        if ok then
            log("Y shortcut used vanilla Select-wheel command: " .. command)
            return true
        end
        log("vanilla Select-wheel command " .. command .. " failed: " .. tostring(err))
    end

    -- The fallback calls the same native APIs used by ISBackButtonWheel in B42.
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if command == "Building" and player and ISEntityUI and type(ISEntityUI.OpenBuildWindow) == "function" then
        local ok, err = pcall(ISEntityUI.OpenBuildWindow, player, nil, "*")
        if ok then log("Y shortcut opened Building through ISEntityUI fallback"); return true end
        log("Building fallback failed: " .. tostring(err))
    elseif command == "Crafting" and player and ISEntityUI and type(ISEntityUI.OpenHandcraftWindow) == "function" then
        local ok, err = pcall(ISEntityUI.OpenHandcraftWindow, player, nil, "*")
        if ok then log("Y shortcut opened Crafting through ISEntityUI fallback"); return true end
        log("Crafting fallback failed: " .. tostring(err))
    elseif command == "PlayerInfo" then
        local infoWindow = type(getPlayerInfoPanel) == "function" and getPlayerInfoPanel(playerNum) or nil
        local target = infoWindow and { infoWindow = infoWindow } or nil
        if target and activateCharacterInfoThroughVanilla(target, playerNum) then return true end
    end
    return false
end

local function ensureEntityWindowFocus(playerNum, windowKey)
    if not ISEntityUI or type(ISEntityUI.GetWindowInstance) ~= "function" then return end
    local ok, window = pcall(ISEntityUI.GetWindowInstance, playerNum, windowKey)
    if not ok or not window or not isVisible(window) then return end
    local focus = getCurrentFocus(playerNum)
    if isFocusWithin(focus, window) then return end
    if type(setJoypadFocus) == "function" then
        local setOk, err = pcall(setJoypadFocus, playerNum, window)
        if setOk then log("Y shortcut applied native focus to " .. windowKey)
        else log("could not focus " .. windowKey .. ": " .. tostring(err)) end
    end
end

local function activatePlayerInfo(playerNum)
    local infoWindow = type(getPlayerInfoPanel) == "function" and getPlayerInfoPanel(playerNum) or nil
    if not infoWindow then
        log("Y shortcut PlayerInfo failed: info panel is unavailable")
        return false
    end
    local ok = runNativeWheelCommand(playerNum, "PlayerInfo")
    if not ok then
        local view = activateCharacterInfoThroughVanilla({ infoWindow = infoWindow }, playerNum)
        return view ~= nil
    end
    local active = safeCall(infoWindow.panel, "getActiveView")
    if active and type(setJoypadFocus) == "function" and getCurrentFocus(playerNum) ~= active then
        pcall(setJoypadFocus, playerNum, active)
    end
    return true
end

local function activateHealthPanel(playerNum)
    local infoWindow = type(getPlayerInfoPanel) == "function" and getPlayerInfoPanel(playerNum) or nil
    if not infoWindow then
        log("Y shortcut Health failed: info panel is unavailable")
        return false
    end

    -- First activate the PlayerInfo window through the game's own Select-wheel
    -- path, then switch to the health tab and explicitly focus that active view.
    runNativeWheelCommand(playerNum, "PlayerInfo")
    safeCall(infoWindow, "setVisible", true)
    safeCall(infoWindow, "addToUIManager")

    local tabPanel = infoWindow.panel
    local active = safeCall(tabPanel, "getActiveView")
    local activeName = string.lower(getTypeName(active))
    local alreadyHealth = string.find(activeName, "healthpanel", 1, true) ~= nil
    if not alreadyHealth then
        local healthKey = xpSystemText and xpSystemText.health or nil
        local switched = false
        if healthKey ~= nil and type(infoWindow.toggleView) == "function" then
            local ok = pcall(infoWindow.toggleView, infoWindow, healthKey)
            switched = ok
        end
        if not switched and healthKey ~= nil then
            local ok = pcall(function()
                if type(tabPanel.activateView) == "function" then tabPanel:activateView(healthKey)
                elseif type(tabPanel.setActiveView) == "function" then tabPanel:setActiveView(healthKey)
                else error("tab panel has no activateView/setActiveView") end
            end)
            switched = ok
        end
        if not switched then
            log("Y shortcut Health could not switch tab; native health key action unavailable")
            return false
        end
    end
    active = safeCall(tabPanel, "getActiveView")
    if active and type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, playerNum, active)
        if ok then
            log("Y shortcut activated Health and focused " .. getTypeName(active))
            return true
        end
        log("Y shortcut Health opened but focus failed: " .. tostring(err))
    end
    return active ~= nil
end

local function activateFitnessPanel(playerNum)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if not player then
        log("Y shortcut Fitness failed: player is unavailable")
        return false
    end

    local okRequire, requireErr = pcall(require, "ISUI/ISFitnessUI")
    if not ISFitnessUI or type(ISFitnessUI.new) ~= "function" then
        log("Y shortcut Fitness failed: ISFitnessUI unavailable: " .. tostring(requireErr))
        return false
    end

    local instanceIndex = playerNum + 1
    local panel = ISFitnessUI.instance and ISFitnessUI.instance[instanceIndex]
    if panel and isVisible(panel) then
        if JoypadState and JoypadState.players and JoypadState.players[instanceIndex]
            and type(setJoypadFocus) == "function" then
            local okFocus, err = pcall(setJoypadFocus, playerNum, panel)
            if okFocus then
                log("Y shortcut focused existing Fitness panel")
                return true
            end
            log("Y shortcut Fitness focus failed: " .. tostring(err))
            return false
        end
        return true
    end

    -- Reuse the same construction path that already works for the right-D-pad
    -- Fitness option. A hidden stale instance must be removed before rebuilding.
    if panel then
        pcall(function() panel:removeFromUIManager() end)
        ISFitnessUI.instance[instanceIndex] = nil
    end

    local okCreate, newPanel = pcall(function()
        local ui = ISFitnessUI:new(0, 0, 600, 350, player)
        ui:initialise()
        ui:addToUIManager()
        return ui
    end)
    if not okCreate or not newPanel then
        log("Y shortcut Fitness creation failed: " .. tostring(newPanel))
        return false
    end

    if JoypadState and JoypadState.players and JoypadState.players[instanceIndex]
        and type(setJoypadFocus) == "function" then
        local okFocus, err = pcall(setJoypadFocus, playerNum, newPanel)
        if not okFocus then
            log("Y shortcut Fitness opened but focus failed: " .. tostring(err))
            return false
        end
    end

    log("Y shortcut opened Fitness and assigned controller focus")
    return true
end

local function activateInventory(playerNum)
    local inventory = getPlayerInventorySafely(playerNum)
    if not inventory then
        local playerData = ISPlayerData and ISPlayerData[playerNum + 1] or nil
        if playerData and type(playerData.createInventoryInterface) == "function" then
            pcall(playerData.createInventoryInterface, playerData)
            inventory = getPlayerInventorySafely(playerNum)
        end
    end
    if not inventory then
        log("Y shortcut Backpack failed: player inventory is unavailable")
        return false
    end
    safeCall(inventory, "setVisible", true)
    -- Do not add the inventory to UIManager again; createInventoryInterface owns it.
    if type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, playerNum, inventory)
        if ok then
            log("Y shortcut opened Backpack and focused ISInventoryPage")
            return true
        end
        log("Y shortcut opened Backpack but focus failed: " .. tostring(err))
    end
    return true
end

local function isTutorialMessageObject(object)
    if object == nil then return false end
    local name = string.lower(tostring(getTypeName(object) or "") .. " " ..
        tostring(object.Type or object.type or object.className or object.ClassName or object.name or ""))
    return string.find(name, "tutorialmessage", 1, true) ~= nil
end

local function hookTutorialMessageUpdate(tutorialMessage, playerNum)
    if not tutorialMessage or tutorialMessage._gqsTutorialYGuardInstalled then return end
    local originalUpdate = tutorialMessage.update
    if type(originalUpdate) ~= "function" then return end

    local assigned = pcall(function()
        tutorialMessage._gqsTutorialYOriginalUpdate = originalUpdate
        tutorialMessage.update = function(self, ...)
            local ok, result = pcall(originalUpdate, self, ...)
            if ok then
                self._gqsTutorialInventoryFallbackDone = false
                return result
            end

            local failure = tostring(result)
            if string.find(failure, "openInventoryJoypad", 1, true) == nil then
                error(result)
            end

            -- Build 42.21's tutorial callback throws from Steps.lua while trying
            -- to open the backpack. Recover through the same safe inventory path
            -- used by GQS shortcuts, and contain only this known callback error.
            if not self._gqsTutorialInventoryFallbackDone then
                self._gqsTutorialInventoryFallbackDone = true
                print("[GQS Tutorial Y] Caught vanilla openInventoryJoypad error; opening inventory through the safe UI path")
                activateInventory(playerNum)
            end
            return nil
        end
        tutorialMessage._gqsTutorialYGuardInstalled = true
    end)
    if not assigned then
        print("[GQS Tutorial Y] Could not install the tutorial inventory callback guard")
    end
end

local function closeVisibleSelectWheel(playerNum, reason)
    local wheel = nil
    if type(getPlayerBackButtonWheel) == "function" then
        local ok, value = pcall(getPlayerBackButtonWheel, playerNum)
        if ok then wheel = value end
    end
    if not wheel or not isVisible(wheel) then return false end

    local visibleOk = pcall(function() wheel:setVisible(false) end)
    local removeOk = pcall(function() wheel:removeFromUIManager() end)
    if getCurrentFocus(playerNum) == wheel and type(setJoypadFocus) == "function" then
        -- A shortcut normally focuses its destination first. If a command failed
        -- to move focus, don't leave the now-hidden Select wheel as the UI focus.
        pcall(setJoypadFocus, playerNum, nil)
    end
    log("closed visible Select wheel after Y+D-pad action (" .. tostring(reason)
        .. "; setVisible=" .. tostring(visibleOk) .. ", removeFromUIManager=" .. tostring(removeOk) .. ")")
    return true
end

local function executeYShortcutAction(state, action)
    local playerNum = state.playerNum
    if action == "building" then
        local success = runNativeWheelCommand(playerNum, "Building")
        ensureEntityWindowFocus(playerNum, "BuildWindow")
        return success
    elseif action == "crafting" then
        local success = runNativeWheelCommand(playerNum, "Crafting")
        ensureEntityWindowFocus(playerNum, "HandcraftWindow")
        return success
    elseif action == "playerInfo" then
        return activatePlayerInfo(playerNum)
    elseif action == "health" then
        return activateHealthPanel(playerNum)
    elseif action == "inventory" then
        return activateInventory(playerNum)
    elseif action == "fitness" then
        return activateFitnessPanel(playerNum)
    end
    return false
end

handleYShortcut = function(state, direction)
    if not state or not direction then return false end
    if isTutorialMode() then return false end
    -- Same direction, still held: this is the repeat of the press that already ran
    -- (the D-pad event can be re-delivered after the focus moved to the window we
    -- just opened). Swallow it instead of firing the same action twice.
    if state.lastDpadDirection == direction then
        return state.shortcutActionExecuted == true
    end
    state.lastDpadDirection = direction
    state.cancelNativeY = true
    state.directionInput = true

    if not isYShortcutEnabled() then return false end
    if state.usedSelector or state.selectorActive then
        log("Y+D-pad shortcut ignored because left-stick panel selection is already active")
        return false
    end

    local action = getYShortcutAction(direction)
    if action == "disabled" then
        log("Y+" .. direction .. " has no shortcut assigned; native Y action suppressed")
        return false
    end

    -- Consume the combo before invoking a native UI path, so focus changes caused
    -- by opening the target do not let the same held D-pad event fire twice.
    -- A *different* direction while Y is still held is deliberately allowed to run
    -- again: that is how the player hops health -> crafting -> building without
    -- releasing Y. Native Y stays cancelled for the rest of this press because
    -- cancelNativeY/directionInput were set above and are only cleared on release.
    state.shortcutActionExecuted = true
    state.usedShortcut = true
    state.shortcutActionName = action
    state.selectorEligible = false
    state.selectorArmed = false
    state.axisLatched = true
    drawSelection(nil)

    local success = executeYShortcutAction(state, action)
    if success then
        closeVisibleSelectWheel(state.playerNum, action)
    end
    log(string.format("Y+%s shortcut action=%s %s", direction, action, success and "executed" or "attempted; API reported failure"))
    return true
end

local function processStickNudge(state, axisX, axisY)
    if not isPanelQuickSelectEnabled() then return end
    if state.axisLatched then return end
    if math.max(math.abs(axisX), math.abs(axisY)) < GQS.DEADZONE_ON then return end
    local dirX, dirY = quantizeDirection(axisX, axisY)
    if dirX == nil then return end
    state.axisLatched = true
    state.usedSelector = true

    local windows, screen, scanStats = collectWindows(state.playerNum)
    if not state.candidateListLogged then
        if screen then logWindows(windows, screen, scanStats) end
        state.candidateListLogged = true
    end
    if #windows == 0 then
        log("Y+left-stick detected, but no eligible visible window was found")
        return
    end

    state.selectorActive = true

    local target
    if state.selected then
        -- After the first directional selection, each new stick nudge moves to
        -- a neighbouring window in that relative direction. If no neighbour
        -- exists, keep the current preview visibly selected.
        target = chooseDirectional(windows, state.selected.cx, state.selected.cy, dirX, dirY, state.selected)
        if not target then target = state.selected end
    else
        -- First nudge selects a window in the screen region indicated by the
        -- stick direction. Always choose the best matching region if any window
        -- is available, even if its center sits on a quadrant boundary.
        target = chooseInitialDirectional(windows, screen, dirX, dirY)
    end

    if target then
        state.selected = target
        state.selectorActive = true
        -- Transfer real joypad focus immediately. The game's native green focus
        -- border then follows the selected window during the Y hold; no separate
        -- orange overlay/confirmation-on-release is needed.
        if type(setJoypadFocus) == "function" then
            local targetName = string.lower((target.name or "") .. " " .. getTypeName(target.object))
            local isCharacterInfoTarget = target.infoWindow ~= nil
                or string.find(targetName, "ischaracterinfowindow", 1, true) ~= nil
                or string.find(targetName, "ishealthpanel", 1, true) ~= nil
                or string.find(targetName, "ischaracterprotection", 1, true) ~= nil
                or string.find(targetName, "ischaracterinfo", 1, true) ~= nil
            if isCharacterInfoTarget then
                -- Do not focus the outer ISCharacterInfoWindow. Use vanilla's
                -- remembered active-tab route so the native green border updates immediately.
                local activeView = activateCharacterInfoThroughVanilla(target, state.playerNum)
                if activeView then
                    target.object = activeView
                    target.name = "ISCharacterInfoWindow." .. getTypeName(activeView)
                    if not target.infoWindow and type(getPlayerInfoPanel) == "function" then
                        local ok, value = pcall(getPlayerInfoPanel, state.playerNum)
                        if ok then target.infoWindow = value end
                    end
                    log(string.format("character-info live focus follows vanilla active tab: %s at (%.0f,%.0f)", target.name, target.cx, target.cy))
                else
                    local ok, err = pcall(setJoypadFocus, state.playerNum, target.object)
                    if ok then log("character-info fallback focused " .. target.name)
                    else log("character-info focus switch failed for " .. target.name .. ": " .. tostring(err)) end
                end
            else
                local ok, err = pcall(setJoypadFocus, state.playerNum, target.object)
                if ok then
                    log(string.format("live focus switched %s -> %s at (%.0f,%.0f); native green border should be visible now", directionName(dirX, dirY), target.name, target.cx, target.cy))
                else
                    log("live focus switch failed for " .. target.name .. ": " .. tostring(err))
                end
            end
        else
            log("setJoypadFocus unavailable; selected " .. target.name .. " but could not switch live focus")
        end
    else
        log(string.format("direction %s found no selectable window", directionName(dirX, dirY)))
    end
    -- The native joypad-focus border is the live selection indicator.
end

local function hookFocusObject(focus, playerNum)
    if focus == nil or type(focus) ~= "table" then return end
    local state = stateFor(playerNum)

    if not focus._gqsPanelQuickSelectDownHooked and type(focus.onJoypadDown) == "function" then
        local originalDown = focus.onJoypadDown
        local assigned = pcall(function()
            focus._gqsPanelQuickSelectOriginalDown = originalDown
            focus.onJoypadDown = function(self, button, ...)
                -- Preserve the map's native, immediate event context. In
                -- particular, never queue ISWorldMap.onJoypadDown for OnTick.
                if isWorldMapObject(self) then
                    return originalDown(self, button, ...)
                end
                if isYButton(button) then
                    if not isYEnhancementEnabled() then
                        -- Full-off mode: do not intercept, queue, or delay the native Y action.
                        return originalDown(self, button, ...)
                    end
                    local currentState = stateFor(playerNum)
                    if currentState.pendingY == nil then
                        currentState.pendingY = { focus = self, original = originalDown, button = button }
                        currentState.dpadDownAtYEvent = isAnyDpadDown(getControllerId(playerNum))
                        log("captured Y-down order: D-pad already down=" .. tostring(currentState.dpadDownAtYEvent))
                    end
                    currentState.yEventIntercepted = true
                    log("Y button event intercepted; delaying native action until release")
                    return true
                end
                return originalDown(self, button, ...)
            end
            focus._gqsPanelQuickSelectDownHooked = true
        end)
        if not assigned then log("could not intercept Y on current focus object") end
    elseif focus._gqsPanelQuickSelectDownHooked and not focus._gqsPanelQuickSelectOriginalDown and type(focus.onJoypadDown) == "function" then
        focus._gqsPanelQuickSelectOriginalDown = focus.onJoypadDown
    end

    local directions = {
        { name = "onJoypadDirUp" },
        { name = "onJoypadDirDown" },
        { name = "onJoypadDirLeft" },
        { name = "onJoypadDirRight" },
    }
    for i = 1, #directions do
        local methodName = directions[i].name
        local flagName = "_gqsPanelQuickSelectHooked_" .. methodName
        if not focus[flagName] and type(focus[methodName]) == "function" then
            local originalMethod = focus[methodName]
            local assigned = pcall(function()
                focus[methodName] = function(self, ...)
                    local currentState = stateFor(playerNum)
                    -- Left/right/up/down on the map must remain entirely native.
                    -- Also ignore a still-held Y that began on the map and then
                    -- survived a focus change back to another panel.
                    if isWorldMapObject(self) or currentState.suppressYUntilRelease then
                        return originalMethod(self, ...)
                    end
                    if isYEnhancementEnabled() and (currentState.wasYDown or isYDown(playerNum)) then
                        if not currentState.wasYDown then
                            local axisX, axisY = getStickAxes(playerNum)
                            local magnitude = math.max(math.abs(axisX), math.abs(axisY))
                            beginYGesture(currentState, magnitude, axisX, axisY, getCurrentFocus(playerNum))
                        end
                        local direction = methodName:match("onJoypadDir(%a+)")
                        direction = direction and string.lower(direction) or nil
                        if currentState.ignoreYCombosForGesture then
                            if not currentState.ignoredDpadLogged then
                                log("D-pad callback ignored: this Y hold began while D-pad was already down")
                                currentState.ignoredDpadLogged = true
                            end
                            return true
                        end
                        currentState.cancelNativeY = true
                        currentState.directionInput = true
                        local comboConsumed = direction and handleYShortcut and handleYShortcut(currentState, direction) or false
                        if not currentState.directionCancelLogged then
                            log("D-pad direction received after Y-down; native Y action cancelled for this press")
                            currentState.directionCancelLogged = true
                        end
                        if comboConsumed or currentState.selectorActive then return true end
                    end
                    return originalMethod(self, ...)
                end
                focus[flagName] = true
            end)
            if not assigned then log("could not hook " .. methodName) end
        end
    end
end

local function recoverFocusAfterEmptySelector(state)
    -- If the left-stick selector was used but found no target, explicitly restore
    -- the focus route that existed before Y. In hosted multiplayer, an invisible
    -- stale UI focus can otherwise continue swallowing world D-pad/radial input.
    -- Never steal focus from a currently visible UI panel.
    if not state then return end

    local playerNum = state.playerNum
    local current = getCurrentFocus(playerNum)
    local baseline = state.focusAtYDown
    local currentVisible = current ~= nil and isVisible(current)
    local baselineVisible = baseline ~= nil and isVisible(baseline)

    if currentVisible then
        log(string.format(
            "empty selector focus recovery skipped: current focus is visible (%s)",
            getTypeName(current)))
        return
    end

    if type(setJoypadFocus) ~= "function" then
        log("empty selector focus recovery unavailable: setJoypadFocus is missing")
        return
    end

    local restoreFocus = baselineVisible and baseline or nil
    local ok, err = pcall(setJoypadFocus, playerNum, restoreFocus)
    if ok then
        log(string.format(
            "empty selector focus recovery applied: current=%s visible=%s; baseline=%s visible=%s; restored=%s",
            current and getTypeName(current) or "nil",
            tostring(currentVisible),
            baseline and getTypeName(baseline) or "nil",
            tostring(baselineVisible),
            restoreFocus and getTypeName(restoreFocus) or "nil/world focus"))
    else
        log("empty selector focus recovery failed: " .. tostring(err))
    end
end

local function finishGesture(state)
    -- Restore the movement state once Y is released or the controller disconnects.
    setSelectorMovementLock(state, false)
    local selected = state.selected
    local usedSelector = state.usedSelector
    local cancelNativeY = state.cancelNativeY or state.directionInput

    if usedSelector and selected and isVisible(selected.object) then
        -- Focus was already switched on every stick nudge. Reassert only if some
        -- other UI callback changed it during the gesture.
        if getCurrentFocus(state.playerNum) ~= selected.object and type(setJoypadFocus) == "function" then
            local ok, err = pcall(setJoypadFocus, state.playerNum, selected.object)
            if ok then log("focus confirmed on " .. selected.name)
            else log("final focus confirmation failed: " .. tostring(err)) end
        else
            log("selection complete; live focus kept on " .. selected.name)
        end
    elseif usedSelector and not selected then
        recoverFocusAfterEmptySelector(state)
        log("selector gesture ended without a target; native Y action suppressed")
    elseif cancelNativeY then
        log("Y released after directional input; native Y/backpack action suppressed")
    else
        runDeferredNativeY(state)
    end

    state.wasYDown = false
    state.pendingY = nil
    state.selectorEligible = false
    state.selectorArmed = false
    state.selectorActive = false
    state.usedSelector = false
    state.selected = nil
    state.axisLatched = false
    state.candidateListLogged = false
    state.cancelNativeY = false
    state.directionInput = false
    state.directionCancelLogged = false
    state.usedShortcut = false
    state.shortcutActionExecuted = false
    state.shortcutActionName = nil
    state.lastDpadDirection = nil
    state.dpadDownAtYEvent = nil
    state.ignoreYCombosForGesture = false
    state.ignoredDpadLogged = false
    state.focusAtYDown = nil
    state.prematureActionReverted = false
    state.startedWithStickActive = false
    state.yEventIntercepted = false
    state.inventoryVisibleAtYDown = nil
    state.lootVisibleAtYDown = nil
    drawSelection(nil)
end

local function syncOverlaySize()
    if not GQS.overlay then return end
    local core = type(getCore) == "function" and getCore() or nil
    if core then
        local width, height = 0, 0
        if type(core.getScreenWidth) == "function" then
            local ok, value = pcall(function() return core:getScreenWidth() end)
            if ok then width = asNumber(value) or 0 end
        end
        if type(core.getScreenHeight) == "function" then
            local ok, value = pcall(function() return core:getScreenHeight() end)
            if ok then height = asNumber(value) or 0 end
        end
        if width > 0 and GQS.overlay.width ~= width then safeCall(GQS.overlay, "setWidth", width) end
        if height > 0 and GQS.overlay.height ~= height then safeCall(GQS.overlay, "setHeight", height) end
    end
    if GQS.overlay.targetRect then
        pcall(function() GQS.overlay:setAlwaysOnTop(true) end)
        safeCall(GQS.overlay, "bringToTop")
    end
end

local function discardGestureWithoutReplay(state, reason)
    if not state then return end
    setSelectorMovementLock(state, false)
    state.wasYDown = false
    state.pendingY = nil
    state.selectorEligible = false
    state.selectorArmed = false
    state.selectorActive = false
    state.usedSelector = false
    state.selected = nil
    state.axisLatched = false
    state.candidateListLogged = false
    state.cancelNativeY = false
    state.directionInput = false
    state.directionCancelLogged = false
    state.usedShortcut = false
    state.shortcutActionExecuted = false
    state.shortcutActionName = nil
    state.lastDpadDirection = nil
    state.dpadDownAtYEvent = nil
    state.ignoreYCombosForGesture = false
    state.ignoredDpadLogged = false
    state.focusAtYDown = nil
    state.prematureActionReverted = false
    state.startedWithStickActive = false
    state.yEventIntercepted = false
    state.inventoryVisibleAtYDown = nil
    state.lootVisibleAtYDown = nil
    drawSelection(nil)
    log(tostring(reason or "Y enhancement disabled") .. "; cleared pending gesture without replay")
end

local function onTick()
    restoreTutorialInventoryBlinkMethod()
    syncOverlaySize()
    local playerCount = 1
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then playerCount = math.min(value, 4) end
    end

    for playerNum = 0, playerCount - 1 do
        local controllerId = getControllerId(playerNum)
        if controllerId >= 0 then
            local state = stateFor(playerNum)
            local focus = getCurrentFocus(playerNum)
            if isTutorialMessageObject(focus) then
                hookTutorialMessageUpdate(focus, playerNum)
            end
            if isRBZoomButtonChordActive(playerNum, "Y") then
                -- Do not let this Y hold arm panel selection or be replayed as
                -- vanilla Y when released; GQSRBZoom owns it as RB+Y zoom.
                if state.wasYDown or state.pendingY ~= nil or state.selectorActive or state.movementLockActive then
                    discardGestureWithoutReplay(state, "RB+Y zoom chord owns Y input")
                end
                state.suppressYUntilRelease = isYDown(playerNum)
                state.lastFocus = focus
                state.lastFocusKnown = true
            else
                if isWorldMapObject(focus) and not isWorldMapFocus(focus) then
                    local fallback = state.lastFocusKnown and state.lastFocus or nil
                    if fallback == nil or isWorldMapObject(fallback) or not isVisible(fallback) then
                        fallback = nil
                    end
                    local ok, err = false, nil
                    if type(setJoypadFocus) == "function" then
                        ok, err = pcall(setJoypadFocus, playerNum, fallback)
                    end
                    if ok then
                        focus = getCurrentFocus(playerNum)
                        if isWorldMapObject(focus) then focus = fallback end
                        log(fallback and "restored previous visible focus after hidden world-map focus" or "cleared stale hidden world-map focus")
                    else
                        -- Even if the engine rejected the reset, do not let the
                        -- hidden map object become the baseline for a new gesture.
                        focus = fallback
                        log("could not reset hidden world-map focus: " .. tostring(err))
                    end
                end
                if not isYEnhancementEnabled() then
                    if state.wasYDown or state.pendingY ~= nil or state.selectorActive or state.movementLockActive then
                        discardGestureWithoutReplay(state, "global Y enhancement disabled")
                    end
                    state.lastFocus = focus
                    state.lastFocusKnown = true
                elseif isWorldMapFocus(focus) then
                    -- While ISWorldMap owns focus, let Y and every direction reach
                    -- vanilla immediately. If Y is held as the map opens, cancel the
                    -- pending selector without replay and suppress re-arming until
                    -- that same physical Y press is released.
                    local gestureWasPending = state.wasYDown or state.pendingY ~= nil
                        or state.selectorActive or state.movementLockActive
                    state.suppressYUntilRelease = isYDown(playerNum)
                    if gestureWasPending then
                        discardGestureWithoutReplay(state, "world map has joypad focus; native input preserved")
                    end
                    -- Keep lastFocus pointing at the last non-map UI (if any).
                    -- The map object may remain as a stale focus after it closes.
                elseif state.suppressYUntilRelease then
                    -- The map closed while Y was still held. Do not turn the same
                    -- physical press into a new gesture on the newly focused panel.
                    if not isYDown(playerNum) then state.suppressYUntilRelease = false end
                    state.lastFocus = focus
                    state.lastFocusKnown = true
                else
                    if focus then hookFocusObject(focus, playerNum) end

                    local yDown = isYDown(playerNum)
                local axisX, axisY = getStickAxes(playerNum)
                local axisMagnitude = math.max(math.abs(axisX), math.abs(axisY))

                if yDown then
                    if not state.wasYDown then
                        beginYGesture(state, axisMagnitude, axisX, axisY, focus)
                        if state.focusAtYDown then hookFocusObject(state.focusAtYDown, playerNum) end
                    end

                    -- Any new analog input during a neutral-stick Y gesture cancels
                    -- the normal inventory action, even if movement locking failed.
                    -- A stick that was already moving before Y is the deliberate
                    -- walk+Y exception and keeps the ordinary Y action on release.
                    if isPanelQuickSelectEnabled() and not state.startedWithStickActive and axisMagnitude >= GQS.DEADZONE_ON then
                        state.cancelNativeY = true
                        state.directionInput = true
                    end

                    -- D-pad input during Y cancels the pending native Y action. UI
                    -- focus handlers normally catch the combo immediately; this polling
                    -- edge-detection is a fallback when no focus handler receives it.
                    local dpadDirection = getDpadDirection(controllerId)
                    if dpadDirection then
                        if state.ignoreYCombosForGesture then
                            -- D-pad was down at Y-down: leave native input alone and
                            -- do not let polling fire a synthetic shortcut.
                            if not state.ignoredDpadLogged then
                                log("polling ignored D-pad because it was already down at Y-down")
                                state.ignoredDpadLogged = true
                            end
                            state.lastDpadDirection = dpadDirection
                        else
                            state.cancelNativeY = true
                            state.directionInput = true
                            if dpadDirection ~= state.lastDpadDirection and handleYShortcut then
                                handleYShortcut(state, dpadDirection)
                            end
                        end
                    else
                        state.lastDpadDirection = nil
                    end

                    -- If a native global Y handler managed to change focus before our
                    -- per-window callback intercepted it, revert that change while the
                    -- button remains held. It will be replayed on release only when the
                    -- gesture had no directional input.
                    restoreEarlyYAction(state)

                    if axisMagnitude <= GQS.DEADZONE_OFF then
                        state.axisLatched = false
                    elseif state.selectorEligible and state.selectorArmed and not state.usedShortcut and axisMagnitude >= GQS.DEADZONE_ON then
                        processStickNudge(state, axisX, axisY)
                    end
                elseif state.wasYDown or state.pendingY ~= nil then
                    finishGesture(state)
                    state.lastFocus = getCurrentFocus(playerNum)
                    state.lastFocusKnown = true
                elseif state.selectorActive then
                    -- Defensive cleanup if the controller disconnects or loses state.
                    finishGesture(state)
                    state.lastFocus = getCurrentFocus(playerNum)
                    state.lastFocusKnown = true
                else
                    state.lastFocus = focus
                    state.lastFocusKnown = true
                end
                end -- isYEnhancementEnabled()
            end -- RB+Y zoom chord owns the Y press
        else
            local state = GQS.states[playerNum]
            if state and (state.wasYDown or state.pendingY ~= nil or state.selectorActive) then
                finishGesture(state)
            end
        end
    end
end

-- Do not create/use the custom orange overlay; the game-native green joypad-focus
-- border is switched live to the target UI whenever the left stick is nudged.
if Events and Events.OnTick then Events.OnTick.Add(onTick) end

-- Read-only query used by GQSYHoldSidebarHints. True only while a Y gesture is
-- active and still able to fire a D-pad shortcut for this press. Keeps the
-- sidebar hint in sync with this state machine instead of duplicating the
-- tutorial / world-map / switch logic.
-- Deliberately does not test the current focus: the gesture machinery also runs
-- while a panel has focus, and state.focusAtYDown can hold a stale panel after
-- it was closed, so testing either one would hide a usable hint.
-- Also deliberately does not test directionInput/usedShortcut: several combos may
-- run during a single Y hold, so the hints stay up until Y is released.
function GQSPanelQuickSelect.isYShortcutHintActive(playerNum)
    if type(playerNum) ~= "number" or playerNum < 0 then return false end
    if not isYShortcutEnabled() then return false end
    if isTutorialMode() then return false end
    local state = GQS.states[playerNum]
    if type(state) ~= "table" or state.wasYDown ~= true then return false end
    if state.ignoreYCombosForGesture then return false end
    if state.selectorActive then return false end
    return true
end

log("loaded; global Y enhancement switch controls all Y interception; when off, native Y is immediate. When on: Y+D-pad shortcuts and Y+left-stick panel selection are independently configurable.")
