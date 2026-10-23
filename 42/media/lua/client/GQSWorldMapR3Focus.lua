-- Gamepad QoL Suite: focus the in-game world map on the player with R3.
-- This deliberately calls the vanilla ISWorldMap:onCenterOnPlayer() method,
-- which is also used by the map's C button. No map movement is reimplemented.

require "ISUI/Maps/ISWorldMap"

local GQSWorldMapR3Focus = rawget(_G, "GQSWorldMapR3Focus") or {}
GQSWorldMapR3Focus.VERSION = "1.5.1.15"

local function log(message)
    local logger = rawget(_G, "GQSLog")
    if logger and type(logger.log) == "function" then
        logger.log("mapControls", message)
    end
end

local function isR3Button(button)
    local joypad = rawget(_G, "Joypad")
    if not joypad then return false end
    -- RStickButton is the native Build 42 name, with aliases retained for
    -- controller/input wrappers that expose an alternate spelling.
    for _, name in ipairs({ "RStickButton", "RightStickButton", "RStick", "RightStick", "R3Button", "R3" }) do
        local ok, value = pcall(function() return joypad[name] end)
        if ok and value ~= nil and button == value then
            return true
        end
    end
    return false
end

local function getR3Texture()
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    if not textures then return nil end
    -- Prefer the official native RStick glyph used by the game UI, then try
    -- click-specific aliases for builds that expose a separate R3 texture.
    for _, name in ipairs({ "RStick", "RStickButton", "RightStickButton", "RightStick", "R3Button", "R3", "RightStickClick" }) do
        local ok, texture = pcall(function() return textures[name] end)
        if ok and texture ~= nil then
            return texture, name
        end
    end
    return nil
end

local function uiReallyVisible(ui)
    if ui == nil then return false end
    if type(ui.isReallyVisible) == "function" then
        local ok, visible = pcall(ui.isReallyVisible, ui)
        if ok then return visible == true end
    end
    if type(ui.isVisible) == "function" then
        local ok, visible = pcall(ui.isVisible, ui)
        if ok then return visible == true end
    end
    return ui.visible == true
end

local function isMapVisible(map)
    if map == nil then return false end
    if type(map.isVisible) == "function" then
        local ok, visible = pcall(map.isVisible, map)
        if not ok or visible ~= true then return false end
    end
    return true
end

-- Hook the map's native joypad handler. The callback only runs when the map
-- receives the button event; other panels and non-map controls are untouched.
if type(ISWorldMap) == "table" and type(ISWorldMap.onJoypadDown) == "function"
        and not ISWorldMap._gqsR3FocusOnJoypadDownWrapped then
    local originalOnJoypadDown = ISWorldMap.onJoypadDown

    local function wrappedOnJoypadDown(self, button, joypadData, ...)
        if isR3Button(button) and isMapVisible(self) then
            local nativeCenter = self.onCenterOnPlayer
            if type(nativeCenter) == "function" then
                local ok, err = pcall(nativeCenter, self)
                if ok then
                    log("R3 invoked vanilla ISWorldMap:onCenterOnPlayer for player " .. tostring(self.playerNum))
                    return
                end
                log("R3 center-on-player call failed; forwarding to vanilla handler: " .. tostring(err))
            end
        end
        return originalOnJoypadDown(self, button, joypadData, ...)
    end

    ISWorldMap._gqsR3FocusOnJoypadDownOriginal = originalOnJoypadDown
    ISWorldMap._gqsR3FocusOnJoypadDownWrapped = wrappedOnJoypadDown
    ISWorldMap.onJoypadDown = wrappedOnJoypadDown
end

-- Add the prompt above the vanilla map's existing left-bottom zoom prompts.
-- Vanilla currently draws X (edit markings), LT (zoom out), and RT (zoom in).
-- This adds a fourth row at the top of that same prompt stack.
if type(ISWorldMap) == "table" and type(ISWorldMap.render) == "function"
        and not ISWorldMap._gqsR3FocusRenderWrapped then
    local originalRender = ISWorldMap.render
    local missingTextureLogged = false

    local function wrappedRender(self, ...)
        local result = originalRender(self, ...)

        if self.joyfocus and isMapVisible(self)
                and not uiReallyVisible(self.stashMapUI)
                and not uiReallyVisible(self.optionsUI)
                and not uiReallyVisible(self.forgetUI)
                and type(self.renderJoypadPrompt) == "function" then
            local texture = getR3Texture()
            if texture then
                local promptHeight = tonumber(self.joypadPromptHgt)
                if not promptHeight then
                    local ok, height = pcall(function()
                        return math.max(32, getTextManager():getFontHeight(UIFont.Large))
                    end)
                    promptHeight = (ok and tonumber(height)) or 32
                end
                local y = self.height - 16 - promptHeight
                    - 8 - promptHeight
                    - 8 - promptHeight
                    - 8 - promptHeight
                self:renderJoypadPrompt(texture, getText("UI_GQS_MapFocusPlayer"), 16, y)
            elseif not missingTextureLogged then
                missingTextureLogged = true
                log("Native R3 prompt texture not found in Joypad.Texture; R3 map action remains enabled")
            end
        end

        return result
    end

    ISWorldMap._gqsR3FocusRenderOriginal = originalRender
    ISWorldMap._gqsR3FocusRenderWrapped = wrappedRender
    ISWorldMap.render = wrappedRender
end

_G.GQSWorldMapR3Focus = GQSWorldMapR3Focus
return GQSWorldMapR3Focus
