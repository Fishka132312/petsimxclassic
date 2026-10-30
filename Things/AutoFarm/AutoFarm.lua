--------------------------------------------------------------------------------
-- КОНФИГ (значения сняты с реальной игры)
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	-- Индекс ремоута в ReplicatedStorage:GetChildren() (из Cobalt).
	-- Если фарм перестал работать, снова сними вызов в Cobalt и поменяй число.
	RemoteIndex = 182,

	LocationAttr = "Area",  -- атрибут монеты с названием локации
	IdAttr       = "ID",    -- атрибут ID у монет и петов
	OwnerAttr    = "Owner", -- атрибут владельца у пета

	PetsPerCoin  = 3,    -- сколько петов отправлять на одну монету
	SendDelay    = 0.05, -- пауза между вызовами
	LoopInterval = 1.5,  -- как часто автофарм пересчитывает цели
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local warned = {}
local function warnOnce(key, text)
	if not warned[key] then
		warned[key] = true
		warn(text)
	end
end

local function getByPath(root, path)
	local cur = root
	for _, name in ipairs(path) do
		cur = cur:WaitForChild(name, 5)
		if not cur then
			warn(string.format("[Pets] Не найден '%s' (путь: %s)", name, table.concat(path, ".")))
			return nil
		end
	end
	return cur
end

local CoinsFolder = getByPath(Workspace, CONFIG.CoinsPath)
local PetsFolder = getByPath(Workspace, CONFIG.PetsPath)

if not CoinsFolder then
	return
end

-- Позиция монеты: часть POS, иначе меш Coin
local function getPos(coin)
	local p = coin:FindFirstChild("POS") or coin:FindFirstChild("Coin")
	if p and p:IsA("BasePart") then
		return p.Position
	end
	if coin:IsA("Model") then
		return coin:GetPivot().Position
	end
	if coin:IsA("BasePart") then
		return coin.Position
	end
	return Vector3.zero
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
-- Атрибуты (Area, HasLanded...) могут проставляться уже после появления монеты,
-- поэтому локацию читаем в момент запроса, а не при регистрации.
--------------------------------------------------------------------------------
local CoinManager = {}
CoinManager.AllCoins = {} -- [coin] = true

local function registerCoin(coin)
	CoinManager.AllCoins[coin] = true
end

local function unregisterCoin(coin)
	CoinManager.AllCoins[coin] = nil
end

for _, c in ipairs(CoinsFolder:GetChildren()) do
	registerCoin(c)
end
CoinsFolder.ChildAdded:Connect(registerCoin)
CoinsFolder.ChildRemoved:Connect(unregisterCoin)

local function coinLocation(coin)
	return tostring(coin:GetAttribute(CONFIG.LocationAttr) or "Unknown")
end

-- Имена всех локаций, где сейчас есть монеты
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

-- Живые монеты, отсортированные по расстоянию от origin.
-- locations: nil (все), строка или список строк.
function CoinManager.GetCoins(locations, origin)
	local filter
	if type(locations) == "string" then
		filter = { [locations] = true }
	elseif type(locations) == "table" then
		filter = {}
		for _, name in ipairs(locations) do
			filter[name] = true
		end
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
-- 2. ПЕТЫ И РЕМОУТ
--------------------------------------------------------------------------------
-- ID моих петов: дети Pets с атрибутом Owner == мой ник
local function GetEquippedPetIds()
	local ids = {}
	local folder = PetsFolder or Workspace:FindFirstChild("__THINGS") and Workspace.__THINGS:FindFirstChild("Pets")
	if not folder then return ids end

	for _, pet in ipairs(folder:GetChildren()) do
		if pet:GetAttribute(CONFIG.OwnerAttr) == LocalPlayer.Name then
			local id = pet:GetAttribute(CONFIG.IdAttr)
			if id then
				table.insert(ids, tostring(id))
			end
		end
	end
	return ids
end

local cachedRemote
local function getRemote()
	if cachedRemote and cachedRemote.Parent then
		return cachedRemote
	end
	local r = ReplicatedStorage:GetChildren()[CONFIG.RemoteIndex]
	if r and r:IsA("RemoteFunction") then
		cachedRemote = r
		return r
	end
	warnOnce("remote", string.format(
		"[Pets] По индексу %d нет RemoteFunction (индекс мог сдвинуться). Сними вызов в Cobalt и обнови CONFIG.RemoteIndex.",
		CONFIG.RemoteIndex
	))
	return nil
end

-- Один вызов = группа петов на одну монету
local function sendGroup(coin, petIds)
	if not coin or not coin.Parent or #petIds == 0 then return end
	local remote = getRemote()
	if not remote then return end

	local coinId = tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name)
	task.spawn(function()
		local ok, err = pcall(function()
			remote:InvokeServer(coinId, petIds)
		end)
		if not ok then
			warn("[Pets] Ошибка вызова: " .. tostring(err))
		end
	end)
end

-- Делит список петов на группы по PetsPerCoin
local function chunk(list, size)
	local groups = {}
	for i = 1, #list, size do
		local g = {}
		for j = i, math.min(i + size - 1, #list) do
			g[#g + 1] = list[j]
		end
		groups[#groups + 1] = g
	end
	return groups
end

--------------------------------------------------------------------------------
-- 3. УПРАВЛЕНИЕ ПЕТАМИ
--------------------------------------------------------------------------------
local PetController = {}

-- Все петы на одну монету
function PetController.SendAllToOne(coin)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end
	sendGroup(coin, ids)
end

-- Группы петов на ближайшие монеты выбранных локаций
function PetController.Distribute(locations)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end

	local coins = CoinManager.GetCoins(locations, getRootPos())
	if #coins == 0 then return end

	local groups = chunk(ids, math.max(1, CONFIG.PetsPerCoin))
	for i, group in ipairs(groups) do
		local coin = coins[((i - 1) % #coins) + 1]
		sendGroup(coin, group)
		task.wait(CONFIG.SendDelay)
	end
end

-- Группы петов на случайные монеты
function PetController.Random(locations)
	local ids = GetEquippedPetIds()
	local coins = CoinManager.GetCoins(locations, nil)
	if #ids == 0 or #coins == 0 then return end

	for _, group in ipairs(chunk(ids, math.max(1, CONFIG.PetsPerCoin))) do
		sendGroup(coins[math.random(1, #coins)], group)
		task.wait(CONFIG.SendDelay)
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil } -- Location: nil / строка / список

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locations

	task.spawn(function()
		while AutoFarm.Enabled do
			PetController.Distribute(AutoFarm.Location)
			task.wait(CONFIG.LoopInterval)
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
