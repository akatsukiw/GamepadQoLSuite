-- Gamepad QoL Suite: controller-friendly trait selector for ISCharacterScreen.
-- X opens the selector. D-pad directions move the selection; B closes it.
-- Trait names, descriptions and icons come from CharacterTraitDefinition.

require "ISUI/ISPanel"
-- ISToolTip is provided by ISUI/ISToolTip; avoid probing the invalid root module path,
-- which produces a Kahlua "require failed" warning even inside pcall.
pcall(require, "ISUI/ISToolTip")

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then fn("panelInfo", message) end
end

local function isFeatureEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.panelInfoEnhancementEnabled
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok then return value == true end
    end
    return true
end

local function safeVisible(element)
    if not element then return false end
    local ok, visible = pcall(function() return element:getIsVisible() end)
    return not ok or visible == true
end

local function getTraitLabel(definition)
    local ok, value = pcall(function() return definition:getLabel() end)
    if ok and value ~= nil and tostring(value) ~= "" then return tostring(value) end
    ok, value = pcall(function() return definition:getUIName() end)
    if ok and value ~= nil and tostring(value) ~= "" then return tostring(value) end
    return "(?)"
end

local function getTraitDescription(definition)
    local ok, value = pcall(function() return definition:getDescription() end)
    if ok and value ~= nil then return tostring(value) end
    return ""
end

local function getTraitCost(definition)
    local ok, value = pcall(function() return definition:getCost() end)
    if ok and type(value) == "number" then return value end
    return 0
end

local function getTraitTexture(definition)
    local ok, value = pcall(function() return definition:getTexture() end)
    if ok then return value end
    return nil
end

local function getTraitListFont()
    -- AutoNormSmall is slightly more compact than Small and remains a native PZ UI font.
    if not UIFont then return nil end
    return UIFont.AutoNormSmall or UIFont.Small
end

local function measureText(text, font)
    local ok, width = pcall(function() return getTextManager():MeasureStringX(font, text) end)
    if ok and type(width) == "number" then return width end
    return #tostring(text or "") * 8
end

local function splitUtf8(text)
    local out, index = {}, 1
    while index <= #text do
        local first = string.byte(text, index) or 0
        local charLength = 1
        if first >= 240 then charLength = 4
        elseif first >= 224 then charLength = 3
        elseif first >= 192 then charLength = 2 end
        local last = math.min(#text, index + charLength - 1)
        out[#out + 1] = string.sub(text, index, last)
        index = last + 1
    end
    return out
end

local function fitLabel(text, maxWidth, font)
    text = tostring(text or "")
    if measureText(text, font) <= maxWidth then return text end
    local chars = splitUtf8(text)
    local out = ""
    for _, char in ipairs(chars) do
        if measureText(out .. char .. "…", font) > maxWidth then break end
        out = out .. char
    end
    return out .. "…"
end

local function getTraitDefinitions(screen)
    if screen and type(screen.traitsChanged) == "function" then
        local ok, changed = pcall(screen.traitsChanged, screen)
        if ok and changed and type(screen.loadTraits) == "function" then pcall(screen.loadTraits, screen) end
    elseif screen and type(screen.setDisplayedTraits) == "function" then
        pcall(screen.setDisplayedTraits, screen)
    end

    local definitions = screen and screen.displayedTraits
    if type(definitions) ~= "table" or #definitions == 0 then
        definitions = {}
        for _, image in ipairs((screen and screen.traits) or {}) do
            if image and image.trait then definitions[#definitions + 1] = image.trait end
        end
    end

    local groups = { good = {}, bad = {}, other = {} }
    for _, definition in ipairs(definitions) do
        local record = {
            definition = definition,
            label = getTraitLabel(definition),
            description = getTraitDescription(definition),
            texture = getTraitTexture(definition),
            cost = getTraitCost(definition),
        }
        if record.cost > 0 then
            record.group = "good"
            groups.good[#groups.good + 1] = record
        elseif record.cost < 0 then
            record.group = "bad"
            groups.bad[#groups.bad + 1] = record
        else
            record.group = "other"
            groups.other[#groups.other + 1] = record
        end
    end

    local function sortGroup(group)
        -- Sort by trait point value from smallest magnitude to largest.
        -- Negative-cost traits grant points, so compare their absolute cost.
        table.sort(group, function(a, b)
            local aa, bb = math.abs(a.cost or 0), math.abs(b.cost or 0)
            if aa ~= bb then return aa < bb end
            local la, lb = string.lower(a.label), string.lower(b.label)
            if la == lb then return a.label < b.label end
            return la < lb
        end)
    end
    sortGroup(groups.good)
    sortGroup(groups.bad)
    sortGroup(groups.other)
    return groups
end

local function getJoypadTexture(name)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    return textures and textures[name] or nil
end

local function textureSize(texture, maxSize)
    local width, height = maxSize, maxSize
    if texture then
        local okW, w = pcall(function() return texture:getWidth() end)
        local okH, h = pcall(function() return texture:getHeight() end)
        if okW and okH and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            local ratio = maxSize / math.max(w, h)
            width, height = w * ratio, h * ratio
        end
    end
    return width, height
end

local GQSTraitInfoSidePanel = ISPanel:derive("GQSTraitInfoSidePanel")

function GQSTraitInfoSidePanel:new(screen)
    local o = ISPanel.new(self, 0, 0, 400, 400)
    setmetatable(o, self)
    self.__index = self
    o.sourceScreen = screen
    o.goodTraits = {}
    o.badTraits = {}
    o.otherTraits = {}
    o.selectedColumn = nil
    o.selectedIndex = nil
    o.scrollRow = 0
    o.rowHeight = getTextManager():getFontHeight(getTraitListFont()) + 6
    o.headerHeight = 42
    o.background = true
    o.backgroundColor = { r = 0.015, g = 0.015, b = 0.015, a = 0.94 }
    o.borderColor = { r = 0.10, g = 0.62, b = 0.48, a = 1.0 }
    o.moveWithMouse = false
    return o
end

function GQSTraitInfoSidePanel:getContentTop()
    return self.headerHeight + 6
end

function GQSTraitInfoSidePanel:getVisibleRows()
    local available = math.max(0, self.height - self:getContentTop() - 10)
    return math.max(1, math.floor(available / math.max(1, self.rowHeight)))
end

function GQSTraitInfoSidePanel:getColumnItems(column)
    if column == "bad" then return self.badTraits end
    return self.leftTraits
end

function GQSTraitInfoSidePanel:getColumnX(column)
    local padding = 10
    local gap = 12
    local colWidth = (self.width - padding * 2 - gap) / 2
    if column == "bad" then return padding + colWidth + gap end
    return padding
end

function GQSTraitInfoSidePanel:getColumnWidth()
    return (self.width - 20 - 12) / 2
end

function GQSTraitInfoSidePanel:getTotalRows()
    return math.max(#(self.leftTraits or {}), #(self.badTraits or {}))
end

function GQSTraitInfoSidePanel:clampScroll()
    self.scrollRow = math.max(0, math.min(self.scrollRow or 0, self:getTotalRows() - self:getVisibleRows()))
end

function GQSTraitInfoSidePanel:ensureSelectionVisible()
    if not self.selectedIndex then return end
    local visibleRows = self:getVisibleRows()
    if self.selectedIndex - 1 < self.scrollRow then
        self.scrollRow = self.selectedIndex - 1
    elseif self.selectedIndex > self.scrollRow + visibleRows then
        self.scrollRow = self.selectedIndex - visibleRows
    end
    self:clampScroll()
end

function GQSTraitInfoSidePanel:hideTraitTooltip()
    local tooltip = self.traitTooltip
    if tooltip then
        pcall(function() tooltip:setVisible(false) end)
        pcall(function() tooltip:removeFromUIManager() end)
    end
end

function GQSTraitInfoSidePanel:showSelectedTraitTooltip()
    local items = self:getColumnItems(self.selectedColumn)
    local record = self.selectedIndex and items[self.selectedIndex] or nil
    if not record then
        self:hideTraitTooltip()
        return
    end

    local ISToolTipClass = rawget(_G, "ISToolTip")
    if not ISToolTipClass or type(ISToolTipClass.new) ~= "function" then
        log("ISToolTip is unavailable; selected trait description cannot use the native tooltip", true)
        return
    end

    if not self.traitTooltip then
        local ok, tooltip = pcall(ISToolTipClass.new, ISToolTipClass)
        if not ok or not tooltip then
            log("Unable to create native ISToolTip for selected trait", true)
            return
        end
        self.traitTooltip = tooltip
        pcall(function() tooltip:setOwner(self) end)
        pcall(function() tooltip:setVisible(false) end)
        pcall(function() tooltip:setAlwaysOnTop(true) end)
        tooltip.followMouse = false
        -- Match the native ISImage tooltip layout used by ISCharacterScreen:
        -- it calls setMouseOverText(label .. "\n" .. description) and does not
        -- assign a separate tooltip title. The empty title added in 1.5.1.0-1.5.1.4
        -- could leave the native ISToolTip title row reserved but blank.
        tooltip.name = nil
        tooltip.nameMarginX = 0
        tooltip.defaultMyWidth = 0
        tooltip.maxLineWidth = 360
    end

    local tooltip = self.traitTooltip
    -- Gamepad selection must show the same label + newline + description payload
    -- without requiring physical mouse hover. Keep the native tooltip untitled.
    tooltip.name = nil
    tooltip.description = tostring(record.label or "") .. "\n" .. tostring(record.description or "")
    if not safeVisible(tooltip) then
        pcall(function() tooltip:addToUIManager() end)
        pcall(function() tooltip:setVisible(true) end)
    elseif type(tooltip.addToUIManager) == "function" then
        pcall(function() tooltip:addToUIManager() end)
    end
    self:updateTraitTooltipPosition()
end

function GQSTraitInfoSidePanel:updateTraitTooltipPosition()
    local tooltip = self.traitTooltip
    if not tooltip or not safeVisible(tooltip) or not self.selectedIndex or not self.selectedColumn then return end
    local panelX, panelY = self:getAbsoluteX(), self:getAbsoluteY()
    local rowY = self:getContentTop() + (self.selectedIndex - 1 - self.scrollRow) * self.rowHeight
    local left, top, viewportWidth, viewportHeight = getPlayerScreenLeft and getPlayerScreenLeft(self.sourceScreen.playerNum) or 0,
        getPlayerScreenTop and getPlayerScreenTop(self.sourceScreen.playerNum) or 0,
        getPlayerScreenWidth and getPlayerScreenWidth(self.sourceScreen.playerNum) or 1280,
        getPlayerScreenHeight and getPlayerScreenHeight(self.sourceScreen.playerNum) or 720
    left, top = tonumber(left) or 0, tonumber(top) or 0
    viewportWidth, viewportHeight = tonumber(viewportWidth) or 1280, tonumber(viewportHeight) or 720
    local expectedWidth = math.min(440, math.max(280, self.width))
    local x = panelX + self.width + 6
    if x + expectedWidth > left + viewportWidth - 4 then x = panelX - expectedWidth - 6 end
    if x < left + 4 then x = math.max(left + 4, left + viewportWidth - expectedWidth - 4) end
    local y = panelY + rowY
    y = math.max(top + 4, math.min(y, top + viewportHeight - 100))
    if type(tooltip.setDesiredPosition) == "function" then
        pcall(tooltip.setDesiredPosition, tooltip, math.floor(x), math.floor(y))
    else
        pcall(tooltip.setX, tooltip, math.floor(x))
        pcall(tooltip.setY, tooltip, math.floor(y))
    end
end

function GQSTraitInfoSidePanel:rebuildTraits(preserveSelection)
    local oldColumn, oldIndex, oldLabel = self.selectedColumn, self.selectedIndex, nil
    if oldColumn and oldIndex then
        local oldItems = self:getColumnItems(oldColumn)
        oldLabel = oldItems[oldIndex] and oldItems[oldIndex].label or nil
    end

    local groups = getTraitDefinitions(self.sourceScreen)
    self.goodTraits, self.badTraits, self.otherTraits = groups.good, groups.bad, groups.other
    -- The UI has exactly two columns: positive/zero-cost traits on the left,
    -- negative-cost traits on the right. Zero-cost/profession traits remain visible
    -- at the bottom of the left column in neutral white rather than being omitted.
    self.leftTraits = {}
    for _, record in ipairs(groups.good) do self.leftTraits[#self.leftTraits + 1] = record end
    for _, record in ipairs(groups.other) do self.leftTraits[#self.leftTraits + 1] = record end

    if preserveSelection and oldLabel then
        local target = oldColumn == "bad" and self.badTraits or self.leftTraits
        local found
        for i, record in ipairs(target) do
            if record.label == oldLabel then found = i; break end
        end
        if found then
            self.selectedColumn, self.selectedIndex = oldColumn, found
        else
            self.selectedColumn, self.selectedIndex = nil, nil
        end
    else
        self.selectedColumn, self.selectedIndex = nil, nil
    end
    self:clampScroll()
    self:ensureSelectionVisible()
    self:showSelectedTraitTooltip()
end

function GQSTraitInfoSidePanel:moveSelection(direction)
    local column = self.selectedColumn or "good"
    local index = self.selectedIndex
    local items = self:getColumnItems(column)

    if direction == "left" or direction == "right" then
        local targetColumn = direction == "left" and "good" or "bad"
        local targetItems = self:getColumnItems(targetColumn)
        if #targetItems == 0 then return true end
        local targetIndex = math.min(index or 1, #targetItems)
        self.selectedColumn, self.selectedIndex = targetColumn, targetIndex
    else
        if #items == 0 then
            local fallback = column == "good" and "bad" or "good"
            local fallbackItems = self:getColumnItems(fallback)
            if #fallbackItems == 0 then return true end
            column, items = fallback, fallbackItems
        end
        -- Keep vertical navigation cyclic within the current column. This lets
        -- players reach the last trait immediately by pressing Up on the first
        -- trait, and return to the first trait by pressing Down on the last one.
        -- X already opens with the first available trait selected; the no-index
        -- fallback also respects the requested direction if state is reset.
        self.selectedColumn = column
        if direction == "up" then
            if not index then
                index = #items
            elseif index <= 1 then
                index = #items
            else
                index = index - 1
            end
        else -- direction == "down"
            if not index or index >= #items then
                index = 1
            else
                index = index + 1
            end
        end
        self.selectedIndex = index
    end

    self:ensureSelectionVisible()
    self:showSelectedTraitTooltip()
    return true
end

function GQSTraitInfoSidePanel:render()
    ISPanel.render(self)
    local font = getTraitListFont()
    local manager = getTextManager()
    local fontHeight = manager:getFontHeight(font)
    local title = getText("UI_GQOS_TraitInfoTitle")
    local closeLabel = getText("UI_GQOS_TraitInfoHint")
    if closeLabel == "UI_GQOS_TraitInfoHint" or closeLabel == nil or closeLabel == "" then closeLabel = "关闭" end
    self:drawText(title, 10, math.floor((self.headerHeight - manager:getFontHeight(UIFont.Medium)) / 2), 1, 1, 1, 1, UIFont.Medium)

    -- Use the same native controller textures as the Build/Handcraft header prompts.
    local bTexture = getJoypadTexture("BButton")
    local bW, bH = textureSize(bTexture, 18)
    local closeWidth = measureText(closeLabel, font)
    local iconGap, rightPadding = 5, 10
    local closeX = self.width - rightPadding - closeWidth - iconGap - bW
    local closeY = math.floor((self.headerHeight - math.max(bH, manager:getFontHeight(font))) / 2)
    if bTexture then
        pcall(self.drawTextureScaled, self, bTexture, closeX, closeY, bW, bH, 1, 1, 1, 1)
    else
        self:drawText("B", closeX, closeY, 1, 1, 1, 1, font)
        closeX = closeX + measureText("B", font) + 2
    end
    self:drawText(closeLabel, closeX + (bTexture and bW + iconGap or 0),
        math.floor((self.headerHeight - manager:getFontHeight(font)) / 2), 0.90, 0.90, 0.90, 1, font)
    self:drawRect(8, self.headerHeight - 3, self.width - 16, 1, 0.75, 0.22, 0.48, 0.40)

    local contentTop = self:getContentTop()
    local availableHeight = math.max(0, self.height - contentTop - 8)
    local colWidth = self:getColumnWidth()
    local rowHeight = self.rowHeight
    local iconSize = 18
    local columns = { { name = "good", items = self.leftTraits or {} }, { name = "bad", items = self.badTraits or {} } }
    local visibleRows = self:getVisibleRows()

    pcall(function() self:setStencilRect(8, contentTop, self.width - 16, availableHeight) end)
    for _, column in ipairs(columns) do
        local x = self:getColumnX(column.name)
        for i, record in ipairs(column.items) do
            local visibleIndex = i - 1 - self.scrollRow
            if visibleIndex >= 0 and visibleIndex < visibleRows then
                local y = contentTop + visibleIndex * rowHeight
                local selected = self.selectedColumn == column.name and self.selectedIndex == i
                if selected then
                    self:drawRect(x - 2, y, colWidth, rowHeight - 1, 0.45, 0.12, 0.34, 0.30)
                    self:drawRectBorder(x - 2, y, colWidth, rowHeight - 1, 0.8, 0.22, 0.78, 0.65)
                end
                if record.texture then
                    pcall(self.drawTextureScaled, self, record.texture, x + 2, y + math.floor((rowHeight - iconSize) / 2),
                        iconSize, iconSize, 1, 1, 1, 1)
                end
                local textX = x + iconSize + 8
                local availableWidth = colWidth - iconSize - 14
                local label = fitLabel(record.label, availableWidth, font)
                local r, g, b = 0.90, 0.91, 0.90
                if record.group == "good" then r, g, b = 0.40, 0.98, 0.48
                elseif record.group == "bad" then r, g, b = 1.00, 0.36, 0.35 end
                self:drawText(label, textX, y + math.floor((rowHeight - fontHeight) / 2), r, g, b, 1, font)
            end
        end
    end
    pcall(function() self:clearStencilRect() end)

    self:drawRect(8 + colWidth + 6, contentTop, 1, math.max(0, availableHeight), 0.35, 0.38, 0.38, 0.38)
    local totalRows = self:getTotalRows()
    local maxScroll = math.max(0, totalRows - visibleRows)
    if maxScroll > 0 then
        local trackX = self.width - 6
        local trackY = contentTop + 2
        local trackH = availableHeight - 4
        local thumbH = math.max(18, trackH * visibleRows / math.max(visibleRows, totalRows))
        local thumbY = trackY + (self.scrollRow / maxScroll) * math.max(0, trackH - thumbH)
        self:drawRect(trackX, trackY, 2, trackH, 0.45, 0.48, 0.48, 0.48)
        self:drawRect(trackX - 1, thumbY, 4, thumbH, 0.8, 0.76, 0.78, 0.76)
    end
    self:updateTraitTooltipPosition()
end

function GQSTraitInfoSidePanel:onMouseWheel(del)
    local delta = tonumber(del) or 0
    self.scrollRow = math.max(0, math.min(self:getTotalRows() - self:getVisibleRows(), self.scrollRow - (delta > 0 and 2 or -2)))
    self:updateTraitTooltipPosition()
    return true
end

local openScreens = {}

local function getHostWindow(screen)
    local current = screen
    for _ = 1, 6 do
        local parent = current and current.parent
        if not parent then break end
        local ok, childPanel = pcall(function() return parent.panel end)
        if ok and childPanel == current then return parent end
        current = parent
    end
    return screen and screen.parent and screen.parent.parent or screen
end

local function getViewport(screen)
    local playerNum = tonumber(screen and screen.playerNum) or 0
    local left, top, width, height = 0, 0, nil, nil
    if type(getPlayerScreenLeft) == "function" then
        local ok, value = pcall(getPlayerScreenLeft, playerNum)
        if ok and type(value) == "number" then left = value end
    end
    if type(getPlayerScreenTop) == "function" then
        local ok, value = pcall(getPlayerScreenTop, playerNum)
        if ok and type(value) == "number" then top = value end
    end
    if type(getPlayerScreenWidth) == "function" then
        local ok, value = pcall(getPlayerScreenWidth, playerNum)
        if ok and type(value) == "number" and value > 0 then width = value end
    end
    if type(getPlayerScreenHeight) == "function" then
        local ok, value = pcall(getPlayerScreenHeight, playerNum)
        if ok and type(value) == "number" and value > 0 then height = value end
    end
    local core = rawget(_G, "getCore") and getCore() or nil
    if not width and core and type(core.getScreenWidth) == "function" then
        local ok, value = pcall(core.getScreenWidth, core)
        if ok and type(value) == "number" then width = value end
    end
    if not height and core and type(core.getScreenHeight) == "function" then
        local ok, value = pcall(core.getScreenHeight, core)
        if ok and type(value) == "number" then height = value end
    end
    return left, top, width or 1280, height or 720
end

local function isScreenActive(screen)
    if not screen or not safeVisible(screen) then return false end
    local parent = screen.parent
    if parent and type(parent.getActiveView) == "function" then
        local ok, activeView = pcall(parent.getActiveView, parent)
        if ok and activeView ~= nil and activeView ~= screen then return false end
    end
    local host = getHostWindow(screen)
    if host and host ~= screen and not safeVisible(host) then return false end
    if host and host.isCollapsed == true then return false end
    return true
end

-- The X prompt label depends on whether the selector is currently open. Kept in
-- one place so the nutrition readout can measure the space it occupies and sit
-- to its left without duplicating the wording.
local function getTraitHint(screen)
    if not isFeatureEnabled() or not isScreenActive(screen) then return nil end
    local sidePanelOpen = screen._gqsTraitInfoSidePanel and safeVisible(screen._gqsTraitInfoSidePanel)
    local hint = getText(sidePanelOpen and "UI_GQOS_TraitCloseHint" or "UI_GQOS_TraitOpenHint")
    if hint == "UI_GQOS_TraitCloseHint" or hint == "UI_GQOS_TraitOpenHint" or hint == nil or hint == "" then
        hint = sidePanelOpen and "关闭详情" or "特质信息"
    end
    return hint
end

-- ---------------------------------------------------------------------------
-- Bottom-right controller prompts
-- ---------------------------------------------------------------------------
-- The trait prompt and the nutrition prompt share this corner, so both use the
-- same row geometry: a row is as tall as the taller of the icon box and the font
-- line, and each part is centred inside it with (rowHeight - partHeight) / 2 --
-- the rule the Build/Handcraft header prompts already use.
--
-- Deriving the icon position from the icon height alone only lines up while the
-- icon happens to be taller than the font; the moment UI scaling makes the font
-- taller the icon sticks to the top of the row and the pair looks misaligned.
--
-- GQSNutritionInfoPanel keeps its own copy of these two helpers on purpose, so
-- either module can be switched off without breaking the other's prompt.
local PROMPT_ICON_SIZE = 18
local PROMPT_GAP = 5
local PROMPT_RIGHT_PADDING = 10
local PROMPT_BOTTOM_PADDING = 7
local PROMPT_ROW_SPACING = 4

-- One row height for every prompt, independent of the individual icon aspect
-- ratio, so stacked rows stay evenly spaced.
local function getPromptRowHeight(font)
    return math.max(PROMPT_ICON_SIZE, getTextManager():getFontHeight(font))
end

local function getBottomRowTop(element, font)
    return (element.height or 420) - getPromptRowHeight(font) - PROMPT_BOTTOM_PADDING
end

-- Right-aligned "icon + label" prompt, vertically centred in its row.
local function drawPromptRow(element, label, texture, fallbackIcon, rowTop, font)
    local rowHeight = getPromptRowHeight(font)
    local iconW, iconH = textureSize(texture, PROMPT_ICON_SIZE)
    local manager = getTextManager()
    local textWidth = manager:MeasureStringX(font, label)
    local rightEdge = (element.width or 360) - PROMPT_RIGHT_PADDING
    local leftX = rightEdge - (iconW + PROMPT_GAP + textWidth)

    local iconY = rowTop + math.floor((rowHeight - iconH) / 2)
    local textY = rowTop + math.floor((rowHeight - manager:getFontHeight(font)) / 2)

    if texture then
        pcall(element.drawTextureScaled, element, texture, leftX, iconY, iconW, iconH, 1, 1, 1, 1)
    else
        pcall(element.drawText, element, fallbackIcon, leftX, textY, 1, 1, 1, 1, font)
    end
    pcall(element.drawText, element, label, leftX + iconW + PROMPT_GAP, textY, 0.90, 0.90, 0.90, 1, font)
end

local function positionSidePanel(screen, panel)
    local host = getHostWindow(screen)
    local left, top, viewportWidth, viewportHeight = getViewport(screen)
    local hostX, hostY, hostWidth, hostHeight = left + 8, top + 8, screen.width or 360, screen.height or 420
    if host then
        if type(host.getAbsoluteX) == "function" then
            local ok, value = pcall(host.getAbsoluteX, host)
            if ok and type(value) == "number" then hostX = value end
        end
        if type(host.getAbsoluteY) == "function" then
            local ok, value = pcall(host.getAbsoluteY, host)
            if ok and type(value) == "number" then hostY = value end
        end
        if type(host.getWidth) == "function" then
            local ok, value = pcall(host.getWidth, host)
            if ok and type(value) == "number" then hostWidth = value end
        end
        if type(host.getHeight) == "function" then
            local ok, value = pcall(host.getHeight, host)
            if ok and type(value) == "number" then hostHeight = value end
        end
    end

    -- Compact two-column selector: enough room for both names, not a prose wall.
    local panelWidth = math.min(440, math.max(320, math.floor(viewportWidth * 0.34)))
    local panelX = hostX + hostWidth
    local rightEdge = left + viewportWidth
    if panelX + panelWidth > rightEdge - 4 then
        local leftX = hostX - panelWidth
        if leftX >= left + 4 then panelX = leftX
        else panelX = math.max(left + 4, rightEdge - panelWidth - 4) end
    end

    local panelY = math.max(top + 4, hostY)
    local bottomEdge = top + viewportHeight
    -- Match the height of the existing character information window.
    local panelHeight = math.max(220, math.min(hostHeight, bottomEdge - panelY - 4))
    panel:setX(math.floor(panelX))
    panel:setY(math.floor(panelY))
    panel:setWidth(math.floor(panelWidth))
    panel:setHeight(math.floor(panelHeight))
    panel:clampScroll()
end

local function closePanel(screen)
    local panel = screen and screen._gqsTraitInfoSidePanel
    if panel then
        panel:hideTraitTooltip()
        pcall(function() panel:setVisible(false) end)
        pcall(function() panel:removeFromUIManager() end)
    end
    openScreens[screen] = nil
end

local function openPanel(screen)
    if not isFeatureEnabled() or not isScreenActive(screen) then return false end

    -- Mutually exclusive with the Y nutrition readout.
    local nutrition = rawget(_G, "GQSNutritionInfo")
    if nutrition and type(nutrition.close) == "function" then
        pcall(nutrition.close, screen)
    end

    local panel = screen._gqsTraitInfoSidePanel
    if not panel then
        panel = GQSTraitInfoSidePanel:new(screen)
        panel:initialise()
        panel:setVisible(false)
        screen._gqsTraitInfoSidePanel = panel
    end
    panel.sourceScreen = screen
    panel.scrollRow = 0
    panel.selectedColumn, panel.selectedIndex = nil, nil
    positionSidePanel(screen, panel)
    panel:rebuildTraits(false)
    -- Opening X immediately focuses the first positive trait and shows its tooltip.
    if #(panel.leftTraits or {}) > 0 then
        panel.selectedColumn, panel.selectedIndex = "good", 1
        panel:ensureSelectionVisible()
        panel:showSelectedTraitTooltip()
    elseif #(panel.badTraits or {}) > 0 then
        panel.selectedColumn, panel.selectedIndex = "bad", 1
        panel:ensureSelectionVisible()
        panel:showSelectedTraitTooltip()
    end
    panel:addToUIManager()
    panel:setVisible(true)
    openScreens[screen] = true
    log("Opened two-column gamepad trait selector for player " .. tostring(screen.playerNum))
    return true
end

local function closeOpenPanels()
    local screens = {}
    for screen in pairs(openScreens) do screens[#screens + 1] = screen end
    for _, screen in ipairs(screens) do closePanel(screen) end
end

-- Exposed so the nutrition readout can close this panel when it opens, and can
-- stack its own Y prompt directly above the X prompt.
GQSTraitInfo = {
    close = closePanel,
    -- Where the X prompt currently sits. Returns nil when it is not drawn, which
    -- tells the nutrition readout to fall back to the bottom-right corner.
    promptLayout = function(screen)
        local hint = getTraitHint(screen)
        if not hint then return nil end
        local font = UIFont and UIFont.Small
        if not font then return nil end
        return {
            rowTop = getBottomRowTop(screen, font),
            rowHeight = getPromptRowHeight(font),
            spacing = PROMPT_ROW_SPACING,
        }
    end,
}

local function install()
    pcall(require, "XpSystem/ISUI/ISCharacterScreen")
    local CharacterScreen = rawget(_G, "ISCharacterScreen")
    if not CharacterScreen then
        pcall(require, "ISUI/ISCharacterScreen")
        CharacterScreen = rawget(_G, "ISCharacterScreen")
    end
    if not CharacterScreen then return false end
    if CharacterScreen._gqsTraitInfoGamepadInstalled then return true end

    local originalDown = CharacterScreen.onJoypadDown
    if type(originalDown) == "function" then
        CharacterScreen.onJoypadDown = function(self, button, ...)
            local xButton = Joypad and Joypad.XButton
            local bButton = Joypad and Joypad.BButton
            local lbButton = Joypad and Joypad.LBumper
            local rbButton = Joypad and Joypad.RBumper
            local panel = self._gqsTraitInfoSidePanel
            local isOpen = panel and safeVisible(panel)

            if not isFeatureEnabled() then
                if isOpen then closePanel(self) end
                return originalDown(self, button, ...)
            end
            if button == xButton and isScreenActive(self) then
                if isOpen then closePanel(self) else openPanel(self) end
                return
            end
            if isOpen and button == bButton then
                closePanel(self)
                return
            end
            if isOpen and (button == lbButton or button == rbButton) then
                closePanel(self)
            end
            return originalDown(self, button, ...)
        end
    end

    for _, direction in ipairs({ "Up", "Down", "Left", "Right" }) do
        local methodName = "onJoypadDir" .. direction
        local directionName = string.lower(direction)
        local original = CharacterScreen[methodName]
        if type(original) == "function" then
            CharacterScreen[methodName] = function(self, joypadData, ...)
                local panel = self._gqsTraitInfoSidePanel
                if isFeatureEnabled() and panel and safeVisible(panel) and isScreenActive(self) then
                    panel:moveSelection(directionName)
                    return
                end
                return original(self, joypadData, ...)
            end
        end
    end

    local originalRender = CharacterScreen.render
    if type(originalRender) == "function" and not CharacterScreen._gqsTraitInfoHintInstalled then
        CharacterScreen.render = function(self, ...)
            local result = { originalRender(self, ...) }
            local hint = getTraitHint(self)
            if hint then
                local font = UIFont.Small
                drawPromptRow(self, hint, getJoypadTexture("XButton"), "X",
                    getBottomRowTop(self, font), font)
            end
            return unpack(result)
        end
        CharacterScreen._gqsTraitInfoHintInstalled = true
    end

    CharacterScreen._gqsTraitInfoGamepadInstalled = true
    log("Installed X-toggle two-column trait selector on ISCharacterScreen")
    return true
end

install()
if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        local CharacterScreen = rawget(_G, "ISCharacterScreen")
        if not CharacterScreen or not CharacterScreen._gqsTraitInfoGamepadInstalled then install() end
        if not isFeatureEnabled() then
            if next(openScreens) ~= nil then closeOpenPanels() end
            return
        end
        local screens = {}
        for screen in pairs(openScreens) do screens[#screens + 1] = screen end
        for _, screen in ipairs(screens) do
            local panel = screen and screen._gqsTraitInfoSidePanel
            if not isScreenActive(screen) or not panel or not safeVisible(panel) then
                closePanel(screen)
            else
                positionSidePanel(screen, panel)
                local changed = false
                if type(screen.traitsChanged) == "function" then
                    local ok, value = pcall(screen.traitsChanged, screen)
                    changed = ok and value == true
                    if changed and type(screen.loadTraits) == "function" then pcall(screen.loadTraits, screen) end
                end
                if changed then panel:rebuildTraits(true) end
                panel:updateTraitTooltipPosition()
            end
        end
    end)
end
