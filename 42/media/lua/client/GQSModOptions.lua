local BaseCGUI = require("SWModOptions")
local multiSelect = rawget(_G, "GamepadQoLSuite") or rawget(_G, "GamepadMultiSelectStandalone")
if not multiSelect or type(multiSelect.addOptionsTo) ~= "function" then
    pcall(require, "GQSMultiSelectStandalone")
end
local GQS = setmetatable({}, { __index = BaseCGUI })

local options = nil
if PZAPI and PZAPI.ModOptions then
    if type(PZAPI.ModOptions.getOptions) == "function" then
        local ok, existing = pcall(PZAPI.ModOptions.getOptions, PZAPI.ModOptions, "GamepadQoLSuite")
        if ok then options = existing end
    end
    if not options and type(PZAPI.ModOptions.create) == "function" then
        options = PZAPI.ModOptions:create("GamepadQoLSuite", "Gamepad QoL Suite")
    end
end

local function addLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then logger.log("modOptions", message) end
end

-- Options flagged this way stay fully functional and keep persisting their
-- values; they are only skipped when the options panel is built. Used for
-- tuning knobs that would otherwise clutter the list.
local function hideOption(option)
    if type(option) == "table" then option._gqsHidden = true end
    return option
end

if options then
    options:addTitle("UI_GQOS_invLoot")
    GQS.invLootWidth = options:addSlider("invLootWidth", "UI_GQOS_invLootWidth", 30, 100, 5, 65, "UI_GQOS_invLootWidth_tooltip")
    GQS.invHeight = options:addSlider("invHeight", "UI_GQOS_invHeight", 20, 80, 5, 50, "UI_GQOS_invHeight_tooltip")
    GQS.lootHeight = options:addSlider("lootHeight", "UI_GQOS_lootHeight", 20, 80, 5, 50, "UI_GQOS_lootHeight_tooltip")
    GQS.invLootPosition = options:addComboBox("invLootPosition", "UI_GQOS_invLootPosition", "UI_GQOS_invLootPosition_tooltip")
    GQS.invLootPosition:addItem("UI_GQOS_default", true)
    GQS.invLootPosition:addItem("UI_GQOS_left", false)
    GQS.invLootPosition:addItem("UI_GQOS_right", false)
    GQS.invLootPosition:addItem("UI_GQOS_centerBottom", false)
    GQS.invLootPosition:addItem("UI_GQOS_centerTop", false)
    options:addTitle("UI_GQOS_splitSection")
    GQS.splitInvLootWidth = options:addSlider("splitInvLootWidth", "UI_GQOS_splitInvLootWidth", 50, 100, 5, 100, "UI_GQOS_splitInvLootWidth_tooltip")
    GQS.splitContainerHeight = options:addSlider("splitContainerHeight", "UI_GQOS_splitContainerHeight", 20, 80, 5, 50, "UI_GQOS_splitContainerHeight_tooltip")

    options:addTitle("UI_GQOS_SelectSortTitle")
    GQS.sortBy = options:addComboBox("sortBy", "UI_GQOS_sortBy", "UI_GQOS_sortBy_tooltip")
    GQS.sortBy:addItem("UI_GQOS_disabled", true)
    GQS.sortBy:addItem("UI_GQOS_name", false)
    GQS.sortBy:addItem("UI_GQOS_category", false)
    GQS.sortBy:addItem("UI_GQOS_weight", false)
    GQS.sortBy:addItem("UI_GQOS_weightCategoryCycle", false)
    GQS.sortBy:addItem("UI_GQOS_categoryDescWeightCycle", false)
    GQS.sortDoubleClickDelay = hideOption(options:addSlider("sortDoubleClickDelay", "UI_GQOS_sortDoubleClickDelay", 100, 1000, 50, 200, "UI_GQOS_sortDoubleClickDelay_tooltip"))

    options:addSeparator()
    options:addTitle("UI_GQOS_containerOperations")
    GQS.combinedContainerSwitch = options:addTickBox("combinedContainerSwitch", "UI_GQOS_combinedContainerSwitch", true, "UI_GQOS_combinedContainerSwitch_tooltip")
    options:addTitle("UI_GQOS_ContainerPageNavTitle")
    GQS.containerPageNavMode = options:addComboBox("containerPageNavMode", "UI_GQOS_ContainerPageNavMode", "UI_GQOS_ContainerPageNavMode_tooltip")
    GQS.containerPageNavMode:addItem("UI_GQOS_ContainerPageNavFixed", true)
    GQS.containerPageNavMode:addItem("UI_GQOS_ContainerPageNavViewport", false)

    multiSelect = rawget(_G, "GamepadQoLSuite") or rawget(_G, "GamepadMultiSelectStandalone")
    if multiSelect and type(multiSelect.addOptionsTo) == "function" then
        multiSelect.addOptionsTo(options)
    end
    options:addTitle("UI_GQOS_gamepadDragTransfer")
    GQS.multiSelectDragEnabled = hideOption(options:addTickBox("multiSelectDragEnabled", "UI_GQOS_multiSelectDragEnabled", false, "UI_GQOS_multiSelectDragEnabled_tooltip"))
    GQS.multiSelectDragHoldDelay = hideOption(options:addSlider("multiSelectDragHoldDelay", "UI_GQOS_multiSelectDragHoldDelay", 150, 1000, 50, 200, "UI_GQOS_multiSelectDragHoldDelay_tooltip"))
    GQS.xContainerTransferEnabled = options:addTickBox("xContainerTransferEnabled", "UI_GQOS_xContainerTransferEnabled", true, "UI_GQOS_xContainerTransferEnabled_tooltip")
    GQS.xContainerHoldDelay = hideOption(options:addSlider("xContainerHoldDelay", "UI_GQOS_xContainerHoldDelay", 150, 1000, 50, 200, "UI_GQOS_xContainerHoldDelay_tooltip"))

    options:addSeparator()
    options:addTitle("UI_GQOS_yEnhancementTitle")
    GQS.yEnhancementEnabled = options:addTickBox("yEnhancementEnabled", "UI_GQOS_yEnhancementEnabled", true, "UI_GQOS_yEnhancementEnabled_tooltip")
    GQS.yShortcutEnabled = options:addTickBox("yShortcutEnabled", "UI_GQOS_yShortcutEnabled", true, "UI_GQOS_yShortcutEnabled_tooltip")
    local function addShortcut(name, action)
        local combo = options:addComboBox(name, "UI_GQOS_" .. name, "UI_GQOS_yShortcutMapping_tooltip")
        local labels = {"UI_GQOS_yShortcutDisabled", "UI_GQOS_yShortcutBuilding", "UI_GQOS_yShortcutCrafting", "UI_GQOS_yShortcutPlayerInfo", "UI_GQOS_yShortcutHealth", "UI_GQOS_yShortcutInventory", "UI_GQOS_yShortcutFitness"}
        for index, key in ipairs(labels) do combo:addItem(key, index == action) end
        return combo
    end
    GQS.yShortcutUp = addShortcut("yShortcutUp", 5)
    GQS.yShortcutDown = addShortcut("yShortcutDown", 6)
    GQS.yShortcutLeft = addShortcut("yShortcutLeft", 2)
    GQS.yShortcutRight = addShortcut("yShortcutRight", 3)
    GQS.panelQuickSelectEnabled = options:addTickBox("panelQuickSelectEnabled", "UI_GQOS_panelQuickSelectEnabled", true, "UI_GQOS_panelQuickSelectEnabled_tooltip")

    options:addTitle("UI_GQOS_rbExtensionTitle")
    GQS.rbExtensionsEnabled = options:addTickBox("rbExtensionsEnabled", "UI_GQOS_rbExtensionsEnabled", true, "UI_GQOS_rbExtensionsEnabled_tooltip")
    -- Keep emotion browsing on Up/Down and zoom choices on Left/Right.
    -- These are UI-only choices: GQSRBZoom still exposes the historical action
    -- API for other modules and consumes the selected values through a direction map.
    local rbMoodleLabels = {"UI_GQOS_rbActionDisabled", "UI_GQOS_rbActionMoodlePrevious", "UI_GQOS_rbActionMoodleNext"}
    local rbZoomLabels = {"UI_GQOS_rbActionDisabled", "UI_GQOS_rbActionZoomIn", "UI_GQOS_rbActionZoomOut"}
    local function addRB(name, labels, index)
        local combo = options:addComboBox(name, "UI_GQOS_" .. name, "UI_GQOS_rbDpadAction_tooltip")
        for i, key in ipairs(labels) do combo:addItem(key, i == index) end
        return combo
    end
    GQS.rbDpadUpAction = addRB("rbDpadUpAction", rbMoodleLabels, 2)
    GQS.rbDpadDownAction = addRB("rbDpadDownAction", rbMoodleLabels, 3)
    GQS.rbDpadLeftAction = addRB("rbDpadLeftAction", rbZoomLabels, 3)
    GQS.rbDpadRightAction = addRB("rbDpadRightAction", rbZoomLabels, 2)
    local function addRBButton(name, index)
        local combo = options:addComboBox(name, "UI_GQOS_" .. name, "UI_GQOS_rbButtonAction_tooltip")
        for i, key in ipairs(rbZoomLabels) do combo:addItem(key, i == index) end
        return combo
    end
    GQS.rbButtonYAction = addRBButton("rbButtonYAction", 2)
    GQS.rbButtonAAction = addRBButton("rbButtonAAction", 3)

    local function optionIndex(option)
        if not option then return nil end
        if type(option.getValue) == "function" then
            local ok, value = pcall(option.getValue, option)
            if ok then return tonumber(value) end
        end
        return tonumber(option.value)
    end
    local function setOptionIndex(option, value)
        if option and type(option.setValue) == "function" then
            pcall(option.setValue, option, value)
        end
    end
    -- Normalize saved values from the former five-choice lists without overwriting
    -- valid user choices. The current UI contracts are Up/Down=moodles only and
    -- Left/Right=zoom only. Older Left/Right indices 4/5 were Moodle actions; move
    -- those obsolete choices to the direction's intended zoom default instead of
    -- silently turning the shortcuts off.
    local function normalizeMoodleDirection(option, defaultIndex)
        local index = optionIndex(option)
        if index == 4 then
            setOptionIndex(option, 2) -- legacy Moodle Previous -> current index 2
            addLog("Migrated legacy RB moodle direction value 4 to Previous.")
        elseif index == 5 then
            setOptionIndex(option, 3) -- legacy Moodle Next -> current index 3
            addLog("Migrated legacy RB moodle direction value 5 to Next.")
        elseif index == nil or index < 1 or index > 3 then
            setOptionIndex(option, defaultIndex)
            addLog("Reset invalid RB moodle direction value to default index " .. tostring(defaultIndex) .. ".")
        end
    end
    local function normalizeZoomDirection(option, defaultIndex, directionName)
        local index = optionIndex(option)
        if index == 4 or index == 5 then
            setOptionIndex(option, defaultIndex)
            addLog("Migrated obsolete RB+" .. directionName .. " moodle mapping to its zoom default.")
        elseif index == nil or index < 1 or index > 3 then
            setOptionIndex(option, defaultIndex)
            addLog("Reset invalid RB+" .. directionName .. " zoom mapping to default index " .. tostring(defaultIndex) .. ".")
        end
    end
    normalizeMoodleDirection(GQS.rbDpadUpAction, 2)
    normalizeMoodleDirection(GQS.rbDpadDownAction, 3)
    normalizeZoomDirection(GQS.rbDpadLeftAction, 3, "Left")
    normalizeZoomDirection(GQS.rbDpadRightAction, 2, "Right")
    options:addTitle("UI_GQOS_RightRadialTitle")
    GQS.rightRadialFitnessEnabled = options:addTickBox("rightRadialFitnessEnabled", "UI_GQOS_RightRadialFitnessEnabled", true, "UI_GQOS_RightRadialFitnessEnabled_tooltip")
    GQS.rightRadialSkillsEnabled = options:addTickBox("rightRadialSkillsEnabled", "UI_GQOS_RightRadialSkillsEnabled", true, "UI_GQOS_RightRadialSkillsEnabled_tooltip")
    GQS.rightRadialSmashWindowEnabled = options:addTickBox("rightRadialSmashWindowEnabled", "UI_GQOS_RightRadialSmashWindowEnabled", true, "UI_GQOS_RightRadialSmashWindowEnabled_tooltip")
    GQS.rightRadialLightSwitchEnabled = options:addTickBox("rightRadialLightSwitchEnabled", "UI_GQOS_RightRadialLightSwitchEnabled", true, "UI_GQOS_RightRadialLightSwitchEnabled_tooltip")

    options:addTitle("UI_GQOS_RTBFocusTitle")
    GQS.rtBFocusEnabled = options:addTickBox("rtBFocusEnabled", "UI_GQOS_RTBFocusEnabled", true, "UI_GQOS_RTBFocusEnabled_tooltip")

    options:addSeparator()
    options:addTitle("UI_GQOS_PanelEnhancementTitle")
    GQS.fitnessUIEnhancementEnabled = options:addTickBox("fitnessUIEnhancementEnabled", "UI_GQOS_FitnessUIEnhancementEnabled", true, "UI_GQOS_FitnessUIEnhancementEnabled_tooltip")
    GQS.fitnessDefaultDuration = options:addSlider("fitnessDefaultDuration", "UI_GQOS_FitnessDefaultDuration", 10, 60, 10, 30, "UI_GQOS_FitnessDefaultDuration_tooltip")
    GQS.panelInfoEnhancementEnabled = options:addTickBox("panelInfoEnhancementEnabled", "UI_GQOS_PanelInfoEnhancementEnabled", true, "UI_GQOS_PanelInfoEnhancementEnabled_tooltip")
    GQS.nutritionInfoEnabled = options:addTickBox("nutritionInfoEnabled", "UI_GQOS_NutritionInfoEnabled", true, "UI_GQOS_NutritionInfoEnabled_tooltip")

    options:addSeparator()
    options:addTitle("UI_GQOS_MiscFeaturesTitle")
    GQS.mixedLiquidAutoDrinkEnabled = options:addTickBox("mixedLiquidAutoDrinkEnabled", "UI_GQOS_MixedLiquidAutoDrinkEnabled", true, "UI_GQOS_MixedLiquidAutoDrinkEnabled_tooltip")
    GQS.selectWheelPvpOptionEnabled = options:addTickBox("selectWheelPvpOptionEnabled", "UI_GQOS_SelectWheelPvpOptionEnabled", false, "UI_GQOS_SelectWheelPvpOptionEnabled_tooltip")
    GQS.disableSmashWindowBEnabled = options:addTickBox("disableSmashWindowBEnabled", "UI_GQOS_DisableSmashWindowBEnabled", false, "UI_GQOS_DisableSmashWindowBEnabled_tooltip")
end

-- Keep dependent modules that access the historical shared table name working.
GamepadQoLSuiteOptions = GQS

-- The required CustomGamepadUI mod registers its own inventory layout options
-- and its own Select sort mode. This mod takes both over completely (see
-- GQSPanelLayout and GQSSelectAndStartFix), so the upstream controls are hidden
-- to avoid two sets of widgets driving one value. The option objects themselves
-- stay alive because upstream code still reads them.
local function hideUpstreamOwnedOptions()
    if not PZAPI or not PZAPI.ModOptions or not PZAPI.ModOptions.Dict then return end
    local upstream = PZAPI.ModOptions.Dict["CustomGamepadUI"]
    if not upstream or type(upstream.data) ~= "table" then return end
    local owned = {
        invLootWidth = true,
        invHeight = true,
        lootHeight = true,
        invLootPosition = true,
        sortBy = true,
    }
    local hidden = 0
    for _, entry in ipairs(upstream.data) do
        if entry.id and owned[entry.id] then
            entry._gqsHidden = true
            hidden = hidden + 1
        elseif entry.type == "title" and entry.name == "UI_CGUI_invLoot" then
            entry._gqsHidden = true
            hidden = hidden + 1
        end
    end
    if hidden > 0 then
        addLog("Hid " .. tostring(hidden) .. " CustomGamepadUI entries now owned by this mod.")
    end
end

-- Groups are listed in registration order, so the required CustomGamepadUI mod
-- would always come first. Move this mod's group ahead of it so the upstream
-- leftovers (Rack Reload, Focus Combat, ...) follow our own settings.
local function moveOwnGroupBeforeUpstream()
    if not PZAPI or not PZAPI.ModOptions or type(PZAPI.ModOptions.Data) ~= "table" then return end
    local data = PZAPI.ModOptions.Data
    local ownIndex, upstreamIndex
    for index, group in ipairs(data) do
        if group.modOptionsID == "GamepadQoLSuite" then ownIndex = index end
        if group.modOptionsID == "CustomGamepadUI" then upstreamIndex = index end
    end
    if not ownIndex or not upstreamIndex or ownIndex < upstreamIndex then return end
    local own = table.remove(data, ownIndex)
    table.insert(data, upstreamIndex, own)
end

hideUpstreamOwnedOptions()
moveOwnGroupBeforeUpstream()

-- Build the panel without the hidden entries, then restore them right away so
-- PZAPI.ModOptions:save() keeps writing their values to ModOptions.ini.
local previousAddModOptionsPanel = MainOptions and MainOptions.addModOptionsPanel
if previousAddModOptionsPanel and not MainOptions._gqsModOptionsWrapped then
    MainOptions._gqsModOptionsWrapped = true
    function MainOptions:addModOptionsPanel()
        if not PZAPI or not PZAPI.ModOptions or type(PZAPI.ModOptions.Data) ~= "table" then
            return previousAddModOptionsPanel(self)
        end
        local groups = PZAPI.ModOptions.Data
        local stashed = {}
        for index, group in ipairs(groups) do
            if type(group.data) == "table" then
                local visible, hasHidden = {}, false
                for _, entry in ipairs(group.data) do
                    if entry._gqsHidden then
                        hasHidden = true
                    else
                        visible[#visible + 1] = entry
                    end
                end
                if hasHidden then
                    stashed[index] = group.data
                    group.data = visible
                end
            end
        end
        local ok, err = pcall(previousAddModOptionsPanel, self)
        for index, full in pairs(stashed) do
            groups[index].data = full
        end
        if not ok then error(err) end
    end
end

-- Move prior GQS-stored CustomGamepadUI preferences back to the upstream option
-- objects only when the upstream group has no saved value for that option.
local function migrateUpstreamOptions()
    if type(getFileReader) ~= "function" then return end
    local ok, reader = pcall(getFileReader, "ModOptions.ini", true)
    if not ok or not reader then return end
    local gqsValues, baseValues = {}, {}
    pcall(function()
        while true do
            local line = reader:readLine()
            if line == nil then break end
            local typ, group, key, value = line:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if group == "GamepadQoLSuite" then gqsValues[key] = { type = typ, value = value }
            elseif group == "CustomGamepadUI" then baseValues[key] = true end
        end
    end)
    pcall(function() reader:close() end)
    local names = {"rackReload", "focusCombat", "doubleClickWithStart", "hideEquipment", "hideUIElements", "hideNotAttachedWeapons", "tileRadialMenu", "offsetAndExpandMechanicsUI", "doResetLayout"}
    local moved = {}
    for _, key in ipairs(names) do
        local old = gqsValues[key]
        local option = BaseCGUI[key]
        if old and not baseValues[key] and option and type(option.setValue) == "function" then
            local value
            if old.type == "tickbox" then value = old.value == "true" or old.value == "1"
            elseif old.type == "slider" or old.type == "combobox" then value = tonumber(old.value) end
            if value ~= nil and pcall(option.setValue, option, value) then moved[#moved + 1] = key end
        end
    end
    if #moved > 0 then addLog("Moved saved CustomGamepadUI preferences to the upstream mod options: " .. table.concat(moved, ", ") .. ". Apply Mod Options once to persist them.") end
end
migrateUpstreamOptions()

local previousApply = MainOptions and MainOptions.apply
if previousApply and not MainOptions._gqsApplyWrapped then
    MainOptions._gqsApplyWrapped = true
    function MainOptions:apply(closeAfter)
        previousApply(self, closeAfter)
        if type(getNumActivePlayers) == "function" and type(ISPlayerData) == "table" then
            for i = 0, getNumActivePlayers() - 1 do
                local data = ISPlayerData[i + 1]
                if data and data.onResolutionChange then data:onResolutionChange() end
            end
        end
    end
end

return GQS

