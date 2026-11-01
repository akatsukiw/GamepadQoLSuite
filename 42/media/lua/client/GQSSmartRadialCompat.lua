-- Gamepad QoL Suite: Smart Radial Menu compatibility (detection only).
--
-- The actual slice injection lives in GQSTileRadialMenuFix's ISDPadWheels
-- onDisplayUp wrapper: when SRM is active it opens the SRM wheel directly and
-- appends our contextual world-object slices to srm.SRMRootMenu. That path does
-- not depend on hooking SRMRadialMenu.showRadialMenu (which the previous version
-- did, but the actual open path never reached it, so nothing was appended).
--
-- This module only records that SRM is active for logging/diagnostics.

local function debugLog(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("srmCompat", message)
    end
end

local function isSRMActive()
    -- The module being loaded is the most reliable signal that SRM is active.
    if rawget(_G, "SRMRadialMenu") ~= nil then return true end
    local modsGetter = rawget(_G, "getActivatedMods")
    if type(modsGetter) == "function" then
        local okList, list = pcall(modsGetter)
        if okList and list and type(list.contains) == "function" then
            local okHas, has = pcall(list.contains, list, "SmartRadialMenu")
            if okHas and has == true then return true end
        end
    end
    return false
end

local installed = false

local function install()
    if installed then return end
    if not isSRMActive() then return end
    installed = true
    debugLog("Smart Radial detected; D-pad Up opens the SRM wheel with GQS actions appended")
end

if Events and Events.OnGameBoot then Events.OnGameBoot.Add(install) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
