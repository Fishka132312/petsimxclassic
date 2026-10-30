--------------------------------------------------------------------------------111212121
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	LocationAttr = "Area",
	IdAttr       = "ID",
	OwnerAttr    = "Owner",

	PetsPerCoin  = 3,    -- сколько петов на одну монету
	LoopInterval = 1.0,  -- как часто назначать свободных петов
	HitInterval  = 0.5,  -- как часто слать удары (FireServer)
	SendDelay    = 0.05,
	StuckTimeout = 10,
	Debug        = false,
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

if _G.PetTools and _G.PetTools.AutoFarm then
	_G.PetTools.AutoFarm.Stop()
end

local warned = {}
local function warnOnce(key, text)
	if not warned[key] then
		warned[key] = true
		warn(text)
	end
end

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Pets Farm", Text = text, Duration = 6 })
	end)
end

local function getByPath(root, path)
	local cur = root
	for _, name in ipairs(path) do
		cur = cur:WaitForChild(name, 5)
		if not cur then
			warn("[Pets] Не найден '" .. name .. "' (путь: " .. table.concat(path, ".") .. ")")
			return nil
		end
	end
	return cur
end

local CoinsFolder = getByPath(Workspace, CONFIG.CoinsPath)
local PetsFolder = getByPath(Workspace, CONFIG.PetsPath)
if not CoinsFolder then return end

local function getPos(coin)
	local p = coin:FindFirstChild("POS") or coin:FindFirstChild("Coin")
	if p and p:IsA("BasePart") then return p.Position end
	return Vector3.zero
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

--------------------------------------------------------------------------------
-- 0. ЗАПОМИНАЕМ РЕМОУТЫ ПО РУЧНОМУ КЛИКУ
-- В ReplicatedStorage десятки ремоутов с одинаковыми именами, поэтому ищем
-- не по имени, а ловим сам объект из настоящего вызова игры.
--   _G.PetRF: RemoteFunction, InvokeServer("монета", {id петов})
--   _G.PetRE: RemoteEvent,    FireServer("монета", "id пета")
--------------------------------------------------------------------------------
if not _G.PetsHooked then
	if hookmetamethod and getnamecallmethod and newcclosure then
		_G.PetsHooked = true
		local old
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if (method == "InvokeServer" or method == "FireServer")
				and not (_G.PetRF and _G.PetRE)
				and not checkcaller()
			then
				local a, b = ...
				local n = select("#", ...)
				if typeof(self) == "Instance" and type(a) == "string" and tonumber(a) then
					if method == "InvokeServer" and not _G.PetRF
						and type(b) == "table" and type(b[1]) == "string"
						and string.sub(b[1], 1, 2) == "id"
					then
						_G.PetRF = self
						task.defer(print, "[Pets] RemoteFunction запомнен")
					elseif method == "FireServer" and not _G.PetRE
						and n == 2 and type(b) == "string"
						and string.sub(b, 1, 2) == "id"
					then
						_G.PetRE = self
						task.defer(print, "[Pets] RemoteEvent запомнен")
					end
					if _G.PetRF and _G.PetRE then
						task.defer(notify, "Remotes saved, farm is ready")
					end
				end
			end
			return old(self, ...)
		end))
	else
		warn("[Pets] Экзекутор не поддерживает hookmetamethod/newcclosure")
	end
end

local function remotesReady()
	local rf, re = _G.PetRF, _G.PetRE
	if rf and re and rf.Parent and re.Parent then
		return true
	end
	if not warned.learn then
		warned.learn = true
		warn("[Pets] Кликни вручную по монете и подожди пару секунд, пока петы начнут бить")
		notify("Click a coin once and wait a few seconds")
	end
	return false
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
--------------------------------------------------------------------------------
local CoinManager = { AllCoins = {} }

for _, c in ipairs(CoinsFolder:GetChildren()) do
	CoinManager.AllCoins[c] = true
end
CoinsFolder.ChildAdded:Connect(function(c) CoinManager.AllCoins[c] = true end)
CoinsFolder.ChildRemoved:Connect(function(c) CoinManager.AllCoins[c] = nil end)

local function coinLocation(coin)
	return tostring(coin:GetAttribute(CONFIG.LocationAttr) or "Unknown")
end

function CoinManager.GetLocationNames()
	local set, names = {}, {}
	for coin in pairs(CoinManager.AllCoins) do
		local loc = coinLocation(coin)
		if not set[loc] then
			set[loc] = true
			table.insert(names, loc)
		end
	end
	table.sort(names)
	return names
end

function CoinManager.GetCoins(locations, origin)
	local filter
	if type(locations) == "string" then
		filter = { [locations] = true }
	elseif type(locations) == "table" then
		filter = {}
		for _, name in ipairs(locations) do filter[name] = true end
	end

	local list = {}
	for coin in pairs(CoinManager.AllCoins) do
		if coin.Parent
			and coin:GetAttribute("HasLanded") ~= false
			and coin:GetAttribute("IsFalling") ~= true
			and (not filter or filter[coinLocation(coin)])
		then
			table.insert(list, coin)
		end
	end

	if origin then
		table.sort(list, function(a, b)
			return (getPos(a) - origin).Magnitude < (getPos(b) - origin).Magnitude
		end)
	end
	return list
end

--------------------------------------------------------------------------------
-- 2. ПЕТЫ
--------------------------------------------------------------------------------
local function GetEquippedPetIds()
	local ids = {}
	if not PetsFolder then return ids end
	for _, pet in ipairs(PetsFolder:GetChildren()) do
		if pet:GetAttribute(CONFIG.OwnerAttr) == LocalPlayer.Name then
			local id = pet:GetAttribute(CONFIG.IdAttr)
			if id then table.insert(ids, tostring(id)) end
		end
	end
	return ids
end

local function chunk(list, size)
	local groups = {}
	for i = 1, #list, size do
		local g = {}
		for j = i, math.min(i + size - 1, #list) do g[#g + 1] = list[j] end
		groups[#groups + 1] = g
	end
	return groups
end

-- [coin] = { id = coinId, pets = {...}, lastHealth, lastProgress }
local assignments = {}

-- Назначаем группу петов на монету (RemoteFunction)
local function assignGroup(coin, petIds)
	if not coin.Parent or #petIds == 0 then return false end
	if not remotesReady() then return false end

	local coinId = tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name)
	local RF = _G.PetRF

	task.spawn(function()
		local ok, res = pcall(function()
			return RF:InvokeServer(coinId, petIds)
		end)
		local accepted = 0
		if ok and type(res) == "table" then
			for _, v in pairs(res) do
				if v == true then accepted += 1 end
			end
		end
		if CONFIG.Debug then
			print(string.format("[Pets] монета %s, петов %d -> ok=%s принято=%d",
				coinId, #petIds, tostring(ok), accepted))
		end
		if not ok or accepted == 0 then
			assignments[coin] = nil
		end
	end)
	return true
end

-- Удары: FireServer(coinId, petId) для каждого назначенного пета
local function hitAll()
	local RE = _G.PetRE
	if not RE or not RE.Parent then return end
	for coin, a in pairs(assignments) do
		if coin.Parent then
			for _, petId in ipairs(a.pets) do
				RE:FireServer(a.id, petId)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 3. УПРАВЛЕНИЕ ПЕТАМИ
--------------------------------------------------------------------------------
local PetController = {}

function PetController.Reset()
	assignments = {}
end

function PetController.Distribute(locations)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end

	local now = os.clock()
	local busy = {}
	for coin, a in pairs(assignments) do
		if not coin.Parent then
			assignments[coin] = nil
		else
			local hp = coin:GetAttribute("Health")
			if hp ~= a.lastHealth then
				a.lastHealth = hp
				a.lastProgress = now
			end
			if hp ~= nil and now - a.lastProgress > CONFIG.StuckTimeout then
				assignments[coin] = nil
			else
				for _, id in ipairs(a.pets) do busy[id] = true end
			end
		end
	end

	local free = {}
	for _, id in ipairs(ids) do
		if not busy[id] then free[#free + 1] = id end
	end
	if #free == 0 then return end

	local targets = {}
	for _, coin in ipairs(CoinManager.GetCoins(locations, getRootPos())) do
		if not assignments[coin] then targets[#targets + 1] = coin end
	end
	if #targets == 0 then return end

	for i, group in ipairs(chunk(free, math.max(1, CONFIG.PetsPerCoin))) do
		local coin = targets[i]
		if not coin then break end
		assignments[coin] = {
			id = tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name),
			pets = group,
			lastHealth = coin:GetAttribute("Health"),
			lastProgress = now,
		}
		if not assignGroup(coin, group) then
			assignments[coin] = nil
		end
		task.wait(CONFIG.SendDelay)
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil }

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locations
	PetController.Reset()
	warned.learn = nil

	-- цикл назначения петов
	task.spawn(function()
		while AutoFarm.Enabled do
			local ok, err = pcall(PetController.Distribute, AutoFarm.Location)
			if not ok then warn("[Pets] Ошибка в цикле: " .. tostring(err)) end
			task.wait(CONFIG.LoopInterval)
		end
	end)

	-- цикл ударов
	task.spawn(function()
		while AutoFarm.Enabled do
			local ok, err = pcall(hitAll)
			if not ok then warn("[Pets] Ошибка ударов: " .. tostring(err)) end
			task.wait(CONFIG.HitInterval)
		end
	end)
end

function AutoFarm.Stop()
	AutoFarm.Enabled = false
end

_G.PetTools = {
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
}

print("[Pets] Готово. Один раз кликни по монете вручную, дождись 'RemoteFunction запомнен' и 'RemoteEvent запомнен'")
