-- Gamepad QoL Suite: panel information enhancements.
-- Build 42 skills are selected by ISCharacterInfo.joypadIndex; the progress bar
-- itself is not the joypad focus. Hook the panel's directional callbacks.

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then
        fn("panelInfo", message)
    else
        print("[GQS PanelInfo] " .. (isError and "[ERROR] " or "") .. tostring(message))
    end
end

local function isEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.panelInfoEnhancementEnabled
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok then return value == true end
    end
    return true
end

-- Skill list paging follows the container navigation convention: RT must be
-- held before D-pad Up/Down is pressed. A seven-skill jump matches the
-- container page navigation's default step without adding another option.
local skillDirectionLocks = {}

local function getControllerId(playerNum, joypadData)
    if joypadData and type(joypadData.id) == "number" and joypadData.id >= 0 then
        return joypadData.id
    end
    if type(getJoypadData) == "function" then
        local ok, data = pcall(getJoypadData, playerNum)
        if ok and data and type(data.id) == "number" and data.id >= 0 then
            return data.id
        end
    end
    local players = rawget(_G, "JoypadState") and JoypadState.players
    local data = players and players[playerNum + 1]
    if data and type(data.id) == "number" and data.id >= 0 then
        return data.id
    end
    return -1
end

local function isRightTriggerDown(controllerId)
    if type(controllerId) ~= "number" or controllerId < 0 then return false end
    local axes = rawget(_G, "JoypadAxis1d")
    local axis = axes and axes.RightTrigger
    if not axis or type(axis.getValue) ~= "function" then return false end
    local ok, value = pcall(axis.getValue, axis, controllerId)
    if not ok or type(value) ~= "number" then return false end
    local threshold = 0.50
    if type(axis.getDeadZone) == "function" then
        local okDeadZone, deadZone = pcall(axis.getDeadZone, axis, controllerId)
        if okDeadZone and type(deadZone) == "number" then
            threshold = math.max(threshold, math.min(0.95, deadZone + 0.05))
        end
    end
    return value >= threshold
end

local function isSkillDirectionDown(controllerId, direction)
    if type(controllerId) ~= "number" or controllerId < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and buttons[direction == "up" and "DPadUp" or "DPadDown"]
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(button.isDown, button, controllerId)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    local legacyButton = joypad and joypad[direction == "up" and "DPadUp" or "DPadDown"]
    if legacyButton ~= nil and type(isJoypadPressed) == "function" then
        local ok, down = pcall(isJoypadPressed, controllerId, legacyButton)
        if ok then return down == true end
    end
    return false
end

local function isRecipeDirectionDown(controllerId, direction)
    if type(controllerId) ~= "number" or controllerId < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and buttons[direction == "up" and "DPadUp" or "DPadDown"]
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(button.isDown, button, controllerId)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    local legacyButton = joypad and joypad[direction == "up" and "DPadUp" or "DPadDown"]
    if legacyButton ~= nil and type(isJoypadPressed) == "function" then
        local ok, down = pcall(isJoypadPressed, controllerId, legacyButton)
        if ok then return down == true end
    end
    return false
end

local recipeDirectionLocks = {}

local function getRecipePlayerNum(list, joypadData)
    local current = list
    while current do
        if type(current.playerNum) == "number" then return current.playerNum end
        current = current.parent
    end
    local player = list.player
    if player and type(player.getPlayerNum) == "function" then
        local ok, value = pcall(player.getPlayerNum, player)
        if ok and type(value) == "number" then return value end
    end
    if joypadData and type(joypadData.player) == "number" then return joypadData.player end
    if joypadData and type(joypadData.id) == "number" then return joypadData.id end
    return nil
end

local function tryRecipePageNavigation(list, direction, joypadData)
    if not isEnabled() or type(list) ~= "table" or type(list.items) ~= "table" then return false end
    local playerNum = getRecipePlayerNum(list, joypadData)
    if playerNum == nil then return false end
    local controllerId = getControllerId(playerNum, joypadData)
    if controllerId < 0 then return false end
    local count = math.min(tonumber(list.count) or #list.items, #list.items)
    local currentIndex = math.floor(tonumber(list.selected) or 0)
    if count < 1 or currentIndex < 1 or currentIndex > count then return false end

    local state = recipeDirectionLocks[playerNum]
    if not state then state = {}; recipeDirectionLocks[playerNum] = state end
    local rtDown = isRightTriggerDown(controllerId)
    if state[direction] == "needs-release" then return false end
    if state[direction] == "handled" and rtDown then return true end
    if not rtDown then
        if isRecipeDirectionDown(controllerId, direction) then state[direction] = "needs-release" end
        return false
    end

    state[direction] = "handled"
    -- Match container paging exactly: add/subtract seven list rows, selecting
    -- the eighth row counting the current selection.
    local targetIndex = direction == "down"
        and math.min(count, currentIndex + 7)
        or math.max(1, currentIndex - 7)
    if targetIndex == currentIndex then
        log("RT+" .. direction .. " recipe page reached boundary: player=" .. tostring(playerNum)
            .. ", index=" .. tostring(currentIndex) .. ", count=" .. tostring(count))
        return true
    end

    local row = list.items[targetIndex]
    list.selected = targetIndex
    if type(list.ensureVisible) == "function" then
        local ok, err = pcall(list.ensureVisible, list, targetIndex)
        if not ok then log("Recipe page ensureVisible failed: " .. tostring(err), true) end
    end
    if row and not row.groupNode and row.item and type(list.onmousedown) == "function" then
        local ok, err = pcall(list.onmousedown, list.target, row.item)
        if not ok then log("Recipe page detail refresh failed: " .. tostring(err), true) end
    end
    local sound = rawget(_G, "getSoundManager")
    if type(sound) == "function" then
        pcall(function() getSoundManager():playUISound("UISelectListItem") end)
    end
    log("RT+" .. direction .. " recipe page navigation: player=" .. tostring(playerNum)
        .. ", index=" .. tostring(currentIndex) .. " -> " .. tostring(targetIndex)
        .. ", count=" .. tostring(count))
    return true
end

local function tryRecipeCategoryPageNavigation(list, direction, joypadData)
    if not isEnabled() or type(list) ~= "table" or list._gqsRecipeCategoryList ~= true
        or type(list.items) ~= "table" then return false end
    local playerNum = getRecipePlayerNum(list, joypadData)
    if playerNum == nil then return false end
    local controllerId = getControllerId(playerNum, joypadData)
    if controllerId < 0 then return false end
    local count = math.min(tonumber(list.count) or #list.items, #list.items)
    local currentIndex = math.floor(tonumber(list.selected) or 0)
    if count < 1 then return false end
    if currentIndex < 1 then currentIndex = direction == "up" and count or 1 end
    currentIndex = math.min(count, currentIndex)

    local state = recipeDirectionLocks[playerNum]
    if not state then state = {}; recipeDirectionLocks[playerNum] = state end
    local rtDown = isRightTriggerDown(controllerId)
    if state[direction] == "needs-release" then return false end
    if state[direction] == "handled" and rtDown then return true end
    if not rtDown then
        if isRecipeDirectionDown(controllerId, direction) then state[direction] = "needs-release" end
        return false
    end
    state[direction] = "handled"

    local targetIndex = direction == "down"
        and math.min(count, currentIndex + 7)
        or math.max(1, currentIndex - 7)
    if targetIndex == currentIndex then
        log("RT+" .. direction .. " recipe category page reached boundary: player=" .. tostring(playerNum)
            .. ", index=" .. tostring(currentIndex) .. ", count=" .. tostring(count))
        return true
    end

    list.selected = targetIndex
    if type(list.ensureVisible) == "function" then
        local ok, err = pcall(list.ensureVisible, list, targetIndex)
        if not ok then log("Recipe category ensureVisible failed: " .. tostring(err), true) end
    end
    local row = list.items[targetIndex]
    if row and row.item ~= nil and type(list.onmousedown) == "function" then
        local ok, err = pcall(list.onmousedown, list.target, row.item)
        if not ok then log("Recipe category selection callback failed: " .. tostring(err), true) end
    end
    local sound = rawget(_G, "getSoundManager")
    if type(sound) == "function" then
        pcall(function() getSoundManager():playUISound("UISelectListItem") end)
    end
    log("RT+" .. direction .. " recipe category page navigation: player=" .. tostring(playerNum)
        .. ", index=" .. tostring(currentIndex) .. " -> " .. tostring(targetIndex)
        .. ", count=" .. tostring(count))
    return true
end

local function clearReleasedRecipeDirections()
    for playerNum, state in pairs(recipeDirectionLocks) do
        local controllerId = getControllerId(playerNum)
        if controllerId < 0 or not isRecipeDirectionDown(controllerId, "up") then state.up = nil end
        if controllerId < 0 or not isRecipeDirectionDown(controllerId, "down") then state.down = nil end
        if state.up == nil and state.down == nil then recipeDirectionLocks[playerNum] = nil end
    end
end

local function getSkillDirectionState(playerNum)
    local state = skillDirectionLocks[playerNum]
    if not state then
        state = {}
        skillDirectionLocks[playerNum] = state
    end
    return state
end

local function trySkillPageNavigation(panel, direction)
    if not isEnabled() or type(panel) ~= "table" then return false end
    local playerNum = tonumber(panel.playerNum)
    local bars = panel.progressBars
    local count = type(bars) == "table" and #bars or 0
    if not playerNum or count < 2 then return false end

    local controllerId = getControllerId(playerNum)
    if controllerId < 0 then return false end
    local state = getSkillDirectionState(playerNum)
    local rtDown = isRightTriggerDown(controllerId)

    if state[direction] == "needs-release" then
        -- D-pad was pressed before RT; don't convert a held direction into a page.
        return false
    end
    if state[direction] == "handled" and rtDown then
        -- Ignore controller repeat until this D-pad direction is released.
        return true
    end
    if not rtDown then
        if isSkillDirectionDown(controllerId, direction) then
            state[direction] = "needs-release"
        end
        return false
    end

    state[direction] = "handled"
    local currentIndex = tonumber(panel.joypadIndex)
    if not currentIndex or currentIndex < 1 or currentIndex > count then
        currentIndex = direction == "up" and count or 1
    end
    local targetIndex
    if direction == "down" then
        targetIndex = math.min(count, currentIndex + 7)
    else
        targetIndex = math.max(1, currentIndex - 7)
    end

    if targetIndex == currentIndex then
        log("RT+" .. direction .. " skill page reached boundary: player=" .. tostring(playerNum)
            .. ", index=" .. tostring(currentIndex) .. ", count=" .. tostring(count))
        return true
    end

    panel.joypadIndex = targetIndex
    if type(panel.ensureVisible) == "function" then
        local ok, err = pcall(panel.ensureVisible, panel)
        if not ok then log("Skill page ensureVisible failed: " .. tostring(err), true) end
    end
    log("RT+" .. direction .. " skill page navigation: player=" .. tostring(playerNum)
        .. ", index=" .. tostring(currentIndex) .. " -> " .. tostring(targetIndex)
        .. ", count=" .. tostring(count))
    return true
end

local function clearReleasedSkillDirections()
    for playerNum, state in pairs(skillDirectionLocks) do
        local controllerId = getControllerId(playerNum)
        if controllerId < 0 or not isSkillDirectionDown(controllerId, "up") then state.up = nil end
        if controllerId < 0 or not isSkillDirectionDown(controllerId, "down") then state.down = nil end
        if state.up == nil and state.down == nil then skillDirectionLocks[playerNum] = nil end
    end
end

local function removeTooltip(bar)
    if bar and type(bar.removeTooltip) == "function" then
        pcall(bar.removeTooltip, bar)
    end
end

local function updateSelectedSkillTooltip(panel, direction)
    if not isEnabled() then
        removeTooltip(panel.barWithTooltip)
        panel.barWithTooltip = nil
        return
    end

    local bars = panel.progressBars
    local index = panel.joypadIndex
    local bar = type(bars) == "table" and type(index) == "number" and bars[index] or nil
    if not bar then
        log("Skill navigation captured but no progress bar is selected: direction=" .. tostring(direction)
            .. ", index=" .. tostring(index) .. ", count=" .. tostring(type(bars) == "table" and #bars or "unavailable"))
        return
    end

    if panel.barWithTooltip and panel.barWithTooltip ~= bar then
        removeTooltip(panel.barWithTooltip)
    end
    panel.barWithTooltip = bar

    if type(bar.updateTooltip) ~= "function" then
        log("Selected skill bar has no updateTooltip method: index=" .. tostring(index), true)
        return
    end

    local ok, err = pcall(bar.updateTooltip, bar, bar.level)
    if ok then
        local perkName = "unknown"
        if bar.perk and type(bar.perk.getName) == "function" then
            local perkOK, value = pcall(bar.perk.getName, bar.perk)
            if perkOK and value ~= nil then perkName = tostring(value) end
        end
        log("Joypad skill selected: direction=" .. tostring(direction) .. ", index=" .. tostring(index)
            .. ", perk=" .. perkName .. ", level=" .. tostring(bar.level))
    else
        log("Failed to build selected skill tooltip: " .. tostring(err), true)
    end
end

local function isXButton(button)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad.XButton ~= nil and button == joypad.XButton then return true end
    local buttons = rawget(_G, "JoypadButton")
    if buttons and buttons.X ~= nil and button == buttons.X then return true end
    local ok, text = pcall(tostring, button)
    return ok and (text == "X" or text == "JoypadButton.X" or text == "zombie.input.JoypadButton.X")
end

local function isYButton(button)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad.YButton ~= nil and button == joypad.YButton then return true end
    local buttons = rawget(_G, "JoypadButton")
    if buttons and buttons.Y ~= nil and button == buttons.Y then return true end
    local ok, text = pcall(tostring, button)
    return ok and (text == "Y" or text == "JoypadButton.Y" or text == "zombie.input.JoypadButton.Y")
end

local function recipeFavoriteState(recipe, player)
    if not recipe or not player then return nil, nil end
    local ok, favorite = pcall(function() return recipe:isFavourite(player) end)
    if ok and type(favorite) == "boolean" then return favorite, nil end

    local base = rawget(_G, "BaseCraftingLogic")
    local key
    if base and type(base.getFavouriteModDataString) == "function" then
        local keyOK, value = pcall(base.getFavouriteModDataString, recipe)
        if keyOK then key = value end
    end
    if type(key) ~= "string" or key == "" then return nil, nil end
    local dataOK, data = pcall(player.getModData, player)
    if not dataOK or type(data) ~= "table" then return nil, key end
    return data[key] == true, key
end

local function toggleRecipeFavorite(list)
    if not isEnabled() then return false end
    local row = list and type(list.items) == "table" and list.items[list.selected] or nil
    local recipe = row and not row.groupNode and row.item or nil
    local player = list.player
    if not recipe or not player then return false end

    local favorite, key = recipeFavoriteState(recipe, player)
    if favorite == nil then
        log("Cannot read selected recipe favorite state", true)
        return false
    end
    if not key then
        local base = rawget(_G, "BaseCraftingLogic")
        if base and type(base.getFavouriteModDataString) == "function" then
            local ok, value = pcall(base.getFavouriteModDataString, recipe)
            if ok then key = value end
        end
    end
    if type(key) ~= "string" or key == "" then
        log("Cannot resolve vanilla recipe favorite key", true)
        return false
    end

    local okData, data = pcall(player.getModData, player)
    if not okData or type(data) ~= "table" then return false end
    data[key] = not favorite
    if type(player.transmitModData) == "function" then pcall(player.transmitModData, player) end

    -- Re-selecting the same recipe can be treated as a no-op by the crafting
    -- logic, leaving its detail widgets with the old favorite state. Clear and
    -- restore the recipe through the vanilla selection callback to make the
    -- detail panel rebuild without changing the list selection or focus.
    if type(list.onmousedown) == "function" then
        local cleared, clearError = pcall(list.onmousedown, list.target, nil)
        if not cleared then
            log("Failed to clear selected recipe details before favorite refresh: " .. tostring(clearError), true)
        end
        local refreshed, refreshError = pcall(list.onmousedown, list.target, recipe)
        if not refreshed then
            log("Failed to refresh selected recipe details after favorite toggle: " .. tostring(refreshError), true)
        else
            log("Refreshed selected recipe details after favorite toggle: recipe=" .. tostring(recipe:getName()))
        end
    else
        log("Selected recipe favorite changed, but the list has no selection callback to refresh details", true)
    end

    local sound = rawget(_G, "getSoundManager")
    if type(sound) == "function" then
        pcall(function() getSoundManager():playUISound("UISelectListItem") end)
    end
    log("Joypad X toggled recipe favorite: recipe=" .. tostring(recipe:getName()) .. ", favorite=" .. tostring(not favorite))
    return true
end

local function getFocusedWindowControls(window)
    local playerNum = tonumber(window and window.playerNum)
    if not playerNum then return nil, nil, false end
    local focus
    if type(getJoypadFocus) == "function" then
        local ok, value = pcall(getJoypadFocus, playerNum)
        if ok then focus = value end
    end
    if not focus and JoypadState and type(JoypadState.players) == "table" then
        local playerData = JoypadState.players[playerNum + 1]
        focus = playerData and playerData.focus or nil
    end
    local current, seen, focusedList, focusedListKind = focus, {}, nil, nil
    while current and not seen[current] do
        if not focusedList and current._gqsRecipeFavoriteList then
            focusedList, focusedListKind = current, "recipe"
        elseif not focusedList and current._gqsRecipeCategoryList then
            focusedList, focusedListKind = current, "category"
        end
        if current == window then return focusedList, focusedListKind, true end
        seen[current] = true
        current = current.parent
    end
    return focusedList, focusedListKind, false
end

local function getRightTriggerTexture()
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    if not textures then return nil, nil end
    for _, name in ipairs({ "RTrigger", "RTButton", "RightTrigger", "RightTriggerButton", "RT", "R2Button" }) do
        if textures[name] then return textures[name], name end
    end
    return nil, nil
end

local recipeListTriggerTextureLogged = false

local function getJoypadTexture(names)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    if not textures then return nil, nil end
    for _, name in ipairs(names) do
        if textures[name] then return textures[name], name end
    end
    return nil, nil
end

local function getTextureSize(texture, fallbackSize)
    local width, height = 0, 0
    if texture and type(texture.getWidth) == "function" then
        local ok, value = pcall(texture.getWidth, texture)
        if ok and type(value) == "number" then width = value end
    end
    if texture and type(texture.getHeight) == "function" then
        local ok, value = pcall(texture.getHeight, texture)
        if ok and type(value) == "number" then height = value end
    end
    if width > 0 and height > 0 then
        return fallbackSize * width / math.max(width, height), fallbackSize * height / math.max(width, height)
    end
    return fallbackSize, fallbackSize
end

local function findRecipeFilterPanel(window)
    local seen = {}
    local function visit(element, depth)
        if type(element) ~= "table" or seen[element] or depth > 20 then return nil end
        seen[element] = true
        if element.tickBoxShowAllVersion then
            return element, element.tickBoxShowAllVersion, "version"
        end
        if element.showAllRecipeTickBox then
            return element, element.showAllRecipeTickBox, "recipe"
        end
        local children = element.children
        if type(children) == "table" then
            for _, child in pairs(children) do
                local filter, tickBox, filterKind = visit(child, depth + 1)
                if filter then return filter, tickBox, filterKind end
            end
        end
        return nil
    end
    return visit(window, 0)
end

local function toggleShowAllPanelItems(window)
    if not isEnabled() then return false end
    local filter, tickBox, filterKind = findRecipeFilterPanel(window)
    if not filter or not tickBox or type(tickBox.selected) ~= "table" then
        log("Y show-all toggle unavailable: vanilla filter checkbox was not found", true)
        return false
    end
    local enabled = tickBox.selected[1] ~= true
    tickBox.selected[1] = enabled
    local callbackName = filterKind == "version" and "onShowAllVersionClick" or "onShowAllRecipeClick"
    local callback = filter[callbackName]
    if type(callback) ~= "function" then
        tickBox.selected[1] = not enabled
        log("Y show-all toggle unavailable: vanilla " .. callbackName .. " callback is missing", true)
        return false
    end
    local ok, err = pcall(callback, filter, 1, enabled)
    if not ok then
        tickBox.selected[1] = not enabled
        log("Y show-all toggle failed: " .. tostring(err), true)
        return false
    end
    local sound = rawget(_G, "getSoundManager")
    if type(sound) == "function" then
        pcall(function() getSoundManager():playUISound("UISelectListItem") end)
    end
    log("Joypad Y toggled show-all filter: type=" .. tostring(filterKind) .. ", enabled=" .. tostring(enabled))
    return true
end

local function drawRecipeFavoritePrompt(header, window)
    if not isEnabled() or not header or type(header.getWidth) ~= "function"
        or type(header.getHeight) ~= "function" then return end
    local list, listKind, windowFocused = getFocusedWindowControls(window)
    if not windowFocused then return end
    local row = list and type(list.items) == "table" and list.items[list.selected] or nil
    local recipe = listKind == "recipe" and row and not row.groupNode and row.item or nil
    if type(header.drawText) ~= "function" then return end
    local favoriteLabel, showAllLabel
    local xTexture = getJoypadTexture({ "XButton" })
    local yTexture = getJoypadTexture({ "YButton" })
    local bTexture = getJoypadTexture({ "BButton" })
    local rbTexture = getJoypadTexture({ "RBumper", "RBButton" })
    local rtTexture, rtTextureName = getRightTriggerTexture()
    local dpad = {
        up = getJoypadTexture({ "DPadUp", "DpadUp", "UpArrow" }),
        down = getJoypadTexture({ "DPadDown", "DpadDown", "DownArrow" }),
        left = getJoypadTexture({ "DPadLeft", "DpadLeft", "LeftArrow" }),
        right = getJoypadTexture({ "DPadRight", "DpadRight", "RightArrow" }),
    }
    local filter, showAllTickBox, filterKind = findRecipeFilterPanel(window)
    if filter and showAllTickBox and type(showAllTickBox.selected) == "table" then
        local checked = showAllTickBox.selected[1] == true
        local key
        if filterKind == "version" then
            key = checked and "UI_GQOS_PanelHideAllVersions" or "UI_GQOS_PanelShowAllVersions"
        else
            key = checked and "UI_GQOS_PanelHideAllRecipes" or "UI_GQOS_PanelShowAllRecipes"
        end
        showAllLabel = type(getText) == "function" and getText(key) or key
    end
    if recipe and xTexture then
        local favorite = recipeFavoriteState(recipe, list.player)
        if favorite ~= nil then
            local labelKey = favorite and "UI_GQOS_PanelRecipeUnfavorite" or "UI_GQOS_PanelRecipeFavorite"
            favoriteLabel = type(getText) == "function" and getText(labelKey)
                or (favorite and "Unfavorite recipe" or "Favorite recipe")
        end
    end
    local font = UIFont and UIFont.Small
    if not font or type(getTextManager) ~= "function" then return end
    local rbLabel = type(getText) == "function" and getText("UI_GQOS_PanelSwitchArea") or "Switch panel area"
    local pageLabel = type(getText) == "function" and getText("UI_GQOS_PanelRecipePage") or "Page"
    local closeLabel = type(getText) == "function" and getText("UI_GQOS_PanelClose") or "Close"
    local groups = {}
    local function token(texture, fallback)
        return { texture = texture, fallback = fallback }
    end
    local function txt(value) return { text = value } end
    local function addGroup(parts)
        local tokens = {}
        for _, part in ipairs(parts) do tokens[#tokens + 1] = part end
        tokens[#tokens + 1] = txt(" ")
        groups[#groups + 1] = tokens
    end
    addGroup({ token(rbTexture, "RB"), txt(rbLabel) })
    addGroup({ token(rtTexture, "RT"), txt("+"), token(dpad.up, "↑"), txt("/"), token(dpad.down, "↓"), txt(pageLabel) })
    if favoriteLabel then addGroup({ token(xTexture, "X"), txt(favoriteLabel) }) end
    if showAllLabel then addGroup({ token(yTexture, "Y"), txt(showAllLabel) }) end
    addGroup({ token(bTexture, "B"), txt(closeLabel) })

    local ok, manager = pcall(getTextManager)
    if not ok or not manager then return end
    local height = header:getHeight()
    local iconSize = math.max(14, math.min(20, height - 6))
    local tokenGap, groupGap, totalWidth = 5, 18, 0
    local lineHeight = manager:MeasureStringY(font, "Ag")
    for groupIndex, parts in ipairs(groups) do
        local width = 0
        for partIndex, part in ipairs(parts) do
            if part.texture and type(header.drawTextureScaled) == "function" then
                part.width, part.height = getTextureSize(part.texture, iconSize)
            else
                part.width = manager:MeasureStringX(font, part.text or part.fallback or "")
                part.height = lineHeight
            end
            width = width + part.width
            if partIndex < #parts then width = width + tokenGap end
        end
        parts.width = width
        totalWidth = totalWidth + width
        if groupIndex < #groups then totalWidth = totalWidth + groupGap end
    end
    local x = math.floor((header:getWidth() - totalWidth) / 2)
    for _, parts in ipairs(groups) do
        for _, part in ipairs(parts) do
            if part.texture and type(header.drawTextureScaled) == "function" then
                pcall(header.drawTextureScaled, header, part.texture, x, math.floor((height - part.height) / 2),
                    part.width, part.height, 1, 1, 1, 1)
            else
                local label = part.text or part.fallback or ""
                pcall(header.drawText, header, label, x, math.floor((height - lineHeight) / 2), 1, 1, 1, 1, font)
            end
            x = x + part.width + tokenGap
        end
        x = x + groupGap - tokenGap
    end
    if not recipeListTriggerTextureLogged then
        log(rtTexture and ("Using RT button prompt texture: Joypad.Texture." .. tostring(rtTextureName))
            or "RT button prompt texture not found; showing RT text label")
        recipeListTriggerTextureLogged = true
    end
end

local function installHeaderPrompt(windowClass)
    if not windowClass or windowClass._gqsRecipeFavoriteHeaderInstalled
        or type(windowClass.createChildren) ~= "function" then return end
    local originalCreateChildren = windowClass.createChildren
    windowClass.createChildren = function(self, ...)
        local result = originalCreateChildren(self, ...)
        local header = self.windowHeader or self.header
        if header and type(header.render) == "function" and not header._gqsRecipeFavoritePromptInstalled then
            local originalRender = header.render
            header.render = function(headerSelf, ...)
                local renderResult = originalRender(headerSelf, ...)
                drawRecipeFavoritePrompt(headerSelf, self)
                return renderResult
            end
            header._gqsRecipeFavoritePromptInstalled = true
        end
        return result
    end
    windowClass._gqsRecipeFavoriteHeaderInstalled = true
end

local function installShowAllYControl(windowClass)
    if not windowClass or windowClass._gqsPanelShowAllYInstalled then return end
    local original = windowClass.onJoypadDown_Descendant
    if type(original) ~= "function" then return end
    windowClass.onJoypadDown_Descendant = function(self, descendant, button, joypadData, ...)
        if isYButton(button) and toggleShowAllPanelItems(self) then return end
        return original(self, descendant, button, joypadData, ...)
    end
    windowClass._gqsPanelShowAllYInstalled = true
    log("Installed Y show-all toggle for " .. tostring(windowClass.Type or windowClass.__class or "recipe panel"))
end

local function installRecipeFavoriteControls()
    pcall(require, "Entity/ISUI/CraftRecipe/ISRecipeScrollingListBox")
    local recipeList = rawget(_G, "ISRecipeScrollingListBox")
    if recipeList and type(recipeList.onJoypadDown) == "function"
        and not recipeList._gqsFavoriteXInstalled then
        local originalJoypadDown = recipeList.onJoypadDown
        recipeList.onJoypadDown = function(self, button, joypadData, ...)
            if isXButton(button) and toggleRecipeFavorite(self) then return end
            return originalJoypadDown(self, button, joypadData, ...)
        end
        recipeList._gqsFavoriteXInstalled = true
        recipeList._gqsRecipeFavoriteList = true
    end
    if recipeList then
        for _, direction in ipairs({ "Up", "Down" }) do
            local lowerDirection = direction == "Up" and "up" or "down"
            local methodName = "onJoypadDir" .. direction
            local flagName = direction == "Up" and "_gqsPanelRecipePageUpInstalled" or "_gqsPanelRecipePageDownInstalled"
            if type(recipeList[methodName]) == "function" and not recipeList[flagName] then
                local original = recipeList[methodName]
                recipeList[methodName] = function(self, joypadData, ...)
                    if tryRecipePageNavigation(self, lowerDirection, joypadData) then return end
                    return original(self, joypadData, ...)
                end
                recipeList[flagName] = true
                log("Installed ISRecipeScrollingListBox:" .. methodName .. " hook")
            end
        end
        recipeList._gqsRecipeFavoriteList = true
    end

    pcall(require, "ISUI/ISScrollingListBox")
    pcall(require, "Entity/ISUI/CraftRecipe/ISWidgetRecipeCategories")
    local categoryWidget = rawget(_G, "ISWidgetRecipeCategories")
    if categoryWidget and type(categoryWidget.createChildren) == "function"
        and not categoryWidget._gqsRecipeCategoryListInstalled then
        local originalCreateChildren = categoryWidget.createChildren
        categoryWidget.createChildren = function(self, ...)
            local result = originalCreateChildren(self, ...)
            local categoryList = self.recipeCategoryPanel
            if categoryList then
                categoryList._gqsRecipeCategoryList = true
            end
            return result
        end
        categoryWidget._gqsRecipeCategoryListInstalled = true
        log("Installed ISWidgetRecipeCategories child list marker")
    end

    local scrollingList = rawget(_G, "ISScrollingListBox")
    if scrollingList then
        for _, direction in ipairs({ "Up", "Down" }) do
            local lowerDirection = direction == "Up" and "up" or "down"
            local methodName = "onJoypadDir" .. direction
            local flagName = direction == "Up" and "_gqsPanelCategoryPageUpInstalled" or "_gqsPanelCategoryPageDownInstalled"
            if type(scrollingList[methodName]) == "function" and not scrollingList[flagName] then
                local original = scrollingList[methodName]
                scrollingList[methodName] = function(self, joypadData, ...)
                    if tryRecipeCategoryPageNavigation(self, lowerDirection, joypadData) then return end
                    return original(self, joypadData, ...)
                end
                scrollingList[flagName] = true
                log("Installed ISScrollingListBox category " .. methodName .. " hook")
            end
        end
    end

    pcall(require, "ISUI/Building/ISBuildWindow")
    pcall(require, "ISUI/Crafting/ISHandcraftWindow")
    local buildWindow = rawget(_G, "ISBuildWindow")
    local handcraftWindow = rawget(_G, "ISHandcraftWindow")
    installHeaderPrompt(buildWindow)
    installHeaderPrompt(handcraftWindow)
    installShowAllYControl(buildWindow)
    installShowAllYControl(handcraftWindow)
end

local lastInstallError
local function install()
    installRecipeFavoriteControls()
    local ok, err = pcall(require, "XpSystem/ISUI/ISSkillProgressBar")
    local Bar = rawget(_G, "ISSkillProgressBar")
    if not Bar then
        ok, err = pcall(require, "ISUI/ISSkillProgressBar")
        Bar = rawget(_G, "ISSkillProgressBar")
    end

    local charOK, charErr = pcall(require, "XpSystem/ISUI/ISCharacterInfo")
    local CharacterInfo = rawget(_G, "ISCharacterInfo")
    if not CharacterInfo then
        charOK, charErr = pcall(require, "ISUI/ISCharacterInfo")
        CharacterInfo = rawget(_G, "ISCharacterInfo")
    end

    if not Bar or not CharacterInfo
        or type(Bar.updateTooltip) ~= "function"
        or type(Bar.render) ~= "function"
        or type(Bar.removeTooltip) ~= "function"
        or type(CharacterInfo.onJoypadDirUp) ~= "function"
        or type(CharacterInfo.onJoypadDirDown) ~= "function" then
        local message = "waiting for skill UI classes: bar=" .. tostring(Bar ~= nil)
            .. ", characterInfo=" .. tostring(CharacterInfo ~= nil)
            .. ", require=" .. tostring(charErr or err)
        if lastInstallError ~= message then
            lastInstallError = message
            log(message)
        end
        return false
    end

    if not Bar._gqsPanelInfoTooltipLifecycleInstalled then
        local originalRemoveTooltip = Bar.removeTooltip
        Bar.removeTooltip = function(self, ...)
            if self._gqsPanelInfoPreservingJoypadTooltip then return end
            return originalRemoveTooltip(self, ...)
        end

        local originalRender = Bar.render
        Bar.render = function(self, ...)
            local parent = self.parent
            self._gqsPanelInfoPreservingJoypadTooltip = isEnabled()
                and parent ~= nil and parent.joyfocus and parent.barWithTooltip == self
            local okRender, renderError = pcall(originalRender, self, ...)
            self._gqsPanelInfoPreservingJoypadTooltip = nil
            if not okRender then error(renderError) end
        end

        Bar._gqsPanelInfoTooltipLifecycleInstalled = true
        log("Installed selected-skill tooltip preservation during render")
    end

    if CharacterInfo._gqsPanelInfoJoypadInstalled then return true end

    for _, direction in ipairs({ "Up", "Down" }) do
        local callbackDirection = direction
        local navigationDirection = direction == "Up" and "up" or "down"
        local methodName = "onJoypadDir" .. callbackDirection
        local original = CharacterInfo[methodName]
        CharacterInfo[methodName] = function(self, ...)
            if trySkillPageNavigation(self, navigationDirection) then
                updateSelectedSkillTooltip(self, callbackDirection)
                return
            end
            local result = original(self, ...)
            updateSelectedSkillTooltip(self, callbackDirection)
            return result
        end
    end

    CharacterInfo._gqsPanelInfoJoypadInstalled = true
    lastInstallError = nil
    log("Installed ISCharacterInfo joypad Up/Down hooks; skill selection uses progressBars[joypadIndex]")
    return true
end

log("Module loaded; attaching to the Build 42 skill-panel selection callbacks")
if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(install) end
    if Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end
end
install()

-- Retry in case the skill UI classes become available after this client module loads.
if Events and Events.OnTick then
    local ticks = 0
    Events.OnTick.Add(function()
        clearReleasedSkillDirections()
        clearReleasedRecipeDirections()
        ticks = ticks + 1
        if ticks % 30 ~= 0 then return end
        installRecipeFavoriteControls()
        local CharacterInfo = rawget(_G, "ISCharacterInfo")
        if not CharacterInfo or not CharacterInfo._gqsPanelInfoJoypadInstalled then install() end
    end)
end
