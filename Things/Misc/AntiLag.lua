--[[
    AntiLag ALL — объединение AntiLag2 (карта) + AntiLag3 (петы) + AntiLag4 (монеты).
    Один переключатель, один откат, общие вспомогательные функции.

    _G.AntiLagEnabled = true   -> всё включено
    _G.AntiLagEnabled = false  -> всё возвращено как было

    Модули включаются в блоке ENABLE ниже (MAP / PETS / COINS).
    Повторный запуск сначала выгружает прошлую копию и откатывает её изменения.
]]

local FLAG = "AntiLagEnabled"

local CLEANUP = FLAG .. "_Cleanup"
if _G[CLEANUP] then
    pcall(_G[CLEANUP])
    _G[CLEANUP] = nil
end
if _G[FLAG] == nil then
    _G[FLAG] = false -- по умолчанию выключен. Хочешь автозапуск — поставь true
end

local function enabled()
    return _G[FLAG] and true or false
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Lighting          = game:GetService("Lighting")
local RunService        = game:GetService("RunService")
local LocalPlayer       = Players.LocalPlayer

--================== НАСТРОЙКИ ==================--
local ENABLE = {
    MAP   = true, -- AntiLag2: очистка карты, модельки игроков, Lighting
    PETS  = true, -- AntiLag3: скрыть петов и эффекты выбора монеты
    COINS = true, -- AntiLag4: убирать далёкие монеты, частицы, звуки
}

local CFG = {
    LOG          = true,
    BATCH        = 400,   -- объектов за кадр при откате
    WAIT_TIMEOUT = 15,    -- сколько ждать загрузку папок (сек)

    -- MAP (AntiLag2)
    CHARACTERS   = "delete", -- модельки других игроков: "delete" / "hide" / "off"
    INCLUDE_SELF = false,    -- трогать свою модельку (почти всегда ломает игру)
    LIGHTING     = "visual", -- "visual" / "all" / "off"
    AREAS_MODE   = "delete", -- режим для декораций в __MAP.Areas

    -- PETS (AntiLag3)
    HIDE_PETS         = true,
    HIDE_SELECTION_FX = true,
    MUTE_PET_SOUNDS   = true,
    NO_EFFECTS        = false, -- отключить PetCmds.Effects (больше FPS, но может сломать)

    -- COINS (AntiLag4)
    FAR_DISTANCE        = 999,
    RESTORE_MARGIN      = 50,
    CHECK_INTERVAL      = 1,
    DESTROY_FAR         = false, -- true = удалять навсегда (откат не вернёт!)
    DISABLE_COIN_FX     = true,
    KILL_HIT_PARTICLES  = true,
    MUTE_COIN_SOUNDS    = true,
}

-- Папки целиком: "delete" / "hide" / "off"
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
--===============================================--

local function log(...)
    if CFG.LOG then print("[AntiLag]", ...) end
end

-- ================== БИБЛИОТЕКА ИГРЫ (для PETS и COINS) ==================
local Library
if ENABLE.PETS or ENABLE.COINS then
    local okLib, res = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Framework", CFG.WAIT_TIMEOUT):WaitForChild("Library", CFG.WAIT_TIMEOUT))
    end)
    if okLib and res then
        Library = res
        while not Library.Loaded do task.wait() end
    else
        log("Library не найдена: модули PETS и COINS пропущены")
    end
end

-- ================== СОСТОЯНИЕ ==================
local alive, active = true, false
local sid = 0
local conns = {}
local saved = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = исходное значение }
local removed = {}          -- { obj, parent, valid } (delete-режим карты)
local effectsOrig           -- оригинальный PetCmds.Effects
local audioOrig             -- оригинальный Audio.Play
local particleBackup = {}   -- шаблоны частиц монет
local CoinsFolder, PetsFolder
local info = {}             -- [id] = { folder, pos, stored }
local nStored = 0

local function track(conn)
    conns[#conns + 1] = conn
    return conn
end

local function disconnect(c)
    pcall(function() c:Disconnect() end)
end

-- ================== СВОЙСТВА (запомнить / вернуть) ==================
local function setProp(obj, prop, value)
    local ok = pcall(function() obj[prop] = value end)
    if not ok and sethiddenproperty then
        ok = pcall(sethiddenproperty, obj, prop, value)
    end
    return ok
end

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
        if s[prop] == nil then s[prop] = cur end -- исходное значение пишется один раз, даже если трогают несколько модулей
    end
    setProp(obj, prop, value)
end

-- убрать объект с карты (Parent = nil, не Destroy), чтобы можно было вернуть
local function detach(obj, valid)
    if not obj or not obj.Parent then return end
    if not obj:IsDescendantOf(game) then return end
    removed[#removed + 1] = { obj = obj, parent = obj.Parent, valid = valid }
    pcall(function() obj.Parent = nil end)
end

-- ================== СКРЫТИЕ ==================
-- Универсальное скрытие одного объекта (используют MAP и PETS)
local DISABLE_ENABLED = {
    ParticleEmitter = true, Trail = true, Beam = true, Fire = true, Smoke = true,
    Sparkles = true, Highlight = true, PointLight = true, SpotLight = true,
    SurfaceLight = true, BillboardGui = true, SurfaceGui = true,
}

-- opts.transparency: ещё и Transparency=1 у частей (для MAP); opts.sound: глушить звуки
local function hideOne(obj, opts)
    if not (alive and active) then return end
    pcall(function()
        if obj:IsA("BasePart") then
            setSaved(obj, "LocalTransparencyModifier", 1)
            if opts.transparency then setSaved(obj, "Transparency", 1) end
            setSaved(obj, "CastShadow", false)
        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            setSaved(obj, "Transparency", 1)
        elseif DISABLE_ENABLED[obj.ClassName] or obj:IsA("Light") then
            setSaved(obj, "Enabled", false)
        elseif opts.sound and obj:IsA("Sound") then
            setSaved(obj, "Volume", 0)
        end
    end)
end

local MAP_OPTS = { transparency = true, sound = true }
local PET_OPTS = { transparency = false, sound = nil } -- sound выставляется из CFG при старте

local function hideTree(root, opts, withFuture)
    hideOne(root, opts)
    for _, d in ipairs(root:GetDescendants()) do hideOne(d, opts) end
    if withFuture then
        track(root.DescendantAdded:Connect(function(d)
            task.defer(hideOne, d, opts)
        end))
    end
end

-- ================== ОТКАТ ==================
local function restoreParticles()
    for i = #particleBackup, 1, -1 do
        local rec = particleBackup[i]
        particleBackup[i] = nil
        for _, ch in ipairs(rec.children) do
            pcall(function() ch.Parent = rec.template end)
        end
    end
end

local function restoreCoins(sync)
    local n = 0
    for _, c in pairs(info) do
        if c.stored then
            c.stored = false
            nStored -= 1
            pcall(function() c.folder.Parent = CoinsFolder end)
            n += 1
            if not sync and n % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
        end
    end
    info = {}
    nStored = 0
end

local function unpatchAudio()
    if audioOrig then
        pcall(function() Library.Audio.Play = audioOrig end)
        audioOrig = nil
    end
end

local function unpatchEffects()
    if effectsOrig then
        pcall(function() Library.PetCmds.Effects = effectsOrig end)
        effectsOrig = nil
    end
end

-- sync = true: без пауз между кадрами (при выгрузке скрипта)
local function revertAll(sync)
    unpatchAudio()
    unpatchEffects()
    restoreParticles()
    restoreCoins(sync)

    -- 1. свойства
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

    -- 2. убранные объекты: по порядку, родители раньше детей
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

-- ================== МОДУЛЬ MAP (AntiLag2) ==================
local function apply(obj, mode, valid)
    if not (alive and active) then return end
    if mode == "delete" then
        detach(obj, valid)
    elseif mode == "hide" then
        hideTree(obj, MAP_OPTS, true)
    end
end

local function waitPath(path, ok)
    local cur = workspace
    for _, name in ipairs(path) do
        cur = cur:WaitForChild(name, CFG.WAIT_TIMEOUT)
        if not cur or not ok() then return nil end
    end
    return cur
end

local function startMap(ok)
    -- 1. Папки
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

    -- 2. Декорации Areas
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

    -- 3. Модельки игроков
    if CFG.CHARACTERS ~= "off" then
        local function onCharacter(plr, char)
            if plr == LocalPlayer and not CFG.INCLUDE_SELF then return end
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

    -- 4. Lighting
    if CFG.LIGHTING ~= "off" then
        local function isVisual(obj)
            return obj:IsA("Sky") or obj:IsA("Atmosphere") or obj:IsA("Clouds") or obj:IsA("PostEffect")
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
end

-- ================== МОДУЛЬ PETS (AntiLag3) ==================
local function patchEffects()
    local ok = pcall(function()
        local orig = Library.PetCmds.Effects
        effectsOrig = orig
        Library.PetCmds.Effects = function(...)
            if alive and active then return end
            return orig(...)
        end
    end)
    if not ok then effectsOrig = nil end
end

local function startPets(ok)
    PET_OPTS.sound = CFG.MUTE_PET_SOUNDS or nil
    task.spawn(function()
        PetsFolder = PetsFolder or Library.Things:WaitForChild("Pets", CFG.WAIT_TIMEOUT)
        if not PetsFolder or not ok() then
            log("папка Pets не найдена")
            return
        end

        if CFG.HIDE_PETS then
            track(PetsFolder.DescendantAdded:Connect(function(d)
                if ok() then hideOne(d, PET_OPTS) end
            end))
            for _, p in ipairs(PetsFolder:GetChildren()) do hideTree(p, PET_OPTS, false) end
        end

        if CFG.HIDE_SELECTION_FX then
            local Debris = Library.Debris
            if Debris then
                local function checkDebris(inst)
                    if not ok() then return end
                    if inst.Name == "SelectionCircle" or inst.Name == "DottedLine" then
                        hideTree(inst, PET_OPTS, false)
                        inst.DescendantAdded:Connect(function(d)
                            if ok() then hideOne(d, PET_OPTS) end
                        end)
                    end
                end
                track(Debris.ChildAdded:Connect(checkDebris))
                for _, c in ipairs(Debris:GetChildren()) do checkDebris(c) end
            end
        end

        if CFG.NO_EFFECTS then patchEffects() end
    end)
end

-- ================== МОДУЛЬ COINS (AntiLag4) ==================
local blocked = {}
for _, id in ipairs({
    6485234572, 6485234808, 6485234993,
    6422233047, 6422233117, 12151937071, 12151936879, 12151936744,
    6422233314, 6422233259, 6422233191, 12151937223,
    6958718789, 6958718747, 7029284027, 11648888186,
    6958713639, 6958713793, 6958713747, 6958713692, 9395255388, 12970061125,
}) do
    blocked[tostring(id)] = true
end

local function soundKey(x)
    return tostring(x):match("%d+")
end

local function patchAudio()
    local ok = pcall(function()
        local orig = Library.Audio.Play
        audioOrig = orig
        Library.Audio.Play = function(sound, ...)
            if alive and active then
                local first = type(sound) == "table" and sound[1] or sound
                if first ~= nil and blocked[soundKey(first) or ""] then return end
            end
            return orig(sound, ...)
        end
    end)
    if not ok then audioOrig = nil end
end

local function killHitParticles(ok)
    local P = Library.Assets:WaitForChild("Particles", 10)
    if not P or not ok() then return end

    for _, name in ipairs({ "Coin Damage", "Coin Explode" }) do
        local t = P:FindFirstChild(name)
        if t then
            local rec = { template = t, children = t:GetChildren() }
            particleBackup[#particleBackup + 1] = rec
            for _, ch in ipairs(rec.children) do
                pcall(function() ch.Parent = nil end)
            end
        end
    end
    for _, name in ipairs({ "New Coin Particle", "Pet Damage" }) do
        local t = P:FindFirstChild(name)
        if t and t:IsA("ParticleEmitter") then
            setSaved(t, "Lifetime", NumberRange.new(0))
        end
    end
end

local COIN_FX = { ParticleEmitter = true, Beam = true, Trail = true,
    PointLight = true, SpotLight = true, SurfaceLight = true }

local function getRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function register(folder)
    if not folder:IsA("Folder") then return end
    local id = folder.Name
    local c = info[id]
    if c and c.folder == folder then
        if c.stored then c.stored = false; nStored -= 1 end
        return
    end
    local pos = folder:FindFirstChild("POS")
    if not pos then return end
    info[id] = { folder = folder, pos = pos.Position, stored = false }
end

local function startCoins(ok)
    if CFG.MUTE_COIN_SOUNDS then patchAudio() end

    if CFG.KILL_HIT_PARTICLES then
        task.spawn(function() pcall(killHitParticles, ok) end)
    end

    task.spawn(function()
        CoinsFolder = CoinsFolder or Library.Things:WaitForChild("Coins", CFG.WAIT_TIMEOUT)
        if not CoinsFolder or not ok() then
            log("папка Coins не найдена")
            return
        end

        if CFG.DISABLE_COIN_FX then
            track(CoinsFolder.DescendantAdded:Connect(function(d)
                if ok() and COIN_FX[d.ClassName] then setSaved(d, "Enabled", false) end
            end))
            for _, d in ipairs(CoinsFolder:GetDescendants()) do
                if COIN_FX[d.ClassName] then setSaved(d, "Enabled", false) end
            end
        end

        info = {}
        nStored = 0
        track(CoinsFolder.ChildAdded:Connect(function(f)
            if ok() then register(f) end
        end))
        for _, f in ipairs(CoinsFolder:GetChildren()) do register(f) end

        track(Library.Network.Fired("Remove Coin"):Connect(function(coinId)
            if not ok() then return end
            local c = info[coinId]
            if not c then return end
            info[coinId] = nil
            if c.stored then
                nStored -= 1
                c.folder:Destroy()
            end
        end))

        track(Library.Signal.Fired("World Changed"):Connect(function()
            if not ok() then return end
            for _, c in pairs(info) do
                if c.stored then c.folder:Destroy() end
            end
            info = {}
            nStored = 0
        end))

        local restoreAt = CFG.FAR_DISTANCE - CFG.RESTORE_MARGIN
        while ok() do
            task.wait(CFG.CHECK_INTERVAL)
            local root = ok() and getRoot()
            if root then
                local p = root.Position
                for cid, c in pairs(info) do
                    local folder = c.folder
                    local d = (c.pos - p).Magnitude
                    if c.stored then
                        if d <= restoreAt then
                            folder.Parent = CoinsFolder
                        end
                    elseif d > CFG.FAR_DISTANCE then
                        if folder.Parent == CoinsFolder then
                            if CFG.DESTROY_FAR then
                                info[cid] = nil
                                folder:Destroy()
                            else
                                c.stored = true
                                nStored += 1
                                folder.Parent = nil
                            end
                        else
                            info[cid] = nil
                        end
                    end
                end
            end
        end
    end)
end

-- ================== СЕССИЯ (одно включение) ==================
local function startSession()
    sid += 1
    local id = sid
    local function ok() return alive and active and sid == id end

    if ENABLE.MAP then startMap(ok) end
    if ENABLE.PETS and Library then startPets(ok) end
    if ENABLE.COINS and Library then startCoins(ok) end
    log("включён")
end

local function stopSession()
    sid += 1
    for _, c in ipairs(conns) do disconnect(c) end
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
    for _, c in ipairs(conns) do disconnect(c) end
    table.clear(conns)
    revertAll(true)
end
