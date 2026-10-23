-- Allows auto-drinking water-primary fluid mixtures without changing vanilla files.
-- Per-container opt-out is stored on that inventory item and synchronized in MP.

local CGUI = require("GQSModOptions")
require "ISUI/ISFluidContainerMenu"

local GQSMixedLiquidAutoDrink = {}
local installed = false
local replayingVanillaAutoDrink = false
local ITEM_SETTING_KEY = "GQSMixedLiquidAutoDrink"
local WATER_RATIO_THRESHOLD = 0.5
local MAX_SIP_AMOUNT = 0.12
local NETWORK_MODULE = "GQS_MixedLiquidAutoDrink"
local pendingRequests = {}
local lastRequestAt = {}
local nextRequestId = 0
local lastPlayerUpdateCheck = {}
local REQUEST_COOLDOWN_MS = 750
local PLAYER_UPDATE_CHECK_MS = 1000

local function isEnabled()
    return CGUI.mixedLiquidAutoDrinkEnabled
        and type(CGUI.mixedLiquidAutoDrinkEnabled.getValue) == "function"
        and CGUI.mixedLiquidAutoDrinkEnabled:getValue() == true
end

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("mixedAutoDrink", message)
    end
end

local function itemFromContextEntry(entry)
    if not entry then return nil end
    if instanceof(entry, "InventoryItem") then return entry end
    if type(entry) == "table" and type(entry.items) == "table" then
        for _, item in ipairs(entry.items) do
            if instanceof(item, "InventoryItem") then return item end
        end
    end
    return nil
end

local function getMixture(item)
    if not item or not item.getFluidContainer then return nil end
    local fluidContainer = item:getFluidContainer()
    if not fluidContainer or fluidContainer:isEmpty() or not fluidContainer:isMixture() then return nil end
    return fluidContainer
end

local function isSafeWaterPrimaryMixture(item, fluidContainer)
    if not item or not fluidContainer then return false end
    if not fluidContainer:isMixture() or not Fluid or not Fluid.Water then return false end
    if type(fluidContainer.getRatioForFluid) ~= "function"
        or fluidContainer:getRatioForFluid(Fluid.Water) <= WATER_RATIO_THRESHOLD then
        return false
    end
    if fluidContainer.isTainted and fluidContainer:isTainted() then return false end
    if fluidContainer.isPoisonous and fluidContainer:isPoisonous() then return false end
    local data = item:getModData()
    return data[ITEM_SETTING_KEY] ~= false
end

local function setContainerPreference(item, enabled)
    if not item or not item.getModData then return end
    local data = item:getModData()
    data[ITEM_SETTING_KEY] = enabled == true
    if item.transmitModData then item:transmitModData() end
end

local function onSetContainerPreference(item, enabled)
    setContainerPreference(item, enabled)
end

local function onFillInventoryContextMenu(playerNum, context, items)
    if not isEnabled() or not context or not items then return end
    local fluidOption = context:getOptionFromName(getText("ContextMenu_Fluid"))
    if not fluidOption or not fluidOption.subOption then return end
    local fluidMenu = context:getSubMenu(fluidOption.subOption)
    if not fluidMenu then return end

    local actualItems = ISInventoryPane and ISInventoryPane.getActualItems
        and ISInventoryPane.getActualItems(items) or items
    local added = {}
    for _, entry in ipairs(actualItems) do
        local item = itemFromContextEntry(entry)
        local fluidContainer = getMixture(item)
        if fluidContainer and not added[item] then
            added[item] = true
            local enabled = item:getModData()[ITEM_SETTING_KEY] ~= false
            local labelKey = enabled and "UI_GQOS_MixedLiquidAutoDrinkDisableContainer"
                or "UI_GQOS_MixedLiquidAutoDrinkEnableContainer"
            fluidMenu:addOption(getText(labelKey), item, onSetContainerPreference, not enabled)
        end
    end
end

local function getMixedWaterContainer(character)
    if not character or not character.getInventory then return nil end
    local inventory = character:getInventory()
    if not inventory then return nil end
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fluidContainer = item and item:getFluidContainer() or nil
        if fluidContainer and isSafeWaterPrimaryMixture(item, fluidContainer)
            and fluidContainer:getAmount() > 0 then
            return item, fluidContainer
        end
    end
    return nil
end

local function onServerCommand(module, command, args)
    if module ~= NETWORK_MODULE or command ~= "mixedDrinkResult" or not args then return end
    local playerNum, matchedPending = nil, nil
    for pendingPlayerNum, pending in pairs(pendingRequests) do
        if tostring(args.requestId) == tostring(pending.requestId) then
            playerNum, matchedPending = pendingPlayerNum, pending
            break
        end
    end
    if not matchedPending then return end
    pendingRequests[playerNum] = nil
    if args.accepted == true then
        log("Server accepted immediate mixed-liquid auto-drink request.")
    elseif args.reason ~= "cooldown" then
        log("Server rejected mixed-liquid auto-drink request: " .. tostring(args.reason))
    end
end

local function drinkMixedLiquid(character, item, fluidContainer, currentAmount)
    local sipAmount = math.min(MAX_SIP_AMOUNT, currentAmount)
    if isClient and isClient() then
        local playerNum = character.getPlayerNum and character:getPlayerNum() or nil
        if playerNum == nil or getSpecificPlayer(playerNum) ~= character then return end

        local now = getTimestampMs()
        if lastRequestAt[playerNum] and now - lastRequestAt[playerNum] < REQUEST_COOLDOWN_MS then return end
        local pending = pendingRequests[playerNum]
        if pending and now - pending.sentAt < 5000 then return end
        if pending then
            log("Mixed-liquid auto-drink request timed out; retrying with a new request id.")
            pendingRequests[playerNum] = nil
        end

        nextRequestId = nextRequestId + 1
        local requestId = nextRequestId
        pendingRequests[playerNum] = { requestId = requestId, sentAt = now }
        lastRequestAt[playerNum] = now
        local ok, err = pcall(function()
            sendClientCommand(character, NETWORK_MODULE, "drinkMixedLiquid", {
                itemId = item:getID(),
                requestId = requestId,
            })
        end)
        if not ok then
            pendingRequests[playerNum] = nil
            log("Could not send mixed-liquid auto-drink request: " .. tostring(err))
        else
            log("Sent mixed-liquid auto-drink request to server.")
        end
        return
    end

    -- In single player, execute immediately. In multiplayer the server performs
    -- this call after validating the request in the server-side companion file.
    local ok, err = pcall(function()
        character:DrinkFluid(item, sipAmount / currentAmount, false)
        item:syncItemFields()
    end)
    if not ok then
        log("Immediate mixed-liquid auto-drink failed: " .. tostring(err))
    end
end

local function onAutoDrink(character)
    if replayingVanillaAutoDrink or not character then return end

    -- The AutoDrink hook replaces the Java implementation. Re-enter it once
    -- without our listener so clean water keeps using the exact vanilla path.
    local beforeThirst = nil
    local stats = character.getStats and character:getStats() or nil
    if stats then beforeThirst = tonumber(stats:get(CharacterStat.THIRST)) end

    replayingVanillaAutoDrink = true
    Hook.AutoDrink.Remove(onAutoDrink)
    local ok, err = pcall(function() character:autoDrink() end)
    Hook.AutoDrink.Add(onAutoDrink)
    replayingVanillaAutoDrink = false
    if not ok then
        log("Vanilla auto-drink replay failed: " .. tostring(err))
        return
    end

    if not isEnabled() or not getCore():getOptionAutoDrink() then return end
    if stats and beforeThirst and tonumber(stats:get(CharacterStat.THIRST)) < beforeThirst then return end
    if stats and tonumber(stats:get(CharacterStat.THIRST)) <= 0.1 then return end
    if ISTimedActionQueue.hasActionType(character, "ISDrinkFluidAction") then return end

    local item, fluidContainer = getMixedWaterContainer(character)
    if not item or not fluidContainer then return end
    local currentAmount = tonumber(fluidContainer:getAmount()) or 0
    if currentAmount <= 0 then return end
    drinkMixedLiquid(character, item, fluidContainer, currentAmount)
end

-- In multiplayer the Java AutoDrink hook may run on the authoritative server
-- without invoking the client-side hook. Poll the local player as a fallback so
-- a thirsty client can still request the server-authoritative mixed-fluid sip.
local function onPlayerUpdate(character)
    if not (isClient and isClient()) or not character then return end
    local playerNum = character.getPlayerNum and character:getPlayerNum() or nil
    if playerNum == nil or getSpecificPlayer(playerNum) ~= character then return end

    local now = getTimestampMs()
    if lastPlayerUpdateCheck[playerNum]
        and now - lastPlayerUpdateCheck[playerNum] < PLAYER_UPDATE_CHECK_MS then
        return
    end
    lastPlayerUpdateCheck[playerNum] = now

    if not isEnabled() or not getCore():getOptionAutoDrink() then return end
    local stats = character.getStats and character:getStats() or nil
    local thirst = stats and tonumber(stats:get(CharacterStat.THIRST)) or nil
    if not thirst or thirst <= 0.1 then return end
    if ISTimedActionQueue.hasActionType(character, "ISDrinkFluidAction") then return end

    local item, fluidContainer = getMixedWaterContainer(character)
    if not item or not fluidContainer then return end
    local currentAmount = tonumber(fluidContainer:getAmount()) or 0
    if currentAmount <= 0 then return end
    log("MP player-update fallback found an eligible mixed-liquid container.")
    drinkMixedLiquid(character, item, fluidContainer, currentAmount)
end

local function install()
    if installed then return true end
    if Events and Events.OnFillInventoryObjectContextMenu then
        Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
    end
    if Events and Events.OnServerCommand then
        Events.OnServerCommand.Add(onServerCommand)
    end
    if Events and Events.OnPlayerUpdate then
        Events.OnPlayerUpdate.Add(onPlayerUpdate)
    else
        log("OnPlayerUpdate is unavailable; multiplayer fallback was not installed.")
    end
    if Hook and Hook.AutoDrink and type(Hook.AutoDrink.Add) == "function"
        and type(Hook.AutoDrink.Remove) == "function" then
        Hook.AutoDrink.Add(onAutoDrink)
    else
        log("Hook.AutoDrink is not available; mixed-liquid auto-drink is unavailable on this game version.")
    end
    installed = true
    log("Mixed-liquid auto-drink support installed.")
    return true
end

GQSMixedLiquidAutoDrink.install = install
GQSMixedLiquidAutoDrink.setContainerPreference = setContainerPreference

if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end

return GQSMixedLiquidAutoDrink
