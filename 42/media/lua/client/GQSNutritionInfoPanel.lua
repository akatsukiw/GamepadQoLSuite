-- Gamepad QoL Suite: nutrition readout on the character screen (v1.5.4).
-- Y opens a compact read-only panel with the current lipid / carbohydrate /
-- protein / calorie values. It is mutually exclusive with the X trait selector:
-- opening one closes the other.
--
-- Everything the panel shows comes from NUTRITION_ROWS below. Adding another
-- value is a one-line change there -- the label comes from a translation key and
-- the number from a getter on zombie.characters.BodyDamage.Nutrition.
--
-- The panel is display-only: it never captures the D-pad, so the character
-- screen keeps working normally while it is open. B closes it.

pcall(require, "ISUI/ISPanel")

local function log(message, isError)
    local logger = rawget(_G, "GQSLog")
    local fn = logger and (isError and logger.error or logger.log)
    if type(fn) == "function" then fn("panelInfo", message) end
end

local function isFeatureEnabled()
    local options = rawget(_G, "GamepadQoLSuiteOptions")
    local option = options and options.nutritionInfoEnabled
    if option and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        if ok then return value == true end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Data rows
-- ---------------------------------------------------------------------------
-- labelKey : translation key for the left-hand label
-- getter   : method name on the Nutrition object
-- decimals : digits after the decimal point (default 1)
-- scale    : optional multiplier, e.g. 100 to show a 0..1 ratio as a percentage
local NUTRITION_ROWS = {
    { labelKey = "UI_GQOS_NutritionLipids",        getter = "getLipids" },
    { labelKey = "UI_GQOS_NutritionCarbohydrates", getter = "getCarbohydrates" },
    { labelKey = "UI_GQOS_NutritionProteins",      getter = "getProteins" },
    { labelKey = "UI_GQOS_NutritionCalories",      getter = "getCalories" },
}

local PADDING = 10
local HEADER_HEIGHT = 36
-- Minimum width of the numeric column. The actual width grows with the font so
-- the panel keeps working when UI scaling enlarges the text.
local VALUE_COLUMN_MIN_WIDTH = 78
local VALUE_WIDTH_SAMPLE = "-000000.0"
local LABEL_VALUE_GAP = 14
local MIN_PANEL_WIDTH = 168

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function safeVisible(element)
    if not element then return false end
    local ok, visible = pcall(function() return element:getIsVisible() end)
    return not ok or visible == true
end

local function getJoypadTexture(name)
    local joypad = rawget(_G, "Joypad")
    local textures = joypad and joypad.Texture
    return textures and textures[name] or nil
end

local function textureSize(texture, maxSize)
    local width, height = maxSize, maxSize
    if texture then
        local okW, w = pcall(function() return texture:getWidth() end)
        local okH, h = pcall(function() return texture:getHeight() end)
        if okW and okH and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            local ratio = maxSize / math.max(w, h)
            width, height = w * ratio, h * ratio
        end
    end
    return width, height
end

local function measureText(text, font)
    local ok, width = pcall(function() return getTextManager():MeasureStringX(font, text) end)
    if ok and type(width) == "number" then return width end
    return #tostring(text or "") * 8
end

-- ---------------------------------------------------------------------------
-- Bottom-right controller prompt
-- ---------------------------------------------------------------------------
-- Same row geometry as GQSTraitInfoPanel (which keeps its own copy so either
-- module can be switched off independently): a row is as tall as the taller of
-- the icon box and the font line, and each part is centred inside it with
-- (rowHeight - partHeight) / 2. Using the icon height as the row height only
-- lines up while the icon is taller than the font.
local PROMPT_ICON_SIZE = 18
local PROMPT_GAP = 5
local PROMPT_RIGHT_PADDING = 10
local PROMPT_BOTTOM_PADDING = 7
local PROMPT_ROW_SPACING = 4

local function getPromptRowHeight(font)
    return math.max(PROMPT_ICON_SIZE, getTextManager():getFontHeight(font))
end

local function drawPromptRow(element, label, texture, fallbackIcon, rowTop, font)
    local rowHeight = getPromptRowHeight(font)
    local iconW, iconH = textureSize(texture, PROMPT_ICON_SIZE)
    local manager = getTextManager()
    local textWidth = manager:MeasureStringX(font, label)
    local rightEdge = (element.width or 360) - PROMPT_RIGHT_PADDING
    local leftX = rightEdge - (iconW + PROMPT_GAP + textWidth)

    local iconY = rowTop + math.floor((rowHeight - iconH) / 2)
    local textY = rowTop + math.floor((rowHeight - manager:getFontHeight(font)) / 2)

    if texture then
        pcall(element.drawTextureScaled, element, texture, leftX, iconY, iconW, iconH, 1, 1, 1, 1)
    else
        pcall(element.drawText, element, fallbackIcon, leftX, textY, 1, 1, 1, 1, font)
    end
    pcall(element.drawText, element, label, leftX + iconW + PROMPT_GAP, textY, 0.90, 0.90, 0.90, 1, font)
end

local function getHostWindow(screen)
    local current = screen
    for _ = 1, 6 do
        local parent = current and current.parent
        if not parent then break end
        local ok, childPanel = pcall(function() return parent.panel end)
        if ok and childPanel == current then return parent end
        current = parent
    end
    return screen and screen.parent and screen.parent.parent or screen
end

local function getViewport(screen)
    local playerNum = tonumber(screen and screen.playerNum) or 0
    local left, top, width, height = 0, 0, nil, nil
    if type(getPlayerScreenLeft) == "function" then
        local ok, value = pcall(getPlayerScreenLeft, playerNum)
        if ok and type(value) == "number" then left = value end
    end
    if type(getPlayerScreenTop) == "function" then
        local ok, value = pcall(getPlayerScreenTop, playerNum)
        if ok and type(value) == "number" then top = value end
    end
    if type(getPlayerScreenWidth) == "function" then
        local ok, value = pcall(getPlayerScreenWidth, playerNum)
        if ok and type(value) == "number" and value > 0 then width = value end
    end
    if type(getPlayerScreenHeight) == "function" then
        local ok, value = pcall(getPlayerScreenHeight, playerNum)
        if ok and type(value) == "number" and value > 0 then height = value end
    end
    local core = rawget(_G, "getCore") and getCore() or nil
    if not width and core and type(core.getScreenWidth) == "function" then
        local ok, value = pcall(core.getScreenWidth, core)
        if ok and type(value) == "number" then width = value end
    end
    if not height and core and type(core.getScreenHeight) == "function" then
        local ok, value = pcall(core.getScreenHeight, core)
        if ok and type(value) == "number" then height = value end
    end
    return left, top, width or 1280, height or 720
end

local function isScreenActive(screen)
    if not screen or not safeVisible(screen) then return false end
    local parent = screen.parent
    if parent and type(parent.getActiveView) == "function" then
        local ok, activeView = pcall(parent.getActiveView, parent)
        if ok and activeView ~= nil and activeView ~= screen then return false end
    end
    local host = getHostWindow(screen)
    if host and host ~= screen and not safeVisible(host) then return false end
    if host and host.isCollapsed == true then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------
local GQSNutritionInfoPanel = ISPanel:derive("GQSNutritionInfoPanel")

function GQSNutritionInfoPanel:new(screen)
    local o = ISPanel.new(self, 0, 0, MIN_PANEL_WIDTH, 140)
    setmetatable(o, self)
    self.__index = self
    o.sourceScreen = screen
    o.background = true
    o.backgroundColor = { r = 0.015, g = 0.015, b = 0.015, a = 0.94 }
    o.borderColor = { r = 0.10, g = 0.62, b = 0.48, a = 1.0 }
    o.moveWithMouse = false
    o.font = UIFont.Small
    o.rowHeight = getTextManager():getFontHeight(o.font) + 8
    o:measureContent()
    return o
end

-- Width depends only on the labels, which are fixed, so this runs once. The
-- numeric column keeps a constant width instead of tracking the widest current
-- value, otherwise the panel would jitter while the numbers change.
-- Width and height both follow NUTRITION_ROWS, so adding a row grows the panel
-- without touching the layout code: every row contributes self.rowHeight and the
-- widest label decides the label column.
function GQSNutritionInfoPanel:measureContent()
    local manager = getTextManager()
    local labelWidth = 0
    for _, row in ipairs(NUTRITION_ROWS) do
        local label = getText(row.labelKey)
        labelWidth = math.max(labelWidth, manager:MeasureStringX(self.font, label))
    end
    self.labelWidth = labelWidth

    local valueWidth = math.max(VALUE_COLUMN_MIN_WIDTH, manager:MeasureStringX(self.font, VALUE_WIDTH_SAMPLE))
    local contentWidth = PADDING * 2 + labelWidth + LABEL_VALUE_GAP + valueWidth
    local titleWidth = manager:MeasureStringX(UIFont.Medium, getText("UI_GQOS_NutritionInfoTitle"))
    local closeWidth = manager:MeasureStringX(self.font, getText("UI_GQOS_NutritionPanelClose"))
    local headerWidth = PADDING * 2 + titleWidth + 8 + 18 + 5 + closeWidth

    self:setWidth(math.max(contentWidth, headerWidth, MIN_PANEL_WIDTH))
    self:setHeight(HEADER_HEIGHT + #NUTRITION_ROWS * self.rowHeight + 8)
end

function GQSNutritionInfoPanel:getNutrition()
    local screen = self.sourceScreen
    local player = screen and screen.char
    if not player or type(player.getNutrition) ~= "function" then return nil end
    local ok, nutrition = pcall(player.getNutrition, player)
    if ok then return nutrition end
    return nil
end

function GQSNutritionInfoPanel:readValue(nutrition, row)
    if not nutrition then return nil end
    local getter = nutrition[row.getter]
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter, nutrition)
    if not ok or type(value) ~= "number" then return nil end
    if type(row.scale) == "number" then value = value * row.scale end
    return value
end

function GQSNutritionInfoPanel:formatValue(value, decimals)
    if type(value) ~= "number" then return "--" end
    decimals = tonumber(decimals) or 1
    -- Avoid "-0.0" for values that round away to nothing.
    if math.abs(value) < 0.5 * (10 ^ -decimals) then value = 0 end
    return string.format("%." .. decimals .. "f", value)
end

function GQSNutritionInfoPanel:render()
    ISPanel.render(self)

    local manager = getTextManager()
    local font = self.font
    local fontHeight = manager:getFontHeight(font)

    local title = getText("UI_GQOS_NutritionInfoTitle")
    self:drawText(title, PADDING,
        math.floor((HEADER_HEIGHT - manager:getFontHeight(UIFont.Medium)) / 2), 1, 1, 1, 1, UIFont.Medium)

    local bTexture = getJoypadTexture("BButton")
    local bW, bH = textureSize(bTexture, 18)
    local closeLabel = getText("UI_GQOS_NutritionPanelClose")
    local closeX = self.width - PADDING - measureText(closeLabel, font) - 5 - bW
    local closeY = math.floor((HEADER_HEIGHT - math.max(bH, fontHeight)) / 2)
    if bTexture then
        pcall(self.drawTextureScaled, self, bTexture, closeX, closeY, bW, bH, 1, 1, 1, 1)
        closeX = closeX + bW + 5
    else
        self:drawText("B", closeX, closeY, 1, 1, 1, 1, font)
        closeX = closeX + measureText("B", font) + 5
    end
    self:drawText(closeLabel, closeX, math.floor((HEADER_HEIGHT - fontHeight) / 2), 0.90, 0.90, 0.90, 1, font)

    self:drawRect(8, HEADER_HEIGHT - 3, self.width - 16, 1, 0.75, 0.22, 0.48, 0.40)

    local nutrition = self:getNutrition()
    local valueRight = self.width - PADDING
    local y = HEADER_HEIGHT + 4
    for _, row in ipairs(NUTRITION_ROWS) do
        self:drawText(getText(row.labelKey), PADDING, y, 0.90, 0.91, 0.90, 1, font)
        self:drawTextRight(self:formatValue(self:readValue(nutrition, row), row.decimals),
            valueRight, y, 0.75, 0.92, 1.00, 1, font)
        y = y + self.rowHeight
    end
end

-- ---------------------------------------------------------------------------
-- Positioning and lifecycle
-- ---------------------------------------------------------------------------
local openScreens = {}

local function positionPanel(screen, panel)
    local host = getHostWindow(screen)
    local left, top, viewportWidth, viewportHeight = getViewport(screen)
    local hostX, hostY, hostWidth = left + 8, top + 8, screen.width or 360
    if host then
        if type(host.getAbsoluteX) == "function" then
            local ok, value = pcall(host.getAbsoluteX, host)
            if ok and type(value) == "number" then hostX = value end
        end
        if type(host.getAbsoluteY) == "function" then
            local ok, value = pcall(host.getAbsoluteY, host)
            if ok and type(value) == "number" then hostY = value end
        end
        if type(host.getWidth) == "function" then
            local ok, value = pcall(host.getWidth, host)
            if ok and type(value) == "number" then hostWidth = value end
        end
    end

    local panelWidth = panel.width or MIN_PANEL_WIDTH
    local panelX = hostX + hostWidth
    local rightEdge = left + viewportWidth
    if panelX + panelWidth > rightEdge - 4 then
        local leftX = hostX - panelWidth
        if leftX >= left + 4 then
            panelX = leftX
        else
            panelX = math.max(left + 4, rightEdge - panelWidth - 4)
        end
    end

    -- Top-aligned with the character window: the panel is short, so it reads as
    -- sitting above the area the trait selector would cover.
    local panelY = math.max(top + 4, hostY)
    local bottomEdge = top + viewportHeight
    local panelHeight = math.min(panel.height or 140, bottomEdge - panelY - 4)

    panel:setX(math.floor(panelX))
    panel:setY(math.floor(panelY))
    panel:setHeight(math.floor(math.max(80, panelHeight)))
end

local function closePanel(screen)
    local panel = screen and screen._gqsNutritionInfoPanel
    if panel then
        pcall(function() panel:setVisible(false) end)
        pcall(function() panel:removeFromUIManager() end)
    end
    openScreens[screen] = nil
end

local function openPanel(screen)
    if not isFeatureEnabled() or not isScreenActive(screen) then return false end

    -- Mutually exclusive with the X trait selector.
    local traitInfo = rawget(_G, "GQSTraitInfo")
    if traitInfo and type(traitInfo.close) == "function" then
        pcall(traitInfo.close, screen)
    end

    local panel = screen._gqsNutritionInfoPanel
    if not panel then
        panel = GQSNutritionInfoPanel:new(screen)
        panel:initialise()
        panel:setVisible(false)
        screen._gqsNutritionInfoPanel = panel
    end
    panel.sourceScreen = screen
    panel:measureContent()
    positionPanel(screen, panel)
    panel:addToUIManager()
    panel:setVisible(true)
    openScreens[screen] = true
    log("Opened nutrition readout for player " .. tostring(screen.playerNum))
    return true
end

local function closeOpenPanels()
    local screens = {}
    for screen in pairs(openScreens) do screens[#screens + 1] = screen end
    for _, screen in ipairs(screens) do closePanel(screen) end
end

-- Exposed so the trait selector can close this panel when it opens.
GQSNutritionInfo = {
    close = closePanel,
    isOpen = function(screen)
        return safeVisible(screen and screen._gqsNutritionInfoPanel)
    end,
}

-- ---------------------------------------------------------------------------
-- Y prompt on the character screen
-- ---------------------------------------------------------------------------
local function drawHint(screen)
    if not isFeatureEnabled() or not isScreenActive(screen) then return end

    local panelOpen = GQSNutritionInfo.isOpen(screen)
    local key = panelOpen and "UI_GQOS_NutritionCloseHint" or "UI_GQOS_NutritionOpenHint"
    local hint = getText(key)
    if hint == key or hint == nil or hint == "" then
        hint = panelOpen and "关闭营养" or "营养信息"
    end

    local font = UIFont.Small
    local texture = getJoypadTexture("YButton")
    local rowHeight = getPromptRowHeight(font)
    local rowTop = (screen.height or 420) - rowHeight - PROMPT_BOTTOM_PADDING

    -- The X trait prompt owns the bottom row. Stack the Y prompt directly above
    -- it with the right edges aligned: side by side, the pair reaches far enough
    -- left to run into the survival-time line at the bottom of the window.
    local traitInfo = rawget(_G, "GQSTraitInfo")
    if traitInfo and type(traitInfo.promptLayout) == "function" then
        local ok, layout = pcall(traitInfo.promptLayout, screen)
        if ok and type(layout) == "table" then
            rowTop = layout.rowTop - rowHeight - (layout.spacing or PROMPT_ROW_SPACING)
        end
    end

    drawPromptRow(screen, hint, texture, "Y", rowTop, font)
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------
local function install()
    pcall(require, "XpSystem/ISUI/ISCharacterScreen")
    local CharacterScreen = rawget(_G, "ISCharacterScreen")
    if not CharacterScreen then
        pcall(require, "ISUI/ISCharacterScreen")
        CharacterScreen = rawget(_G, "ISCharacterScreen")
    end
    if not CharacterScreen then return false end
    if CharacterScreen._gqsNutritionInfoInstalled then return true end

    local originalDown = CharacterScreen.onJoypadDown
    if type(originalDown) == "function" then
        CharacterScreen.onJoypadDown = function(self, button, ...)
            local yButton = Joypad and Joypad.YButton
            local bButton = Joypad and Joypad.BButton
            local lbButton = Joypad and Joypad.LBumper
            local rbButton = Joypad and Joypad.RBumper
            local isOpen = GQSNutritionInfo.isOpen(self)

            if not isFeatureEnabled() then
                if isOpen then closePanel(self) end
                return originalDown(self, button, ...)
            end
            if button == yButton and isScreenActive(self) then
                if isOpen then closePanel(self) else openPanel(self) end
                return
            end
            if isOpen and button == bButton then
                closePanel(self)
                return
            end
            if isOpen and (button == lbButton or button == rbButton) then
                -- Let the vanilla handler switch tabs; the panel is page-specific.
                closePanel(self)
            end
            return originalDown(self, button, ...)
        end
    end

    local originalRender = CharacterScreen.render
    if type(originalRender) == "function" and not CharacterScreen._gqsNutritionHintInstalled then
        CharacterScreen.render = function(self, ...)
            local result = { originalRender(self, ...) }
            pcall(drawHint, self)
            return unpack(result)
        end
        CharacterScreen._gqsNutritionHintInstalled = true
    end

    CharacterScreen._gqsNutritionInfoInstalled = true
    log("Installed Y nutrition readout on ISCharacterScreen")
    return true
end

install()
if Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(install) end
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        local CharacterScreen = rawget(_G, "ISCharacterScreen")
        if not CharacterScreen or not CharacterScreen._gqsNutritionInfoInstalled then install() end
        if not isFeatureEnabled() then
            if next(openScreens) ~= nil then closeOpenPanels() end
            return
        end
        local screens = {}
        for screen in pairs(openScreens) do screens[#screens + 1] = screen end
        for _, screen in ipairs(screens) do
            local panel = screen and screen._gqsNutritionInfoPanel
            if not isScreenActive(screen) or not panel or not safeVisible(panel) then
                closePanel(screen)
            else
                positionPanel(screen, panel)
            end
        end
    end)
end
