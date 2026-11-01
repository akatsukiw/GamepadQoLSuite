-- Gamepad QoL Suite: Quick Clothing Actions compatibility.
--
-- QuickClothingActions (workshop 3790742081) is an ISRadialMenu wheel opened by
-- a keyboard key (default G). It never calls setJoypadFocus, and its slices use
-- the vanilla ISRadialMenu handlers, which only close on B/X and only confirm on
-- the "hideWhenButtonReleased" button (never set). So on a controller it is dead.
--
-- This module:
--   * opens QCA's wheel from the right D-pad wheel ("Clothing" slice),
--   * assigns joypad focus after every addToUIManager (level 1 and level 2),
--   * maps A to confirm the focused slice, B/X to go back from level 2 to
--     level 1 (and only close at level 1),
--   * relies on GQSRtBFocusReset to close it cleanly via removeFromUIManager.

local function debugLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("qcaCompat", message)
    end
end

local function hasJoypad(playerNum)
    return JoypadState and JoypadState.players and JoypadState.players[playerNum + 1] ~= nil
end

local function isQCAPresent()
    return rawget(_G, "QuickClothingActionRadial") ~= nil
end

local cachedRadial = nil

local function ensureRadial(playerNum)
    local cls = rawget(_G, "QuickClothingActionRadial")
    if type(cls) ~= "table" or type(cls.new) ~= "function" then return nil end
    if cachedRadial then return cachedRadial end
    local ok, radial = pcall(function() return cls:new(0, 0, 100, 200, playerNum) end)
    if ok and radial then cachedRadial = radial end
    return cachedRadial
end

local function open(player)
    if not player then return end
    if not isQCAPresent() then return end
    local playerNum = player:getPlayerNum()
    local radial = ensureRadial(playerNum)
    if not radial then debugLog("QCA radial unavailable"); return end

    -- Toggle off if already open.
    if radial:isReallyVisible() then
        radial:removeFromUIManager()
        return
    end

    -- Don't open while a timed action is running (matches QCA's own guard).
    local queue = ISTimedActionQueue.getTimedActionQueue(player)
    if queue and #queue.queue > 0 then return end

    radial:reinitialize()
    radial:populateItems()
    if #radial.slices == 0 then debugLog("QCA radial has no slices"); return end
    radial:addToUIManager()
end

local function installHooks()
    local cls = rawget(_G, "QuickClothingActionRadial")
    if type(cls) ~= "table" then return false end
    if cls._gqsQCAHooked then return true end

    -- Track the current level: nil = clothing list (level 1), item = actions (level 2).
    local originalPopulate = cls.populateItems
    if type(originalPopulate) == "function" then
        cls.populateItems = function(self, item)
            self._gqsCurrentItem = item
            return originalPopulate(self, item)
        end
    end

    -- Re-assign joypad focus after every (re)display, including level changes.
    local originalAdd = cls.addToUIManager
    if type(originalAdd) == "function" then
        cls.addToUIManager = function(self, ...)
            local result = originalAdd(self, ...)
            if self.playerNum ~= nil and hasJoypad(self.playerNum) then
                local ok, err = pcall(setJoypadFocus, self.playerNum, self)
                if not ok then debugLog("focus failed: " .. tostring(err)) end
            end
            return result
        end
    end

    -- Confirm buttons: A, R3, D-pad Up and D-pad Right (user preference).
    -- B/X goes back one level, or closes at level 1.
    local confirmButtons = {
        [Joypad.AButton] = true,
        [Joypad.RStickButton] = true,
        [Joypad.DPadUp] = true,
        [Joypad.DPadRight] = true,
    }
    local originalDown = cls.onJoypadDown
    cls.onJoypadDown = function(self, button, joypadData)
        if confirmButtons[button] then
            local focusId = self.joyfocus and self.joyfocus.id
            if focusId ~= nil then
                local sliceIndex = self.javaObject:getSliceIndexFromJoypad(focusId)
                local command = self:getSliceCommand(sliceIndex + 1)
                if command and command[1] then
                    command[1](command[2], command[3], command[4], command[5], command[6], command[7])
                end
            end
            return
        end
        if button == Joypad.BButton or button == Joypad.XButton then
            if self._gqsCurrentItem then
                -- Level 2 -> back to the clothing list.
                self:removeFromUIManager()
                self:reinitialize()
                self:populateItems()
                if #self.slices > 0 then self:addToUIManager() end
            else
                self:undisplay()
            end
            return
        end
        if type(originalDown) == "function" then
            return originalDown(self, button, joypadData)
        end
    end

    cls._gqsQCAHooked = true
    debugLog("Quick Clothing Actions joypad hooks installed")
    return true
end

local GQSQuickClothingCompat = {}
GQSQuickClothingCompat.open = open
GQSQuickClothingCompat.isAvailable = isQCAPresent
_G.GQSQuickClothingCompat = GQSQuickClothingCompat

local installed = false
local function install()
    if installed then return true end
    if not isQCAPresent() then return false end
    installed = installHooks()
    return installed
end

-- QCA may load after this file; retry on boot, start and (briefly) every tick.
local retryTicks = 0
local function installOrRetry()
    if install() then return end
    if not Events or not Events.OnTick then return end
    if retryTicks >= 600 then return end
    local function retry()
        retryTicks = retryTicks + 1
        if install() or retryTicks >= 600 then
            Events.OnTick.Remove(retry)
        end
    end
    Events.OnTick.Add(retry)
end

if Events and Events.OnGameBoot then Events.OnGameBoot.Add(installOrRetry) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(installOrRetry) end

return GQSQuickClothingCompat
