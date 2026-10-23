-- Gamepad QoL Suite: X short-tap transfer / hold-to-pick-container.
-- Adds a gamepad-only transfer gesture without modifying CleanUI files.
-- Short X release transfers the custom multi-selection, or the focused row,
-- to the other pane's current container. Holding X opens a container-target
-- selection mode starting on the source pane's current container. Up/Down cycles
-- that side's visible containers; Left/Right switches sides. Releasing X on the
-- source container cancels transfer and clears multi-selection; another target
-- performs the transfer.

require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryPane"

local CGUI = require("GQSModOptions")

local GQX = rawget(_G, "GamepadQoLXContainerTransfer") or {}
_G.GamepadQoLXContainerTransfer = GQX

local DEFAULT_X_HOLD_THRESHOLD_MS = 350
local pendingX = {}
local hookedPages = setmetatable({}, { __mode = "k" })
local frameCount = 0
local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("xTransfer", message)
    end
end

local function logTransferError(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.error) == "function" then
        logger.error("xTransfer", message)
    end
end

local function xTransferEnabled()
    local option = CGUI and CGUI.xContainerTransferEnabled
    if not option or type(option.getValue) ~= "function" then return false end
    local ok, value = pcall(option.getValue, option)
    return ok and value == true
end

local function getXHoldThresholdMs()
    local option = CGUI and CGUI.xContainerHoldDelay
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        value = ok and tonumber(value) or nil
        if value then return math.max(150, math.min(1000, value)) end
    end
    return DEFAULT_X_HOLD_THRESHOLD_MS
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return frameCount * 16
end

local function callMethod(object, methodName, ...)
    if not object or type(object[methodName]) ~= "function" then return false, nil end
    local args = { ... }
    local unpackArgs = unpack or (table and table.unpack)
    local ok, result = pcall(function()
        if unpackArgs then return object[methodName](object, unpackArgs(args)) end
        return object[methodName](object)
    end)
    return ok, result
end

local function getControllerId(playerIndex)
    if type(getJoypadData) ~= "function" then return -1 end
    local ok, data = pcall(getJoypadData, playerIndex)
    local id = ok and data and tonumber(data.id) or -1
    return id or -1
end

local function isXDown(controllerId)
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and (buttons.X or buttons.XButton) or nil
    if button and type(button.isDown) == "function" and controllerId >= 0 then
        local ok, down = pcall(button.isDown, button, controllerId)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    if type(isJoypadPressed) == "function" and joypad and joypad.XButton ~= nil and controllerId >= 0 then
        local ok, down = pcall(isJoypadPressed, controllerId, joypad.XButton)
        if ok then return down == true end
    end
    return false
end

local function isVisible(element)
    if not element then return false end
    if type(element.getIsVisible) == "function" then
        local ok, visible = pcall(element.getIsVisible, element)
        if ok then return visible == true end
    end
    if element.visible == false then return false end
    return true
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
    return page.visible ~= false
end

local function getPages(playerIndex)
    local inv = type(getPlayerInventory) == "function" and getPlayerInventory(playerIndex) or nil
    local loot = type(getPlayerLoot) == "function" and getPlayerLoot(playerIndex) or nil
    return inv, loot
end

local function oppositePage(sourcePage, playerIndex)
    local inv, loot = getPages(playerIndex)
    if sourcePage == inv then return loot end
    if sourcePage == loot then return inv end
    return nil
end

local function rowsForTransfer(pane)
    if not pane or type(pane.items) ~= "table" then return {} end
    local rows = {}
    local fromSelection = 0
    -- Only honor the mod's persistent multi-selection when it is active.
    if pane.gmsKeepSelection == true and type(pane.selected) == "table" then
        for index, row in ipairs(pane.items) do
            if pane.selected[index] ~= nil and row ~= nil then
                rows[#rows + 1] = row
                fromSelection = fromSelection + 1
            end
        end
    end
    -- Without a custom multi-selection, act on the currently focused row.
    local fromFocus = false
    if #rows == 0 then
        local index = (tonumber(pane.joyselection) or -1) + 1
        local row = pane.items[index]
        if row then
            rows[1] = row
            fromFocus = true
        end
    end
    local selectedEntries = 0
    if type(pane.selected) == "table" then
        for _ in pairs(pane.selected) do selectedEntries = selectedEntries + 1 end
    end
    log(string.format(
        "rowsForTransfer: rows=%d fromSelection=%d fromFocus=%s keepSelection=%s paneRows=%d paneSelectedEntries=%d",
        #rows, fromSelection, tostring(fromFocus), tostring(pane.gmsKeepSelection), #pane.items, selectedEntries))
    return rows
end

local function actualItemsForRows(rows)
    local result = {}
    if type(rows) ~= "table" or #rows == 0 then return result end
    if ISInventoryPane and type(ISInventoryPane.getActualItems) == "function" then
        local ok, actual = pcall(ISInventoryPane.getActualItems, rows)
        if ok and type(actual) == "table" then
            local seen = {}
            for _, item in ipairs(actual) do
                if item and not seen[item] then
                    seen[item] = true
                    result[#result + 1] = item
                end
            end
        else
            log("Could not expand selected rows: " .. tostring(actual))
        end
    end
    if #result == 0 then
        local seen = {}
        for _, row in ipairs(rows) do
            if instanceof and instanceof(row, "InventoryItem") then
                if not seen[row] then seen[row] = true; result[#result + 1] = row end
            elseif type(row) == "table" and type(row.items) == "table" then
                for _, item in ipairs(row.items) do
                    if item and (not instanceof or instanceof(item, "InventoryItem")) and not seen[item] then
                        seen[item] = true
                        result[#result + 1] = item
                    end
                end
            end
        end
    end
    return result
end

local function buildTransferItems(pane)
    return actualItemsForRows(rowsForTransfer(pane))
end

local function buttonPosition(button)
    local x, y = 0, 0
    if type(button.getAbsoluteX) == "function" then
        local ok, value = pcall(button.getAbsoluteX, button)
        if ok and tonumber(value) then x = tonumber(value) end
    end
    if type(button.getAbsoluteY) == "function" then
        local ok, value = pcall(button.getAbsoluteY, button)
        if ok and tonumber(value) then y = tonumber(value) end
    end
    return x, y
end

local function isLockedForPlayer(container, playerIndex)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerIndex) or nil
    local parent = container and type(container.getParent) == "function" and container:getParent() or nil
    if parent and instanceof and instanceof(parent, "IsoThumpable") and type(parent.isLockedToCharacter) == "function" then
        local ok, locked = pcall(parent.isLockedToCharacter, parent, player)
        if ok and locked then return true end
    end
    return false
end

local function targetButtons(page, state)
    local buttons = {}
    if not page or page.isCollapsed or not page.backpacks then return buttons end
    for _, button in ipairs(page.backpacks) do
        if button and button.inventory and isVisible(button)
            and not isLockedForPlayer(button.inventory, state and state.playerIndex or 0) then
            -- The source pane's current container is intentionally selectable.
            -- Releasing X on it cancels the transfer and clears multi-selection.
            buttons[#buttons + 1] = button
        end
    end
    table.sort(buttons, function(a, b)
        local ax, ay = buttonPosition(a)
        local bx, by = buttonPosition(b)
        if ay == by then return ax < bx end
        return ay < by
    end)
    return buttons
end

local function findButton(page, container)
    if not page or not container then return nil end
    for _, button in ipairs(page.backpacks or {}) do
        if button and button.inventory == container and isVisible(button) then return button end
    end
    return nil
end

local function drawTargetOutline(self)
    if not self or not self._gqolXTransferTarget then return end
    local w = tonumber(self.width) or 0
    local h = tonumber(self.height) or 0
    if w < 8 or h < 8 or type(self.drawRect) ~= "function" then return end

    -- Slight tinted fill helps the target stand out from CleanUI's own gray/white
    -- selected-button skin; draw after the button itself to keep the cue visible.
    pcall(self.drawRect, self, 1, 1, w - 2, h - 2, 0.20, 1.0, 0.78, 0.0)
    local function line(x, y, width, height, alpha, r, g, b)
        if width <= 0 or height <= 0 then return end
        pcall(self.drawRect, self, x, y, width, height, alpha, r, g, b)
    end
    local outer = 4
    line(0, 0, w, outer, 1.0, 1.0, 0.82, 0.0)
    line(0, h - outer, w, outer, 1.0, 1.0, 0.82, 0.0)
    line(0, 0, outer, h, 1.0, 1.0, 0.82, 0.0)
    line(w - outer, 0, outer, h, 1.0, 1.0, 0.82, 0.0)
    local inner = 2
    line(outer, outer, math.max(0, w - outer * 2), inner, 1.0, 0.0, 1.0, 1.0)
    line(outer, h - outer - inner, math.max(0, w - outer * 2), inner, 1.0, 0.0, 1.0, 1.0)
    line(outer, outer, inner, math.max(0, h - outer * 2), 1.0, 0.0, 1.0, 1.0)
    line(w - outer - inner, outer, inner, math.max(0, h - outer * 2), 1.0, 0.0, 1.0, 1.0)
end

local function wrapButtonDraw(button)
    if not button then return end

    -- Wrap render (not just prerender): the outline is painted after CleanUI's
    -- selected/focused state, so its gray/white frame cannot cover the cue.
    local currentRender = button.render
    if type(currentRender) == "function" then
        if button._gqolXRenderWrapper ~= currentRender then
            local oldRender = currentRender
            local wrapper = function(self, ...)
                local result = oldRender(self, ...)
                drawTargetOutline(self)
                return result
            end
            button.render = wrapper
            button._gqolXRenderWrapper = wrapper
            button._gqolXTargetDrawWrapped = true
        end
        return
    end

    -- Defensive fallback for non-standard buttons which do not implement render.
    local currentPrerender = button.prerender
    if type(currentPrerender) == "function" and button._gqolXPrerenderWrapper ~= currentPrerender then
        local oldPrerender = currentPrerender
        local wrapper = function(self, ...)
            local result = oldPrerender(self, ...)
            drawTargetOutline(self)
            return result
        end
        button.prerender = wrapper
        button._gqolXPrerenderWrapper = wrapper
        button._gqolXTargetDrawWrapped = true
    end
end

local function getWorldParent(page, container)
    if not page or not container or type(page.getContainerParent) ~= "function" then return nil end
    local ok, parent = pcall(page.getContainerParent, page, container)
    if ok then return parent end
    return nil
end

local function clearWorldHighlight(state)
    if not state then return end
    local page = state.targetPage
    local parent = state.worldParent
    local playerIndex = state.playerIndex or 0
    if parent then
        -- Only clear the outline this selection mode owns. If another hover
        -- interaction has since taken over the page, avoid erasing that state.
        local ownsPageHover = page
            and page.mouseOverColoredContainer == parent
            and page.mouseOverColoredContainerInv == state.targetContainer
        if ownsPageHover and type(page.stopHighlightContainer) == "function" then
            pcall(page.stopHighlightContainer, page, parent)
            page.mouseOverColoredContainer = nil
            page.mouseOverColoredContainerInv = nil
        else
            if type(parent.setOutlineHighlight) == "function" then
                pcall(parent.setOutlineHighlight, parent, playerIndex, false)
            end
            if type(parent.setOutlineHlAttached) == "function" then
                pcall(parent.setOutlineHlAttached, parent, playerIndex, false)
            end
        end
    end
    if page and page.mouseOverButton and state.targetContainer
        and page.mouseOverButton.inventory == state.targetContainer then
        page.mouseOverButton = nil
    end
    state.worldParent = nil
end

local function applyWorldHighlight(state, button)
    if not state or not button or not button.inventory then return end
    local page = state.targetPage
    local container = button.inventory
    local parent = getWorldParent(page, container)
    if not parent then return end
    if instanceof and instanceof(parent, "IsoPlayer") then return end
    if type(parent.setOutlineHighlight) ~= "function" or type(parent.setOutlineHlAttached) ~= "function" then return end

    local r, g, b = 1.0, 0.78, 0.0
    if type(getCore) == "function" then
        local okCore, core = pcall(getCore)
        if okCore and core and type(core.getWorldItemHighlightColor) == "function" then
            local okColor, color = pcall(core.getWorldItemHighlightColor, core)
            if okColor and color then
                if type(color.getR) == "function" then local ok, v = pcall(color.getR, color); if ok and tonumber(v) then r = tonumber(v) end end
                if type(color.getG) == "function" then local ok, v = pcall(color.getG, color); if ok and tonumber(v) then g = tonumber(v) end end
                if type(color.getB) == "function" then local ok, v = pcall(color.getB, color); if ok and tonumber(v) then b = tonumber(v) end end
            end
        end
    end

    local playerIndex = state.playerIndex or 0
    pcall(parent.setOutlineHighlight, parent, playerIndex, true)
    pcall(parent.setOutlineHlAttached, parent, playerIndex, true)
    if type(parent.setOutlineHighlightCol) == "function" then
        pcall(parent.setOutlineHighlightCol, parent, playerIndex, r, g, b, 1)
    end
    page.mouseOverButton = button
    page.mouseOverColoredContainer = parent
    page.mouseOverColoredContainerInv = container
    state.worldParent = parent
end

local function clearTargetVisual(state)
    if not state then return end
    local page, oldButton = state.targetPage, state.targetButton
    local oldContainer = state.targetContainer
    if oldButton then oldButton._gqolXTransferTarget = nil end
    -- CleanUI can replace button instances when a containing item changes name.
    -- Clear every current instance for the old target, not just a stale pointer.
    if page and oldContainer then
        for _, button in ipairs(page.backpacks or {}) do
            if button and button.inventory == oldContainer then
                button._gqolXTransferTarget = nil
            end
        end
    end
    clearWorldHighlight(state)
    state.targetButton = nil
end

local function applyTargetVisual(state)
    if not state or not state.targetPage or not state.targetContainer then return end
    local page = state.targetPage
    local button = findButton(page, state.targetContainer)
    state.targetButton = button
    if not button then
        log("Target has no visible button: " .. tostring(state.targetContainer:getType()))
        return
    end

    wrapButtonDraw(button)
    button._gqolXTransferTarget = true
    applyWorldHighlight(state, button)
    log(string.format("Target highlighted: side=%s container=%s; strong UI outline armed", state.targetSide, tostring(button.name or (state.targetContainer.getType and state.targetContainer:getType()) or "?")))
end

local function setTarget(state, page, side, container)
    if not state or not page or not page.inventoryPane then return false end
    if not pageIsVisible(page) or page.isCollapsed then
        log("Cannot select target side because its container bar is hidden: " .. tostring(side))
        return false
    end
    local buttons = targetButtons(page, state)
    local chosen = nil
    -- Only keep the requested container if it is a valid navigation target.
    -- In particular, don't select the source pane's own current container when
    -- the player switches the target side back to that pane.
    if container then
        for _, candidate in ipairs(buttons) do
            if candidate.inventory == container then
                chosen = candidate
                break
            end
        end
    end
    if not chosen and container and page.inventoryPane.inventory == container then
        -- The active container is a valid default/no-op target even if CleanUI
        -- doesn't expose a separate visible button for it in this layout.
        clearTargetVisual(state)
        state.targetPage = page
        state.targetSide = side
        state.targetContainer = container
        state.targetButton = nil
        applyTargetVisual(state)
        log("Current active container selected as no-op target on side " .. tostring(side))
        return true
    end
    if not chosen then chosen = buttons[1] end
    if not chosen then
        log("No available container buttons on side " .. tostring(side))
        return false
    end
    clearTargetVisual(state)
    state.targetPage = page
    state.targetSide = side
    state.targetContainer = chosen.inventory
    applyTargetVisual(state)
    return true
end

local function initializeTarget(state)
    local invPage, lootPage = getPages(state.playerIndex)
    -- Long-X mode starts at the source pane's currently active container.
    -- Releasing without changing the target is therefore a safe no-op.
    local targetPage = state.sourcePage
    local side = targetPage == invPage and "player" or (targetPage == lootPage and "loot" or nil)
    if not targetPage or not targetPage.inventoryPane or not side then
        log("No current source container available for X target selection")
        return false
    end
    local currentContainer = targetPage.inventoryPane.inventory
    if setTarget(state, targetPage, side, currentContainer) then return true end
    return false
end

local function cycleVertical(state, direction)
    local buttons = targetButtons(state.targetPage, state)
    if #buttons == 0 then return end
    local current = 0
    for index, button in ipairs(buttons) do
        if button.inventory == state.targetContainer then current = index; break end
    end
    local targetIndex
    if current == 0 then
        targetIndex = direction < 0 and #buttons or 1
    else
        targetIndex = current + direction
        if targetIndex < 1 then targetIndex = #buttons end
        if targetIndex > #buttons then targetIndex = 1 end
    end
    setTarget(state, state.targetPage, state.targetSide, buttons[targetIndex].inventory)
end

local function chooseSide(state, side)
    local invPage, lootPage = getPages(state.playerIndex)
    local page = side == "player" and invPage or lootPage
    if not page or page == state.targetPage then return end
    if not page.inventoryPane then return end
    setTarget(state, page, side, page.inventoryPane.inventory)
end

local function handleDirection(state, direction)
    if direction == "up" then cycleVertical(state, -1)
    elseif direction == "down" then cycleVertical(state, 1)
    elseif direction == "left" then chooseSide(state, "player")
    elseif direction == "right" then chooseSide(state, "loot") end
end

local function isMultiplayerSession()
    if type(isMultiplayer) == "function" then
        local ok, value = pcall(isMultiplayer)
        if ok then return value == true end
    end
    -- Compatibility fallback for game versions where isMultiplayer is absent.
    for _, name in ipairs({ "isClient", "isServer" }) do
        local query = rawget(_G, name)
        if type(query) == "function" then
            local ok, value = pcall(query)
            if ok and value == true then return true end
        end
    end
    return false
end

local function isPlayerCarriedContainer(container, player)
    if not container or not player then return false end
    if type(container.isInCharacterInventory) == "function" then
        local ok, value = pcall(container.isInCharacterInventory, container, player)
        if ok then return value == true end
    end
    if type(player.getInventory) == "function" then
        local ok, inventory = pcall(player.getInventory, player)
        if ok and inventory == container then return true end
    end
    return false
end

-- Diagnostic helper: item display name without risking a native call error.
local function safeDisplayName(item)
    if not item then return "nil" end
    if type(item.getDisplayName) == "function" then
        local ok, name = pcall(item.getDisplayName, item)
        if ok and name ~= nil then return tostring(name) end
    end
    return "?"
end

local function isFavoriteItem(item)
    if not item or type(item.isFavorite) ~= "function" then return false end
    local ok, favorite = pcall(item.isFavorite, item)
    return ok and favorite == true
end

local function isItemTransferable(item, targetContainer, player)
    if not item or not targetContainer then return false end
    local sourceContainer = nil
    if type(item.getContainer) == "function" then
        local ok, value = pcall(item.getContainer, item)
        if ok then sourceContainer = value end
    end
    if sourceContainer == targetContainer then return false end
    if type(targetContainer.isInside) == "function" then
        local ok, inside = pcall(targetContainer.isInside, targetContainer, item)
        if ok and inside then return false end
    end

    -- Favorites are protected in every session, not only in multiplayer: they may
    -- move between the character's own containers (inventory and carried bags),
    -- but a favorited item must never be sent to a world/loot/search container or
    -- onto the floor. Vanilla only enforces this in multiplayer, so singleplayer
    -- sessions were letting favorites escape into crates; the rule is applied
    -- here unconditionally.
    if player and not isPlayerCarriedContainer(targetContainer, player) and isFavoriteItem(item) then
        log("Transfer skipped: favorite item cannot be sent to a non-carried container")
        return false
    end

    -- Equipped/worn items and hotbar/belt-attached items remain eligible;
    -- the destination container's own isItemAllowed check remains authoritative.
    if type(targetContainer.isItemAllowed) == "function" then
        local ok, allowed = pcall(targetContainer.isItemAllowed, targetContainer, item)
        if not ok then
            log("Container validation failed for " .. tostring(item) .. ": " .. tostring(allowed))
            return false
        end
        if allowed ~= true then
            log("Transfer skipped by destination validation: item=" .. tostring(item:getDisplayName()) .. ", target=" .. tostring(targetContainer:getType()))
            return false
        end
    end
    return true
end

local function transferToContainer(state, targetContainer, reason)
    if not state or not state.sourcePane or not targetContainer then
        log("Transfer aborted: source pane or target container is missing")
        return false
    end
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(state.playerIndex) or nil
    if player and type(player.isAsleep) == "function" and player:isAsleep() then return false end
    if UIManager and UIManager.getSpeedControls then
        local controls = UIManager.getSpeedControls()
        if controls and type(controls.getCurrentGameSpeed) == "function" and controls:getCurrentGameSpeed() == 0 then
            log("Transfer blocked while the game is paused")
            return false
        end
    end

    local allowed = {}
    local seen = {}
    local multiplayer = isMultiplayerSession()
    log(string.format("transfer start: candidates=%d target=%s multiplayer=%s",
        #(state.items or {}), tostring(targetContainer:getType()), tostring(multiplayer)))
    for _, item in ipairs(state.items or {}) do
        if item and not seen[item] then
            seen[item] = true
            local transferable = isItemTransferable(item, targetContainer, player)
            log(string.format("transfer candidate: name=%s favorite=%s transferable=%s",
                safeDisplayName(item), tostring(isFavoriteItem(item)), tostring(transferable)))
            if transferable then
                allowed[#allowed + 1] = item
            end
        end
    end
    if #allowed == 0 then
        log("No selected items can be transferred to target " .. tostring(targetContainer:getType()))
        return false
    end

    local sourcePane = state.sourcePane
    if type(sourcePane.transferItemsByWeight) ~= "function" then
        log("Transfer aborted: source pane has no transferItemsByWeight")
        return false
    end
    local ok, err = pcall(sourcePane.transferItemsByWeight, sourcePane, allowed, targetContainer)
    if not ok then
        logTransferError("Transfer function failed: " .. tostring(err))
        return false
    end
    log(string.format("%s: queued %d item(s) to %s", tostring(reason), #allowed, tostring(targetContainer:getType())))
    local gms = rawget(_G, "GamepadMultiSelectStandalone")
    if gms and type(gms.clearPlayer) == "function" then pcall(gms.clearPlayer, state.playerIndex) end
    return true
end

local function clearMultiSelection(state)
    local gms = rawget(_G, "GamepadMultiSelectStandalone")
    if gms and type(gms.clearPlayer) == "function" then
        pcall(gms.clearPlayer, state.playerIndex)
    end
end

local function finishPending(state)
    if not state then return end
    if state.longPress then
        local page, button = state.targetPage, state.targetButton
        local targetContainer = state.targetContainer
        clearTargetVisual(state)
        if page and button and type(page.mouseOverButton) == "table" and page.mouseOverButton == button then
            page.mouseOverButton = nil
        end
        if targetContainer and state.sourcePane and targetContainer == state.sourcePane.inventory then
            -- Default target is the current source container. Releasing X
            -- without choosing another target cancels transfer and clears the
            -- custom multi-selection instead of trying to transfer items to themselves.
            clearMultiSelection(state)
            log("Long X released on current container; no transfer, selection cleared")
            return
        end
        transferToContainer(state, targetContainer, "Long X release")
    else
        local targetPage = oppositePage(state.sourcePage, state.playerIndex)
        local targetContainer = targetPage and targetPage.inventoryPane and targetPage.inventoryPane.inventory or nil
        transferToContainer(state, targetContainer, "Short X release")
    end
end

local function startLongPress(state)
    state.longPress = true
    if not initializeTarget(state) then
        log("Long X selection started, but no visible target button is available")
    else
        log("Long X target mode started; release X to transfer")
    end
end

local function updatePendingX()
    for playerIndex, state in pairs(pendingX) do
        if not xTransferEnabled() then
            clearTargetVisual(state)
            pendingX[playerIndex] = nil
            log("Cancelled X gesture because the feature was disabled")
        elseif not pageIsVisible(state.sourcePage) then
            clearTargetVisual(state)
            pendingX[playerIndex] = nil
            log("Cancelled X gesture because its source pane closed")
        elseif isXDown(state.controllerId) then
            if not state.longPress and nowMs() - state.startedAt >= getXHoldThresholdMs() then
                startLongPress(state)
            elseif state.longPress then
                -- CleanUI may rebuild buttons or its hover update may clear the
                -- outline. Re-arm the latest button and world highlight each tick.
                local button = findButton(state.targetPage, state.targetContainer)
                if button ~= state.targetButton then
                    clearTargetVisual(state)
                    applyTargetVisual(state)
                elseif button then
                    button._gqolXTransferTarget = true
                    wrapButtonDraw(button)
                    applyWorldHighlight(state, button)
                end
            end
        else
            pendingX[playerIndex] = nil
            finishPending(state)
        end
    end
end

local function wrapDirections(pageClass)
    -- B42/CleanUI load order can leave optional page classes unavailable.
    -- Do not index a nil/non-table class during startup.
    if type(pageClass) ~= "table" then return end
    local directions = {
        onJoypadDirUp = "up",
        onJoypadDirDown = "down",
        onJoypadDirLeft = "left",
        onJoypadDirRight = "right",
    }
    for methodName, direction in pairs(directions) do
        local oldMethod = pageClass[methodName]
        if type(oldMethod) == "function" and not pageClass["_gqolXWrapped_" .. methodName] then
            pageClass[methodName] = function(self, ...)
                local state = pendingX[tonumber(self.player) or 0]
                if state and state.longPress then
                    handleDirection(state, direction)
                    return true
                end
                return oldMethod(self, ...)
            end
            pageClass["_gqolXWrapped_" .. methodName] = true
        end
    end
end

local function wrapPageClass(pageClass)
    if type(pageClass) ~= "table" or hookedPages[pageClass] then return end
    local oldJoypadDown = pageClass.onJoypadDown
    if type(oldJoypadDown) ~= "function" then return end
    hookedPages[pageClass] = true

    pageClass.onJoypadDown = function(self, button, ...)
        local joypad = rawget(_G, "Joypad")
        local playerIndex = tonumber(self.player) or 0
        if xTransferEnabled() and joypad and button == joypad.XButton and not (JoypadState and JoypadState.disableGrab) then
            if pendingX[playerIndex] then return true end
            local controllerId = getControllerId(playerIndex)
            if controllerId >= 0 and self.inventoryPane and pageIsVisible(self) and self ~= nil then
                local rows = rowsForTransfer(self.inventoryPane)
                local items = actualItemsForRows(rows)
                if #items > 0 then
                    pendingX[playerIndex] = {
                        playerIndex = playerIndex,
                        controllerId = controllerId,
                        sourcePage = self,
                        sourcePane = self.inventoryPane,
                        sourceRows = rows,
                        items = items,
                        startedAt = nowMs(),
                        longPress = false,
                        targetPage = nil,
                        targetContainer = nil,
                        targetButton = nil,
                        targetSide = nil,
                    }
                    log(string.format("X pressed: rows=%d items=%d source=%s; waiting for release/long press",
                        #rows, #items, self.onCharacter and "player" or "loot"))
                    return true
                end
            end
        end
        return oldJoypadDown(self, button, ...)
    end

    wrapDirections(pageClass)
end

local function installHooks()
    wrapPageClass(rawget(_G, "ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Clean_ISInventoryPage"))
    wrapPageClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPage"))
    -- Direction methods might be added/replaced after CleanUI initialization.
    wrapDirections(rawget(_G, "ISInventoryPage"))
    wrapDirections(rawget(_G, "CleanUI_Clean_ISInventoryPage"))
    wrapDirections(rawget(_G, "CleanUI_Vanilla_ISInventoryPage"))
end

installHooks()
if Events and Events.OnGameStart then Events.OnGameStart.Add(installHooks) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(installHooks) end
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        frameCount = frameCount + 1
        if frameCount % 30 == 0 then installHooks() end
        updatePendingX()
    end)
end
