-- Gamepad QoL Suite: melee target outline for split-screen players 2 and up.
--
-- Vanilla only ever highlights player 1's melee target:
--   zombie/CombatManager.java -> update(boolean) reads IsoPlayer.players[0]
--   directly (updateReticle + highlightTargets) and never loops over the other
--   local players. The outline itself is a per-player render state, so a second
--   split-screen player never sees it.
--
-- This module fills that gap on the Lua side, for local players 1..n-1 only:
--   * player 0 keeps the native path untouched (no duplicate work, no override)
--   * the outline is written through setOutlineHighlight(playerNum, ...), which
--     is per local player and purely client-side, so multiplayer peers are never
--     affected and two local players may highlight different targets
--   * the flag is one-shot (IsoMovingObject.renderlast() clears it after every
--     frame), so it is re-applied on every tick, exactly like the native
--     CombatManager.update() does for player 1
--   * the target is cleared as soon as the player stops aiming, switches target,
--     dies, or the vanilla meleeOutline option is turned off
--
-- What this cannot do: the vanilla target selection uses CombatManager's hit
-- list (weapon range, multi-hit, body part). None of that is exposed to Lua, so
-- the target here is an approximation: the nearest living zombie inside a short
-- cone in front of the player.

GQSSplitScreenMeleeOutline = {}
GQSSplitScreenMeleeOutline.VERSION = "1.5.2.2"

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("splitMeleeOutline", message)
    end
end

-- Nearest zombie inside this radius (in tiles) is considered a melee candidate.
local MAX_DISTANCE = 1.8
-- cos(70 degrees): how far off the facing direction a target may sit.
local MIN_FACING = 0.34
-- Below this distance the target counts as point-blank and facing is ignored,
-- matching how melee can hit a zombie sharing the player's tile.
local POINT_BLANK = 0.35
-- Tiles scanned around the player. MAX_DISTANCE is under 2, so 2 is enough.
local SCAN_RADIUS = 2

-- IsoDirections -> unit vector in tile space (y grows southward). Diagonals are
-- normalised so MIN_FACING means the same angle for all eight directions.
local DIAG = 0.7071067811865476
local DIR_VECTORS = {}
do
    local dirs = rawget(_G, "IsoDirections")
    if dirs then
        DIR_VECTORS[dirs.N]  = { 0, -1 }
        DIR_VECTORS[dirs.NE] = { DIAG, -DIAG }
        DIR_VECTORS[dirs.E]  = { 1, 0 }
        DIR_VECTORS[dirs.SE] = { DIAG, DIAG }
        DIR_VECTORS[dirs.S]  = { 0, 1 }
        DIR_VECTORS[dirs.SW] = { -DIAG, DIAG }
        DIR_VECTORS[dirs.W]  = { -1, 0 }
        DIR_VECTORS[dirs.NW] = { -DIAG, -DIAG }
    end
end

-- playerNum -> zombie currently outlined by us.
local targets = {}

local function isRangedWeapon(player)
    local item = player:getPrimaryHandItem()
    if item == nil then return false end
    if not instanceof(item, "HandWeapon") then return false end
    local ok, ranged = pcall(function() return item:isRanged() end)
    return ok and ranged == true
end

local function isLivingZombie(object)
    if not instanceof(object, "IsoZombie") then return false end
    local ok, dead = pcall(function() return object:isDead() end)
    return ok and dead ~= true
end

local function findMeleeTarget(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local facing = DIR_VECTORS[player:getDir()]
    if facing == nil then return nil end
    local fx, fy = facing[1], facing[2]

    local cell = getCell()
    if cell == nil then return nil end

    local baseX, baseY = math.floor(px), math.floor(py)
    local best, bestDistance = nil, MAX_DISTANCE

    for dx = -SCAN_RADIUS, SCAN_RADIUS do
        for dy = -SCAN_RADIUS, SCAN_RADIUS do
            local square = cell:getGridSquare(baseX + dx, baseY + dy, pz)
            if square then
                local moving = square:getMovingObjects()
                local size = moving and moving:size() or 0
                for i = 0, size - 1 do
                    local object = moving:get(i)
                    if isLivingZombie(object) then
                        local zx, zy = object:getX(), object:getY()
                        local vx, vy = zx - px, zy - py
                        local distance = math.sqrt(vx * vx + vy * vy)
                        if distance < bestDistance then
                            local inCone = distance < POINT_BLANK
                            if not inCone then
                                inCone = (vx / distance) * fx + (vy / distance) * fy >= MIN_FACING
                            end
                            if inCone then
                                best, bestDistance = object, distance
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function clearTarget(playerNum)
    local previous = targets[playerNum]
    if previous == nil then return end
    targets[playerNum] = nil
    -- The zombie may already be removed from the world; never let that throw.
    pcall(function() previous:setOutlineHighlight(playerNum, false) end)
    log("cleared melee outline for player " .. tostring(playerNum))
end

local function clearAll()
    for playerNum in pairs(targets) do
        clearTarget(playerNum)
    end
end

local function applyOutline(playerNum, zombie)
    -- Same colour the native path uses for melee targets (getBadHighlitedColor).
    local r, g, b = 1, 0, 0
    local color = getCore():getBadHighlitedColor()
    if color then
        local ok, cr, cg, cb = pcall(function() return color.r, color.g, color.b end)
        if ok and type(cr) == "number" then
            r, g, b = cr, cg, cb
        end
    end
    -- Indexed colour setter: only this player's channel, so player 1 keeps its
    -- own colour (the unindexed overload writes every player's channel).
    pcall(function()
        zombie:setOutlineHighlightCol(playerNum, r, g, b, 1.0)
        zombie:setOutlineHighlight(playerNum, true)
    end)
end

local function updatePlayer(playerNum)
    local player = getSpecificPlayer(playerNum)
    if player == nil then
        clearTarget(playerNum)
        return
    end

    local dead = player:isDead()
    local npc = player:isNpc()
    -- Player 0 is handled by the native CombatManager path; only fill in the rest.
    if dead or npc or not player:isAiming() or isRangedWeapon(player) then
        clearTarget(playerNum)
        return
    end

    local target = findMeleeTarget(player)
    if target == nil then
        clearTarget(playerNum)
        return
    end

    if targets[playerNum] ~= target then
        clearTarget(playerNum)
        targets[playerNum] = target
        log("outlined melee target for player " .. tostring(playerNum))
    end

    -- The outline flag is one-shot: IsoMovingObject.renderlast() sets it back to
    -- false as soon as the frame has been drawn, so it has to be re-applied on
    -- every tick. The native CombatManager.update() does exactly the same for
    -- player 1; setting it only when the target changes makes it flash for a
    -- single frame and then vanish.
    applyOutline(playerNum, target)
end

local function onTick()
    local core = getCore()
    if core == nil then return end
    -- Follow the vanilla option so the two paths always agree.
    if not core:getOptionMeleeOutline() then
        clearAll()
        return
    end

    local count = 1
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok and type(value) == "number" and value > 0 then count = value end
    end

    -- Start at 1: local player 0 keeps the native outline path.
    for playerNum = 1, count - 1 do
        updatePlayer(playerNum)
    end

    -- Drop outlines belonging to players that are no longer in this split screen.
    for playerNum in pairs(targets) do
        if playerNum >= count then clearTarget(playerNum) end
    end
end

if Events and Events.OnTick then Events.OnTick.Add(onTick) end

log("loaded; melee target outline extended to split-screen players 2+; player 1 keeps the native path")
