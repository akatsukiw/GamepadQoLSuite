-- CustomGamepadUI Fix15: make reverse gamepad cycling follow CleanUI's visible
-- container-button order, matching the sorting performed by CleanUI's mouse-wheel
-- handler. Only player inventory is overridden; the loot/search pane keeps its
-- original behavior. Client-side only; does not modify CleanUI files.

local CGUIContainerCycleFix = {}
local installed = false

local function debugPrint(...)
    local logger = rawget(_G, "GQSLog")
    if not logger or type(logger.log) ~= "function" then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.log("containerCycle", table.concat(parts, " "))
end

local function safeNumber(object, methodName, fallback)
    if not object or type(object[methodName]) ~= "function" then
        return fallback
    end
    local ok, value = pcall(object[methodName], object)
    if ok and type(value) == "number" then
        return value
    end
    return fallback
end

local function buttonX(button)
    return safeNumber(button, "getX", 0)
end

local function buttonY(button)
    return safeNumber(button, "getY", 0)
end

local function buttonHeight(button)
    return safeNumber(button, "getHeight", 0)
end

local function visualLess(a, b, originalIndex)
    local ay = buttonY(a)
    local by = buttonY(b)
    local rowTolerance = math.max(2, math.min(buttonHeight(a), buttonHeight(b)) * 0.35)
    if math.abs(ay - by) > rowTolerance then
        return ay < by
    end

    local ax = buttonX(a)
    local bx = buttonX(b)
    if ax ~= bx then
        return ax < bx
    end

    -- Stable tie-breaker for hidden/overlapping buttons.
    return (originalIndex[a] or 0) < (originalIndex[b] or 0)
end

local function makeVisualOrder(page)
    local list = page and page.backpacks
    if type(list) ~= "table" then return nil end

    local visual = {}
    local originalIndex = {}
    for index, button in ipairs(list) do
        visual[#visual + 1] = button
        originalIndex[button] = index
    end

    table.sort(visual, function(a, b)
        return visualLess(a, b, originalIndex)
    end)
    return visual
end

local function findIndexByInventory(buttons, inventory)
    if type(buttons) ~= "table" or inventory == nil then return nil end
    for index, button in ipairs(buttons) do
        if button and button.inventory == inventory then
            return index
        end
    end
    return nil
end

local function isContainerLocked(page, button)
    if not button or not button.inventory then return true end

    local playerObj = getSpecificPlayer(page.player)
    local ok, parent = pcall(function()
        return button.inventory:getParent()
    end)
    if not ok then return false end

    if parent and type(instanceof) == "function" and instanceof(parent, "IsoThumpable") then
        local lockOK, locked = pcall(function()
            return parent:isLockedToCharacter(playerObj)
        end)
        return lockOK and locked == true
    end
    return false
end

local function selectPreviousPlayerContainer(page, original)
    -- Never replace the loot/search pane's own behavior.
    if not page or not page.onCharacter then
        return original(page)
    end

    local backing = page.backpacks
    if type(backing) ~= "table" or #backing <= 1 then
        return original(page)
    end

    -- CleanUI's mouse-wheel wrapper sorts self.backpacks by screen Y/X before
    -- choosing the previous/next button. Its gamepad method does not. Use a
    -- sorted COPY so we follow the same visible order without mutating the array.
    local visual = makeVisualOrder(page)
    if not visual or #visual <= 1 then
        return original(page)
    end

    local paneInventory = page.inventoryPane and page.inventoryPane.inventory or nil
    local currentInventory = paneInventory
    local currentVisualIndex = findIndexByInventory(visual, currentInventory)

    -- During some CleanUI refreshes the pane and page can briefly disagree.
    if not currentVisualIndex then
        currentInventory = page.inventory
        currentVisualIndex = findIndexByInventory(visual, currentInventory)
    end
    if not currentVisualIndex and page.inventoryPane then
        currentInventory = page.inventoryPane.lastinventory
        currentVisualIndex = findIndexByInventory(visual, currentInventory)
    end

    if not currentVisualIndex then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("containerCycle", "Could not map selected player container to visual order; falling back to original method.") end
        return original(page)
    end

    local playerObj = getSpecificPlayer(page.player)
    local joypadBound = playerObj and playerObj:getJoypadBind() ~= -1

    -- Iterate previous visible buttons, wrapping from the first visual button to
    -- the last, and skip containers locked to the character.
    for offset = 1, #visual do
        -- Do not use modulo on a negative index here. Project Zomboid's Lua
        -- runtime can leave a negative remainder, which makes the first item
        -- calculate visualIndex=0/-1 and silently prevents reverse wrap-around.
        -- offset is bounded by #visual, so a single addition is sufficient.
        local visualIndex = currentVisualIndex - offset
        if visualIndex < 1 then
            visualIndex = visualIndex + #visual
        end
        local candidate = visual[visualIndex]
        if candidate and candidate.inventory and not isContainerLocked(page, candidate) then
            if candidate.inventory == currentInventory then
                return -- no other accessible container exists
            end

            local backingIndex = findIndexByInventory(backing, candidate.inventory)
            if not backingIndex then
                local logger = rawget(_G, "GQSLog"); if logger then logger.error("containerCycle", "Target container is missing from backing list; falling back to original method.") end
                return original(page)
            end

            if page.inventoryPane then
                page.inventoryPane.selected = {}
            end

            -- setNewContainer refreshes the visible item pane without rebuilding
            -- the button array. Keep backpackChoice in BACKING-array coordinates;
            -- CleanUI's refreshBackpacks uses it as an array index.
            if type(page.setNewContainer) == "function" then
                page:setNewContainer(candidate.inventory)
            else
                if joypadBound then page.backpackChoice = backingIndex end
                return page:selectContainer(candidate)
            end

            page.inventory = candidate.inventory
            if page.inventoryPane then
                page.inventoryPane.inventory = candidate.inventory
                page.inventoryPane.lastinventory = candidate.inventory
            end
            page.selectedButton = candidate
            if joypadBound then
                page.backpackChoice = backingIndex
            end

            if type(page.updateItemCount) == "function" then
                pcall(function() page:updateItemCount() end)
            end
            if type(page.refreshWeight) == "function" then
                pcall(function() page:refreshWeight() end)
            end
            if page.containerButtonPanel
                    and type(page.containerButtonPanel.keepSelectedButtonVisible) == "function" then
                pcall(function() page.containerButtonPanel:keepSelectedButtonVisible() end)
            end

            debugPrint(string.format(
                "[CustomGamepadUI Fix15] Reverse player-container cycle: visual %d -> %d, backing %d (count=%d)",
                currentVisualIndex, visualIndex, backingIndex, #backing
            ))
            return
        end
    end
end

local function installHooks()
    if installed then return true end
    if not ISInventoryPage or type(ISInventoryPage.selectPrevContainer) ~= "function" then
        return false
    end
    if ISInventoryPage._cguiFix15ReverseCycleInstalled then
        installed = true
        return true
    end

    local original = ISInventoryPage.selectPrevContainer
    ISInventoryPage.selectPrevContainer = function(self)
        return selectPreviousPlayerContainer(self, original)
    end
    ISInventoryPage._cguiFix15ReverseCycleInstalled = true
    installed = true
    debugPrint("[CustomGamepadUI Fix15] Reverse cycle follows visible CleanUI order with explicit wrap arithmetic; loot/search pane remains unchanged.")
    return true
end

CGUIContainerCycleFix.install = installHooks

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(installHooks)
end
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(installHooks)
end

installHooks()
