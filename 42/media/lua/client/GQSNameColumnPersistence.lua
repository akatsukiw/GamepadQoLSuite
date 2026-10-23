-- Gamepad QoL Suite: persist CleanUI column dividers without editing CleanUI.
-- Client-side only. Stores Name and Category/Weight widths per player and pane in Zomboid/Lua.

local CGUINameColumnPersistence = {}
local DATA_FILE = "GamepadQoLSuite_NameColumnWidth.txt"
local LEGACY_DATA_FILE = "CustomGamepadUI_NameColumnWidth.txt"
local storedWidths = nil
local installed = false

local function debugPrint(...)
    local logger = rawget(_G, "GQSLog")
    if not logger or type(logger.log) ~= "function" then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.log("nameColumn", table.concat(parts, " "))
end

local function readFileWidths(filename, target)
    local openOK, reader = pcall(getFileReader, filename, false)
    if not openOK or reader == nil then return false end
    local found = false
    while true do
        local lineOK, line = pcall(function() return reader:readLine() end)
        if not lineOK or line == nil then break end
        local key, value = string.match(tostring(line), "^([%w_]+)=(%d+)$")
        local number = tonumber(value)
        if key and number and number >= 1 and number <= 10000 then
            target[key] = math.floor(number)
            found = true
        end
    end
    pcall(function() reader:close() end)
    return found
end

local function readStoredWidths()
    if storedWidths ~= nil then return storedWidths end
    storedWidths = {}

    -- Read the new file first. If it has no saved values yet, read the old
    -- CustomGamepadUI filename so existing divider widths are retained after rename.
    local foundNew = readFileWidths(DATA_FILE, storedWidths)
    if not foundNew then
        readFileWidths(LEGACY_DATA_FILE, storedWidths)
    end
    return storedWidths
end
local function writeStoredWidths()
    local data = readStoredWidths()
    local keys = {}
    for key, value in pairs(data) do
        if type(key) == "string" and type(value) == "number" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local lines = {}
    for _, key in ipairs(keys) do
        table.insert(lines, key .. "=" .. tostring(math.floor(data[key])))
    end

    local openOK, writer = pcall(getFileWriter, DATA_FILE, true, false)
    if not openOK or writer == nil then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("nameColumn", "Could not open " .. DATA_FILE .. " for writing") end
        return false
    end

    local writeOK, writeError = pcall(function()
        writer:write(table.concat(lines, "\n") .. "\n")
    end)
    local closeOK, closeError = pcall(function() writer:close() end)
    if not writeOK then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("nameColumn", "Could not write name-column settings: " .. tostring(writeError)) end
        return false
    end
    if not closeOK then
        local logger = rawget(_G, "GQSLog"); if logger then logger.error("nameColumn", "Could not close name-column settings: " .. tostring(closeError)) end
        return false
    end
    return true
end

local function isSplitScreenPane(pane)
    local player = math.floor(tonumber(pane and pane.player) or 0)
    if type(getNumActivePlayers) == "function" then
        local ok, activePlayers = pcall(getNumActivePlayers)
        if ok and (tonumber(activePlayers) or 1) > 1 then return true end
    end
    if type(getPlayerScreenWidth) == "function" and type(getCore) == "function" then
        local ok, viewportWidth = pcall(getPlayerScreenWidth, player)
        local coreOK, core = pcall(getCore)
        local screenWidth = coreOK and core and tonumber(core:getScreenWidth()) or nil
        if ok and tonumber(viewportWidth) and screenWidth and viewportWidth < screenWidth then return true end
    end
    if type(getPlayerScreenHeight) == "function" and type(getCore) == "function" then
        local ok, viewportHeight = pcall(getPlayerScreenHeight, player)
        local coreOK, core = pcall(getCore)
        local screenHeight = coreOK and core and tonumber(core:getScreenHeight()) or nil
        if ok and tonumber(viewportHeight) and screenHeight and viewportHeight < screenHeight then return true end
    end
    return false
end

local function getPaneKey(pane)
    local player = tonumber(pane and pane.player) or 0
    local panelName = "inventory"
    if pane and pane.inventoryPage and pane.inventoryPage.onCharacter == false then
        panelName = "loot"
    end
    local mode = isSplitScreenPane(pane) and "split_" or "solo_"
    return mode .. "p" .. tostring(math.floor(player)) .. "_" .. panelName
end

local function getStoredPaneValue(pane, suffix)
    local data = readStoredWidths()
    local key = getPaneKey(pane) .. (suffix or "")
    local value = tonumber(data[key])
    if value then return value end
    -- Migrate legacy single-player keys in place. Split-screen always gets its
    -- own key and can never inherit or overwrite the solo layout.
    if not isSplitScreenPane(pane) then
        local player = math.floor(tonumber(pane and pane.player) or 0)
        local panelName = pane and pane.inventoryPage and pane.inventoryPage.onCharacter == false and "loot" or "inventory"
        return tonumber(data["p" .. tostring(player) .. "_" .. panelName .. (suffix or "")])
    end
    return nil
end

local function isCleanUIPane(pane)
    return pane ~= nil
        and type(pane.onResizeColumn) == "function"
        and type(pane.cleanUICancelColumnResize) == "function"
        and pane.nameHeader ~= nil
        and pane.typeHeader ~= nil
end

local function savePaneWidth(pane)
    if not isCleanUIPane(pane) then return false end

    local column3 = tonumber(pane.column3)
    local iconColumnWidth = tonumber(pane.column2) or 0
    if not column3 then return false end

    local textWidth = math.floor(column3 - iconColumnWidth + 0.5)
    if textWidth < 1 or textWidth > 10000 then return false end

    local data = readStoredWidths()
    data[getPaneKey(pane)] = textWidth
    pane._cguiNameColumnWidthFixLastSaved = textWidth
    return writeStoredWidths()
end

local function getWeightDividerWidth(pane)
    if not pane then return nil end

    local contentRight = tonumber(pane._cleanUIColumnContentRight)
    local boundary = tonumber(pane._cleanUIRarityWeightBoundary)
    if contentRight and boundary then
        local width = contentRight - boundary
        if width > 0 and width <= 10000 then
            return math.floor(width + 0.5)
        end
    end

    local width = tonumber(pane.cleanUIWeightColumnWidth)
        or tonumber(pane._cleanUIWeightRestoreWidth)
    if width and width > 0 and width <= 10000 then
        return math.floor(width + 0.5)
    end
    return nil
end

local function savePaneWeightWidth(pane)
    if not isCleanUIPane(pane) then return false end

    local weightWidth = getWeightDividerWidth(pane)
    if not weightWidth then return false end

    local data = readStoredWidths()
    data[getPaneKey(pane) .. "_weight"] = weightWidth
    pane._cguiWeightDividerFixLastSaved = weightWidth
    -- Keep CleanUI's in-memory width in step with our per-pane value. We do not
    -- write CleanUI files/configuration; the independent file remains authoritative.
    pane.cleanUIWeightColumnWidth = weightWidth
    pane._cleanUIWeightRestoreWidth = weightWidth
    return writeStoredWidths()
end

local function applyPaneWeightWidth(pane, force)
    if not isCleanUIPane(pane) then return false end
    if pane._cleanUIDividerPendingResize or pane.resizingWeightColumn then return false end
    if not force and pane._cguiWeightDividerFixChecked then return false end

    local stored = getStoredPaneValue(pane, "_weight")
    if stored and stored > 0 and stored <= 10000 then
        local current = getWeightDividerWidth(pane)
        if not current or math.abs(current - stored) >= 1 then
            pane.cleanUIWeightColumnWidth = math.floor(stored)
            pane._cleanUIWeightRestoreWidth = math.floor(stored)
            pane._cleanUIWeightCollapsed = false
            -- Reinitialize CleanUI's own logical divider model using the stored
            -- Weight width. With Rarity disabled, the Category/Weight divider is
            -- the shared boundary between Category and Weight.
            pane._cleanUIColumnBoundariesInitialized = false
            pane._cleanUIColumnBoundaryCache = nil
            pane._cleanUIHeaderMetricsCache = nil
            pane._cleanUIColumnHeaderLayoutCache = nil
            pane._cleanUIWeightMetricsCache = nil
            pane._cleanUIRarityMetricsCache = nil
        end
    end

    pane._cguiWeightDividerFixChecked = true
    return stored ~= nil
end

local function clamp(value, low, high)
    if high < low then high = low end
    if value < low then return low end
    if value > high then return high end
    return value
end

local function applyPaneWidth(pane, force)
    if not isCleanUIPane(pane) then return false end
    if pane._cleanUIDividerPendingResize or pane.resizingColumn then return false end
    if not force and pane._cguiNameColumnWidthFixChecked then return false end

    local stored = getStoredPaneValue(pane)
    if not stored then
        pane._cguiNameColumnWidthFixChecked = true
        return false
    end

    local iconColumnWidth = tonumber(pane.column2) or 0
    local panelWidth = tonumber(pane.width) or 0
    local padding = tonumber(pane.padding) or 0
    local rightLimit = panelWidth - padding
    if type(pane.isVScrollBarVisible) == "function" and pane:isVScrollBarVisible() then
        rightLimit = rightLimit - 8
    end

    -- Keep enough space for CleanUI's non-collapsible Item area and Category column.
    local minimumColumn3 = math.max(iconColumnWidth + 45, 90)
    local maximumColumn3 = math.max(minimumColumn3, rightLimit - 70)
    local targetColumn3 = math.floor(clamp(iconColumnWidth + stored, minimumColumn3, maximumColumn3))
    local oldColumn3 = tonumber(pane.column3) or targetColumn3
    local delta = targetColumn3 - oldColumn3

    if math.abs(delta) > 0 then
        -- Move the downstream dividers by the same amount to preserve their widths
        -- where possible, instead of allowing CleanUI to clamp Name against Category.
        local categoryRarityBoundary = tonumber(pane._cleanUICategoryRarityBoundary)
        local rarityWeightBoundary = tonumber(pane._cleanUIRarityWeightBoundary)
        if categoryRarityBoundary then
            pane._cleanUICategoryRarityBoundary = categoryRarityBoundary + delta
        end
        if rarityWeightBoundary then
            pane._cleanUIRarityWeightBoundary = rarityWeightBoundary + delta
        end

        pane.column3 = targetColumn3
        if pane.nameHeader and type(pane.nameHeader.setWidth) == "function" then
            local nameLeft = tonumber(pane.nameHeader.x) or 0
            pane.nameHeader:setWidth(math.max(1, targetColumn3 - nameLeft))
            pane:onResizeColumn(pane.nameHeader)
        end

        pane._cleanUIColumnBoundaryCache = nil
        pane._cleanUIWeightMetricsCache = nil
        pane._cleanUIRarityMetricsCache = nil
        pane._cleanUIColumnBoundariesInitialized = true
    end

    pane._cguiNameColumnWidthFixChecked = true
    pane._cguiNameColumnWidthFixLastApplied = targetColumn3 - iconColumnWidth
    return true
end

local function invokeForSecondaryDivider(pane, callback, x, y)
    if not pane or (tonumber(pane.player) or 0) == 0 or type(callback) ~= "function" then
        return callback and callback(pane, x, y) or nil
    end
    local originalPlayer = pane.player
    pane.player = 0
    local ok, result = pcall(callback, pane, x, y)
    pane.player = originalPlayer
    if not ok then error(result) end
    return result
end

local function isDividerMouseDown(pane, x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y or not pane then return false end
    local headers = { pane.nameHeader, pane.typeHeader, pane.rarityHeader, pane.weightHeader }
    local paneWidth = tonumber(pane.width) or 0
    for _, header in pairs(headers) do
        if header then
            local left = tonumber(header.x)
            local width = tonumber(header.width)
            local top = tonumber(header.y) or 0
            local height = tonumber(header.height) or tonumber(pane.headerHeight) or 24
            if left and width and width > 0 then
                local edge = left + width
                if math.abs(x - edge) <= 9 and y >= top - 5 and y <= top + height + 5 then
                    return true
                end
            end
        end
    end
    -- CleanUI stores the logical rarity/weight boundary independently of the
    -- visual header widgets, so include it when the Weight column is enabled.
    local boundary = tonumber(pane._cleanUIRarityWeightBoundary)
    local top = tonumber(pane.weightHeader and pane.weightHeader.y) or 0
    local height = tonumber(pane.weightHeader and pane.weightHeader.height) or tonumber(pane.headerHeight) or 24
    if boundary and boundary > 0 and boundary < paneWidth
        and math.abs(x - boundary) <= 9 and y >= top - 5 and y <= top + height + 5 then
        return true
    end
    return false
end

local function installHooks()
    if installed then return true end
    if not ISInventoryPane or type(ISInventoryPane.cleanUICancelColumnResize) ~= "function" then
        -- CleanUI was not active when this callback fired. OnCreatePlayer below can retry.
        return false
    end

    local originalOnMouseDown = ISInventoryPane.onMouseDown
    if type(originalOnMouseDown) == "function" then
        ISInventoryPane.onMouseDown = function(self, x, y)
            local beforeName = tonumber(self.column3)
            local beforeWeight = getWeightDividerWidth(self)
            local result
            if (tonumber(self.player) or 0) ~= 0 and isDividerMouseDown(self, x, y) then
                result = invokeForSecondaryDivider(self, originalOnMouseDown, x, y)
            else
                result = originalOnMouseDown(self, x, y)
            end
            local afterName = tonumber(self.column3)
            local afterWeight = getWeightDividerWidth(self)
            -- CleanUI's double-click auto-fit can change either divider on mouse-down.
            if beforeName and afterName and math.abs(afterName - beforeName) >= 1 then
                savePaneWidth(self)
                self._cguiNameColumnWidthFixChecked = true
            end
            if beforeWeight and afterWeight and math.abs(afterWeight - beforeWeight) >= 1 then
                savePaneWeightWidth(self)
                self._cguiWeightDividerFixChecked = true
            end
            return result
        end
    end

    local originalOnMouseMove = ISInventoryPane.onMouseMove
    if type(originalOnMouseMove) == "function" then
        ISInventoryPane.onMouseMove = function(self, dx, dy)
            local dividerActive = self._cleanUIDividerPendingResize ~= nil
                or self.resizingColumn == true
                or self.resizingWeightColumn == true
                or (self._cleanUIResizeState ~= nil)
            if (tonumber(self.player) or 0) ~= 0 and dividerActive then
                return invokeForSecondaryDivider(self, originalOnMouseMove, dx, dy)
            end
            return originalOnMouseMove(self, dx, dy)
        end
    end

    local originalOnMouseUp = ISInventoryPane.onMouseUp
    if type(originalOnMouseUp) == "function" then
        ISInventoryPane.onMouseUp = function(self, x, y)
            local resizeKey = self._cleanUIResizeState and self._cleanUIResizeState.key
            local wasNameResize = self.resizingColumn == true or resizeKey == "name"
            local wasWeightResize = self.resizingWeightColumn == true or resizeKey == "weight"

            -- CleanUI's current onMouseUp handles the Name divider, but does not
            -- finalize the Weight divider. Capture its final width and explicitly
            -- cancel that resize so it cannot keep intercepting future mouse moves.
            if wasWeightResize then
                savePaneWeightWidth(self)
                if type(self.cleanUICancelColumnResize) == "function" then
                    self:cleanUICancelColumnResize()
                end
                self._cguiWeightDividerFixChecked = true
                return true
            end

            local result
            if (tonumber(self.player) or 0) ~= 0 and (wasNameResize or wasWeightResize) then
                result = invokeForSecondaryDivider(self, originalOnMouseUp, x, y)
            else
                result = originalOnMouseUp(self, x, y)
            end
            if wasNameResize then
                savePaneWidth(self)
                self._cguiNameColumnWidthFixChecked = true
            end
            return result
        end
    end

    local originalOnMouseUpOutside = ISInventoryPane.onMouseUpOutside
    if type(originalOnMouseUpOutside) == "function" then
        ISInventoryPane.onMouseUpOutside = function(self, x, y)
            local resizeKey = self._cleanUIResizeState and self._cleanUIResizeState.key
            local wasNameResize = self.resizingColumn == true or resizeKey == "name"
            local wasWeightResize = self.resizingWeightColumn == true or resizeKey == "weight"

            if wasWeightResize then
                savePaneWeightWidth(self)
                if type(self.cleanUICancelColumnResize) == "function" then
                    self:cleanUICancelColumnResize()
                end
                self._cguiWeightDividerFixChecked = true
                return true
            end

            local result
            if (tonumber(self.player) or 0) ~= 0 and (wasNameResize or wasWeightResize) then
                result = invokeForSecondaryDivider(self, originalOnMouseUpOutside, x, y)
            else
                result = originalOnMouseUpOutside(self, x, y)
            end
            if wasNameResize then
                savePaneWidth(self)
                self._cguiNameColumnWidthFixChecked = true
            end
            return result
        end
    end

    local originalRestoreLayout = ISInventoryPane.RestoreLayout
    if type(originalRestoreLayout) == "function" then
        ISInventoryPane.RestoreLayout = function(self, name, layout)
            local result = originalRestoreLayout(self, name, layout)
            self._cguiNameColumnWidthFixChecked = false
            self._cguiWeightDividerFixChecked = false
            applyPaneWidth(self, true)
            applyPaneWeightWidth(self, true)
            return result
        end
    end

    local originalPrerender = ISInventoryPane.prerender
    if type(originalPrerender) == "function" then
        ISInventoryPane.prerender = function(self, ...)
            local result = originalPrerender(self, ...)
            if not self._cguiNameColumnWidthFixChecked then
                applyPaneWidth(self, false)
            end
            if not self._cguiWeightDividerFixChecked then
                applyPaneWeightWidth(self, false)
            end
            return result
        end
    end

    installed = true
    debugPrint("[Gamepad QoL Suite NameColumn] CleanUI Name and Weight divider persistence enabled (client-side).")
    return true
end

CGUINameColumnPersistence.install = installHooks

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(installHooks)
end
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(installHooks)
end
