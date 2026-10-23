-- Gamepad QoL Suite: Right D-pad radial extension
-- Extends the vanilla right D-pad wheel without replacing its existing actions.
-- Diagnostics are centrally controlled by GQSDebugLog.lua (category: rightRadial).
local function debugLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rightRadial", message)
    end
end

local function optionEnabled(optionName, fallback)
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options[optionName]
    if not option or type(option.getValue) ~= "function" then
        return fallback
    end
    local ok, value = pcall(option.getValue, option)
    if not ok then
        debugLog("reading setting " .. optionName .. " failed: " .. tostring(value))
        return fallback
    end
    return value == true or value == 1
end

local function hasJoypadForPlayer(playerNum)
    return JoypadState and JoypadState.players and JoypadState.players[playerNum + 1] ~= nil
end

-- Keep the Fitness panel path that was already tested successfully in-game.
local function gqsOpenFitnessPanel(player)
    if not player then
        debugLog("Fitness action aborted: player is nil")
        return
    end

    local okRequire, requireErr = pcall(require, "ISUI/ISFitnessUI")
    if not ISFitnessUI or type(ISFitnessUI.new) ~= "function" then
        debugLog("Fitness UI unavailable: " .. tostring(requireErr))
        return
    end

    local playerNum = player:getPlayerNum()
    local instanceIndex = playerNum + 1
    local panel = ISFitnessUI.instance and ISFitnessUI.instance[instanceIndex]
    if panel and panel:isReallyVisible() then
        if hasJoypadForPlayer(playerNum) then
            local okFocus, err = pcall(setJoypadFocus, playerNum, panel)
            if not okFocus then debugLog("Fitness focus failed: " .. tostring(err)) end
        end
        return
    end

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
        debugLog("Fitness panel creation failed: " .. tostring(newPanel))
        return
    end

    if hasJoypadForPlayer(playerNum) then
        local okFocus, err = pcall(setJoypadFocus, playerNum, newPanel)
        if not okFocus then debugLog("Fitness focus failed: " .. tostring(err)) end
    end
end

-- Mirrors the vanilla XpUpdate.displayCharacterInfo() branch for
-- "Toggle Skill Panel". The actual keyboard shortcut toggles the same view,
-- but does not assign controller focus. We focus ISCharacterInfo directly and
-- defer the focus handoff until the UI has completed its layout/update pass.
local function gqsSkillsLog(message)
    -- One line per action/result only; centrally muted unless rightRadial is enabled.
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rightRadial", "Skills: " .. tostring(message))
    end
end

local function gqsObjectVisible(object)
    if not object then return false end
    if type(object.getIsVisible) == "function" then
        local ok, value = pcall(object.getIsVisible, object)
        if ok then return value == true end
    end
    if type(object.isVisible) == "function" then
        local ok, value = pcall(object.isVisible, object)
        if ok then return value == true end
    end
    if object.visible ~= nil then return object.visible == true end
    -- Do not block focus just because this UI class exposes no visibility getter.
    return true
end

local function gqsGetSkillsView(infoWindow, skillsLabel)
    if not infoWindow then return nil end

    -- This is the concrete view used by vanilla ISCharacterInfoWindow:createChildren().
    if infoWindow.characterView then return infoWindow.characterView end

    -- Fallback for modded windows whose field layout differs.
    local panel = infoWindow.panel
    if panel and type(panel.getView) == "function" then
        local ok, view = pcall(panel.getView, panel, skillsLabel)
        if ok and view then return view end
    end
    return nil
end

local function gqsSkillsViewIsShown(infoWindow, skillsView, skillsLabel)
    if not infoWindow or not skillsView then return false, "no-view" end

    local panel = infoWindow.panel
    if panel and type(panel.getActiveView) == "function" then
        local ok, activeView = pcall(panel.getActiveView, panel)
        if ok and activeView == skillsView and gqsObjectVisible(infoWindow) then
            return true, "tabbed"
        end
    end

    -- If the player previously tore the skills tab off, vanilla toggles the
    -- detached window in ISCharacterInfoWindow.view instead of the tab panel.
    local class = rawget(_G, "ISCharacterInfoWindow")
    local detached = class and class.view
    if type(detached) == "table" then
        for _, window in pairs(detached) do
            if window and type(window.getTitle) == "function" then
                local okTitle, title = pcall(window.getTitle, window)
                if okTitle and title == skillsLabel and gqsObjectVisible(window) then
                    return true, "detached"
                end
            end
        end
    end
    return false, "not-active"
end

local function gqsScheduleSkillsFocus(playerNum, infoWindow, skillsLabel)
    if not hasJoypadForPlayer(playerNum) or type(setJoypadFocus) ~= "function" then
        gqsSkillsLog("skill page opened, but no active joypad slot was found")
        return
    end

    local attempts = 0
    local maxAttempts = 12
    local onTick
    onTick = function()
        attempts = attempts + 1

        local currentWindow = infoWindow
        if type(getPlayerInfoPanel) == "function" then
            local okWindow, result = pcall(getPlayerInfoPanel, playerNum)
            if okWindow and result then currentWindow = result end
        end
        local skillsView = gqsGetSkillsView(currentWindow, skillsLabel)
        local shown, viewKind = gqsSkillsViewIsShown(currentWindow, skillsView, skillsLabel)

        if shown and skillsView then
            local okFocus, err = pcall(setJoypadFocus, playerNum, skillsView)
            if Events and Events.OnTick and type(Events.OnTick.Remove) == "function" then
                Events.OnTick.Remove(onTick)
            end
            if okFocus then
                local currentFocus = JoypadState and JoypadState.players
                    and JoypadState.players[playerNum + 1] and JoypadState.players[playerNum + 1].focus
                gqsSkillsLog("focus assigned to skill view; path=" .. tostring(viewKind)
                    .. ", focus=" .. tostring(currentFocus))
            else
                gqsSkillsLog("setJoypadFocus failed: " .. tostring(err))
            end
            return
        end

        if attempts >= maxAttempts then
            if Events and Events.OnTick and type(Events.OnTick.Remove) == "function" then
                Events.OnTick.Remove(onTick)
            end
            local activeName = "nil"
            local panel = currentWindow and currentWindow.panel
            if panel and type(panel.getActiveView) == "function" then
                local okActive, activeView = pcall(panel.getActiveView, panel)
                if okActive then activeName = tostring(activeView) end
            end
            gqsSkillsLog("could not focus skill view after " .. tostring(maxAttempts)
                .. " ticks; state=" .. tostring(viewKind)
                .. ", windowVisible=" .. tostring(gqsObjectVisible(currentWindow))
                .. ", activeView=" .. activeName)
        end
    end

    if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
        Events.OnTick.Add(onTick)
    else
        -- Fallback if the event is unavailable in a particular client context.
        onTick()
    end
end

local function gqsOpenSkillsPanel(player)
    if not player then
        gqsSkillsLog("action aborted: player is nil")
        return
    end
    if type(getPlayerInfoPanel) ~= "function" then
        gqsSkillsLog("action aborted: getPlayerInfoPanel unavailable")
        return
    end

    local playerNum = player:getPlayerNum()
    local okWindow, infoWindow = pcall(getPlayerInfoPanel, playerNum)
    if not okWindow or not infoWindow then
        gqsSkillsLog("action aborted: character-info window unavailable")
        return
    end

    -- Vanilla XpUpdate.displayCharacterInfo() uses this exact toggle for L.
    local skillsLabel = xpSystemText and xpSystemText.skills
    if (not skillsLabel or skillsLabel == "") and type(getText) == "function" then
        local okText, textValue = pcall(getText, "IGUI_XP_Skills")
        if okText then skillsLabel = textValue end
    end
    if not skillsLabel or skillsLabel == "" then
        gqsSkillsLog("action aborted: vanilla skill-tab label unavailable")
        return
    end

    local okToggle, toggleErr = pcall(function()
        infoWindow:toggleView(skillsLabel)
    end)
    if not okToggle then
        gqsSkillsLog("vanilla skill-tab toggle failed: " .. tostring(toggleErr))
        return
    end

    gqsSkillsLog("vanilla skills toggle called; scheduling controller focus")
    gqsScheduleSkillsFocus(playerNum, infoWindow, skillsLabel)
end

local function addSliceSafely(menu, label, texturePath, callback, player)
    local icon = nil
    if texturePath and type(getTexture) == "function" then
        local okTexture, texture = pcall(getTexture, texturePath)
        if okTexture then icon = texture end
    end
    local okAdd, err = pcall(function()
        menu:addSlice(label, icon, callback, player)
    end)
    if not okAdd then debugLog("failed to append '" .. tostring(label) .. "': " .. tostring(err)) end
end

local function gqsAddRightRadialSlices(joypadData)
    if not joypadData or joypadData.player == nil or type(getPlayerRadialMenu) ~= "function" then return end
    local menu = getPlayerRadialMenu(joypadData.player)
    if not menu or type(menu.addSlice) ~= "function" then return end

    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(joypadData.player) or nil
    if optionEnabled("rightRadialFitnessEnabled", true) then
        addSliceSafely(menu, getText("UI_GQOS_RightRadialFitness"),
            "media/ui/icon_fitness_dumbbell.png", gqsOpenFitnessPanel, player)
    end
    if optionEnabled("rightRadialSkillsEnabled", true) then
        addSliceSafely(menu, getText("UI_GQOS_RightRadialSkills"),
            "media/ui/icon_skill_book.png", gqsOpenSkillsPanel, player)
    end
end

local function gqsInstallRightRadialHook()
    if not ISDPadWheels or type(ISDPadWheels.onDisplayRight) ~= "function" then
        debugLog("right-wheel handler unavailable; will retry on game start")
        return false
    end
    if ISDPadWheels._gqsRightRadialExtensionHook then return true end

    local original = ISDPadWheels.onDisplayRight
    ISDPadWheels.onDisplayRight = function(joypadData, ...)
        local result = original(joypadData, ...)
        -- The vanilla call above builds its own slices; append only afterward.
        gqsAddRightRadialSlices(joypadData)
        return result
    end
    ISDPadWheels._gqsRightRadialExtensionHook = true
    debugLog("right-wheel hook installed")
    return true
end

if not gqsInstallRightRadialHook() and Events and Events.OnGameStart then
    Events.OnGameStart.Add(gqsInstallRightRadialHook)
end
