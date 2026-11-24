-- Gamepad QoL Suite: auto-share newly drawn world-map markers, with a
-- controller-cyclable sharing type (LS on the map).
-- Vanilla requires opening the sharing panel for every marker. With this
-- option on, a marker (symbol or text note) is set to the selected sharing
-- type as soon as it is created. Holding LS on the map cycles that type:
-- everyone -> faction -> safehouse -> private -> everyone... and the choice is
-- remembered per local player (like the exercise/duration preferences).

require "ISUI/Maps/ISWorldMapSymbols"
require "ISUI/Maps/ISWorldMap"

local GQSMapAutoShare = rawget(_G, "GQSMapAutoShare") or {}
GQSMapAutoShare.VERSION = "1.5.14.18"

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("mapControls", message)
    end
end

local function getOptions()
    return rawget(_G, "GamepadQoLSuiteOptions")
        or rawget(_G, "GQS")
        or rawget(_G, "GQSModOptions")
end

local function autoShareEnabled()
    local options = getOptions()
    if not options then return false end
    local option = options.mapAutoShareEnabled
    if not option then return false end
    if type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        return ok and value == true
    end
    return option.value == true
end

-- ---------------------------------------------------------------------------
-- Sharing types
-- ---------------------------------------------------------------------------
-- Order matches the LS cycle. The setSharing payloads are exactly what vanilla
-- ISWorldMapSharing:applyChanges() writes for each radio choice.
local SHARE_TYPES = {
    { id = "everyone",  labelKey = "UI_GQOS_ShareEveryone" },
    { id = "faction",   labelKey = "UI_GQOS_ShareFaction" },
    { id = "safehouse", labelKey = "UI_GQOS_ShareSafehouse" },
    { id = "private",   labelKey = "UI_GQOS_SharePrivate" },
}
local DEFAULT_SHARE_TYPE = "everyone"

local function typeIndex(shareType)
    for i, entry in ipairs(SHARE_TYPES) do
        if entry.id == shareType then return i end
    end
    return nil
end

local function isValidType(value)
    return type(value) == "string" and typeIndex(value) ~= nil
end

local function sharingPayload(shareType)
    if shareType == "faction" then
        return { everyone = false, faction = true, safehouse = false, players = {} }
    elseif shareType == "safehouse" then
        return { everyone = false, faction = false, safehouse = true, players = {} }
    elseif shareType == "private" then
        return nil
    end
    return { everyone = true }
end

local function safeGetText(key)
    if type(getText) ~= "function" then return nil end
    local ok, value = pcall(getText, key)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function typeLabel(shareType)
    local index = typeIndex(shareType)
    local entry = index and SHARE_TYPES[index] or SHARE_TYPES[1]
    return safeGetText(entry.labelKey) or entry.id
end

-- ---------------------------------------------------------------------------
-- Per-player remembered type (local file, survives multiplayer logins where
-- player ModData is server-owned -- same approach as the fitness preferences).
-- ---------------------------------------------------------------------------
local shareTypeCache = {}

local function shareTypeFileName(playerNum)
    return "GQSMapShareType_" .. tostring(playerNum + 1) .. ".txt"
end

local function readShareType(playerNum)
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, shareTypeFileName(playerNum), false)
    if not ok or reader == nil then return nil end
    local value = nil
    pcall(function()
        local line = reader:readLine()
        if line ~= nil then value = tostring(line) end
        reader:close()
    end)
    if value == nil then return nil end
    value = string.gsub(value, "^%s*(.-)%s*$", "%1")
    if #value > 32 or string.find(value, "[%c]") then return nil end
    return isValidType(value) and value or nil
end

local function writeShareType(playerNum, shareType)
    if type(getFileWriter) ~= "function" then return false end
    local ok, writer = pcall(getFileWriter, shareTypeFileName(playerNum), true, false)
    if not ok or writer == nil then return false end
    return (pcall(function()
        writer:writeln(shareType)
        writer:close()
    end))
end

-- Default type comes from the Mod Options dropdown; the remembered choice wins.
local function defaultShareTypeFromOptions()
    local options = getOptions()
    local option = options and options.mapAutoShareDefaultType
    if not option then return DEFAULT_SHARE_TYPE end
    local value = nil
    if type(option.getValue) == "function" then
        local ok, v = pcall(option.getValue, option)
        if ok then value = v end
    else
        value = option.value
    end
    if value == nil then return DEFAULT_SHARE_TYPE end
    -- Option may store an index or a string id; accept both.
    if type(value) == "number" then
        local entry = SHARE_TYPES[math.floor(value)]
        return entry and entry.id or DEFAULT_SHARE_TYPE
    end
    return isValidType(value) and value or DEFAULT_SHARE_TYPE
end

local function getCurrentShareType(playerNum)
    if playerNum ~= nil then
        local remembered = shareTypeCache[playerNum + 1] or readShareType(playerNum)
        if remembered then
            shareTypeCache[playerNum + 1] = remembered
            return remembered
        end
    end
    return defaultShareTypeFromOptions()
end

-- Advance one step in the cycle and persist for this player.
local function cycleShareType(playerNum)
    if playerNum == nil then return DEFAULT_SHARE_TYPE end
    local current = getCurrentShareType(playerNum)
    local index = typeIndex(current) or 1
    local nextIndex = (index % #SHARE_TYPES) + 1
    local nextType = SHARE_TYPES[nextIndex].id
    if writeShareType(playerNum, nextType) then
        shareTypeCache[playerNum + 1] = nextType
        log("share type cycled to '" .. nextType .. "' for player " .. tostring(playerNum + 1))
    else
        log("could not persist share type for player " .. tostring(playerNum + 1), true)
    end
    return nextType
end

-- ---------------------------------------------------------------------------
-- Auto-share newly created markers
-- ---------------------------------------------------------------------------
local function shareNewSymbols(symbolsAPI, beforeCount, afterCount, shareType)
    if not symbolsAPI or not beforeCount or not afterCount then return 0 end
    if afterCount <= beforeCount then return 0 end

    local shared = 0
    for index = beforeCount, afterCount - 1 do
        local symbolOk, symbol = pcall(function() return symbolsAPI:getSymbolByIndex(index) end)
        if symbolOk and symbol then
            local payload = sharingPayload(shareType)
            local ok, err = pcall(function() symbol:setSharing(payload) end)
            if ok then
                shared = shared + 1
            else
                log("setSharing failed for symbol " .. tostring(index) .. ": " .. tostring(err))
            end
        end
    end
    return shared
end

local function wrapCreator(toolTable, methodName)
    if type(toolTable) ~= "table" then return false end
    local original = toolTable[methodName]
    if type(original) ~= "function" then return false end
    if toolTable["_gqsAutoShare_" .. methodName] then return false end

    local wrapped = function(self, ...)
        if not autoShareEnabled() then
            return original(self, ...)
        end

        local symbolsAPI = self and self.symbolsAPI or nil
        local beforeCount = nil
        if symbolsAPI then
            local ok, count = pcall(function() return symbolsAPI:getSymbolCount() end)
            if ok then beforeCount = count end
        end

        local result = original(self, ...)

        if symbolsAPI and beforeCount then
            local ok, afterCount = pcall(function() return symbolsAPI:getSymbolCount() end)
            if ok then
                local playerNum = self.symbolsUI and self.symbolsUI.playerNum or nil
                local shareType = getCurrentShareType(playerNum)
                local shared = shareNewSymbols(symbolsAPI, beforeCount, afterCount, shareType)
                if shared > 0 then
                    log("auto-shared " .. tostring(shared) .. " new marker(s) as " .. tostring(shareType))
                end
            end
        end
        return result
    end

    toolTable["_gqsAutoShare_" .. methodName .. "Original"] = original
    toolTable["_gqsAutoShare_" .. methodName] = wrapped
    toolTable[methodName] = wrapped
    return true
end

-- ---------------------------------------------------------------------------
-- LS key on the world map + bottom-left prompt
-- ---------------------------------------------------------------------------
local function isLSButton(button)
    local joypad = rawget(_G, "Joypad")
    if not joypad then return false end
    for _, name in ipairs({ "LStickButton", "LeftStickButton", "L3Button", "LStick" }) do
        local ok, value = pcall(function() return joypad[name] end)
        if ok and value ~= nil and button == value then return true end
    end
    return false
end

local function getLSButtonTexture()
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    if not textures then return nil end
    for _, name in ipairs({ "LStick", "LStickButton", "LeftStickButton", "LeftStick", "L3Button", "L3" }) do
        local ok, texture = pcall(function() return textures[name] end)
        if ok and texture ~= nil then return texture end
    end
    return nil
end

local function mapPlayerNum(self)
    if type(self.playerNum) == "number" then return self.playerNum end
    return nil
end

if type(ISWorldMap) == "table" and type(ISWorldMap.onJoypadDown) == "function"
        and not ISWorldMap._gqsShareTypeOnJoypadDownWrapped then
    local originalOnJoypadDown = ISWorldMap.onJoypadDown
    ISWorldMap.onJoypadDown = function(self, button, joypadData, ...)
        if isLSButton(button) and autoShareEnabled() then
            local playerNum = mapPlayerNum(self)
            cycleShareType(playerNum)
            return
        end
        return originalOnJoypadDown(self, button, joypadData, ...)
    end
    ISWorldMap._gqsShareTypeOnJoypadDownOriginal = originalOnJoypadDown
    ISWorldMap._gqsShareTypeOnJoypadDownWrapped = true
end

if type(ISWorldMap) == "table" and type(ISWorldMap.render) == "function"
        and not ISWorldMap._gqsShareTypeRenderWrapped then
    local originalRender = ISWorldMap.render
    ISWorldMap.render = function(self, ...)
        local result = originalRender(self, ...)
        if autoShareEnabled() and self.joyfocus then
            local texture = getLSButtonTexture()
            if texture then
                local promptHeight = tonumber(self.joypadPromptHgt) or 32
                -- Vanilla stacks X at the bottom, then LT, RT above it; the R3
                -- module adds one more row. Put the LS row above all of them.
                local y = self.height - 16 - promptHeight
                    - 8 - promptHeight
                    - 8 - promptHeight
                    - 8 - promptHeight
                    - 8 - promptHeight
                if type(self.renderJoypadPrompt) == "function" then
                    local label = getText("UI_GQOS_SharePrompt") or "Share"
                    local text = label .. ": " .. typeLabel(getCurrentShareType(mapPlayerNum(self)))
                    pcall(self.renderJoypadPrompt, self, texture, text, 16, y)
                end
            end
        end
        return result
    end
    ISWorldMap._gqsShareTypeRenderOriginal = originalRender
    ISWorldMap._gqsShareTypeRenderWrapped = true
end

if type(Events) == "table" and type(Events.OnGameBoot) == "table" then
    Events.OnGameBoot.Add(function()
        local symbolTool = rawget(_G, "ISWorldMapSymbolTool_AddSymbol")
        local noteTool = rawget(_G, "ISWorldMapSymbolTool_AddNote")
        local installedSymbol = wrapCreator(symbolTool, "addSymbol")
        local installedNote = wrapCreator(noteTool, "onNoteAdded")
        log("map auto-share wrappers installed: symbol=" .. tostring(installedSymbol)
            .. " note=" .. tostring(installedNote))
    end)
end

GQSMapAutoShare.SHARE_TYPES = SHARE_TYPES
GQSMapAutoShare.getCurrentShareType = getCurrentShareType
GQSMapAutoShare.cycleShareType = cycleShareType
_G.GQSMapAutoShare = GQSMapAutoShare
return GQSMapAutoShare
