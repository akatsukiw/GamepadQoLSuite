-- Gamepad QoL Suite: joypad navigation for the CraftLogic panel (v1.5.9.1).
--
-- 皮革晾晒架（entity DryingRackLarge / Medium / Small）用的是 ISCraftLogicPanel。
-- 这个面板原版完全没有手柄装配：没有 onGainJoypadFocus、没有 joypadNavigate、
-- 没有 onJoypadDown、render 里也不画导航覆盖层。焦点虽然被 ISEntityWindow 交进来了，
-- 但停在面板本身，子控件一个都拿不到，所以打开后只能按 B 退出。
--
-- 同目录的 ISCraftBenchPanel（软化梁 / 单宁桶）有完整的四件套，这里照它的结构补齐。
--
-- 面板的真实视觉布局是 3 列 2 行：
--   ┌──────────┬──────────────┬────────────┐
--   │ 配方列表 │ 输入/制作/输出│ 可用物品   │
--   │          ├──────────────┼────────────┤
--   │          │ 进行中/完成  │ 已包含物品 │
--   └──────────┴──────────────┴────────────┘
-- 所以导航图按这个网格来（RB + 方向键切换区域，普通方向键在区域内滚动）：
--
--   配方列表 ←→ 制作按钮 ←→ 可用物品
--      ↕                        ↕
--   全部拿走 ←→ 已包含物品
--
-- 原版就支持的控件（不需要动）：
--   ISRecipeScrollingListBox  配方列表    自带 A 选中 / B 回父级
--   ISScrollingListBox        可用物品 / 已包含物品   自带 A 确认 + 上下滚动
--   ISWidgetCraftLogicControl 制作按钮    ISPanelJoypad 派生，自带焦点
--   ISUIElement:renderJoypadNavigateOverlay  导航箭头覆盖层，任何元素都能调
-- 真正缺的只有两件事，用 X / Y 补上：
--   1. 输入槽位上的小箭头（打开右侧"可用物品"）只有鼠标点击
--   2. "全部拿走"按钮没有手柄焦点

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then fn("panelInfo", message) end
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
        if isJoypadButton(button, "XButton", "X") then
            if toggleInputPicker(self) then
                if isManualPickerShown(self) then
                    setFocus(joypadData, getInventoryList(self))
                end
                return
            end
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
        local focus = joypadData and joypadData.focus
        -- Already standing in the material column: X means "craft now", not
        -- "toggle the picker I am looking at".
        if focus ~= nil and focus == getInventoryList(self) then
            craftNow(self)
            return
        end
        if toggleInputPicker(self) then
            if isManualPickerShown(self) then
                setFocus(joypadData, getInventoryList(self))
            end
            return
        end
    elseif isJoypadButton(button, "YButton", "Y") then
        if takeAllOutputs(self) then return end
    end

    if type(originalDownDescendant) == "function" then
        return originalDownDescendant(self, descendant, button, joypadData)
    end
end

-- Same arrow overlay the vanilla Build / Handcraft panels draw while RB is
-- held: it is a plain ISUIElement method, no extra machinery needed.
local originalRender = CraftLogicPanel.render
CraftLogicPanel.render = function(self, ...)
    if type(originalRender) == "function" then originalRender(self, ...) end
    if type(self.renderJoypadNavigateOverlay) == "function" then
        pcall(self.renderJoypadNavigateOverlay, self, getPlayerNum(self))
    end
end

CraftLogicPanel._gqsCraftLogicJoypadInstalled = true
log("CraftLogic panel joypad navigation installed")
