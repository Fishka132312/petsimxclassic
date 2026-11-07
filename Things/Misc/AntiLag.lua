--[[
    Анти-лаг (локальный) с переключателем и откатом.

    _G.AntiLagEnabled = true   -> применяет оптимизацию
    _G.AntiLagEnabled = false  -> возвращает всё как было

    Ничего структурного не уничтожается: парты, модели, папки, скрипты, Humanoid не трогаются.
    Эффекты, свет, GUI отключаются через Enabled/Visible/Transparency.
    SurfaceAppearance и одежда других игроков не удаляются, а временно снимаются (Parent = nil)
    и при выключении возвращаются на место.
    Повторный запуск скрипта сначала выгружает прошлую копию и откатывает её изменения.
]]

-- Имя переменной-переключателя. Если у тебя несколько анти-лагов, поставь в каждом своё.
local FLAG = "AntiLagEnabled"

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
    MESHID_MODE      = "all",   -- "all" = у всех мешпартов, "coins" = только у монет, "off" = не трогать MeshId
    CLEAR_TEXTURES   = true,    -- убрать TextureID у MeshPart и TextureId у SpecialMesh
    ENFORCE          = true,    -- если игра вернёт TextureID/MeshId — снова очистить (пока включено)
    HIDE_COINS       = true,    -- монеты невидимые (парты остаются)
    HIDE_ALL_MESHES  = false,   -- все мешпарты невидимые (максимум FPS, карту не видно)
    DISABLE_GUI      = true,    -- BillboardGui/SurfaceGui в мире выключаются
    REMOVE_EFFECTS   = true,    -- частицы, трейлы, лучи, огонь, дым, Highlight -> выключаются
    REMOVE_LIGHTS    = true,    -- PointLight/SpotLight/SurfaceLight -> выключаются
    REMOVE_DECALS    = true,    -- Decal/Texture -> прозрачные
    REMOVE_SURFACE_APPEARANCE = true, -- SurfaceAppearance (PBR) -> временно снимается
    REMOVE_CLOTHING  = false,   -- одежда/аксессуары других игроков
    MUTE_SOUNDS      = false,   -- звуки в workspace -> громкость 0
    SIMPLE_PHYSICS   = false,   -- CollisionFidelity = Box (локально)
    LIGHTING_OPT     = true,    -- упрощение освещения, воды, террейна
    FPS_CAP          = nil,     -- например 60, если инжектор поддерживает setfpscap (nil = не трогать)
    BATCH            = 400,     -- объектов за кадр
    RECHECK_DELAY    = 5,       -- перепроверка монет (сек)
}
-- ===============================================

-- Папка монет (не виснем навсегда, если её нет)
local coinsFolder do
    local things = workspace:WaitForChild("__THINGS", 10)
    coinsFolder = things and things:WaitForChild("Coins", 10)
end

-- Классы, которые НИКОГДА не снимаются
local PROTECTED = { "BasePart", "Model", "Folder", "LuaSourceContainer", "Humanoid",
    "Attachment", "Constraint", "JointInstance", "ValueBase", "Camera", "Terrain" }

local EFFECTS  = { "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "Highlight" }
local LIGHTS   = { "PointLight", "SpotLight", "SurfaceLight" }
local CLOTHES  = { "Shirt", "Pants", "ShirtGraphic" }

-- Свойства, которые нельзя менять на лету: для них не используем sethiddenproperty,
-- иначе движок спамит "Cannot change ... during Run-Time"
local NO_HIDDEN = { RenderFidelity = true }

-- ================== СОСТОЯНИЕ ==================
local alive, active = true, false
local connections = {}

local saved     = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = исходное значение }
local processed = setmetatable({}, { __mode = "k" })
local enforced  = setmetatable({}, { __mode = "k" })
local removed   = {}   -- { obj, parent } снятые объекты
local envSaved  = {}   -- { inst, prop, value, hidden } освещение, террейн, настройки
local failedProps = {} -- ["ClassName.Prop"] = true — свойство у этого класса не меняется, больше не пробуем
local fpsOriginal
local queue, running = {}, false

-- ================== УТИЛИТЫ ==================
local function isAny(obj, list)
    for _, c in ipairs(list) do
        if obj:IsA(c) then return true end
    end
    return false
end

local function setProp(obj, prop, value)
    local key = obj.ClassName .. "." .. prop
    if failedProps[key] then return false end

    local ok = pcall(function() obj[prop] = value end)
    if not ok and sethiddenproperty and not NO_HIDDEN[prop] then
        ok = pcall(sethiddenproperty, obj, prop, value)
    end
    if not ok then
        failedProps[key] = true
    end
    return ok
end

-- поставить значение, запомнив исходное (только при первом изменении и только если запись удалась)
local function setSaved(obj, prop, value)
    local ok, cur = pcall(function() return obj[prop] end)
    if not ok and gethiddenproperty and not NO_HIDDEN[prop] then
        ok, cur = pcall(gethiddenproperty, obj, prop)
    end
    if ok and cur == value then return true end

    if not setProp(obj, prop, value) then return false end

    if ok then
        local s = saved[obj]
        if not s then
            s = {}
            saved[obj] = s
        end
        if s[prop] == nil then s[prop] = cur end
    end
    return true
end

-- то же для не-объектов мира (Lighting, Terrain, settings)
local function keepProp(inst, prop, value, hidden)
    local ok, cur
    if hidden and gethiddenproperty then
        ok, cur = pcall(gethiddenproperty, inst, prop)
    else
        ok, cur = pcall(function() return inst[prop] end)
    end
    if ok then envSaved[#envSaved + 1] = { inst, prop, cur, hidden } end

    if hidden then
        if sethiddenproperty then pcall(sethiddenproperty, inst, prop, value) end
    else
        pcall(function() inst[prop] = value end)
    end
end

-- Безопасное снятие (не уничтожение): защищённые классы не трогает никогда
local function detach(obj)
    if isAny(obj, PROTECTED) then return end
    if obj:FindFirstChildWhichIsA("BasePart", true) then return end -- внутри есть парты — не трогаем
    local parent = obj.Parent
    if not parent then return end
    removed[#removed + 1] = { obj = obj, parent = parent }
    pcall(function() obj.Parent = nil end)
end

local function isCoin(obj)
    return coinsFolder ~= nil and obj:IsDescendantOf(coinsFolder)
end

local function isMyCharacter(obj)
    local char = LocalPlayer and LocalPlayer.Character
    return char ~= nil and obj:IsDescendantOf(char)
end

-- Быстрая проверка персонажа другого игрока (без цикла по всем игрокам)
local function getOtherPlayerOf(obj)
    local model = obj:FindFirstAncestorOfClass("Model")
    while model do
        local plr = Players:GetPlayerFromCharacter(model)
        if plr then return plr ~= LocalPlayer and plr or nil end
        model = model:FindFirstAncestorOfClass("Model")
    end
    return nil
end

local function shouldClearMesh(obj)
    return CFG.MESHID_MODE == "all" or (CFG.MESHID_MODE == "coins" and isCoin(obj))
end

-- Не даём игре вернуть текстуры/меши (пока анти-лаг включён)
local function enforce(obj, prop)
    if not CFG.ENFORCE then return end
    local e = enforced[obj]
    if not e then
        e = {}
        enforced[obj] = e
    end
    if e[prop] then return end
    e[prop] = true

    pcall(function()
        local conn = obj:GetPropertyChangedSignal(prop):Connect(function()
            if not (alive and active) then return end
            local cur = obj[prop]
            if cur ~= "" then
                local s = saved[obj]
                if s then s[prop] = cur end -- игра поставила новое значение: к нему и откатимся
                setProp(obj, prop, "")
            end
        end)
        connections[#connections + 1] = conn -- чтобы отключалось при выгрузке
    end)
end

-- ================== ОПТИМИЗАЦИЯ ОБЪЕКТОВ ==================
local function stripMeshPart(part)
    if CFG.CLEAR_TEXTURES then
        setSaved(part, "TextureID", "")
        enforce(part, "TextureID")
    end
    if shouldClearMesh(part) then
        setSaved(part, "MeshId", "")
        enforce(part, "MeshId")
    end
    -- RenderFidelity только у настоящих MeshPart (у юнионов/SolidModel нельзя менять на лету)
    if part.ClassName == "MeshPart" then
        setSaved(part, "RenderFidelity", Enum.RenderFidelity.Performance)
    end
    if CFG.SIMPLE_PHYSICS then
        setSaved(part, "CollisionFidelity", Enum.CollisionFidelity.Box)
    end
end

local function stripPart(part, coin)
    if part:IsA("Terrain") then return end
    local isMesh = part.ClassName == "MeshPart"

    if not processed[part] then
        processed[part] = true
        setSaved(part, "CastShadow", false)
        setSaved(part, "Reflectance", 0)
        setSaved(part, "Material", Enum.Material.SmoothPlastic)
        setSaved(part, "MaterialVariant", "")
        if isMesh then
            stripMeshPart(part)
        elseif CFG.SIMPLE_PHYSICS and part:IsA("PartOperation") then
            setSaved(part, "CollisionFidelity", Enum.CollisionFidelity.Box)
        end
    end

    if ((isMesh or part:IsA("PartOperation")) and CFG.HIDE_ALL_MESHES) or (coin and CFG.HIDE_COINS) then
        setSaved(part, "LocalTransparencyModifier", 1)
        setSaved(part, "Transparency", 1)
    end
end

local function disableGui(obj)
    if obj:IsA("LayerCollector") then
        setSaved(obj, "Enabled", false)
    else
        setSaved(obj, "Visible", false)
    end
end

local function optimize(obj)
    if isMyCharacter(obj) then return end

    -- Парты: только визуал
    if obj:IsA("BasePart") then
        stripPart(obj, isCoin(obj))
        return
    end

    -- GUI в мире и 3D-адорнменты
    if obj:IsA("LayerCollector") or obj:IsA("GuiBase3d") then
        if CFG.DISABLE_GUI then disableGui(obj) end
        return
    end

    -- SpecialMesh / FileMesh
    if obj:IsA("FileMesh") then
        if CFG.CLEAR_TEXTURES then
            setSaved(obj, "TextureId", "")
            enforce(obj, "TextureId")
        end
        if shouldClearMesh(obj) then
            setSaved(obj, "MeshId", "")
            enforce(obj, "MeshId")
        end
        return
    end

    if CFG.REMOVE_EFFECTS and isAny(obj, EFFECTS) then
        setSaved(obj, "Enabled", false)
        if obj:IsA("ParticleEmitter") then pcall(function() obj:Clear() end) end
    elseif obj:IsA("Explosion") then
        setSaved(obj, "Visible", false)
    elseif obj:IsA("ForceField") and getOtherPlayerOf(obj) then
        setSaved(obj, "Visible", false)
    elseif CFG.REMOVE_LIGHTS and isAny(obj, LIGHTS) then
        setSaved(obj, "Enabled", false)
        setSaved(obj, "Shadows", false)
    elseif CFG.REMOVE_DECALS and obj:IsA("Decal") then -- Texture тоже наследует Decal
        setSaved(obj, "Transparency", 1)
    elseif CFG.REMOVE_SURFACE_APPEARANCE and obj:IsA("SurfaceAppearance") then
        detach(obj)
    elseif CFG.REMOVE_CLOTHING and getOtherPlayerOf(obj) then
        if isAny(obj, CLOTHES) then
            detach(obj)
        end
        -- Аксессуары не снимаем (внутри Handle-парт), они станут прозрачными через Handle ниже
    elseif CFG.MUTE_SOUNDS and obj:IsA("Sound") then
        setSaved(obj, "Volume", 0)
    end
end

-- Прятать аксессуары других игроков (Handle — это парт)
local function hideAccessoryHandle(obj)
    if CFG.REMOVE_CLOTHING and obj:IsA("BasePart") and obj.Parent and obj.Parent:IsA("Accessory")
        and getOtherPlayerOf(obj) then
        setSaved(obj, "LocalTransparencyModifier", 1)
    end
end

local function handle(obj)
    if not (alive and active) then return end
    if obj.Parent then
        pcall(optimize, obj)
        pcall(hideAccessoryHandle, obj)
    end
end

-- ================== ОСВЕЩЕНИЕ ==================
local function fixLighting(v)
    if v:IsA("PostEffect") then
        setSaved(v, "Enabled", false)  -- Bloom, Blur, ColorCorrection, SunRays, DoF
    elseif v:IsA("Clouds") then
        setSaved(v, "Enabled", false)
    elseif v:IsA("Atmosphere") then
        setSaved(v, "Density", 0)
        setSaved(v, "Haze", 0)
        setSaved(v, "Glare", 0)
    end
end

local function applyLighting()
    if CFG.LIGHTING_OPT then
        keepProp(Lighting, "GlobalShadows", false)
        keepProp(Lighting, "FogEnd", 9e9)
        keepProp(Lighting, "FogStart", 9e9)
        keepProp(Lighting, "Brightness", 2)
        keepProp(Lighting, "EnvironmentDiffuseScale", 0)
        keepProp(Lighting, "EnvironmentSpecularScale", 0)
        keepProp(Lighting, "ShadowSoftness", 0)
        keepProp(Lighting, "Technology", Enum.Technology.Compatibility, true)

        for _, v in ipairs(Lighting:GetDescendants()) do fixLighting(v) end
        local cam = workspace.CurrentCamera
        if cam then
            for _, v in ipairs(cam:GetChildren()) do fixLighting(v) end
        end

        local okR, rendering = pcall(function() return settings().Rendering end)
        if okR and rendering then
            keepProp(rendering, "QualityLevel", Enum.QualityLevel.Level01)
            keepProp(rendering, "MeshPartDetailLevel", Enum.MeshPartDetailLevel.Level04)
        end

        local t = workspace.Terrain
        keepProp(t, "Decoration", false)
        keepProp(t, "WaterWaveSize", 0)
        keepProp(t, "WaterWaveSpeed", 0)
        keepProp(t, "WaterReflectance", 0)
        keepProp(t, "WaterTransparency", 1)
    end

    if CFG.FPS_CAP and setfpscap then
        if getfpscap and not fpsOriginal then
            pcall(function() fpsOriginal = getfpscap() end)
        end
        pcall(setfpscap, CFG.FPS_CAP)
    end
end

-- ================== ОТКАТ ==================
-- sync = true: без пауз между кадрами (используется при выгрузке скрипта)
local function revertAll(sync)
    -- свойства объектов
    local list = {}
    for obj in pairs(saved) do list[#list + 1] = obj end
    for i, obj in ipairs(list) do
        local props = saved[obj]
        if props then
            saved[obj] = nil
            if obj.Parent then
                for prop, val in pairs(props) do setProp(obj, prop, val) end
            end
        end
        if not sync and i % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
    end

    -- снятые объекты (SurfaceAppearance, одежда)
    for i = #removed, 1, -1 do
        local r = removed[i]
        removed[i] = nil
        if r.parent and r.parent.Parent then
            pcall(function() r.obj.Parent = r.parent end)
        end
    end

    -- освещение, террейн, настройки (в обратном порядке)
    for i = #envSaved, 1, -1 do
        local e = envSaved[i]
        local inst, prop, val, hidden = e[1], e[2], e[3], e[4]
        if hidden then
            if sethiddenproperty then pcall(sethiddenproperty, inst, prop, val) end
        else
            pcall(function() inst[prop] = val end)
        end
    end
    table.clear(envSaved)

    if fpsOriginal and setfpscap then
        pcall(setfpscap, fpsOriginal)
    end
    fpsOriginal = nil

    table.clear(processed)
    table.clear(queue)
end

-- ================== ПОДКЛЮЧЕНИЯ ==================
if CFG.LIGHTING_OPT then
    connections[#connections + 1] = Lighting.DescendantAdded:Connect(function(v)
        if alive and active then task.defer(fixLighting, v) end
    end)

    -- Эффекты на камере (Blur и т.п. иногда кладут туда)
    local cam = workspace.CurrentCamera
    if cam then
        connections[#connections + 1] = cam.ChildAdded:Connect(function(v)
            if alive and active then task.defer(fixLighting, v) end
        end)
    end
end

-- Новые объекты (с очередью, чтобы не лагало при массовом спавне)
connections[#connections + 1] = workspace.DescendantAdded:Connect(function(obj)
    if not (alive and active) then return end
    table.insert(queue, obj)
    if running then return end
    running = true
    task.defer(function()
        local n = 0
        while #queue > 0 and alive and active do
            handle(table.remove(queue))
            n += 1
            if n % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
        end
        running = false
    end)
end)

-- Если игра возвращает видимость монетам — прячем снова
task.spawn(function()
    while alive do
        task.wait(CFG.RECHECK_DELAY)
        if active and CFG.HIDE_COINS and coinsFolder then
            local n = 0
            for _, obj in ipairs(coinsFolder:GetDescendants()) do
                if not (alive and active) then break end
                if obj:IsA("BasePart") and obj.Transparency ~= 1 then
                    pcall(stripPart, obj, true)
                end
                n += 1
                if n % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
            end
        end
    end
end)

-- ================== ПЕРЕКЛЮЧАТЕЛЬ ==================
local function scan()
    local list = workspace:GetDescendants()
    for i, obj in ipairs(list) do
        if not (alive and enabled()) then return end
        handle(obj)
        if i % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
    end
end

task.spawn(function()
    while alive do
        local want = enabled()
        if want and not active then
            active = true
            applyLighting()
            scan()
        elseif not want and active then
            active = false
            revertAll(false)
        end
        task.wait(0.2)
    end
end)

-- ================== ВЫГРУЗКА ==================
_G[CLEANUP] = function()
    alive = false
    active = false
    for _, c in ipairs(connections) do c:Disconnect() end
    table.clear(connections)
    revertAll(true)
end
