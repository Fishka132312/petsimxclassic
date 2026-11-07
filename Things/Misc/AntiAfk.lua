--[[
    Анти-лаг (локальный)
    Главное правило: НИЧЕГО структурного не удаляется.
    BasePart / Model / Folder / скрипты / Humanoid и т.п. никогда не уничтожаются —
    эффекты, свет, GUI отключаются через Enabled/Visible/Transparency, а не Destroy.
]]

local Players     = game:GetService("Players")
local Lighting    = game:GetService("Lighting")
local RunService  = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- ================== НАСТРОЙКИ ==================
local CFG = {
    MESHID_MODE      = "all",   -- "all" = у всех мешпартов, "coins" = только у монет, "off" = не трогать MeshId
    CLEAR_TEXTURES   = true,    -- убрать TextureID у MeshPart и TextureId у SpecialMesh
    ENFORCE          = true,    -- если игра вернёт TextureID/MeshId — снова очистить
    HIDE_COINS       = true,    -- монеты невидимые (парты остаются)
    HIDE_ALL_MESHES  = false,   -- все мешпарты невидимые (максимум FPS, карту не видно)
    DISABLE_GUI      = true,    -- BillboardGui/SurfaceGui в мире выключаются (НЕ удаляются)
    REMOVE_EFFECTS   = true,    -- частицы, трейлы, лучи, огонь, дым, Highlight -> выключаются
    REMOVE_LIGHTS    = true,    -- PointLight/SpotLight/SurfaceLight -> выключаются
    REMOVE_DECALS    = true,    -- Decal/Texture -> прозрачные
    REMOVE_SURFACE_APPEARANCE = true, -- SurfaceAppearance (PBR) — единственное, что удаляется (выключить нельзя)
    REMOVE_CLOTHING  = false,   -- одежда/аксессуары других игроков (аксессуары -> прозрачные)
    MUTE_SOUNDS      = false,   -- звуки в workspace -> громкость 0 (не останавливаются)
    SIMPLE_PHYSICS   = false,   -- CollisionFidelity = Box (может поменять коллизию локально)
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

-- Классы, которые НИКОГДА не уничтожаются
local PROTECTED = { "BasePart", "Model", "Folder", "LuaSourceContainer", "Humanoid",
    "Attachment", "Constraint", "JointInstance", "ValueBase", "Camera", "Terrain" }

local EFFECTS  = { "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "Highlight" }
local LIGHTS   = { "PointLight", "SpotLight", "SurfaceLight" }
local CLOTHES  = { "Shirt", "Pants", "ShirtGraphic" }

local processed = setmetatable({}, { __mode = "k" })

local function isAny(obj, list)
    for _, c in ipairs(list) do
        if obj:IsA(c) then return true end
    end
    return false
end

-- Безопасное удаление: защищённые классы не трогает никогда
local function safeDestroy(obj)
    if isAny(obj, PROTECTED) then return end
    if obj:FindFirstChildWhichIsA("BasePart", true) then return end -- внутри есть парты — не трогаем
    pcall(function() obj:Destroy() end)
end

local function setProp(obj, prop, value)
    local ok = pcall(function() obj[prop] = value end)
    if not ok and sethiddenproperty then
        ok = pcall(sethiddenproperty, obj, prop, value)
    end
    return ok
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

-- Не даём игре вернуть текстуры/меши
local function enforce(obj, prop)
    if not CFG.ENFORCE then return end
    pcall(function()
        obj:GetPropertyChangedSignal(prop):Connect(function()
            if obj[prop] ~= "" then setProp(obj, prop, "") end
        end)
    end)
end

local function stripMeshPart(part)
    if CFG.CLEAR_TEXTURES then
        setProp(part, "TextureID", "")
        enforce(part, "TextureID")
    end
    if shouldClearMesh(part) then
        setProp(part, "MeshId", "")
        enforce(part, "MeshId")
    end
    pcall(function() part.RenderFidelity = Enum.RenderFidelity.Performance end)
    if CFG.SIMPLE_PHYSICS then
        pcall(function() part.CollisionFidelity = Enum.CollisionFidelity.Box end)
    end
end

local function stripPart(part, coin)
    local isMesh = part:IsA("MeshPart")

    if not processed[part] then
        processed[part] = true
        pcall(function() part.CastShadow = false end)
        pcall(function() part.Reflectance = 0 end)
        pcall(function() part.Material = Enum.Material.SmoothPlastic end)
        pcall(function() part.MaterialVariant = "" end)
        if isMesh then stripMeshPart(part) end
    end

    if (isMesh and CFG.HIDE_ALL_MESHES) or (coin and CFG.HIDE_COINS) then
        pcall(function() part.LocalTransparencyModifier = 1 end)
        pcall(function() part.Transparency = 1 end)
    end
end

local function disableGui(obj)
    if obj:IsA("LayerCollector") then
        pcall(function() obj.Enabled = false end)
    else
        pcall(function() obj.Visible = false end)
    end
end

local function optimize(obj)
    if isMyCharacter(obj) then return end

    -- Парты: только визуал, никогда не удаляются
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
            setProp(obj, "TextureId", "")
            enforce(obj, "TextureId")
        end
        if shouldClearMesh(obj) then
            setProp(obj, "MeshId", "")
            enforce(obj, "MeshId")
        end
        return
    end

    if CFG.REMOVE_EFFECTS and isAny(obj, EFFECTS) then
        pcall(function() obj.Enabled = false end)
        if obj:IsA("ParticleEmitter") then pcall(function() obj:Clear() end) end
    elseif obj:IsA("Explosion") then
        pcall(function() obj.Visible = false end)
    elseif obj:IsA("ForceField") and getOtherPlayerOf(obj) then
        pcall(function() obj.Visible = false end)
    elseif CFG.REMOVE_LIGHTS and isAny(obj, LIGHTS) then
        pcall(function() obj.Enabled = false end)
        pcall(function() obj.Shadows = false end)
    elseif CFG.REMOVE_DECALS and (obj:IsA("Decal")) then -- Texture тоже наследует Decal
        pcall(function() obj.Transparency = 1 end)
    elseif CFG.REMOVE_SURFACE_APPEARANCE and obj:IsA("SurfaceAppearance") then
        safeDestroy(obj)
    elseif CFG.REMOVE_CLOTHING and getOtherPlayerOf(obj) then
        if isAny(obj, CLOTHES) then
            safeDestroy(obj)
        end
        -- Аксессуары не удаляем (внутри Handle-парт), они уже станут прозрачными через Handle ниже
    elseif CFG.MUTE_SOUNDS and obj:IsA("Sound") then
        pcall(function() obj.Volume = 0 end)
    end
end

-- Прятать аксессуары других игроков (Handle — это парт, его не удаляем)
local function hideAccessoryHandle(obj)
    if CFG.REMOVE_CLOTHING and obj:IsA("BasePart") and obj.Parent and obj.Parent:IsA("Accessory")
        and getOtherPlayerOf(obj) then
        pcall(function() obj.LocalTransparencyModifier = 1 end)
    end
end

-- ================== ОСВЕЩЕНИЕ ==================
if CFG.LIGHTING_OPT then
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 9e9
        Lighting.FogStart = 9e9
        Lighting.Brightness = 2
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.ShadowSoftness = 0
    end)
    if sethiddenproperty then
        pcall(sethiddenproperty, Lighting, "Technology", Enum.Technology.Compatibility)
    end

    local function fixLighting(v)
        if v:IsA("PostEffect") then
            pcall(function() v.Enabled = false end)  -- Bloom, Blur, ColorCorrection, SunRays, DoF
        elseif v:IsA("Clouds") then
            pcall(function() v.Enabled = false end)
        elseif v:IsA("Atmosphere") then
            pcall(function() v.Density = 0; v.Haze = 0; v.Glare = 0 end)
        end
    end
    for _, v in ipairs(Lighting:GetDescendants()) do fixLighting(v) end
    Lighting.DescendantAdded:Connect(function(v) task.defer(fixLighting, v) end)

    -- Эффекты на камере (Blur и т.п. иногда кладут туда)
    local cam = workspace.CurrentCamera
    if cam then
        for _, v in ipairs(cam:GetChildren()) do fixLighting(v) end
        cam.ChildAdded:Connect(function(v) task.defer(fixLighting, v) end)
    end

    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level04 end)
    pcall(function()
        local t = workspace.Terrain
        t.Decoration = false
        t.WaterWaveSize = 0
        t.WaterWaveSpeed = 0
        t.WaterReflectance = 0
        t.WaterTransparency = 1
    end)
end

if CFG.FPS_CAP and setfpscap then
    pcall(setfpscap, CFG.FPS_CAP)
end

-- ================== ЗАПУСК ==================
local function handle(obj)
    if obj.Parent then
        pcall(optimize, obj)
        pcall(hideAccessoryHandle, obj)
    end
end

task.spawn(function()
    local list = workspace:GetDescendants()
    for i, obj in ipairs(list) do
        handle(obj)
        if i % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
    end
end)

-- Новые объекты (с очередью, чтобы не лагало при массовом спавне)
local queue, running = {}, false
workspace.DescendantAdded:Connect(function(obj)
    table.insert(queue, obj)
    if running then return end
    running = true
    task.defer(function()
        local n = 0
        while #queue > 0 do
            handle(table.remove(queue))
            n += 1
            if n % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
        end
        running = false
    end)
end)

-- Если игра возвращает видимость монетам — прячем снова
if CFG.HIDE_COINS and coinsFolder then
    task.spawn(function()
        while task.wait(CFG.RECHECK_DELAY) do
            local n = 0
            for _, obj in ipairs(coinsFolder:GetDescendants()) do
                if obj:IsA("BasePart") and obj.Transparency ~= 1 then
                    pcall(stripPart, obj, true)
                end
                n += 1
                if n % CFG.BATCH == 0 then RunService.Heartbeat:Wait() end
            end
        end
    end)
end
