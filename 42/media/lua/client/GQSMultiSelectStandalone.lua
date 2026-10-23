require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryPane"

-- Legacy compatibility flag. Feature diagnostics are controlled by GQSDebugLog.lua.
GQS_DEBUG_LOGGING = false

-- Integrated Gamepad QoL Suite multi-select module.
-- Use the new public global while preserving the old global as a compatibility alias
-- for the other client modules that still reference GamepadMultiSelectStandalone.
GamepadQoLSuite = rawget(_G, "GamepadQoLSuite") or rawget(_G, "GamepadMultiSelectStandalone") or {}
GamepadMultiSelectStandalone = GamepadQoLSuite -- legacy compatibility alias
local GMS = GamepadQoLSuite

GMS.VERSION = "1.2.3"
GMS.MOD_ID = "GamepadQoLSuite"
GMS.players = GMS.players or {}
GMS.hookedPages = GMS.hookedPages or {}
GMS.hookedPanes = GMS.hookedPanes or {}
GMS.options = GMS.options or {}
GMS.optionsRegistered = GMS.optionsRegistered or false
GMS.cleanUICallbackRegistered = GMS.cleanUICallbackRegistered or false

local OPTIONS_ID = "GamepadQoLSuite"
local OPTIONS_DISPLAY_NAME = "Gamepad QoL Suite"
local LEGACY_OPTIONS_ID = "GamepadMultiSelectStandalone"
local PREVIOUS_OPTIONS_ID = "CustomGamepadUI"

local SELECT_ALL_COMBO = "L3 + R3"
local COMBO_SELECT_ALL_GRACE_TICKS = 3

local BUTTON_CHOICES = { "R2", "L2", "R3", "L3", "Select", "Start", "None" }
local MULTI_SELECT_BUTTONS = BUTTON_CHOICES
-- Append the combination rather than inserting it, so existing option indices
-- for R2/L2/R3/L3/Select/Start/None stay stable.
local SELECT_ALL_BUTTONS = { "R2", "L2", "R3", "L3", "Select", "Start", "None", SELECT_ALL_COMBO }
local RANGE_SELECT_BUTTONS = BUTTON_CHOICES

local BUTTON_ALIASES = {
    R3 = { "RStickButton", "RightStickButton", "RStick", "R3" },
    L3 = { "LStickButton", "LeftStickButton", "LStick", "L3" },
    Select = { "Back", "Select" },
    Start = { "Start" },
}

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("multiSelect", message)
    end
end

local function optionValue(option, fallback)
    if not option then return fallback end
    if type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok and value ~= nil then return value end
    end
    if option.value ~= nil then return option.value end
    return fallback
end

function GMS.isEnabled()
    return optionValue(GMS.options.enabled, true) == true
end

function GMS.getMultiSelectButton()
    local index = tonumber(optionValue(GMS.options.button, 3)) or 3
    return MULTI_SELECT_BUTTONS[index] or "R3"
end

function GMS.getSelectAllButton()
    -- The option uses a new key (SelectAllInput) so an upgrade from v1.0.2
    -- receives the new L3+R3 default instead of retaining the old Select value.
    local index = tonumber(optionValue(GMS.options.selectAllButton, 8)) or 8
    return SELECT_ALL_BUTTONS[index] or SELECT_ALL_COMBO
end

function GMS.getRangeSelectButton()
    local index = tonumber(optionValue(GMS.options.rangeSelectButton, 4)) or 4
    return RANGE_SELECT_BUTTONS[index] or "L3"
end

function GMS.resolveButtonCode(name)
    local aliases = BUTTON_ALIASES[name]
    if not aliases or type(Joypad) ~= "table" then return nil end
    for _, key in ipairs(aliases) do
        if Joypad[key] ~= nil then return Joypad[key] end
    end
    return nil
end

local function playerState(playerNum)
    local key = tostring(playerNum)
    local state = GMS.players[key]
    if not state then
        state = {
            inventoryVisible = false,
            lootVisible = false,
            inventoryPage = nil,
            lootPage = nil,
            triggerActions = {},
            comboPending = {},
            selectAllComboDown = false,
        }
        GMS.players[key] = state
    end
    return state
end

local function wipeTable(target)
    if not target then return end
    if type(table.wipe) == "function" then
        table.wipe(target)
    else
        for key in pairs(target) do target[key] = nil end
    end
end

local function clearComboPending(state)
    if not state then return end
    state.comboPending = state.comboPending or {}
    wipeTable(state.comboPending)
end

local function clearPane(pane)
    if not pane then return end
    pane.selected = pane.selected or {}
    wipeTable(pane.selected)
    pane.firstSelect = nil
    pane.gmsKeepSelection = false
    pane.gmsSelectionState = nil
    pane.gmsRangeAnchor = nil
end

function GMS.clearPlayer(playerNum)
    local inventoryPage = getPlayerInventory and getPlayerInventory(playerNum) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerNum) or nil
    clearPane(inventoryPage and inventoryPage.inventoryPane)
    clearPane(lootPage and lootPage.inventoryPane)
end

function GMS.clearAllPlayers()
    for playerNum = 0, 3 do GMS.clearPlayer(playerNum) end
end

local function isDescendant(element, ancestor)
    local current = element
    for _ = 1, 16 do
        if not current then return false end
        if current == ancestor then return true end
        current = current.parent
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

local function hasOpenContextMenu(playerNum)
    local data = ISPlayerData and ISPlayerData[playerNum + 1]
    local context = data and data.contextMenu
    return context and pageIsVisible(context)
end

function GMS.resolveFocusedPane(page)
    if not page or page.player == nil or not page.inventoryPane then return nil end
    if hasOpenContextMenu(page.player) then return nil end
    local focus = getJoypadFocus and getJoypadFocus(page.player) or nil
    if not focus then return nil end
    if isDescendant(focus, page.inventoryPane) or isDescendant(focus, page) then
        return page.inventoryPane
    end
    return nil
end

local function getPage(playerNum, isLoot)
    if isLoot then
        return getPlayerLoot and getPlayerLoot(playerNum) or nil
    end
    return getPlayerInventory and getPlayerInventory(playerNum) or nil
end

local function resolveFocusedPaneForPlayer(playerNum)
    local inventoryPage = getPage(playerNum, false)
    local lootPage = getPage(playerNum, true)
    local pane = GMS.resolveFocusedPane(inventoryPage)
    if pane then return pane end
    return GMS.resolveFocusedPane(lootPage)
end

-- Diagnostic only: explains why resolveFocusedPaneForPlayer returned nil. Called
-- exclusively from the select-all chord, so it never runs on normal navigation.
local function logFocusDiagnostics(playerNum)
    local focus = getJoypadFocus and getJoypadFocus(playerNum) or nil
    local function describe(page, label)
        if not page then return label .. "=nil" end
        return string.format("%s{player=%s paneExists=%s visible=%s focusInPane=%s focusInPage=%s contextMenu=%s}",
            label, tostring(page.player), tostring(page.inventoryPane ~= nil), tostring(pageIsVisible(page)),
            tostring(page.inventoryPane ~= nil and isDescendant(focus, page.inventoryPane)),
            tostring(isDescendant(focus, page)), tostring(hasOpenContextMenu(playerNum)))
    end
    log("focus diagnostics: focus=" .. tostring(focus) .. " "
        .. describe(getPage(playerNum, false), "inventoryPage") .. " "
        .. describe(getPage(playerNum, true), "lootPage"))
end

local function isInventoryItem(row)
    return row ~= nil and type(instanceof) == "function" and instanceof(row, "InventoryItem")
end

local function selectionState(pane)
    if not pane.gmsSelectionState then pane.gmsSelectionState = {} end
    return pane.gmsSelectionState
end

local function rowToken(row)
    if not row then return nil end
    if isInventoryItem(row) then
        return { item = row, group = false }
    end
    local firstItem = row.items and row.items[1] or nil
    if firstItem then return { item = firstItem, group = true } end
    return nil
end

local function findTokenIndex(pane, token)
    if not pane or not token or not token.item then return nil end
    for index, row in ipairs(pane.items or {}) do
        if token.group then
            if not isInventoryItem(row) and row.items and row.items[1] == token.item then
                return index
            end
        elseif row == token.item then
            return index
        end
    end
    -- The list may have been expanded/collapsed since the anchor was recorded.
    for index, row in ipairs(pane.items or {}) do
        if isInventoryItem(row) and row == token.item then return index end
        if not isInventoryItem(row) and row.items then
            for _, item in ipairs(row.items) do
                if item == token.item then return index end
            end
        end
    end
    return nil
end

local function groupIsSelected(pane, group)
    local saved = selectionState(pane)
    local firstItem = group.items and group.items[1]
    if firstItem and saved[firstItem] == "group" then return true end
    local items = group.items or {}
    if #items == 0 then return false end
    for _, item in ipairs(items) do
        if saved[item] ~= "item" then return false end
    end
    return true
end

local function setGroupSelected(pane, group, selected)
    local saved = selectionState(pane)
    local firstItem = group.items and group.items[1]
    if not firstItem then return end
    for _, item in ipairs(group.items) do saved[item] = nil end
    if selected then saved[firstItem] = "group" end
end

local function markRowSelected(saved, row)
    if not row then return end
    if isInventoryItem(row) then
        saved[row] = "item"
        return
    end
    local firstItem = row.items and row.items[1]
    if not firstItem then return end
    for _, item in ipairs(row.items) do saved[item] = nil end
    saved[firstItem] = "group"
end

local function rowIsSelected(saved, row)
    if not row or not saved then return false end
    if isInventoryItem(row) then return saved[row] == "item" end
    local items = row.items
    if not items or #items == 0 then return false end
    if saved[items[1]] == "group" then return true end
    for _, item in ipairs(items) do
        if saved[item] ~= "item" then return false end
    end
    return true
end

-- Avoid relying on the global next() function: some PZ/Kahlua mod environments
-- do not expose it consistently, which caused select-all and range-select to throw.
local function hasAnyEntries(source)
    if type(source) ~= "table" then return false end
    for _ in pairs(source) do
        return true
    end
    return false
end

local function applyPersistentSelection(pane)
    if not pane then return end
    local saved = pane.gmsSelectionState
    pane.selected = pane.selected or {}
    wipeTable(pane.selected)
    if not saved then return end

    local row = 1
    for _, group in ipairs(pane.itemslist or {}) do
        local firstItem = group.items and group.items[1] or nil
        if firstItem and saved[firstItem] == "group" then
            pane.selected[row] = group
        elseif firstItem and saved[firstItem] == "item" then
            pane.selected[row] = firstItem
        end
        row = row + 1
        if group.items and not ((pane.collapsed or {})[group.name]) then
            for itemIndex = 2, #group.items do
                local item = group.items[itemIndex]
                if saved[item] == "item" then pane.selected[row] = item end
                row = row + 1
            end
        end
    end
end

local function toggleFocusedSelection(pane)
    if not GMS.isEnabled() or not pane or not pane.items then return false end
    local index = (tonumber(pane.joyselection) or -1) + 1
    local row = pane.items[index]
    if index < 1 or not row then return false end

    pane.firstSelect = index
    pane.gmsKeepSelection = true
    if isInventoryItem(row) then
        local saved = selectionState(pane)
        if saved[row] == "item" then saved[row] = nil else saved[row] = "item" end
    else
        setGroupSelected(pane, row, not groupIsSelected(pane, row))
    end
    applyPersistentSelection(pane)
    return true
end

local function focusedRowIndex(pane)
    if not pane or not pane.items then return nil end
    local index = (tonumber(pane.joyselection) or -1) + 1
    if index < 1 or not pane.items[index] then return nil end
    return index
end

-- Diagnostics for the select-all toggle. Temporary: remove together with the
-- multiSelect log category switch once the character-inventory case is verified.
local function countEntries(source)
    local total = 0
    if type(source) ~= "table" then return total end
    for _ in pairs(source) do total = total + 1 end
    return total
end

local function containerLabel(pane)
    if not pane then return "pane=nil" end
    local inv = pane.inventory
    if not inv then return "pane.inventory=nil" end
    local containerType = "?"
    local okType, value = pcall(function() return inv:getType() end)
    if okType and value ~= nil then containerType = tostring(value) end
    local itemCount = -1
    local okSize, size = pcall(function() return inv:getItems():size() end)
    if okSize and type(size) == "number" then itemCount = size end
    return string.format("container=%s onCharacter=%s containedItems=%d",
        containerType, tostring(pane.parent and pane.parent.onCharacter), itemCount)
end

-- True when at least one row that is *currently displayed* in the pane is part of
-- this mod's persistent multi-selection. Only pane.gmsSelectionState is consulted.
--
-- Vanilla's pane.selected is deliberately ignored here. In the character inventory
-- it can keep a single stale entry forever (observed: index 3, the "worn items"
-- group row) because nothing clears it while the container is not redrawn, and
-- that entry made every L3+R3 press take the "clear" branch, so select-all never
-- ran at all. A vanilla single-row highlight is just the focused row, not a
-- multi-selection, so it must not block select-all.
local function paneHasSelection(pane)
    if not pane then return false end
    local saved = pane.gmsSelectionState
    if type(saved) ~= "table" then return false end
    for index, row in ipairs(pane.items or {}) do
        if rowIsSelected(saved, row) then
            log("paneHasSelection: true, row " .. index .. " selected via gmsSelectionState")
            return true
        end
    end
    return false
end

local function selectAll(pane)
    if not GMS.isEnabled() or not pane then return false end

    log(string.format(
        "selectAll enter: %s rows=%d groups=%d keep=%s gmsState=%d paneSelected=%d",
        containerLabel(pane), #(pane.items or {}), #(pane.itemslist or {}),
        tostring(pane.gmsKeepSelection), countEntries(pane.gmsSelectionState), countEntries(pane.selected)))

    -- Toggle semantics: clear first whenever something is already selected, no
    -- matter how many rows that is. Only an entirely unselected pane selects all.
    -- This deliberately does NOT test "are all rows selected": the player list is
    -- rebuilt on every refresh and can hold rows the persistent state cannot map
    -- back (equipped/hotbar name prefixes, the duplicated group header item), so
    -- the old "all rows selected?" test could answer false forever and made the
    -- toggle impossible to switch off in the character inventory.
    if paneHasSelection(pane) then
        clearPane(pane)
        log("selectAll: branch=clear (something was already selected)")
        return true
    end

    if not pane.items or #pane.items == 0 then
        log("selectAll: branch=abort (row list is empty)")
        return false
    end

    local saved = {}
    local marked, skipped = 0, 0
    for _, row in ipairs(pane.items) do
        if isInventoryItem(row) or (type(row) == "table" and row.items and row.items[1]) then
            markRowSelected(saved, row)
            marked = marked + 1
        else
            skipped = skipped + 1
        end
    end
    if not hasAnyEntries(saved) then
        log(string.format("selectAll: branch=abort (no markable row; rows=%d skipped=%d)", #pane.items, skipped))
        return false
    end

    pane.gmsSelectionState = saved
    pane.gmsKeepSelection = true
    pane.firstSelect = (tonumber(pane.joyselection) or -1) + 1
    pane.gmsRangeAnchor = nil
    applyPersistentSelection(pane)
    log(string.format("selectAll: branch=select-all rows=%d marked=%d skipped=%d savedEntries=%d paneSelected=%d",
        #pane.items, marked, skipped, countEntries(saved), countEntries(pane.selected)))
    return true
end

local function selectRange(pane, targetIndex)
    if not GMS.isEnabled() or not pane or not pane.items then return false end
    targetIndex = tonumber(targetIndex)
    if not targetIndex or targetIndex < 1 or not pane.items[targetIndex] then return false end

    local anchorIndex = findTokenIndex(pane, pane.gmsRangeAnchor)
    if not anchorIndex then
        -- If the user has not set an anchor yet, start from the focused row.
        pane.gmsRangeAnchor = rowToken(pane.items[targetIndex])
        anchorIndex = targetIndex
    end

    local firstIndex = math.min(anchorIndex, targetIndex)
    local lastIndex = math.max(anchorIndex, targetIndex)
    -- Extend the existing multi-selection with the range, matching the
    -- behavior of the working Gemini implementation.
    local saved = selectionState(pane)
    for index = firstIndex, lastIndex do markRowSelected(saved, pane.items[index]) end
    if not hasAnyEntries(saved) then return false end

    pane.gmsSelectionState = saved
    pane.gmsKeepSelection = true
    pane.firstSelect = targetIndex
    applyPersistentSelection(pane)
    return true
end

local function triggerAxis(buttonName)
    if type(JoypadAxis1d) ~= "table" then return nil end
    if buttonName == "L2" then return JoypadAxis1d.LeftTrigger end
    if buttonName == "R2" then return JoypadAxis1d.RightTrigger end
    return nil
end

local function isTriggerPressed(axis, playerNum)
    if not axis or type(getJoypadData) ~= "function" then return false end
    local joypadData = getJoypadData(playerNum)
    local controllerID = joypadData and joypadData.id or -1
    if controllerID == nil or controllerID < 0 or type(axis.getValue) ~= "function" then return false end
    local ok, value = pcall(axis.getValue, axis, controllerID)
    if not ok or type(value) ~= "number" then return false end
    local threshold = 0.50
    if type(axis.getDeadZone) == "function" then
        local okDeadZone, deadZone = pcall(axis.getDeadZone, axis, controllerID)
        if okDeadZone and type(deadZone) == "number" then
            threshold = math.max(threshold, math.min(0.95, deadZone + 0.05))
        end
    end
    return value >= threshold
end

-- Query the live controller state for the two stick-click buttons. Build 42
-- exposes JoypadButton.LeftStick/RightStick:isDown(controllerID); the globals
-- are retained as a fallback for game versions/mod environments that expose
-- the older helper functions instead.
local function isStickButtonDown(playerNum, buttonName)
    if type(getJoypadData) ~= "function" then return false end
    local joypadData = getJoypadData(playerNum)
    local controllerID = joypadData and joypadData.id or -1
    if controllerID == nil or controllerID < 0 then return false end

    local enumName = buttonName == "L3" and "LeftStick" or (buttonName == "R3" and "RightStick" or nil)
    local joypadButtons = rawget(_G, "JoypadButton")
    local enumButton = enumName and joypadButtons and joypadButtons[enumName] or nil
    if enumButton and type(enumButton.isDown) == "function" then
        local ok, down = pcall(enumButton.isDown, enumButton, controllerID)
        if ok then return down == true end
    end

    local fallbackName = buttonName == "L3" and "isJoypadLeftStickButtonPressed"
        or (buttonName == "R3" and "isJoypadRightStickButtonPressed" or nil)
    local fallback = fallbackName and rawget(_G, fallbackName) or nil
    if type(fallback) == "function" then
        local ok, down = pcall(fallback, controllerID)
        if ok then return down == true end
    end
    return false
end

local function areComboButtonsDown(playerNum)
    return isStickButtonDown(playerNum, "L3") and isStickButtonDown(playerNum, "R3")
end

local function performMultiSelect(pane)
    local index = focusedRowIndex(pane)
    if not index then return false end
    -- R3 selects/deselects one row and establishes the range anchor.
    -- The item token is more stable than storing a raw row index.
    pane.gmsRangeAnchor = rowToken(pane.items[index])
    return toggleFocusedSelection(pane)
end

local function buttonNameFromCode(button)
    if button == GMS.resolveButtonCode("L3") then return "L3" end
    if button == GMS.resolveButtonCode("R3") then return "R3" end
    return nil
end

-- When L3+R3 is the select-all binding, briefly defer their ordinary L3/R3
-- actions. This gives the second button time to arrive, so a chord does not
-- first perform a range/single selection and then toggle select-all.
local function queueComboIndividualAction(playerNum, buttonName, actionKey)
    local state = playerState(playerNum)
    state.comboPending = state.comboPending or {}
    state.comboPending[buttonName] = { action = actionKey, ticks = 0 }
end

local function handleComboButtonPress(playerNum, button, pane, multiName, rangeName)
    local buttonName = buttonNameFromCode(button)
    if not buttonName then return false end

    local state = playerState(playerNum)
    if areComboButtonsDown(playerNum) then
        if not state.selectAllComboDown then
            state.selectAllComboDown = true
            clearComboPending(state)
            log("combo (joypad-down) fired on player " .. tostring(playerNum) .. " button=" .. tostring(buttonName))
            selectAll(pane)
        else
            log("combo (joypad-down) already consumed for this press; ignoring " .. tostring(buttonName))
        end
        return true
    end

    local actionKey = nil
    if buttonName == multiName and multiName ~= "None" and multiName ~= rangeName then
        actionKey = "multi"
    elseif buttonName == rangeName and rangeName ~= "None" and rangeName ~= multiName then
        actionKey = "range"
    end
    if actionKey then
        queueComboIndividualAction(playerNum, buttonName, actionKey)
        return true
    end
    return false
end

local function processComboSelectAll(playerNum)
    local state = playerState(playerNum)
    if not GMS.isEnabled() or GMS.getSelectAllButton() ~= SELECT_ALL_COMBO then
        clearComboPending(state)
        state.selectAllComboDown = false
        return
    end

    local bothDown = areComboButtonsDown(playerNum)
    if bothDown then
        if not state.selectAllComboDown then
            state.selectAllComboDown = true
            clearComboPending(state)
            local pane = resolveFocusedPaneForPlayer(playerNum)
            if pane then
                log("combo (poll) fired on player " .. tostring(playerNum))
                selectAll(pane)
            else
                log("combo (poll) fired on player " .. tostring(playerNum) .. " but no focused pane was resolved")
                logFocusDiagnostics(playerNum)
            end
        end
        return
    end

    state.selectAllComboDown = false
    for buttonName, pending in pairs(state.comboPending or {}) do
        pending.ticks = (pending.ticks or 0) + 1
        if pending.ticks >= COMBO_SELECT_ALL_GRACE_TICKS then
            state.comboPending[buttonName] = nil
            local pane = resolveFocusedPaneForPlayer(playerNum)
            if pane then
                if pending.action == "multi" then
                    performMultiSelect(pane)
                elseif pending.action == "range" then
                    selectRange(pane, focusedRowIndex(pane))
                end
            end
        end
    end
end

local function pollTriggerAction(playerNum, actionKey, buttonName, actionFunction)
    local state = playerState(playerNum).triggerActions[actionKey]
    if not state then
        state = { down = false, name = nil }
        playerState(playerNum).triggerActions[actionKey] = state
    end

    local axis = triggerAxis(buttonName)
    if not GMS.isEnabled() or not axis then
        state.down = false
        state.name = buttonName
        return
    end

    local multiName = GMS.getMultiSelectButton()
    local allName = GMS.getSelectAllButton()
    local rangeName = GMS.getRangeSelectButton()
    if actionKey == "multi" and (buttonName == allName or buttonName == rangeName) then
        state.down = false
        state.name = buttonName
        return
    end
    if actionKey == "all" and (buttonName == multiName or buttonName == rangeName) then
        state.down = false
        state.name = buttonName
        return
    end
    if actionKey == "range" and (buttonName == multiName or buttonName == allName) then
        state.down = false
        state.name = buttonName
        return
    end

    local down = isTriggerPressed(axis, playerNum)
    if state.name ~= buttonName then
        state.name = buttonName
        state.down = down
        return
    end
    if down and not state.down then
        local pane = resolveFocusedPaneForPlayer(playerNum)
        if pane then actionFunction(pane, playerNum) end
    end
    state.down = down
end

local function snapshotContainers(page)
    local snapshot = {}
    for _, button in ipairs((page and page.backpacks) or {}) do
        if button and button.inventory then snapshot[#snapshot + 1] = button.inventory end
    end
    return snapshot
end

local function sameSnapshot(a, b)
    if a == b then return true end
    if not a or not b or #a ~= #b then return false end
    for index = 1, #a do
        if a[index] ~= b[index] then return false end
    end
    return true
end

local function wrapPaneClass(paneClass)
    if type(paneClass) ~= "table" or GMS.hookedPanes[paneClass] then return end
    GMS.hookedPanes[paneClass] = true

    local oldUpdate = paneClass.update
    if type(oldUpdate) == "function" then
        paneClass.update = function(self, ...)
            local result = oldUpdate(self, ...)
            if GMS.isEnabled() and self.gmsKeepSelection == true then applyPersistentSelection(self) end
            return result
        end
    end

    local oldPrerender = paneClass.prerender
    if type(oldPrerender) == "function" then
        paneClass.prerender = function(self, ...)
            if GMS.isEnabled() and self.gmsKeepSelection == true then applyPersistentSelection(self) end
            local result = oldPrerender(self, ...)
            if GMS.isEnabled() and self.gmsKeepSelection == true then applyPersistentSelection(self) end
            return result
        end
    end

    local oldRender = paneClass.render
    if type(oldRender) == "function" then
        paneClass.render = function(self, ...)
            if GMS.isEnabled() and self.gmsKeepSelection == true then applyPersistentSelection(self) end
            return oldRender(self, ...)
        end
    end
end

local function wrapPageClass(pageClass)
    if type(pageClass) ~= "table" or GMS.hookedPages[pageClass] then return end
    GMS.hookedPages[pageClass] = true

    local oldJoypad = pageClass.onJoypadDown
    if type(oldJoypad) == "function" then
        pageClass.onJoypadDown = function(self, button, ...)
            if GMS.isEnabled() then
                local playerNum = tonumber(self.player) or 0
                local pane = GMS.resolveFocusedPane(self)
                if pane then
                    -- If a multi-selection is active and A is pressed on a row
                    -- outside that selection, clear the stale selection BEFORE
                    -- vanilla/CleanUI handles A. Otherwise the old selection
                    -- can leak into context-menu handling, opening the menu for
                    -- previously selected rows instead of the focused row (or
                    -- interfering with expanding/collapsing equipped groups).
                    local joypad = rawget(_G, "Joypad")
                    local aButton = joypad and (joypad.AButton or joypad.A) or nil
                    local savedSelection = pane.gmsSelectionState
                    if aButton ~= nil and button == aButton
                        and pane.gmsKeepSelection == true
                        and hasAnyEntries(savedSelection) then
                        local focusedIndex = focusedRowIndex(pane)
                        local focusedRow = focusedIndex and pane.items[focusedIndex] or nil
                        if not focusedRow or not rowIsSelected(savedSelection, focusedRow) then
                            clearPane(pane)
                            log("cleared multi-selection before A on an unselected/non-item focus (player=" .. tostring(playerNum) .. ")")
                        end
                    end

                    local multiName = GMS.getMultiSelectButton()
                    local allName = GMS.getSelectAllButton()
                    local rangeName = GMS.getRangeSelectButton()

                    -- L3+R3 is a chord. Detect it from live controller state and
                    -- defer ordinary L3/R3 actions briefly, so the chord only
                    -- performs select-all once instead of also firing range/single.
                    if allName == SELECT_ALL_COMBO then
                        if handleComboButtonPress(playerNum, button, pane, multiName, rangeName) then
                            return
                        end
                    end

                    -- Discrete gamepad buttons are handled directly here.
                    -- Defaults: R3 toggles one row, L3 selects a range,
                    -- L3+R3 toggles select-all; Select/Back remains selectable.
                    if allName ~= "None" and allName ~= SELECT_ALL_COMBO and allName ~= multiName and allName ~= rangeName then
                        local allCode = GMS.resolveButtonCode(allName)
                        if allCode ~= nil and button == allCode then
                            if selectAll(pane) then return end
                        end
                    end

                    if rangeName ~= "None" and rangeName ~= multiName and rangeName ~= allName
                        and rangeName ~= "R2" and rangeName ~= "L2" then
                        local rangeCode = GMS.resolveButtonCode(rangeName)
                        if rangeCode ~= nil and button == rangeCode then
                            local index = focusedRowIndex(pane)
                            if index and selectRange(pane, index) then return end
                        end
                    end

                    if multiName ~= "None" and multiName ~= allName and multiName ~= rangeName
                        and multiName ~= "R2" and multiName ~= "L2" then
                        local multiCode = GMS.resolveButtonCode(multiName)
                        if multiCode ~= nil and button == multiCode then
                            if performMultiSelect(pane) then return end
                        end
                    end
                elseif GMS.getSelectAllButton() == SELECT_ALL_COMBO then
                    -- The chord cannot run without a focused pane. Log only for the
                    -- two stick buttons so an "L3+R3 does nothing" report can be
                    -- traced to focus resolution instead of the toggle itself.
                    local l3 = GMS.resolveButtonCode("L3")
                    local r3 = GMS.resolveButtonCode("R3")
                    if button == l3 or button == r3 then
                        local focus = getJoypadFocus and getJoypadFocus(playerNum) or nil
                        log(string.format(
                            "onJoypadDown: stick button pressed but no focused inventory pane (page=%s focus=%s pageVisible=%s paneExists=%s)",
                            tostring(self), tostring(focus), tostring(pageIsVisible(self)),
                            tostring(self.inventoryPane ~= nil)))
                    end
                end
            end
            return oldJoypad(self, button, ...)
        end
    end

    local oldSelect = pageClass.selectContainer
    if type(oldSelect) == "function" then
        pageClass.selectContainer = function(self, button, ...)
            local oldInventory = self.inventoryPane and self.inventoryPane.inventory or nil
            local result = oldSelect(self, button, ...)
            local newInventory = self.inventoryPane and self.inventoryPane.inventory or nil
            if oldInventory ~= newInventory then clearPane(self.inventoryPane) end
            return result
        end
    end

    local oldRefresh = pageClass.refreshBackpacks
    if type(oldRefresh) == "function" then
        pageClass.refreshBackpacks = function(self, ...)
            local before = snapshotContainers(self)
            local result = oldRefresh(self, ...)
            local after = snapshotContainers(self)
            if not sameSnapshot(before, after) then clearPane(self.inventoryPane) end
            return result
        end
    end
end

function GMS.bindLiveClasses()
    wrapPageClass(rawget(_G, "ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Clean_ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPage"))
    wrapPaneClass(rawget(_G, "ISInventoryPane"))
    wrapPaneClass(rawget(_G, "CleanUI_Clean_ISInventoryPane"))
    wrapPaneClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPane"))
end

local function registerCleanUICallback()
    if GMS.cleanUICallbackRegistered then return true end
    local register = rawget(_G, "CleanUI_RegisterInventoryUiToggleCallback")
    if type(register) ~= "function" then return false end
    GMS.cleanUICallbackRegistered = true
    register(function()
        GMS.clearAllPlayers()
        GMS.bindLiveClasses()
    end)
    return true
end

local function localizedButtonLabel(name)
    local labels = {
        ["R2"] = "UI_GQOS_Button_R2",
        ["L2"] = "UI_GQOS_Button_L2",
        ["R3"] = "UI_GQOS_Button_R3",
        ["L3"] = "UI_GQOS_Button_L3",
        ["Select"] = "UI_GQOS_Button_Select",
        ["Start"] = "UI_GQOS_Button_Start",
        ["None"] = "UI_GQOS_Button_None",
        [SELECT_ALL_COMBO] = "UI_GQOS_Button_L3R3",
    }
    return labels[name] or name
end

local function migrateLegacyOptions(newOptions)
    -- Preserve existing choices in this priority order: current GamepadQoLSuite,
    -- previous combined CustomGamepadUI settings, then the old standalone multi-select group.
    if GMS.legacyOptionsMigrationChecked then return end
    GMS.legacyOptionsMigrationChecked = true
    if type(getFileReader) ~= "function" then return end

    local okReader, reader = pcall(getFileReader, "ModOptions.ini", true)
    if not okReader or not reader then return end
    local legacy, previous, current = {}, {}, {}
    local okRead = pcall(function()
        while true do
            local line = reader:readLine()
            if line == nil then break end
            local typ, groupId, optionId, value = line:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
            local entry = { type = typ, value = value }
            if groupId == LEGACY_OPTIONS_ID then
                legacy[optionId] = entry
            elseif groupId == PREVIOUS_OPTIONS_ID then
                previous[optionId] = entry
            elseif groupId == OPTIONS_ID then
                current[optionId] = true
            end
        end
    end)
    pcall(function() reader:close() end)
    if not okRead then return end

    local migrationMap = {
        Enabled = { option = GMS.options.enabled, type = "tickbox" },
        SelectionButton = { option = GMS.options.button, type = "combobox" },
        SelectAllInput = { option = GMS.options.selectAllButton, type = "combobox" },
        RangeSelectButton = { option = GMS.options.rangeSelectButton, type = "combobox" },
    }
    local migrated = {}
    for optionId, entry in pairs(migrationMap) do
        local old = previous[optionId] or legacy[optionId]
        if old and not current[optionId] and entry.option and type(entry.option.setValue) == "function" then
            if entry.type == "tickbox" and old.type == "tickbox" then
                local value = old.value == "true" or old.value == "1"
                pcall(entry.option.setValue, entry.option, value)
                migrated[#migrated + 1] = optionId
            elseif entry.type == "combobox" and old.type == "combobox" and tonumber(old.value) then
                pcall(entry.option.setValue, entry.option, tonumber(old.value))
                migrated[#migrated + 1] = optionId
            end
        end
    end
    if #migrated > 0 then
        log("Migrated previous multi-select settings into Gamepad QoL Suite: " .. table.concat(migrated, ", "))
    end
end

-- Add multi-select settings to the already-created suite options group.
-- GQSModOptions.lua calls this at the desired position under "Container Operations",
-- preventing these controls from appearing at the top of the options page.
function GMS.addOptionsTo(options)
    if GMS.optionsRegistered then return true end
    if not options or type(options.addTitle) ~= "function" then return false end

    options:addTitle("UI_GQOS_MultiSelectTitle")
    GMS.options.enabled = options:addTickBox(
        "Enabled",
        "UI_GQOS_MS_Enabled",
        true,
        "UI_GQOS_MS_Enabled_tooltip"
    )
    GMS.options.button = options:addComboBox(
        "SelectionButton",
        "UI_GQOS_MS_Button",
        "UI_GQOS_MS_Button_tooltip"
    )
    for _, name in ipairs(MULTI_SELECT_BUTTONS) do
        GMS.options.button:addItem(localizedButtonLabel(name), name == "R3")
    end

    GMS.options.selectAllButton = options:addComboBox(
        "SelectAllInput",
        "UI_GQOS_MS_SelectAll",
        "UI_GQOS_MS_SelectAll_tooltip"
    )
    for _, name in ipairs(SELECT_ALL_BUTTONS) do
        GMS.options.selectAllButton:addItem(localizedButtonLabel(name), name == SELECT_ALL_COMBO)
    end

    GMS.options.rangeSelectButton = options:addComboBox(
        "RangeSelectButton",
        "UI_GQOS_MS_RangeSelect",
        "UI_GQOS_MS_RangeSelect_tooltip"
    )
    for _, name in ipairs(RANGE_SELECT_BUTTONS) do
        GMS.options.rangeSelectButton:addItem(localizedButtonLabel(name), name == "L3")
    end

    migrateLegacyOptions(options)

    local enabledOption = GMS.options.enabled
    local function onEnabledChanged(option)
        if optionValue(option or enabledOption, true) ~= true then GMS.clearAllPlayers() end
    end
    enabledOption.apply = onEnabledChanged
    enabledOption.onChange = onEnabledChanged
    enabledOption.onValueChange = onEnabledChanged

    GMS.optionsRegistered = true
    log("multi-select options registered inside Container Operations")
    return true
end

local function monitorWindows()
    GMS.bindLiveClasses()
    registerCleanUICallback()

    for playerNum = 0, 3 do
        local state = playerState(playerNum)
        local inventoryPage = getPage(playerNum, false)
        local lootPage = getPage(playerNum, true)
        local inventoryVisible = pageIsVisible(inventoryPage)
        local lootVisible = pageIsVisible(lootPage)

        if state.inventoryPage and state.inventoryPage ~= inventoryPage then
            clearPane(state.inventoryPage.inventoryPane)
        end
        if state.lootPage and state.lootPage ~= lootPage then
            clearPane(state.lootPage.inventoryPane)
        end
        if state.inventoryVisible and not inventoryVisible and not (isGamePaused and isGamePaused()) then
            clearPane(inventoryPage and inventoryPage.inventoryPane)
        end
        if state.lootVisible and not lootVisible and not (isGamePaused and isGamePaused()) then
            clearPane(lootPage and lootPage.inventoryPane)
        end

        state.inventoryVisible = inventoryVisible
        state.lootVisible = lootVisible
        state.inventoryPage = inventoryPage
        state.lootPage = lootPage

        processComboSelectAll(playerNum)
        pollTriggerAction(playerNum, "multi", GMS.getMultiSelectButton(), function(pane) return performMultiSelect(pane) end)
        pollTriggerAction(playerNum, "all", GMS.getSelectAllButton(), function(pane) return selectAll(pane) end)
        pollTriggerAction(playerNum, "range", GMS.getRangeSelectButton(), function(pane) return selectRange(pane, focusedRowIndex(pane)) end)
    end
end

if Events.OnGameBoot then
    Events.OnGameBoot.Add(function()
        GMS.bindLiveClasses()
        registerCleanUICallback()
        log("loaded v" .. GMS.VERSION)
    end)
end
if Events.OnGameStart then
    Events.OnGameStart.Add(function()
        GMS.players = {}
        GMS.bindLiveClasses()
        registerCleanUICallback()
    end)
end
if Events.OnResetLua then
    Events.OnResetLua.Add(function()
        GMS.players = {}
        GMS.bindLiveClasses()
        registerCleanUICallback()
    end)
end
if Events.OnTick then Events.OnTick.Add(monitorWindows) end

log("loaded v" .. GMS.VERSION .. " (Gamepad QoL Suite multi-select)")
