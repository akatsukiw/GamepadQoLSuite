-- Gamepad QoL Suite v1.4.1
-- RT + D-pad Up/Down pages through the currently focused inventory container.
-- The item index is the current UI row index (after sorting/grouping), not a
-- permanent item ID. The vanilla page's ensureVisible() method handles scrolling.

local LOG_CATEGORY = "containerPageNav"
local directionLocks = {}

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log(LOG_CATEGORY, message)
    end
end

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

local function isButtonDown(controllerId, enumName, legacyName)
    if type(controllerId) ~= "number" or controllerId < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and buttons[enumName]
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(button.isDown, button, controllerId)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    local legacyButton = joypad and joypad[legacyName or enumName]
    if legacyButton ~= nil and type(isJoypadPressed) == "function" then
        local ok, down = pcall(isJoypadPressed, controllerId, legacyButton)
        if ok then return down == true end
    end
    return false
end

local function isDirectionDown(controllerId, direction)
    if direction == "up" then
        return isButtonDown(controllerId, "DPadUp", "DPadUp")
    end
    return isButtonDown(controllerId, "DPadDown", "DPadDown")
end

local function isShoulderDown(controllerId)
    return isButtonDown(controllerId, "LeftBump", "LBumper")
        or isButtonDown(controllerId, "RightBump", "RBumper")
end

local function getVisibleRange(page, pane, itemCount)
    local rowHeight = tonumber(pane.itemHgt) or 0
    local headerHeight = tonumber(pane.headerHgt) or 17
    local paneHeight = tonumber(pane.height) or 0
    if rowHeight <= 0 or paneHeight <= 0 then return 1, math.min(1, itemCount), 1 end

    -- ISInventoryPage:ensureVisible() reserves a header band at both the top
    -- and bottom of its scrolling viewport. Use those same dimensions.
    local visibleRows = math.floor((paneHeight - headerHeight * 2) / rowHeight)
    if visibleRows < 1 then visibleRows = 1 end

    local scrollY = 0
    if type(pane.getYScroll) == "function" then
        local ok, value = pcall(function() return pane:getYScroll() end)
        if ok and type(value) == "number" then scrollY = value end
    end
    local scrollOffset = math.max(0, -scrollY)
    -- Pick the first fully-visible row when the list is at a fractional scroll offset.
    local firstVisible = math.max(1, math.ceil((scrollOffset - 0.001) / rowHeight) + 1)
    if firstVisible > itemCount then firstVisible = itemCount end
    local lastVisible = math.min(itemCount, firstVisible + visibleRows - 1)
    return firstVisible, lastVisible, visibleRows
end

local function getDirectionState(playerNum)
    local state = directionLocks[playerNum]
    if not state then
        state = {}
        directionLocks[playerNum] = state
    end
    return state
end

local function getNavigationMode()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.containerPageNavMode
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(function() return option:getValue() end)
        if ok and type(value) == "number" then
            value = math.floor(value)
            if value == 2 then return 2 end
        end
    end
    -- Safe fallback and fresh-install default: fixed seven-item jump.
    return 1
end

local function tryPageNavigation(page, direction, joypadData)
    if type(page) ~= "table" or type(page.player) ~= "number" then return false end
    local playerNum = page.player
    local controllerId = getControllerId(playerNum, joypadData)
    if controllerId < 0 then return false end

    local pane = page.inventoryPane
    if type(pane) ~= "table" or page.isCollapsed == true then return false end
    if pane.mode ~= nil and pane.mode ~= "details" then
        return false
    end
    if type(page.isVisible) == "function" then
        local ok, visible = pcall(function() return page:isVisible() end)
        if ok and visible == false then return false end
    end

    local items = pane.items
    local itemCount = type(items) == "table" and #items or 0
    if itemCount < 1 then return false end

    local state = getDirectionState(playerNum)
    local rtDown = isRightTriggerDown(controllerId)

    if state[direction] == "handled" and rtDown then
        -- The same D-pad hold has already paged once; swallow controller repeat.
        return true
    end
    if state[direction] == "needs-release" then
        -- D-pad began before RT (or alongside LB/RB). Don't turn the held D-pad
        -- into a page command just because RT is pressed afterward.
        return false
    end

    if isShoulderDown(controllerId) then
        if isDirectionDown(controllerId, direction) then
            state[direction] = "needs-release"
        end
        return false
    end
    if not rtDown then
        -- Track normal D-pad presses too, to enforce RT-before-direction order.
        if isDirectionDown(controllerId, direction) then
            state[direction] = "needs-release"
        end
        return false
    end

    state[direction] = "handled"
    local currentIndex = math.floor(tonumber(pane.joyselection) or 0) + 1
    if currentIndex < 1 then currentIndex = 1 end
    if currentIndex > itemCount then currentIndex = itemCount end

    local firstVisible, lastVisible, visibleRows = getVisibleRange(page, pane, itemCount)
    local targetIndex
    local navigationMode = getNavigationMode()
    if navigationMode == 1 then
        -- Fixed mode: skip seven rows, selecting the eighth row from the current
        -- selection (e.g. 1 -> 8 -> 15). Clamp at either end of the list.
        if direction == "down" then
            targetIndex = math.min(itemCount, currentIndex + 7)
        else
            targetIndex = math.max(1, currentIndex - 7)
        end
    elseif direction == "down" then
        -- Viewport mode: first move to the bottom row currently visible; once
        -- there, advance roughly one page with a one-row overlap.
        if currentIndex < lastVisible then
            targetIndex = lastVisible
        else
            targetIndex = math.min(itemCount, currentIndex + visibleRows - 1)
        end
    else
        -- Viewport mode: first move to the top row currently visible; once
        -- there, go back roughly one page with a one-row overlap.
        if currentIndex > firstVisible then
            targetIndex = firstVisible
        else
            targetIndex = math.max(1, currentIndex - visibleRows + 1)
        end
    end

    if targetIndex == currentIndex then
        log(string.format("RT+%s reached list boundary: player=%d index=%d count=%d",
            direction, playerNum, currentIndex, itemCount))
        return true
    end

    pane.joyselection = targetIndex - 1
    if type(page.ensureVisible) == "function" then
        local ok, err = pcall(function() page:ensureVisible(targetIndex) end)
        if not ok then
            log("ensureVisible failed for RT+" .. direction .. ": " .. tostring(err))
        end
    elseif type(pane.setYScroll) == "function" then
        -- Fallback for compatible page implementations without ensureVisible().
        local rowHeight = tonumber(pane.itemHgt) or 18
        local headerHeight = tonumber(pane.headerHgt) or 17
        local paneHeight = tonumber(pane.height) or 0
        local rowY = headerHeight + (targetIndex - 1) * rowHeight
        local targetScroll
        if direction == "down" then
            targetScroll = -(rowY + rowHeight - paneHeight)
        else
            targetScroll = -rowY + headerHeight
        end
        pcall(function() pane:setYScroll(targetScroll) end)
    end

    local soundManager = rawget(_G, "getSoundManager") and getSoundManager() or nil
    if soundManager and type(soundManager.playUISound) == "function" then
        pcall(function() soundManager:playUISound("UISelectListItem") end)
    end

    local modeLabel = navigationMode == 1 and "fixed-7" or "viewport"
    log(string.format("RT+%s page navigation (%s): player=%d index=%d -> %d, visible=%d-%d, rows/page=%d, count=%d",
        direction, modeLabel, playerNum, currentIndex, targetIndex, firstVisible, lastVisible, visibleRows, itemCount))
    return true
end

local function wrapDirectionMethod(class, methodName, direction)
    local flagName = direction == "up" and "_gqsContainerPageUpWrapped" or "_gqsContainerPageDownWrapped"
    local originalName = direction == "up" and "_gqsContainerPageOriginalUp" or "_gqsContainerPageOriginalDown"
    if class[flagName] then return end
    local original = class[methodName]
    if type(original) ~= "function" then return end

    class[originalName] = original
    class[methodName] = function(self, joypadData, ...)
        if tryPageNavigation(self, direction, joypadData) then
            return
        end
        return original(self, joypadData, ...)
    end
    class[flagName] = true
    log("installed ISInventoryPage:" .. methodName .. " hook")
end

local function installHooks()
    local class = rawget(_G, "ISInventoryPage")
    if type(class) ~= "table" then return false end
    wrapDirectionMethod(class, "onJoypadDirUp", "up")
    wrapDirectionMethod(class, "onJoypadDirDown", "down")
    return class._gqsContainerPageUpWrapped == true and class._gqsContainerPageDownWrapped == true
end

local function getPlayerControllerId(playerNum)
    return getControllerId(playerNum, nil)
end

local function onTick()
    installHooks()
    for playerNum, state in pairs(directionLocks) do
        local controllerId = getPlayerControllerId(playerNum)
        if controllerId < 0 or not isDirectionDown(controllerId, "up") then
            state.up = nil
        end
        if controllerId < 0 or not isDirectionDown(controllerId, "down") then
            state.down = nil
        end
        if state.up == nil and state.down == nil then
            directionLocks[playerNum] = nil
        end
    end
end

installHooks()
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(installHooks) end
if Events and Events.OnTick then Events.OnTick.Add(onTick) end

log("loaded; RT + D-pad Up/Down navigation modes: fixed jump of 7 items (default) or viewport-aware paging; LB/RB + D-pad remains vanilla")
