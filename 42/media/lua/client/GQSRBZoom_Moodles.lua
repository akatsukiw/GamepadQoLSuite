-- Gamepad QoL Suite: RB + D-pad Moodle browser.
-- The native MoodlesUI icon is wiggle-animated. A small, native-tooltip-style
-- text panel is drawn to its left; this module never moves the real mouse cursor
-- or draws a separate highlight rectangle around the icon.

require "ISUI/ISPanel"

local playerStates = {}
local activationTrackers = {}
local overlay = nil
local overlayPlayerIndex = nil

-- Diagnostics are centrally controlled by GQSDebugLog.lua (category: rbMoodles).
local RB_MOODLE_DEBUG_ONCE = {}

local function debugLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rbMoodles", message)
    end
end

local function debugOnce(key, message)
    if not RB_MOODLE_DEBUG_ONCE[key] then
        RB_MOODLE_DEBUG_ONCE[key] = true
        debugLog(message)
    end
end

local DISPLAY_TIMEOUT_TICKS = 150 -- about 2.5 seconds at 60 ticks/second
local FADE_TICKS = 18
local MOODLE_REFRESH_TICKS = 6 -- refresh displayed moodle data about every 0.1 seconds
local FALLBACK_ICON_SIZE = 48
local FALLBACK_FIRST_ICON_Y = 102 -- shifted down slightly after in-game alignment feedback
local NATIVE_ROW_GAP = 10 -- Build 42.21 MoodlesUI.update(): moodleDistY = 10 + width
-- Preserve the first-row anchor that aligned in the user's in-game test.
local NATIVE_FIRST_ICON_OFFSET_Y = 10
local MIN_PANEL_WIDTH = 112
local MAX_PANEL_WIDTH = 520
local PANEL_PADDING_X = 8
local PANEL_PADDING_Y = 4
local PANEL_ICON_GAP = 18 -- wider clearance so the dark panel never touches the Moodle icon ring
local LINE_HEIGHT = 23 -- closer to vanilla Moodle tooltip line spacing

-- Observed vanilla Build 42 stack order from the user's in-game screenshot,
-- top to bottom: Unhappy, Endurance (fatigue/exhaustion), Hungry, Pain,
-- Thirst, Tired (sleepiness). Only active moodles (level > 0) are navigable.
-- The remaining types below are fallback-ranked only; their relative native
-- order has not yet been confirmed from the Java UI layout.
local MOODLE_ORDER = {
    "UNHAPPY", "ENDURANCE", "HUNGRY", "PAIN", "THIRST", "TIRED",
    "PANIC", "SICK", "BORED", "BLEEDING", "WET", "HAS_A_COLD", "ANGRY",
    "STRESS", "HYPERTHERMIA", "INJURED", "HEAVY_LOAD", "DRUNK", "DEAD",
    "ZOMBIE", "HYPOTHERMIA", "WINDCHILL", "CANT_SPRINT", "UNCOMFORTABLE",
    "NOXIOUS_SMELL", "FOOD_EATEN",
}

local DEFAULT_ACTIONS = {
    Up = "moodlePrevious", Down = "moodleNext", Left = "zoomOut", Right = "zoomIn",
}
local OPTION_KEYS = {
    Up = "rbDpadUpAction", Down = "rbDpadDownAction", Left = "rbDpadLeftAction", Right = "rbDpadRightAction",
}
local DIRECTION_DATA = {
    { name = "Up", button = "DPadUp", opposite = "Down" },
    { name = "Down", button = "DPadDown", opposite = "Up" },
    { name = "Left", button = "DPadLeft", opposite = "Right" },
    { name = "Right", button = "DPadRight", opposite = "Left" },
}
local BUTTON_BY_DIRECTION = {
    Up = "DPadUp", Down = "DPadDown", Left = "DPadLeft", Right = "DPadRight",
}
local ACTION_BY_INDEX = {
    [1] = "none", [2] = "zoomIn", [3] = "zoomOut",
    [4] = "moodlePrevious", [5] = "moodleNext",
}

local function safeField(object, fieldName)
    if not object then return nil end
    local ok, value = pcall(function() return object[fieldName] end)
    if ok then return value end
    return nil
end

local function safeCall(object, methodName, argument)
    if not object then return nil end
    local okMethod, method = pcall(function() return object[methodName] end)
    if not okMethod or type(method) ~= "function" then return nil end
    local ok, value
    if argument ~= nil then
        ok, value = pcall(function() return method(object, argument) end)
    else
        ok, value = pcall(function() return method(object) end)
    end
    if ok then return value end
    return nil
end

-- Build 42's Kahlua binding does not expose java.lang.reflect.Field methods
-- such as Class:getDeclaredField(). Do not attempt Java reflection here: doing
-- so throws every frame while RB+direction is held. Read only fields exposed
-- directly by Lua and log once when the private MoodlesUI map is unavailable.
local PRIVATE_FIELD_UNAVAILABLE = {}
local function readJavaField(object, fieldName)
    local value = safeField(object, fieldName)
    if value == nil then
        local key = tostring(fieldName)
        if not PRIVATE_FIELD_UNAVAILABLE[key] then
            PRIVATE_FIELD_UNAVAILABLE[key] = true
            debugLog("Field '" .. key .. "' is not exposed to Lua; no Java reflection will be attempted.")
        end
    end
    return value
end

local function getNativeMoodleStateMap(moodleUI)
    return readJavaField(moodleUI, "moodleUiState")
end

local function getMoodleLayoutData(moodleUI, moodleType, stateMap)
    stateMap = stateMap or getNativeMoodleStateMap(moodleUI)
    if not stateMap or not moodleType then return nil end
    local ok, data = pcall(function() return stateMap:get(moodleType) end)
    if ok and data then return data end
    local okIndex, dataByIndex = pcall(function() return stateMap[moodleType] end)
    if okIndex then return dataByIndex end
    return nil
end

local function readPosition(data, name)
    local n = tonumber(readJavaField(data, name))
    if n and n >= 0 and n < 9000 then return n end
    return nil
end

local function collectMapEntries(stateMap)
    if not stateMap then return nil end
    local okIterator, iterator = pcall(function() return stateMap:entrySet():iterator() end)
    if not okIterator or not iterator then return nil end
    local entries = {}
    local guard = 0
    while guard < 512 do
        local okHas, hasNext = pcall(function() return iterator:hasNext() end)
        if not okHas then return nil end
        if not hasNext then break end
        local okEntry, entry = pcall(function() return iterator:next() end)
        if not okEntry or not entry then return nil end
        local okKey, key = pcall(function() return entry:getKey() end)
        local okValue, value = pcall(function() return entry:getValue() end)
        if okKey and okValue and key ~= nil and value ~= nil then
            entries[#entries + 1] = { type = key, data = value }
        end
        guard = guard + 1
    end
    return entries
end

local function getMoodleKeyAndFallbackRank(moodleType, moodleTypeClass)
    for rank, typeName in ipairs(MOODLE_ORDER) do
        if moodleTypeClass and safeField(moodleTypeClass, typeName) == moodleType then
            return typeName, rank
        end
    end
    local translationName = safeCall(moodleType, "getTranslationName")
    if type(translationName) == "string" and translationName ~= "" then
        return translationName, 10000
    end
    return tostring(moodleType), 10000
end

-- The vanilla Build 42 MoodlesUI constructor fills a java.util.HashMap using
-- Registries.MOODLE_TYPE.values().  MoodlesUI.update() iterates entrySet() in
-- that HashMap order and assigns slots to active moodles in the same pass.
-- When Lua cannot see the private map, mirror Java HashMap's bucket order from
-- the public registry list and each MoodleType object's hashCode().  This does
-- not use reflection and is enabled only when every required value is readable.
local nativeHashMapOrderCache = nil
local nativeHashMapOrderFailure = nil

local function xor32(a, b)
    a = math.floor(tonumber(a) or 0) % 4294967296
    b = math.floor(tonumber(b) or 0) % 4294967296
    local result, bitValue = 0, 1
    for _ = 1, 32 do
        local abit = a % 2
        local bbit = b % 2
        if abit ~= bbit then result = result + bitValue end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitValue = bitValue * 2
    end
    return result
end

local function getMoodleRegistryList()
    local registriesClass = rawget(_G, "Registries")
    if not registriesClass and luajava and type(luajava.bindClass) == "function" then
        local ok, value = pcall(function()
            return luajava.bindClass("zombie.scripting.objects.Registries")
        end)
        if ok then registriesClass = value end
    end
    if not registriesClass then return nil, "Registries class unavailable" end

    local registry = safeField(registriesClass, "MOODLE_TYPE")
    if not registry then return nil, "Registries.MOODLE_TYPE unavailable" end

    local values = safeCall(registry, "values")
    if not values then return nil, "Moodle registry values() unavailable" end
    local count = tonumber(safeCall(values, "size"))
    if not count or count < 1 or count > 512 then
        return nil, "Moodle registry size unavailable or unreasonable"
    end

    local types = {}
    for index = 0, math.floor(count) - 1 do
        local moodleType = safeCall(values, "get", index)
        if not moodleType then
            return nil, "Could not read registry value at index " .. tostring(index)
        end
        types[#types + 1] = moodleType
    end
    return types
end

local function getNativeHashMapOrder(moodleTypeClass)
    if nativeHashMapOrderCache then return nativeHashMapOrderCache end
    if nativeHashMapOrderFailure then return nil end

    local registeredTypes, registryError = getMoodleRegistryList()
    if not registeredTypes then
        nativeHashMapOrderFailure = registryError or "registry unavailable"
        debugOnce("hashmap-order-unavailable", "Cannot mirror native MoodlesUI HashMap order: " .. tostring(nativeHashMapOrderFailure) .. ". Using the stable fallback order.")
        return nil
    end

    local count = #registeredTypes
    -- java.util.HashMap() starts at capacity 16 and resizes above its 0.75 load threshold.
    local capacity = 16
    while count > math.floor(capacity * 0.75) do capacity = capacity * 2 end

    local records, bucketCounts = {}, {}
    for registryIndex, moodleType in ipairs(registeredTypes) do
        local rawHash = tonumber(safeCall(moodleType, "hashCode"))
        if rawHash == nil then
            nativeHashMapOrderFailure = "MoodleType.hashCode() unavailable at registry index " .. tostring(registryIndex - 1)
            debugOnce("hashmap-order-unavailable", "Cannot mirror native MoodlesUI HashMap order: " .. tostring(nativeHashMapOrderFailure) .. ". Using the stable fallback order.")
            return nil
        end

        -- HashMap.hash(key) is h ^ (h >>> 16), using a 32-bit int.
        local unsignedHash = math.floor(rawHash) % 4294967296
        local spreadHash = xor32(unsignedHash, math.floor(unsignedHash / 65536))
        local bucket = spreadHash % capacity
        local key = getMoodleKeyAndFallbackRank(moodleType, moodleTypeClass)
        records[#records + 1] = {
            type = moodleType,
            key = key,
            bucket = bucket,
            registryIndex = registryIndex,
        }
        bucketCounts[bucket] = (bucketCounts[bucket] or 0) + 1
    end

    -- HashMap treeifies unusually large collision bins. Do not guess its tree-bin
    -- iteration order; retain the previous stable fallback if this ever occurs.
    for bucket, amount in pairs(bucketCounts) do
        if amount >= 8 then
            nativeHashMapOrderFailure = "HashMap bucket " .. tostring(bucket) .. " has " .. tostring(amount) .. " collisions; tree-bin order is not mirrored"
            debugOnce("hashmap-order-unavailable", "Cannot mirror native MoodlesUI HashMap order: " .. tostring(nativeHashMapOrderFailure) .. ". Using the stable fallback order.")
            return nil
        end
    end

    -- Java HashMap iterates table buckets from low to high. For ordinary linked
    -- bins, node order follows registry insertion order, including after resize.
    table.sort(records, function(a, b)
        if a.bucket ~= b.bucket then return a.bucket < b.bucket end
        return a.registryIndex < b.registryIndex
    end)

    local ranks, orderedNames = {}, {}
    for rank, record in ipairs(records) do
        if ranks[record.key] == nil then ranks[record.key] = rank end
        orderedNames[#orderedNames + 1] = tostring(record.key) .. "[b" .. tostring(record.bucket) .. "]"
    end

    nativeHashMapOrderCache = {
        ranks = ranks,
        entries = records,
        registrySize = count,
        capacity = capacity,
    }
    debugLog("Native HashMap-order mirror ready: registrySize=" .. tostring(count) ..
        ", capacity=" .. tostring(capacity) .. ", computed slot iteration=" .. table.concat(orderedNames, " > "))
    return nativeHashMapOrderCache
end

local function readOptionValue(option)
    if not option then return nil end
    if type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok and value ~= nil then return value end
    end
    return safeField(option, "value")
end

local function getConfiguredAction(direction)
    local shared = rawget(_G, "GQS_RBControls")
    if shared and type(shared.getAction) == "function" then
        local ok, value = pcall(shared.getAction, direction)
        if ok and type(value) == "string" then return value end
    end
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    if options then
        local enabled = readOptionValue(options.rbExtensionsEnabled)
        if enabled == false or enabled == 0 then return "none" end
        local index = tonumber(readOptionValue(options[OPTION_KEYS[direction] or ""]))
        if index and ACTION_BY_INDEX[index] then return ACTION_BY_INDEX[index] end
    end
    return DEFAULT_ACTIONS[direction] or "none"
end

local function getScreenSize()
    local core = type(getCore) == "function" and getCore() or nil
    local width = tonumber(safeCall(core, "getScreenWidth")) or 1920
    local height = tonumber(safeCall(core, "getScreenHeight")) or 1080
    return math.max(640, width), math.max(480, height)
end

local function getPlayerScreenArea(playerIndex)
    local screenW, screenH = getScreenSize()
    local area = { left = 0, top = 0, width = screenW, height = screenH }
    if type(getPlayerScreenLeft) == "function" then
        local ok, value = pcall(getPlayerScreenLeft, playerIndex)
        if ok and tonumber(value) then area.left = tonumber(value) end
    end
    if type(getPlayerScreenTop) == "function" then
        local ok, value = pcall(getPlayerScreenTop, playerIndex)
        if ok and tonumber(value) then area.top = tonumber(value) end
    end
    if type(getPlayerScreenWidth) == "function" then
        local ok, value = pcall(getPlayerScreenWidth, playerIndex)
        if ok and tonumber(value) and tonumber(value) > 0 then area.width = tonumber(value) end
    end
    if type(getPlayerScreenHeight) == "function" then
        local ok, value = pcall(getPlayerScreenHeight, playerIndex)
        if ok and tonumber(value) and tonumber(value) > 0 then area.height = tonumber(value) end
    end
    area.left = math.max(0, math.min(screenW, area.left))
    area.top = math.max(0, math.min(screenH, area.top))
    area.width = math.max(1, math.min(area.width, screenW - area.left))
    area.height = math.max(1, math.min(area.height, screenH - area.top))
    return area
end

local function getJoypadBind(playerIndex)
    local player = getSpecificPlayer and getSpecificPlayer(playerIndex) or nil
    local bind = tonumber(safeCall(player, "getJoypadBind"))
    if bind and bind >= 0 then return bind end
    return -1
end

local function isButtonDown(buttonName, joypadBind)
    if type(joypadBind) ~= "number" or joypadBind < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local button = buttons and buttons[buttonName]
    if button and type(button.isDown) == "function" then
        local ok, down = pcall(function() return button:isDown(joypadBind) end)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    local legacyButton = joypad and joypad[buttonName]
    if legacyButton ~= nil and type(isJoypadPressed) == "function" then
        local ok, down = pcall(function() return isJoypadPressed(joypadBind, legacyButton) end)
        if ok then return down == true end
    end
    return false
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
    return safeField(page, "visible") == true
end

local function areInventoryWindowsClosed(playerIndex)
    local inventoryPage = getPlayerInventory and getPlayerInventory(playerIndex) or nil
    local lootPage = getPlayerLoot and getPlayerLoot(playerIndex) or nil
    return not pageIsVisible(inventoryPage) and not pageIsVisible(lootPage)
end

local function getPlayerMoodles(playerIndex)
    local player = getSpecificPlayer and getSpecificPlayer(playerIndex) or nil
    return safeCall(player, "getMoodles")
end

local function getMoodleTypeClass()
    local class = rawget(_G, "MoodleType")
    if class then return class end
    if luajava and type(luajava.bindClass) == "function" then
        local ok, value = pcall(function() return luajava.bindClass("zombie.scripting.objects.MoodleType") end)
        if ok then return value end
    end
    return nil
end

local getMoodlesUI

local function summarizeMoodles(active)
    local names = {}
    for _, item in ipairs(active or {}) do
        names[#names + 1] = tostring(item.key) .. " Lv" .. tostring(item.level)
    end
    if #names == 0 then return "(none)" end
    return table.concat(names, " > ")
end

local function applyStableFallbackOrder(playerIndex, active)
    local tracker = activationTrackers[playerIndex]
    if not tracker then
        tracker = { lastSignature = nil, lastSource = "stable-moodletype-order-fallback" }
        activationTrackers[playerIndex] = tracker
    end

    -- Build 42 does not expose MoodlesUI.moodleUiState to the Lua binding.
    -- Activation chronology is NOT the native stack order. Use a stable fallback
    -- ranking, with the first six entries confirmed by the user's screenshot:
    -- UNHAPPY > ENDURANCE > HUNGRY > PAIN > THIRST > TIRED. Other types remain
    -- provisional until their native slot order can be observed.
    table.sort(active, function(a, b)
        if a.fallbackRank ~= b.fallbackRank then
            return a.fallbackRank < b.fallbackRank
        end
        return tostring(a.key) < tostring(b.key)
    end)

    local signature = summarizeMoodles(active)
    if signature ~= tracker.lastSignature then
        tracker.lastSignature = signature
        debugLog("Player " .. playerIndex .. " active order [stable MoodleType fallback; native private layout unavailable]: " .. signature)
    end
    tracker.lastSource = "stable-moodletype-order-fallback"
end

local function getActiveMoodles(playerIndex)
    local moodles = getPlayerMoodles(playerIndex)
    local moodleTypeClass = getMoodleTypeClass()
    if not moodles or not moodleTypeClass then return {} end

    local moodleUI = getMoodlesUI and getMoodlesUI(playerIndex) or nil
    local stateMap = moodleUI and getNativeMoodleStateMap(moodleUI) or nil
    local entries = collectMapEntries(stateMap)
    if entries and #entries == 0 then entries = nil end
    local nativeHashOrder = nil
    if not entries then
        nativeHashOrder = getNativeHashMapOrder(moodleTypeClass)
    end
    local active, seen = {}, {}

    local function addType(moodleType, data)
        if not moodleType then return end
        local key, fallbackRank = getMoodleKeyAndFallbackRank(moodleType, moodleTypeClass)
        if seen[key] then return end
        local level = tonumber(safeCall(moodles, "getMoodleLevel", moodleType)) or 0
        if level <= 0 then return end
        local displayName = safeCall(moodles, "getMoodleDisplayString", moodleType)
        local description = safeCall(moodles, "getMoodleDescriptionString", moodleType)
        if type(displayName) ~= "string" or displayName == "" then
            displayName = tostring(key):gsub("_", " ")
        end
        if type(description) ~= "string" then description = "" end
        local currentPos = readPosition(data, "slotsPos")
        local desiredPos = readPosition(data, "slotsDesiredPos")
        -- slotsDesiredPos reflects the game's target stack position. Use it for
        -- navigation order; slotsPos is the live animated position for placement.
        local sortPos = desiredPos or currentPos
        active[#active + 1] = {
            key = key,
            type = moodleType,
            level = level,
            title = displayName,
            description = description,
            sortPos = sortPos,
            renderPos = currentPos,
            fallbackRank = fallbackRank,
        }
        seen[key] = true
    end

    -- Prefer the exact set and native slot order maintained by MoodlesUI. This
    -- also accommodates moodle types registered by other mods when exposed here.
    if entries then
        for _, entry in ipairs(entries) do addType(entry.type, entry.data) end
    else
        debugOnce("native-order-fallback", "MoodlesUI.moodleUiState is not iterable through the Build 42 Lua binding; trying public-registry HashMap-order mirroring before falling back.")
    end

    -- Compatibility fallback for runtimes where Java Map iteration is not
    -- available from Lua. It still reads per-type layout data when possible.
    if #active == 0 then
        for _, typeName in ipairs(MOODLE_ORDER) do
            local moodleType = safeField(moodleTypeClass, typeName)
            if moodleType then
                local data = stateMap and getMoodleLayoutData(moodleUI, moodleType, stateMap) or nil
                addType(moodleType, data)
            end
        end
    else
        -- Include any vanilla types missing from a partially exposed map.
        for _, typeName in ipairs(MOODLE_ORDER) do
            local moodleType = safeField(moodleTypeClass, typeName)
            if moodleType and not seen[typeName] then
                local data = stateMap and getMoodleLayoutData(moodleUI, moodleType, stateMap) or nil
                addType(moodleType, data)
            end
        end
    end

    -- If MoodlesUI's private map is inaccessible but the public registry is
    -- available, include registered moodle types added by other mods as well.
    if not entries and nativeHashOrder then
        for _, registryEntry in ipairs(nativeHashOrder.entries) do
            if registryEntry.type then addType(registryEntry.type, nil) end
        end
    end

    if entries then
        table.sort(active, function(a, b)
            if a.sortPos ~= nil and b.sortPos ~= nil and a.sortPos ~= b.sortPos then
                return a.sortPos < b.sortPos
            end
            if a.sortPos ~= nil and b.sortPos == nil then return true end
            if a.sortPos == nil and b.sortPos ~= nil then return false end
            if a.fallbackRank ~= b.fallbackRank then return a.fallbackRank < b.fallbackRank end
            return tostring(a.key) < tostring(b.key)
        end)
        for i, item in ipairs(active) do item.nativeOrderIndex = i - 1 end
        local tracker = activationTrackers[playerIndex]
        if tracker then tracker.lastSource = "native-layout" end
    elseif nativeHashOrder then
        table.sort(active, function(a, b)
            local rankA = nativeHashOrder.ranks[a.key]
            local rankB = nativeHashOrder.ranks[b.key]
            if rankA ~= nil and rankB ~= nil and rankA ~= rankB then return rankA < rankB end
            if rankA ~= nil and rankB == nil then return true end
            if rankA == nil and rankB ~= nil then return false end
            if a.fallbackRank ~= b.fallbackRank then return a.fallbackRank < b.fallbackRank end
            return tostring(a.key) < tostring(b.key)
        end)
        for i, item in ipairs(active) do item.nativeOrderIndex = i - 1 end
        local tracker = activationTrackers[playerIndex]
        if not tracker then
            tracker = { lastSignature = nil, lastSource = "native-hashmap-order-mirror" }
            activationTrackers[playerIndex] = tracker
        end
        local signature = summarizeMoodles(active)
        if signature ~= tracker.lastSignature then
            tracker.lastSignature = signature
            debugLog("Player " .. playerIndex .. " active order [native HashMap-order mirror]: " .. signature)
        end
        tracker.lastSource = "native-hashmap-order-mirror"
    else
        applyStableFallbackOrder(playerIndex, active)
        for i, item in ipairs(active) do item.nativeOrderIndex = i - 1 end
        local tracker = activationTrackers[playerIndex]
        if tracker then tracker.lastSource = "stable-moodletype-order-fallback" end
    end
    return active
end

getMoodlesUI = function(playerIndex)
    if UIManager and type(UIManager.getMoodleUI) == "function" then
        local ok, ui = pcall(function() return UIManager.getMoodleUI(playerIndex) end)
        if ok and ui then return ui end
    end
    local moodleUIClass = rawget(_G, "MoodlesUI")
    if moodleUIClass and type(moodleUIClass.getInstance) == "function" then
        local ok, ui = pcall(function() return moodleUIClass.getInstance() end)
        if ok then return ui end
    end
    return nil
end

local function getIconSize(moodleUI)
    -- Keep the already-tested panel/icon rectangle geometry unchanged. The
    -- actual native size is queried separately for vertical row spacing below.
    local size = tonumber(safeCall(moodleUI, "getTextureSizeForOption"))
    if size and size >= 24 and size <= 128 then return size end
    local core = type(getCore) == "function" and getCore() or nil
    local option = tonumber(safeCall(core, "getOptionMoodleSize"))
    local map = { [0] = 32, [1] = 32, [2] = 40, [3] = 48, [4] = 64 }
    if option and map[option] then return map[option] end
    return FALLBACK_ICON_SIZE
end

local function getNativeRowIconSize(moodleUI, fallbackSize)
    -- MoodlesUI inherits the public UIElement:getWidth() accessor. Its width is
    -- set to the exact texture size (32/48/64/80/96/128) in the native ctor.
    local size = tonumber(safeCall(moodleUI, "getWidth"))
    if size and size >= 24 and size <= 128 then return size end

    -- Mirror the native textureSizes array if this binding lacks getWidth().
    local core = type(getCore) == "function" and getCore() or nil
    local option = tonumber(safeCall(core, "getOptionMoodleSize"))
    local map = { [0] = 32, [1] = 32, [2] = 48, [3] = 64, [4] = 80, [5] = 96, [6] = 128 }
    if option == 7 then
        local fontOption = tonumber(safeCall(core, "getOptionFontSizeReal"))
        if fontOption and map[fontOption] then return map[fontOption] end
    end
    if option and map[option] then return map[option] end
    return fallbackSize or FALLBACK_ICON_SIZE
end

local function getIconRect(playerIndex, item, activeIndex)
    local screenW, screenH = getScreenSize()
    local area = getPlayerScreenArea(playerIndex)
    local moodleUI = getMoodlesUI(playerIndex)
    local iconSize = getIconSize(moodleUI) -- preserves prior panel rectangle alignment
    local rowIconSize = getNativeRowIconSize(moodleUI, iconSize)
    local x = area.left + area.width - iconSize - 10

    local absY = moodleUI and tonumber(safeCall(moodleUI, "getAbsoluteY")) or nil
    local localY = moodleUI and tonumber(safeCall(moodleUI, "getY")) or nil
    local uiY = absY or localY or 0
    local uiX = moodleUI and (tonumber(safeCall(moodleUI, "getAbsoluteX")) or tonumber(safeCall(moodleUI, "getX"))) or nil
    local y, ySource

    if item and item.renderPos ~= nil then
        -- slotsPos is currently private in the observed B42 Lua binding, but keep
        -- this path for runtimes/mods that expose it directly.
        y = uiY + item.renderPos
        ySource = "native-slotsPos"
    end

    if not y or y < 0 or y > screenH - iconSize then
        -- If the MoodlesUI widget itself has a useful absolute screen anchor, use
        -- its top + the game's documented default Moodle distance. This is more
        -- robust than a fixed screen Y when the widget/HUD placement changes.
        local anchorY = nil
        local anchorSource = nil
        if absY and absY >= 40 and absY < screenH - iconSize then
            anchorY, anchorSource = absY, "MoodlesUI:absoluteY+defaultInset"
        elseif localY and localY >= 40 and localY < screenH - iconSize then
            anchorY, anchorSource = localY, "MoodlesUI:y+defaultInset"
        end
        if anchorY then
            local rowPitch = rowIconSize + NATIVE_ROW_GAP
            y = anchorY + NATIVE_FIRST_ICON_OFFSET_Y + (activeIndex - 1) * rowPitch
            ySource = anchorSource .. ";pitch=" .. tostring(rowPitch) .. ";rowIconSize=" .. tostring(rowIconSize) .. ";panelIconSize=" .. tostring(iconSize)
        else
            local rowPitch = rowIconSize + NATIVE_ROW_GAP
            y = area.top + FALLBACK_FIRST_ICON_Y + (activeIndex - 1) * rowPitch
            ySource = "screen-absolute-fallback;pitch=" .. tostring(rowPitch) .. ";rowIconSize=" .. tostring(rowIconSize) .. ";panelIconSize=" .. tostring(iconSize)
        end
    end

    y = math.max(area.top + 4, math.min(area.top + area.height - iconSize - 4, y))
    x = math.max(area.left + 4, math.min(area.left + area.width - iconSize - 4, x))
    return {
        x = x, y = y, w = iconSize, h = iconSize,
        ySource = ySource or "unknown",
        moodleUIY = localY,
        moodleUIAbsY = absY,
        moodleUIX = uiX,
        screenW = screenW,
        screenH = screenH,
        areaLeft = area.left,
        areaTop = area.top,
        areaWidth = area.width,
        areaHeight = area.height,
    }
end

-- Read-only state/anchor API for the shortcut-hint module. It reuses the same
-- per-player viewport and native MoodlesUI geometry, and includes active Moodle
-- levels so the shortcut cue can flash only when a Moodle appears or rises.
local shortcutHintAnchorTick = 0
local shortcutHintAnchorCache = {}
local function getShortcutHintAnchors(playerIndex)
    playerIndex = tonumber(playerIndex)
    if playerIndex == nil or playerIndex < 0 or playerIndex > 3 then return nil end

    local cached = shortcutHintAnchorCache[playerIndex]
    if cached and (shortcutHintAnchorTick - cached.tick) < MOODLE_REFRESH_TICKS then
        return cached.anchors
    end

    local active = getActiveMoodles(playerIndex)
    local levels = {}
    for _, item in ipairs(active or {}) do
        levels[tostring(item.key)] = tonumber(item.level) or 0
    end

    -- Keep a state snapshot even when no moodles are active. The shortcut-hint
    -- module compares these levels and only flashes its control cue when a
    -- Moodle appears or rises in level; it does not leave prompts permanently on.
    local anchors = { levels = levels, count = active and #active or 0 }
    if active and #active > 0 then
        anchors.top = getIconRect(playerIndex, active[1], 1)
        anchors.bottom = getIconRect(playerIndex, active[#active], #active)
    end

    shortcutHintAnchorCache[playerIndex] = { tick = shortcutHintAnchorTick, anchors = anchors }
    return anchors
end

GQSRBZoomMoodles = GQSRBZoomMoodles or {}
GQSRBZoomMoodles.getShortcutHintAnchors = getShortcutHintAnchors

local function measureText(text, font)
    if getTextManager and font then
        local ok, width = pcall(function() return getTextManager():MeasureStringX(font, text) end)
        if ok and type(width) == "number" then return width end
    end
    return #tostring(text or "") * 8
end

local function wrapUTF8(text, maxWidth, font)
    local lines = {}
    text = tostring(text or "")
    for paragraph in string.gmatch(text .. "\n", "(.-)\n") do
        if paragraph == "" then
            lines[#lines + 1] = ""
        else
            local line = ""
            for char in string.gmatch(paragraph, "[^\128-\191][\128-\191]*") do
                local candidate = line .. char
                if line ~= "" and measureText(candidate, font) > maxWidth then
                    lines[#lines + 1] = line
                    line = char
                else
                    line = candidate
                end
            end
            if line ~= "" then lines[#lines + 1] = line end
        end
    end
    return lines
end

local function ensureOverlay()
    if overlay then return overlay end
    if type(ISPanel) ~= "table" then return nil end

    local Panel = ISPanel:derive("GQSRBMoodleTooltipPanel")
    function Panel:new(x, y, width, height)
        local instance = ISPanel.new(self, x, y, width, height)
        setmetatable(instance, self)
        self.__index = self
        instance.background = false
        instance.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        instance.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        instance.viewData = nil
        return instance
    end

    function Panel:render()
        if ISPanel.render then ISPanel.render(self) end
        local view = self.viewData
        if not view or (view.alpha or 0) <= 0 then return end
        local alpha = math.max(0, math.min(1, view.alpha or 1))
        local x, y, w, h = view.panelX, view.panelY, view.panelW, view.panelH
        local font = UIFont and (UIFont.Small or UIFont.Medium) or nil
        if not font then return end

        -- Use one consistent dark panel, like the vanilla tooltip. The title
        -- (moodle name + level) is right-aligned near the icon side, while the
        -- description lines remain left-aligned. A common background also
        -- avoids uneven per-line rectangles when text widths differ.
        self:drawRect(x, y, w, h, alpha * 0.80, 0.025, 0.03, 0.035)

        local title = view.titleLine or "状态"
        local titleWidth = measureText(title, font)
        -- Preserve vanilla-style right alignment, but leave a few pixels of
        -- extra clearance at the panel's right edge so the final level digit
        -- (for example, "Lv2") cannot visually protrude from the dark panel.
        local titleX = x + w - titleWidth - 5
        if titleX < x + PANEL_PADDING_X then titleX = x + PANEL_PADDING_X end
        self:drawText(title, titleX, y + PANEL_PADDING_Y,
            0.88, 0.90, 0.92, alpha, font)

        local lineY = y + PANEL_PADDING_Y + LINE_HEIGHT
        for i = 1, #(view.descriptionLines or {}) do
            self:drawText(view.descriptionLines[i], x + PANEL_PADDING_X, lineY,
                0.79, 0.81, 0.83, alpha, font)
            lineY = lineY + LINE_HEIGHT
        end
    end

    local screenW, screenH = getScreenSize()
    local ok, instance = pcall(function()
        local panel = Panel:new(0, 0, screenW, screenH)
        panel:initialise()
        panel:noBackground()
        if type(panel.setConsumeMouseEvents) == "function" then panel:setConsumeMouseEvents(false) end
        if type(panel.setCapture) == "function" then panel:setCapture(false) end
        if type(panel.setAlwaysOnTop) == "function" then panel:setAlwaysOnTop(true) end
        panel:setVisible(false)
        panel:addToUIManager()
        return panel
    end)
    if ok then overlay = instance end
    return overlay
end

local function makeView(playerIndex, item, activeIndex, alpha)
    local iconRect = getIconRect(playerIndex, item, activeIndex)
    local areaLeft, areaTop = iconRect.areaLeft, iconRect.areaTop
    local areaWidth, areaHeight = iconRect.areaWidth, iconRect.areaHeight
    local bodyFont = UIFont and (UIFont.Small or UIFont.Medium) or nil
    local levelShort = type(getText) == "function" and getText("UI_GQOS_RBMoodle_LevelShort") or "Lv"
    if type(levelShort) ~= "string" or levelShort == "" then levelShort = "Lv" end
    local titleLine = tostring(item.title or "状态") .. " " .. levelShort .. tostring(item.level or 0)

    -- Match the native tooltip's content-driven width instead of the old 300px
    -- cap. Anchor its right edge to the left of the actual icon region with a wider gap;
    -- when the screen is narrow, use all available space and wrap the text.
    local panelRight = iconRect.x - PANEL_ICON_GAP
    local availableWidth = math.max(96, panelRight - areaLeft - 8)
    local maxPanelW = math.max(96, math.min(MAX_PANEL_WIDTH, areaWidth - 20, availableWidth))
    local titleWidth = measureText(titleLine, bodyFont)
    local descWidth = measureText(item.description or "", bodyFont)
    local desiredTextWidth = math.max(titleWidth, math.min(descWidth, maxPanelW - PANEL_PADDING_X * 2))
    local panelW = math.max(MIN_PANEL_WIDTH, math.min(maxPanelW, desiredTextWidth + PANEL_PADDING_X * 2))
    local descriptionLines = wrapUTF8(item.description or "", panelW - PANEL_PADDING_X * 2, bodyFont)
    if #descriptionLines == 0 then descriptionLines[1] = "" end
    while #descriptionLines > 6 do table.remove(descriptionLines) end
    local panelH = PANEL_PADDING_Y * 2 + (#descriptionLines + 1) * LINE_HEIGHT + 1

    local panelX = panelRight - panelW
    panelX = math.max(areaLeft + 8, math.min(areaLeft + areaWidth - panelW - 8, panelX))
    local panelY = iconRect.y + math.floor((iconRect.h - panelH) / 2)
    panelY = math.max(areaTop + 8, math.min(areaTop + areaHeight - panelH - 8, panelY))

    return {
        titleLine = titleLine,
        descriptionLines = descriptionLines,
        panelX = panelX,
        panelY = panelY,
        panelW = panelW,
        panelH = panelH,
        alpha = alpha,
        iconY = iconRect.y,
        iconYSource = iconRect.ySource,
        moodleUIY = iconRect.moodleUIY,
        moodleUIAbsY = iconRect.moodleUIAbsY,
        moodleUIX = iconRect.moodleUIX,
        screenW = iconRect.screenW,
        screenH = iconRect.screenH,
        areaLeft = areaLeft,
        areaTop = areaTop,
        areaWidth = areaWidth,
        areaHeight = areaHeight,
    }
end

local function getState(playerIndex)
    local state = playerStates[playerIndex]
    if not state then
        state = { chordDown = {}, selectedKey = nil, timer = 0, alpha = 0, orderPollTicks = 0, rbWasDown = false, dpadDownAtRB = {} }
        playerStates[playerIndex] = state
    end
    return state
end

local nativeHoverSuppressed = {}

local function suppressNativeHover(playerIndex)
    if nativeHoverSuppressed[playerIndex] then return end
    local moodleUI = getMoodlesUI(playerIndex)
    if not moodleUI then return end
    -- Use the public UI callback instead of writing private fields via Java
    -- reflection. That avoids the unsupported getDeclaredField() call in B42.
    local ok, err = pcall(function() moodleUI:onMouseMoveOutside(0, 0) end)
    if ok then
        nativeHoverSuppressed[playerIndex] = moodleUI
        debugLog("Player " .. playerIndex .. " native hover tooltip suppressed via onMouseMoveOutside().")
    else
        debugOnce("hover-suppress-fail", "Could not suppress native tooltip with onMouseMoveOutside(): " .. tostring(err))
    end
end

local function refreshNativeHover(playerIndex)
    local moodleUI = nativeHoverSuppressed[playerIndex]
    if not moodleUI then return end
    nativeHoverSuppressed[playerIndex] = nil
    local ok, err = pcall(function() moodleUI:onMouseMove(0, 0) end)
    if ok then
        debugLog("Player " .. playerIndex .. " native hover recalculated after controller tooltip dismissal.")
    else
        debugOnce("hover-refresh-fail", "Could not refresh native tooltip with onMouseMove(): " .. tostring(err))
    end
end

local function dismiss(state, playerIndex)
    if playerIndex ~= nil and (state.selectedKey ~= nil or nativeHoverSuppressed[playerIndex]) then
        refreshNativeHover(playerIndex)
    end
    state.selectedKey = nil
    state.timer = 0
    state.alpha = 0
    state.activeMoodles = nil
    state.viewData = nil
    state.viewDirty = false
    state.orderPollTicks = 0
    if overlay and (overlayPlayerIndex == nil or playerIndex == nil or overlayPlayerIndex == playerIndex) then
        overlay.viewData = nil
        overlay:setVisible(false)
        overlayPlayerIndex = nil
    end
end

local function selectDirection(playerIndex, direction, directionName)
    local active = getActiveMoodles(playerIndex)
    local state = getState(playerIndex)
    if #active == 0 then
        state.activeMoodles = active
        state.orderPollTicks = 0
        state.viewDirty = state.selectedKey ~= nil
        debugLog("Player " .. playerIndex .. " RB+DPad" .. tostring(directionName or "?") ..
            " action requested but no active moodles were found.")
        return false
    end
    local currentIndex = nil
    if state.selectedKey then
        for i, item in ipairs(active) do
            if item.key == state.selectedKey then currentIndex = i; break end
        end
    end
    local nextIndex
    if not currentIndex then
        nextIndex = direction > 0 and 1 or #active
    else
        nextIndex = currentIndex + direction
        if nextIndex < 1 then nextIndex = #active end
        if nextIndex > #active then nextIndex = 1 end
    end
    local selected = active[nextIndex]
    local tracker = activationTrackers[playerIndex]
    debugLog("Player " .. playerIndex .. " RB+DPad" .. tostring(directionName or "?") ..
        " selected " .. tostring(selected.key) .. " (" .. tostring(selected.title) .. ") Lv" ..
        tostring(selected.level) .. "; index=" .. tostring(nextIndex) .. "/" .. tostring(#active) ..
        "; orderSource=" .. tostring(tracker and tracker.lastSource or "unknown") ..
        "; order=" .. summarizeMoodles(active))
    state.selectedKey = selected.key
    state.activeMoodles = active
    state.orderPollTicks = 0
    state.viewDirty = false
    overlayPlayerIndex = playerIndex
    state.timer = DISPLAY_TIMEOUT_TICKS
    state.alpha = 1
    local moodleUI = getMoodlesUI(playerIndex)
    if moodleUI then safeCall(moodleUI, "wiggle", selected.type) end
    suppressNativeHover(playerIndex)
    local panel = ensureOverlay()
    if panel then
        state.viewData = makeView(playerIndex, selected, nextIndex, state.alpha)
        panel.viewData = state.viewData
        panel:setVisible(true)
        debugLog("Player " .. playerIndex .. " tooltip panel placed at x=" .. tostring(panel.viewData.panelX) ..
            ", y=" .. tostring(panel.viewData.panelY) .. ", w=" .. tostring(panel.viewData.panelW) ..
            ", h=" .. tostring(panel.viewData.panelH) .. "; icon row=" .. tostring(nextIndex) ..
            ", iconTopY=" .. tostring(panel.viewData.iconY) .. ", ySource=" .. tostring(panel.viewData.iconYSource) ..
            ", MoodlesUI y=" .. tostring(panel.viewData.moodleUIY) .. ", absY=" .. tostring(panel.viewData.moodleUIAbsY) ..
            ", x=" .. tostring(panel.viewData.moodleUIX) .. ", screen=" .. tostring(panel.viewData.screenW) .. "x" .. tostring(panel.viewData.screenH) ..
            ", player viewport=" .. tostring(panel.viewData.areaLeft) .. "," .. tostring(panel.viewData.areaTop) .. " " ..
            tostring(panel.viewData.areaWidth) .. "x" .. tostring(panel.viewData.areaHeight))
    else
        debugLog("Player " .. playerIndex .. " failed to create tooltip overlay UI element.")
    end
    return true
end

local function onTick()
    shortcutHintAnchorTick = shortcutHintAnchorTick + 1
    for playerIndex = 0, 3 do
        local state = getState(playerIndex)
        local bind = getJoypadBind(playerIndex)
        local focus = nil
        if type(getJoypadFocus) == "function" then
            local ok, value = pcall(getJoypadFocus, playerIndex)
            if ok then focus = value end
        else
            local players = JoypadState and JoypadState.players
            local data = players and players[playerIndex]
            focus = data and data.focus or nil
        end
        local eligible = bind >= 0 and areInventoryWindowsClosed(playerIndex) and focus == nil

        -- The D-pad handler below reads moodles synchronously on the button edge.
        -- Only refresh the visible tooltip's data periodically; scanning while it
        -- is hidden has no effect on input handling or the native moodle display.
        if bind >= 0 and state.selectedKey then
            state.orderPollTicks = (state.orderPollTicks or 0) + 1
            if state.orderPollTicks >= MOODLE_REFRESH_TICKS then
                state.activeMoodles = getActiveMoodles(playerIndex)
                state.orderPollTicks = 0
                state.viewDirty = true
            end
        else
            state.orderPollTicks = 0
        end

        local rbDown = eligible and isButtonDown("RightBump", bind)
        if rbDown and not state.rbWasDown then
            state.dpadDownAtRB = {}
            for _, d in ipairs(DIRECTION_DATA) do
                state.dpadDownAtRB[d.name] = isButtonDown(d.button, bind)
            end
            debugLog("Player " .. playerIndex .. " RB-down captured; D-pad held=" .. tostring(state.dpadDownAtRB.Up or state.dpadDownAtRB.Down or state.dpadDownAtRB.Left or state.dpadDownAtRB.Right))
        end
        for _, direction in ipairs(DIRECTION_DATA) do
            local action = getConfiguredAction(direction.name)
            local chordDown = false
            if eligible and rbDown and (action == "moodlePrevious" or action == "moodleNext") then
                local buttonDown = isButtonDown(direction.button, bind)
                local oppositeDown = isButtonDown(BUTTON_BY_DIRECTION[direction.opposite], bind)
                chordDown = buttonDown and not oppositeDown and not state.dpadDownAtRB[direction.name]
            end
            if chordDown and not state.chordDown[direction.name] then
                debugLog("Player " .. playerIndex .. " RB+DPad" .. direction.name .. " chord edge detected; configured action=" .. action)
                selectDirection(playerIndex, action == "moodleNext" and 1 or -1, direction.name)
            end
            state.chordDown[direction.name] = chordDown == true
        end
        state.rbWasDown = rbDown == true
        if not rbDown then state.dpadDownAtRB = {} end

        if not eligible then
            dismiss(state, playerIndex)
        elseif state.selectedKey then
            suppressNativeHover(playerIndex)
            local active = state.activeMoodles
            if not active then
                active = getActiveMoodles(playerIndex)
                state.activeMoodles = active
                state.viewDirty = true
            end
            local selected, selectedIndex = nil, nil
            for i, item in ipairs(active) do
                if item.key == state.selectedKey then selected, selectedIndex = item, i; break end
            end
            if not selected then
                dismiss(state, playerIndex)
            else
                if state.timer > 0 then
                    state.timer = state.timer - 1
                else
                    state.alpha = math.max(0, state.alpha - (1 / FADE_TICKS))
                end
                if state.alpha <= 0 then
                    dismiss(state, playerIndex)
                else
                    local panel = ensureOverlay()
                    if panel then
                        if state.viewDirty or not state.viewData then
                            state.viewData = makeView(playerIndex, selected, selectedIndex, state.alpha)
                            state.viewDirty = false
                        end
                        state.viewData.alpha = state.alpha
                        panel.viewData = state.viewData
                        if type(panel.getIsVisible) ~= "function" or not panel:getIsVisible() then panel:setVisible(true) end
                    end
                end
            end
        end
    end
end

debugLog("Module loaded. RB Moodle diagnostics are ON; will prefer native slots when exposed, otherwise mirror vanilla HashMap order without reflection. Tooltip row pitch uses native icon width + 10. Tooltip title is right-aligned to the icon-side edge, descriptions stay left-aligned, content width expands to available space, and line spacing is 23px. Stable fallback starts UNHAPPY > ENDURANCE > HUNGRY > PAIN > THIRST > TIRED.")
if Events and Events.OnTick then Events.OnTick.Add(onTick) end
if Events and Events.OnResetLua then
    Events.OnResetLua.Add(function()
        for playerIndex = 0, 3 do refreshNativeHover(playerIndex) end
        playerStates = {}
        activationTrackers = {}
        shortcutHintAnchorTick = 0
        shortcutHintAnchorCache = {}
        RB_MOODLE_DEBUG_ONCE = {}
        nativeHashMapOrderCache = nil
        nativeHashMapOrderFailure = nil
        if overlay then pcall(function() overlay:setVisible(false) end) end
        overlay = nil
        overlayPlayerIndex = nil
        debugLog("Lua reset; activation/order diagnostics reinitialized.")
    end)
end
