-- Add adjacent-tile discovery to CustomGamepadUI's radial menu without shipping
-- or replacing its SWTileRadialMenu.lua implementation.
local GQS = require("GQSModOptions")
local installed = false
local suppressCustomWheel = false

-- The D-pad Up wheel shows at most this many water sources: the player's own
-- square first, then the forward 180-degree arc. Squares behind the player are
-- never offered. Keep it small: every source adds a drink + fill pair to the
-- wheel and too many sources crowd out the other actions.
local MAX_WATER_SOURCES = 2

local function debugLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("rightRadial", message)
    end
end

-- SRM compatibility logging goes to the srmCompat category so it can be enabled
-- independently of the rightRadial trace.
local function srmLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("srmCompat", message)
    end
end

local function optionEnabled(optionName, fallback)
    local option = GQS and GQS[optionName]
    if not option or type(option.getValue) ~= "function" then return fallback end
    local ok, value = pcall(option.getValue, option)
    if not ok then
        debugLog("reading setting " .. optionName .. " failed: " .. tostring(value))
        return fallback
    end
    return value == true or value == 1
end

local function eligibleWaterContainer(item)
    local fluid = item and item:getFluidContainer()
    return item and not item:isSealed() and item:canStoreWater()
        and fluid and (item:isWaterSource() and fluid:getFilledRatio() < 1 or fluid:getFilledRatio() == 0)
end
local function compareWater(a, b)
    local af = a:isWaterSource() and a:getFluidContainer():getFilledRatio() or 0
    local bf = b:isWaterSource() and b:getFluidContainer():getFilledRatio() or 0
    return af - bf
end

-- Most world water sources use hasWater(). In Build 42.21, a plumbed sink
-- backed by a rain collector can still supply liquid mixtures (e.g. water +
-- wine) even when hasWater() no longer reports true. Use this narrow fallback
-- only for objects that identify an external water-source connection and whose
-- linked source still contains fluid. The action remains bound to the sink, so
-- vanilla ISTakeWaterAction preserves plumbing and mixture transfer behaviour.
local function objectHasWater(object)
    if not object then return false end
    local ok, value = pcall(function() return object:hasWater() end)
    return ok and value == true
end

-- Rain/blood-contaminated water is still drinkable in vanilla but is a poor
-- default choice. Sort it behind clean sources so clean ones take the limited
-- radial slots first. If a source cannot be queried, treat it as clean so we
-- never hide a usable source on a build that lacks this method.
local function objectWaterIsTainted(object)
    if not object then return false end
    local ok, value = pcall(function() return object:isTaintedWater() end)
    return ok and value == true
end

local function objectHasAnyFluid(object)
    if not object then return false end
    local amountOk, amount = pcall(function() return object:getFluidAmount() end)
    if amountOk and type(amount) == "number" and amount > 0 then return true end
    local hasOk, hasFluid = pcall(function() return object:hasFluid() end)
    return hasOk and hasFluid == true
end

local function objectHasLiquidExternalSource(object)
    if not object then return false end
    if instanceof(object, "IsoClothingDryer") or instanceof(object, "IsoClothingWasher") then
        return false
    end

    local linkOk, hasExternal = pcall(function() return object:hasExternalWaterSource() end)
    local usesOk, usesExternal = pcall(function() return object:getUsesExternalWaterSource() end)
    local linked = (linkOk and hasExternal == true) or (usesOk and usesExternal == true)
    if not linked then return false end

    local sourceOk, source = pcall(function() return object:FindExternalWaterSource() end)
    if sourceOk and source and source ~= object and objectHasAnyFluid(source) then
        return true
    end

    -- Some objects report the plumbing link before FindExternalWaterSource()
    -- resolves it; only accept that fallback when the object itself reports
    -- remaining fluid, not just because it is plumbed.
    return objectHasAnyFluid(object)
end

-- Use the FluidContainer's UI name for the radial label. In Build 42, an
-- item's script display name can describe its original contents (for example,
-- Orange Soda) even after the same container has been emptied. The UI name
-- describes the actual receptacle (for example, Bottle).
local function getWaterContainerDisplayName(item)
    if not item then return nil end

    local fluidOk, fluidContainer = pcall(function()
        return item:getFluidContainer()
    end)
    if fluidOk and fluidContainer then
        local nameOk, name = pcall(function()
            return fluidContainer:getUiName()
        end)
        if nameOk and type(name) == "string" and name ~= "" then
            return name
        end
    end

    local nameOk, name = pcall(function()
        return item:getDisplayName()
    end)
    if nameOk and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- getTex() is the item's current texture. Keep getIcon() as a compatibility
-- fallback in case a future item implementation does not expose getTex().
local function getWaterContainerTexture(item)
    if not item then return nil end

    local texOk, texture = pcall(function()
        return item:getTex()
    end)
    if texOk and texture then return texture end

    local iconOk, texture = pcall(function()
        return item:getIcon()
    end)
    if iconOk and texture then return texture end
    return nil
end

-- Icon for a world object, using the same sprite source vanilla uses for its
-- X-interaction entries (getTexture(spriteName):splitIcon()). Only used for
-- Generic world-object sprite icon (fallback for radio and other actions).
-- texture:getWidth() is unavailable in this Kahlua build, so no size filter.
local function getObjectIcon(object, fallback)
    if not object then return fallback end

    local nameOk, spriteName = pcall(function() return object:getSpriteName() end)
    if nameOk and type(spriteName) == "string" and spriteName ~= "" then
        local texOk, texture = pcall(getTexture, spriteName)
        if texOk and texture then
            local splitOk, icon = pcall(function() return texture:splitIcon() end)
            if splitOk and icon then return icon end
            return texture
        end
    end

    -- Some objects only expose the sprite object, not getSpriteName().
    local spriteOk, sprite = pcall(function() return object:getSprite() end)
    if spriteOk and sprite then
        local spriteNameOk, name = pcall(function() return sprite:getName() end)
        if spriteNameOk and type(name) == "string" and name ~= "" then
            local texOk, texture = pcall(getTexture, name)
            if texOk and texture then
                local splitOk, icon = pcall(function() return texture:splitIcon() end)
                if splitOk and icon then return icon end
                return texture
            end
        end
    end
    return fallback
end

-- World TV/radio object -> the item icon shown in the inventory (the one in
-- the player's bag), using the same lookup as vanilla ISRadioAndTvMenu:
--   1) built-in set: object properties "CustomItem" -> getItem():getNormalTexture()
--   2) player-dropped: mod data RadioItemID -> matching world item -> getTex()
-- Falls back to the object's sprite icon (getObjectIcon), then the bulb icon.
-- Every Java call is pcall-guarded for Kahlua.
local function getRadioIcon(object, fallback)
    if not object then return fallback end

    -- 1) Built-in TV/radio: CustomItem property names the inventory item script.
    local propsOk, props = pcall(function() return object:getProperties() end)
    if propsOk and props then
        local customOk, customItem = pcall(function() return props:get("CustomItem") end)
        if customOk and type(customItem) == "string" and customItem ~= "" then
            local scriptOk, script = pcall(getItem, customItem)
            if scriptOk and script then
                local texOk, texture = pcall(function() return script:getNormalTexture() end)
                if texOk and texture then return texture end
            end
        end
    end

    -- 2) Player-dropped item: RadioItemID links the invisible IsoWaveSignal to
    --    a world item whose getTex() is the inventory icon in the screenshot.
    local dataOk, modData = pcall(function() return object:getModData() end)
    if dataOk and modData then
        local idOk, radioId = pcall(function() return modData.RadioItemID end)
        if idOk and type(radioId) == "number" then
            local squareOk, square = pcall(function() return object:getSquare() end)
            if squareOk and square then
                local objsOk, objs = pcall(function() return square:getWorldObjects() end)
                if objsOk and objs then
                    local sizeOk, count = pcall(function() return objs:size() end)
                    if sizeOk then
                        for i = 1, count do
                            local itemOk, worldItem = pcall(function() return objs:get(i - 1) end)
                            if itemOk and worldItem then
                                local innerOk, inner = pcall(function() return worldItem:getItem() end)
                                if innerOk and inner then
                                    local innerIdOk, innerId = pcall(function() return inner:getID() end)
                                    if innerIdOk and innerId == radioId then
                                        local texOk, texture = pcall(function() return inner:getTex() end)
                                        if texOk and texture then return texture end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return getObjectIcon(object, fallback)
end

-- Curtains use CGUI's plain cloth icon (32x32, fixed size). The entity sprite
-- was far too big for a wheel slice; a fixed icon is safe and readable.
local CURTAIN_ICON = "media/ui/icon_sheet.png"
local function getCurtainIcon()
    local ok, texture = pcall(getTexture, CURTAIN_ICON)
    if ok and texture then return texture end
    return nil
end

-- Read an object's visible moveable name using the same sprite metadata and
-- Translator rule as vanilla ISWorldObjectContextMenu.getMoveableDisplayName().
-- Do not use getName()/getObjectName() here: generic fixtures can return "IsoObject".
local function isUsableDisplayName(value)
    return type(value) == "string"
        and value ~= ""
        and value ~= "nil"
        and value ~= "null"
        and value ~= "IsoObject"
        and value:gsub("%s", "") ~= ""
end

local function isInstanceOfSafe(object, className)
    if not object or type(instanceof) ~= "function" then return false end
    local ok, result = pcall(instanceof, object, className)
    return ok and result == true
end

local function getVanillaMoveableDisplayName(object)
    if not object then return nil end

    -- Keep parity with vanilla for world inventory objects when one is passed.
    if isInstanceOfSafe(object, "IsoWorldInventoryObject") then
        local itemOk, item = pcall(function() return object:getItem() end)
        if itemOk and item then
            local nameOk, name = pcall(function() return item:getName() end)
            if nameOk and isUsableDisplayName(name) then return name end
        end
        return nil
    end

    local spriteOk, sprite = pcall(function() return object:getSprite() end)
    if not spriteOk or not sprite then return nil end
    local propsOk, props = pcall(function() return sprite:getProperties() end)
    if not propsOk or not props then return nil end
    local hasOk, hasCustom = pcall(function() return props:has("CustomName") end)
    if not hasOk or not hasCustom then return nil end

    local nameOk, customName = pcall(function() return props:get("CustomName") end)
    if not nameOk or not isUsableDisplayName(customName) then return nil end
    local displayName = customName
    local groupOk, hasGroup = pcall(function() return props:has("GroupName") end)
    if groupOk and hasGroup then
        local groupNameOk, groupName = pcall(function() return props:get("GroupName") end)
        if groupNameOk and isUsableDisplayName(groupName) then
            displayName = groupName .. " " .. displayName
        end
    end

    local translator = rawget(_G, "Translator")
    if translator and type(translator.getMoveableDisplayName) == "function" then
        local translatedOk, translated = pcall(translator.getMoveableDisplayName, displayName)
        if translatedOk and isUsableDisplayName(translated) then return translated end
    end
    return isUsableDisplayName(displayName) and displayName or nil
end

local function getWorldObjectFallbackName(object, hint)
    -- Prefer the real object's class when it is known. Hints are only a fallback
    -- for generic/BarricadeAble targets and must not mislabel a door as a window.
    if isInstanceOfSafe(object, "IsoLightSwitch") then
        return getText("UI_GQS_RadialTargetLightSwitch")
    end
    if isInstanceOfSafe(object, "IsoWindow") then
        return getText("UI_GQS_RadialTargetWindow")
    end
    if isInstanceOfSafe(object, "IsoDoor") then
        return getText("UI_GQS_RadialTargetDoor")
    end
    if isInstanceOfSafe(object, "IsoWaveSignal") then
        return getText("UI_GQS_RadialTargetRadio")
    end
    if isInstanceOfSafe(object, "IsoCurtain") then
        return getText("UI_GQS_RadialTargetWindow")
    end
    if hint == "light" then return getText("UI_GQS_RadialTargetLightSwitch") end
    if hint == "window" then return getText("UI_GQS_RadialTargetWindow") end
    if hint == "door" then return getText("UI_GQS_RadialTargetDoor") end
    if hint == "radio" then return getText("UI_GQS_RadialTargetRadio") end
    return nil
end

local function getWorldObjectDisplayName(object, hint)
    local displayName = getVanillaMoveableDisplayName(object)
    if isUsableDisplayName(displayName) then return displayName end
    return getWorldObjectFallbackName(object, hint)
end

-- Match the vanilla ISWorldObjectContextMenu.createWaterSourceTooltip() naming
-- rules; water has a specific localized fallback when sprite metadata is absent.
local function getWaterSourceDisplayName(object)
    if not object then return getText("ContextMenu_NaturalWaterSource") end
    local displayName = getVanillaMoveableDisplayName(object)
    if isUsableDisplayName(displayName) then return displayName end
    return getText("ContextMenu_NaturalWaterSource")
end

local function appendNamedTargetLine(label, targetName)
    if not isUsableDisplayName(targetName) then return label end
    label = tostring(label or "")
    local suffix = "\n" .. targetName
    if label:sub(-#suffix) == suffix then return label end
    return label .. suffix
end

-- Shared label builders for every drink/fill slice. GQS-created neighbour
-- slices also pass through the wrapped addSlice(), so appendNamedTargetLine()
-- makes the source name idempotent and prevents duplicate second lines.
local function makeDrinkLabel(label, water)
    return appendNamedTargetLine(label, getWaterSourceDisplayName(water))
end

local function makeFillLabel(label, item, water)
    local name = getWaterContainerDisplayName(item)
    if not isUsableDisplayName(name) then
        -- Keep the native label if the selected item cannot supply a UI name,
        -- but still identify the exact water source for this slice.
        return appendNamedTargetLine(label, getWaterSourceDisplayName(water))
    end

    local prefix = ""
    local taintedPrefix = "(" .. getText("Tooltip_tainted") .. ") "
    label = tostring(label or "")
    if label:sub(1, #taintedPrefix) == taintedPrefix then
        prefix = taintedPrefix
    end
    local fillLabel = prefix .. getText("ContextMenu_Fill") .. " " .. name
    return appendNamedTargetLine(fillLabel, getWaterSourceDisplayName(water))
end

local function makeObjectActionLabel(label, object, hint)
    return appendNamedTargetLine(label, getWorldObjectDisplayName(object, hint))
end

local function resolveCurtainHost(curtain)
    if not curtain then return nil end
    if isInstanceOfSafe(curtain, "IsoWindow") or isInstanceOfSafe(curtain, "IsoDoor") then
        return curtain
    end

    local squareOk, square = pcall(function() return curtain:getSquare() end)
    if not squareOk or not square then return nil end
    local xOk, x = pcall(function() return square:getX() end)
    local yOk, y = pcall(function() return square:getY() end)
    local zOk, z = pcall(function() return square:getZ() end)
    if not xOk or not yOk or not zOk then return nil end

    -- A curtain can occupy a different tile from its window/door. Search the
    -- small surrounding area and resolve the host by the actual HasCurtains()
    -- object reference, rather than guessing from the curtain object's class name.
    local cellOk, cell = pcall(getCell)
    if not cellOk or not cell then return nil end
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sqOk, nearby = pcall(function() return cell:getGridSquare(x + dx, y + dy, z) end)
            if sqOk and nearby then
                local listOk, objects = pcall(function() return nearby:getObjects() end)
                if listOk and objects then
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if isInstanceOfSafe(object, "IsoWindow") or isInstanceOfSafe(object, "IsoDoor") then
                            local hasOk, attached = pcall(function() return object:HasCurtains() end)
                            if hasOk and attached == curtain then return object end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function makeCurtainActionLabel(label, curtain)
    local host = resolveCurtainHost(curtain)
    local target = host or curtain
    local hint = host and isInstanceOfSafe(host, "IsoDoor") and "door" or "window"

    -- Prefer the actual host (the window or door), but still try the curtain's
    -- own sprite metadata if a broken/detached window cannot be resolved.
    local targetName = getWorldObjectDisplayName(target, hint)
    if not isUsableDisplayName(targetName) and target ~= curtain then
        targetName = getVanillaMoveableDisplayName(curtain)
    end
    if not isUsableDisplayName(targetName) then
        targetName = hint == "door" and getText("UI_GQS_RadialTargetDoor")
            or getText("UI_GQS_RadialTargetWindow")
    end
    return appendNamedTargetLine(label, targetName)
end

local function decorateRadialObjectAction(callback, label, args, radialApi)
    if not callback or not radialApi then return label end
    if callback == radialApi.onOpenCloseCurtain then
        return makeCurtainActionLabel(label, args[1])
    elseif callback == radialApi.onToggleRadio then
        return makeObjectActionLabel(label, args[1], "radio")
    elseif callback == radialApi.onLockDoor or callback == radialApi.onUnlockDoor then
        return makeObjectActionLabel(label, args[1], "door")
    elseif callback == radialApi.onRemoveBrokenGlass or callback == radialApi.onBarricade
        or callback == radialApi.onUnbarricade or callback == radialApi.onUnbarricadeMetal
        or callback == radialApi.onUnbarricadeMetalBar or callback == radialApi.onMetalBarricade
        or callback == radialApi.onMetalBarBarricade then
        return makeObjectActionLabel(label, args[1], "window")
    end
    return label
end

-- Preserve the GQS Drop Worn Bag action from the pre-split radial menu.
local function onDropWornBag(item, player)
    if not item or not player or item:isFavorite() then return end
    -- The bag can change after the radial slice is created; only drop it if it
    -- is still the item worn on the player's back.
    if player:getClothingItem_Back() ~= item then return end
    if not ISInventoryPaneContextMenu or type(ISInventoryPaneContextMenu.dropItem) ~= "function" then
        debugLog("Drop Worn Bag action unavailable: inventory drop API is missing")
        return
    end
    ISInventoryPaneContextMenu.dropItem(item, player:getPlayerNum())
end

local function showIfNeeded(player, menu, added)
    if not added or menu:isReallyVisible() then return end
    local playerIndex = player:getPlayerNum()
    menu:setX(getPlayerScreenLeft(playerIndex) + getPlayerScreenWidth(playerIndex) / 2 - menu:getWidth() / 2)
    menu:setY(getPlayerScreenTop(playerIndex) + getPlayerScreenHeight(playerIndex) / 2 - menu:getHeight() / 2)
    menu:addToUIManager()
    if JoypadState.players[playerIndex + 1] then
        menu:setHideWhenButtonReleased(Joypad.DPadUp)
        setJoypadFocus(playerIndex, menu)
        player:setJoypadIgnoreAimUntilCentered(true)
    end
end

-- Public extension API for future D-pad Up contextual-wheel actions.
-- Other GQS modules may call:
--   GQSTileRadialMenuFix.registerProvider("my.action", function(context)
--       for _, entry in ipairs(context.objects) do
--           local object = entry.object
--           -- Inspect objects in nearby squares, nearest/front squares first.
--       end
--       context:addSlice(label, texture, callback, arg1, arg2)
--       return true
--   end, 100)
-- Provider callbacks receive one context object containing player, menu, radial,
-- currentSquare, frontSquare, nearbySquares, objects and addSlice/findObjects helpers.
local GQSTileRadialMenuFix = rawget(_G, "GQSTileRadialMenuFix")
if type(GQSTileRadialMenuFix) ~= "table" then
    GQSTileRadialMenuFix = {}
    _G.GQSTileRadialMenuFix = GQSTileRadialMenuFix
end
GQSTileRadialMenuFix.apiVersion = 1
GQSTileRadialMenuFix.providers = GQSTileRadialMenuFix.providers or {}
GQSTileRadialMenuFix._nextProviderOrder = GQSTileRadialMenuFix._nextProviderOrder or 0

function GQSTileRadialMenuFix.registerProvider(id, callback, priority)
    if type(id) ~= "string" or id == "" or type(callback) ~= "function" then
        return false, "registerProvider expects a non-empty id and callback function"
    end
    local previous = GQSTileRadialMenuFix.providers[id]
    GQSTileRadialMenuFix._nextProviderOrder = GQSTileRadialMenuFix._nextProviderOrder + 1
    GQSTileRadialMenuFix.providers[id] = {
        id = id,
        callback = callback,
        priority = tonumber(priority) or 100,
        order = previous and previous.order or GQSTileRadialMenuFix._nextProviderOrder,
    }
    return true
end

function GQSTileRadialMenuFix.unregisterProvider(id)
    if GQSTileRadialMenuFix.providers[id] == nil then return false end
    GQSTileRadialMenuFix.providers[id] = nil
    return true
end

function GQSTileRadialMenuFix.getProviderIDs()
    local ids = {}
    for id in pairs(GQSTileRadialMenuFix.providers) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function buildProviderContext(player, menu, radial)
    local currentSquare = player and player:getCurrentSquare() or nil
    if not currentSquare then return nil end
    local playerIndex = player:getPlayerNum()
    local frontSquare = currentSquare:getAdjacentSquare(player:getDir())
    local frontX = frontSquare and frontSquare:getX() or nil
    local frontY = frontSquare and frontSquare:getY() or nil
    local cell = getCell()
    local squareRecords = {}
    local nearbySquares = {}

    -- Scan the whole 3x3 ring, including the current and front squares. Legacy
    -- extension slices still scan only side/rear neighbours to avoid duplicates
    -- with CustomGamepadUI; providers need the full ring for missing native actions.
    for dx = -1, 1 do
        for dy = -1, 1 do
            local nearby = cell:getGridSquare(currentSquare:getX() + dx, currentSquare:getY() + dy, currentSquare:getZ())
            if nearby then
                local priority
                if frontX ~= nil and frontY ~= nil
                    and nearby:getX() == frontX and nearby:getY() == frontY then
                    priority = 0
                elseif dx == 0 and dy == 0 then
                    priority = 1
                else
                    priority = 2 + dx * dx + dy * dy
                end
                squareRecords[#squareRecords + 1] = {
                    square = nearby, dx = dx, dy = dy, priority = priority,
                    tie = (dy + 1) * 3 + (dx + 1),
                }
            end
        end
    end
    table.sort(squareRecords, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.tie < b.tie
    end)

    local objects = {}
    local order = 0
    for _, squareRecord in ipairs(squareRecords) do
        nearbySquares[#nearbySquares + 1] = squareRecord.square
        local squareObjects = squareRecord.square:getObjects()
        for index = 0, squareObjects:size() - 1 do
            local object = squareObjects:get(index)
            order = order + 1
            objects[#objects + 1] = {
                object = object,
                square = squareRecord.square,
                dx = squareRecord.dx,
                dy = squareRecord.dy,
                priority = squareRecord.priority,
                order = order,
            }
        end
    end

    local context = {
        player = player,
        playerIndex = playerIndex,
        menu = menu,
        radial = radial,
        currentSquare = currentSquare,
        frontSquare = frontSquare,
        nearbySquares = nearbySquares,
        objects = objects,
        addedCount = 0,
    }
    function context:addSlice(label, texture, callback, ...)
        if not self.menu or type(self.menu.addSlice) ~= "function" then return false end
        self.menu:addSlice(label, texture, callback, ...)
        self.addedCount = self.addedCount + 1
        return true
    end
    function context:findObjects(predicate)
        local results = {}
        if type(predicate) ~= "function" then return results end
        for _, entry in ipairs(self.objects) do
            local ok, matched = pcall(predicate, entry.object, entry, self)
            if ok and matched then results[#results + 1] = entry end
        end
        return results
    end
    return context
end

local function runRegisteredProviders(context)
    if not context then return false end
    local registry = GQSTileRadialMenuFix.providers or {}
    local providers = {}
    for _, provider in pairs(registry) do providers[#providers + 1] = provider end
    table.sort(providers, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)

    local added = false
    for _, provider in ipairs(providers) do
        local before = context.addedCount
        local ok, result = pcall(provider.callback, context)
        if not ok then
            debugLog("D-pad Up provider failed: " .. tostring(provider.id) .. "; error=" .. tostring(result))
        elseif context.addedCount > before or result == true then
            added = true
        end
    end
    return added
end

local function onToggleNearbyLight(light, player)
    local worldMenu = rawget(_G, "ISWorldObjectContextMenu")
    if not worldMenu or type(worldMenu.onToggleLight) ~= "function" or not light or not player then return end
    -- Re-check at activation time; the target/power state may have changed since
    -- the wheel was opened. The vanilla callback handles movement and action queue.
    local squareOk, square = pcall(function() return light:getSquare() end)
    local indexOk, objectIndex = pcall(function() return light:getObjectIndex() end)
    local canOk, canSwitch = pcall(function() return light:canSwitchLight() end)
    if not squareOk or not square or not indexOk or objectIndex == -1 or not canOk or not canSwitch then return end
    local ok, err = pcall(worldMenu.onToggleLight, { light }, light, player:getPlayerNum())
    if not ok then debugLog("Toggle nearby light failed: " .. tostring(err)) end
end

local function registerBuiltInLightSwitchProvider()
    GQSTileRadialMenuFix.registerProvider("gqs.light-switch", function(context)
        if not optionEnabled("rightRadialLightSwitchEnabled", true) then return false end
        -- Show every usable switch in scan order (nearest first). A wall can
        -- hold a switch on each face; listing them all lets the player pick
        -- the side they actually want instead of the wheel silently choosing
        -- one. makeObjectActionLabel appends each switch's own name so the
        -- slices stay distinguishable.
        local added = false
        for _, entry in ipairs(context.objects) do
            local light = entry.object
            if instanceof(light, "IsoLightSwitch") then
                local squareOk, objectSquare = pcall(function() return light:getSquare() end)
                local canOk, canSwitch = pcall(function() return light:canSwitchLight() end)
                if squareOk and objectSquare and canOk and canSwitch then
                    local activeOk, active = pcall(function() return light:isActivated() end)
                    if activeOk then
                        local labelKey = active and "ContextMenu_Turn_Off" or "ContextMenu_Turn_On"
                        local label = makeObjectActionLabel(getText(labelKey), light, "light")
                        if context:addSlice(label, getTexture("media/ui/icon_light_bulb.png"), onToggleNearbyLight, light, context.player) then
                            added = true
                        end
                    end
                end
            end
        end
        return added
    end, 20)
end

local function onSmashNearbyWindow(window, player)
    local worldMenu = rawget(_G, "ISWorldObjectContextMenu")
    if not worldMenu or type(worldMenu.onSmashWindow) ~= "function" or not window or not player then return end
    -- Re-check before dispatching the native action so a stale wheel slice cannot
    -- request smashing a window that has already broken or lost its glass.
    local squareOk, square = pcall(function() return window:getSquare() end)
    local smashedOk, smashed = pcall(function() return window:isSmashed() end)
    local removedOk, removed = pcall(function() return window:isGlassRemoved() end)
    if not squareOk or not square or not smashedOk or smashed or not removedOk or removed then return end
    local ok, err = pcall(worldMenu.onSmashWindow, { window }, window, player:getPlayerNum())
    if not ok then debugLog("Smash nearby window failed: " .. tostring(err)) end
end

local function registerBuiltInSmashWindowProvider()
    GQSTileRadialMenuFix.registerProvider("gqs.smash-intact-window", function(context)
        if not optionEnabled("rightRadialSmashWindowEnabled", true) then return false end
        for _, entry in ipairs(context.objects) do
            local window = entry.object
            if instanceof(window, "IsoWindow") then
                local squareOk, objectSquare = pcall(function() return window:getSquare() end)
                local smashedOk, smashed = pcall(function() return window:isSmashed() end)
                local removedOk, removed = pcall(function() return window:isGlassRemoved() end)
                if squareOk and objectSquare and smashedOk and not smashed and removedOk and not removed then
                    local label = makeObjectActionLabel(getText("UI_GQS_RadialSmashWindow"), window, "window")
                    context:addSlice(label, getTexture("media/ui/icon_glass_broken.png"), onSmashNearbyWindow, window, context.player)
                    return true -- avoids ambiguous duplicate slices for multiple nearby windows
                end
            end
        end
        return false
    end, 30)
end

registerBuiltInLightSwitchProvider()
registerBuiltInSmashWindowProvider()

local function addNeighborSlices(player, menu, includeFront)
    local square = player:getCurrentSquare()
    if not square then return false end
    local playerIndex = player:getPlayerNum()
    local front = square:getAdjacentSquare(player:getDir())
    local cell = getCell()
    local found, added, seenSquare = {}, false, {}

    -- Visit the 3x3 ring in numpad-style priority order, NOT raw dx/dy order:
    --   5 (self) -> 8 (facing) -> 7/9 (forward diagonals)
    --   -> 4/6 (direct left/right) -> 1/2/3 (behind)
    -- All nine squares are scanned; squares behind the player only lose
    -- priority (and are excluded from water selection) but still show actions.
    -- Facing is derived from the front square's offset, so this does not depend
    -- on any direction-index constant (safer under Kahlua).
    local facingX = 0
    local facingY = 0
    if front then
        local okFX, fx = pcall(function() return front:getX() - square:getX() end)
        local okFY, fy = pcall(function() return front:getY() - square:getY() end)
        if okFX and okFY then facingX, facingY = fx, fy end
    end
    local function isForward(dx, dy)
        return (dx * facingX + dy * facingY) > 0
    end
    local squareRecords = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            local nearby = cell:getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
            if nearby and not seenSquare[nearby] then
                seenSquare[nearby] = true
                -- Numpad-style priority, matching the player's mental model:
                --   5 (self) -> 8 (facing) -> 7/9 (forward diagonals)
                --   -> 4/6 (direct left/right) -> 1/2/3 (behind)
                local dot = dx * facingX + dy * facingY
                local priority
                local behind
                if dx == 0 and dy == 0 then
                    priority, behind = 0, false         -- 5: player's own square
                elseif front and nearby == front then
                    priority, behind = 1, false         -- 8: square faced
                elseif dot > 0 then
                    priority, behind = 2, false         -- 7/9: forward diagonals
                elseif dot == 0 then
                    priority, behind = 3, false         -- 4/6: direct left/right
                else
                    priority, behind = 4, true          -- 1/2/3: behind
                end
                squareRecords[#squareRecords + 1] = {
                    square = nearby, dx = dx, dy = dy, priority = priority,
                    tie = (dy + 1) * 3 + (dx + 1),
                    behind = behind,
                }
            end
        end
    end
    table.sort(squareRecords, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.tie < b.tie
    end)

    -- When CGUI owns its native wheel (includeFront=false) it already handles
    -- the current and facing squares; we only add the other seven to avoid
    -- duplicating its slices. The SRM / animal / LB paths pass includeFront=true
    -- and cover all nine here.
    local function shouldScan(record)
        if includeFront then return true end
        if record.dx == 0 and record.dy == 0 then return false end
        if front and record.square == front then return false end
        return true
    end

    local waters, seenWater = {}, {}
    for _, record in ipairs(squareRecords) do
        if shouldScan(record) then
            local objects = record.square:getObjects()
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                if instanceof(object, "BarricadeAble") and not found.barricade then found.barricade = object end
                if instanceof(object, "IsoWindow") then
                    if not found.window then found.window = object end
                    if not found.windowCurtain then found.windowCurtain = object:HasCurtains() end
                elseif instanceof(object, "IsoDoor") and not object:IsOpen() then
                    if not found.door then found.door = object end
                    if not found.doorCurtain then found.doorCurtain = object:HasCurtains() end
                elseif instanceof(object, "IsoWaveSignal") and not found.radio then
                    found.radio = object
                end
                -- includeFront=false is the CGUI path: CGUI only covers the
                -- player + facing squares, so we may still offer the side and
                -- rear squares there (no duplication). The forward-only filter
                -- applies to the SRM / animal / LB wheels that cover all nine.
                -- Collect all candidates first; the 2-slot budget is applied
                -- after sorting clean water ahead of tainted water, so a
                -- contaminated puddle cannot crowd out a clean sink.
                if ((includeFront and not record.behind) or not includeFront)
                    and objectHasWater(object)
                    and not instanceof(object, "IsoClothingDryer")
                    and not instanceof(object, "IsoClothingWasher")
                    and not seenWater[object] then
                    seenWater[object] = true
                    waters[#waters + 1] = object
                end
            end
        end
    end

    -- Connected fluid sources that hasWater() does not report. Keep the sink
    -- object itself (not the rain collector behind it) so the native action
    -- transfers the connected source contents correctly. Same facing filter
    -- and the same MAX_WATER_SOURCES budget as ordinary water above.
    local mixedWaters, seenMixed = {}, {}
    for _, record in ipairs(squareRecords) do
        local objects = record.square:getObjects()
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if ((includeFront and not record.behind) or not includeFront)
                and not objectHasWater(object)
                and objectHasLiquidExternalSource(object)
                and not seenMixed[object] then
                seenMixed[object] = true
                mixedWaters[#mixedWaters + 1] = object
                debugLog("Detected a connected fluid source not reported by hasWater(); using the original sink object for drink/fill actions.")
            end
        end
    end

    -- Merge both candidate pools, then split into clean / tainted while
    -- preserving the player-centric collection order within each group (no
    -- table.sort: its stability is not guaranteed under Kahlua). Apply the
    -- shared 2-slot budget afterwards so clean sources take priority and a
    -- contaminated puddle cannot crowd out a clean sink.
    local allWaters = {}
    for _, water in ipairs(waters) do allWaters[#allWaters + 1] = water end
    for _, water in ipairs(mixedWaters) do allWaters[#allWaters + 1] = water end
    waters, mixedWaters = {}, {}
    for _, water in ipairs(allWaters) do
        if objectWaterIsTainted(water) then
            mixedWaters[#mixedWaters + 1] = water
        else
            waters[#waters + 1] = water
        end
    end
    -- Clean first, then tainted, up to the shared budget.
    local ordered = {}
    for _, water in ipairs(waters) do
        if #ordered < MAX_WATER_SOURCES then ordered[#ordered + 1] = water end
    end
    for _, water in ipairs(mixedWaters) do
        if #ordered < MAX_WATER_SOURCES then ordered[#ordered + 1] = water end
    end
    waters = ordered

    local radial = rawget(_G, "SWTileRadialMenu")
    if not radial then return false end
    if not player:isOutside() and found.door and found.door:isExteriorDoor(player) then
        if found.door:isLocked() then
            menu:addSlice(getText("ContextMenu_UnlockDoor"), getTexture("media/ui/icon_key.png"), radial.onUnlockDoor, found.door, player)
        else
            menu:addSlice(getText("ContextMenu_LockDoor"), getTexture("media/ui/icon_key.png"), radial.onLockDoor, found.door, player)
        end
        added = true
    end
    local function addCurtain(curtain, isDoorCurtain)
        if not curtain then return end
        local open
        if isDoorCurtain then open = curtain:isCurtainOpen() else open = curtain:IsOpen() end
        local label = open and "ContextMenu_Close_curtains" or "ContextMenu_Open_curtains"
        local icon = getCurtainIcon()
        menu:addSlice(getText(label), icon, radial.onOpenCloseCurtain, curtain, player)
        added = true
    end
    if not player:isOutside() then addCurtain(found.doorCurtain, true) end
    addCurtain(found.windowCurtain, false)
    local barricadeAble = found.barricade
    if barricadeAble then
        local inventory = player:getInventory()
        local barricade = barricadeAble:getBarricadeForCharacter(player)
        local hasHammer = inventory:containsTagEvalRecurse(ItemTag.HAMMER, function(item) return not item:isBroken() end)
        local hasRemoveTool = inventory:containsTagEvalRecurse(ItemTag.REMOVE_BARRICADE, function(item) return not item:isBroken() end)
        local hasTorch = inventory:getFirstEvalRecurse(function(item) return item:getType() == "BlowTorch" and item:getCurrentUses() > 0 end) ~= nil
        if barricade then
            if hasHammer and barricade:canAddPlank() and inventory:containsTypeRecurse("Plank") and inventory:getItemCountRecurse("Base.Nails") > 1 then
                menu:addSlice(getText("ContextMenu_Barricade"), getTexture("media/ui/icon_plank.png"), radial.onBarricade, barricadeAble, player); added = true
            end
            if hasRemoveTool and barricade:getNumPlanks() > 0 then
                menu:addSlice(getText("ContextMenu_Unbarricade"), getTexture("media/ui/icon_plank.png"), radial.onUnbarricade, barricadeAble, player); added = true
            end
            if hasTorch and barricade:isMetal() then
                menu:addSlice(getText("ContextMenu_Unbarricade"), getTexture("media/ui/icon_sheet_metal.png"), radial.onUnbarricadeMetal, barricadeAble, player); added = true
            end
            if hasTorch and barricade:isMetalBar() then
                menu:addSlice(getText("ContextMenu_Unbarricade"), getTexture("media/ui/icon_metal_bar.png"), radial.onUnbarricadeMetalBar, barricadeAble, player); added = true
            end
        elseif barricadeAble:isBarricadeAllowed() then
            if hasHammer and inventory:containsTypeRecurse("Plank") and inventory:getItemCountRecurse("Base.Nails") > 1 then
                menu:addSlice(getText("ContextMenu_Barricade"), getTexture("media/ui/icon_plank.png"), radial.onBarricade, barricadeAble, player); added = true
            end
            if hasTorch and inventory:containsTypeRecurse("SheetMetal") then
                menu:addSlice(getText("ContextMenu_MetalBarricade"), getTexture("media/ui/icon_sheet_metal.png"), radial.onMetalBarricade, barricadeAble, player); added = true
            end
            if hasTorch and inventory:getItemCountRecurse("Base.MetalBar") > 2 then
                menu:addSlice(getText("ContextMenu_MetalBarBarricade"), getTexture("media/ui/icon_metal_bar.png"), radial.onMetalBarBarricade, barricadeAble, player); added = true
            end
        end
    end
    if found.window and player:getPrimaryHandItem() and found.window:isSmashed() and not found.window:isGlassRemoved() then
        menu:addSlice(getText("ContextMenu_RemoveBrokenGlass"), getTexture("media/ui/icon_glass_broken.png"), radial.onRemoveBrokenGlass, found.window, player); added = true
    end
    if found.radio then
        local label = found.radio:getDeviceData():getIsTurnedOn() and "ContextMenu_Turn_Off" or "ContextMenu_Turn_On"
        local icon = getRadioIcon(found.radio, getTexture("media/ui/icon_light_bulb.png"))
        menu:addSlice(getText(label), icon, radial.onToggleRadio, found.radio, player); added = true
    end
    local function addWaterSlices(water)
        if not water then return end
        local tainted = water:isTaintedWater() and "(" .. getText("Tooltip_tainted") .. ") " or ""
        menu:addSlice(makeDrinkLabel(tainted .. getText("ContextMenu_Drink"), water), getTexture("media/ui/icon_water_drop.png"), radial.onDrink, water, player)
        added = true
        local container = player:getInventory():getBestEvalRecurse(eligibleWaterContainer, compareWater)
        if container then
            local fillLabel = makeFillLabel(tainted .. getText("ContextMenu_Fill"), container, water)
            local containerTexture = getWaterContainerTexture(container)
            menu:addSlice(fillLabel, containerTexture, radial.onTakeWater, water, container, player)
        end
    end
    -- One drink/fill pair per reachable source, in player-centric order. The
    -- label helper appends the source name so the player can tell them apart.
    for _, water in ipairs(waters) do
        addWaterSlices(water)
    end

    -- This action was part of GQS's old SWTileRadialMenu implementation. It
    -- belongs in the D-pad Up contextual wheel alongside adjacent-tile actions.
    local wornBag = player:getClothingItem_Back()
    if wornBag and not wornBag:isFavorite() then
        menu:addSlice(getText("UI_optionscreen_binding_DropWornBag"), wornBag:getTex(), onDropWornBag, wornBag, player)
        added = true
        debugLog("Drop Worn Bag slice added to the D-pad Up contextual wheel")
    end
    -- Provider API: new D-pad Up actions are registered independently from the
    -- legacy neighbour-slice code. Providers receive a full 3x3 context and may
    -- add their own slices without touching CustomGamepadUI's source file.
    local providerContext = buildProviderContext(player, menu, radial)
    if runRegisteredProviders(providerContext) then added = true end
    return added
end

local function install()
    if installed then return end
    local radial = rawget(_G, "SWTileRadialMenu")
    if not radial or type(radial.showRadialMenu) ~= "function" then return end
    if not radial._gqsTileRadialMenuFixInstalled then
        local original = radial.showRadialMenu
        radial.showRadialMenu = function(player, ...)
            -- The vanilla D-pad handler may open a vehicle or animal wheel
            -- before CustomGamepadUI calls this function. Keep that wheel
            -- visible instead of replacing it with the contextual GQS wheel.
            if suppressCustomWheel then return false end
            local menu = player and getPlayerRadialMenu(player:getPlayerNum())
            if not menu then return original(player, ...) end
            if menu:isReallyVisible() then return original(player, ...) end

            -- Take over the D-pad Up wheel using CGUI's own tileRadialMenu
            -- toggle: when it is ON, build the entire wheel from GQS's 3x3
            -- scan (same player-centric logic as the SRM path) and skip CGUI's
            -- native scan completely. That native scan keeps the LAST water
            -- object in the player/facing squares and also surfaces odd objects
            -- (e.g. a toilet as "natural water source"), which this replaces.
            -- No new GQS option is added; the CGUI switch is the single source
            -- of truth, so turning it off restores CGUI's vanilla wheel.
            local takeOver = false
            local reqOk, cgui = pcall(require, "SWModOptions")
            if reqOk and cgui and cgui.tileRadialMenu then
                local okValue, value = pcall(function() return cgui.tileRadialMenu:getValue() end)
                takeOver = okValue and value == true
            end
            -- When SRM is installed it owns the wheel; never build here.
            if takeOver and rawget(_G, "SRMRadialMenu") ~= nil then takeOver = false end

            if takeOver then
                menu:clear()
                local added = false
                local okAdd, addResult = pcall(function()
                    return addNeighborSlices(player, menu, true)
                end)
                added = okAdd and addResult == true
                if not okAdd then debugLog("takeover scan failed: " .. tostring(addResult)) end
                showIfNeeded(player, menu, added)
                return added
            end

            -- Toggle OFF (or SRM active): run CGUI's original wheel untouched.
            return original(player, ...)
        end
        radial._gqsTileRadialMenuFixInstalled = true
    end

    -- When the vanilla animal-care wheel already owns the D-pad Up press, add
    -- our contextual actions into that same wheel instead of staying silent.
    -- The vehicle wheel keeps exclusive priority and is never modified.
    -- The wheel is already displayed and focused by AnimalContextMenu, so we
    -- only add slices and re-center; showIfNeeded is deliberately not called.
    local function appendToAnimalWheel(player, playerNum)
        local wheel = nil
        if type(getPlayerRadialMenu) == "function" then
            local okWheel, w = pcall(getPlayerRadialMenu, playerNum)
            if okWheel then wheel = w end
        end
        if not wheel then return false end
        local okAdd, added = pcall(function()
            return GQSTileRadialMenuFix.addContextSlices(player, wheel, true)
        end)
        if not okAdd then
            debugLog("animal wheel append failed: " .. tostring(added))
            return false
        end
        if added then pcall(function() wheel:center() end) end
        debugLog("GQS actions appended to the animal-care wheel: " .. tostring(added))
        return added == true
    end

    -- Force the Smart Radial Menu wheel open with our contextual actions,
    -- bypassing the whole upstream chain (vanilla vehicle/animal + CGUI).
    -- This is the explicit LB + D-pad Up escape hatch: the player asked for
    -- the mod wheel even though a vehicle or pet would normally claim Up.
    -- Returns true when a wheel was actually opened.
    local function openSrmWheelWithGqs(player, playerNum)
        local srm = rawget(_G, "SRMRadialMenu")
        if not srm or type(srm.showRadialMenu) ~= "function" then return false end

        -- A stale vanilla wheel must not make SRM think vanilla claimed Up.
        -- Clear it before opening SRM directly (we are skipping the vanilla
        -- handler on purpose, so nothing else will clear it for us).
        if type(getPlayerRadialMenu) == "function" then
            pcall(function()
                local vanilla = getPlayerRadialMenu(playerNum)
                if vanilla then vanilla:clear() end
            end)
        end
        if type(srm.hasSwappedMenu) == "table" then srm.hasSwappedMenu[playerNum] = false end

        -- Always call showRadialMenu(), never reuse SRMRootMenu[playerNum].
        -- SRM rebuilds and re-displays that menu on every call, and the previous
        -- one was undisplayed by setHideWhenButtonReleased(DPadUp) when the
        -- player let go. Reusing the stale menu only added slices to a hidden
        -- panel, so the second LB+Up press appeared to open nothing.
        local okShow, errShow = pcall(function() return srm.showRadialMenu(player) end)
        if not okShow then
            srmLog("LB+Up: SRM showRadialMenu failed: " .. tostring(errShow))
            return false
        end
        local srmMenu = srm.SRMRootMenu and srm.SRMRootMenu[playerNum]
        if not srmMenu then
            srmLog("LB+Up: SRM opened but no root menu for player " .. tostring(playerNum))
            return false
        end

        srmMenu.isFromOtherMenu = false
        local okAdd, addResult = pcall(function()
            local adapter = {
                addSlice = function(_, label, texture, callback, ...)
                    local base = rawget(_G, "ISRadialMenu")
                    if type(base) == "table" and type(base.addSlice) == "function" then
                        return base.addSlice(srmMenu, label, texture, callback, ...)
                    end
                    return srmMenu:addSlice(label, texture, callback, nil, nil, nil, nil, ...)
                end,
            }
            return GQSTileRadialMenuFix.addContextSlices(player, adapter, true)
        end)
        if not okAdd then srmLog("LB+Up: SRM append failed: " .. tostring(addResult)) end
        if addResult == true then pcall(function() srmMenu:center() end) end
        srmLog("LB+Up: forced SRM wheel open (added=" .. tostring(addResult == true) .. ")")
        return true
    end

    -- The old combined SWTileRadialMenu checked interaction context before
    -- replacing the D-pad Up wheel. Recreate that priority from GQS without
    -- changing CustomGamepadUI's source file: its handler calls showRadialMenu
    -- after vanilla has had the chance to build a vehicle/animal wheel.
    local dpadWheels = rawget(_G, "ISDPadWheels")
    if dpadWheels and type(dpadWheels.onDisplayUp) == "function" and not dpadWheels._gqsTileRadialPriorityInstalled then
        local originalOnDisplayUp = dpadWheels.onDisplayUp
        dpadWheels.onDisplayUp = function(joypadData, ...)
            local playerIndex = joypadData and joypadData.player
            local player = playerIndex ~= nil and type(getSpecificPlayer) == "function" and getSpecificPlayer(playerIndex) or nil

            -- RB + D-pad chords (moodle browser / zoom) belong to GQSRBZoom.
            -- Bail out BEFORE clearing or reopening anything: otherwise an SRM
            -- fallback reopens SRMRootMenu and steals focus, and the player can
            -- no longer cycle the top-right moodle icon with RB+Up. This is
            -- deliberately checked ahead of the tileRadialMenu option because
            -- RB shortcuts are a separate feature with their own settings.
            local rbControls = rawget(_G, "GQS_RBControls")
            if playerIndex ~= nil and rbControls and type(rbControls.isDpadChordOwned) == "function" then
                local okChord, owned = pcall(rbControls.isDpadChordOwned, playerIndex, "Up")
                if okChord and owned then
                    srmLog("RB+Up chord owned by GQSRBZoom; skipping D-pad Up wheel")
                    return nil
                end
            end

            -- LB + D-pad Up escape hatch: force the mod wheel (Smart Radial Menu
            -- with our actions appended) open, overriding even the vehicle/animal
            -- wheel. This is intentionally independent of the tileRadialMenu
            -- master switch and of any native context -- the player explicitly
            -- asked for the mod wheel with this chord. Only meaningful when SRM
            -- is installed (it is SRM's wheel we open).
            local lbOption = GQS.lbUpOpensSrmWheel
            local lbEnabled = lbOption and type(lbOption.getValue) == "function" and lbOption:getValue() == true
            if lbEnabled and playerIndex ~= nil and player and rawget(_G, "SRMRadialMenu") then
                local lbQuery = rbControls and type(rbControls.isLBChordHeld) == "function" and rbControls.isLBChordHeld or nil
                if lbQuery then
                    local okLB, held = pcall(lbQuery, playerIndex, "Up")
                    if okLB and held then
                        openSrmWheelWithGqs(player, player:getPlayerNum())
                        return nil
                    end
                end
            end

            -- CustomGamepadUI's "Tile Radial Menu" tick box is the master switch
            -- for the whole D-pad Up extension. When it is off we must stay
            -- completely out of the way: no CGUI wheel, no GQS neighbour slices,
            -- and no GQS actions appended to a Smart Radial Menu wheel. Let the
            -- upstream chain (and SRM, if installed) decide by themselves.
            -- The vanilla vehicle/animal wheel is never touched by us here.
            local option = GQS.tileRadialMenu
            local enabled = option and type(option.getValue) == "function" and option:getValue() == true
            local hasVehicleContext = false
            local hasAnimalContext = false
            if enabled and player then
                local ok, vehicle = pcall(function() return player:getVehicle() end)
                hasVehicleContext = ok and vehicle ~= nil
                if not hasVehicleContext and ISVehicleMenu and type(ISVehicleMenu.getVehicleToInteractWith) == "function" then
                    local vehicleOk, target = pcall(ISVehicleMenu.getVehicleToInteractWith, player)
                    hasVehicleContext = vehicleOk and target ~= nil
                end
                if not hasVehicleContext and AnimalContextMenu and type(AnimalContextMenu.getAnimalToInteractWith) == "function" then
                    local animalOk, target = pcall(AnimalContextMenu.getAnimalToInteractWith, player)
                    hasAnimalContext = animalOk and target ~= nil
                end
            end
            local hasNativeContext = hasVehicleContext or hasAnimalContext
            -- Smart Radial compatibility: delegate the priority decision to
            -- SRM's own onDisplayUp wrapper so "Show SRM after vanilla menu"
            -- is honoured. The previous version opened the SRM wheel here and
            -- returned immediately, which skipped SRM, CustomGamepadUI and the
            -- vanilla handler entirely: a vehicle/animal wheel could never win
            -- the D-pad Up press. Now we run the whole chain first, read back
            -- the result, and only append our contextual slices afterwards.
            --
            -- The upstream "Tile Radial Menu" option gates this whole branch.
            -- Before v1.5.14.4 the SRM branch ignored it and appended our
            -- actions unconditionally, so toggling the option had no visible
            -- effect whenever Smart Radial Menu was installed. With the option
            -- off we skip the branch entirely and fall through to the plain
            -- upstream call below: no CGUI wheel, no GQS slices, no suppressed
            -- wheel, and SRM (if loaded) keeps its own behaviour untouched.
            local srm = rawget(_G, "SRMRadialMenu")
            if srm and enabled and player then
                local playerNum = playerIndex or 0
                if type(srm.hasSwappedMenu) == "table" then srm.hasSwappedMenu[playerNum] = false end

                -- Make isEmpty() describe THIS press. The vanilla handler
                -- clears the wheel as its first step, but when SRM takes
                -- priority that handler never runs, so stale slices from the
                -- previous session could look like a freshly opened menu.
                if type(getPlayerRadialMenu) == "function" then
                    pcall(function()
                        local wheel = getPlayerRadialMenu(playerNum)
                        if wheel then wheel:clear() end
                    end)
                end

                -- suppressCustomWheel stops CustomGamepadUI from filling the
                -- vanilla wheel with its own slices: that would make SRM think
                -- vanilla claimed the press even with no vehicle nearby.
                -- SRMRadialMenu.showRadialMenu is a different function and is
                -- deliberately NOT affected by this flag.
                local previous = suppressCustomWheel
                suppressCustomWheel = true
                local okCall, callResult = pcall(originalOnDisplayUp, joypadData, ...)
                suppressCustomWheel = previous
                if not okCall then error(callResult) end

                -- Read back instead of guessing. A non-empty vanilla wheel
                -- means the vehicle/animal menu won: leave it alone and do not
                -- touch the SRM wheel at all.
                local vanillaClaimed = false
                if type(getPlayerRadialMenu) == "function" then
                    local okWheel, wheel = pcall(getPlayerRadialMenu, playerNum)
                    if okWheel and wheel then
                        local okEmpty, empty = pcall(function() return wheel:isEmpty() end)
                        vanillaClaimed = okEmpty and empty == false
                    end
                end
                if vanillaClaimed then
                    -- Vehicle wheel keeps exclusive priority, unchanged.
                    -- An animal wheel, however, only has a few care slices:
                    -- merge our contextual actions into that same wheel so the
                    -- player can still drink/toggle lights while a pet is near.
                    if hasAnimalContext and not hasVehicleContext and player then
                        appendToAnimalWheel(player, playerNum)
                        srmLog("SRM: animal wheel kept priority; GQS actions appended")
                    else
                        srmLog("SRM: vanilla vehicle wheel kept priority")
                    end
                    return callResult
                end

                -- Vanilla wheel is empty, so SRM should have opened its root
                -- menu. Fall back to opening it directly if we happen to sit
                -- inside SRM's wrapper (another mod re-wrapping after us).
                local srmMenu = srm.SRMRootMenu and srm.SRMRootMenu[playerNum]
                if not srmMenu then
                    local okShow, errShow = pcall(function() srm.showRadialMenu(player) end)
                    if not okShow then
                        srmLog("SRM showRadialMenu failed: " .. tostring(errShow))
                        return callResult
                    end
                    srmMenu = srm.SRMRootMenu and srm.SRMRootMenu[playerNum]
                end

                local added = false
                if srmMenu then
                    srmMenu.isFromOtherMenu = false
                    local okAdd, addResult = pcall(function()
                        local adapter = {
                            addSlice = function(_, label, texture, callback, ...)
                                local base = rawget(_G, "ISRadialMenu")
                                if type(base) == "table" and type(base.addSlice) == "function" then
                                    return base.addSlice(srmMenu, label, texture, callback, ...)
                                end
                                return srmMenu:addSlice(label, texture, callback, nil, nil, nil, nil, ...)
                            end,
                        }
                        return GQSTileRadialMenuFix.addContextSlices(player, adapter, true)
                    end)
                    added = okAdd and addResult == true
                    if added then pcall(function() srmMenu:center() end) end
                    if not okAdd then srmLog("SRM append failed: " .. tostring(addResult)) end
                end
                srmLog("SRM branch: delegated=" .. tostring(okCall) .. " menu="
                    .. tostring(srmMenu ~= nil) .. " added=" .. tostring(added))
                return callResult
            end

            if not hasNativeContext then return originalOnDisplayUp(joypadData, ...) end

            local previous = suppressCustomWheel
            suppressCustomWheel = true
            local ok, result = pcall(originalOnDisplayUp, joypadData, ...)
            suppressCustomWheel = previous
            if not ok then error(result) end
            if hasAnimalContext and not hasVehicleContext and player then
                appendToAnimalWheel(player, player:getPlayerNum())
            else
                debugLog("Native vehicle wheel kept priority over the GQS D-pad Up wheel")
            end
            return result
        end
        dpadWheels._gqsTileRadialPriorityInstalled = true
    end
    installed = dpadWheels ~= nil and dpadWheels._gqsTileRadialPriorityInstalled == true
end
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(install) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end

-- Exposed for GQSSmartRadialCompat: append the contextual world-object slices to
-- an external radial menu (Smart Radial Menu) through an adapter table that
-- implements addSlice with the vanilla ISRadialMenu signature.
GQSTileRadialMenuFix.addContextSlices = addNeighborSlices

return GQSTileRadialMenuFix
