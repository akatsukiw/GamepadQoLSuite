-- Gamepad QoL Suite - Build 42.21 ISScrollingListBox joypad-B compatibility fix
-- v1.3.17: B on the right-side available/suitable-items pane closes Handcraft UI.
--
-- The supplied vanilla ISScrollingListBox.lua attempts to call
-- self.joypadParent:getJoypadFocus() without checking whether the method exists.
-- Some Crafting/Handcraft subpanel focus paths do not provide that method.
-- In addition, returning B focus to that broken parent can leave the player
-- with no usable focus (R1 navigation then stops working).
--
-- On the far-right list inside ISHandcraftWindow (the Available/Suitable Items
-- pane), B now closes the whole Handcraft window and restores world focus.
-- Other scrolling lists retain the vanilla navigation behavior, with the
-- optional getJoypadFocus() check guarded for compatibility. No vanilla file
-- or Workshop file is edited.

local GQS_FIX_MARKER = "GQSSafeJoypadBReturnFixApplied"
local GQS_patchedOnJoypadDown = nil
local GQS_RIGHT_PANE_RATIO = 0.72

local function GQS_log(message, isError)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        if isError and type(logger.error) == "function" then
            logger.error("craftingFocus", message)
        else
            logger.log("craftingFocus", message)
        end
    end
end

local function GQS_safeGet(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function GQS_call(object, methodName, ...)
    local method = GQS_safeGet(object, methodName)
    if type(method) ~= "function" then return nil, false end
    local ok, value = pcall(method, object, ...)
    return value, ok
end

local function GQS_isVisible(object)
    local value, ok = GQS_call(object, "isReallyVisible")
    if ok and value ~= nil then return value == true or value == 1 end
    value, ok = GQS_call(object, "isVisible")
    if ok and value ~= nil then return value == true or value == 1 end
    local javaObject = GQS_safeGet(object, "javaObject")
    value, ok = GQS_call(javaObject, "isVisible")
    if ok and value ~= nil then return value == true or value == 1 end
    return nil
end

local function GQS_isHandcraftWindowObject(object)
    if object == nil then return false end
    if type(instanceof) == "function" then
        local ok, result = pcall(instanceof, object, "ISHandcraftWindow")
        if ok and result then return true end
    end
    for _, key in ipairs({ "Type", "type", "className", "ClassName", "name" }) do
        local value = GQS_safeGet(object, key)
        if value ~= nil and string.find(string.lower(tostring(value)), "ishandcraftwindow", 1, true) then
            return true
        end
    end
    local uiName = GQS_call(object, "getUIName")
    return uiName ~= nil and string.find(string.lower(tostring(uiName)), "handcraftwindow", 1, true) ~= nil
end

local function GQS_addCandidate(queue, seen, value)
    if value ~= nil and not seen[value] then
        seen[value] = true
        queue[#queue + 1] = value
    end
end

local function GQS_findHandcraftAncestor(object)
    local queue, seen = {}, {}
    GQS_addCandidate(queue, seen, object)
    local index = 1
    while index <= #queue and index <= 80 do
        local current = queue[index]
        index = index + 1
        if GQS_isHandcraftWindowObject(current) then return current end
        GQS_addCandidate(queue, seen, GQS_safeGet(current, "parent"))
        GQS_addCandidate(queue, seen, GQS_safeGet(current, "joypadParent"))
        local parent = GQS_call(current, "getParent")
        GQS_addCandidate(queue, seen, parent)
        local joypadParent = GQS_call(current, "getJoypadParent")
        GQS_addCandidate(queue, seen, joypadParent)
    end
    return nil
end

local function GQS_getPlayerNum(joypadData, listBox, window)
    local playerNum = GQS_safeGet(joypadData, "player")
    if type(playerNum) == "number" then return playerNum end
    playerNum = GQS_safeGet(joypadData, "playerNum")
    if type(playerNum) == "number" then return playerNum end
    playerNum = GQS_safeGet(listBox, "playerNum")
    if type(playerNum) == "number" then return playerNum end
    playerNum = GQS_safeGet(window, "playerNum")
    if type(playerNum) == "number" then return playerNum end
    local players = JoypadState and JoypadState.players
    if players then
        for i = 1, #players do
            if players[i] == joypadData or GQS_safeGet(players[i], "focus") == listBox then
                return i - 1
            end
        end
    end
    return 0
end

local function GQS_getAbsoluteX(object)
    local value, ok = GQS_call(object, "getAbsoluteX")
    if ok and type(value) == "number" then return value end
    local total, current, seen = 0, object, {}
    for _ = 1, 40 do
        if current == nil or seen[current] then break end
        seen[current] = true
        local x = GQS_safeGet(current, "x")
        if type(x) ~= "number" then x = GQS_call(current, "getX") end
        if type(x) == "number" then total = total + x end
        local parent = GQS_safeGet(current, "parent")
        if parent == nil then parent = GQS_call(current, "getParent") end
        current = parent
    end
    return total
end

local function GQS_getWidth(object)
    local value, ok = GQS_call(object, "getWidth")
    if ok and type(value) == "number" then return value end
    value = GQS_safeGet(object, "width")
    if type(value) == "number" then return value end
    return nil
end

local function GQS_isRightAvailableItemsPane(listBox, handcraftWindow)
    -- Require the focused list to belong to this Handcraft window; geometry alone
    -- should not make an unrelated inventory list close the crafting UI.
    local ancestor = GQS_findHandcraftAncestor(listBox)
    if not ancestor then return false end
    if ancestor ~= handcraftWindow and not GQS_isHandcraftWindowObject(ancestor) then return false end

    local windowX = GQS_getAbsoluteX(handcraftWindow)
    local listX = GQS_getAbsoluteX(listBox)
    local windowWidth = GQS_getWidth(handcraftWindow)
    local listWidth = GQS_getWidth(listBox) or 0
    if type(windowX) ~= "number" or type(listX) ~= "number" or type(windowWidth) ~= "number" or windowWidth <= 0 then
        GQS_log("Could not determine Handcraft/list coordinates; keeping normal B navigation")
        return false
    end

    local centerRatio = ((listX + listWidth / 2) - windowX) / windowWidth
    GQS_log("Handcraft B candidate: list center ratio=" .. tostring(centerRatio))
    return centerRatio >= GQS_RIGHT_PANE_RATIO
end

local function GQS_getHandcraftWindow(playerNum, listBox)
    -- Prefer the actual window in the focus ancestry. It is the object whose
    -- close() method also updates the entity-window state.
    local ancestor = GQS_findHandcraftAncestor(listBox)
    if ancestor then return ancestor end

    local entityUI = rawget(_G, "ISEntityUI")
    if entityUI and type(GQS_safeGet(entityUI, "GetWindowInstance")) == "function" then
        local ok, window = pcall(entityUI.GetWindowInstance, playerNum, "HandcraftWindow")
        if ok and window and GQS_isVisible(window) ~= false then return window end
    end
    return nil
end

local function GQS_closeHandcraftWindow(window, playerNum, joypadData)
    if not window then
        GQS_log("Could not locate HandcraftWindow; B close request was not handled", true)
        return false
    end

    local closed = false
    local closeMethod = GQS_safeGet(window, "close")
    if type(closeMethod) == "function" then
        local ok, err = pcall(closeMethod, window)
        if not ok then
            GQS_log("HandcraftWindow:close() failed: " .. tostring(err), true)
        else
            local visible = GQS_isVisible(window)
            if visible == false then closed = true end
            GQS_log("Called HandcraftWindow:close(); visible=" .. tostring(visible))
        end
    end

    if not closed and GQS_isVisible(window) ~= false then
        local removeMethod = GQS_safeGet(window, "removeFromUIManager")
        if type(removeMethod) == "function" then
            local ok, err = pcall(removeMethod, window)
            if ok then
                closed = true
                GQS_log("Removed HandcraftWindow from UIManager as close fallback")
            else
                GQS_log("HandcraftWindow:removeFromUIManager() failed: " .. tostring(err), true)
            end
        end
    end

    if not closed and GQS_isVisible(window) ~= false then
        local setVisible = GQS_safeGet(window, "setVisible")
        if type(setVisible) == "function" then
            local ok, err = pcall(setVisible, window, false)
            if ok then
                closed = true
                GQS_log("Set HandcraftWindow invisible as final close fallback")
            else
                GQS_log("HandcraftWindow:setVisible(false) failed: " .. tostring(err), true)
            end
        end
    end

    -- Closing the window and returning world focus are separate operations.
    -- Do both so the player is not left with an invisible/stale list focus.
    if type(setJoypadFocus) == "function" then
        local ok, err = pcall(setJoypadFocus, playerNum, nil)
        if not ok then GQS_log("setJoypadFocus(nil) failed after Handcraft close: " .. tostring(err), true) end
    end
    if joypadData and GQS_safeGet(joypadData, "focus") ~= nil then
        pcall(function() joypadData.focus = nil end)
        if type(updateJoypadFocus) == "function" then pcall(updateJoypadFocus, joypadData) end
    end

    local stillVisible = GQS_isVisible(window)
    if stillVisible == false or closed then
        GQS_log("B on Handcraft available-items pane handled by closing the entire Handcraft window")
        return true
    end
    GQS_log("Handcraft close could not be confirmed; B was still consumed to avoid the broken parent-focus path", true)
    return true
end

local function GQS_installScrollingListBoxJoypadFix()
    -- Ensure the vanilla class is defined before patching it.
    pcall(require, "ISUI/ISScrollingListBox")

    local listBoxClass = ISScrollingListBox
    if not listBoxClass or type(listBoxClass.onJoypadDown) ~= "function" then
        return false
    end

    if listBoxClass[GQS_FIX_MARKER] and listBoxClass.onJoypadDown == GQS_patchedOnJoypadDown then
        return true
    end

    local function GQS_safeOnJoypadDown(self, button, joypadData)
        if button == Joypad.AButton and self.overrideAButtonFunction then
            self.overrideAButtonFunction(self.target, self.items[self.selected].item)
            return
        end

        if button == Joypad.AButton and self.onmousedblclick then
            if (#self.items > 0) and (self.selected ~= -1) then
                local previousSelected = self.selected
                self:invokeOnMouseDoubleClick()
                self.selected = previousSelected
            end
        elseif button == Joypad.BButton then
            local playerNum = GQS_getPlayerNum(joypadData, self, nil)
            local handcraftWindow = GQS_getHandcraftWindow(playerNum, self)
            if handcraftWindow and GQS_isVisible(handcraftWindow) ~= false
                and GQS_isRightAvailableItemsPane(self, handcraftWindow) then
                GQS_closeHandcraftWindow(handcraftWindow, playerNum, joypadData)
                return
            end

            if self.joypadParent then
                self.joypadFocused = false
                joypadData.focus = self.joypadParent
                updateJoypadFocus(joypadData)

                -- Guard the optional parent method instead of blindly calling it.
                local parent = self.joypadParent
                local getParentFocus = GQS_safeGet(parent, "getJoypadFocus")
                if joypadData.focus == parent and type(getParentFocus) == "function" then
                    local ok, parentFocus = pcall(getParentFocus, parent)
                    if ok and parentFocus == self then
                        self.joypadFocused = true
                    end
                end
            else
                ISPanelJoypad.onJoypadDown(self, button, joypadData)
            end
        else
            ISPanelJoypad.onJoypadDown(self, button, joypadData)
        end
    end

    GQS_patchedOnJoypadDown = GQS_safeOnJoypadDown
    listBoxClass.onJoypadDown = GQS_patchedOnJoypadDown
    listBoxClass[GQS_FIX_MARKER] = true
    return true
end

-- Apply immediately when possible, then retry after vanilla/UI initialization.
GQS_installScrollingListBoxJoypadFix()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(GQS_installScrollingListBoxJoypadFix)
end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(GQS_installScrollingListBoxJoypadFix)
end
