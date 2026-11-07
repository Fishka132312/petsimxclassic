--[[
    Антилаг 3 — Pet Optimizer с переключателем и откатом.
    Петы остаются в игре и фармят (логика Pets.Tick / Join Coin / Farm Coin не тронута),
    но визуально скрыты. Ничего не удаляем, только выключаем: прозрачность на клиенте,
    частицы, трейлы, GUI, свет, звуки.

    _G.AntiLag3Enabled = true   -> прячет петов и эффекты выбора монеты
    _G.AntiLag3Enabled = false  -> возвращает всё как было

    Повторный запуск скрипта сначала выгружает прошлую копию и откатывает её изменения.
]]

-- Имя переменной-переключателя (у каждого анти-лага своё)
local FLAG = "AntiLag3Enabled"

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
local RunService = game:GetService("RunService")

local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do task.wait() end

--================ НАСТРОЙКИ ================--
local HIDE_PETS         = true   -- скрыть всех петов (чужих лучше ещё убрать в настройках игры: Show Other Pets = Off)
local HIDE_SELECTION_FX = true   -- убрать пунктирную линию и круги выбора монеты
local MUTE_PET_SOUNDS   = true   -- звуки пет-объектов
local NO_EFFECTS        = false  -- true = отключить PetCmds.Effects (даёт больше FPS, но это внутренний
                                 -- модуль, которого я не видел: если что-то сломается - ставь false)
local BATCH             = 400    -- объектов за кадр при откате
--==========================================--

local PetsFolder = Library.Things:WaitForChild("Pets", 15)
if not PetsFolder then
    return
end

local DISABLE_ENABLED = {
    ParticleEmitter = true, Trail = true, Beam = true, Fire = true, Smoke = true,
    Sparkles = true, Highlight = true, PointLight = true, SpotLight = true,
    SurfaceLight = true, BillboardGui = true, SurfaceGui = true,
}

-- ================== СОСТОЯНИЕ ==================
local alive, active = true, false
local sid = 0                -- номер сессии (каждое включение = новая сессия)
local conns = {}             -- подключения текущей сессии
local saved = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = исходное значение }
local effectsOrig            -- оригинальный PetCmds.Effects

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

local function hide(d)
    if not (alive and active) then return end
    local cls = d.ClassName
    if d:IsA("BasePart") then
        setSaved(d, "LocalTransparencyModifier", 1)
        setSaved(d, "CastShadow", false)
    elseif DISABLE_ENABLED[cls] then
        setSaved(d, "Enabled", false)
    elseif d:IsA("Decal") or d:IsA("Texture") then
        setSaved(d, "Transparency", 1)
    elseif MUTE_PET_SOUNDS and d:IsA("Sound") then
        setSaved(d, "Volume", 0)
    end
end

local function hideTree(root)
    pcall(hide, root)
    for _, d in ipairs(root:GetDescendants()) do
        pcall(hide, d)
    end
end

-- sync = true: без пауз между кадрами (используется при выгрузке скрипта)
local function revertAll(sync)
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

-- ================== ЭФФЕКТЫ ==================
local function patchEffects()
    local ok = pcall(function()
        local orig = Library.PetCmds.Effects
        effectsOrig = orig
        Library.PetCmds.Effects = function(...)
            if alive and active then return end
            return orig(...)
        end
    end)
    if not ok then
        effectsOrig = nil
    end
end

local function unpatchEffects()
    if effectsOrig then
        pcall(function() Library.PetCmds.Effects = effectsOrig end)
        effectsOrig = nil
    end
end

-- ================== СЕССИЯ (одно включение) ==================
local function startSession()
    sid += 1
    local id = sid
    local function ok() return alive and active and sid == id end

    -- ===== Петы =====
    if HIDE_PETS then
        track(PetsFolder.DescendantAdded:Connect(function(d)
            if ok() then pcall(hide, d) end
        end))
        for _, p in ipairs(PetsFolder:GetChildren()) do hideTree(p) end
    end

    -- ===== Визуал выбора монеты =====
    -- Tick создаёт SelectionCircle (с SurfaceGui) и пунктирную линию (Beam) и кладёт в Debris
    if HIDE_SELECTION_FX then
        local Debris = Library.Debris
        if Debris then
            local function checkDebris(inst)
                if not ok() then return end
                if inst.Name == "SelectionCircle" or inst.Name == "DottedLine" then
                    hideTree(inst)
                    -- без track: эти объекты короткоживущие, подключение уйдёт вместе с ними
                    inst.DescendantAdded:Connect(function(d)
                        if ok() then pcall(hide, d) end
                    end)
                end
            end
            track(Debris.ChildAdded:Connect(checkDebris))
            for _, c in ipairs(Debris:GetChildren()) do checkDebris(c) end
        end
    end

    -- ===== Эффекты =====
    if NO_EFFECTS then patchEffects() end

end

local function stopSession()
    sid += 1
    for _, c in ipairs(conns) do c:Disconnect() end
    table.clear(conns)
    unpatchEffects()
    revertAll(false)
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
    unpatchEffects()
    revertAll(true)
end
