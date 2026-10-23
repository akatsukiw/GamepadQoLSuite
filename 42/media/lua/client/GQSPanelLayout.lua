-- Own the inventory layout settings in Gamepad QoL Suite while retaining the
-- base CustomGamepadUI layout as the fallback before this wrapper runs.
local GQS = require("GQSModOptions")

local originalPlaceInventoryScreens = ISPlayerDataObject.placeInventoryScreens
function ISPlayerDataObject:placeInventoryScreens(playerID, totalPlayers, mouse)
    originalPlaceInventoryScreens(self, playerID, totalPlayers, mouse)
    if mouse then return end

    local screenWidth = getPlayerScreenWidth(playerID)
    local screenHeight = getPlayerScreenHeight(playerID)
    local isSplit = (tonumber(totalPlayers) or 1) > 1
    if not isSplit and type(getNumActivePlayers) == "function" then
        local ok, count = pcall(getNumActivePlayers)
        isSplit = ok and (tonumber(count) or 1) > 1
    end

    local width = (isSplit and GQS.splitInvLootWidth or GQS.invLootWidth):getValue() * 0.01
    local invHeight = (isSplit and GQS.splitContainerHeight or GQS.invHeight):getValue() * 0.01
    local lootHeight = isSplit and invHeight or GQS.lootHeight:getValue() * 0.01
    if not isSplit and (screenWidth < 1600 or playerID ~= 0) and width < 0.5 then width = 0.5 end
    local left = getPlayerScreenLeft(playerID)
    local top = getPlayerScreenTop(playerID)
    local position = GQS.invLootPosition:getValue()

    self.x1left, self.y1top = left, top
    self.x1 = left
    self.w1 = screenWidth * width / 2
    self.h1 = screenHeight * invHeight
    self.y1 = screenHeight - self.h1
    if position == 1 then
        self.x2, self.w2 = self.x1 + screenWidth - self.w1, self.w1
        self.h2, self.y2 = screenHeight * lootHeight, screenHeight - screenHeight * lootHeight
    elseif position == 2 then
        self.x2, self.w2 = self.x1 + self.w1, self.w1
        self.h2, self.y2 = screenHeight * lootHeight, screenHeight - screenHeight * lootHeight
    elseif position == 3 then
        self.x1 = left + screenWidth - self.w1 * 2
        self.x2, self.w2 = self.x1 + self.w1, self.w1
        self.h2, self.y2 = screenHeight * lootHeight, screenHeight - screenHeight * lootHeight
    elseif position == 4 then
        self.x1 = left + screenWidth / 2 - self.w1
        self.x2, self.w2 = self.x1 + self.w1, self.w1
        self.h2, self.y2 = screenHeight * lootHeight, screenHeight - screenHeight * lootHeight
    elseif position == 5 then
        self.x1 = left + screenWidth / 2 - self.w1
        self.x2, self.w2 = self.x1 + self.w1, self.w1
        self.h2, self.y2 = screenHeight * lootHeight, 0
        self.y1 = 0
    end
end
