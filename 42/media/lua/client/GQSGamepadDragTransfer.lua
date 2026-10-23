-- CustomGamepadUI: drag an existing multi-selection with a gamepad stick.
-- The actual ISMouseDrag state is only armed at drop time. The vanilla/CleanUI
-- inventory pane otherwise sees that no physical mouse button is held and
-- clears its drag state on the next update.

require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryPane"
require "ISUI/ISMouseDrag"
require "ISUI/ISUIElement"

local CGUI = require "GQSModOptions"
local GMS = rawget(_G, "GamepadMultiSelectStandalone")

local MODE_DISABLED = 1
local MODE_B = 2
local STICK_DEADZONE = 0.18
local MAX_PIXELS_PER_TICK = 16
local DEFAULT_B_HOLD_MS = 300

local activeDrags = {}
local pendingBPresses = {}
local hookedClasses = setmetatable({}, { __mode = "k" })
local tickCount = 0
local cursorApiLogged = false
local nativeMouseClassChecked = false
local nativeMouseClass = nil
local cursorOverlay = nil
local cursorVisibilityKnown = false
local lastCursorVisible = true

local function debugPrint(...)
    local logger = rawget(_G, "GQSLog")
    if not logger or type(logger.log) ~= "function" then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.log("dragTransfer", table.concat(parts, " "))
end

local function safeCall(object, methodName)
    if not object or type(object[methodName]) ~= "function" then return false, nil end
    local ok, result = pcall(function() return object[methodName](object) end)
    return ok, result
end

local function optionValue(option, defaultValue)
    if not option or type(option.getValue) ~= "function" then return defaultValue end
    local ok, value = pcall(option.getValue, option)
    if not ok then return defaultValue end
    return value
end

local function getMode()
    -- New checkbox is the primary control. It defaults OFF as requested.
    -- Keep the legacy combobox fallback for users running this module with an older GQSModOptions.
    if CGUI and CGUI.multiSelectDragEnabled then
        return optionValue(CGUI.multiSelectDragEnabled, false) == true and MODE_B or MODE_DISABLED
    end
    local value = tonumber(optionValue(CGUI and CGUI.multiSelectDragMode, MODE_DISABLED))
    if value and value >= 2 then
        if value == 3 and CGUI and CGUI.multiSelectDragMode
            and type(CGUI.multiSelectDragMode.setValue) == "function" then
            pcall(CGUI.multiSelectDragMode.setValue, CGUI.multiSelectDragMode, MODE_B)
        end
        return MODE_B
    end
    return MODE_DISABLED
end

local function getHoldDelay()
    local value = tonumber(optionValue(CGUI and CGUI.multiSelectDragHoldDelay, DEFAULT_B_HOLD_MS))
    if not value then value = DEFAULT_B_HOLD_MS end
    if value < 150 then value = 150 end
    if value > 1000 then value = 1000 end
    return value
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return tickCount * 16
end

local function getControllerId(playerIndex)
    if type(getJoypadData) ~= "function" then return -1 end
    local data = getJoypadData(playerIndex)
    local id = data and tonumber(data.id) or -1
    if id < 0 then
        local player = getSpecificPlayer and getSpecificPlayer(playerIndex) or nil
        if player and type(player.getJoypadBind) == "function" then
            local ok, bind = pcall(player.getJoypadBind, player)
            if ok then id = tonumber(bind) or -1 end
        end
    end
    return id
end

local function getAxis(axisName, controllerId)
    local axisGroup = rawget(_G, "JoypadAxis1d")
    local axis = axisGroup and axisGroup[axisName] or nil
    if not axis or type(axis.getValue) ~= "function" then return 0 end
    local ok, value = pcall(axis.getValue, axis, controllerId)
    if not ok or type(value) ~= "number" then return 0 end
    return value
end

local function deadzoneAxis(value)
    if math.abs(value) < STICK_DEADZONE then return 0 end
    return (value > 0 and 1 or -1) * ((math.abs(value) - STICK_DEADZONE) / (1 - STICK_DEADZONE))
end

local function getStick(controllerId)
    -- Both available drag modes intentionally use the LEFT stick.
    local x = deadzoneAxis(getAxis("LeftStickX", controllerId))
    local y = deadzoneAxis(getAxis("LeftStickY", controllerId))
    return x, y
end

local function isButtonDown(buttonName, controllerId)
    local buttonGroup = rawget(_G, "JoypadButton")
    local button = buttonGroup and buttonGroup[buttonName] or nil
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(button.isDown, button, controllerId)
        if ok then return down == true end
    end
    if buttonName == "B" and type(isJoypadPressed) == "function" and Joypad and Joypad.BButton ~= nil then
        local ok, down = pcall(isJoypadPressed, controllerId, Joypad.BButton)
        if ok then return down == true end
    end
    return false
end

local function modifierDown(mode, controllerId)
    return mode == MODE_B and isButtonDown("B", controllerId)
end

local function isVisible(element)
    if not element then return false end
    if type(element.getIsVisible) == "function" then
        local ok, visible = pcall(element.getIsVisible, element)
        if ok then return visible == true end
    end
    if type(element.isVisible) == "function" then
        local ok, visible = pcall(element.isVisible, element)
        if ok then return visible == true end
    end
    return element.visible ~= false
end

local function pageIsVisible(page)
    return isVisible(page)
end

local function getSelectedRows(pane)
    local rows = {}
    local firstIndex = nil
    if not pane or pane.gmsKeepSelection ~= true or type(pane.items) ~= "table" or type(pane.selected) ~= "table" then
        return rows, nil
    end
    for index, row in ipairs(pane.items) do
        if pane.selected[index] ~= nil and row ~= nil then
            rows[#rows + 1] = row
            if not firstIndex then firstIndex = index end
        end
    end
    if #rows == 0 then return rows, nil end
    local focusIndex = (tonumber(pane.joyselection) or -1) + 1
    if focusIndex >= 1 and pane.selected[focusIndex] ~= nil then firstIndex = focusIndex end
    return rows, firstIndex
end

local function getFocusedSource(playerIndex)
    if not GMS or type(GMS.resolveFocusedPane) ~= "function" then return nil, nil end
    local invPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
    if pageIsVisible(invPage) then
        local pane = GMS.resolveFocusedPane(invPage)
        if pane then return pane, invPage end
    end
    if pageIsVisible(lootPage) then
        local pane = GMS.resolveFocusedPane(lootPage)
        if pane then return pane, lootPage end
    end
    return nil, nil
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function getScreenSize()
    local core = getCore and getCore() or nil
    local width, height = 1920, 1080
    if core then
        local okW, w = safeCall(core, "getScreenWidth")
        local okH, h = safeCall(core, "getScreenHeight")
        if okW and tonumber(w) then width = tonumber(w) end
        if okH and tonumber(h) then height = tonumber(h) end
    end
    return width, height
end

local function getNativeMouseClass()
    if nativeMouseClassChecked then return nativeMouseClass end
    nativeMouseClassChecked = true

    -- This B42 Kahlua runtime may resolve org.lwjglx.input.Mouse to nil.
    -- Avoid qualified namespace access here: indexing a missing Java package
    -- can emit an engine-level Lua error even when surrounded by pcall.
    -- Use only the documented binder; if unavailable, stay in virtual mode.
    local java = rawget(_G, "luajava")
    if java and type(java.bindClass) == "function" then
        local okBind, bound = pcall(java.bindClass, "org.lwjglx.input.Mouse")
        if okBind and bound then nativeMouseClass = bound end
    end
    return nativeMouseClass
end

local function getInputMouseClass()
    -- `rawget(_G, "Mouse")` misses class globals resolved by Kahlua's
    -- class loader, so use regular qualified lookup under pcall.
    local ok, cls = pcall(function() return zombie.input.Mouse end)
    if ok and cls then return cls end
    local ok2, cls2 = pcall(function() return Mouse end)
    if ok2 and cls2 then return cls2 end
    local cls3 = rawget(_G, "Mouse")
    if cls3 then return cls3 end
    return nil
end

local DragTransferVirtualCursor = ISUIElement:derive("DragTransferVirtualCursor")

function DragTransferVirtualCursor:new()
    local width, height = getScreenSize()
    local o = ISUIElement.new(self, 0, 0, width, height)
    setmetatable(o, self)
    self.__index = self
    o:initialise()
    o:addToUIManager()
    o:bringToTop()
    return o
end

function DragTransferVirtualCursor:isPointOver(x, y)
    -- The overlay is visual only and must never intercept normal UI actions.
    return false
end

function DragTransferVirtualCursor:onMouseDown(x, y)
    return false
end

function DragTransferVirtualCursor:onMouseUp(x, y)
    return false
end

function DragTransferVirtualCursor:onMouseMove(dx, dy)
    return false
end

function DragTransferVirtualCursor:render()
    local width, height = getScreenSize()
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end

    for _, state in pairs(activeDrags) do
        if state and state.virtualCursor then
            local x = tonumber(state.cursorX) or 0
            local y = tonumber(state.cursorY) or 0
            -- High-contrast virtual pointer, used only when B42 prevents an
            -- actual OS cursor warp. It is intentionally an overlay, not a
            -- fake native mouse event.
            self:drawRect(x - 2, y - 2, 5, 5, 1.0, 1.0, 0.72, 0.12)
            self:drawRect(x, y + 3, 2, 17, 1.0, 1.0, 0.72, 0.12)
            self:drawRect(x + 3, y, 17, 2, 1.0, 1.0, 0.72, 0.12)
            self:drawRect(x + 17, y + 15, 228, 38, 0.90, 0.03, 0.03, 0.03)
            local items = state.actualItems or {}
            local drawnIcon = false
            for i = 1, math.min(2, #items) do
                local item = items[i]
                if item and type(item.getTex) == "function" then
                    local okTex, tex = pcall(item.getTex, item)
                    if okTex and tex then
                        local okDraw = pcall(self.drawTextureScaled, self, tex, x + 22 + (i - 1) * 22, y + 23, 18, 18, 1, 1, 1, 1)
                        if okDraw then drawnIcon = true end
                    end
                end
            end
            local itemCount = tonumber(state.actualItemCount) or #state.rows
            local itemName = nil
            if items[1] and type(items[1].getName) == "function" then
                local okName, name = pcall(items[1].getName, items[1])
                if okName and type(name) == "string" then itemName = name end
            end
            if itemName and #itemName > 20 then itemName = string.sub(itemName, 1, 17) .. "..." end
            local label = (itemName or "Selected items") .. (itemCount > 1 and (" +" .. tostring(itemCount - 1)) or "")
            local textX = x + (drawnIcon and 70 or 23)
            if UIFont and UIFont.Small then
                self:drawText(label, textX, y + 27, 1, 1, 1, 1, UIFont.Small)
            else
                self:drawText(label, textX, y + 27, 1, 1, 1, 1)
            end
        end
    end
end

local function ensureCursorOverlay()
    if cursorOverlay then
        if type(cursorOverlay.setVisible) == "function" then pcall(cursorOverlay.setVisible, cursorOverlay, true) end
        if type(cursorOverlay.bringToTop) == "function" then pcall(cursorOverlay.bringToTop, cursorOverlay) end
        return cursorOverlay
    end
    local ok, overlay = pcall(function() return DragTransferVirtualCursor:new() end)
    if ok then cursorOverlay = overlay end
    if not ok then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Could not create virtual cursor: " .. tostring(overlay)) end
    end
    return cursorOverlay
end

-- Remove the full-screen virtual-cursor overlay when no virtual drag is active.
-- Leaving this element attached and brought to the top after a drag can interfere
-- with normal mouse-hover/tooltip updates even when the drag option is disabled.
local function hasActiveVirtualCursor()
    for _, state in pairs(activeDrags) do
        if state and state.virtualCursor then return true end
    end
    return false
end

local function removeCursorOverlay()
    local overlay = cursorOverlay
    if not overlay then return end

    if type(overlay.setVisible) == "function" then
        pcall(overlay.setVisible, overlay, false)
    end

    local removed = false
    if type(overlay.removeFromUIManager) == "function" then
        local ok = pcall(overlay.removeFromUIManager, overlay)
        removed = ok
    end
    if not removed then
        local manager = rawget(_G, "UIManager")
        if manager and type(manager.RemoveElement) == "function" then
            pcall(manager.RemoveElement, overlay)
        end
    end

    cursorOverlay = nil
end

local function cleanupIdleCursorOverlay()
    if not hasActiveVirtualCursor() then
        removeCursorOverlay()
    end
end

local function getMousePosition()
    local inputMouse = getInputMouseClass()
    if inputMouse and type(inputMouse.getX) == "function" and type(inputMouse.getY) == "function" then
        local ok, x, y = pcall(function() return inputMouse.getX(), inputMouse.getY() end)
        if ok and tonumber(x) and tonumber(y) then return tonumber(x), tonumber(y) end
    end
    if type(getMouseX) == "function" and type(getMouseY) == "function" then
        local ok, x, y = pcall(function() return getMouseX(), getMouseY() end)
        if ok and tonumber(x) and tonumber(y) then return tonumber(x), tonumber(y) end
    end
    return 0, 0
end

local function setMousePosition(x, y)
    local width, height = getScreenSize()
    x = math.floor(clamp(x, 0, math.max(0, width - 1)))
    y = math.floor(clamp(y, 0, math.max(0, height - 1)))
    local nativeY = math.floor(clamp(height - y, 0, math.max(0, height - 1)))

    local native = getNativeMouseClass()
    local nativeOK = false
    local nativeError = nil
    if native and type(native.setCursorPosition) == "function" then
        local ok, err = pcall(native.setCursorPosition, x, nativeY)
        nativeOK = ok
        if not ok then nativeError = tostring(err) end
    end

    -- Do not dereference org.lwjglx.input.Mouse directly here. In this game's
    -- Kahlua runtime the namespace can be nil, and the failed field access logs
    -- an engine-level error despite being inside pcall. Virtual cursor fallback
    -- is safer when the binder is unavailable.

    -- setMouseXY is the UI/logical position setter, not proof that the actual
    -- native cursor warped. Only report success if native setCursorPosition ran.
    if nativeOK then
        if type(setMouseXY) == "function" then pcall(setMouseXY, x, y) end
        local inputMouse = getInputMouseClass()
        if inputMouse and type(inputMouse.setXY) == "function" then
            pcall(inputMouse.setXY, x, y)
        end
        return true
    end

    if not cursorApiLogged then
        debugPrint("[CustomGamepadUI DragTransfer] Native cursor warp unavailable; using virtual cursor; reason=" .. tostring(nativeError))
        cursorApiLogged = true
    end
    return false
end

local function getNativeMousePosition()
    local native = getNativeMouseClass()
    if native and type(native.getX) == "function" and type(native.getY) == "function" then
        local ok, nx, ny = pcall(function() return native.getX(), native.getY() end)
        if ok and tonumber(nx) and tonumber(ny) then
            local _, height = getScreenSize()
            return tonumber(nx), tonumber(ny), height - tonumber(ny)
        end
    end
    return nil, nil, nil
end

local function setCursorVisible(visible)
    local inputMouse = getInputMouseClass()
    if inputMouse and type(inputMouse.setCursorVisible) == "function" then
        pcall(inputMouse.setCursorVisible, visible == true)
        return
    end
    pcall(function() return Mouse.setCursorVisible(visible == true) end)
end

local function cursorWasVisible()
    local inputMouse = getInputMouseClass()
    if inputMouse and type(inputMouse.isCursorVisible) == "function" then
        local ok, visible = pcall(inputMouse.isCursorVisible)
        if ok and type(visible) == "boolean" then return visible end
    end
    local ok, visible = pcall(function() return Mouse.isCursorVisible() end)
    if ok and type(visible) == "boolean" then return visible end
    -- Assume visible if the runtime does not expose its state, so cleanup
    -- will always attempt to restore the normal cursor.
    return true
end

local function clearNativeDragState(state)
    if not ISMouseDrag then return end
    if not state or ISMouseDrag.draggingFocus == state.pane then
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
    end
    if state and state.pane then
        state.pane.dragging = nil
        state.pane.dragStarted = false
        if state.pane.draggedItems and type(state.pane.draggedItems.reset) == "function" then
            pcall(state.pane.draggedItems.reset, state.pane.draggedItems)
        end
    end
end

local function restoreMovement(state)
    if not state or not state.player or state.movementWasIgnored == nil then return end
    if type(state.player.setIgnoreMovement) == "function" then
        pcall(state.player.setIgnoreMovement, state.player, state.movementWasIgnored)
    end
    state.movementWasIgnored = nil
end

local function cancelDrag(playerIndex)
    local state = activeDrags[playerIndex]
    if not state then return end
    clearNativeDragState(state)
    restoreMovement(state)
    if state.cursorWasVisible ~= nil then setCursorVisible(state.cursorWasVisible) end
    activeDrags[playerIndex] = nil
    cleanupIdleCursorOverlay()
end

local function beginDrag(playerIndex, controllerId, mode, pane, page, selectedRows, rowIndex)
    if not pane or not page or type(selectedRows) ~= "table" or #selectedRows == 0 then return false end
    if activeDrags[playerIndex] then return false end
    if ISMouseDrag and ISMouseDrag.dragging ~= nil then return false end

    local rowCount = #(pane.items or {})
    rowIndex = math.floor(tonumber(rowIndex) or 1)
    rowIndex = clamp(rowIndex, 1, math.max(1, rowCount))
    if type(pane.ensureVisible) == "function" then pcall(pane.ensureVisible, pane, rowIndex) end
    if type(page.ensureVisible) == "function" then pcall(page.ensureVisible, page, rowIndex) end

    local width = tonumber(pane.width) or 300
    local localX = clamp((tonumber(pane.column2) or 55) + 10, 8, math.max(8, width - 8))
    local scrollY = 0
    if type(pane.getYScroll) == "function" then
        local ok, value = pcall(pane.getYScroll, pane)
        if ok and tonumber(value) then scrollY = tonumber(value) end
    end
    local localY = (tonumber(pane.headerHgt) or 17)
        + ((rowIndex - 1) * (tonumber(pane.itemHgt) or 20))
        + scrollY + ((tonumber(pane.itemHgt) or 20) / 2)
    local paneX = tonumber(pane:getAbsoluteX()) or 0
    local paneY = tonumber(pane:getAbsoluteY()) or 0
    local absX = paneX + localX
    local absY = paneY + localY

    local actualItems = {}
    if ISInventoryPane and type(ISInventoryPane.getActualItems) == "function" then
        local okItems, resolved = pcall(ISInventoryPane.getActualItems, selectedRows)
        if okItems and type(resolved) == "table" then actualItems = resolved end
    end
    if #actualItems == 0 then
        for _, row in ipairs(selectedRows) do
            if instanceof and instanceof(row, "InventoryItem") then
                actualItems[#actualItems + 1] = row
            elseif type(row) == "table" and type(row.items) == "table" then
                for _, item in ipairs(row.items) do
                    if instanceof and instanceof(item, "InventoryItem") then actualItems[#actualItems + 1] = item end
                end
            end
        end
    end

    local oldCursorVisible = cursorWasVisible()
    local nativeWarpOK = setMousePosition(absX, absY)
    local virtualCursor = not nativeWarpOK
    if virtualCursor then
        ensureCursorOverlay()
        setCursorVisible(false)
    else
        setCursorVisible(true)
    end

    local player = getSpecificPlayer and getSpecificPlayer(playerIndex) or nil
    local movementWasIgnored = nil
    if player and type(player.getIgnoreMovement) == "function" then
        local ok, oldValue = pcall(player.getIgnoreMovement, player)
        if ok then movementWasIgnored = oldValue == true end
    end
    if player and type(player.setIgnoreMovement) == "function" then
        pcall(player.setIgnoreMovement, player, true)
    end
    if player and type(player.nullifyAiming) == "function" then pcall(player.nullifyAiming, player) end

    -- Wait a couple of ticks before accepting release. With native cursor
    -- support the OS pointer has been warped; otherwise a virtual cursor
    -- overlay follows the row and is used for drop hit-testing.
    activeDrags[playerIndex] = {
        mode = MODE_B,
        controllerId = controllerId,
        pane = pane,
        page = page,
        rows = selectedRows,
        rowIndex = rowIndex,
        localX = localX,
        localY = localY,
        anchorX = absX,
        anchorY = absY,
        cursorX = absX,
        cursorY = absY,
        virtualCursor = virtualCursor,
        lastPhysicalX = select(1, getMousePosition()),
        lastPhysicalY = select(2, getMousePosition()),
        usingPhysicalMouse = false,
        actualItems = actualItems,
        actualItemCount = (#actualItems > 0 and #actualItems or #selectedRows),
        paneX = paneX,
        paneY = paneY,
        cursorSnapTicks = 2,
        waitingForRender = false,
        nativeArmed = false,
        cursorWasVisible = oldCursorVisible,
        player = player,
        movementWasIgnored = movementWasIgnored,
        startedAt = nowMs(),
    }

    -- Repeat the native warp after state creation when it is supported.
    -- In virtual mode, cursorX/Y remain independent of the OS mouse position.
    local warpOK = nativeWarpOK
    if nativeWarpOK then setMousePosition(absX, absY) end
    local actualX, actualY = getMousePosition()
    local nativeX, nativeY, nativeUIY = getNativeMousePosition()
    debugPrint(string.format("[CustomGamepadUI DragTransfer] Started B-drag: rows=%d pane=%s anchor=(%d,%d) gameCursor=(%d,%d) nativeCursor=(%s,%s uiY=%s) nativeWarp=%s virtualCursor=%s movementLocked=%s",
        #selectedRows, page.onCharacter and "inventory" or "loot", math.floor(absX), math.floor(absY),
        math.floor(actualX), math.floor(actualY), tostring(nativeX), tostring(nativeY), tostring(nativeUIY),
        tostring(warpOK), tostring(virtualCursor), tostring(player and type(player.setIgnoreMovement) == "function")))
    return true
end

local function selectedDragSource(page)
    if not GMS or type(GMS.resolveFocusedPane) ~= "function" then return nil, nil, nil end
    local pane = GMS.resolveFocusedPane(page)
    if not pane then return nil, nil, nil end
    local rows, firstIndex = getSelectedRows(pane)
    if #rows == 0 then return nil, nil, nil end
    return pane, rows, firstIndex
end

local function selectedDragAvailable(page)
    local pane = selectedDragSource(page)
    return pane ~= nil
end

local function findButtonAtCursor(playerIndex, x, y, sourceInventory)
    local pages = {}
    local invPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
    if invPage then pages[#pages + 1] = invPage end
    if lootPage then pages[#pages + 1] = lootPage end
    for _, page in ipairs(pages) do
        if page and pageIsVisible(page) and not page.isCollapsed then
            for _, button in ipairs(page.backpacks or {}) do
                if button and button.inventory and button.inventory ~= sourceInventory and isVisible(button)
                    and type(button.getAbsoluteX) == "function" and type(button.getAbsoluteY) == "function"
                    and type(button.getWidth) == "function" and type(button.getHeight) == "function" then
                    local bx, by = button:getAbsoluteX(), button:getAbsoluteY()
                    local bw, bh = button:getWidth(), button:getHeight()
                    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then return page, button end
                end
            end
        end
    end
    return nil, nil
end

local function paneAtCursor(playerIndex, x, y, sourcePane)
    local pages = {}
    local invPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
    if invPage then pages[#pages + 1] = invPage end
    if lootPage then pages[#pages + 1] = lootPage end
    for _, page in ipairs(pages) do
        local pane = page and page.inventoryPane or nil
        if page and pane and pane ~= sourcePane and pageIsVisible(page)
            and type(pane.getAbsoluteX) == "function" and type(pane.getAbsoluteY) == "function"
            and type(pane.getWidth) == "function" and type(pane.getHeight) == "function" then
            local px, py = pane:getAbsoluteX(), pane:getAbsoluteY()
            if x >= px and x <= px + pane:getWidth() and y >= py and y <= py + pane:getHeight() then
                return pane, x - px, y - py
            end
        end
    end
    return nil, nil, nil
end

local function armNativeDrag(state)
    if not ISMouseDrag or not state or not state.pane or type(state.rows) ~= "table" or #state.rows == 0 then return false end
    ISMouseDrag.dragging = state.rows
    ISMouseDrag.draggingFocus = state.pane
    return true
end

local function finishDrag(playerIndex)
    local state = activeDrags[playerIndex]
    if not state then return end
    local sourcePane = state.pane
    if (state.cursorSnapTicks and state.cursorSnapTicks > 0) or not state.nativeArmed or state.waitingForRender then
        debugPrint("[CustomGamepadUI DragTransfer] Released before drag cursor was ready; cancelling safely")
        cancelDrag(playerIndex)
        return
    end
    local mx = tonumber(state.cursorX)
    local my = tonumber(state.cursorY)
    if not mx or not my then mx, my = getMousePosition() end
    -- Apply the final physical cursor position only when native warping is supported.
    -- In virtual-cursor mode, all drop hit-testing uses state.cursorX/Y directly.
    if not state.virtualCursor then setMousePosition(mx, my) end
    local completed = false
    debugPrint(string.format("[CustomGamepadUI DragTransfer] Drop attempt at x=%d y=%d", math.floor(mx), math.floor(my)))

    if not armNativeDrag(state) then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Could not arm native drag state") end
    else
        local buttonPage, button = findButtonAtCursor(playerIndex, mx, my, sourcePane and sourcePane.inventory or nil)
        if buttonPage and button then
            debugPrint("[CustomGamepadUI DragTransfer] Target: container button")
            local invPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
            local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
            if invPage then invPage.mouseOverButton = nil end
            if lootPage then lootPage.mouseOverButton = nil end
            buttonPage.mouseOverButton = button
            local canDrop = false
            if type(buttonPage.canPutIn) == "function" then
                local ok, allowed = pcall(buttonPage.canPutIn, buttonPage)
                canDrop = ok and allowed == true
                if not ok then local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Button canPutIn failed: " .. tostring(allowed)) end end
            end
            debugPrint("[CustomGamepadUI DragTransfer] Button canDrop=" .. tostring(canDrop))
            if canDrop and type(buttonPage.dropItemsInContainer) == "function" then
                local ok, result = pcall(buttonPage.dropItemsInContainer, buttonPage, button)
                completed = ok and result ~= false
                if not ok then local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Container-button drop failed: " .. tostring(result)) end end
            end
        else
            local targetPane, localX, localY = paneAtCursor(playerIndex, mx, my, sourcePane)
            if targetPane then
                debugPrint("[CustomGamepadUI DragTransfer] Target: inventory pane")
                local invPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
                local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
                if invPage then invPage.mouseOverButton = nil end
                if lootPage then lootPage.mouseOverButton = nil end
                targetPane.mouseOverOption = 0
                if type(targetPane.canPutIn) == "function" then
                    local ok, allowed = pcall(targetPane.canPutIn, targetPane)
                    debugPrint("[CustomGamepadUI DragTransfer] Pane canDrop=" .. tostring(ok and allowed == true))
                    if ok and allowed == true and type(targetPane.onMouseUp) == "function" then
                        local dropOK, result = pcall(targetPane.onMouseUp, targetPane, localX, localY)
                        completed = dropOK and result ~= false
                        if not dropOK then local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Pane drop failed: " .. tostring(result)) end end
                    elseif not ok then
                        local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Pane canPutIn failed: " .. tostring(allowed)) end
                    end
                end
            else
                debugPrint(string.format("[CustomGamepadUI DragTransfer] No compatible drop target at cursor=(%d,%d) virtual=%s",
                    math.floor(mx), math.floor(my), tostring(state.virtualCursor)))
            end
        end
    end

    -- Always release any drag state re-armed for the synchronous native drop.
    clearNativeDragState(state)
    restoreMovement(state)
    if state.cursorWasVisible ~= nil then setCursorVisible(state.cursorWasVisible) end
    activeDrags[playerIndex] = nil
    cleanupIdleCursorOverlay()
    if completed and GMS and type(GMS.clearPlayer) == "function" then pcall(GMS.clearPlayer, playerIndex) end
    debugPrint(string.format("[CustomGamepadUI DragTransfer] Finished drag: transferred=%s", tostring(completed)))
end

local function replayShortB(pending)
    if not pending or type(pending.oldJoypadDown) ~= "function" or not pending.page then return end
    debugPrint("[CustomGamepadUI DragTransfer] Short B tap: replaying vanilla B action")
    local unpackArgs = unpack or (table and table.unpack)
    local ok, err = pcall(function()
        if unpackArgs and pending.args then
            return pending.oldJoypadDown(pending.page, pending.button, unpackArgs(pending.args))
        end
        return pending.oldJoypadDown(pending.page, pending.button)
    end)
    if not ok then local logger = rawget(_G, "GQSLog"); if logger then logger.error("dragTransfer", "Replaying short B failed: " .. tostring(err)) end end
end

local function processPendingBPresses()
    local mode = getMode()
    for playerIndex = 0, 3 do
        local pending = pendingBPresses[playerIndex]
        if pending then
            if mode ~= MODE_B then
                pendingBPresses[playerIndex] = nil
                replayShortB(pending)
            elseif isButtonDown("B", pending.controllerId) then
                if not pending.longPress and nowMs() - pending.startedAt >= getHoldDelay() then
                    pending.longPress = true
                    local pane, rows, firstIndex = selectedDragSource(pending.page)
                    if pane and pageIsVisible(pending.page) and not activeDrags[playerIndex] then
                        pending.dragStarted = beginDrag(playerIndex, pending.controllerId, MODE_B, pane, pending.page, rows, firstIndex)
                        if pending.dragStarted then pendingBPresses[playerIndex] = nil end
                    end
                elseif pending.longPress and not pending.dragStarted then
                    local pane, rows, firstIndex = selectedDragSource(pending.page)
                    if pane and pageIsVisible(pending.page) and not activeDrags[playerIndex] then
                        pending.dragStarted = beginDrag(playerIndex, pending.controllerId, MODE_B, pane, pending.page, rows, firstIndex)
                        if pending.dragStarted then pendingBPresses[playerIndex] = nil end
                    end
                end
            else
                pendingBPresses[playerIndex] = nil
                if not pending.longPress and not pending.dragStarted then replayShortB(pending) end
            end
        end
    end
end

local function activateNativeDrag(state)
    if not state or not state.pane or not ISMouseDrag then return false end
    ISMouseDrag.dragging = state.rows
    ISMouseDrag.draggingFocus = state.pane
    state.pane.dragging = state.rowIndex
    state.pane.draggingX = state.localX
    state.pane.draggingY = state.localY
    -- Keep the dragged copy hidden for one extra frame while the cursor snap
    -- settles; then the normal CleanUI drag ghost appears at the selected row.
    state.pane.dragStarted = false
    state.nativeArmed = true
    state.waitingForRender = true
    return true
end

local function updateDragTransfer()
    processPendingBPresses()
    local mode = getMode()
    for playerIndex = 0, 3 do
        local state = activeDrags[playerIndex]
        if state then
            if mode ~= MODE_B or not pageIsVisible(state.page) then
                cancelDrag(playerIndex)
            elseif modifierDown(state.mode, state.controllerId) then
                if state.cursorSnapTicks and state.cursorSnapTicks > 0 then
                    if not state.virtualCursor then setMousePosition(state.anchorX, state.anchorY) end
                    state.cursorSnapTicks = state.cursorSnapTicks - 1
                    if state.cursorSnapTicks == 0 then
                        local cx, cy = getMousePosition()
                        local nx, ny, nuy = getNativeMousePosition()
                        debugPrint(string.format("[CustomGamepadUI DragTransfer] Cursor snap target=(%d,%d) gameActual=(%d,%d) native=(%s,%s uiY=%s) virtual=%s",
                            math.floor(state.anchorX), math.floor(state.anchorY), math.floor(cx), math.floor(cy),
                            tostring(nx), tostring(ny), tostring(nuy), tostring(state.virtualCursor)))
                        if state.virtualCursor then
                            -- A virtual cursor is ready immediately. Native drag state is
                            -- armed only synchronously at release, so CleanUI cannot reset it.
                            state.nativeArmed = true
                            state.waitingForRender = false
                            ensureCursorOverlay()
                        elseif not activateNativeDrag(state) then
                            cancelDrag(playerIndex)
                        end
                    end
                elseif state.waitingForRender then
                    if not state.virtualCursor then setMousePosition(state.anchorX, state.anchorY) end
                    state.pane.dragStarted = true
                    state.waitingForRender = false
                else
                    local stickX, stickY = getStick(state.controllerId)
                    if not state.loggedAxisSample then
                        local rawX = getAxis("LeftStickX", state.controllerId)
                        local rawY = getAxis("LeftStickY", state.controllerId)
                        debugPrint(string.format("[CustomGamepadUI DragTransfer] Left-stick sample: controller=%d raw=(%.3f,%.3f) filtered=(%.3f,%.3f)",
                            tonumber(state.controllerId) or -1, rawX, rawY, stickX, stickY))
                        state.loggedAxisSample = true
                    end
                    local physicalX, physicalY = getMousePosition()
                    local physicalDx = math.abs(physicalX - (tonumber(state.lastPhysicalX) or physicalX))
                    local physicalDy = math.abs(physicalY - (tonumber(state.lastPhysicalY) or physicalY))
                    local physicalMoved = physicalDx > 3 or physicalDy > 3

                    if physicalMoved then
                        -- Keep manual mouse testing/use available. Whichever input moved last
                        -- owns the drag cursor until the other input is used again.
                        state.cursorX = clamp(physicalX, 0, math.max(0, select(1, getScreenSize()) - 1))
                        state.cursorY = clamp(physicalY, 0, math.max(0, select(2, getScreenSize()) - 1))
                        state.usingPhysicalMouse = true
                    elseif stickX ~= 0 or stickY ~= 0 then
                        state.usingPhysicalMouse = false
                        local x = tonumber(state.cursorX) or state.anchorX
                        local y = tonumber(state.cursorY) or state.anchorY
                        local nextX = clamp(x + stickX * MAX_PIXELS_PER_TICK, 0, math.max(0, select(1, getScreenSize()) - 1))
                        local nextY = clamp(y + stickY * MAX_PIXELS_PER_TICK, 0, math.max(0, select(2, getScreenSize()) - 1))
                        state.cursorX = nextX
                        state.cursorY = nextY
                        if not state.virtualCursor then setMousePosition(nextX, nextY) end
                    end
                    state.lastPhysicalX = physicalX
                    state.lastPhysicalY = physicalY

                    if not state.loggedStickMove and (stickX ~= 0 or stickY ~= 0) then
                        local nx, ny, nuy = getNativeMousePosition()
                        debugPrint(string.format("[CustomGamepadUI DragTransfer] Left-stick cursor movement: axis=(%.2f,%.2f) virtualTarget=(%d,%d) gameActual=(%d,%d) native=(%s,%s uiY=%s) virtual=%s",
                            stickX, stickY, math.floor(state.cursorX), math.floor(state.cursorY), math.floor(physicalX), math.floor(physicalY),
                            tostring(nx), tostring(ny), tostring(nuy), tostring(state.virtualCursor)))
                        state.loggedStickMove = true
                    end
                end
            else
                finishDrag(playerIndex)
            end
        end
    end
end

local function wrapPageClass(pageClass)
    if type(pageClass) ~= "table" or hookedClasses[pageClass] then return end
    if type(pageClass.onJoypadDown) ~= "function" then return end
    local oldJoypadDown = pageClass.onJoypadDown
    pageClass.onJoypadDown = function(self, button, ...)
        local mode = getMode()
        local bCode = Joypad and Joypad.BButton or nil
        local playerIndex = tonumber(self.player) or 0
        if mode == MODE_B and bCode ~= nil and button == bCode then
            -- Do not let button-repeat events leak through once this gesture
            -- has already been intercepted.
            if activeDrags[playerIndex] or pendingBPresses[playerIndex] then return true end
            if selectedDragAvailable(self) then
                -- Don't execute vanilla B on key-down. A short tap is replayed on
                -- release; holding beyond the threshold starts the drag gesture.
                local controllerId = getControllerId(playerIndex)
                if controllerId >= 0 then
                    pendingBPresses[playerIndex] = {
                        page = self,
                        button = button,
                        oldJoypadDown = oldJoypadDown,
                        args = { ... },
                        controllerId = controllerId,
                        startedAt = nowMs(),
                        dragStarted = false,
                        longPress = false,
                    }
                    return true
                end
            end
        end
        return oldJoypadDown(self, button, ...)
    end
    hookedClasses[pageClass] = true
end

local hookedPaneClasses = setmetatable({}, { __mode = "k" })

local function wrapPaneClass(paneClass)
    if type(paneClass) ~= "table" or hookedPaneClasses[paneClass] then return end
    if type(paneClass.update) ~= "function" then return end
    local oldUpdate = paneClass.update
    paneClass.update = function(self, ...)
        local state = nil
        for playerIndex = 0, 3 do
            local candidate = activeDrags[playerIndex]
            if candidate and candidate.pane == self then
                state = candidate
                break
            end
        end
        if state and ISMouseDrag and ISMouseDrag.draggingFocus == self then
            -- CleanUI's ISInventoryPane:update clears a drag whenever the
            -- physical mouse button is not down. Temporarily hide only the
            -- synthetic drag state during that update, then restore it for the
            -- normal render and for the eventual native drop handler.
            local savedDragging = ISMouseDrag.dragging
            local savedFocus = ISMouseDrag.draggingFocus
            ISMouseDrag.dragging = nil
            ISMouseDrag.draggingFocus = nil
            local ok, result = pcall(oldUpdate, self, ...)
            ISMouseDrag.dragging = savedDragging
            ISMouseDrag.draggingFocus = savedFocus
            if not ok then error(result) end
            return result
        end
        return oldUpdate(self, ...)
    end
    hookedPaneClasses[paneClass] = true
end

local function installHooks()
    wrapPageClass(rawget(_G, "ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Clean_ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPage"))
    wrapPaneClass(rawget(_G, "ISInventoryPane"))
    wrapPaneClass(rawget(_G, "CleanUI_Clean_ISInventoryPane"))
    wrapPaneClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPane"))
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(installHooks) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(installHooks) end
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        tickCount = tickCount + 1
        if tickCount % 30 == 0 then installHooks() end
        updateDragTransfer()
        cleanupIdleCursorOverlay()
    end)
end
