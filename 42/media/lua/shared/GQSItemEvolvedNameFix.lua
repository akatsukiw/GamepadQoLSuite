--[[
    GQSItemEvolvedNameFix.lua  v1.0.0

    修复：烹饪（EvolvedRecipe）菜品名里出现 "Base.XXX" 这种原始 fullType 的问题。
    典型症状：方便面丢进炒锅后，菜名变成「Base.Ramen 和 牛肉干 炒菜」。

    ------------------------------------------------------------------
    根因（已反编译 projectzomboid.jar 确认）

    1) 物品脚本里声明了 EvolvedRecipeName，例如 food.txt：
           item Ramen
               EvolvedRecipeName = Ramen,

    2) Item.DoParam 处理这一行时，会在**解析脚本的过程中**立刻去查翻译：
           Translator.setDefaultItemEvolvedRecipeName(this.getFullName(), value);
           this.evolvedRecipeName = Translator.getItemEvolvedRecipeName(this.getFullName());

    3) Translator.getItemEvolvedRecipeName 的实现是：
           String s = itemEvolvedRecipeName.get(fullType);
           if (s == null) {
               Item it = ScriptManager.instance.getItem(fullType);
               s = (it == null) ? fullType : it.getDisplayName();   // ← 查不到就吐 fullType
               itemEvolvedRecipeName.put(fullType, s);              // ← 写进静态缓存，永久生效
           }
           return s;
       而第 2 步发生在脚本解析中途，此时该物品还没注册进 ScriptManager，
       getItem() 返回 null → s = "Base.Ramen" → 写进缓存，同时写进 Item.evolvedRecipeName。

    4) 原版 ISAddItemInRecipe.lua 拼菜名时：
           local name = getItemEvolvedRecipeName(food) or getItemDisplayName(food);
       因为上一步返回了非 nil 的脏值，`or` 直接短路，
       永远走不到 getItemDisplayName（中文物品名）→ 菜名里出现 Base.Ramen。

    ------------------------------------------------------------------
    修法

    覆写 Lua 全局 getItemEvolvedRecipeName：把「返回值等于 fullType」的脏值
    改判为 nil，让原版回落到 getItemDisplayName(food)。

    · 不修改 Java 字段，不改存档，不发网络包
    · 只影响 Lua 侧对 getItemEvolvedRecipeName 的调用（原版仅 ISAddItemInRecipe 两处）
    · 放在 shared 是为了让「以服务器身份运行」时也能生效（菜名由服务端生成）
    · 可在 模组设置 → 其他杂项 → 「修复菜品名里的 Base.XXX」 里关掉（默认开启）
--]]

if GQSItemEvolvedNameFix ~= nil then
    return
end

GQSItemEvolvedNameFix = {
    installed = false,
    hits = 0,
    -- 诊断开关：true 时每次拦截都打印一行，另外开局/开服时打印一条语言探针。
    -- 排查「菜名没修好」或「服务器语言不对」时把它改成 true，收尾改回 false。
    verbose = false,
}

local TAG = "[GQS-EvolvedName]"
local FIX = GQSItemEvolvedNameFix

local _origEvolvedName = getItemEvolvedRecipeName

-- 开关：读 Mod Options 里的「修复菜品名 Base.XXX」勾选框。
-- 面板还没建好、或读不到值时一律按开启处理（保持默认行为）。
-- 注意：这是客户端设置；以服务器身份运行时（本地开服同进程）能读到，
-- 远程专用服务器读不到客户端设置，会按默认开启处理。
local function optionEnabled()
    local opts = rawget(_G, "GamepadQoLSuiteOptions")
    if opts == nil then return true end
    local option = opts.evolvedNameFixEnabled
    if option == nil then return true end
    local ok, value = pcall(function() return option:getValue() end)
    if ok and value ~= nil then return value == true end
    return true
end
FIX.isEnabled = optionEnabled

local function fullTypeOf(arg)
    if arg == nil then return nil end
    if type(arg) == "string" then return arg end
    -- Java 对象：取 fullType；失败就当不是对象
    local ok, ft = pcall(function() return arg:getFullType() end)
    if ok and type(ft) == "string" then return ft end
    return nil
end

local function isDirty(value, ft)
    if value == nil then return false end
    if type(value) ~= "string" then return false end
    if ft ~= nil and value == ft then return true end
    if string.sub(value, 1, 5) == "Base." then return true end
    return false
end

local function fixedGetItemEvolvedRecipeName(arg)
    if _origEvolvedName == nil then return nil end

    -- 开关关闭：原样透传，完全等同未安装本修复
    if not optionEnabled() then
        local okPass, valuePass = pcall(_origEvolvedName, arg)
        if okPass then return valuePass end
        return nil
    end

    local ok, value = pcall(_origEvolvedName, arg)
    if not ok or value == nil then return nil end

    local ft = fullTypeOf(arg)
    if isDirty(value, ft) then
        FIX.hits = FIX.hits + 1
        if FIX.verbose then
            print(string.format("%s dirty value '%s' -> nil (fallback to item name)", TAG, value))
        end
        return nil
    end
    return value
end

if _origEvolvedName == nil then
    print(TAG .. " SKIP: global getItemEvolvedRecipeName not found")
else
    getItemEvolvedRecipeName = fixedGetItemEvolvedRecipeName
    FIX.installed = (getItemEvolvedRecipeName == fixedGetItemEvolvedRecipeName)
    print(TAG .. " loaded, installed = " .. tostring(FIX.installed))
end

-- ---------------------------------------------------------------------------
-- 诊断接口（常驻，默认关闭；把上面 GQSItemEvolvedNameFix.verbose 改 true 即启用）
--
-- 1) 每次拦截脏值打印一行，看得到具体是哪个 fullType 中招。
-- 2) 语言探针：UI_foraging_WildFood 在当前语言是「野生」/ EN 是 "Wild"，
--    用它判断这一端语言。客户端日志在 console.txt，
--    服务端日志在 Logs/*_DebugLog-server.txt。
--    联机时菜名由服务端生成，所以服务端那一条才是关键。
-- ---------------------------------------------------------------------------
local function reportLanguage(where)
    if not FIX.verbose then return end
    local ok, value = pcall(function() return getText("UI_foraging_WildFood") end)
    print(string.format("%s language check [%s] isServer=%s isClient=%s | UI_foraging_WildFood=%s",
        TAG, where, tostring(isServer()), tostring(isClient()), tostring(ok and value or "ERR")))
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function() reportLanguage("OnGameStart") end)
    end
    if Events.OnServerStarted ~= nil then
        Events.OnServerStarted.Add(function() reportLanguage("OnServerStarted") end)
    end
end
