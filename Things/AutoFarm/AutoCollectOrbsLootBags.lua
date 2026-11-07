-- Magnet v3: авто-подбор орбов и лутбагов.
-- Управление: _G.AutoCollectOrbsLootbags = true / false (можно менять в любой момент)
-- Повторный запуск скрипта сначала полностью выгружает прошлую копию (ничего не накладывается).
-- Оригинальные скрипты Orbs/Lootbags НЕ выключаем: притягиваем орбы/мешки к игроку,
-- оригинал сам шлёт Claim Orbs / Collect Lootbag.

--================ ВЫГРУЗКА ПРОШЛОЙ КОПИИ ================--
if _G.MagnetCleanup then
	pcall(_G.MagnetCleanup)
	_G.MagnetCleanup = nil
end

if _G.AutoCollectOrbsLootbags == nil then
	_G.AutoCollectOrbsLootbags = true -- по умолчанию включено
end

local function enabled()
	return _G.AutoCollectOrbsLootbags and true or false
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
local LocalPlayer = Players.LocalPlayer
while not Library.Loaded do task.wait() end

--================ НАСТРОЙКИ ================--
local HIDE_BAGS        = true   -- делать мешки невидимыми
local MUTE_SOUNDS      = true   -- глушить звуки орбов/мешков
local MUTE_QUEST_GLOW  = true   -- убрать подсветку лутбагов
local MUTE_CURRENCY_FX = true   -- убрать вылетающую валюту (AddCurrency). Внимание: отключается и для остальных источников
local DEBUG            = false  -- печатать статистику в консоль (F9)
--==========================================--
-- Все глушилки действуют только пока AutoCollectOrbsLootbags включена.

local alive = true
local connections = {}
local restoreFns = {}
local stats = { orbs = 0, bags = 0 }

local function connect(signal, fn)
	local c = signal:Connect(fn)
	connections[#connections + 1] = c
	return c
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local JUNK = {
	BillboardGui = true, SurfaceGui = true, ParticleEmitter = true, Trail = true,
	Beam = true, Decal = true, Texture = true, Highlight = true, PointLight = true,
	SpotLight = true, SurfaceLight = true, Fire = true, Smoke = true, Sparkles = true,
	SurfaceAppearance = true,
}

local stripped = setmetatable({}, { __mode = "k" })
local function strip(inst)
	if stripped[inst] then return end
	stripped[inst] = true
	for _, d in ipairs(inst:GetDescendants()) do
		if JUNK[d.ClassName] then d:Destroy() end
	end
end

--================ ПАТЧИ ЭФФЕКТОВ ================--
if MUTE_SOUNDS then
	local blocked = {}
	for _, id in ipairs({
		-- орбы
		"8269454228", "8269454300", "6422183746", "7139322725", "6980747924",
		"7805995973", "7805996163", "6980747874",
		-- лутбаги
		"8049260816", "8049260324", "8049260443", "8068357028", "8167299784",
	}) do
		blocked["rbxassetid://" .. id] = true
	end

	local origPlay = Library.Audio.Play
	local ok = pcall(function()
		Library.Audio.Play = function(sound, ...)
			local first = type(sound) == "table" and sound[1] or sound
			if alive and enabled() and blocked[first] then return end
			return origPlay(sound, ...)
		end
	end)
	if ok then
		restoreFns[#restoreFns + 1] = function() Library.Audio.Play = origPlay end
	else
	end
end

if MUTE_QUEST_GLOW then
	local origGlow = Library.WorldFX.QuestGlow
	local ok = pcall(function()
		Library.WorldFX.QuestGlow = function(obj, ...)
			if alive and enabled() and typeof(obj) == "Instance"
				and obj:IsDescendantOf(Library.Things.Lootbags) then
				return
			end
			return origGlow(obj, ...)
		end
	end)
	if ok then
		restoreFns[#restoreFns + 1] = function() Library.WorldFX.QuestGlow = origGlow end
	end
end

if MUTE_CURRENCY_FX then
	local origCurrency = Library.WorldFX.AddCurrency
	local ok = pcall(function()
		Library.WorldFX.AddCurrency = function(...)
			if alive and enabled() then return end
			return origCurrency(...)
		end
	end)
	if ok then
		restoreFns[#restoreFns + 1] = function() Library.WorldFX.AddCurrency = origCurrency end
	end
end

--================ ПРИТЯГИВАНИЕ ================--
-- tracked[part] = смещение по Y. Каждый кадр ставим парт на игрока,
-- оригинальный цикл видит дистанцию <= 4 и сам собирает.
local tracked = {}
local original = {} -- [part] = { Anchored, CanCollide, Transparency } до наших изменений

local function follow(part, yOff)
	if not original[part] then
		original[part] = {
			Anchored = part.Anchored,
			CanCollide = part.CanCollide,
			Transparency = part.Transparency,
		}
	end
	part.Anchored = true
	part.CanCollide = false
	tracked[part] = yOff
end

-- вернуть партам их исходное состояние (при выключении / выгрузке)
local function releaseAll()
	for part in pairs(tracked) do
		local o = original[part]
		if o and part.Parent then
			part.Anchored = o.Anchored
			part.CanCollide = o.CanCollide
			part.Transparency = o.Transparency
		end
	end
	table.clear(tracked)
	table.clear(original)
end

local wasEnabled = enabled()

connect(RunService.Heartbeat, function()
	local on = enabled()
	if on ~= wasEnabled then
		wasEnabled = on
		if not on then releaseAll() end
	end
	if not on then return end

	local root = getRoot()
	if not root then return end
	local pos = root.Position
	for part, yOff in pairs(tracked) do
		if part.Parent then
			part.CFrame = CFrame.new(pos + Vector3.new(0, yOff, 0))
		else
			tracked[part] = nil
			original[part] = nil
		end
	end
end)

--================ ОРБЫ ================--
local Orbs = Library.Things:WaitForChild("Orbs")

local function onOrb(part)
	if not part:IsA("BasePart") or tracked[part] then return end
	strip(part)
	stats.orbs += 1
	follow(part, -2) -- оригинал меряет дистанцию до pos + (0,2,0)
end

--================ ЛУТБАГИ ================--
local Bags = Library.Things:WaitForChild("Lootbags")
local hooked = setmetatable({}, { __mode = "k" })

local function bagReady(part)
	return part:GetAttribute("ReadyForCollection") and not part:GetAttribute("Collected")
end

local function onBag(part)
	if not part:IsA("BasePart") then return end
	strip(part)

	if not original[part] then
		original[part] = {
			Anchored = part.Anchored,
			CanCollide = part.CanCollide,
			Transparency = part.Transparency,
		}
	end
	if HIDE_BAGS then part.Transparency = 1 end

	local function tryFollow()
		if enabled() and not tracked[part] and bagReady(part) then
			stats.bags += 1
			follow(part, 0)
		end
	end

	if not hooked[part] then
		hooked[part] = true
		connect(part:GetAttributeChangedSignal("ReadyForCollection"), tryFollow)
	end
	tryFollow()
end

--================ ПОДКЛЮЧЕНИЕ И СТРАХОВОЧНЫЙ ЦИКЛ ================--
connect(Orbs.ChildAdded, function(p)
	if enabled() then onOrb(p) end
end)
connect(Bags.ChildAdded, function(p)
	if enabled() then onBag(p) end
end)

-- подхватывает всё, что уже лежало / появилось, пока скрипт был выключен
task.spawn(function()
	while alive do
		if enabled() then
			for _, p in ipairs(Orbs:GetChildren()) do onOrb(p) end
			for _, b in ipairs(Bags:GetChildren()) do
				if b:IsA("BasePart") and not tracked[b] then
					onBag(b)
				end
			end
		end
		task.wait(0.5)
	end
end)

if DEBUG then
	task.spawn(function()
		while alive do
			task.wait(5)
				tostring(enabled()), stats.orbs, stats.bags))
		end
	end)
end

--================ ВЫГРУЗКА ================--
_G.MagnetCleanup = function()
	alive = false
	for _, c in ipairs(connections) do c:Disconnect() end
	table.clear(connections)
	releaseAll()
	for _, fn in ipairs(restoreFns) do pcall(fn) end
	table.clear(restoreFns)
end
