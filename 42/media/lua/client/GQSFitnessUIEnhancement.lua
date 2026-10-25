-- Gamepad QoL Suite: Fitness panel convenience improvements (v1.5.3).
-- Wraps vanilla ISFitnessUI methods only; does not replace the vanilla confirmation path.
-- Enabled by the "Fitness Panel Enhancements" Mod Options checkbox.
--
-- v1.5.3: the preselected exercise is no longer a fixed list -- the player's own
-- last confirmed choice is remembered and restored (see "Remembered exercise
-- selection" below).

pcall(require, "ISUI/ISPanelJoypad")
pcall(require, "ISUI/ISButton")
pcall(require, "ISUI/ISFitnessUI")

local FitnessUI = rawget(_G, "ISFitnessUI")
if not FitnessUI or FitnessUI._gqsFitnessEnhancementInstalled then
    return
end

local function fitnessLog(message, isError)
    local logger = rawget(_G, "GQSLog")
    if logger then
        if isError and type(logger.error) == "function" then
            logger.error("fitnessUI", message)
        elseif type(logger.log) == "function" then
            logger.log("fitnessUI", message)
        end
    end
end

local function isEnhancementEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.fitnessUIEnhancementEnabled
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok and value ~= nil then
            return value == true
        end
    end
    -- If Mod Options isn't ready in this load order, retain the previous enabled behavior.
    return true
end

local function safeGetText(key)
    if type(getText) ~= "function" then return nil end
    local ok, value = pcall(getText, key)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function containsLiteral(text, needle)
    return type(text) == "string" and type(needle) == "string" and needle ~= ""
        and string.find(string.lower(text), string.lower(needle), 1, true) ~= nil
end

-- Exercise ids come from FitnessExercises.exercisesType. Vanilla ships squats,
-- pushups, situp, burpees, barbellcurl, dumbbellpress and bicepscurl; other mods
-- may add more. Matching on the id is exact and survives translation changes,
-- the translated name is only a fallback for a build that renamed the ids.
local function findOptionIndex(list, exerciseId, textKey)
    if type(list.options) ~= "table" then return nil end

    if type(exerciseId) == "string" and exerciseId ~= "" then
        for index, option in ipairs(list.options) do
            if option.data == exerciseId then return index end
        end
    end

    local displayName = textKey and safeGetText(textKey) or nil
    if displayName then
        for index, option in ipairs(list.options) do
            if containsLiteral(option.text, displayName) then return index end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Remembered exercise selection
-- ---------------------------------------------------------------------------
-- Vanilla preselects whatever the list happens to build first (the options come
-- out of a pairs() loop, so the order is not even stable), and this module used
-- to force a fixed priority list. Players repeat the same exercise most of the
-- time, so the last confirmed choice is stored per local player and restored the
-- next time the panel opens.
--
-- A file is used instead of player ModData on purpose: in multiplayer the server
-- owns the player's ModData and overwrites a client-side write on the next
-- login, while Zomboid/Lua/ is plain local storage that always survives.
local preferenceCache = {}

local function preferenceFileName(playerNum)
    return "GQSFitnessLastExercise_" .. tostring(playerNum + 1) .. ".txt"
end

local function readExercisePreference(playerNum)
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, preferenceFileName(playerNum), false)
    if not ok or reader == nil then return nil end

    local value = nil
    pcall(function()
        local line = reader:readLine()
        if line ~= nil then value = tostring(line) end
        reader:close()
    end)
    if value == nil then return nil end

    value = string.gsub(value, "^%s*(.-)%s*$", "%1")
    if value == "" or #value > 64 or string.find(value, "[%c]") then return nil end
    return value
end

local function writeExercisePreference(playerNum, exerciseId)
    if type(getFileWriter) ~= "function" then return false end
    local ok, writer = pcall(getFileWriter, preferenceFileName(playerNum), true, false)
    if not ok or writer == nil then return false end
    return (pcall(function()
        writer:writeln(exerciseId)
        writer:close()
    end))
end

local function getLocalPlayerNum(self)
    if type(self.playerNum) == "number" then return self.playerNum end
    local player = self.player
    if player and type(player.getPlayerNum) == "function" then
        local ok, num = pcall(player.getPlayerNum, player)
        if ok and type(num) == "number" then return num end
    end
    return nil
end

-- Called from the clickedExe wrapper, i.e. only for a choice the player actually
-- confirmed (mouse click or joypad A on the radio list).
local function rememberExercise(self)
    if not isEnhancementEnabled() then return end
    local playerNum = getLocalPlayerNum(self)
    if playerNum == nil then return end

    local exerciseId = self.selectedExe
    if type(exerciseId) ~= "string" or exerciseId == "" then return end
    if preferenceCache[playerNum + 1] == exerciseId then return end

    -- Only cache after a successful write, otherwise a failed write would
    -- suppress every retry for the rest of the session.
    if writeExercisePreference(playerNum, exerciseId) then
        preferenceCache[playerNum + 1] = exerciseId
        fitnessLog("remembered exercise '" .. exerciseId .. "' for player " .. tostring(playerNum + 1))
    else
        fitnessLog("could not persist exercise '" .. exerciseId .. "' for player " .. tostring(playerNum + 1), true)
    end
end

local function applyExerciseSelection(self, index, exerciseId)
    local list = self.exercises
    if type(list.setSelected) == "function" then
        pcall(list.setSelected, list, index)
    else
        list.selected = index
    end
    -- Move the joypad cursor as well, otherwise a controller user has to walk
    -- the cursor down to the restored option before pressing A.
    list.joypadIndex = index
    self.selectedExe = exerciseId
    if type(self.selectedNewExercise) == "function" then
        pcall(self.selectedNewExercise, self)
    end
end

local function selectPreferredExercise(self)
    local list = self.exercises
    if not list or type(list.options) ~= "table" then return false end

    -- 1. The player's own last confirmed choice wins, as long as the exercise is
    --    still listed and still usable. option.enabled is computed by the vanilla
    --    list-building code, so it already includes the equipment check.
    local playerNum = getLocalPlayerNum(self)
    if playerNum ~= nil then
        local remembered = readExercisePreference(playerNum)
        if remembered then
            local index = findOptionIndex(list, remembered, nil)
            if index and list.options[index].enabled ~= false then
                applyExerciseSelection(self, index, remembered)
                preferenceCache[playerNum + 1] = remembered
                fitnessLog("restored remembered exercise '" .. remembered .. "'")
                return true
            end
            fitnessLog("remembered exercise '" .. remembered
                .. "' is unavailable right now; using the default priority list.")
        end
    end

    -- 2. First run, or the remembered exercise needs equipment the player is not
    --    carrying: keep the original priority list.
    local priorities = {
        { id = "barbellcurl", key = "IGUI_BarbellCurl" },
        { id = "dumbbellpress", key = "IGUI_DumbbellPress" },
        { id = "pushups", key = "IGUI_PushUps" },
    }

    for _, wanted in ipairs(priorities) do
        local index = findOptionIndex(list, wanted.id, wanted.key)
        if index and list.options[index].enabled ~= false then
            local exerciseId = list.options[index].data
            if exerciseId == nil then return false end
            applyExerciseSelection(self, index, exerciseId)
            return true
        end
    end
    return false
end

-- Duration pre-filled into the vanilla time field. Read on every panel open so a
-- change in Mod Options applies without reloading.
local function getDefaultDuration()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.fitnessDefaultDuration
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok and tonumber(value) then
            return tostring(math.floor(tonumber(value)))
        end
    end
    return "30"
end

local function setDefaultDuration(self)
    if self.exeTime and type(self.exeTime.setText) == "function" then
        pcall(self.exeTime.setText, self.exeTime, getDefaultDuration())
    end
end

local function getButtonHeight(button)
    if not button then return nil end
    if type(button.getHeight) == "function" then
        local ok, height = pcall(button.getHeight, button)
        if ok and type(height) == "number" then return height end
    end
    return button.height
end

-- Keep the vanilla button X positions, widths, titles, A/B/Y assignments and navigation order.
-- Only align their Y position to the panel's *current* height. Vanilla can resize the panel
-- after initialise(), so this is also reapplied after update and before prerender.
local function layoutFooter(self)
    if type(self.getHeight) ~= "function" then return end
    local okHeight, panelHeight = pcall(self.getHeight, self)
    if not okHeight or type(panelHeight) ~= "number" then return end

    local buttons = { self.ok, self.cancel, self.close }
    for _, button in ipairs(buttons) do
        if button and type(button.setY) == "function" then
            local height = getButtonHeight(button) or 24
            local targetY = math.max(0, math.floor(panelHeight - height - 11))
            if type(button.getY) == "function" then
                local okY, currentY = pcall(button.getY, button)
                if not okY or currentY ~= targetY then
                    pcall(button.setY, button, targetY)
                end
            else
                pcall(button.setY, button, targetY)
            end
        end
    end
end

-- Draw a separate X hint immediately before the native Y-close prompt. Do not bind X to self.ok:
-- doing so replaces the native A hint and breaks the original selected-button + A confirmation.
local function drawXPrompt(self)
    if not isEnhancementEnabled() or not self.joyfocus then return end

    local closeButton = self.close
    if type(closeButton) ~= "table" or type(closeButton.getX) ~= "function"
        or type(closeButton.getY) ~= "function" or type(closeButton.getWidth) ~= "function"
        or type(closeButton.getHeight) ~= "function" then
        return
    end

    local joypad = rawget(_G, "Joypad")
    local texture = joypad and joypad.Texture and joypad.Texture.XButton
    if not texture then return end

    local title = safeGetText("UI_GQOS_FitnessStart") or "Start Workout"
    local font = (closeButton.font and closeButton.font) or (UIFont and UIFont.Small)
    if not font or not getTextManager then return end

    local textWidth, textHeight
    local okMeasure, measuredWidth, measuredHeight = pcall(function()
        local manager = getTextManager()
        return manager:MeasureStringX(font, title), manager:MeasureStringY(font, title)
    end)
    if not okMeasure then return end
    textWidth, textHeight = measuredWidth, measuredHeight
    if type(textWidth) ~= "number" or type(textHeight) ~= "number" then return end

    local iconSize = closeButton.joypadTextureWH
    if type(iconSize) ~= "number" or iconSize <= 0 then iconSize = 32 end
    local gap = 12
    local blockWidth = iconSize + 5 + textWidth
    local closeTitle = type(closeButton.title) == "string" and closeButton.title or ""
    local closeTextWidth = 0
    pcall(function() closeTextWidth = getTextManager():MeasureStringX(font, closeTitle) end)
    local closeWidth = closeButton:getWidth()
    local closeIconOffset = math.max(5, (closeWidth - closeTextWidth) / 2 - 5 - iconSize)
    local closePromptLeft = closeButton:getX() + closeIconOffset

    local iconX = math.max(8, closePromptLeft - gap - blockWidth)
    local iconY = closeButton:getY() + (closeButton:getHeight() - iconSize) / 2
    local textX = iconX + iconSize + 5
    local textY = closeButton:getY() + (closeButton:getHeight() - textHeight) / 2 + (closeButton.yoffset or 0)

    if type(self.drawTextureScaled) == "function" then
        pcall(self.drawTextureScaled, self, texture, iconX, iconY, iconSize, iconSize, 1, 1, 1, 1)
    end
    if type(self.drawText) == "function" then
        pcall(self.drawText, self, title, textX, textY, 1, 1, 1, 1, font)
    end
end

local originalInitialise = FitnessUI.initialise
if type(originalInitialise) == "function" then
    FitnessUI.initialise = function(self, ...)
        local result = originalInitialise(self, ...)
        if isEnhancementEnabled() then
            local ok, err = pcall(function()
                selectPreferredExercise(self)
                setDefaultDuration(self)
                layoutFooter(self)
            end)
            if not ok then
                fitnessLog("Initialization enhancement failed: " .. tostring(err), true)
            else
                fitnessLog("Fitness panel initialized; preferred exercise/time/footer enhancement applied.")
            end
        end
        return result
    end
end

local originalUpdate = FitnessUI.update
if type(originalUpdate) == "function" then
    FitnessUI.update = function(self, ...)
        local result = originalUpdate(self, ...)
        if isEnhancementEnabled() then
            pcall(layoutFooter, self)
        end
        return result
    end
end

local originalPrerender = FitnessUI.prerender
if type(originalPrerender) == "function" then
    FitnessUI.prerender = function(self, ...)
        if isEnhancementEnabled() then
            pcall(layoutFooter, self)
        end
        return originalPrerender(self, ...)
    end
end

local originalRender = FitnessUI.render
if type(originalRender) == "function" then
    FitnessUI.render = function(self, ...)
        local result = originalRender(self, ...)
        if isEnhancementEnabled() then
            pcall(drawXPrompt, self)
        end
        return result
    end
end

local originalJoypadDown = FitnessUI.onJoypadDown
local function isXButton(button)
    local joypad = rawget(_G, "Joypad")
    if joypad and joypad.XButton ~= nil and button == joypad.XButton then return true end
    local buttonEnums = rawget(_G, "JoypadButton")
    if buttonEnums and buttonEnums.X ~= nil and button == buttonEnums.X then return true end
    local ok, text = pcall(tostring, button)
    return ok and (text == "X" or text == "JoypadButton.X" or text == "zombie.input.JoypadButton.X")
end

local function uiStillVisible(self)
    if type(self.getIsVisible) == "function" then
        local ok, visible = pcall(self.getIsVisible, self)
        if ok then return visible == true end
    end
    if type(self.isVisible) == "function" then
        local ok, visible = pcall(self.isVisible, self)
        if ok then return visible == true end
    end
    return true
end

local function closeFitnessPanel(self)
    -- Prefer the vanilla close button so its own focus restoration is respected.
    local closeButton = self.close
    if type(closeButton) == "table" and closeButton.enable ~= false
        and type(closeButton.forceClick) == "function" then
        local closeOK, closeErr = pcall(closeButton.forceClick, closeButton)
        if not closeOK then
            fitnessLog("Native close button failed: " .. tostring(closeErr), true)
        end
        if not uiStillVisible(self) then
            fitnessLog("Fitness panel closed through the native close button.")
            return
        end
    end

    -- Safe fallback for game builds/mods where the native close button callback did not hide it.
    if type(self.removeFromUIManager) == "function" then
        local removeOK, removeErr = pcall(self.removeFromUIManager, self)
        if not removeOK then fitnessLog("Fallback removeFromUIManager failed: " .. tostring(removeErr), true) end
    end
    if type(self.setVisible) == "function" then
        local visibleOK, visibleErr = pcall(self.setVisible, self, false)
        if not visibleOK then fitnessLog("Fallback setVisible(false) failed: " .. tostring(visibleErr), true) end
    end
    local playerNum = self.playerNum
    if playerNum == nil and self.player and type(self.player.getPlayerNum) == "function" then
        pcall(function() playerNum = self.player:getPlayerNum() end)
    end
    if playerNum ~= nil then
        local instances = FitnessUI.instance
        if type(instances) == "table" then
            instances[playerNum + 1] = nil
        end
        if type(setJoypadFocus) == "function" then
            local focusOK, focusErr = pcall(setJoypadFocus, playerNum, nil)
            if not focusOK then fitnessLog("Clearing joypad focus failed: " .. tostring(focusErr), true) end
        end
    end
    fitnessLog("Fitness panel hidden and removed from UIManager using fallback close.")
end

-- addGetUpAndThen() may enqueue a wrapper action rather than placing the
-- ISFitnessAction itself at the top level. Compare queue identities instead of
-- requiring the newly added entry to be an ISFitnessAction tied directly to UI.
local function snapshotTimedActionQueue(self)
    if not self.player or not ISTimedActionQueue
        or type(ISTimedActionQueue.getTimedActionQueue) ~= "function" then
        return nil
    end
    local ok, actionQueue = pcall(ISTimedActionQueue.getTimedActionQueue, self.player)
    local queue = ok and actionQueue and actionQueue.queue or nil
    if type(queue) ~= "table" then return nil end
    local seen = {}
    for _, action in ipairs(queue) do
        if action ~= nil then seen[action] = true end
    end
    return seen
end

local function hasNewTimedAction(self, previousActions)
    if type(previousActions) ~= "table" or not self.player or not ISTimedActionQueue
        or type(ISTimedActionQueue.getTimedActionQueue) ~= "function" then
        return false
    end
    local ok, actionQueue = pcall(ISTimedActionQueue.getTimedActionQueue, self.player)
    local queue = ok and actionQueue and actionQueue.queue or nil
    if type(queue) ~= "table" then return false end
    for _, action in ipairs(queue) do
        if action ~= nil and not previousActions[action] then return true end
    end
    return false
end

if type(originalJoypadDown) == "function" then
    FitnessUI.onJoypadDown = function(self, button, joypadData, ...)
        if isXButton(button) and isEnhancementEnabled() then
            -- Refresh vanilla restrictions before allowing the original OK callback to run.
            if self.player and type(self.updateButtons) == "function" then
                local currentAction = nil
                if ISTimedActionQueue and type(ISTimedActionQueue.getTimedActionQueue) == "function" then
                    local okQueue, actionQueue = pcall(ISTimedActionQueue.getTimedActionQueue, self.player)
                    if okQueue and actionQueue and type(actionQueue.queue) == "table" then
                        currentAction = actionQueue.queue[1]
                    end
                end
                pcall(self.updateButtons, self, currentAction)
            end

            if self.ok and self.ok.enable and type(self.ok.forceClick) == "function" then
                -- Preserve the vanilla OK callback, then check whether it changed the
                -- timed-action queue. addGetUpAndThen() can enqueue a wrapper action,
                -- so checking only for a top-level ISFitnessAction misses valid starts.
                local previousActions = snapshotTimedActionQueue(self)
                fitnessLog("X pressed: invoking vanilla OK callback; okEnabled=" .. tostring(self.ok.enable)
                    .. ", queueSnapshotAvailable=" .. tostring(previousActions ~= nil))
                local clickOK, clickErr = pcall(self.ok.forceClick, self.ok)
                if not clickOK then
                    fitnessLog("X workout callback failed: " .. tostring(clickErr), true)
                elseif hasNewTimedAction(self, previousActions) then
                    fitnessLog("X workout accepted; new timed action was queued. Closing fitness panel.")
                    if uiStillVisible(self) then closeFitnessPanel(self) end
                else
                    fitnessLog("No new timed action detected after X; keeping panel open. This may indicate a vanilla restriction or queue wrapper difference.")
                end
            else
                fitnessLog("X pressed but the vanilla OK button is unavailable or disabled; panel left open.")
            end
            return
        end
        if type(originalJoypadDown) == "function" then
            return originalJoypadDown(self, button, joypadData, ...)
        end
    end
end

-- Vanilla funnels every confirmed exercise change (mouse click and joypad A on
-- the radio list) through ISFitnessUI:clickedExe, so that is the single point
-- where a player's choice becomes final. The reference is read inside
-- initialise() when the radio buttons are built, and this wrapper is installed
-- at load time, so the vanilla call site picks up the wrapper.
local originalClickedExe = FitnessUI.clickedExe
if type(originalClickedExe) == "function" then
    FitnessUI.clickedExe = function(self, buttons, index)
        local result = originalClickedExe(self, buttons, index)
        pcall(rememberExercise, self)
        return result
    end
end

FitnessUI._gqsFitnessEnhancementInstalled = true
