-- Gamepad QoL Suite: furniture rotation fix.
--
-- Vanilla has three independent problems that all make a gamepad player press
-- the rotate button, see the preview turn, then watch the object snap back to
-- its original facing once the action runs. They are listed in the order the
-- confirm path hits them.
--
-- 1) FALLBACK FACINGS
--    ISMoveableSpriteProps:getIndexedFaces() always returns four entries and
--    fills missing facings with the object's own facing:
--        d[1] = faces.N or faces.S or ownFace
--        d[2] = faces.W or faces.E or ownFace
--        d[3] = faces.S or faces.N or ownFace
--        d[4] = faces.E or faces.W or ownFace
--    The cursor cycles a raw 1..4 index over those entries, so furniture that
--    only ships N/S sprites stops on index 2 and 4 - both resolving back to its
--    own sprite. The preview appears not to turn at all.
--
-- 2) POINTER ROTATION DURING CONFIRM
--    ISBuildingObject.lua DoTileBuilding() calls rotateMouse(x, y) every frame
--    while the place button is held. rotateMouse derives the facing from the
--    pointer position relative to the cursor centre (south = 3, north = 1,
--    west = 2, east = 4). A gamepad player never moves the pointer, so the
--    parked pointer rewrites the direction right before the action is created.
--
-- 3) DUPLICATE CREATE
--    One press of the confirm button runs ISMoveableCursor:create() twice. The
--    first call is correct, but vanilla clears cursorFacing/joypadFacing at the
--    end of create(), and ISMoveablesAction:perform() calls clearCache() which
--    resets objectIndex to -1 in rotate mode. The second call therefore
--    re-derives the facing from the object's own sprite and rotates it back.
--    cursorFacing and objectIndex are both fields vanilla clears at will, so the
--    chosen facing is remembered in our own _gqs* fields and re-applied.
--
-- Fixes: skip fallback facings, ignore pointer rotation while the gamepad is
-- driving, and re-apply the chosen facing on duplicate confirm calls. Mannequins
-- (canRotateDirection) keep their vanilla path untouched.
--
-- Client-side only; no vanilla file is modified.

local GQSFurnitureRotateFix = {}
local installed = false

-- Same order as ISMoveableSpriteProps:getIndexedFaces().
local FACE_ORDER = { "N", "W", "S", "E" }
-- N <-> S, W <-> E.
local OPPOSITE_AXIS = { [1] = 3, [2] = 4, [3] = 1, [4] = 2 }
-- How long after a gamepad rotation pointer input is still considered stale.
local JOYPAD_ROTATE_GRACE_MS = 4000

local function debugPrint(...)
    local logger = rawget(_G, "GQSLog")
    if not logger or type(logger.log) ~= "function" then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.log("furnitureRotate", table.concat(parts, " "))
end

local function safeCall(object, methodName, ...)
    if not object or type(object[methodName]) ~= "function" then return nil end
    local ok, a, b = pcall(object[methodName], object, ...)
    if not ok then return nil end
    return a, b
end

local function nowMs()
    local fn = rawget(_G, "getTimestampMs")
    if type(fn) == "function" then
        local ok, value = pcall(fn)
        if ok and type(value) == "number" then return value end
    end
    return nil
end

local function playRotateSound()
    local manager = getSoundManager and getSoundManager()
    if manager and type(manager.playUISound) == "function" then
        pcall(manager.playUISound, manager, "UIObjectMenuObjectRotateOutline")
    end
end

local function currentMode(self)
    return ISMoveableCursor.mode and ISMoveableCursor.mode[self.player]
end

-- Builds a 1..4 map of facings that own a real sprite, plus how many there are.
-- Returns nil when the props cannot be inspected, so callers stay on the
-- vanilla path.
local function getRealFaceMap(moveProps)
    if not moveProps then return nil end
    if safeCall(moveProps, "hasFaces") ~= true then return nil end
    local faces = safeCall(moveProps, "getFaces")
    if type(faces) ~= "table" then return nil end

    local real = {}
    local count = 0
    for index = 1, 4 do
        if faces[FACE_ORDER[index]] ~= nil then
            real[index] = true
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return real, count
end

-- Next facing after `current` that owns a real sprite. Returns nil when there is
-- nothing else to rotate to, which keeps single-facing props on the vanilla path.
local function nextRealIndex(real, current, count)
    if not real or not count or count < 2 then return nil end
    local start = tonumber(current) or 0
    if start < 1 or start > 4 then start = 0 end

    for step = 1, 4 do
        local candidate = ((start + step - 1) % 4) + 1
        if real[candidate] and candidate ~= start then
            return candidate
        end
    end
    return nil
end

-- For pointer input: keep the requested direction when it exists, otherwise use
-- the opposite direction on the same axis.
local function resolveSameAxis(real, desired)
    local index = tonumber(desired)
    if not real or not index or index < 1 or index > 4 then return nil end
    if real[index] then return index end
    local opposite = OPPOSITE_AXIS[index]
    if opposite and real[opposite] then return opposite end
    return nil
end

-- Picks the facing index the cursor should be showing right now, defaulting to
-- the object's own facing when the cursor has not been rotated yet.
local function currentFacingIndex(self, moveProps)
    local index = tonumber(self.cursorFacing)
    if index and index >= 1 and index <= 4 then return index end

    index = tonumber(self.joypadFacing)
    if index and index >= 1 and index <= 4 then return index end

    local faceIndex = safeCall(moveProps, "getFaceIndex")
    if type(faceIndex) == "number" and faceIndex >= 1 and faceIndex <= 4 then
        return faceIndex
    end
    return nil
end

local function applyCursorFacing(self, target)
    if not target then return false end
    if type(self.setCursorFacing) == "function" then
        self:setCursorFacing(target)
    else
        self.cursorFacing = target
    end
    return true
end

-- Timestamp of the last gamepad-driven rotation.
local joypadRotateAt = 0

-- True when the last input came from the gamepad rather than the pointer.
local function isJoypadDriving()
    local now = nowMs()
    if now and joypadRotateAt > 0 and (now - joypadRotateAt) < JOYPAD_ROTATE_GRACE_MS then
        return true
    end
    local checker = rawget(_G, "wasMouseActiveMoreRecentlyThanJoypad")
    if type(checker) ~= "function" then return false end
    local ok, mouseActive = pcall(checker)
    if not ok then return false end
    return mouseActive ~= true
end

-- The object the current rotation targets, used to invalidate a remembered
-- facing when the player moves to a different piece of furniture.
local function currentTargetObject(self, mode)
    local cache = self.objectListCache
    if type(cache) ~= "table" then return nil end
    if mode == "rotate" then
        return cache.object
    end
    local entry = cache[self.objectIndex]
    return entry and entry.object or nil
end

-- Advances the cursor to the next facing that owns a real sprite and remembers
-- it. Returns true when handled, false to let the vanilla code run.
local function advanceFacing(self, moveProps)
    if safeCall(moveProps, "canRotateDirection") == true then return false end

    local real, count = getRealFaceMap(moveProps)
    if not real then return false end

    local target = nextRealIndex(real, currentFacingIndex(self, moveProps), count)
    if not target then return false end

    if not applyCursorFacing(self, target) then return false end

    local mode = currentMode(self)
    -- Keep objectIndex in step while it still holds a facing index. Vanilla
    -- resets it to -1 in clearCache(), so this only covers the window between
    -- rotating and the first create(); _gqsFacing below covers the rest.
    if mode == "rotate" then
        self.objectIndex = target
    end
    -- Remember the pick outside of cursorFacing/objectIndex: vanilla clears both
    -- (create() at the end, clearCache() when the action completes), and the
    -- confirm button runs create() twice.
    self._gqsFacing = target
    self._gqsFacingObj = currentTargetObject(self, mode)
    self._gqsPendingRestore = false

    local now = nowMs()
    if now then joypadRotateAt = now end
    return true
end

-- Diagnostics only: what vanilla would derive from the sprite name.
local function reverseFacing(moveProps)
    if not moveProps then return nil end
    local sprite = moveProps.sprite
    if not sprite or type(sprite.getName) ~= "function" then return nil end
    return safeCall(moveProps, "getFaceDirectionFromSpriteName", sprite:getName())
end

-- Defensive: vanilla derives the target facing by reverse-looking it up from the
-- sprite name, which needs the sprite to carry a "Facing" tile property. Modded
-- furniture sometimes lacks it, the lookup returns nil, and the action silently
-- keeps the original facing. Prefer the facing index the player is looking at.
-- Not triggered by vanilla furniture (their sprites carry the property).
local function installActionDirectionFix()
    if not ISMoveablesAction or type(ISMoveablesAction.new) ~= "function" then return false end
    if not ISMoveableSpriteProps or type(ISMoveableSpriteProps.new) ~= "function" then return false end
    if ISMoveablesAction._gqsDirectionFix then return true end

    local originalNew = ISMoveablesAction.new
    ISMoveablesAction.new = function(self, character, square, mode, origSpriteName, object, direction, item, moveCursor)
        if moveCursor and (mode == "place" or mode == "rotate") then
            local index = tonumber(moveCursor.cursorFacing) or tonumber(moveCursor.joypadFacing)
            if index and index >= 1 and index <= 4 then
                local props = nil
                if mode == "rotate" then
                    if object and type(object.getSprite) == "function" then
                        local ok, sprite = pcall(object.getSprite, object)
                        if ok and sprite then
                            props = ISMoveableSpriteProps.new(sprite)
                        end
                    end
                else
                    props = moveCursor.origMoveProps
                end

                local real = getRealFaceMap(props)
                if real and real[index] then
                    if direction ~= FACE_ORDER[index] then
                        debugPrint("direction", tostring(direction), "->", FACE_ORDER[index])
                    end
                    direction = FACE_ORDER[index]
                end
            end
        end
        return originalNew(self, character, square, mode, origSpriteName, object, direction, item, moveCursor)
    end

    ISMoveablesAction._gqsDirectionFix = true
    return true
end

local function installHooks()
    if installed then return true end
    if not ISMoveableCursor then return false end
    if ISMoveableCursor._gqsFurnitureRotateFix then
        -- Cursor hooks are in place; the action fix can still be pending if
        -- ISMoveablesAction was not loaded yet.
        installActionDirectionFix()
        installed = true
        return true
    end

    -- Gamepad X while placing an item.
    local originalRotateWhilePlacing = ISMoveableCursor.rotateWhilePlacing
    if type(originalRotateWhilePlacing) == "function" then
        ISMoveableCursor.rotateWhilePlacing = function(self)
            if self and self.objectListCache then
                local entry = self.objectListCache[self.objectIndex]
                local moveProps = entry and entry.moveProps
                if advanceFacing(self, moveProps) then
                    debugPrint("place rotate ->", FACE_ORDER[self.cursorFacing])
                    return
                end
            end
            return originalRotateWhilePlacing(self)
        end
    end

    -- Gamepad RB in rotate mode.
    local originalRotateKey = ISMoveableCursor.rotateKey
    if type(originalRotateKey) == "function" then
        ISMoveableCursor.rotateKey = function(self, key, joypadTriggered)
            if joypadTriggered and self and currentMode(self) == "rotate" then
                local rotateObject = self.objectListCache
                if not rotateObject and type(self.getRotateableObject) == "function" then
                    local ok, value = pcall(self.getRotateableObject, self)
                    if ok then rotateObject = value end
                end
                local moveProps = type(rotateObject) == "table" and rotateObject.moveProps or nil
                if advanceFacing(self, moveProps) then
                    playRotateSound()
                    debugPrint("rotate mode ->", FACE_ORDER[self.cursorFacing])
                    return
                end
            end
            return originalRotateKey(self, key, joypadTriggered)
        end
    end

    -- Problem 2: pointer rotation while the place button is held. Ignore it
    -- entirely while the gamepad is driving; keep the same-axis snap for real
    -- pointer users.
    local originalRotateMouse = ISMoveableCursor.rotateMouse
    if type(originalRotateMouse) == "function" then
        ISMoveableCursor.rotateMouse = function(self, x, y)
            if not self then return end

            if isJoypadDriving() then
                if self.cursorFacing ~= nil then
                    debugPrint("mouse rotate ignored (joypad active), keeping",
                        FACE_ORDER[tonumber(self.cursorFacing)] or tostring(self.cursorFacing))
                end
                return
            end

            originalRotateMouse(self, x, y)
            local real = getRealFaceMap(self.origMoveProps or self.currentMoveProps)
            if not real then return end
            local desired = tonumber(self.cursorFacing)
            if not desired or real[desired] then return end
            local target = resolveSameAxis(real, desired)
            if target then
                self.cursorFacing = target
                debugPrint("mouse snap", FACE_ORDER[desired], "->", FACE_ORDER[target])
            end
        end
    end

    -- Problem 3: the confirm button runs create() twice. Re-apply the remembered
    -- facing on the follow-up call, and snap a fallback facing onto a real one.
    local originalCreate = ISMoveableCursor.create
    if type(originalCreate) == "function" then
        ISMoveableCursor.create = function(self, x, y, z, north, sprite)
            if self then
                local mode = currentMode(self)

                if (mode == "rotate" or mode == "place")
                    and self._gqsPendingRestore and self._gqsFacing
                    and not self.cursorFacing then
                    local target = self._gqsFacing
                    local current = currentTargetObject(self, mode)
                    if current == nil or current == self._gqsFacingObj then
                        self.cursorFacing = target
                        -- objectIndex is a facing index only in rotate mode.
                        if mode == "rotate" then
                            self.objectIndex = target
                        end
                        debugPrint("restored facing", FACE_ORDER[target])
                    end
                end

                local real = getRealFaceMap(self.origMoveProps)
                local desired = tonumber(self.cursorFacing)
                if real and desired and not real[desired] then
                    local target = resolveSameAxis(real, desired)
                    if target then
                        self.cursorFacing = target
                        debugPrint("confirm snap", FACE_ORDER[desired], "->", FACE_ORDER[target])
                    end
                end

                debugPrint("confirm cursor=", tostring(self.cursorFacing),
                    "objIdx=", tostring(self.objectIndex),
                    "facing=", tostring(self.currentMoveProps and self.currentMoveProps.facing),
                    "reverse=", tostring(reverseFacing(self.currentMoveProps)))
            end

            local result = originalCreate(self, x, y, z, north, sprite)

            -- Arm the restore for the duplicate create() that follows.
            if self and self._gqsFacing and currentMode(self) then
                self._gqsPendingRestore = true
            end
            return result
        end
    end

    installActionDirectionFix()

    ISMoveableCursor._gqsFurnitureRotateFix = true
    installed = true
    debugPrint("installed")
    return true
end

GQSFurnitureRotateFix.install = installHooks

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(installHooks)
end
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(installHooks)
end

installHooks()
