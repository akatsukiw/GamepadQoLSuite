-- CustomGamepadUI: combine vanilla container switching schemes 1 and 3.
-- With the in-game setting on mode 3, a tap of LB/RB advances the corresponding
-- container list; LB/RB + Up/Down continues to use the normal mode-3 controls.
-- Strict chord order: L1/R1 must be pressed before the D-pad direction. If the
-- D-pad is already held when the shoulder goes down, reject that input so it
-- cannot trigger vanilla container switching or the combined tap-cycle action.
-- Client-side only. CleanUI and the existing Fix15 cycle patch remain untouched.

local CGUI = require("GQSModOptions")
local pendingTaps = {}

local function debugPrint(...)
    local logger = rawget(_G, "GQSLog")
    if not logger or type(logger.log) ~= "function" then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.log("containerSwitch", table.concat(parts, " "))
end

local function optionEnabled()
    return CGUI.combinedContainerSwitch
        and type(CGUI.combinedContainerSwitch.getValue) == "function"
        and CGUI.combinedContainerSwitch:getValue() == true
end

local function getShoulderSwitchMode()
    if not getCore() then return nil end
    if getCore():getGameMode() == "Tutorial" then return 1 end
    return getCore():getOptionShoulderButtonContainerSwitch()
end

local function isComboModeActive()
    return optionEnabled() and getShoulderSwitchMode() == 3
end

local function getJoypadId(playerIndex)
    local playerObj = getSpecificPlayer(playerIndex)
    if playerObj and type(playerObj.getJoypadBind) == "function" then
        local ok, id = pcall(function() return playerObj:getJoypadBind() end)
        if ok and type(id) == "number" then return id end
    end
    return -1
end

-- Strict shoulder + Up/Down chord order, matching GQSPanelQuickSelect's Y+D-pad logic:
-- L1/R1 must already be down when Up/Down is pressed. If Up/Down is already held
-- when L1/R1 goes down, suppress that shoulder event and do not treat it as a tap-cycle.
local function isVerticalDpadPressed(joypadId)
    if type(joypadId) ~= "number" or joypadId < 0 then return false end

    local buttons = rawget(_G, "JoypadButton")
    local names = { "DPadUp", "DPadDown" }
    if buttons then
        for i = 1, #names do
            local button = buttons[names[i]]
            if button and type(button.isDown) == "function" then
                local ok, down = pcall(button.isDown, button, joypadId)
                if ok and down == true then return true end
            end
        end
    end

    -- Compatibility fallback for builds that expose only the legacy Joypad enum.
    local joypad = rawget(_G, "Joypad")
    if type(isJoypadPressed) == "function" and joypad then
        for i = 1, #names do
            local button = joypad[names[i]]
            if button ~= nil then
                local ok, down = pcall(isJoypadPressed, joypadId, button)
                if ok and down == true then return true end
            end
        end
    end
    return false
end

local function isShoulderDirectionSwitchModeActive()
    local mode = getShoulderSwitchMode()
    -- In the vanilla accessibility modes 2 and 3, L1/R1 + Up/Down switches
    -- inventory containers. Mode 3 may additionally use shoulder taps via our
    -- combined scheme, but strict ordering applies to the chord either way.
    return mode == 2 or mode == 3
end

local function isShoulderPressed(joypadId, isLeft)
    if type(joypadId) ~= "number" or joypadId < 0 then return false end

    -- Build 42.17+: enum-backed controller buttons.
    if JoypadButton then
        local button = isLeft and JoypadButton.LeftBump or JoypadButton.RightBump
        if button and type(button.isDown) == "function" then
            local ok, pressed = pcall(function() return button:isDown(joypadId) end)
            if ok then return pressed == true end
        end
    end

    -- Older Build 42 versions.
    if type(isJoypadPressed) == "function" and Joypad then
        local button = isLeft and Joypad.LBumper or Joypad.RBumper
        if button ~= nil then
            local ok, pressed = pcall(function() return isJoypadPressed(joypadId, button) end)
            if ok then return pressed == true end
        end
    end

    local helper = isLeft and isJoypadLBPressed or isJoypadRBPressed
    if type(helper) == "function" then
        local ok, pressed = pcall(function() return helper(joypadId) end)
        if ok then return pressed == true end
    end
    return false
end

local function queueTap(page, side, dpadWasAlreadyDown)
    if not page or page.player == nil then return end
    local playerIndex = page.player
    local joypadId = getJoypadId(playerIndex)
    if joypadId < 0 then return end

    local playerPending = pendingTaps[playerIndex]
    if not playerPending then
        playerPending = {}
        pendingTaps[playerIndex] = playerPending
    end

    -- Do not reset a pending chord's state if the bumper generates a repeated event.
    if not playerPending[side] then
        playerPending[side] = {
            joypadId = joypadId,
            usedAsModifier = false,
            rejectedByOrder = dpadWasAlreadyDown == true,
        }
    elseif dpadWasAlreadyDown then
        playerPending[side].rejectedByOrder = true
    end
end

local function markHeldBumpersAsModifiers(playerIndex, joypadId)
    local playerPending = pendingTaps[playerIndex]
    if not playerPending then return end

    for side, tap in pairs(playerPending) do
        local currentJoypadId = joypadId
        if type(currentJoypadId) ~= "number" or currentJoypadId < 0 then
            currentJoypadId = tap.joypadId
        end
        if isShoulderPressed(currentJoypadId, side == "left") then
            tap.usedAsModifier = true
        end
    end
end

local function cycleNextForSide(playerIndex, side)
    local page
    if side == "left" then
        page = getPlayerInventory(playerIndex)
    else
        page = getPlayerLoot(playerIndex)
    end
    if page and type(page.selectNextContainer) == "function" then
        local ok, err = pcall(function() page:selectNextContainer() end)
        if ok then
            debugPrint(string.format("[CustomGamepadUI ContainerCombo] Tap %s -> next %s container (player=%s)",
                side == "left" and "LB" or "RB",
                side == "left" and "carried" or "searched",
                tostring(playerIndex)))
        else
            local logger = rawget(_G, "GQSLog"); if logger then logger.error("containerSwitch", "Container switch failed: " .. tostring(err)) end
        end
    end
end

local function processPendingTaps()
    for playerIndex, playerPending in pairs(pendingTaps) do
        for side, tap in pairs(playerPending) do
            if not isComboModeActive() then
                playerPending[side] = nil
            elseif not isShoulderPressed(tap.joypadId, side == "left") then
                -- A tap is processed on release. If Up/Down was pressed while the
                -- shoulder was held, the regular mode-3 handler already switched it.
                playerPending[side] = nil
                if not tap.usedAsModifier and not tap.rejectedByOrder then
                    cycleNextForSide(playerIndex, side)
                elseif tap.rejectedByOrder then
                    debugPrint(string.format("Rejected %s shoulder input: D-pad was already held (player=%s)",
                        side == "left" and "L1/LB" or "R1/RB", tostring(playerIndex)))
                end
            end
        end
        -- Avoid calling the global `next` here. In the game's Kahlua
        -- environment this call resolves to nil and throws every OnTick.
        if playerPending.left == nil and playerPending.right == nil then
            pendingTaps[playerIndex] = nil
        end
    end
end

local function installHooks()
    if not ISInventoryPage then return false end

    if type(ISInventoryPage.onJoypadDown) == "function"
            and not ISInventoryPage._cguiContainerComboDownInstalled then
        local originalDown = ISInventoryPage.onJoypadDown
        ISInventoryPage.onJoypadDown = function(self, button, ...)
            local side = nil
            if button == Joypad.LBumper then
                side = "left"
            elseif button == Joypad.RBumper then
                side = "right"
            end

            if side then
                local joypadId = -1
                if self.player ~= nil then
                    joypadId = getJoypadId(self.player)
                end
                local dpadWasAlreadyDown = isVerticalDpadPressed(joypadId)

                if isComboModeActive() then
                    queueTap(self, side, dpadWasAlreadyDown)
                end

                -- Vanilla mode 2/3 may inspect held Up/Down when the shoulder
                -- goes down. Reject this event if the direction came first; otherwise
                -- Up/Down -> L1/R1 can accidentally trigger the same container
                -- operation as L1/R1 -> Up/Down. This mirrors the strict ordering
                -- test used by GQSPanelQuickSelect for Y + D-pad.
                if dpadWasAlreadyDown and isShoulderDirectionSwitchModeActive() then
                    debugPrint(string.format("Rejected out-of-order %s + D-pad chord: direction was already down (player=%s)",
                        side == "left" and "L1/LB" or "R1/RB", tostring(self.player)))
                    return true
                end
            end

            -- Preserve vanilla/CleanUI behavior for valid chords and ordinary input.
            return originalDown(self, button, ...)
        end
        ISInventoryPage._cguiContainerComboDownInstalled = true
    end

    if type(ISInventoryPage.onJoypadDirUp) == "function"
            and not ISInventoryPage._cguiContainerComboUpInstalled then
        local originalUp = ISInventoryPage.onJoypadDirUp
        ISInventoryPage.onJoypadDirUp = function(self, joypadData)
            if isComboModeActive() then
                markHeldBumpersAsModifiers(self.player, joypadData and joypadData.id)
            end
            return originalUp(self, joypadData)
        end
        ISInventoryPage._cguiContainerComboUpInstalled = true
    end

    if type(ISInventoryPage.onJoypadDirDown) == "function"
            and not ISInventoryPage._cguiContainerDownInstalled then
        local originalDirDown = ISInventoryPage.onJoypadDirDown
        ISInventoryPage.onJoypadDirDown = function(self, joypadData)
            if isComboModeActive() then
                markHeldBumpersAsModifiers(self.player, joypadData and joypadData.id)
            end
            return originalDirDown(self, joypadData)
        end
        ISInventoryPage._cguiContainerDownInstalled = true
    end

    return true
end

if Events and Events.OnTick then
    Events.OnTick.Add(processPendingTaps)
end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(installHooks)
end
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(installHooks)
end
