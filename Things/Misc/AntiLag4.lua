--[[
    Антилаг 4 — Coin Optimizer с переключателем и откатом.
    1) Коины дальше FAR_DISTANCE студов выносятся из workspace (Parent = nil),
       а при приближении возвращаются. Не Destroy: иначе коин не вернётся
       (оригинал создаёт папку коина только один раз при Add Coin).
    2) Убираем самое тяжёлое косметическое: частицы удара/взрыва, свет и частицы
       на самих коинах, звуки.
    Оригинальный скрипт Coins НЕ выключается.

    _G.AntiLag4Enabled = true   -> оптимизация включена
    _G.AntiLag4Enabled = false  -> всё возвращено (вынесенные коины снова в workspace,
                                   эффекты, звуки и шаблоны частиц как были)

    Повторный запуск скрипта сначала выгружает прошлую копию и откатывает её изменения.
]]

-- Имя переменной-переключателя (у каждого анти-лага своё)
local FLAG = "AntiLag4Enabled"

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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
local LocalPlayer = Players.LocalPlayer
while not Library.Loaded do task.wait() end

--================ НАСТРОЙКИ ================--
local FAR_DISTANCE         = 999    -- дальше этого коины убираются из workspace
local RESTORE_MARGIN       = 50     -- вернуть, когда ближе FAR_DISTANCE - RESTORE_MARGIN (чтобы не мигали на границе)
local CHECK_INTERVAL       = 1      -- как часто проверять дистанцию (сек)
local DESTROY_FAR          = false  -- true = удалять навсегда (коин не вернётся до смены мира/перезахода, откат не вернёт!)
local DISABLE_COIN_FX      = true   -- выключить частицы/свет/beam на моделях коинов
local KILL_HIT_PARTICLES   = true   -- убрать частицы удара/взрыва коинов (клоны шаблонов из Assets.Particles)
local MUTE_COIN_SOUNDS     = true   -- глушить звуки ударов/падения/разрушения коинов
local BATCH                = 300    -- объектов за кадр при откате
local DEBUG                = false
--==========================================--

local CoinsFolder = Library.Things:WaitForChild("Coins", 15)
if not CoinsFolder then
    return
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function disconnect(c)
    pcall(function() c:Disconnect() end)
end

-- ================== СОСТОЯНИЕ ==================
local alive, active = true, false
local sid = 0                -- номер сессии (каждое включение = новая сессия)
local conns = {}             -- подключения текущей сессии
local saved = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = исходное значение }
local info = {}              -- [id] = { folder, pos, stored }
local nStored = 0
local particleBackup = {}    -- { { template = inst, children = { ... } } }
local audioOrig              -- оригинальный Audio.Play

local function track(conn)
    conns[#conns + 1] = conn
    return conn
end

-- ================== СВОЙСТВА (сохранить / вернуть) ==================
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
        if s[prop] == nil then s[prop] = cur end
    end
    setProp(obj, prop, value)
end

local function revertProps(sync)
    local list = {}
    for obj in pairs(saved) do list[#list + 1] = obj end
    for i, obj in ipairs(list) do
        local props = saved[obj]
        if props then
            saved[obj] = nil
            for prop, val in pairs(props) do setProp(obj, prop, val) end
        end
        if not sync and i % BATCH == 0 then RunService.Heartbeat:Wait() end
    end
end

-- ================== ЗВУКИ ==================
local blocked = {}
for _, id in ipairs({
    6485234572, 6485234808, 6485234993,                                   -- удар
    6422233047, 6422233117, 12151937071, 12151936879, 12151936744,        -- монеты
    6422233314, 6422233259, 6422233191, 12151937223,                      -- сундуки
    6958718789, 6958718747, 7029284027, 11648888186,                      -- сейф/хранилище/special/luckyblock
    6958713639, 6958713793, 6958713747, 6958713692, 9395255388, 12970061125, -- разрушение
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
    if not ok then
        audioOrig = nil
    end
end

local function unpatchAudio()
    if audioOrig then
        pcall(function() Library.Audio.Play = audioOrig end)
        audioOrig = nil
    end
end

-- ================== ЧАСТИЦЫ УДАРА ==================
-- CoinDamageAnimation / PetDamageAnimation клонируют эти шаблоны на каждый удар по коину.
-- Вместо ClearAllChildren дети шаблонов временно снимаются (Parent = nil) и потом возвращаются.
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
            -- объект остаётся (оригинал его клонирует и зовёт Emit), но частицы не живут
            setSaved(t, "Lifetime", NumberRange.new(0))
        end
    end
end

local function restoreParticles()
    for i = #particleBackup, 1, -1 do
        local rec = particleBackup[i]
        particleBackup[i] = nil
        for _, ch in ipairs(rec.children) do
            pcall(function() ch.Parent = rec.template end)
        end
    end
end

-- ================== КОИНЫ: ОТСЕЧЕНИЕ ПО ДИСТАНЦИИ ==================
local FX = { ParticleEmitter = true, Beam = true, Trail = true,
    PointLight = true, SpotLight = true, SurfaceLight = true }

local function register(folder)
    if not folder:IsA("Folder") then return end
    local id = folder.Name
    local c = info[id]
    if c and c.folder == folder then
        -- вернули мы сами
        if c.stored then c.stored = false; nStored -= 1 end
        return
    end
    local pos = folder:FindFirstChild("POS")
    if not pos then return end
    info[id] = { folder = folder, pos = pos.Position, stored = false }
end

-- вернуть вынесенные коины в workspace
local function restoreCoins(sync)
    local n = 0
    for id, c in pairs(info) do
        if c.stored then
            c.stored = false
            nStored -= 1
            pcall(function() c.folder.Parent = CoinsFolder end)
            n += 1
            if not sync and n % BATCH == 0 then RunService.Heartbeat:Wait() end
        end
    end
    info = {}
    nStored = 0
end

-- ================== СЕССИЯ (одно включение) ==================
local function startSession()
    sid += 1
    local id = sid
    local function ok() return alive and active and sid == id end

    -- звуки
    if MUTE_COIN_SOUNDS then patchAudio() end

    -- частицы удара (ждёт папку Assets.Particles, поэтому в отдельном потоке)
    if KILL_HIT_PARTICLES then
        task.spawn(function() pcall(killHitParticles, ok) end)
    end

    -- эффекты на моделях коинов
    if DISABLE_COIN_FX then
        track(CoinsFolder.DescendantAdded:Connect(function(d)
            if ok() and FX[d.ClassName] then setSaved(d, "Enabled", false) end
        end))
        for _, d in ipairs(CoinsFolder:GetDescendants()) do
            if FX[d.ClassName] then setSaved(d, "Enabled", false) end
        end
    end

    -- отсечение по дистанции
    info = {}
    nStored = 0
    track(CoinsFolder.ChildAdded:Connect(function(f)
        if ok() then register(f) end
    end))
    for _, f in ipairs(CoinsFolder:GetChildren()) do register(f) end

    -- Коин удалён сервером: вынесенную папку уничтожаем сами (оригинал её не найдёт в Things.Coins)
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

    -- Смена мира: оригинал перезагрузит все коины заново, наши вынесенные чистим
    track(Library.Signal.Fired("World Changed"):Connect(function()
        if not ok() then return end
        for _, c in pairs(info) do
            if c.stored then c.folder:Destroy() end
        end
        info = {}
        nStored = 0
    end))

    task.spawn(function()
        local restoreAt = FAR_DISTANCE - RESTORE_MARGIN
        while ok() do
            task.wait(CHECK_INTERVAL)
            local root = ok() and getRoot()
            if root then
                local p = root.Position
                for cid, c in pairs(info) do
                    local folder = c.folder
                    local d = (c.pos - p).Magnitude
                    if c.stored then
                        if d <= restoreAt then
                            folder.Parent = CoinsFolder -- ChildAdded -> register сбросит stored
                        end
                    elseif d > FAR_DISTANCE then
                        if folder.Parent == CoinsFolder then
                            if DESTROY_FAR then
                                info[cid] = nil
                                folder:Destroy()
                            else
                                c.stored = true
                                nStored += 1
                                folder.Parent = nil
                            end
                        else
                            info[cid] = nil -- папку уже удалил оригинал
                        end
                    end
                end
            end
        end
    end)

    if DEBUG then
        task.spawn(function()
            while ok() do
                task.wait(5)
                local total = 0
                for _ in pairs(info) do total += 1 end
                    total, nStored, #CoinsFolder:GetChildren()))
            end
        end)
    end

end

local function stopSession()
    sid += 1
    for _, c in ipairs(conns) do disconnect(c) end
    table.clear(conns)
    unpatchAudio()
    restoreParticles()
    restoreCoins(false)
    revertProps(false)
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
    unpatchAudio()
    restoreParticles()
    restoreCoins(true)
    revertProps(true)
end
