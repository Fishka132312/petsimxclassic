--[[
    Антилаг 2 — локальный очиститель карты с переключателем и откатом.
    Всё происходит только у тебя на клиенте.

    _G.AntiLag2Enabled = true   -> чистит карту
    _G.AntiLag2Enabled = false  -> возвращает всё на место

    Режимы для каждого пункта:
      "delete" — убрать объект с карты (Parent = nil, не Destroy), при выключении вернётся обратно
                 (больше всего FPS, но скрипты игры могут сломаться, пока включено)
      "hide"   — оставить объект, но сделать невидимым/выключить эффекты и звук
                 (коллизии, касания, промпты работают — игра не ломается)
      "off"    — не трогать

    Как найти, что ломает игру: ставь пункты по одному в "delete",
    смотри консоль (F9) — скрипт пишет, что он сделал.
    Повторный запуск скрипта сначала выгружает прошлую копию и откатывает её изменения.
]]

-- Имя переменной-переключателя (у каждого анти-лага своё)
local FLAG = "AntiLag2Enabled"

local CLEANUP = FLAG .. "_Cleanup"
if _G[CLEANUP] then
    pcall(_G[CLEANUP])
    _G[CLEANUP] = nil
end
if _G[FLAG] == nil then
    _G[FLAG] = false -- по умолчанию выключен. Хочешь, чтобы включался сам при запуске — поставь true
end

local function enabled()
    return _G[FLAG] and true or false
end

local Players     = game:GetService("Players")
local Lighting    = game:GetService("Lighting")
local RunService  = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- ================== НАСТРОЙКИ ==================
local CFG = {
    CHARACTERS    = "delete", -- модельки других игроков: "delete" / "hide" / "off"
    INCLUDE_SELF  = false,    -- трогать свою модельку (true почти всегда ломает игру)
    LIGHTING      = "visual", -- "visual" = только Sky/Atmosphere/Clouds/эффекты, "all" = всё, "off"
    AREAS_MODE    = "delete", -- режим для декораций в __MAP.Areas
    WAIT_TIMEOUT  = 15,       -- сколько ждать загрузку папок (сек)
    BATCH         = 400,      -- объектов за кадр при откате
    LOG           = true,     -- писать в консоль (F9)
}

-- Папки целиком. Игровые папки по умолчанию "hide" — их удаление чаще всего ломает игру.
local FOLDERS = {
    { path = {"__MAP", "Cannons"},            mode = "hide"   },
    { path = {"__MAP", "Boxes"},              mode = "delete" },
    { path = {"__MAP", "Audio"},              mode = "hide"   },
    { path = {"__MAP", "Interactive"},        mode = "hide"   },
    { path = {"__MAP", "Gates"},              mode = "hide"   },
    { path = {"__MAP", "PlayerSpawns"},       mode = "hide"   },
    { path = {"__MAP", "Scavenger"},          mode = "hide"   },
    { path = {"__MAP", "Teleports"},          mode = "hide"   },
    { path = {"__MAP", "Areas", "Teleports"}, mode = "hide"   },
}

-- Декорации по именам (регистр не важен, на любой глубине папки)
local AREA_NAMES = {
    Candy   = {"Chocolate Bar", "Lollipop", "Sucker", "Tree"},
    Haunted = {"Arch", "CryptShop", "Fence", "Gravestone", "Stump", "Tree"},
    Heaven  = {"GateDecor", "Egg", "Mesh", "Pillar"},
    Hell    = {"IslandRock", "Stump", "Tree"},
    Samurai = {"CherryBlossom", "GiantCherryBlossom", "Planter", "SamuraiHouse",
               "SamuraiSpawnGate", "SamuraiShop", "SamuraiWall", "Shinto"},
    Shop    = {"Bridge", "Chains", "ColosseumWall", "Tree", "Shop Sign", "sign light"},
    Spawn   = {"Pillar", "Side", "Sign", "Tower"},
    Temple  = {"Tree"},
}
-- ===============================================

-- ================== СОСТОЯНИЕ ==================
local alive, active = false, false
alive = true
local sid = 0                -- номер сессии (каждое включение = новая сессия)
local conns = {}             -- подключения текущей сессии
local saved = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = исходное значение }
local removed = {}           -- { obj, parent, valid } убранные объекты

local function track(conn)
    conns[#conns + 1] = conn
    return conn
end

-- ================== ПРИМЕНЕНИЕ / ОТКАТ ==================
local function setProp(obj, prop, value)
    local ok = pcall(function() obj[prop] = value end)
    if not ok and sethiddenproperty then
        ok = pcall(sethiddenproperty, obj, prop, value)
    end
    return ok
end

-- поставить значение, запомнив исходное (только при первом изменении)
local function setSaved(obj, prop, value)
    local ok, cur = pcall(function() return obj[prop] end)
    if not ok and gethiddenproperty then
        ok, cur = pcall(gethiddenproperty, obj, prop)
    end
    if ok and cur == value then return end

    if ok then
        local s = saved[obj]
        if not s then
            s = {}
            saved[obj] = s
        end
        if s[prop] == nil then s[prop] = cur end
    end
    setProp(obj, prop, value)
end

-- "delete": убрать объект с карты (не Destroy!), чтобы можно было вернуть
local function detach(obj, valid)
    if not obj or not obj.Parent then return end
    if not obj:IsDescendantOf(game) then return end -- уже внутри убранного родителя
    removed[#removed + 1] = { obj = obj, parent = obj.Parent, valid = valid }
    pcall(function() obj.Parent = nil end)
end

-- Скрыть один объект, ничего не удаляя
local function hideOne(obj)
    if not (alive and active) then return end
    pcall(function()
        if obj:IsA("BasePart") then
            setSaved(obj, "LocalTransparencyModifier", 1)
            setSaved(obj, "Transparency", 1)
            setSaved(obj, "CastShadow", false)
        elseif obj:IsA("Decal") then            -- Decal и Texture
            setSaved(obj, "Transparency", 1)
        elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
            or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles")
            or obj:IsA("Light") or obj:IsA("Highlight") then
            setSaved(obj, "Enabled", false)
        elseif obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
            setSaved(obj, "Enabled", false)
        elseif obj:IsA("Sound") then
            setSaved(obj, "Volume", 0)
        end
    end)
end

-- Скрыть объект и всё внутри, включая то, что появится позже
local function hideTree(root)
    hideOne(root)
    for _, d in ipairs(root:GetDescendants()) do hideOne(d) end
    track(root.DescendantAdded:Connect(function(d)
        task.defer(hideOne, d)
    end))
end

local function apply(obj, mode, valid)
    if not (alive and active) then return end
    if mode == "delete" then
        detach(obj, valid)
    elseif mode == "hide" then
        hideTree(obj)
    end
end

-- sync = true: без пауз между кадрами (используется при выгрузке скрипта)
local function revertAll(sync)
    -- 1. свойства (hide)
    local list = {}
    for obj in pairs(saved) do list[#list + 1] = obj end
    for i, obj in ipairs(list) do
        local props = saved[obj]
        if props then
            saved[obj] = nil
            for prop, val in pairs(props) do setProp(obj, prop, val) end
        end
        if not sync and i % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
    end

    -- 2. убранные объекты (delete): по порядку, родители раньше детей
    local list2 = removed
    removed = {}
    for i, r in ipairs(list2) do
        local ok = r.parent and r.parent:IsDescendantOf(game)
        if ok and r.valid then
            local vok, res = pcall(r.valid)
            ok = vok and res
        end
        if ok then
            pcall(function() r.obj.Parent = r.parent end)
        end
        if not sync and i % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
    end
end

-- ================== СЕССИЯ (одно включение) ==================
local function waitPath(path, ok)
    local cur = workspace
    for _, name in ipairs(path) do
        cur = cur:WaitForChild(name, CFG.WAIT_TIMEOUT)
        if not cur or not ok() then return nil end
    end
    return cur
end

local function startSession()
    sid += 1
    local id = sid
    local function ok() return alive and active and sid == id end

    -- ===== 1. Папки =====
    for _, entry in ipairs(FOLDERS) do
        if entry.mode ~= "off" then
            task.spawn(function()
                local path = entry.path
                local parent = waitPath({table.unpack(path, 1, #path - 1)}, ok)
                if not parent then return end
                local name = path[#path]
                local function handle(ch)
                    if ok() and ch.Name == name then
                        log(entry.mode, table.concat(path, "."))
                        apply(ch, entry.mode)
                    end
                end
                local existing = parent:FindFirstChild(name)
                if existing then handle(existing) end
                if ok() then track(parent.ChildAdded:Connect(handle)) end
            end)
        end
    end

    -- ===== 2. Декорации в Areas =====
    if CFG.AREAS_MODE ~= "off" then
        task.spawn(function()
            local areas = waitPath({"__MAP", "Areas"}, ok)
            if not areas then return end
            for areaName, names in pairs(AREA_NAMES) do
                task.spawn(function()
                    local folder = areas:WaitForChild(areaName, CFG.WAIT_TIMEOUT)
                    if not folder or not ok() then return end
                    local set = {}
                    for _, n in ipairs(names) do set[string.lower(n)] = true end
                    local count = 0
                    local function check(obj)
                        if ok() and set[string.lower(obj.Name)] then
                            count += 1
                            apply(obj, CFG.AREAS_MODE)
                        end
                    end
                    for _, d in ipairs(folder:GetDescendants()) do check(d) end
                    track(folder.DescendantAdded:Connect(check))
                    log(CFG.AREAS_MODE, "Areas." .. areaName, count, "шт.")
                end)
            end
        end)
    end

    -- ===== 3. Модельки игроков =====
    if CFG.CHARACTERS ~= "off" then
        local function onCharacter(plr, char)
            if plr == LocalPlayer and not CFG.INCLUDE_SELF then return end
            -- вернуть модельку обратно только если игрок ещё в игре и это его текущий персонаж
            apply(char, CFG.CHARACTERS, function()
                return plr.Parent ~= nil and plr.Character == char
            end)
        end
        local function onPlayer(plr)
            if plr.Character then onCharacter(plr, plr.Character) end
            track(plr.CharacterAdded:Connect(function(char)
                if ok() then onCharacter(plr, char) end
            end))
        end
        for _, plr in ipairs(Players:GetPlayers()) do onPlayer(plr) end
        track(Players.PlayerAdded:Connect(function(plr)
            if ok() then onPlayer(plr) end
        end))
        log(CFG.CHARACTERS, "модельки игроков")
    end

    -- ===== 4. Lighting =====
    -- В Lighting игры часто хранят скрипты/модули/значения — "visual" их не трогает
    if CFG.LIGHTING ~= "off" then
        local function isVisual(obj)
            return obj:IsA("Sky") or obj:IsA("Atmosphere") or obj:IsA("Clouds")
                or obj:IsA("PostEffect") -- Bloom, Blur, ColorCorrection, SunRays, DepthOfField
        end
        local function lightingCheck(obj)
            if ok() and (CFG.LIGHTING == "all" or (CFG.LIGHTING == "visual" and isVisual(obj))) then
                detach(obj)
            end
        end
        for _, obj in ipairs(Lighting:GetChildren()) do lightingCheck(obj) end
        track(Lighting.ChildAdded:Connect(lightingCheck))
        log("Lighting:", CFG.LIGHTING)
    end

    log("включён")
end

local function stopSession()
    sid += 1
    for _, c in ipairs(conns) do c:Disconnect() end
    table.clear(conns)
    revertAll(false)
    log("выключен: всё возвращено")
end

-- ================== ПЕРЕКЛЮЧАТЕЛЬ ==================
task.spawn(function()
    while alive do
        local want = enabled()
        if want and not active then
            active = true
            startSession()
        elseif not want and active then
            active = false
            stopSession()
        end
        task.wait(0.2)
    end
end)

-- ================== ВЫГРУЗКА ==================
_G[CLEANUP] = function()
    alive = false
    active = false
    sid += 1
    for _, c in ipairs(conns) do c:Disconnect() end
    table.clear(conns)
    revertAll(true)
end
