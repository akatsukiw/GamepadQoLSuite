-- Gamepad QoL Suite: joypad navigation for the CraftLogic panel (v1.5.9).
--
-- 皮革晾晒架（entity DryingRackLarge / Medium / Small）用的是 ISCraftLogicPanel。
-- 这个面板原版完全没有手柄装配：没有 onGainJoypadFocus、没有 joypadNavigate、
-- 没有 onJoypadDown。焦点虽然被 ISEntityWindow 交进来了，但停在面板本身，
-- 子控件一个都拿不到焦点，所以打开后只能按 B 退出。
--
-- 同目录的 ISCraftBenchPanel（软化梁 / 单宁桶）有完整的四件套，这里照它的结构补齐。
-- 底层控件其实大多已经支持手柄：
--   ISRecipeScrollingListBox  配方列表      自带 onJoypadDown
--   ISScrollingListBox        可用物品列表  自带 A 确认 + 上下移动
--   ISWidgetCraftLogicControl 制作按钮      ISPanelJoypad 派生，自带焦点
--   ISUIElement               joypadNavigate 四向表是引擎原生支持的
-- 真正缺的只有两件事，用 X / Y 补上：
--   1. 输入槽位上的小箭头（打开右侧"可用物品"）只有鼠标点击
--   2. "全部拿走"按钮需要手柄焦点
--
-- 所以这个模块只做装配，不重写任何控件。

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

local function getRecipeList(self)
    return safeIndex(safeIndex(safeIndex(self, "recipesPanel"), "recipeListPanel"), "recipeListPanel")
end

local function getInventoryList(self)
    return safeIndex(safeIndex(self, "inventoryPanel"), "itemListBox")
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

local function setFocus(joypadData, target)
    if not joypadData or type(target) ~= "table" then return false end
    joypadData.focus = target
    if type(updateJoypadFocus) == "function" then pcall(updateJoypadFocus, joypadData) end
    return true
end

-- ---------------------------------------------------------------------------
-- X: the manual input picker (that little arrow on the input slot)
-- ---------------------------------------------------------------------------
local function isManualPickerShown(self)
    local logic = safeIndex(getInputControl(self), "logic")
    if not logic or type(logic.shouldShowManualSelectInputs) ~= "function" then return false end
    local ok, value = pcall(logic.shouldShowManualSelectInputs, logic)
    return ok and value == true
end

local function toggleInputPicker(self)
    local panel = safeIndex(getInputControl(self), "inputItems")
    if type(panel) ~= "table" or type(panel.getItemSlots) ~= "function" then return false end

    local okSlots, slots = pcall(panel.getItemSlots, panel)
    if not okSlots or type(slots) ~= "table" then return false end

    -- Every input slot with a select button is a separate material slot. Pressing
    -- X walks them in order, which is what a player with only one material slot
    -- (leather drying) expects anyway.
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
-- Wiring
-- ---------------------------------------------------------------------------
local originalGainFocus = CraftLogicPanel.onGainJoypadFocus
CraftLogicPanel.onGainJoypadFocus = function(self, joypadData)
    if type(originalGainFocus) == "function" then pcall(originalGainFocus, self, joypadData) end
    if setFocus(joypadData, getRecipeList(self)) then
        log("focus handed to the recipe list")
    else
        log("no recipe list to focus; leaving focus on the panel", true)
    end
end

-- Rebuilt on every navigation start because the inventory column only exists
-- while the manual picker is open, so the right-hand link comes and goes.
local originalNavigateStart = CraftLogicPanel.onJoypadNavigateStart_Descendant
CraftLogicPanel.onJoypadNavigateStart_Descendant = function(self, descendant, joypadData)
    local recipeList = getRecipeList(self)
    local inventoryList = getInventoryList(self)
    local craftControl = getCraftControl(self)
    local takeButton = getTakeButton(self)

    if recipeList then
        recipeList.joypadNavigate = { right = inventoryList, down = craftControl }
    end
    if inventoryList then
        inventoryList.joypadNavigate = { left = recipeList }
    end
    if craftControl then
        craftControl.joypadNavigate = { up = recipeList, left = recipeList, down = takeButton }
    end
    if takeButton then
        takeButton.joypadNavigate = { up = craftControl }
    end

    if type(originalNavigateStart) == "function" then
        return originalNavigateStart(self, descendant, joypadData)
    end
end

local originalDownDescendant = CraftLogicPanel.onJoypadDown_Descendant
CraftLogicPanel.onJoypadDown_Descendant = function(self, descendant, button, joypadData)
    if isJoypadButton(button, "XButton", "X") then
        if toggleInputPicker(self) then
            -- Opening the picker reveals the inventory column; jump straight
            -- there so the next press of A puts the material in.
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

CraftLogicPanel._gqsCraftLogicJoypadInstalled = true
log("CraftLogic panel joypad navigation installed")
