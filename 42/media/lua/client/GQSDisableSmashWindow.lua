-- Gamepad QoL Suite: optional runtime suppression of native B-button window smashing.
-- This replaces the former observe-only GQSSmashWindowBindingTest diagnostic script.
-- The feature is opt-in through Mod Options and only changes the in-memory action binding.
-- It never writes or saves InputBindings XML and never changes other actions.

local TAG = "[GQS Disable Smash Window] "
local GLOBAL_STATE_KEY = "GQS_DisableSmashWindowB_State"
local OPTION_KEY = "disableSmashWindowBEnabled"

local state = rawget(_G, GLOBAL_STATE_KEY)
if type(state) ~= "table" then
    state = {
        active = false,
        originalButton = nil,
        lastUnavailableReason = nil,
        lastReadFailureLogged = false,
        lastApplyFailureLogged = false,
        lastRestoreFailureLogged = false,
    }
    rawset(_G, GLOBAL_STATE_KEY, state)
end

local function log(message)
    -- This module only logs state changes or failures, never every tick.
    print(TAG .. tostring(message))
end

local function optionEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options[OPTION_KEY] or nil
    if option == nil then return nil end -- Mod Options has not registered yet.

    local value
    if type(option.getValue) == "function" then
        local ok, result = pcall(function() return option:getValue() end)
        if ok then value = result end
    end
    if value == nil then value = option.value end
    if value == nil then return nil end
    return value == true or value == 1 or value == "1" or value == "true"
end

local function resolveSmashWindowAction()
    local bindingEnum = rawget(_G, "CharacterJoypadButtonBinding")
    if bindingEnum == nil then return nil end
    local ok, action = pcall(function() return bindingEnum.SmashWindow end)
    if ok then return action end
    return nil
end

local function readButton(action)
    if action == nil then return false, nil end
    return pcall(function() return action:getJoypadButton() end)
end

local function clearActiveState()
    state.active = false
    state.originalButton = nil
    state.lastApplyFailureLogged = false
    state.lastRestoreFailureLogged = false
end

local function applySuppression(action, buttonB)
    local readOK, currentButton = readButton(action)
    if not readOK then
        if not state.lastReadFailureLogged then
            log("READ-FAILED; cannot inspect SmashWindow button binding; will retry while the option is enabled")
            state.lastReadFailureLogged = true
        end
        return
    end
    state.lastReadFailureLogged = false

    if state.active then
        if currentButton == nil then return end
        if currentButton ~= buttonB then
            -- A user or another mod assigned a different button while this option was active.
            -- Preserve that new mapping instead of silently removing it.
            log("EXTERNAL-REBIND; current SmashWindow button=" .. tostring(currentButton) .. "; preserving current mapping")
            clearActiveState()
            return
        end
        -- A controller config reload may recreate the B binding; remove only B again.
        local removeOK, removeError = pcall(function() action:removeBinding(buttonB) end)
        local verifyOK, verifyButton = readButton(action)
        if removeOK and verifyOK and verifyButton == nil then
            log("REAPPLIED; native SmashWindow B binding was restored by a config reload and has been removed again")
            return
        end
        if not state.lastApplyFailureLogged then
            log("REAPPLY-FAILED; removeOK=" .. tostring(removeOK) .. "; verifyOK=" .. tostring(verifyOK) ..
                "; button=" .. tostring(verifyButton) .. "; error=" .. tostring(removeError))
            state.lastApplyFailureLogged = true
        end
        return
    end

    -- Opt-in suppression is deliberately narrow: if the action is already unbound
    -- or mapped to another button, do not alter the user's controller configuration.
    if currentButton ~= buttonB then return end

    local removeOK, removeError = pcall(function() action:removeBinding(buttonB) end)
    local verifyOK, verifyButton = readButton(action)
    if removeOK and verifyOK and verifyButton == nil then
        state.active = true
        state.originalButton = buttonB
        state.lastApplyFailureLogged = false
        state.lastRestoreFailureLogged = false
        log("APPLIED; removed runtime B binding from CharacterJoypadButtonBinding.SmashWindow; InputBindings XML unchanged")
    elseif not state.lastApplyFailureLogged then
        log("APPLY-FAILED; removeOK=" .. tostring(removeOK) .. "; verifyOK=" .. tostring(verifyOK) ..
            "; button=" .. tostring(verifyButton) .. "; error=" .. tostring(removeError) .. "; retry=enabled")
        state.lastApplyFailureLogged = true
    end
end

local function restoreBinding(action)
    if not state.active then return end
    local buttonToRestore = state.originalButton
    if buttonToRestore == nil then
        clearActiveState()
        return
    end
    local readOK, currentButton = readButton(action)
    if not readOK then
        if not state.lastRestoreFailureLogged then
            log("RESTORE-READ-FAILED; cannot inspect SmashWindow binding; retry=enabled")
            state.lastRestoreFailureLogged = true
        end
        return
    end

    if currentButton == buttonToRestore then
        log("ALREADY-RESTORED; SmashWindow B binding is present")
        clearActiveState()
        return
    end
    if currentButton ~= nil then
        log("RESTORE-SKIPPED; current SmashWindow button=" .. tostring(currentButton) .. "; preserving external mapping")
        clearActiveState()
        return
    end

    local addOK, addError = pcall(function() action:addBinding(buttonToRestore) end)
    local verifyOK, verifyButton = readButton(action)
    if addOK and verifyOK and verifyButton == buttonToRestore then
        log("RESTORED; returned runtime B binding to CharacterJoypadButtonBinding.SmashWindow; InputBindings XML unchanged")
        clearActiveState()
    elseif not state.lastRestoreFailureLogged then
        log("RESTORE-FAILED; addOK=" .. tostring(addOK) .. "; verifyOK=" .. tostring(verifyOK) ..
            "; button=" .. tostring(verifyButton) .. "; error=" .. tostring(addError) .. "; retry=enabled")
        state.lastRestoreFailureLogged = true
    end
end

local function update()
    local enabled = optionEnabled()
    if enabled == nil then return end
    local action = resolveSmashWindowAction()
    local buttons = rawget(_G, "JoypadButton")
    local buttonB = buttons and buttons.B or nil
    if action == nil or buttonB == nil then
        local reason = "action=" .. tostring(action ~= nil) .. "; buttonB=" .. tostring(buttonB ~= nil)
        if state.lastUnavailableReason ~= reason then
            state.lastUnavailableReason = reason
            log("API-UNAVAILABLE; " .. reason .. "; will retry")
        end
        return
    end
    state.lastUnavailableReason = nil

    if enabled then
        applySuppression(action, buttonB)
    else
        restoreBinding(action)
    end
end

if Events and Events.OnGameBoot then Events.OnGameBoot.Add(update) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(update) end
if Events and Events.OnTick then Events.OnTick.Add(update) end
update()
