-- Select-button sort modes and the Start-button separator guard, layered over
-- CustomGamepadUI's own ISInventoryPage handler without replacing its file.
local GQS = require("GQSModOptions")
local pending = {}
local previousSort = setmetatable({}, { __mode = "k" })

local function isCategorySort(pane)
    return pane.itemSortFunc == ISInventoryPane.itemSortByCatInc
        or pane.itemSortFunc == ISInventoryPane.itemSortByCatDesc
end
local function setCategory(pane, fn)
    pane.itemSortFunc = fn
    pane:refreshContainer()
end
local function rememberCategory(pane)
    if isCategorySort(pane) then
        pane._gqsCategorySort = pane.itemSortFunc
    elseif not pane._gqsCategorySort then
        pane._gqsCategorySort = ISInventoryPane.itemSortByCatInc
    end
end
local function applySingle(pane)
    if pane._gqsSortMode == "weight" then
        rememberCategory(pane)
        pane._gqsCategorySort = pane._gqsCategorySort == ISInventoryPane.itemSortByCatInc
            and ISInventoryPane.itemSortByCatDesc or ISInventoryPane.itemSortByCatInc
        setCategory(pane, pane._gqsCategorySort)
        pane._gqsSortMode = "category"
    else
        pane:sortByType()
        if isCategorySort(pane) then pane._gqsCategorySort = pane.itemSortFunc end
        pane._gqsSortMode = "category"
    end
end
local function applyDouble(pane)
    if pane._gqsSortMode == "weight" then
        rememberCategory(pane)
        setCategory(pane, pane._gqsCategorySort)
        pane._gqsSortMode = "category"
    else
        rememberCategory(pane)
        pane:sortByWeight(false)
        pane._gqsSortMode = "weight"
    end
end
local function applyAlternating(pane)
    if pane._gqsAlternateMode == "categoryDesc" then
        pane:sortByWeight(false)
        pane._gqsAlternateMode = "weightDesc"
    else
        setCategory(pane, ISInventoryPane.itemSortByCatDesc)
        pane._gqsAlternateMode = "categoryDesc"
    end
end

Events.OnTick.Add(function()
    local now = getTimestampMs()
    local mode = GQS.sortBy and GQS.sortBy:getValue() or 1
    local delay = GQS.sortDoubleClickDelay and tonumber(GQS.sortDoubleClickDelay:getValue()) or 200
    for pane, item in pairs(pending) do
        if mode ~= 5 then
            pending[pane] = nil
        elseif now - item.time >= delay then
            pending[pane] = nil
            applySingle(pane)
        end
    end
end)

local originalOnJoypadDown = ISInventoryPage.onJoypadDown
function ISInventoryPage:onJoypadDown(button)
    local pane = self.inventoryPane
    local mode = GQS.sortBy and GQS.sortBy:getValue() or 1
    if button == Joypad.Back and pane then
        if previousSort[pane] ~= mode then
            pending[pane] = nil
            pane._gqsSortMode, pane._gqsCategorySort, pane._gqsAlternateMode = nil, nil, nil
            previousSort[pane] = mode
        end
        if mode == 5 then
            local now = getTimestampMs()
            local delay = GQS.sortDoubleClickDelay and tonumber(GQS.sortDoubleClickDelay:getValue()) or 200
            local queued = pending[pane]
            if queued and now - queued.time < delay then
                pending[pane] = nil
                applyDouble(pane)
            else
                pending[pane] = { time = now }
            end
            return
        elseif mode == 6 then
            pending[pane] = nil
            pane._gqsSortMode, pane._gqsCategorySort = nil, nil
            applyAlternating(pane)
            return
        elseif mode == 2 then
            pending[pane] = nil
            pane:sortByName()
            return
        elseif mode == 3 then
            pending[pane] = nil
            pane:sortByType()
            return
        elseif mode == 4 then
            pending[pane] = nil
            pane:sortByWeight()
            return
        end
    end

    if button == Joypad.Start and pane and GQS.doubleClickWithStart
        and type(GQS.doubleClickWithStart.getValue) == "function"
        and GQS.doubleClickWithStart:getValue() then
        local row = pane.items and pane.joyselection ~= nil and pane.items[pane.joyselection + 1] or nil
        local isItemRow = row and (instanceof(row, "InventoryItem")
            or (row.type ~= "separator" and type(row.items) == "table"))
        if not isItemRow then return end
    end
    return originalOnJoypadDown(self, button)
end
