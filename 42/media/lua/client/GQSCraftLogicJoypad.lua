-- Gamepad QoL Suite: joypad navigation for the CraftLogic panel (v1.5.9.1).
--
-- 皮革晾晒架（entity DryingRackLarge / Medium / Small）用的是 ISCraftLogicPanel。
-- 这个面板原版完全没有手柄装配：没有 onGainJoypadFocus、没有 joypadNavigate、
-- 没有 onJoypadDown、render 里也不画导航覆盖层。焦点虽然被 ISEntityWindow 交进来了，
-- 但停在面板本身，子控件一个都拿不到，所以打开后只能按 B 退出。
--
-- 同目录的 ISCraftBenchPanel（软化梁 / 单宁桶）有完整的四件套，这里照它的结构补齐。
-- 面板的真实视觉布局是 3 列 2 行：
--   ┌──────────┬──────────────┬────────────┐
--   │ 配方列表  │ 输入/制作/输出│ 可用物品    │
--   │          ├──────────────┼────────────┤
--   │          │ 进行中/完成   │ 已包含物品  │
--   └──────────┴──────────────┴────────────┘

-- TEMPORARY: set GQSDebugLog.lua craftLogic back to false once the material
-- auto-add path is confirmed working in game.
local LOG_CATEGORY = "craftLogic"

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then fn(LOG_CATEGORY, message) end
end


pcall(require, "Entity/ISUI/Components/Crafting/ISCraftLogicPanel")

local CraftLogicPanel = rawget(_G, "ISCraftLogicPanel")
if type(CraftLogicPanel) ~= "table" or CraftLogicPanel._gqsCraftLogicJoypadInstalled then
    return
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function safeIndex(object, key)
    if type(object) ~= "table" then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function isStickPress(button, name)
    local joypad = rawget(_G, "Joypad")
    return joypad ~= nil and joypad[name] ~= nil and button == joypad[name]
end

local function isJoypadButton(button, name, fallbackKey)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad[name] ~= nil and button == joypad[name] then return true end
    local buttons = rawget(_G, "JoypadButton")
    if buttons and fallbackKey and buttons[fallbackKey] ~= nil and button == buttons[fallbackKey] then
        return true
    end
    return false
end

local function isReallyVisible(element)
    if type(element) ~= "table" then return false end
    local ok, value = pcall(function() return element:isReallyVisible() end)
    return ok and value == true
end

local function getRecipeList(self)
    return safeIndex(safeIndex(safeIndex(self, "recipesPanel"), "recipeListPanel"), "recipeListPanel")
end

-- "可用物品" 列
local function getInventoryList(self)
    return safeIndex(safeIndex(self, "inventoryPanel"), "itemListBox")
end

-- "已包含物品" 列
local function getContainedList(self)
    return safeIndex(safeIndex(self, "resourceInventoryPanel"), "itemListBox")
end

local function getInputControl(self)
    return safeIndex(safeIndex(self, "recipePanel"), "inputControlWidget")
end

local function getCraftControl(self)
    return safeIndex(getInputControl(self), "controlWidget")
end

local function getTakeButton(self)
    return safeIndex(safeIndex(safeIndex(self, "recipePanel"), "outputProgressWidget"), "buttonTake")
end

local function getPlayerNum(self)
    local playerNum = tonumber(safeIndex(self, "playerNum"))
    if playerNum then return playerNum end
    local player = safeIndex(self, "player")
    if player and type(player.getPlayerNum) == "function" then
        local ok, value = pcall(player.getPlayerNum, player)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function setFocus(joypadData, target)
    if not joypadData or type(target) ~= "table" then return false end
    joypadData.focus = target
    if type(updateJoypadFocus) == "function" then pcall(updateJoypadFocus, joypadData) end
    return true
end

local function isManualPickerShown(self)
    local logic = safeIndex(getInputControl(self), "logic")
    if not logic or type(logic.shouldShowManualSelectInputs) ~= "function" then return false end
    local ok, value = pcall(logic.shouldShowManualSelectInputs, logic)
    return ok and value == true
end

-- ---------------------------------------------------------------------------
-- X: the manual input picker (that little arrow on the input slot)
-- ---------------------------------------------------------------------------
local function toggleInputPicker(self)
    local panel = safeIndex(getInputControl(self), "inputItems")
    if type(panel) ~= "table" or type(panel.getItemSlots) ~= "function" then return false end

    local okSlots, slots = pcall(panel.getItemSlots, panel)
    if not okSlots or type(slots) ~= "table" then return false end

    for _, slot in ipairs(slots) do
        if slot.selectInputButton ~= nil and type(slot.onSelectInputsButton) == "function" then
            local ok, err = pcall(slot.onSelectInputsButton, slot)
            if ok then
                log("X: toggled the manual input picker")
                return true
            end
            log("X: input picker failed: " .. tostring(err), true)
        end
    end
    return false
end

-- Opens the picker (or reuses it if already open) and moves focus to the
-- material list, so the next A puts the item in. The visibility of the list is
-- driven by the logic flag, not by isReallyVisible(): the java object only
-- reports visible after a render pass, so checking it here would skip the focus
-- jump on the very frame the picker opens.
local function openInputPicker(self, joypadData)
    if not isManualPickerShown(self) then
        if not toggleInputPicker(self) then return false end
    end
    setFocus(joypadData, getInventoryList(self))
    return true
end

-- ---------------------------------------------------------------------------
-- Crafting straight from the material list
-- ---------------------------------------------------------------------------
local function craftNow(self)
    local button = safeIndex(getCraftControl(self), "buttonCraft")
    if type(button) ~= "table" then return false end
    if button.enable == false then
        log("X: craft button is disabled (missing materials or already running)")
        return false
    end
    if type(button.forceClick) ~= "function" then return false end
    local ok, err = pcall(button.forceClick, button)
    if not ok then
        log("X: craft failed: " .. tostring(err), true)
        return false
    end
    log("X: started crafting")
    return true
end

-- ---------------------------------------------------------------------------
-- X: one key for "put the material in" and then "craft"
-- ---------------------------------------------------------------------------
-- True when this inventory item is already sitting in an input slot. Pressing X
-- again must move on to the next material instead of toggling the first one
-- back out (onListItemClicked treats a second click as "remove").
local function isAlreadyAssigned(self, inventoryItem)
    local logic = safeIndex(getInputControl(self), "logic")
    if not logic or type(logic.getRecipeData) ~= "function" then return false end
    local okData, data = pcall(logic.getRecipeData, logic)
    if not okData or type(data) ~= "table" or type(data.containsInputItem) ~= "function" then
        return false
    end
    local ok, value = pcall(data.containsInputItem, data, inventoryItem)
    return ok and value == true
end

local function tryAddFirstMaterial(self)
    local panel = safeIndex(self, "inventoryPanel")
    local list = safeIndex(panel, "itemListBox")
    if type(list) ~= "table" or type(list.items) ~= "table" then return false end
    if type(panel.onListItemClicked) ~= "function" then return false end

    for _, entry in ipairs(list.items) do
        local data = entry and entry.item
        if type(data) == "table"
            and data.inventoryItem ~= nil
            and not data.isHeader
            and not data.isNode
            and not data.isUnavailable
            then
            if isAlreadyAssigned(self, data.inventoryItem) then
                log("X: skipping an already assigned material")
            else
                local ok, err = pcall(panel.onListItemClicked, panel, data)
                if ok then
                    log("X: added an available material")
                    return true
                end
                log("X: adding the material failed: " .. tostring(err), true)
                return false
            end
        end
    end
    return false
end

-- Diagnostic dump of the material list rows. The list only contains child rows
-- for nodes that are currently expanded, so a freshly opened panel usually shows
-- header + collapsed node and nothing else -- which is exactly why a plain
-- "find a row with an inventory item" walk finds nothing.
local function describeEntry(index, entry)
    local data = entry and entry.item
    if type(data) ~= "table" then return tostring(index) .. "=nodata" end
    return string.format("%d[%s%s%s%s]", index,
        data.isHeader and "H" or "-",
        data.isNode and "N" or "-",
        data.inventoryItem and "I" or "-",
        data.isUnavailable and "U" or "-")
end

local function logListState(self, tag)
    local list = safeIndex(safeIndex(self, "inventoryPanel"), "itemListBox")
    if type(list) ~= "table" or type(list.items) ~= "table" then
        log(tag .. ": no item list")
        return
    end
    local parts = {}
    for index, entry in ipairs(list.items) do
        parts[#parts + 1] = describeEntry(index, entry)
    end
    log(tag .. ": " .. tostring(#list.items) .. " rows " .. table.concat(parts, " "))
end

-- A node row ("大型原始皮（湿）(4)") holds the script item, not an inventory
-- item, and its children only appear once the node is expanded. Expanding it is
-- what a double click on that row does, so do the same and repopulate.
local function expandFirstNode(self)
    local panel = safeIndex(self, "inventoryPanel")
    local list = safeIndex(panel, "itemListBox")
    if type(list) ~= "table" or type(list.items) ~= "table" then return false end

    for index, entry in ipairs(list.items) do
        local data = entry and entry.item
        if type(data) == "table" and data.isNode and data.node ~= nil then
            local node = data.node
            local expanded = false
            if type(node.setExpandedAvailable) == "function" then
                local ok = pcall(node.setExpandedAvailable, node, true)
                expanded = ok or expanded
            end
            if type(node.setExpandedUsed) == "function" then
                pcall(node.setExpandedUsed, node, true)
            end
            log("X: expanding node row " .. tostring(index)
                .. " nodeType=" .. type(node) .. " expanded=" .. tostring(expanded))
            if expanded and type(panel.populate) == "function" then
                pcall(panel.populate, panel)
                return true
            end
            return false
        end
    end
    log("X: no node row found to expand")
    return false
end

-- The material list is an ISScrollingListBox whose entries carry the real
-- inventory item. ISCraftInventoryPanel:onListItemClicked() is the single entry
-- point the mouse uses to add or remove one, so calling it directly gives us
-- exactly the same behaviour as clicking the row -- no reimplementation.
local function addFirstAvailableMaterial(self)
    logListState(self, "X: before")

    if tryAddFirstMaterial(self) then return true end

    -- Nothing addable at the top level: the node is collapsed. Expand it.
    if expandFirstNode(self) then
        logListState(self, "X: after expand")
        if tryAddFirstMaterial(self) then return true end
    end

    -- Last resort: the list was never populated at all.
    local panel = safeIndex(self, "inventoryPanel")
    if type(panel) == "table" and type(panel.populate) == "function" then
        pcall(panel.populate, panel)
        logListState(self, "X: after populate")
        if tryAddFirstMaterial(self) then return true end
    end

    log("X: no unassigned material available")
    return false
end

local function isCraftReady(self)
    local button = safeIndex(getCraftControl(self), "buttonCraft")
    return type(button) == "table" and button.enable ~= false
end

-- Craft when the craft button is live, otherwise drop the next usable material
-- into an input slot. Works from the recipe list and from the material list.
local function smartX(self, joypadData)
    if isCraftReady(self) then
        return craftNow(self)
    end
    return addFirstAvailableMaterial(self)
end

-- ---------------------------------------------------------------------------
-- L3: cycle the recipe sort order (the sort combo box itself)
-- ---------------------------------------------------------------------------
-- ISComboBox:select() only sets `selected`, it never fires the change callback,
-- so OnClickSortType has to be called by hand. That callback is what reaches
-- setSortMode() on this panel.
local function cycleSortMode(self)
    local filterPanel = safeIndex(safeIndex(self, "recipesPanel"), "recipeFilterPanel")
    local combo = safeIndex(filterPanel, "sortCombo")
    if type(combo) ~= "table" then
        log("L3: no sort combo box on this panel")
        return false
    end
    local options = safeIndex(combo, "options")
    if type(options) ~= "table" or #options == 0 then
        log("L3: sort combo has no options yet")
        return false
    end

    local selected = tonumber(safeIndex(combo, "selected")) or 0
    selected = selected % #options + 1
    combo.selected = selected

    if type(filterPanel.OnClickSortType) == "function" then
        local ok, err = pcall(filterPanel.OnClickSortType, filterPanel, combo)
        if not ok then
            log("L3: applying the sort mode failed: " .. tostring(err), true)
            return false
        end
    end

    local label = ""
    local option = options[selected]
    if type(option) == "table" and option.text ~= nil then label = tostring(option.text) end
    log("L3: sort mode -> " .. tostring(selected) .. "/" .. tostring(#options) .. " " .. label)
    return true
end

-- ---------------------------------------------------------------------------
-- R3: take back everything sitting in the "contained items" column
-- ---------------------------------------------------------------------------
-- That column is an ISCraftInventoryPanel with isResourceItemSlot = true, so
-- onListItemClicked takes the ItemSlotRemoveSingleItem branch. Walk it
-- backwards so removing rows cannot shift the ones we have not visited yet.
local function takeBackAllContained(self)
    local panel = safeIndex(self, "resourceInventoryPanel")
    local list = safeIndex(panel, "itemListBox")
    if type(list) ~= "table" or type(list.items) ~= "table" then
        log("R3: no contained items list")
        return false
    end
    if type(panel.onListItemClicked) ~= "function" then return false end

    local taken = 0
    for index = #list.items, 1, -1 do
        local data = list.items[index] and list.items[index].item
        if type(data) == "table"
            and data.inventoryItem ~= nil
            and not data.isHeader
            and not data.isNode
            and not data.isUnavailable then
            local ok = pcall(panel.onListItemClicked, panel, data)
            if ok then taken = taken + 1 end
        end
    end

    if taken == 0 then
        log("R3: contained items column is empty")
        return false
    end
    log("R3: took back " .. tostring(taken) .. " contained item(s)")
    return true
end

-- ---------------------------------------------------------------------------
-- Y: take everything out of the output slots
-- ---------------------------------------------------------------------------
local function takeAllOutputs(self)
    local button = getTakeButton(self)
    if type(button) ~= "table" then return false end
    if button.enable == false then
        log("Y: take-all is disabled right now (nothing finished)")
        return false
    end
    if type(button.forceClick) ~= "function" then return false end
    local ok, err = pcall(button.forceClick, button)
    if not ok then
        log("Y: take-all failed: " .. tostring(err), true)
        return false
    end
    log("Y: took all finished outputs")
    return true
end

-- ---------------------------------------------------------------------------
-- Recipe list: A confirms the recipe and opens the material picker
-- ---------------------------------------------------------------------------
-- Wrapping on the instance (not on the class) does two things at once:
--   * A now continues into "open the picker and jump there", which is the
--     whole three-step flow with one button.
--   * X no longer reaches the class-level favourite toggle installed by
--     GQSPanelInfoEnhancement, which used to turn X into "favourite" here.
local function wrapRecipeList(self)
    local list = getRecipeList(self)
    if type(list) ~= "table" or list._gqsCraftLogicList then return end

    local original = list.onJoypadDown
    if type(original) ~= "function" then return end

    list._gqsCraftLogicList = true
    list._gqsCraftLogicPanel = self
    list.onJoypadDown = function(listSelf, button, joypadData, ...)
        -- X is consumed unconditionally. Letting it fall through when there is
        -- no material to add is what made it reach the class-level favourite
        -- toggle again, which is the bug this wrap exists to prevent.
        if isJoypadButton(button, "XButton", "X") then
            smartX(self, joypadData)
            return
        end

        local result = original(listSelf, button, joypadData, ...)

        -- A already told the logic which recipe is selected; now show the
        -- materials for it. Done after the vanilla call so the recipe is set.
        if isJoypadButton(button, "AButton", "A") then
            openInputPicker(self, joypadData)
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
local originalUpdate = CraftLogicPanel.update
CraftLogicPanel.update = function(self, ...)
    if type(originalUpdate) == "function" then
        local result = { originalUpdate(self, ...) }
        wrapRecipeList(self)
        return unpack(result)
    end
    wrapRecipeList(self)
end

local originalGainFocus = CraftLogicPanel.onGainJoypadFocus
CraftLogicPanel.onGainJoypadFocus = function(self, joypadData)
    if type(originalGainFocus) == "function" then pcall(originalGainFocus, self, joypadData) end
    wrapRecipeList(self)

    -- The material column is the first thing a player needs here, so open it up
    -- front instead of making them press A twice before it appears.
    if not isManualPickerShown(self) then
        toggleInputPicker(self)
    end

    if setFocus(joypadData, getRecipeList(self)) then
        log("focus handed to the recipe list")
    else
        log("no recipe list to focus; leaving focus on the panel", true)
    end
end

-- Rebuilt on every navigation start: the material column only exists while the
-- picker is open, so that link comes and goes.
local originalNavigateStart = CraftLogicPanel.onJoypadNavigateStart_Descendant
CraftLogicPanel.onJoypadNavigateStart_Descendant = function(self, descendant, joypadData)
    local recipeList = getRecipeList(self)
    local craftControl = getCraftControl(self)
    local inventoryList = isReallyVisible(getInventoryList(self)) and getInventoryList(self) or nil
    local takeButton = getTakeButton(self)
    local containedList = isReallyVisible(getContainedList(self)) and getContainedList(self) or nil

    if recipeList then
        recipeList.joypadNavigate = { right = craftControl, down = takeButton }
    end
    if craftControl then
        craftControl.joypadNavigate = {
            left = recipeList,
            right = inventoryList,
            down = takeButton,
        }
    end
    if takeButton then
        -- Up goes back to the craft button (not the recipe list), left returns
        -- to the recipe list, right reaches the contained-items column.
        takeButton.joypadNavigate = { up = craftControl, left = recipeList, right = containedList }
    end
    if inventoryList then
        inventoryList.joypadNavigate = { left = craftControl, down = containedList }
    end
    if containedList then
        containedList.joypadNavigate = { up = inventoryList, left = takeButton }
    end

    if type(originalNavigateStart) == "function" then
        return originalNavigateStart(self, descendant, joypadData)
    end
end

local originalDownDescendant = CraftLogicPanel.onJoypadDown_Descendant
CraftLogicPanel.onJoypadDown_Descendant = function(self, descendant, button, joypadData)
    if isJoypadButton(button, "XButton", "X") then
        -- Consumed even when there is nothing to add, so the class-level
        -- favourite toggle can never see it.
        smartX(self, joypadData)
        return
    elseif isJoypadButton(button, "YButton", "Y") then
        if takeAllOutputs(self) then return end
    elseif isStickPress(button, "LStickButton") then
        cycleSortMode(self)
        return
    elseif isStickPress(button, "RStickButton") then
        takeBackAllContained(self)
        return
    end

    if type(originalDownDescendant) == "function" then
        return originalDownDescendant(self, descendant, button, joypadData)
    end
end

-- ---------------------------------------------------------------------------
-- On-screen key hints
-- ---------------------------------------------------------------------------
local PROMPT_ICON_SIZE = 28
local HEADER_ICON_SIZE = 24

local function getJoypadTexture(names)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    if not textures then return nil end
    for _, name in ipairs(names) do
        if textures[name] then return textures[name] end
    end
    return nil
end

-- Joypad glyphs are not square: the RB / L3 / R3 art is wide and flat. Stretching
-- it into a square shrinks it to a barely readable strip, so scale by height and
-- let the width follow the texture's own aspect ratio.
local function glyphSize(texture, height)
    if not texture then return height, height end
    local okW, w = pcall(function() return texture:getWidth() end)
    local okH, h = pcall(function() return texture:getHeight() end)
    if not okW or not okH or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
        return height, height
    end
    local width = w * (height / h)
    -- Guard against absurdly wide art eating the whole row.
    local maxWidth = height * 2.6
    if width > maxWidth then
        return maxWidth, height * (maxWidth / width)
    end
    return width, height
end

local function text(key, fallback)
    local value = type(getText) == "function" and getText(key) or nil
    if type(value) ~= "string" or value == "" or value == key then return fallback end
    return value
end

-- Right-aligned variant: the glyph's right edge lands on rightEdgeX.
local function drawKeyGlyphRight(element, textureNames, fallbackLetter, rightEdgeX, centerY, font, size)
    size = tonumber(size) or PROMPT_ICON_SIZE
    local texture = getJoypadTexture(textureNames)
    local width, height = glyphSize(texture, size)
    local x = rightEdgeX - width
    local y = centerY - height / 2
    if texture then
        pcall(element.drawTextureScaled, element, texture, x, y, width, height, 1, 1, 1, 1)
    elseif fallbackLetter then
        pcall(element.drawText, element, fallbackLetter, x, y, 1, 1, 1, 1, font)
    end
    return width, height
end

-- Draws one key glyph centred on (centerX, centerY). Returns its width so
-- callers can lay out text next to it.
local function drawKeyGlyph(element, textureNames, fallbackLetter, centerX, centerY, font, size)
    size = tonumber(size) or PROMPT_ICON_SIZE
    local texture = getJoypadTexture(textureNames)
    local width, height = glyphSize(texture, size)
    local x = centerX - width / 2
    local y = centerY - height / 2
    if texture then
        pcall(element.drawTextureScaled, element, texture, x, y, width, height, 1, 1, 1, 1)
    elseif fallbackLetter then
        pcall(element.drawText, element, fallbackLetter, x, y, 1, 1, 1, 1, font)
    end
    return width, height
end

-- X next to the craft button, Y next to "take all". Both use absolute
-- coordinates converted into this panel's space, so they follow the real
-- button positions instead of guessing offsets.
local function drawButtonPrompts(self)
    -- self.x/self.y are relative to the parent; drawing needs absolute space.
    local originX, originY = 0, 0
    if type(self.getAbsoluteX) == "function" then
        local okX, ax = pcall(self.getAbsoluteX, self)
        local okY, ay = pcall(self.getAbsoluteY, self)
        if okX and type(ax) == "number" then originX = ax end
        if okY and type(ay) == "number" then originY = ay end
    end
    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil

    local craftButton = safeIndex(getCraftControl(self), "buttonCraft")
    if type(craftButton) == "table" and craftButton.enable ~= false
        and type(craftButton.getAbsoluteX) == "function" then
        local okX, bx = pcall(craftButton.getAbsoluteX, craftButton)
        local okY, by = pcall(craftButton.getAbsoluteY, craftButton)
        local bh = tonumber(safeIndex(craftButton, "height")) or 20
        if okX and okY and type(bx) == "number" and type(by) == "number" then
            drawKeyGlyph(self, { "XButton" }, "X",
                bx - originX - 14, by - originY + bh / 2, font)
        end
    end

    -- L3 goes in the blank space left of the "Sort by" caption. Anchoring to the
    -- combo box would land on top of that caption, since the combo sits to its
    -- right.
    local filterPanel = safeIndex(safeIndex(self, "recipesPanel"), "recipeFilterPanel")
    local sortCombo = safeIndex(filterPanel, "sortCombo")
    local sortLabel = safeIndex(filterPanel, "sortComboLabel")
    local anchor = sortCombo
    if type(sortLabel) == "table" and type(sortLabel.getAbsoluteX) == "function" then
        anchor = sortLabel
    end
    if type(anchor) == "table" and type(anchor.getAbsoluteX) == "function" then
        local okX, ax = pcall(anchor.getAbsoluteX, anchor)
        local okY, ay = pcall(anchor.getAbsoluteY, anchor)
        local ah = tonumber(safeIndex(anchor, "height")) or 20
        if okX and okY and type(ax) == "number" and type(ay) == "number" then
            drawKeyGlyphRight(self, { "LStick", "AnalogueL", "L3" }, "L3",
                ax - originX - 6, ay - originY + ah / 2, font)
        end
    end

    local takeButton = getTakeButton(self)
    if type(takeButton) == "table" and type(takeButton.getAbsoluteX) == "function" then
        local okX, bx = pcall(takeButton.getAbsoluteX, takeButton)
        local okY, by = pcall(takeButton.getAbsoluteY, takeButton)
        local bw = tonumber(safeIndex(takeButton, "width")) or 60
        local bh = tonumber(safeIndex(takeButton, "height")) or 20
        if okX and okY and type(bx) == "number" and type(by) == "number" then
            drawKeyGlyph(self, { "YButton" }, "Y",
                bx - originX + bw + 14, by - originY + bh / 2, font)
        end
    end
end

-- The window title bar has plenty of empty space, so the whole key map goes
-- there: RB switch area / X quick add or craft / Y take all / B close.
-- X's label follows the craft button state, exactly like the button itself.
local function findCraftLogicPanel(window)
    local componentsPanel = safeIndex(window, "componentsPanel")
    local panels = safeIndex(componentsPanel, "panels")
    if type(panels) ~= "table" then return nil end
    for _, info in ipairs(panels) do
        local panel = safeIndex(info, "panel")
        if type(panel) == "table" and panel._gqsCraftLogicJoypadInstalled then
            return panel
        end
    end
    return nil
end

local function drawHeaderHints(window)
    local panel = findCraftLogicPanel(window)
    if not panel then return end
    local header = safeIndex(window, "entityHeader")
    if type(header) ~= "table" or type(header.getAbsoluteX) ~= "function" then return end

    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil
    if not font or type(getTextManager) ~= "function" then return end
    local manager = getTextManager()
    local lineHeight = manager:getFontHeight(font)
    local iconSize = HEADER_ICON_SIZE
    local iconGap = 5
    local blockGap = 16

    local xLabel = isCraftReady(panel)
        and text("IGUI_CraftingWindow_Craft", "制作")
        or text("UI_GQOS_CraftLogicQuickAdd", "快速放入")

    local parts = {
        { icon = { "RBumper", "RBButton", "RB" }, letter = "RB",
          label = text("UI_GQOS_CraftLogicSwitchArea", "切换区域") },
        { icon = { "XButton" }, letter = "X", label = xLabel },
        -- Y is already shown right next to the "take all" button itself, so it
        -- does not need a second copy up here.
        { icon = { "RStick", "AnalogueR", "R3" }, letter = "R3",
          label = text("UI_GQOS_CraftLogicTakeBack", "取回") },
        { icon = { "BButton" }, letter = "B",
          label = text("UI_GQOS_PanelClose", "关闭") },
    }

    -- Measure first, then right-align inside the header.
    local totalWidth = 0
    for index, part in ipairs(parts) do
        local glyphW = glyphSize(getJoypadTexture(part.icon), iconSize)
        part.glyphWidth = glyphW
        part.width = glyphW + iconGap + manager:MeasureStringX(font, part.label)
        totalWidth = totalWidth + part.width
        if index < #parts then totalWidth = totalWidth + blockGap end
    end

    local okHX, hx = pcall(header.getAbsoluteX, header)
    local okHY, hy = pcall(header.getAbsoluteY, header)
    if not okHX or not okHY or type(hx) ~= "number" or type(hy) ~= "number" then return end
    local okWX, wx = pcall(window.getAbsoluteX, window)
    local okWY, wy = pcall(window.getAbsoluteY, window)
    if not okWX or not okWY or type(wx) ~= "number" or type(wy) ~= "number" then return end

    local headerWidth = tonumber(safeIndex(header, "width")) or 300
    local headerHeight = tonumber(safeIndex(header, "height")) or 24

    -- Leave room for the vanilla info button that sits in the top-right corner
    -- of the header, otherwise the hints run into it.
    local INFO_BUTTON_CLEARANCE = 44
    local startX = (hx - wx) + headerWidth - totalWidth - INFO_BUTTON_CLEARANCE
    local baselineY = (hy - wy) + (headerHeight - lineHeight) / 2
    local cursorX = startX

    for _, part in ipairs(parts) do
        drawKeyGlyph(window, part.icon, part.letter,
            cursorX + part.glyphWidth / 2, baselineY + lineHeight / 2, font, iconSize)
        cursorX = cursorX + part.glyphWidth + iconGap
        pcall(window.drawText, window, part.label, cursorX, baselineY, 0.9, 0.9, 0.9, 1, font)
        cursorX = cursorX + manager:MeasureStringX(font, part.label) + blockGap
    end
end

-- "Contained items" column: an R3 hint in that column's bottom-left corner.
--
-- Drawn from ISCraftLogicPanel:render() like the X / Y / L3 glyphs, which are
-- known to show up. The coordinates are clamped into the panel rect so a bad
-- absolute position can never push the hint off-screen.
local function countContainedItems(list)
    if type(list) ~= "table" or type(list.items) ~= "table" then return 0 end
    local count = 0
    for _, entry in ipairs(list.items) do
        local data = entry and entry.item
        if type(data) == "table"
            and data.inventoryItem ~= nil
            and not data.isHeader
            and not data.isNode
            and not data.isUnavailable then
            count = count + 1
        end
    end
    return count
end

local lastHintState = nil

local function drawContainedHint(self)
    local panel = safeIndex(self, "resourceInventoryPanel")
    local list = safeIndex(panel, "itemListBox")
    if type(list) ~= "table" or type(list.getAbsoluteX) ~= "function" then return end
    local containedCount = countContainedItems(list)
    -- Shown either way: grey when there is nothing to take back, so the key is
    -- still discoverable instead of appearing and disappearing.
    local enabled = containedCount > 0

    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil
    if not font or type(getTextManager) ~= "function" then return end
    local manager = getTextManager()
    local lineHeight = manager:getFontHeight(font)
    local label = text("UI_GQOS_CraftLogicTakeBack", "取回")
    local textWidth = manager:MeasureStringX(font, label)

    local originX, originY = 0, 0
    if type(self.getAbsoluteX) == "function" then
        local okOX, ox = pcall(self.getAbsoluteX, self)
        local okOY, oy = pcall(self.getAbsoluteY, self)
        if okOX and type(ox) == "number" then originX = ox end
        if okOY and type(oy) == "number" then originY = oy end
    end

    local okX, lx = pcall(list.getAbsoluteX, list)
    local okY, ly = pcall(list.getAbsoluteY, list)
    if not okX or not okY or type(lx) ~= "number" or type(ly) ~= "number" then return end
    local listWidth = tonumber(safeIndex(list, "width")) or 200
    local listHeight = tonumber(safeIndex(list, "height")) or 80
    local panelWidth = tonumber(safeIndex(self, "width"))
    local panelHeight = tonumber(safeIndex(self, "height"))
    if not panelWidth or panelWidth <= 0 then
        local okW, w = pcall(function() return self:getWidth() end)
        if okW then panelWidth = tonumber(w) end
    end
    if not panelHeight or panelHeight <= 0 then
        local okH, h = pcall(function() return self:getHeight() end)
        if okH then panelHeight = tonumber(h) end
    end
    panelWidth = panelWidth or 1000
    panelHeight = panelHeight or 600

    local padding = 8
    local gap = 5
    local rowHeight = math.max(PROMPT_ICON_SIZE, lineHeight)
    local glyphWidth = glyphSize(getJoypadTexture({ "RStick", "AnalogueR", "R3" }), PROMPT_ICON_SIZE)

    -- Bottom-left corner of the list box, expressed in this panel's space.
    local leftX = (lx - originX) + padding
    local rowTop = (ly - originY) + listHeight - rowHeight - padding

    -- Clamp inside the panel: the absolute coordinates of the nested table
    -- layout are not always what the eye expects, and an off-panel draw is
    -- silently clipped.
    local maxLeftX = panelWidth - glyphWidth - padding
    if leftX > maxLeftX then leftX = maxLeftX end
    if leftX < padding then leftX = padding end
    local maxRowTop = panelHeight - rowHeight - padding
    if rowTop > maxRowTop then rowTop = maxRowTop end
    if rowTop < 0 then rowTop = 0 end

    local showLabel = (glyphWidth + gap + textWidth) <= (panelWidth - leftX - padding)
    local state = string.format("count=%d enabled=%s panel=%.0fx%.0f list=%.0fx%.0f at(%.0f,%.0f) origin=(%.0f,%.0f) leftX=%.0f rowTop=%.0f label=%s",
        containedCount, tostring(enabled), panelWidth, panelHeight, listWidth, listHeight,
        lx, ly, originX, originY, leftX, rowTop, tostring(showLabel))
    if state ~= lastHintState then
        lastHintState = state
        log("R3 hint: " .. state)
    end

    -- A parent stencil clips the bottom-right corner. clearStencilRect() only
    -- clears this element's own rect, so it does nothing here -- what actually
    -- un-clips the area is repaintStencilRect(), the same call
    -- renderJoypadNavigateOverlay() makes (which is why holding RB made the
    -- hint appear).
    pcall(function() self:repaintStencilRect(0, 0, panelWidth, panelHeight) end)

    local textR, textG, textB = 0.90, 0.90, 0.90
    if not enabled then
        textR, textG, textB = 0.45, 0.45, 0.45
    end

    drawKeyGlyph(self, { "RStick", "AnalogueR", "R3" }, "R3",
        leftX + glyphWidth / 2, rowTop + rowHeight / 2, font)
    if showLabel then
        pcall(self.drawText, self, label, leftX + glyphWidth + gap,
            rowTop + (rowHeight - lineHeight) / 2, textR, textG, textB, 1, font)
    end
end

local EntityWindow = rawget(_G, "ISEntityWindow")
if type(EntityWindow) == "table" and type(EntityWindow.render) == "function"
    and not EntityWindow._gqsCraftLogicHeaderHints then
    local originalEntityRender = EntityWindow.render
    EntityWindow.render = function(self, ...)
        local result = { originalEntityRender(self, ...) }
        pcall(drawHeaderHints, self)
        return unpack(result)
    end
    EntityWindow._gqsCraftLogicHeaderHints = true
end

-- Same arrow overlay the vanilla Build / Handcraft panels draw while RB is
-- held: it is a plain ISUIElement method, no extra machinery needed.
local originalRender = CraftLogicPanel.render
CraftLogicPanel.render = function(self, ...)
    if type(originalRender) == "function" then originalRender(self, ...) end
    if type(self.renderJoypadNavigateOverlay) == "function" then
        pcall(self.renderJoypadNavigateOverlay, self, getPlayerNum(self))
    end
    pcall(drawButtonPrompts, self)
    pcall(drawContainedHint, self)
end

CraftLogicPanel._gqsCraftLogicJoypadInstalled = true
log("CraftLogic panel joypad navigation installed")
