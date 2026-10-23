-- Server-authoritative instant drinking for safe, water-majority mixtures.
-- Clients send only an item id; all eligibility and amount checks run here.

local NETWORK_MODULE = "GQS_MixedLiquidAutoDrink"
local ITEM_SETTING_KEY = "GQSMixedLiquidAutoDrink"
local WATER_RATIO_THRESHOLD = 0.5
local MAX_SIP_AMOUNT = 0.12
local REQUEST_COOLDOWN_MS = 750
local lastDrinkAt = {}

local function reply(player, requestId, accepted, reason)
    if not player or not sendServerCommand then return end
    sendServerCommand(player, NETWORK_MODULE, "mixedDrinkResult", {
        requestId = requestId,
        accepted = accepted == true,
        reason = reason,
    })
end

local function getSafeMixture(item)
    if not item or not item.getFluidContainer then return nil end
    local fluidContainer = item:getFluidContainer()
    if not fluidContainer or fluidContainer:isEmpty() or not fluidContainer:isMixture() then return nil end
    if not Fluid or not Fluid.Water or type(fluidContainer.getRatioForFluid) ~= "function" then return nil end
    if fluidContainer:getRatioForFluid(Fluid.Water) <= WATER_RATIO_THRESHOLD then return nil end
    if fluidContainer.isTainted and fluidContainer:isTainted() then return nil end
    if fluidContainer.isPoisonous and fluidContainer:isPoisonous() then return nil end
    local data = item:getModData()
    if data and data[ITEM_SETTING_KEY] == false then return nil end
    return fluidContainer
end

local function onClientCommand(module, command, player, args)
    if module ~= NETWORK_MODULE or command ~= "drinkMixedLiquid" then return end
    if not player or not args then return end

    local requestId = tonumber(args.requestId)
    if not requestId then return end
    print("[GQS Mixed Auto Drink] Received client request " .. tostring(requestId) .. ".")

    local inventory = player:getInventory()
    local itemId = tonumber(args.itemId)
    local item = inventory and itemId and inventory:getItemById(itemId) or nil
    if not item or not inventory:containsID(item:getID()) then
        reply(player, requestId, false, "item-not-in-inventory")
        return
    end

    local fluidContainer = getSafeMixture(item)
    if not fluidContainer then
        reply(player, requestId, false, "container-not-eligible")
        return
    end

    local stats = player:getStats()
    local thirst = stats and tonumber(stats:get(CharacterStat.THIRST)) or nil
    if not thirst or thirst <= 0.1 then
        reply(player, requestId, false, "not-thirsty")
        return
    end
    local now = getTimestampMs and getTimestampMs() or os.time() * 1000
    local playerKey = tostring(player:getOnlineID())
    local previous = lastDrinkAt[playerKey] or 0
    if now - previous < REQUEST_COOLDOWN_MS then
        reply(player, requestId, false, "cooldown")
        return
    end

    local currentAmount = tonumber(fluidContainer:getAmount()) or 0
    if currentAmount <= 0 then
        reply(player, requestId, false, "container-empty")
        return
    end

    lastDrinkAt[playerKey] = now
    local sipAmount = math.min(MAX_SIP_AMOUNT, currentAmount)
    local ok, err = pcall(function()
        player:DrinkFluid(item, sipAmount / currentAmount, false)
        item:syncItemFields()
    end)
    if not ok then
        reply(player, requestId, false, "drink-call-failed")
        print("[GQS Mixed Auto Drink][ERROR] Server DrinkFluid failed: " .. tostring(err))
        return
    end

    reply(player, requestId, true, nil)
end

if isServer and isServer() and Events and Events.OnClientCommand then
    Events.OnClientCommand.Add(onClientCommand)
    print("[GQS Mixed Auto Drink] Server request handler installed.")
end
