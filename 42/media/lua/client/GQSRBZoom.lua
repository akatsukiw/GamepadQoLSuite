-- Gamepad QoL Suite: configurable RB shortcuts.
-- World-focus defaults (inventory and loot windows must be closed):
--   RB + Up/Down  -> previous/next active Moodle
--   RB + Left/Right -> zoom out/in
--   RB + Y/A -> zoom in/out (each independently configurable)
-- Native Y/A world actions are consumed before no-focus dispatch when the
-- ordered RB chord is active. Existing UI focus and container RB+Up/Down paths
-- remain owned by the original game/container-switch module.
-- v1.5.0.39 keeps both dispatcher interceptors, uses one runtime Interact-mask state manager, and removes temporary action-entry tracing.

local playerStates = {}
local warnedZoomUnavailable = false

-- Retain the shared historical action index table for compatibility with
-- modules that use the old action vocabulary. Mod Options now uses a smaller,
-- direction-specific list: Up/Down = disabled/previous/next; Left/Right = disabled/in/out.
local ACTION_BY_INDEX = {
    [1] = "none",
    [2] = "zoomIn",
    [3] = "zoomOut",
    [4] = "moodlePrevious",
    [5] = "moodleNext",
}
local ACTION_BY_DIRECTION_INDEX = {
    Up = { [1] = "none", [2] = "moodlePrevious", [3] = "moodleNext" },
    Down = { [1] = "none", [2] = "moodlePrevious", [3] = "moodleNext" },
    Left = { [1] = "none", [2] = "zoomIn", [3] = "zoomOut" },
    Right = { [1] = "none", [2] = "zoomIn", [3] = "zoomOut" },
}
local DEFAULT_ACTIONS = {
    Up = "moodlePrevious",
    Down = "moodleNext",
    Left = "zoomOut",
    Right = "zoomIn",
}
local OPTION_KEYS = {
    Up = "rbDpadUpAction",
    Down = "rbDpadDownAction",
    Left = "rbDpadLeftAction",
    Right = "rbDpadRightAction",
}
local DIRECTION_DATA = {
    { name = "Up", button = "DPadUp", opposite = "Down" },
    { name = "Down", button = "DPadDown", opposite = "Up" },
    { name = "Left", button = "DPadLeft", opposite = "Right" },
    { name = "Right", button = "DPadRight", opposite = "Left" },
}
local BUTTON_BY_DIRECTION = {
    Up = "DPadUp", Down = "DPadDown", Left = "DPadLeft", Right = "DPadRight",
}
local ACTION_BUTTONS = {
    { name = "Y", option = "rbButtonYAction", button = "Y", default = "zoomIn" },
    { name = "A", option = "rbButtonAAction", button = "A", default = "zoomOut" },
}

local function debugPrint(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rbZoom", message)
    end
end

local function readOptionValue(option)
    if not option then return nil end
    if type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok and value ~= nil then return value end
    end
    local value = option.value
    if value ~= nil then return value end
    return nil
end

local function getConfiguredAction(direction)
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    if options then
        local enabled = readOptionValue(options.rbExtensionsEnabled)
        if enabled == false or enabled == 0 then return "none" end
        local option = options[OPTION_KEYS[direction] or ""]
        local index = tonumber(readOptionValue(option))
        local directionMap = ACTION_BY_DIRECTION_INDEX[direction]
        if index and directionMap and directionMap[index] then return directionMap[index] end
        -- Runtime compatibility in case old five-choice values survive while
        -- Mod Options is rebuilding/clamping the smaller current combo boxes.
        if direction == "Up" or direction == "Down" then
            if index == 4 then return "moodlePrevious" end
            if index == 5 then return "moodleNext" end
        elseif direction == "Left" or direction == "Right" then
            if index == 4 or index == 5 then return DEFAULT_ACTIONS[direction] end
        end
        if index ~= nil then return "none" end
    end
    return DEFAULT_ACTIONS[direction] or "none"
end

local function getConfiguredActionButton(name)
    local actionButton
    for _, candidate in ipairs(ACTION_BUTTONS) do
        if candidate.name == name then actionButton = candidate; break end
    end
    if not actionButton then return "none" end
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    if options then
        local enabled = readOptionValue(options.rbExtensionsEnabled)
        if enabled == false or enabled == 0 then return "none" end
        local index = tonumber(readOptionValue(options[actionButton.option]))
        if index == 1 then return "none" end
        if index == 2 then return "zoomIn" end
        if index == 3 then return "zoomOut" end
    end
    return actionButton.default
end

-- Shared read-only resolver used by the moodle selector module and native
-- input interceptors. Consumers query current settings instead of caching them.
GQS_RBControls = GQS_RBControls or {}
GQS_RBControls.getAction = getConfiguredAction
GQS_RBControls.getButtonAction = getConfiguredActionButton

local function getJoypadBind(playerIndex)
    local player = getSpecificPlayer and getSpecificPlayer(playerIndex) or nil
    if not player or type(player.getJoypadBind) ~= "function" then return -1 end
    local ok, bind = pcall(function() return player:getJoypadBind() end)
    if ok and type(bind) == "number" then return bind end
    return -1
end

local function isButtonDown(buttonName, joypadBind)
    if type(joypadBind) ~= "number" or joypadBind < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and buttons[buttonName]
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(function() return button:isDown(joypadBind) end)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    local legacyButton = joypad and joypad[buttonName]
    if legacyButton ~= nil and type(isJoypadPressed) == "function" then
        local ok, down = pcall(function() return isJoypadPressed(joypadBind, legacyButton) end)
        if ok then return down == true end
    end
    return false
end

local function pageIsVisible(page)
    if not page then return false end
    if type(page.isReallyVisible) == "function" then
        local ok, visible = pcall(page.isReallyVisible, page)
        if ok then return visible == true end
    end
    if type(page.getIsVisible) == "function" then
        local ok, visible = pcall(page.getIsVisible, page)
        if ok then return visible == true end
    end
    return page.visible == true
end

local function areInventoryWindowsClosed(playerIndex)
    local inventoryPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
    return not pageIsVisible(inventoryPage) and not pageIsVisible(lootPage)
end

local function getCurrentJoypadFocus(playerIndex)
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerIndex)
        if ok then return focus end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerIndex]
    return data and data.focus or nil
end

-- RB shortcuts are world-context actions only. When a crafting/building/other
-- panel owns joypad focus, its native RB+D-pad navigation must take priority.
local function hasWorldFocus(playerIndex)
    return getCurrentJoypadFocus(playerIndex) == nil
end

local function getActionButtonChordState(playerIndex, buttonName)
    local action = getConfiguredActionButton(buttonName)
    local bind = getJoypadBind(playerIndex)
    local state = playerStates[playerIndex]
    local rbDown = bind >= 0 and isButtonDown("RightBump", bind)
    local buttonDown = bind >= 0 and isButtonDown(buttonName, bind)
    local buttonWasDownAtRB = state and state.actionButtonDownAtRB
        and state.actionButtonDownAtRB[buttonName] == true or false
    local awaitingRelease = state and state.actionButtonAwaitRelease
        and state.actionButtonAwaitRelease[buttonName] == true or false
    local eligible = bind >= 0 and areInventoryWindowsClosed(playerIndex) and hasWorldFocus(playerIndex)
    return {
        action = action,
        bind = bind,
        eligible = eligible,
        rbDown = rbDown == true,
        buttonDown = buttonDown == true,
        buttonWasDownAtRB = buttonWasDownAtRB,
        awaitingRelease = awaitingRelease,
        active = action ~= "none" and eligible and rbDown and buttonDown and not awaitingRelease,
    }
end

local function isActionButtonChordDown(playerIndex, buttonName)
    if getConfiguredActionButton(buttonName) == "none" then return false end
    local bind = getJoypadBind(playerIndex)
    if bind < 0 or not areInventoryWindowsClosed(playerIndex) or not hasWorldFocus(playerIndex) then return false end
    if not isButtonDown("RightBump", bind) or not isButtonDown(buttonName, bind) then return false end
    local state = playerStates[playerIndex]
    return not (state and state.actionButtonAwaitRelease and state.actionButtonAwaitRelease[buttonName])
end

GQS_RBControls.getButtonAction = getConfiguredActionButton
GQS_RBControls.isButtonChordDown = isActionButtonChordDown
GQS_RBControls.getButtonChordState = getActionButtonChordState

-- Resolve the local player robustly because JoypadControllerData.joypad.player
-- can be exposed as either a player index or an IsoPlayer object across builds.
local function resolvePlayerIndex(value)
    local playerIndex
    if type(value) == "number" then
        playerIndex = value
    elseif type(value) == "string" then
        playerIndex = tonumber(value)
    end
    if playerIndex ~= nil and playerIndex >= 0 and playerIndex <= 3 then return playerIndex end

    if value ~= nil and type(value.getPlayerNum) == "function" then
        local ok, result = pcall(function() return value:getPlayerNum() end)
        if ok and type(result) == "number" and result >= 0 and result <= 3 then return result end
    end
    if type(value) == "table" then
        local result = tonumber(value.playerNum or value.PlayerNum)
        if result ~= nil and result >= 0 and result <= 3 then return result end
    end
    if value ~= nil and type(getSpecificPlayer) == "function" then
        for i = 0, 3 do
            local ok, player = pcall(getSpecificPlayer, i)
            if ok and player == value then return i end
        end
    end
    return nil
end

local function getControllerPlayerIndex(controllerData)
    local joypadData = controllerData and controllerData.joypad or nil
    local playerIndex = joypadData and resolvePlayerIndex(joypadData.player) or nil
    if playerIndex ~= nil then return playerIndex end

    local controllerId = controllerData and tonumber(controllerData.id) or nil
    if controllerId ~= nil then
        for i = 0, 3 do
            if getJoypadBind(i) == controllerId then return i end
        end
    end
    return nil
end

local function isNativeButton(button, buttonName)
    local buttons = rawget(_G, "JoypadButton")
    if buttons and buttons[buttonName] ~= nil and button == buttons[buttonName] then return true end

    local joypad = rawget(_G, "Joypad")
    if joypad then
        local legacy = joypad[buttonName .. "Button"]
        if legacy == nil then legacy = joypad[buttonName] end
        if legacy ~= nil and button == legacy then return true end
    end

    return type(button) == "string" and string.upper(button) == buttonName
end

local setInteractAExplicitlyMasked

local function shouldConsumeNativeButton(controllerData, button)
    if not controllerData or not controllerData.joypad then return false end
    -- onPressButtonNoFocus is already the native no-focus path. Do not use the
    -- JoypadData.focus field here as it can lag the dispatcher transition.

    local playerIndex = getControllerPlayerIndex(controllerData)
    if playerIndex == nil then
        if isNativeButton(button, "Y") or isNativeButton(button, "A") then
            debugPrint("Native face-button dispatch observed, but player index could not be resolved; input was not consumed")
        end
        return false
    end
    if not areInventoryWindowsClosed(playerIndex) or not hasWorldFocus(playerIndex) then return false end

    if isNativeButton(button, "Y") and isActionButtonChordDown(playerIndex, "Y") then
        return true, playerIndex, "Y"
    end
    if isNativeButton(button, "A") and isActionButtonChordDown(playerIndex, "A") then
        -- Mask the separate character-action binding before its next native poll.
        setInteractAExplicitlyMasked(true, "JoypadControllerData A dispatcher")
        return true, playerIndex, "A"
    end
    return false
end

local nativeHookRegistry = rawget(_G, "GQS_RBNativeInputHookRegistry")
if type(nativeHookRegistry) ~= "table" then
    nativeHookRegistry = {}
    _G.GQS_RBNativeInputHookRegistry = nativeHookRegistry
end

-- The character-action layer polls CharacterJoypadButtonBinding independently
-- of JoypadControllerData's Lua dispatch. On the observed Build 42.21.0 log,
-- Interact remained mapped to A and reported isDown=true during a consumed
-- RB+A press. Temporarily mask only Interact's A button while the ordered RB+A
-- shortcut owns input, then restore the same runtime binding on RB release.
-- This never saves or rewrites InputBindings XML and does not touch other actions.
local interactionMaskState = rawget(_G, "GQS_RBInteractBindingMaskState")
if type(interactionMaskState) ~= "table" then
    interactionMaskState = { active = false, originalButton = nil, skipLogged = false, restoreFailureLogged = false }
    _G.GQS_RBInteractBindingMaskState = interactionMaskState
end
if interactionMaskState.restoreFailureLogged == nil then interactionMaskState.restoreFailureLogged = false end

local function getInteractBindingObject()
    local bindingEnum = rawget(_G, "CharacterJoypadButtonBinding")
    if bindingEnum == nil then return nil end
    local ok, action = pcall(function() return bindingEnum.Interact end)
    if ok then return action end
    return nil
end

local function getActionJoypadButton(action)
    if action == nil then return false, nil end
    return pcall(function() return action:getJoypadButton() end)
end

setInteractAExplicitlyMasked = function(masked, reason)
    local state = interactionMaskState
    if masked then
        local binding = getInteractBindingObject()
        local buttons = rawget(_G, "JoypadButton")
        local aButton = buttons and buttons.A or nil
        if binding == nil or aButton == nil then
            if not state.skipLogged then
                debugPrint("INTERACT-MASK; state=UNAVAILABLE; Interact binding or JoypadButton.A unavailable; reason=" .. tostring(reason))
                state.skipLogged = true
            end
            return false
        end
        local readOK, currentButton = getActionJoypadButton(binding)
        if not readOK then
            if not state.skipLogged then
                debugPrint("INTERACT-MASK; state=READ-FAILED; could not read Interact button; reason=" .. tostring(reason))
                state.skipLogged = true
            end
            return false
        end
        if state.active then
            if currentButton == nil then return true end
            if currentButton == aButton then
                -- A controller-profile reload may restore the mapping while RB is
                -- still held; reapply the temporary mask without logging per tick.
                local reapplyOK = pcall(function() binding:removeBinding(aButton) end)
                local verifyOK, verifyButton = getActionJoypadButton(binding)
                if reapplyOK and verifyOK and verifyButton == nil then
                    debugPrint("INTERACT-MASK; state=REAPPLIED-AFTER-RELOAD; action=CharacterJoypadButtonBinding.Interact; button=A; InputBindings XML unchanged")
                    return true
                end
                if not state.skipLogged then
                    debugPrint("INTERACT-MASK; state=REAPPLY-FAILED; removeOK=" .. tostring(reapplyOK) .. "; verifyOK=" .. tostring(verifyOK) .. "; button=" .. tostring(verifyButton))
                    state.skipLogged = true
                end
                return false
            end
            -- A different live binding appeared while the mask was active. Respect it.
            debugPrint("INTERACT-MASK; state=EXTERNAL-REBIND; current Interact button=" .. tostring(currentButton) .. "; stored original=A; current mapping preserved")
            state.active = false
            state.originalButton = nil
            state.reason = nil
            state.skipLogged = false
            return true
        end
        if currentButton ~= aButton then
            -- Do not alter an intentional unbound/custom binding. This runtime
            -- mask only applies to the exact A binding observed in the log.
            if not state.skipLogged then
                debugPrint("INTERACT-MASK; state=SKIPPED; current Interact button=" .. tostring(currentButton) ..
                    "; expected A; existing mapping preserved; reason=" .. tostring(reason))
                state.skipLogged = true
            end
            return false
        end
        local removeOK, removeError = pcall(function() binding:removeBinding(aButton) end)
        local postOK, postButton = getActionJoypadButton(binding)
        if removeOK and postOK and postButton == nil then
            state.active = true
            state.originalButton = aButton
            state.reason = tostring(reason)
            state.skipLogged = false
            state.restoreFailureLogged = false
            debugPrint("INTERACT-MASK; state=APPLIED; action=CharacterJoypadButtonBinding.Interact; removed runtime button=A while RB+A shortcut owns input; reason=" .. tostring(reason) .. "; InputBindings XML unchanged")
            return true
        end
        if not state.skipLogged then
            debugPrint("INTERACT-MASK; state=FAILED; removeOK=" .. tostring(removeOK) ..
                "; postReadOK=" .. tostring(postOK) .. "; postButton=" .. tostring(postButton) ..
                "; error=" .. tostring(removeError) .. "; reason=" .. tostring(reason))
            state.skipLogged = true
        end
        return false
    end

    state.skipLogged = false
    if not state.active then return true end
    local binding = getInteractBindingObject()
    if binding == nil then
        if not state.restoreFailureLogged then
            debugPrint("INTERACT-MASK; state=RESTORE-DEFERRED; Interact binding unavailable; runtime A binding retained for later retry")
            state.restoreFailureLogged = true
        end
        return false
    end
    local readOK, currentButton = getActionJoypadButton(binding)
    if readOK and currentButton == nil then
        local addOK, addError = pcall(function() binding:addBinding(state.originalButton) end)
        local postOK, postButton = getActionJoypadButton(binding)
        if addOK and postOK and postButton == state.originalButton then
            debugPrint("INTERACT-MASK; state=RESTORED; action=CharacterJoypadButtonBinding.Interact; button=A; reason=" .. tostring(reason) .. "; InputBindings XML unchanged")
            state.active = false
            state.originalButton = nil
            state.reason = nil
            state.restoreFailureLogged = false
            return true
        end
        if not state.restoreFailureLogged then
            debugPrint("INTERACT-MASK; state=RESTORE-FAILED; addOK=" .. tostring(addOK) ..
                "; postReadOK=" .. tostring(postOK) .. "; postButton=" .. tostring(postButton) ..
                "; error=" .. tostring(addError) .. "; retry=enabled")
            state.restoreFailureLogged = true
        end
        return false
    elseif readOK and currentButton == state.originalButton then
        debugPrint("INTERACT-MASK; state=ALREADY-RESTORED; action=CharacterJoypadButtonBinding.Interact; button=A; reason=" .. tostring(reason))
        state.active = false
        state.originalButton = nil
        state.reason = nil
        state.restoreFailureLogged = false
        return true
    elseif readOK then
        -- A settings/config reload or another mod supplied a new binding while
        -- the shortcut was held. Respect it rather than overwriting that change.
        debugPrint("INTERACT-MASK; state=RESTORE-SKIPPED; current Interact button=" .. tostring(currentButton) ..
            "; stored original=A; external/current mapping preserved")
        state.active = false
        state.originalButton = nil
        state.reason = nil
        state.restoreFailureLogged = false
        return true
    end
    if not state.restoreFailureLogged then
        debugPrint("INTERACT-MASK; state=RESTORE-READ-FAILED; Interact binding state could not be read; retry=enabled")
        state.restoreFailureLogged = true
    end
    return false
end

local function installClassMethodHook(owner, methodName, hookKey, shouldConsume, traceInput)
    if type(owner) ~= "table" or type(owner[methodName]) ~= "function" then return false end
    local current = owner[methodName]
    local oldRecord = nativeHookRegistry[hookKey]
    if oldRecord and oldRecord.owner == owner and oldRecord.wrapper == current then return true end

    local original = current
    local wrapped = function(self, ...)
        local consumed, playerIndex, consumedName = shouldConsume(self, ...)
        if type(traceInput) == "function" then
            local traceOK, traceError = pcall(traceInput, self, consumed == true, playerIndex, consumedName, ...)
            if not traceOK then
                debugPrint("INPUT-TRACE-ERROR; hook=" .. hookKey .. "; error=" .. tostring(traceError))
            end
        end
        if consumed then
            debugPrint("Consumed native " .. tostring(consumedName or "button") .. " before " .. hookKey ..
                " for player " .. tostring(playerIndex) .. "; RB shortcut owns this press; original skipped")
            return true
        end
        return original(self, ...)
    end
    local ok = pcall(function() owner[methodName] = wrapped end)
    if ok and owner[methodName] == wrapped then
        nativeHookRegistry[hookKey] = { owner = owner, wrapper = wrapped }
        debugPrint("Installed " .. hookKey .. " RB button interceptor")
        return true
    end
    return false
end

local function readFieldSafely(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function getButtonPromptPlayerNum(prompt, ...)
    -- ISButtonPrompt callbacks have appeared as both instance methods and
    -- player-index-first functions across PZ builds. Resolve either signature.
    local direct = resolvePlayerIndex(prompt)
    if direct ~= nil then return direct end

    local player = readFieldSafely(prompt, "player")
    local playerNum = resolvePlayerIndex(player)
    if playerNum ~= nil then return playerNum end

    local candidateFields = { "playerNum", "playerIndex", "joypadData", "joypad", "controllerData" }
    for _, fieldName in ipairs(candidateFields) do
        local candidate = readFieldSafely(prompt, fieldName)
        if candidate ~= nil then
            playerNum = resolvePlayerIndex(candidate)
            if playerNum ~= nil then return playerNum end
            local nestedPlayer = readFieldSafely(candidate, "player")
            playerNum = resolvePlayerIndex(nestedPlayer)
            if playerNum ~= nil then return playerNum end
        end
    end

    local args = { ... }
    for i = 1, #args do
        playerNum = resolvePlayerIndex(args[i])
        if playerNum ~= nil then return playerNum end
        local nestedPlayer = readFieldSafely(args[i], "player")
        playerNum = resolvePlayerIndex(nestedPlayer)
        if playerNum ~= nil then return playerNum end
    end

    local count = 4
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then count = math.min(value, 4) end
    end
    if player ~= nil and type(getSpecificPlayer) == "function" then
        for i = 0, count - 1 do
            local ok, candidate = pcall(getSpecificPlayer, i)
            if ok and candidate == player then return i end
        end
    end
    return nil
end

local function shouldConsumeControllerNoFocus(self, button, ...)
    return shouldConsumeNativeButton(self, button)
end

local function shouldConsumeControllerDispatch(self, button, ...)
    -- The parent dispatcher is only a fallback, so explicitly preserve UI input.
    if self and self.joypad and self.joypad.focus ~= nil then return false end
    return shouldConsumeNativeButton(self, button)
end

local PROMPT_METHOD_COMBOS = {
    onYPress = "Y",
    onAPress = "A",
    onBPress = "A", -- B handler is only a fallback while the physical RB+A chord is active.
}

local function shouldConsumePromptMethod(methodName, prompt, ...)
    local playerIndex = getButtonPromptPlayerNum(prompt, ...)
    local combo = PROMPT_METHOD_COMBOS[methodName]
    if playerIndex == nil or not combo then return false end
    if not isActionButtonChordDown(playerIndex, combo) then return false end
    if combo == "A" then
        setInteractAExplicitlyMasked(true, "ISButtonPrompt:" .. methodName)
    end
    return true, playerIndex, combo .. " via ISButtonPrompt:" .. methodName
end

local function shouldConsumePromptY(prompt, ...)
    return shouldConsumePromptMethod("onYPress", prompt, ...)
end
local function shouldConsumePromptA(prompt, ...)
    return shouldConsumePromptMethod("onAPress", prompt, ...)
end
local function shouldConsumePromptB(prompt, ...)
    return shouldConsumePromptMethod("onBPress", prompt, ...)
end
local PROMPT_METHOD_HOOKS = {
    { name = "onYPress", shouldConsume = shouldConsumePromptY },
    { name = "onAPress", shouldConsume = shouldConsumePromptA },
    { name = "onBPress", shouldConsume = shouldConsumePromptB },
}

local function safeInputField(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function describeInputValue(value)
    if value == nil then return "nil" end
    local rendered = tostring(value)
    if string.len(rendered) > 100 then rendered = string.sub(rendered, 1, 100) .. "..." end
    return type(value) .. ":" .. rendered
end

local function getFaceButtonName(button)
    for _, name in ipairs({ "A", "B", "Y" }) do
        if isNativeButton(button, name) then return name end
    end
    return nil
end

local function getPlayerInputTrace(playerIndex)
    if playerIndex == nil then return "playerState=unavailable" end
    local bind = getJoypadBind(playerIndex)
    if bind < 0 then return "player=" .. tostring(playerIndex) .. "; joypadBind=" .. tostring(bind) end
    local state = playerStates[playerIndex]
    local focus = getCurrentJoypadFocus(playerIndex)
    local inventoryClosed = areInventoryWindowsClosed(playerIndex)
    return "player=" .. tostring(playerIndex) ..
        "; joypadBind=" .. tostring(bind) ..
        "; RB=" .. tostring(isButtonDown("RightBump", bind)) ..
        "; A=" .. tostring(isButtonDown("A", bind)) ..
        "; B=" .. tostring(isButtonDown("B", bind)) ..
        "; Y=" .. tostring(isButtonDown("Y", bind)) ..
        "; worldFocus=" .. tostring(focus == nil) ..
        "; focusType=" .. type(focus) ..
        "; focusValue=" .. describeInputValue(focus) ..
        "; inventoryLootClosed=" .. tostring(inventoryClosed) ..
        "; configuredA=" .. tostring(getConfiguredActionButton("A")) ..
        "; configuredY=" .. tostring(getConfiguredActionButton("Y")) ..
        "; awaitReleaseA=" .. tostring(state and state.actionButtonAwaitRelease and state.actionButtonAwaitRelease.A or false) ..
        "; awaitReleaseY=" .. tostring(state and state.actionButtonAwaitRelease and state.actionButtonAwaitRelease.Y or false) ..
        "; chordA=" .. tostring(isActionButtonChordDown(playerIndex, "A")) ..
        "; chordY=" .. tostring(isActionButtonChordDown(playerIndex, "Y"))
end

local function traceControllerDispatch(hookKey, controllerData, consumed, suppliedPlayerIndex, consumedName, button)
    local buttonName = getFaceButtonName(button)
    if not buttonName then return end
    local joypadData = safeInputField(controllerData, "joypad")
    local joypadPlayer = safeInputField(joypadData, "player")
    local dispatcherFocus = safeInputField(joypadData, "focus")
    local rawId = safeInputField(controllerData, "id")
    local resolved = suppliedPlayerIndex
    if resolved == nil then resolved = getControllerPlayerIndex(controllerData) end
    local reason
    if consumed then
        reason = "CONSUMED; original method skipped"
    elseif joypadData == nil then
        reason = "PASS; controllerData.joypad is nil"
    elseif resolved == nil then
        reason = "PASS; player index unresolved"
    elseif buttonName == "B" then
        reason = "PASS; B is diagnostic only in the RB+A/Y interceptor"
    elseif hookKey == "JoypadControllerData:onPressButton" and dispatcherFocus ~= nil then
        reason = "PASS; outer dispatcher has a non-nil focus object; preserving its focused-input path"
    elseif not areInventoryWindowsClosed(resolved) then
        reason = "PASS; inventory or loot window open"
    elseif not hasWorldFocus(resolved) then
        reason = "PASS; non-world UI has joypad focus"
    elseif not isActionButtonChordDown(resolved, buttonName) then
        reason = "PASS; live chord check returned false"
    else
        reason = "PASS; chord appeared active but consume predicate returned false"
    end
    debugPrint("INPUT-TRACE; stage=JoypadControllerData; hook=" .. hookKey ..
        "; button=" .. buttonName ..
        "; rawButton=" .. describeInputValue(button) ..
        "; controllerId=" .. describeInputValue(rawId) ..
        "; joypadData=" .. describeInputValue(joypadData) ..
        "; joypadPlayer=" .. describeInputValue(joypadPlayer) ..
        "; dispatcherFocus=" .. describeInputValue(dispatcherFocus) ..
        "; decision=" .. reason ..
        "; " .. getPlayerInputTrace(resolved))
end

local function tracePromptDispatch(methodName, prompt, consumed, suppliedPlayerIndex, consumedName, ...)
    local combo = PROMPT_METHOD_COMBOS[methodName]
    local playerIndex = suppliedPlayerIndex or getButtonPromptPlayerNum(prompt, ...)
    local promptPlayer = safeInputField(prompt, "player")
    local actionText = combo and getConfiguredActionButton(combo) or "n/a"
    local reason
    if consumed then
        reason = "CONSUMED; original method skipped"
    elseif not combo then
        reason = "PASS; method is not mapped to RB+face chord"
    elseif playerIndex == nil then
        reason = "PASS; prompt player index unresolved"
    elseif not areInventoryWindowsClosed(playerIndex) then
        reason = "PASS; inventory or loot window open"
    elseif not hasWorldFocus(playerIndex) then
        reason = "PASS; non-world UI has joypad focus"
    elseif not isActionButtonChordDown(playerIndex, combo) then
        reason = "PASS; live chord check returned false"
    else
        reason = "PASS; chord appeared active but consume predicate returned false"
    end
    debugPrint("INPUT-TRACE; stage=ISButtonPrompt; method=" .. methodName ..
        "; combo=" .. tostring(combo) ..
        "; configuredAction=" .. tostring(actionText) ..
        "; prompt=" .. describeInputValue(prompt) ..
        "; prompt.player=" .. describeInputValue(promptPlayer) ..
        "; decision=" .. reason ..
        "; " .. getPlayerInputTrace(playerIndex))
end

local nativeDispatcherWarningLogged = false
local installNativeButtonInterceptors
local function verifyNativeInputInterceptors()
    local installed = installNativeButtonInterceptors()
    if not installed and not nativeDispatcherWarningLogged then
        nativeDispatcherWarningLogged = true
        debugPrint("WARNING: both JoypadControllerData dispatcher hooks are unavailable; only ISButtonPrompt fallback hooks may intercept RB+Y/A")
    end
end

installNativeButtonInterceptors = function()
    local controllerClass = rawget(_G, "JoypadControllerData")
    local installedNoFocusDispatcher = false
    local installedParentDispatcher = false
    if type(controllerClass) == "table" then
        -- These are two different levels in the vanilla input call path. Install
        -- both rather than treating onPressButton as a fallback: skipping the
        -- inner no-focus method alone may not stop work done by the outer caller.
        installedNoFocusDispatcher = installClassMethodHook(controllerClass, "onPressButtonNoFocus",
            "JoypadControllerData:onPressButtonNoFocus", shouldConsumeControllerNoFocus,
            function(self, consumed, playerIndex, consumedName, button)
                traceControllerDispatch("JoypadControllerData:onPressButtonNoFocus", self, consumed, playerIndex, consumedName, button)
            end)
        installedParentDispatcher = installClassMethodHook(controllerClass, "onPressButton",
            "JoypadControllerData:onPressButton", shouldConsumeControllerDispatch,
            function(self, consumed, playerIndex, consumedName, button)
                traceControllerDispatch("JoypadControllerData:onPressButton", self, consumed, playerIndex, consumedName, button)
            end)
        if not installedNoFocusDispatcher and not installedParentDispatcher then
            if nativeHookRegistry._lastDispatcherStatus ~= "none" then
                debugPrint("WARNING: Neither JoypadControllerData:onPressButton nor onPressButtonNoFocus could be hooked")
                nativeHookRegistry._lastDispatcherStatus = "none"
            end
        else
            local status = "onPressButton=" .. tostring(installedParentDispatcher) ..
                "; onPressButtonNoFocus=" .. tostring(installedNoFocusDispatcher)
            if nativeHookRegistry._lastDispatcherStatus ~= status then
                debugPrint("Controller dispatcher hook status; " .. status)
                nativeHookRegistry._lastDispatcherStatus = status
            end
        end
    end
    local installedDispatcher = installedNoFocusDispatcher or installedParentDispatcher

    local promptClass = rawget(_G, "ISButtonPrompt")
    if type(promptClass) == "table" then
        for _, hookSpec in ipairs(PROMPT_METHOD_HOOKS) do
            local methodName = hookSpec.name
            local traceMethodName = methodName
            installClassMethodHook(promptClass, methodName, "ISButtonPrompt:" .. methodName, hookSpec.shouldConsume,
                function(prompt, consumed, playerIndex, consumedName, ...)
                    tracePromptDispatch(traceMethodName, prompt, consumed, playerIndex, consumedName, ...)
                end)
        end
    end
    return installedDispatcher
end

local function isRBHeldForPlayer(playerIndex)
    if not areInventoryWindowsClosed(playerIndex) or not hasWorldFocus(playerIndex) then return false end
    local bind = getJoypadBind(playerIndex)
    return bind >= 0 and isButtonDown("RightBump", bind)
end

local function performZoom(playerIndex, delta)
    local core = getCore and getCore() or nil
    if not core or type(core.doZoomScroll) ~= "function" then
        if not warnedZoomUnavailable then
            warnedZoomUnavailable = true
            local logger = rawget(_G, "GQSLog"); if logger then logger.error("rbZoom", "Core:doZoomScroll is unavailable; RB zoom actions are disabled.") end
        end
        return false
    end
    local ok, err = pcall(function() core:doZoomScroll(playerIndex, delta) end)
    if not ok then
        if not warnedZoomUnavailable then
            warnedZoomUnavailable = true
            local logger = rawget(_G, "GQSLog"); if logger then logger.error("rbZoom", "Native zoom call failed: " .. tostring(err)) end
        end
        return false
    end
    debugPrint("Zoom action executed for player " .. tostring(playerIndex) .. ", delta=" .. tostring(delta))
    return true
end

local function getState(playerIndex)
    local state = playerStates[playerIndex]
    if not state then
        state = {
            chordDown = {}, actionButtonChordDown = {}, rbWasDown = false,
            dpadDownAtRB = {}, actionButtonDownAtRB = {}, actionButtonAwaitRelease = {},
        }
        playerStates[playerIndex] = state
    end
    return state
end

local function isDirectionChordDown(bind, directionName, oppositeName, rbDown)
    if not rbDown or getConfiguredAction(directionName) == "none" then return false end
    if not isButtonDown(BUTTON_BY_DIRECTION[directionName], bind) then return false end
    if oppositeName and isButtonDown(BUTTON_BY_DIRECTION[oppositeName], bind) then return false end
    return true
end

local function onTick()
    -- The controller/UI classes can load after this module; retry until hooks exist.
    -- Dispatcher status logging is de-duplicated, so this retry no longer floods console.txt.
    installNativeButtonInterceptors()
    local shouldMaskInteract = false
    local anyPhysicalRBDown = false
    local anyPhysicalADown = false
    for playerIndex = 0, 3 do
        local state = getState(playerIndex)
        local bind = getJoypadBind(playerIndex)
        local physicalRBDown = bind >= 0 and isButtonDown("RightBump", bind)
        local physicalADown = bind >= 0 and isButtonDown("A", bind)
        if physicalRBDown then anyPhysicalRBDown = true end
        if physicalADown then anyPhysicalADown = true end
        local eligible = bind >= 0 and areInventoryWindowsClosed(playerIndex) and hasWorldFocus(playerIndex)
        local rbDown = eligible and physicalRBDown
        if rbDown and not state.rbWasDown then
            state.dpadDownAtRB = {}
            state.actionButtonDownAtRB = {}
            state.actionButtonAwaitRelease = {}
            for _, d in ipairs(DIRECTION_DATA) do
                state.dpadDownAtRB[d.name] = isButtonDown(d.button, bind)
            end
            for _, actionButton in ipairs(ACTION_BUTTONS) do
                local heldAtRBDown = isButtonDown(actionButton.button, bind)
                state.actionButtonDownAtRB[actionButton.name] = heldAtRBDown
                state.actionButtonAwaitRelease[actionButton.name] = heldAtRBDown
            end
            debugPrint("Player " .. playerIndex .. " RB-down captured; D-pad held=" ..
                tostring(state.dpadDownAtRB.Up or state.dpadDownAtRB.Down or state.dpadDownAtRB.Left or state.dpadDownAtRB.Right) ..
                "; Y-held=" .. tostring(state.actionButtonDownAtRB.Y) ..
                "; A-held=" .. tostring(state.actionButtonDownAtRB.A))
        end

        for _, direction in ipairs(DIRECTION_DATA) do
            local chordDown = eligible and isDirectionChordDown(bind, direction.name, direction.opposite, rbDown)
                and not state.dpadDownAtRB[direction.name]
            if chordDown and not state.chordDown[direction.name] then
                local action = getConfiguredAction(direction.name)
                if action == "zoomIn" then
                    performZoom(playerIndex, 1)
                elseif action == "zoomOut" then
                    performZoom(playerIndex, -1)
                end
                -- Moodle actions are processed by GQSRBZoom_Moodles.lua.
            end
            state.chordDown[direction.name] = chordDown == true
        end

        for _, actionButton in ipairs(ACTION_BUTTONS) do
            local buttonDown = bind >= 0 and isButtonDown(actionButton.button, bind)
            if rbDown and state.actionButtonAwaitRelease[actionButton.name] and not buttonDown then
                -- The button was held before RB; once released, a new press while
                -- RB remains held is correctly ordered and can start the chord.
                state.actionButtonAwaitRelease[actionButton.name] = false
            end
            local chordDown = eligible
                and getConfiguredActionButton(actionButton.name) ~= "none"
                and buttonDown
                and rbDown
                and not state.actionButtonAwaitRelease[actionButton.name]
            local wasChordDown = state.actionButtonChordDown[actionButton.name] == true
            if chordDown ~= wasChordDown then
                debugPrint("INPUT-TRACE; stage=OnTick-chord-transition; player=" .. tostring(playerIndex) ..
                    "; button=" .. actionButton.name ..
                    "; transition=" .. (chordDown and "ACTIVE" or "INACTIVE") ..
                    "; RB=" .. tostring(rbDown) .. "; buttonDown=" .. tostring(buttonDown) ..
                    "; eligible=" .. tostring(eligible) ..
                    "; configuredAction=" .. tostring(getConfiguredActionButton(actionButton.name)) ..
                    "; buttonWasDownAtRB=" .. tostring(state.actionButtonDownAtRB[actionButton.name] == true) ..
                    "; awaitingRelease=" .. tostring(state.actionButtonAwaitRelease[actionButton.name] == true))
            end
            if chordDown and not state.actionButtonChordDown[actionButton.name] then
                local action = getConfiguredActionButton(actionButton.name)
                debugPrint("Player " .. playerIndex .. " RB+" .. actionButton.name .. " edge; action=" .. tostring(action) ..
                    "; action button was already down at RB press=" ..
                    tostring(state.actionButtonDownAtRB[actionButton.name] == true))
                if action == "zoomIn" then
                    performZoom(playerIndex, 1)
                elseif action == "zoomOut" then
                    performZoom(playerIndex, -1)
                end
            end
            state.actionButtonChordDown[actionButton.name] = chordDown == true
        end

        state.rbWasDown = rbDown == true
        if rbDown and getConfiguredActionButton("A") ~= "none"
            and not (state.actionButtonAwaitRelease and state.actionButtonAwaitRelease.A) then
            shouldMaskInteract = true
        end
        if not rbDown then
            state.dpadDownAtRB = {}
            state.actionButtonDownAtRB = {}
            state.actionButtonAwaitRelease = {}
        end
    end

    -- One state manager owns the temporary native Interact binding change.
    -- The input-dispatch fast path may apply it immediately before returning; this
    -- tick-level reconciliation keeps it active through momentary focus changes
    -- and restores it only after both physical RB and A are released.
    local keepInteractMasked = shouldMaskInteract
        or (interactionMaskState.active and (anyPhysicalRBDown or anyPhysicalADown))
    if keepInteractMasked then
        setInteractAExplicitlyMasked(true, "RB+A state reconciliation")
    else
        setInteractAExplicitlyMasked(false, "RB and A physically released or gameplay context ended")
    end
end

-- Reserve only directions that have an assigned RB action. This prevents a
-- contextual radial from opening over the shortcut, without swallowing native
-- D-pad behavior for directions configured as Disabled.
local function installDPadSuppression()
    local wheelClass = rawget(_G, "ISDPadWheels")
    if not wheelClass then return false end
    for _, direction in ipairs(DIRECTION_DATA) do
        -- Copy loop fields into locals so each closure keeps its own direction.
        local directionName = direction.name
        local buttonName = direction.button
        local methodName = "onDisplay" .. directionName
        local flagName = "_gqsRBControlsSuppression_" .. methodName
        if not wheelClass[flagName] then
            local original = wheelClass[methodName]
            if type(original) == "function" then
                wheelClass[methodName] = function(joypadData, ...)
                    local playerIndex = joypadData and tonumber(joypadData.player) or nil
                    if playerIndex ~= nil
                        and getConfiguredAction(directionName) ~= "none"
                        and isRBHeldForPlayer(playerIndex)
                    then
                        local bind = getJoypadBind(playerIndex)
                        if bind >= 0 and isButtonDown(buttonName, bind) then return true end
                    end
                    return original(joypadData, ...)
                end
                wheelClass[flagName] = true
            end
        end
    end
    return true
end

if Events and Events.OnTick then Events.OnTick.Add(onTick) end
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(installDPadSuppression)
    Events.OnGameBoot.Add(installNativeButtonInterceptors)
end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(installDPadSuppression)
    Events.OnGameStart.Add(verifyNativeInputInterceptors)
end
if Events and Events.OnResetLua then
    Events.OnResetLua.Add(function()
        -- Keep a temporary mask across Lua reset while either physical key is held;
        -- OnTick will restore it after RB and A have both been released.
        playerStates = {}
        warnedZoomUnavailable = false
        installDPadSuppression()
        nativeDispatcherWarningLogged = false
        installNativeButtonInterceptors()
    end)
end

installDPadSuppression()
installNativeButtonInterceptors()
