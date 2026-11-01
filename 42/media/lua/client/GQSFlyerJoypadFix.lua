-- Gamepad QoL Suite: controller support for print-media windows
-- (flyers / newspapers / magazines).
--
-- Vanilla ISReadABook:displayPrintMedia() only installs the controller binding
-- inside `if getJoypadData(self.playerNum) then`. When that check is falsy - or
-- when anything throws before the binding is installed - the flyer window still
-- appears, but it never receives joypad focus, so B / X / Y all do nothing. That
-- is the MP-only "flyer opens, pad is dead" report.
--
-- This module re-applies the binding after the vanilla call, keeps the vanilla
-- behaviour (B closes, X toggles the newspaper text, Y reveals the map location
-- and closes), and re-applies focus if something clears it while the window is
-- still open. It never steals focus from another window: only a nil focus is
-- restored.

local TAG = "[GQS FlyerJoypad]"
local MAX_FOCUS_RESTORES = 60

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("flyerJoypad", message)
    end
end

-- Always-visible diagnostics: only used for abnormal paths, so the volume stays
-- low and a report can be read without flipping a debug category first.
local function warn(message)
    print(TAG .. " " .. tostring(message))
end

-- Option lookup mirrors the other GQS modules: a missing or unreadable toggle
-- counts as "on", so the fix is active by default.
local function getOptions()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    if options then return options end
    local ok, module = pcall(require, "GQSModOptions")
    if ok and type(module) == "table" then return module end
    return nil
end

local function isEnabled()
    local options = getOptions()
    local toggle = options and options.flyerJoypadFixEnabled
    if not toggle or type(toggle.getValue) ~= "function" then return true end
    local ok, value = pcall(function() return toggle:getValue() end)
    if not ok then return true end
    return value == true or value == 1
end

local function getFocus(playerNum)
    if type(getJoypadFocus) == "function" then
        local ok, focus = pcall(getJoypadFocus, playerNum)
        if ok then return focus end
    end
    local players = JoypadState and JoypadState.players
    local data = players and players[playerNum + 1]
    return data and data.focus or nil
end

-- Vanilla ISAtomUIJoypad:toString() ends with
--     if name == "" then return self._ATOM_UI_CLASS.class:getSimpleName() end
-- _ATOM_UI_CLASS is the Java class itself (Node.lua:5 -> AtomUI), not an
-- instance, so `.class` never resolves and getSimpleName() throws
-- "attempted index: getSimpleName of non-table: class zombie.ui.AtomUI".
--
-- setJoypadFocus() calls uiToString(control) -> control:toString() inside its
-- noise() argument list, i.e. *before* it reaches `joypadData.focus = control`.
-- The exception therefore aborts the assignment and the window never gets
-- focus. Every AtomUI widget whose javaObj has an empty UIName hits this, and
-- print-media windows always do - that is the MP "flyer opens, pad is dead"
-- report. Wrapping toString() keeps vanilla's focus bookkeeping intact instead
-- of working around it.
-- IMPORTANT (v1.5.14.1): a pcall wrapper is NOT enough. Kahlua flushes the
-- error message and dumps the stack trace at the *throw site*, before pcall can
-- swallow it. So `pcall(original, self)` keeps the focus assignment alive (that
-- is why the pad works) but still leaves one ERROR + stack trace per call in
-- console.txt. The only way to silence it is to never enter the throwing branch,
-- i.e. reimplement toString() instead of calling vanilla's.
local function safeAtomToString(self)
    local javaObj = self.javaObj
    if javaObj ~= nil then
        local ok, name = pcall(function() return javaObj:getUIName() end)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    local plain = self.UIName
    if type(plain) == "string" and plain ~= "" then return plain end
    return "<AtomUI>"
end

local function patchAtomToString()
    local atom = rawget(_G, "ISAtomUIJoypad")
    if type(atom) ~= "table" or type(atom.toString) ~= "function" then return false end
    if atom._gqsToStringPatched == 2 then return true end
    atom.toString = safeAtomToString
    atom._gqsToStringPatched = 2
    log("patched ISAtomUIJoypad:toString (reimplemented; vanilla empty-UIName branch never runs)")
    return true
end

-- Last-resort focus assignment: exactly the side effects setJoypadFocus()
-- performs, minus the uiToString() call that can throw.
local function applyFocusDirectly(playerNum, object)
    local data = nil
    if type(getJoypadData) == "function" then
        local ok, value = pcall(getJoypadData, playerNum)
        if ok then data = value end
    end
    if data == nil then
        local state = rawget(_G, "JoypadState")
        local players = state and state.players
        data = players and players[playerNum + 1] or nil
    end
    if data == nil then return false end
    if object ~= nil and object ~= data.focus then
        data.prevprevfocus = data.prevfocus
        data.prevfocus = data.focus
    end
    data.focus = object
    if object ~= nil and object.activeWhilePaused then
        data.activeWhilePaused = true
    end
    return true
end

local function setFocus(playerNum, object)
    if type(setJoypadFocus) ~= "function" then
        warn("setJoypadFocus is unavailable; assigning focus directly for player "
            .. tostring(playerNum))
        return applyFocusDirectly(playerNum, object)
    end
    local ok, err = pcall(setJoypadFocus, playerNum, object)
    if not ok then
        warn("setJoypadFocus failed for player " .. tostring(playerNum) .. ": " .. tostring(err)
            .. " -> assigning focus directly")
    end
    -- Verify instead of trusting the call: vanilla can return normally while
    -- the focus assignment was skipped, so compare against the actual state.
    if getFocus(playerNum) ~= object then
        return applyFocusDirectly(playerNum, object)
    end
    return true
end

local function hasJoypad(playerNum)
    if type(getJoypadData) ~= "function" then return false end
    local ok, data = pcall(getJoypadData, playerNum)
    return ok and data ~= nil
end

-- ISReadABook:new() stores character:getPlayerNum(). When that ends up nil the
-- vanilla `getJoypadData(self.playerNum)` call is what kills the binding path,
-- so recover a usable number instead of trusting the field.
local function resolvePlayerNum(action)
    local value = action.playerNum
    if type(value) == "number" then return value end
    local character = action.character
    if character ~= nil then
        -- Java methods cannot be tested with type(o[m]) == "function"; call them.
        local ok, num = pcall(function() return character:getPlayerNum() end)
        if ok and type(num) == "number" then return num end
    end
    return 0
end

-- Joypad.BButton / JoypadButton.B / "B" - all three shapes show up across
-- builds and through modded dispatch layers.
local function isButton(button, enumName, shortName)
    local joypad = rawget(_G, "Joypad")
    local enumValue = joypad and joypad[enumName]
    if enumValue ~= nil and button == enumValue then return true end
    local buttons = rawget(_G, "JoypadButton")
    local shortValue = buttons and buttons[shortName]
    if shortValue ~= nil and button == shortValue then return true end
    local ok, text = pcall(tostring, button)
    if ok and type(text) == "string" then
        local lower = string.lower(text)
        local wanted = string.lower(shortName)
        if lower == wanted then return true end
        if string.find(lower, "joypadbutton." .. wanted, 1, true) then return true end
    end
    return false
end

local watched = { win = nil, playerNum = 0, restores = 0 }

local function isWindowAlive(win)
    if win == nil then return false end
    if win.visible == false then return false end
    local javaObj = win.javaObj
    if javaObj ~= nil then
        local ok, visible = pcall(function() return javaObj:isVisible() end)
        if ok and visible == false then return false end
    end
    return true
end

local function closeWindow(win)
    local playerNum = win.playerNum
    if type(playerNum) ~= "number" then playerNum = resolvePlayerNum(win) end
    local prevFocus = win.prevFocus
    local closed = false

    if type(win.close) == "function" then
        local ok, err = pcall(function() win:close() end)
        if ok then
            closed = true
        else
            warn("flyer close() failed: " .. tostring(err))
        end
    end
    if not closed and win.javaObj ~= nil then
        local ok, err = pcall(function() UIManager.RemoveElement(win.javaObj) end)
        if ok then closed = true else warn("RemoveElement failed: " .. tostring(err)) end
    end

    setFocus(playerNum, prevFocus)
    if watched.win == win then watched.win = nil end
    return closed
end

local function handleButton(win, button)
    if isButton(button, "BButton", "B") then
        closeWindow(win)
        return true
    end
    if isButton(button, "XButton", "X") then
        local ok, err = pcall(function() win:onClickNewspaperButton() end)
        if not ok then warn("onClickNewspaperButton failed: " .. tostring(err)) end
        return true
    end
    if isButton(button, "YButton", "Y") then
        local ok, err = pcall(function() win:onClickMapButton() end)
        if not ok then warn("onClickMapButton failed: " .. tostring(err)) end
        closeWindow(win)
        return true
    end
    return false
end

local function installBinding(win, playerNum)
    win.playerNum = playerNum
    if win.prevFocus == nil then win.prevFocus = getFocus(playerNum) end

    -- Keep the vanilla close() (it restores prevFocus) and only supply one when
    -- the vanilla path never got that far.
    if type(win.close) ~= "function" then
        win.close = function(self)
            local owner = self.playerNum
            if type(owner) ~= "number" then owner = playerNum end
            pcall(function() UIManager.RemoveElement(self.javaObj) end)
            setFocus(owner, self.prevFocus)
        end
    end

    -- Vanilla also rebinds the title-bar close button; do the same so the mouse
    -- path and the pad path agree.
    local bar = win.children and win.children.bar
    local closeButton = bar and bar.children and bar.children.closeButton
    if closeButton ~= nil and closeButton._gqsFlyerCloseButton == nil then
        closeButton._gqsFlyerCloseButton = true
        closeButton.onLeftClick = function(_self)
            local parent = _self.parent
            local window = parent and parent.parent
            if window ~= nil then
                closeWindow(window)
            end
        end
    end

    if win._gqsFlyerJoypadDown == nil then
        win._gqsFlyerPreviousOnJoypadDown = win.onJoypadDown
        win._gqsFlyerJoypadDown = function(self, button, joypadData)
            local ok, handled = pcall(handleButton, self, button)
            if ok and handled then return end
            local previous = self._gqsFlyerPreviousOnJoypadDown
            if type(previous) == "function" then
                pcall(previous, self, button, joypadData)
            end
        end
        win.onJoypadDown = win._gqsFlyerJoypadDown
    end

    local current = getFocus(playerNum)
    if current ~= win then
        setFocus(playerNum, win)
    end

    watched.win = win
    watched.playerNum = playerNum
    watched.restores = 0
end

local function isPrintMediaWindow(ui)
    if type(ui) ~= "table" then return false end
    local bottom = ui.children and ui.children.bottomButtons
    local kids = bottom and bottom.children
    if type(kids) ~= "table" then return false end
    if kids.readNewspaper ~= nil then return true end
    for key in pairs(kids) do
        if type(key) == "string" and string.find(key, "revealOnMap", 1, true) then return true end
    end
    return false
end

-- ISReadABook:displayPrintMedia() calls ISAtomUIJoypad.Apply(win) as its first
-- statement, which is the only point where the window object is reachable from
-- outside without scanning PZAPI.UI.instances.
local lastAtomWindow = nil

local function hookAtomApply()
    local atom = rawget(_G, "ISAtomUIJoypad")
    if type(atom) ~= "table" or type(atom.Apply) ~= "function" then return false end
    if atom._gqsFlyerApplyHooked then return true end
    local original = atom.Apply
    atom.Apply = function(ui)
        original(ui)
        -- Apply() copies ISAtomUIJoypad's methods onto the ui table. That copy is
        -- a snapshot taken before our class-level patch, so the instance's own
        -- toString can still be vanilla's throwing version. Overwrite the copy
        -- with our reimplementation (never call the original - see the note above
        -- about Kahlua logging at the throw site even when pcall catches).
        if type(ui) == "table" and type(ui.toString) == "function" and ui._gqsInstanceToStringPatched ~= 2 then
            ui.toString = safeAtomToString
            ui._gqsInstanceToStringPatched = 2
        end
        if isPrintMediaWindow(ui) then lastAtomWindow = ui end
    end
    atom._gqsFlyerApplyHooked = true
    return true
end

local installed = false
local atomPatched = false

local function install()
    if installed then return true end
    if type(ISReadABook) ~= "table" or type(ISReadABook.displayPrintMedia) ~= "function" then
        return false
    end
    hookAtomApply()
    atomPatched = patchAtomToString()

    local originalDisplay = ISReadABook.displayPrintMedia
    ISReadABook.displayPrintMedia = function(self)
        -- Option off: hand the call straight back to vanilla. No player-number
        -- repair, no binding, no focus change - the mod leaves no trace.
        if not isEnabled() then
            return originalDisplay(self)
        end

        -- Repair the player number before vanilla reads it. A nil value here is
        -- what makes getJoypadData() fail and skips the whole binding block.
        local playerNum = resolvePlayerNum(self)
        if type(self.playerNum) ~= "number" then
            warn("playerNum was " .. tostring(self.playerNum) .. "; using " .. tostring(playerNum))
            self.playerNum = playerNum
        end

        lastAtomWindow = nil
        local ok, err = pcall(originalDisplay, self)
        if not ok then
            warn("vanilla displayPrintMedia failed: " .. tostring(err))
        end

        local win = lastAtomWindow
        if win == nil then
            warn("no print-media window was captured; controller binding skipped")
            return
        end

        -- Did vanilla itself install the binding? This is the exact signature of
        -- the reported bug: the window is on screen but vanilla never called
        -- setJoypadFocus. Recording it means the next occurrence is provable from
        -- one line in console.txt instead of guesswork.
        local vanillaBound = (getFocus(playerNum) == win)

        installBinding(win, playerNum)

        log("flyer open: player=" .. tostring(playerNum)
            .. ", media=" .. tostring(win.media_id)
            .. ", joypad=" .. tostring(hasJoypad(playerNum))
            .. ", vanillaBound=" .. tostring(vanillaBound)
            .. ", focusOk=" .. tostring(getFocus(playerNum) == win))

        if not vanillaBound then
            warn("VANILLA BIND FAILED media=" .. tostring(win.media_id)
                .. " player=" .. tostring(playerNum)
                .. " joypad=" .. tostring(hasJoypad(playerNum))
                .. " selfPlayerNum=" .. tostring(self.playerNum)
                .. " client=" .. tostring(isClient ~= nil and isClient() == true)
                .. " -> GQS re-applied the binding")
        end
    end

    installed = true
    log("loaded; flyer/newspaper windows always receive a controller binding")
    return true
end

if not install() then
    if Events and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            if not install() then
                warn("ISReadABook.displayPrintMedia was unavailable; flyer pad fix inactive")
            end
        end)
    end
end

-- If focus gets cleared while the flyer is still on screen the pad goes dead
-- again. Restore only a nil focus so a deliberately focused panel keeps focus.
local function onTick()
    -- ISAtomUIJoypad can be defined after this file loads; retry until it lands.
    if not atomPatched then atomPatched = patchAtomToString() end

    if not isEnabled() then
        -- Turning the option off is a hard off switch: un-patch a flyer that is
        -- still open and drop the watch, so nothing of this module keeps running.
        local open = watched.win
        if open ~= nil then
            if type(open._gqsFlyerPreviousOnJoypadDown) == "function" then
                open.onJoypadDown = open._gqsFlyerPreviousOnJoypadDown
            end
            open._gqsFlyerJoypadDown = nil
            watched.win = nil
            log("option turned off; open flyer restored to vanilla and focus watch stopped")
        end
        return
    end

    local win = watched.win
    if win == nil then return end
    if not isWindowAlive(win) then
        watched.win = nil
        return
    end
    if watched.restores >= MAX_FOCUS_RESTORES then
        watched.win = nil
        warn("gave up restoring flyer focus after " .. tostring(watched.restores) .. " attempts")
        return
    end
    local current = getFocus(watched.playerNum)
    if current == nil then
        setFocus(watched.playerNum, win)
        watched.restores = watched.restores + 1
        if watched.restores <= 3 then
            warn("focus was cleared while the flyer stayed open; re-applied (#"
                .. tostring(watched.restores) .. ")")
        end
    end
end

if Events and Events.OnTick then Events.OnTick.Add(onTick) end
