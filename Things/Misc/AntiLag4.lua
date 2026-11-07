--[[
    Anti-Lag 4 — Coin Optimizer with a toggle and rollback.
    1) Coins farther than FAR_DISTANCE studs are moved out of workspace (Parent = nil)
       and returned when you get closer. Not Destroy: otherwise the coin won't come back
       (the original only creates a coin's folder once, on Add Coin).
    2) Removes the heaviest cosmetic stuff: hit/explosion particles, lights and particles
       on the coins themselves, sounds.
    The original Coins script is NOT disabled.

    _G.AntiLag4Enabled = true   -> optimization on
    _G.AntiLag4Enabled = false  -> everything restored (moved-out coins are back in workspace,
                                   effects, sounds and particle templates as they were)

    Re-running the script first unloads the previous copy and rolls back its changes.
]]

-- Name of the toggle variable (each anti-lag has its own)
local FLAG = "AntiLag4Enabled"

local CLEANUP = FLAG .. "_Cleanup"
if _G[CLEANUP] then
    pcall(_G[CLEANUP])
    _G[CLEANUP] = nil
end
if _G[FLAG] == nil then
    _G[FLAG] = false -- off by default. Want it to turn on by itself at launch? Set true
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

--================ SETTINGS ================--
local FAR_DISTANCE         = 999    -- coins farther than this are removed from workspace
local RESTORE_MARGIN       = 50     -- return when closer than FAR_DISTANCE - RESTORE_MARGIN (so they don't flicker at the border)
local CHECK_INTERVAL       = 1      -- how often to check distance (sec)
local DESTROY_FAR          = false  -- true = delete permanently (the coin won't return until world change/rejoin, rollback won't bring it back!)
local DISABLE_COIN_FX      = true   -- disable particles/lights/beams on coin models
local KILL_HIT_PARTICLES   = true   -- remove coin hit/explosion particles (clones of templates from Assets.Particles)
local MUTE_COIN_SOUNDS     = true   -- mute coin hit/fall/destroy sounds
local BATCH                = 300    -- objects per frame during rollback
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

-- ================== STATE ==================
local alive, active = true, false
local sid = 0                -- session number (each enable = a new session)
local conns = {}             -- connections of the current session
local saved = setmetatable({}, { __mode = "k" }) -- [obj] = { [prop] = original value }
local info = {}              -- [id] = { folder, pos, stored }
local nStored = 0
local particleBackup = {}    -- { { template = inst, children = { ... } } }
local audioOrig              -- original Audio.Play

local function track(conn)
    conns[#conns + 1] = conn
    return conn
end

-- ================== PROPERTIES (save / restore) ==================
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

-- ================== SOUNDS ==================
local blocked = {}
for _, id in ipairs({
    6485234572, 6485234808, 6485234993,                                   -- hit
    6422233047, 6422233117, 12151937071, 12151936879, 12151936744,        -- coins
    6422233314, 6422233259, 6422233191, 12151937223,                      -- chests
    6958718789, 6958718747, 7029284027, 11648888186,                      -- safe/vault/special/luckyblock
    6958713639, 6958713793, 6958713747, 6958713692, 9395255388, 12970061125, -- destruction
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

-- ================== HIT PARTICLES ==================
-- CoinDamageAnimation / PetDamageAnimation clone these templates on every hit on a coin.
-- Instead of ClearAllChildren, the template children are temporarily removed (Parent = nil) and returned later.
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
            -- the object stays (the original clones it and calls Emit), but particles don't live
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

-- ================== COINS: DISTANCE CULLING ==================
local FX = { ParticleEmitter = true, Beam = true, Trail = true,
    PointLight = true, SpotLight = true, SurfaceLight = true }

local function register(folder)
    if not folder:IsA("Folder") then return end
    local id = folder.Name
    local c = info[id]
    if c and c.folder == folder then
        -- we returned it ourselves
        if c.stored then c.stored = false; nStored -= 1 end
        return
    end
    local pos = folder:FindFirstChild("POS")
    if not pos then return end
    info[id] = { folder = folder, pos = pos.Position, stored = false }
end

-- return moved-out coins to workspace
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

-- ================== SESSION (one enable) ==================
local function startSession()
    sid += 1
    local id = sid
    local function ok() return alive and active and sid == id end

    -- sounds
    if MUTE_COIN_SOUNDS then patchAudio() end

    -- hit particles (waits for the Assets.Particles folder, hence a separate thread)
    if KILL_HIT_PARTICLES then
        task.spawn(function() pcall(killHitParticles, ok) end)
    end

    -- effects on coin models
    if DISABLE_COIN_FX then
        track(CoinsFolder.DescendantAdded:Connect(function(d)
            if ok() and FX[d.ClassName] then setSaved(d, "Enabled", false) end
        end))
        for _, d in ipairs(CoinsFolder:GetDescendants()) do
            if FX[d.ClassName] then setSaved(d, "Enabled", false) end
        end
    end

    -- distance culling
    info = {}
    nStored = 0
    track(CoinsFolder.ChildAdded:Connect(function(f)
        if ok() then register(f) end
    end))
    for _, f in ipairs(CoinsFolder:GetChildren()) do register(f) end

    -- Coin removed by the server: we destroy the moved-out folder ourselves (the original won't find it in Things.Coins)
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

    -- World change: the original reloads all coins from scratch, we clean up our moved-out ones
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
                            folder.Parent = CoinsFolder -- ChildAdded -> register resets stored
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
                            info[cid] = nil -- the folder was already removed by the original
                        end
                    end
                end
            end
        end
    end)
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

-- ================== TOGGLE ==================
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

-- ================== UNLOAD ==================
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
