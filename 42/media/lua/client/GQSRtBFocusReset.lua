-- Gamepad QoL Suite: RT+B focus-aware shortcut.
-- Each activation is a separate strict-order RT-then-B chord:
-- * UI focus present: clear joypad focus and leave the focused panel open.
-- * World focus (nil): close visible, unfocused UI windows, if any exist.
-- Releasing RT between activations is optional; a fresh RT+B chord always works.

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rtBFocus", message)
    end
end

local function getOptions()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    if options then return options end
    local ok, module = pcall(require, "GQSModOptions")
    if ok and type(module) == "table" then return module end
    return nil
end

local function isEnabled()
    local options = getOptions()
    local toggle = options and options.rtBFocusEnabled
    if not toggle or type(toggle.getValue) ~= "function" then return false end
    local ok, value = pcall(function() return toggle:getValue() end)
    return ok and (value == true or value == 1)
end

local function getJoypadId(playerNum)
    if type(getJoypadData) == "function" then
        local ok, data = pcall(getJoypadData, playerNum)
        if ok and data and type(data.id) == "number" and data.id >= 0 then
            return data.id
        end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerNum + 1]
    if data and type(data.id) == "number" and data.id >= 0 then return data.id end
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
    if player and type(player.getJoypadBind) == "function" then
        local ok, id = pcall(function() return player:getJoypadBind() end)
        if ok and type(id) == "number" and id >= 0 then return id end
    end
    return -1
end

local function isRightTriggerDown(controllerId)
    if controllerId == nil or controllerId < 0 then return false end
    local axes = rawget(_G, "JoypadAxis1d")
    local axis = axes and axes.RightTrigger
    if not axis or type(axis.getValue) ~= "function" then return false end
    local ok, value = pcall(axis.getValue, axis, controllerId)
    if not ok or type(value) ~= "number" then return false end
    local threshold = 0.50
    if type(axis.getDeadZone) == "function" then
        local okDead, deadZone = pcall(axis.getDeadZone, axis, controllerId)
        if okDead and type(deadZone) == "number" then
            threshold = math.max(threshold, math.min(0.95, deadZone + 0.05))
        end
    end
    return value >= threshold
end

local function isBDown(controllerId)
    if controllerId == nil or controllerId < 0 then return false end
    local buttons = rawget(_G, "JoypadButton")
    local b = buttons and buttons.B
    if b and type(b.isDown) == "function" then
        local ok, down = pcall(b.isDown, b, controllerId)
        if ok then return down == true end
    end
    local joypad = rawget(_G, "Joypad")
    if type(isJoypadPressed) == "function" and joypad and joypad.BButton ~= nil then
        local ok, down = pcall(isJoypadPressed, controllerId, joypad.BButton)
        if ok then return down == true end
    end
    return false
end

local function isBButton(button)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad.BButton ~= nil and button == joypad.BButton then return true end
    local buttons = rawget(_G, "JoypadButton")
    if buttons and buttons.B ~= nil and button == buttons.B then return true end
    local ok, text = pcall(tostring, button)
    return ok and (text == "B" or text == "JoypadButton.B" or text == "zombie.input.JoypadButton.B")
end

local function getFocus(playerNum)
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok then return focus end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerNum + 1]
    return data and data.focus or nil
end

local function setFocus(playerNum, object)
    if type(setJoypadFocus) ~= "function" then
        log("setJoypadFocus is unavailable; cannot change player " .. tostring(playerNum) .. " focus")
        return false
    end
    local ok, err = pcall(setJoypadFocus, playerNum, object)
    if not ok then
        log("setJoypadFocus failed for player " .. tostring(playerNum) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function safeCall(object, methodName, ...)
    if object == nil then return nil end
    -- Some Java-backed UI entries do not expose every Lua method. Protect the
    -- member lookup itself as well as the invocation; Kahlua may throw during
    -- indexing/calling a missing Java-backed method.
    local okMethod, method = pcall(function() return object[methodName] end)
    if not okMethod or type(method) ~= "function" then return nil end
    local ok, result = pcall(method, object, ...)
    if ok then return result end
    return nil
end

local function isVisible(object)
    local visible = safeCall(object, "isReallyVisible")
    if visible == nil then visible = safeCall(object, "isVisible") end
    return visible == true or visible == 1
end

local function getTypeName(object)
    if object == nil then return "" end
    local name = object.Type or object.type or object.className or object.ClassName
    if name == nil then name = safeCall(object, "getUIName") end
    if name == nil then name = object.name end
    return name ~= nil and tostring(name) or ""
end

local function containsAny(text, words)
    local lower = string.lower(text or "")
    for i = 1, #words do
        if string.find(lower, words[i], 1, true) then return true end
    end
    return false
end

local persistentUIHints = {
    "moodlesui", "speedcontrols", "hotbar", "minimap", "radarpanel", "clock",
    "actionprogressbar", "healthbar", "xpbar", "vehicle gauge", "vehiclegauge",
    "gqspanelquickselectoverlay", "gqsrtbmoodle", "gqsrtbfocus",
    -- The world map has its own controller navigation/close behavior. RT+B must
    -- not hijack it and must never treat it as part of the close-all pass.
    "isworldmap", "worldmap",
}

local windowNameHints = {
    "window", "panel", "inventory", "loot", "health", "fitness", "info", "skill",
    "map", "radio", "television", "craft", "handcraft", "container", "book",
    "mechanic", "vehicle", "character", "garment", "medical", "trading", "recipe",
    "forage", "debug", "smith", "workbench", "modal", "dialog", "build", "building",
    "chat", "water", "tank", "trough", "animal", "farm", "sink", "exercise",
    "contextmenu", "context_menu", "backbuttonwheel", "radialmenu", "textentry",
}

local function unwrapUIObject(object)
    if object == nil then return nil end

    -- Most ISUI instances already arrive as Lua tables. Do not call :getTable()
    -- on them: many do not implement that method, which caused "Tried to call
    -- nil" during stage-2 scanning (even when no closable windows existed).
    if type(object) == "table" then
        local okMethod, getTable = pcall(function() return object.getTable end)
        if okMethod and type(getTable) == "function" then
            local okTable, luaObject = pcall(getTable, object)
            if okTable and type(luaObject) == "table" then return luaObject end
        end
        return object
    end

    -- Only call getTable on Java-backed wrappers that explicitly expose it.
    local okMethod, getTable = pcall(function() return object.getTable end)
    if okMethod and type(getTable) == "function" then
        local okTable, luaObject = pcall(getTable, object)
        if okTable and type(luaObject) == "table" then return luaObject end
    end
    return nil
end

local function looksLikeWorldMap(rawObject, requireVisible)
    local object = unwrapUIObject(rawObject)
    if type(object) ~= "table" then return false end
    local name = string.lower(getTypeName(object))
    if not containsAny(name, { "isworldmap", "worldmap" }) then return false end
    if not requireVisible then return true end
    return isVisible(object)
end

local function isWorldMapOpen(playerNum, preferredObject)
    -- A focused world map always takes precedence, even if its visibility API is
    -- not available through this Build's Lua binding.
    if looksLikeWorldMap(preferredObject, false) then return true end
    if playerNum ~= nil then
        local focused = getFocus(playerNum)
        if looksLikeWorldMap(focused, false) then return true end
    end

    -- ISWorldMap.instance is available in common PZ UI implementations.
    local worldMapClass = rawget(_G, "ISWorldMap")
    if type(worldMapClass) == "table" then
        local okInstance, instance = pcall(function() return worldMapClass.instance end)
        if okInstance and instance and looksLikeWorldMap(instance, true) then return true end
    end

    -- Also inspect UIManager entries for variants/modded wrappers. Check that
    -- methods exist before calling them; some Kahlua/Java proxies throw on nil calls.
    local uiManager = rawget(_G, "UIManager")
    if uiManager then
        local okGetter, getUI = pcall(function() return uiManager.getUI end)
        if okGetter and type(getUI) == "function" then
            local okList, uiList = pcall(getUI)
            if okList and uiList then
                local size = safeCall(uiList, "size")
                if type(size) == "number" then
                    for i = 0, size - 1 do
                        local item = safeCall(uiList, "get", i)
                        if item and looksLikeWorldMap(item, true) then return true end
                    end
                elseif type(uiList) == "table" then
                    for i = 1, #uiList do
                        if looksLikeWorldMap(uiList[i], true) then return true end
                    end
                end
            end
        end
    end
    return false
end

local function objectHasWindowSignal(object, name)
    if containsAny(name, windowNameHints) then return true end
    if object.title ~= nil or object.titleBar ~= nil or object.closeButton ~= nil then return true end
    if object.resizable == true or object.moveWithMouse == true then return true end
    local width = tonumber(safeCall(object, "getWidth") or object.width) or 0
    local height = tonumber(safeCall(object, "getHeight") or object.height) or 0
    return type(object.onJoypadDown) == "function" and width >= 150 and height >= 90
end

local function isOwnedByAnotherPlayer(object, playerNum)
    local owner = object.playerNum
    if owner == nil and type(object.player) == "number" then owner = object.player end
    return type(owner) == "number" and owner ~= playerNum
end

local function collectClosableWindows(playerNum)
    local results, seen = {}, {}
    local function add(rawObject, allowNested)
        local object = unwrapUIObject(rawObject)
        if type(object) ~= "table" or seen[object] then return end
        if not isVisible(object) then return end
        if isOwnedByAnotherPlayer(object, playerNum) then return end
        local name = getTypeName(object)
        if containsAny(name, persistentUIHints) then return end
        if not allowNested and safeCall(object, "getParent") ~= nil then return end
        if not objectHasWindowSignal(object, name) then return end
        seen[object] = true
        results[#results + 1] = { object = object, name = name ~= "" and name or "UI window", playerNum = playerNum }
    end

    local uiManager = rawget(_G, "UIManager")
    if uiManager then
        local okGetter, getUI = pcall(function() return uiManager.getUI end)
        if okGetter and type(getUI) == "function" then
            local ok, uiList = pcall(getUI)
            if ok and uiList ~= nil then
                local size = safeCall(uiList, "size")
                if type(size) == "number" then
                    for i = 0, size - 1 do
                        local object = safeCall(uiList, "get", i)
                        if object then
                            local okAdd, errAdd = pcall(add, object, false)
                            if not okAdd then log("skipped problematic UIManager entry " .. tostring(i) .. ": " .. tostring(errAdd)) end
                        end
                    end
                elseif type(uiList) == "table" then
                    for i = 1, #uiList do
                        local okAdd, errAdd = pcall(add, uiList[i], false)
                        if not okAdd then log("skipped problematic UI table entry " .. tostring(i) .. ": " .. tostring(errAdd)) end
                    end
                end
            end
        end
    end

    -- Some modal dialogs or nested windows are not exposed as a top-level UI entry.
    if uiManager then
        local okGetter, getModal = pcall(function() return uiManager.getModal end)
        if okGetter and type(getModal) == "function" then
            local ok, modal = pcall(getModal)
            if ok and modal then
                local okAdd, errAdd = pcall(add, modal, true)
                if not okAdd then log("skipped problematic modal entry: " .. tostring(errAdd)) end
            end
        end
    end

    -- Add these known singletons explicitly in case a UIManager implementation does
    -- not expose them in the top-level list. They are deduplicated above.
    if type(getPlayerInventory) == "function" then
        local ok, inv = pcall(getPlayerInventory, playerNum)
        if ok and inv then
            local okAdd, errAdd = pcall(add, inv, false)
            if not okAdd then log("skipped problematic player inventory entry: " .. tostring(errAdd)) end
        end
    end
    if type(getPlayerLoot) == "function" then
        local ok, loot = pcall(getPlayerLoot, playerNum)
        if ok and loot then
            local okAdd, errAdd = pcall(add, loot, false)
            if not okAdd then log("skipped problematic loot entry: " .. tostring(errAdd)) end
        end
    end
    if ISFitnessUI and ISFitnessUI.instance and ISFitnessUI.instance[playerNum + 1] then
        local okAdd, errAdd = pcall(add, ISFitnessUI.instance[playerNum + 1], false)
        if not okAdd then log("skipped problematic fitness entry: " .. tostring(errAdd)) end
    end

    return results
end

local function closeWindow(entry)
    local object = entry.object
    local name = entry.name
    local lowerName = string.lower(name or "")
    if not isVisible(object) then return false end

    -- Inventory, loot, character info and chat are persistent singleton widgets:
    -- hide them instead of removing their UI object, so their normal key can show
    -- them again later. Fitness and modal/menu objects use their close/remove path.
    local keepSingleton = containsAny(lowerName, {
        "isinventorypage", "inventorypage", "islootwindow", "lootwindow", "ischat",
        "ischaracterinfowindow", "characterinfowindow", "playerinfopanel",
    })

    -- Prefer the panel's own close implementation so it can clear singleton state.
    if type(object.close) == "function" then
        local ok, err = pcall(function() object:close() end)
        if not ok then log("close() failed for " .. name .. ": " .. tostring(err)) end
        if ok and not isVisible(object) then
            log("close-all closed " .. name .. " via close()")
            return true
        end
    end

    -- A few transient surfaces (modal dialogs, wheels and fitness UI) are normally
    -- removed from UIManager instead of merely hidden.
    local shouldRemove = containsAny(lowerName, { "modal", "dialog", "backbuttonwheel", "radialmenu", "isfitnessui", "fitnessui" })
    if not keepSingleton and shouldRemove and type(object.removeFromUIManager) == "function" then
        local ok, err = pcall(function() object:removeFromUIManager() end)
        if ok then
            if containsAny(lowerName, { "isfitnessui", "fitnessui" }) and ISFitnessUI and ISFitnessUI.instance then
                ISFitnessUI.instance[(tonumber(entry.playerNum) or 0) + 1] = nil
            end
            log("close-all removed transient " .. name .. " from UIManager")
            return true
        end
        log("removeFromUIManager() failed for " .. name .. ": " .. tostring(err))
    end

    if type(object.setVisible) == "function" then
        local ok, err = pcall(function() object:setVisible(false) end)
        if ok then
            log("close-all hid " .. name .. " with setVisible(false)")
            return true
        end
        log("setVisible(false) failed for " .. name .. ": " .. tostring(err))
    end

    -- Last resort for windows without an ordinary close/hide method.
    if not keepSingleton and type(object.removeFromUIManager) == "function" then
        local ok, err = pcall(function() object:removeFromUIManager() end)
        if ok then
            log("close-all removed " .. name .. " from UIManager (fallback)")
            return true
        end
        log("removeFromUIManager() fallback failed for " .. name .. ": " .. tostring(err))
    end

    local closed = not isVisible(object)
    log("close-all " .. (closed and "closed " or "could not confirm closure of ") .. name)
    return closed
end

local states = {}
local handleRTB

local function getPlayerForFocusedObject(object)
    local count = 1
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then count = value end
    end
    for playerNum = 0, count - 1 do
        if getFocus(playerNum) == object then return playerNum end
    end
    return nil
end

local function patchFocusedObject(object)
    if type(object) ~= "table" or type(object.onJoypadDown) ~= "function" then return end
    if object._gqsRTBFocusWrapped == object.onJoypadDown then return end

    local original = object.onJoypadDown
    local wrapped
    wrapped = function(self, button, ...)
        local playerNum = getPlayerForFocusedObject(self)
        if playerNum ~= nil and isBButton(button) and isEnabled() then
            local controllerId = getJoypadId(playerNum)
            local state = states[playerNum] or { wasBDown = false, wasRTDown = false }
            states[playerNum] = state
            if isRightTriggerDown(controllerId) then
                if isWorldMapOpen(playerNum, self) then
                    -- The map's native B handler may close the map and clear focus
                    -- before OnTick polls this same B press. Mark it handled here
                    -- so polling cannot misinterpret that one press as a world-focus
                    -- close-all command after the map disappears.
                    state.wasBDown = true
                    log("RT+B bypassed while world map is open; this B press is reserved for the native map handler")
                elseif state.wasRTDown == true then
                    state.wasBDown = true
                    log("RT+B intercepted before focused panel handler; player=" .. tostring(playerNum)
                        .. ", focus=" .. getTypeName(self))
                    handleRTB(playerNum, self)
                    return
                else
                    log("RT+B ignored: RT was not observed down before the B press; passing to native handler")
                end
            end
        end
        return original(self, button, ...)
    end
    object._gqsRTBOriginalOnJoypadDown = original
    object._gqsRTBFocusWrapped = wrapped
    object.onJoypadDown = wrapped
end

handleRTB = function(playerNum, focusAtPress)
    local focus = focusAtPress
    if focus == nil then focus = getFocus(playerNum) end

    if isWorldMapOpen(playerNum, focus) then
        log("RT+B ignored while world map is open; no focus or window state changed")
        return
    end

    if focus ~= nil then
        local name = getTypeName(focus)
        local ok = setFocus(playerNum, nil)
        log("RT+B focus-return: player " .. tostring(playerNum) .. " returned to world focus; panel kept open: "
            .. (name ~= "" and name or tostring(focus)) .. "; success=" .. tostring(ok)
            .. ". A separate RT-then-B chord while world-focused closes unfocused visible windows.")
        return
    end

    local windows = collectClosableWindows(playerNum)
    if #windows == 0 then
        -- With no visible, unfocused windows there is nothing to do. In particular,
        -- avoid even a redundant setJoypadFocus(nil) call, which may disturb native
        -- map/modal focus transitions on the same frame.
        log("RT+B no-op: player is world-focused and no visible unfocused windows were found")
        return
    end

    local closed, failed = 0, 0
    -- Close in reverse UI-stack order so modal/topmost dialogs are handled first.
    for i = #windows, 1, -1 do
        if closeWindow(windows[i]) then closed = closed + 1 else failed = failed + 1 end
    end
    setFocus(playerNum, nil)
    log("RT+B close-unfocused: attempted=" .. tostring(#windows)
        .. ", closed=" .. tostring(closed) .. ", unconfirmed=" .. tostring(failed)
        .. ". This action required one fresh RT-then-B chord; no Y/left-stick state was modified.")
end

local function getState(playerNum)
    local state = states[playerNum]
    if not state then
        state = { wasBDown = false, wasRTDown = false }
        states[playerNum] = state
    end
    return state
end

local function onTick()
    if not isEnabled() then
        for playerNum, state in pairs(states) do
            local controllerId = getJoypadId(playerNum)
            state.wasBDown = isBDown(controllerId)
            state.wasRTDown = isRightTriggerDown(controllerId)
        end
        return
    end

    local count = 1
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then count = value end
    end

    for playerNum = 0, count - 1 do
        local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(playerNum) or nil
        local state = getState(playerNum)
        local controllerId = getJoypadId(playerNum)
        if player and controllerId >= 0 then
            local focus = getFocus(playerNum)
            if focus ~= nil then patchFocusedObject(focus) end

            local bDown = isBDown(controllerId)
            local rtDown = isRightTriggerDown(controllerId)
            local rtWasDown = state.wasRTDown == true
            if bDown and not state.wasBDown then
                state.wasBDown = true
                if rtDown and not rtWasDown then
                    log("RT+B ignored: B was pressed before RT or RT-down edge was not observed first")
                elseif rtDown and isWorldMapOpen(playerNum, focus) then
                    log("RT+B ignored while world map is open; leaving map focus and panel state untouched")
                elseif rtDown and focus == nil then
                    log("RT+B detected with world focus; checking for visible unfocused panels")
                    handleRTB(playerNum, nil)
                elseif rtDown and focus ~= nil then
                    log("RT+B press edge observed while a panel still has focus, but its onJoypadDown hook did not consume it; no poll fallback used to avoid double-closing")
                end
            elseif not bDown then
                state.wasBDown = false
            end
            state.wasRTDown = rtDown
        else
            state.wasBDown = false
            state.wasRTDown = false
        end
    end
end

if Events and Events.OnTick then Events.OnTick.Add(onTick) end

log("loaded; strict RT-before-B chord enabled; map B presses pass through without being reprocessed; focused UI returns to world focus; a separate RT+B while world-focused closes visible unfocused windows; no-window state is a no-op")
