-- Gamepad QoL Suite: native-button hints for shortcuts available during world focus.
-- This module only renders hints. It does not change any input handling or action.

pcall(require, "ISUI/ISButtonPrompt")

local ISButtonPromptClass = rawget(_G, "ISButtonPrompt")
if type(ISButtonPromptClass) ~= "table" or type(ISButtonPromptClass.prerender) ~= "function"
        or ISButtonPromptClass._gqsWorldFocusShortcutHintsInstalled then
    return
end

local GQSWorldFocusShortcutHints = rawget(_G, "GQSWorldFocusShortcutHints") or {}
GQSWorldFocusShortcutHints.VERSION = "1.5.1.31"

local ACTION_BY_INDEX = {
    [1] = "none",
    [2] = "zoomIn",
    [3] = "zoomOut",
    [4] = "moodlePrevious",
    [5] = "moodleNext",
}

local DEFAULT_OPTION_INDEX = {
    rbDpadUpAction = 2,
    rbDpadDownAction = 3,
    rbDpadLeftAction = 3,
    rbDpadRightAction = 2,
    rbButtonYAction = 2,
    rbButtonAAction = 3,
}

local DIRECTION_CONTROLS = {
    { option = "rbDpadLeftAction", textures = { "DPadLeft", "DpadLeft", "LeftArrow" }, fallback = "←" },
    { option = "rbDpadRightAction", textures = { "DPadRight", "DpadRight", "RightArrow" }, fallback = "→" },
    { option = "rbDpadUpAction", textures = { "DPadUp", "DpadUp", "UpArrow" }, fallback = "↑" },
    { option = "rbDpadDownAction", textures = { "DPadDown", "DpadDown", "DownArrow" }, fallback = "↓" },
}

local originalPrerender = ISButtonPromptClass.prerender

local function safeIndex(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

local function safeCall(object, methodName)
    if object == nil then return nil end
    local method = safeIndex(object, methodName)
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(function() return method(object) end)
    if ok then return value end
    return nil
end

local function getOptions()
    local options = rawget(_G, "GamepadQoLSuiteOptions") or rawget(_G, "GQS")
    if options then return options end
    local ok, module = pcall(require, "GQSModOptions")
    if ok and type(module) == "table" then return module end
    return nil
end

local function readOptionValue(optionKey)
    local options = getOptions()
    local option = options and safeIndex(options, optionKey) or nil
    if option == nil then return nil end
    local getter = safeIndex(option, "getValue")
    if type(getter) == "function" then
        local ok, value = pcall(getter, option)
        if ok and value ~= nil then return value end
    end
    return safeIndex(option, "value")
end

local function isEnabled(optionKey, defaultValue)
    local value = readOptionValue(optionKey)
    if value == nil then return defaultValue end
    return value == true or value == 1 or value == "true"
end

local function getActionIndex(optionKey)
    local value = tonumber(readOptionValue(optionKey))
    if value and ACTION_BY_INDEX[value] then return value end
    return DEFAULT_OPTION_INDEX[optionKey]
end

local function getConfiguredDirectionAction(optionKey)
    local directionByOption = {
        rbDpadUpAction = "Up",
        rbDpadDownAction = "Down",
        rbDpadLeftAction = "Left",
        rbDpadRightAction = "Right",
    }
    local direction = directionByOption[optionKey]
    if not direction then return "none" end

    -- Prefer the exact resolver used by GQSRBZoom's input handling.
    local shared = rawget(_G, "GQS_RBControls")
    local resolver = shared and safeIndex(shared, "getAction")
    if type(resolver) == "function" then
        local ok, action = pcall(resolver, direction)
        if ok and type(action) == "string" then return action end
    end

    -- Defensive fallback while module initialization is still in progress.
    local index = getActionIndex(optionKey)
    if direction == "Up" or direction == "Down" then
        local map = { [1] = "none", [2] = "moodlePrevious", [3] = "moodleNext", [4] = "moodlePrevious", [5] = "moodleNext" }
        return map[index] or "none"
    end
    local map = { [1] = "none", [2] = "zoomIn", [3] = "zoomOut" }
    if index == 4 or index == 5 then
        return direction == "Left" and "zoomOut" or "zoomIn"
    end
    return map[index] or "none"
end

-- Joypad.Texture may return a JoypadIconTextureGetter proxy for an unknown
-- key as well. The six keys below are directly confirmed by vanilla
-- ISButtonPrompt:new(); other candidate keys are accepted only when the native
-- getter reports a real texture file path.
local VANILLA_PROMPT_TEXTURE_NAMES = {
    AButton = true,
    BButton = true,
    XButton = true,
    YButton = true,
    LBumper = true,
    RBumper = true,
}

local function hasResolvedTextureFile(texture)
    local getter = safeIndex(texture, "getTextureFilePath")
    if type(getter) ~= "function" then return false end
    local ok, path = pcall(getter, texture)
    return ok and type(path) == "string" and path ~= ""
end

local function getJoypadTexture(names)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and safeIndex(joypad, "Texture")
    if not textures then return nil end
    for _, name in ipairs(names or {}) do
        local texture = safeIndex(textures, name)
        if texture ~= nil then
            if VANILLA_PROMPT_TEXTURE_NAMES[name] or hasResolvedTextureFile(texture) then
                return texture, name
            end
        end
    end
    return nil
end

local function getFocus(playerNum)
    if type(getFocusForPlayer) == "function" then
        local ok, focus = pcall(getFocusForPlayer, playerNum)
        if ok then return focus end
    end
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok then return focus end
    end
    local players = rawget(_G, "JoypadState")
    local data = players and players.players and players.players[playerNum + 1]
    return data and data.focus or nil
end

local function getRows()
    local rows = {}
    -- Zoom shortcuts are shown contextually on the selected Select-wheel zoom
    -- item now. Do not keep a duplicate always-visible RB+D-pad zoom row here.
    if isEnabled("rtBFocusEnabled", true) then
        rows[#rows + 1] = {
            chord = "RTB",
            labelKey = "UI_GQS_WorldHint_RTB",
            fallback = "退关面板",
            slotOffset = 0,
        }
    end
    return rows
end

local function getConfiguredMoodleControls(actionName)
    local controls = {}
    if not isEnabled("rbExtensionsEnabled", true) then return controls end
    for _, control in ipairs(DIRECTION_CONTROLS) do
        local action = getConfiguredDirectionAction(control.option)
        if action == actionName then
            controls[#controls + 1] = control
        end
    end
    return controls
end

local function getDisplayText(key, fallback)
    if type(getText) == "function" then
        local ok, result = pcall(getText, key)
        if ok and result ~= nil and result ~= "" and result ~= key then
            return tostring(result)
        end
    end
    return fallback
end

-- Do not call getWidthOrig()/getHeightOrig() on JoypadIconTextureGetter.
-- In Build 42.21 these methods can throw when the getter's resolved texture is
-- null, and the exception is logged every render frame. Vanilla ISButtonPrompt
-- draws these same glyph objects directly with drawTexture(), so mirror that
-- path and use the standard 32px controller-prompt slot without querying size.
local ICON_SLOT_SIZE = 32

-- Vanilla ISButtonPrompt draws every prompt row on a fixed 32px grid (rowHgt)
-- and centres each element inside that row by its own height:
--   icon: y1 + (rowHgt - buttonHgt) / 2
--   text: y1 + (rowHgt - fontHgt)   / 2
-- Vanilla button glyphs are 32px tall, so the icon offset is 0. The text offset
-- depends on the active font's line height (CN UIFont.NewLarge = 26 -> +3px),
-- which is measured at render time and passed in as fontLineHeight.
-- An earlier revision derived a row height of "font line height + 6" and centred
-- both the glyph and the label inside that taller box, which pushed the label
-- off the vanilla baseline. Keep the row fixed at 32 and centre by each height.
local ROW_HEIGHT = 32
local DEFAULT_FONT_LINE_HEIGHT = 26

local function drawIconToken(self, texture, x, y)
    if texture == nil then return nil end
    local draw = safeIndex(self, "drawTexture")
    if type(draw) ~= "function" then return nil end

    local drawY = y + math.floor((ROW_HEIGHT - ICON_SLOT_SIZE) / 2)
    local ok = pcall(draw, self, texture, x, drawY, 0.9, 1, 1, 1)
    if ok then return ICON_SLOT_SIZE end
    return nil
end

local function measureText(font, value)
    if type(getTextManager) == "function" then
        local ok, manager = pcall(getTextManager)
        if ok and manager then
            local measure = safeIndex(manager, "MeasureStringX")
            if type(measure) == "function" then
                local success, width = pcall(measure, manager, font, value)
                if success and type(width) == "number" then return width end
            end
        end
    end
    return #tostring(value) * 9
end

local function drawTextToken(self, text, x, y, font, fontLineHeight)
    local drawText = safeIndex(self, "drawText")
    if type(drawText) == "function" then
        -- Same formula as vanilla ISButtonPrompt: centre the label by the font's
        -- own line height inside the fixed 32px row.
        local textY = y + math.floor((ROW_HEIGHT - (fontLineHeight or DEFAULT_FONT_LINE_HEIGHT)) / 2)
        pcall(drawText, self, text, x, textY, 1, 1, 1, 0.9, font)
    end
    return measureText(font, text)
end

local function drawControlList(self, controls, x, y, font, fontLineHeight)
    local cursorX = x
    for index, control in ipairs(controls or {}) do
        if index > 1 then
            cursorX = cursorX + 3
            cursorX = cursorX + drawTextToken(self, "/", cursorX, y, font, fontLineHeight) + 3
        end
        local texture = getJoypadTexture(control.textures)
        local iconWidth = texture and drawIconToken(self, texture, cursorX, y) or nil
        if iconWidth then
            cursorX = cursorX + iconWidth + 3
        else
            cursorX = cursorX + drawTextToken(self, control.fallback or "?", cursorX, y, font, fontLineHeight) + 3
        end
    end
    return cursorX
end

local function drawRow(self, row, x, y, font, fontLineHeight)
    local cursorX = x
    if row.chord == "RB" then
        local rbTexture = getJoypadTexture({ "RBumper", "RBButton" })
        local iconWidth = rbTexture and drawIconToken(self, rbTexture, cursorX, y) or nil
        if iconWidth then
            cursorX = cursorX + iconWidth + 3
        else
            cursorX = cursorX + drawTextToken(self, "RB", cursorX, y, font, fontLineHeight) + 3
        end
        cursorX = cursorX + drawTextToken(self, "+", cursorX, y, font, fontLineHeight) + 3
        cursorX = drawControlList(self, row.controls, cursorX, y, font, fontLineHeight)
    elseif row.chord == "RTB" then
        local rtTexture = getJoypadTexture({ "RTrigger", "RTButton", "RightTrigger", "RightTriggerButton", "RT", "R2Button" })
        local bTexture = getJoypadTexture({ "BButton" })
        local rtWidth = rtTexture and drawIconToken(self, rtTexture, cursorX, y) or nil
        if rtWidth then
            cursorX = cursorX + rtWidth + 3
        else
            cursorX = cursorX + drawTextToken(self, "RT", cursorX, y, font, fontLineHeight) + 3
        end
        cursorX = cursorX + drawTextToken(self, "+", cursorX, y, font, fontLineHeight) + 3
        local bWidth = bTexture and drawIconToken(self, bTexture, cursorX, y) or nil
        if bWidth then
            cursorX = cursorX + bWidth + 5
        else
            cursorX = cursorX + drawTextToken(self, "B", cursorX, y, font, fontLineHeight) + 5
        end
    end
    local label = getDisplayText(row.labelKey, row.fallback)
    drawTextToken(self, label, cursorX, y, font, fontLineHeight)
end

local canDrawForPlayer

-- Moodle cue uses native-size controller glyphs. The two D-pad directions are
-- composed into one compact cluster below the Moodle stack instead of being
-- pinned above/below it all the time.
local MOODLE_HINT_ICON_SIZE = 32
local MOODLE_HINT_COMBINED_VERTICAL_WIDTH = 32
local MOODLE_HINT_GAP = 5
local MOODLE_HINT_MOODLE_GAP = 12
-- Move the shortcut cue left of the Moodle stack center. The final position is
-- clamped to each player's own viewport so split-screen prompts stay on-screen.
local MOODLE_HINT_OFFSET_X = 16
local MOODLE_HINT_VIEWPORT_MARGIN_X = 8
local combinedVerticalDirectionTexture = nil

local function getCombinedVerticalDirectionTexture()
    if combinedVerticalDirectionTexture ~= nil then
        return combinedVerticalDirectionTexture
    end
    if type(getTexture) ~= "function" then return nil end
    local ok, texture = pcall(getTexture, "media/ui/icon_gqs_dpad_up_down.png")
    if ok and texture ~= nil then
        combinedVerticalDirectionTexture = texture
        return texture
    end
    return nil
end
-- Use the game's millisecond clock so the cue duration is independent of FPS.
-- getTimestampMs() is available in the target game; fall back to os.time in
-- environments where it is unavailable (coarser, but still time-based).
local MOODLE_HINT_DURATION_MS = 5000
local moodleHintUntilMs = {}
local knownMoodleLevels = {}
local moodleHintInitialized = {}
local pollMoodleHintsTick = 0
local MOODLE_HINT_POLL_INTERVAL = 6

local function getNowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        value = ok and tonumber(value) or nil
        if value then return value end
    end
    if os and type(os.time) == "function" then
        local ok, value = pcall(os.time)
        value = ok and tonumber(value) or nil
        if value then return value * 1000 end
    end
    -- Extremely defensive fallback. It is used only if neither clock exists.
    return 0
end

local function drawScaledTexture(self, texture, x, y, width, height)
    if texture == nil then return false end
    local drawScaled = safeIndex(self, "drawTextureScaled")
    if type(drawScaled) ~= "function" then return false end
    local ok = pcall(drawScaled, self, texture, x, y, width, height, 0.94, 1, 1, 1)
    return ok
end

local function drawSmallText(self, value, x, y, font)
    local drawText = safeIndex(self, "drawText")
    if type(drawText) ~= "function" then return end
    pcall(drawText, self, value, x, y, 1, 1, 1, 0.95, font)
end

local function getControlDirection(control)
    if not control or not control.option then return nil end
    for _, value in ipairs(DIRECTION_CONTROLS) do
        if value.option == control.option then
            if value.option == "rbDpadUpAction" then return "Up" end
            if value.option == "rbDpadDownAction" then return "Down" end
            if value.option == "rbDpadLeftAction" then return "Left" end
            if value.option == "rbDpadRightAction" then return "Right" end
        end
    end
    return nil
end

local function combineMoodleControls()
    local previous = getConfiguredMoodleControls("moodlePrevious")
    local nextControls = getConfiguredMoodleControls("moodleNext")
    local combined, seen = {}, {}
    for _, collection in ipairs({ previous, nextControls }) do
        for _, control in ipairs(collection) do
            if not seen[control.option] then
                seen[control.option] = true
                combined[#combined + 1] = control
            end
        end
    end
    return combined
end

local function getPairedDirections(controls)
    if type(controls) ~= "table" or #controls ~= 2 then return nil end
    local a, b = getControlDirection(controls[1]), getControlDirection(controls[2])
    if not a or not b then return nil end
    if (a == "Up" and b == "Down") or (a == "Down" and b == "Up") then
        return "vertical"
    end
    if (a == "Left" and b == "Right") or (a == "Right" and b == "Left") then
        return "horizontal"
    end
    return nil
end

local function getPromptGeometry(controls)
    local pair = getPairedDirections(controls)
    if pair == "vertical" then
        -- The user-supplied Up/Down halves are already merged into one square
        -- 32x32 glyph. Treat it as one icon, not a 64px-tall two-icon stack.
        return MOODLE_HINT_ICON_SIZE + MOODLE_HINT_GAP + 9 + MOODLE_HINT_GAP + MOODLE_HINT_COMBINED_VERTICAL_WIDTH,
            MOODLE_HINT_ICON_SIZE, pair
    elseif pair == "horizontal" then
        return MOODLE_HINT_ICON_SIZE + MOODLE_HINT_GAP + 9 + MOODLE_HINT_GAP + MOODLE_HINT_ICON_SIZE * 2,
            MOODLE_HINT_ICON_SIZE, pair
    end
    local width = MOODLE_HINT_ICON_SIZE + MOODLE_HINT_GAP + 9 + MOODLE_HINT_GAP
    for i=1,#controls do
        width = width + MOODLE_HINT_ICON_SIZE
        if i < #controls then width = width + MOODLE_HINT_GAP + 8 + MOODLE_HINT_GAP end
    end
    return width, MOODLE_HINT_ICON_SIZE, nil
end

local function drawMoodleShortcutCue(self, controls, anchor)
    if type(controls) ~= "table" or #controls == 0 or type(anchor) ~= "table" then return end
    local rbTexture = getJoypadTexture({ "RBumper" })
    if not rbTexture then return end

    local width, height, pair = getPromptGeometry(controls)
    local centerX = anchor.x + anchor.w / 2
    local absX = math.floor(centerX - width / 2 - MOODLE_HINT_OFFSET_X)
    -- Keep the hint within the active player's viewport. This also avoids
    -- clipping at the right edge in single-player and split-screen layouts.
    local areaLeft = tonumber(anchor.areaLeft) or 0
    local areaWidth = tonumber(anchor.areaWidth) or tonumber(anchor.screenW) or 1920
    local minX = areaLeft + MOODLE_HINT_VIEWPORT_MARGIN_X
    local maxX = areaLeft + areaWidth - width - MOODLE_HINT_VIEWPORT_MARGIN_X
    if maxX < minX then maxX = minX end
    absX = math.max(minX, math.min(maxX, absX))
    local gap = MOODLE_HINT_MOODLE_GAP
    local absY = math.floor(anchor.y + anchor.h + gap)
    local areaTop = tonumber(anchor.areaTop) or 0
    local areaHeight = tonumber(anchor.areaHeight) or (tonumber(anchor.screenH) or 1080)
    absY = math.min(absY, areaTop + areaHeight - height - 4)

    -- Prompt widgets can be nested in per-player viewports. Convert absolute HUD
    -- anchors back to this ISButtonPrompt's local coordinate space.
    local promptX = tonumber(safeCall(self, "getAbsoluteX")) or tonumber(self.x) or 0
    local promptY = tonumber(safeCall(self, "getAbsoluteY")) or tonumber(self.y) or 0
    local x = absX - promptX
    local y = absY - promptY
    local rowHeight = height
    local rbY = y + math.floor((rowHeight - MOODLE_HINT_ICON_SIZE) / 2)
    drawScaledTexture(self, rbTexture, x, rbY, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE)
    x = x + MOODLE_HINT_ICON_SIZE + MOODLE_HINT_GAP
    local font = rawget(_G, "UIFont") and (UIFont.Small or UIFont.Medium) or nil
    drawSmallText(self, "+", x, y + math.floor((rowHeight - 16) / 2), font)
    x = x + 9 + MOODLE_HINT_GAP

    if pair == "vertical" then
        -- Draw one pre-composed up/down glyph image instead of two independent
        -- native icon widgets. This keeps the directional meaning visually
        -- unified while retaining the native RB glyph beside it.
        local combinedTexture = getCombinedVerticalDirectionTexture()
        if combinedTexture then
            drawScaledTexture(self, combinedTexture, x, y, MOODLE_HINT_COMBINED_VERTICAL_WIDTH,
                MOODLE_HINT_ICON_SIZE)
        else
            -- Safe visual fallback if the mod texture could not be loaded.
            local upTexture = getJoypadTexture({ "DPadUp", "DpadUp", "UpArrow" })
            local downTexture = getJoypadTexture({ "DPadDown", "DpadDown", "DownArrow" })
            if upTexture then drawScaledTexture(self, upTexture, x, y, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE) end
            if downTexture then drawScaledTexture(self, downTexture, x, y + MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE) end
            if not upTexture then drawSmallText(self, "↑", x + 7, y + 2, font) end
            if not downTexture then drawSmallText(self, "↓", x + 7, y + MOODLE_HINT_ICON_SIZE + 2, font) end
        end
    elseif pair == "horizontal" then
        local leftTexture = getJoypadTexture({ "DPadLeft", "DpadLeft", "LeftArrow" })
        local rightTexture = getJoypadTexture({ "DPadRight", "DpadRight", "RightArrow" })
        if leftTexture then drawScaledTexture(self, leftTexture, x, y, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE) end
        if rightTexture then drawScaledTexture(self, rightTexture, x + MOODLE_HINT_ICON_SIZE, y, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE) end
        if not leftTexture then drawSmallText(self, "←", x + 7, y + 2, font) end
        if not rightTexture then drawSmallText(self, "→", x + MOODLE_HINT_ICON_SIZE + 7, y + 2, font) end
    else
        for index, control in ipairs(controls) do
            if index > 1 then
                drawSmallText(self, "/", x, y + math.floor((height - 16) / 2), font)
                x = x + 8 + MOODLE_HINT_GAP
            end
            local texture = getJoypadTexture(control.textures)
            if texture then
                drawScaledTexture(self, texture, x, y, MOODLE_HINT_ICON_SIZE, MOODLE_HINT_ICON_SIZE)
            else
                drawSmallText(self, control.fallback or "?", x + 7, y + 2, font)
            end
            x = x + MOODLE_HINT_ICON_SIZE + MOODLE_HINT_GAP
        end
    end
end

local function copyLevels(levels)
    local result = {}
    if type(levels) == "table" then
        for key, value in pairs(levels) do result[tostring(key)] = tonumber(value) or 0 end
    end
    return result
end

local function isHintPlayerEligible(playerIndex)
    if not isEnabled("rbExtensionsEnabled", true) or #combineMoodleControls() == 0 then return false end
    if getFocus(playerIndex) ~= nil then return false end
    local players = rawget(_G, "JoypadState")
    local data = players and players.players and players.players[playerIndex + 1]
    if not data or not data.player or type(data.id) ~= "number" or data.id < 0 then return false end
    if type(isJoypadConnected) == "function" then
        local ok, connected = pcall(isJoypadConnected, data.id)
        if ok and connected == false then return false end
    end
    return true
end

local function pollMoodleCueState()
    pollMoodleHintsTick = pollMoodleHintsTick + 1
    if pollMoodleHintsTick < MOODLE_HINT_POLL_INTERVAL then return end
    pollMoodleHintsTick = 0

    local moodles = rawget(_G, "GQSRBZoomMoodles")
    local getAnchors = moodles and safeIndex(moodles, "getShortcutHintAnchors")
    if type(getAnchors) ~= "function" then return end

    for playerIndex = 0, 3 do
        if isHintPlayerEligible(playerIndex) then
            local ok, anchors = pcall(getAnchors, playerIndex)
            if ok and type(anchors) == "table" and type(anchors.levels) == "table" then
                local previous = knownMoodleLevels[playerIndex]
                local rose = false
                if previous then
                    for key, level in pairs(anchors.levels) do
                        local oldLevel = previous[key]
                        if oldLevel == nil or tonumber(level or 0) > tonumber(oldLevel or 0) then
                            rose = true
                            break
                        end
                    end
                elseif not moodleHintInitialized[playerIndex] and (tonumber(anchors.count) or 0) > 0 then
                    -- On the first world-focus snapshot after a save loads, active
                    -- moodles have just appeared on-screen. Flash once instead of
                    -- silently treating the whole visible stack as a baseline.
                    rose = true
                end
                moodleHintInitialized[playerIndex] = true
                if rose then
                    moodleHintUntilMs[playerIndex] = getNowMs() + MOODLE_HINT_DURATION_MS
                end
                knownMoodleLevels[playerIndex] = copyLevels(anchors.levels)
            else
                knownMoodleLevels[playerIndex] = nil
            end
        else
            -- Re-baseline on returning to world focus. Opening an inventory or
            -- menu should not trigger a stale Moodle cue when it closes.
            -- Hide the cue while a menu has focus but retain the last known
            -- levels. This lets genuine Moodle changes across a brief UI focus
            -- transition be detected without replaying the initial flash each time.
            moodleHintUntilMs[playerIndex] = nil
        end
    end
end

local function drawMoodleEdgeHints(self)
    if not canDrawForPlayer(self) then return end
    local expiresAt = moodleHintUntilMs[self.player]
    if expiresAt == nil or getNowMs() > expiresAt then return end
    local controls = combineMoodleControls()
    if #controls == 0 then return end

    local moodles = rawget(_G, "GQSRBZoomMoodles")
    local getAnchors = moodles and safeIndex(moodles, "getShortcutHintAnchors")
    if type(getAnchors) ~= "function" then return end
    local ok, anchors = pcall(getAnchors, self.player)
    if not ok or type(anchors) ~= "table" or (tonumber(anchors.count) or 0) <= 0 then return end
    if anchors.bottom then drawMoodleShortcutCue(self, controls, anchors.bottom) end
end

canDrawForPlayer = function(self)
    if self == nil or type(self.player) ~= "number" or self.player < 0 then return false end
    if getFocus(self.player) ~= nil then return false end

    local players = rawget(_G, "JoypadState")
    local joypadData = players and players.players and players.players[self.player + 1]
    if not joypadData or not joypadData.player or type(joypadData.id) ~= "number" or joypadData.id < 0 then
        return false
    end
    if type(isJoypadConnected) == "function" then
        local ok, connected = pcall(isJoypadConnected, joypadData.id)
        if ok and connected == false then return false end
    end
    return type(self.x1) == "number" and type(self.y1) == "number"
end

ISButtonPromptClass.prerender = function(self, ...)
    local result = originalPrerender(self, ...)

    if canDrawForPlayer(self) then
        local rows = getRows()
        if #rows > 0 then
            local font = rawget(_G, "UIFont") and (UIFont.NewLarge or UIFont.Medium or UIFont.Small) or nil
            local fontLineHeight = DEFAULT_FONT_LINE_HEIGHT
            local textManager = type(getTextManager) == "function" and getTextManager() or nil
            if textManager and font then
                local fontObject = safeIndex(textManager, "getFontFromEnum")
                if type(fontObject) == "function" then
                    local ok, fontInfo = pcall(fontObject, textManager, font)
                    if ok and fontInfo then
                        local getLineHeight = safeIndex(fontInfo, "getLineHeight")
                        if type(getLineHeight) == "function" then
                            local okHeight, value = pcall(getLineHeight, fontInfo)
                            if okHeight and type(value) == "number" and value > 0 then
                                -- Centre the label by the real font line height, exactly
                                -- like vanilla ISButtonPrompt does inside its 32px row.
                                fontLineHeight = value
                            end
                        end
                    end
                end
            end

            local x = (tonumber(self.x1) or 0) + (tonumber(self.lmargin) or 16) + 16
            -- Vanilla row occupancy above the Y row: the LB prompt sits at y1-32
            -- (slot 1) and the movable/drag icon sits at y1-64 (slot 2). Take the
            -- lowest free slot so the hint hugs the vanilla prompts instead of
            -- reserving an empty LB row and leaving a visible gap above Y.
            local firstSlotFromBottom = 1
            if self.lbPrompt ~= nil then firstSlotFromBottom = 2 end
            local cell = type(getCell) == "function" and getCell() or nil
            local drag = cell and type(cell.getDrag) == "function" and cell:getDrag(self.player) or nil
            if drag and firstSlotFromBottom >= 2 then firstSlotFromBottom = 3 end

            for _, row in ipairs(rows) do
                local slot = firstSlotFromBottom + (row.slotOffset or 0)
                local y = self.y1 - slot * ROW_HEIGHT
                drawRow(self, row, x, y, font, fontLineHeight)
            end
        end
        -- Moodle controls are intentionally rendered at the native Moodle HUD
        -- stack edges instead of being crowded into the left-bottom text list.
        drawMoodleEdgeHints(self)
    end

    return result
end

if Events and Events.OnTick then
    Events.OnTick.Add(pollMoodleCueState)
end
if Events and Events.OnResetLua then
    Events.OnResetLua.Add(function()
        pollMoodleHintsTick = 0
        moodleHintUntilMs = {}
        knownMoodleLevels = {}
        moodleHintInitialized = {}
    end)
end

ISButtonPromptClass._gqsWorldFocusShortcutHintsInstalled = true
ISButtonPromptClass._gqsWorldFocusShortcutHintsOriginal = originalPrerender
_G.GQSWorldFocusShortcutHints = GQSWorldFocusShortcutHints
return GQSWorldFocusShortcutHints
