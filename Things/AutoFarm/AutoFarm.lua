--------------------------------------------------------------------------------
-- КОНФИГ: ВСЁ, ЧТО НАДО ПОДОГНАТЬ ПОД ИГРУ, ТОЛЬКО ЗДЕСЬ
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsFolderName     = "Coins",
	LocationsFolderName = "Locations",
	RemotesFolderName   = "Remotes",
	RemoteName          = "SendPetToCoin", -- проверь в декомпиле!

	-- Что отправлять в FireServer: "instance" (сам объект) или "id" (имя/UID)
	PetArgMode  = "instance",
	CoinArgMode = "instance",

	-- Атрибут с UID пета/монеты (если PetArgMode/CoinArgMode = "id").
	-- Если атрибута нет, будет использовано Name.
	PetIdAttribute  = "UID",
	CoinIdAttribute = "Id",

	SendDelay    = 0.05, -- пауза между отправками (защита от рейт-лимита)
	LoopInterval = 1.5,  -- как часто автофарм пересчитывает цели
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- WaitForChild с таймаутом, чтобы скрипт не висел вечно, если имя неверное
local function waitFor(parent, name, timeout)
	local obj = parent:WaitForChild(name, timeout or 10)
	if not obj then
		warn(string.format("[Pets] Не найден '%s' в %s. Проверь имя в CONFIG.", name, parent:GetFullName()))
	end
	return obj
end

local CoinsFolder = waitFor(Workspace, CONFIG.CoinsFolderName)
local LocationsFolder = Workspace:FindFirstChild(CONFIG.LocationsFolderName) -- необязательная
local Remotes = waitFor(ReplicatedStorage, CONFIG.RemotesFolderName)
local SendPetRemote = Remotes and waitFor(Remotes, CONFIG.RemoteName)

if not CoinsFolder or not SendPetRemote then
	return -- без монет или ремоута скрипт работать не сможет
end

--------------------------------------------------------------------------------
-- УТИЛИТЫ
--------------------------------------------------------------------------------
local function getPos(obj)
	if obj:IsA("Model") then
		return obj:GetPivot().Position
	end
	return obj.Position
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

-- Лежит ли точка внутри части/модели (для определения локации по зонам)
local function isPointInside(container, point)
	local cf, size
	if container:IsA("BasePart") then
		cf, size = container.CFrame, container.Size
	elseif container:IsA("Model") then
		cf, size = container:GetBoundingBox()
	else
		return false
	end
	local rel = cf:PointToObjectSpace(point)
	return math.abs(rel.X) <= size.X / 2
		and math.abs(rel.Y) <= size.Y / 2
		and math.abs(rel.Z) <= size.Z / 2
end

-- Определяем локацию: атрибут -> зона из Locations -> "Unknown"
local function detectLocation(coin)
	local attr = coin:GetAttribute("Location")
	if attr then
		return tostring(attr)
	end

	if LocationsFolder then
		local pos = getPos(coin)
		for _, zone in ipairs(LocationsFolder:GetChildren()) do
			if isPointInside(zone, pos) then
				return zone.Name
			end
		end
	end

	return "Unknown"
end

--------------------------------------------------------------------------------
-- 1. МЕНЕДЖЕР МОНЕТ
--------------------------------------------------------------------------------
local CoinManager = {}
CoinManager.CoinsByLocation = {} -- [locationName] = { [coin] = true }
CoinManager.AllCoins = {}        -- [coin] = locationName

local function registerCoin(coin)
	if not (coin:IsA("BasePart") or coin:IsA("Model")) then return end

	local loc = detectLocation(coin)
	CoinManager.CoinsByLocation[loc] = CoinManager.CoinsByLocation[loc] or {}
	CoinManager.CoinsByLocation[loc][coin] = true
	CoinManager.AllCoins[coin] = loc
end

local function unregisterCoin(coin)
	local loc = CoinManager.AllCoins[coin]
	if loc and CoinManager.CoinsByLocation[loc] then
		CoinManager.CoinsByLocation[loc][coin] = nil
	end
	CoinManager.AllCoins[coin] = nil
end

-- Монеты могут лежать не прямо в папке, а во вложенных папках: берём всех потомков
for _, d in ipairs(CoinsFolder:GetDescendants()) do
	registerCoin(d)
end
CoinsFolder.DescendantAdded:Connect(registerCoin)
CoinsFolder.DescendantRemoving:Connect(unregisterCoin)

-- Список живых монет локации, отсортированный по расстоянию от origin.
-- locationName = nil -> все локации.
function CoinManager.GetCoins(locationName, origin)
	local list = {}
	local function collect(set)
		for coin in pairs(set) do
			if coin.Parent then
				table.insert(list, coin)
			end
		end
	end

	if locationName then
		collect(CoinManager.CoinsByLocation[locationName] or {})
	else
		for _, set in pairs(CoinManager.CoinsByLocation) do
			collect(set)
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
local function GetEquippedPets()
	local pets = {}
	local folder = LocalPlayer:FindFirstChild("EquippedPets")
		or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Pets"))

	if folder then
		for _, pet in ipairs(folder:GetChildren()) do
			table.insert(pets, pet)
		end
	end
	return pets
end

local function toArg(obj, mode, attrName)
	if mode == "id" then
		return obj:GetAttribute(attrName) or obj.Name
	end
	return obj
end

local function fire(pet, coin)
	local petArg = toArg(pet, CONFIG.PetArgMode, CONFIG.PetIdAttribute)
	local coinArg = toArg(coin, CONFIG.CoinArgMode, CONFIG.CoinIdAttribute)

	local ok, err = pcall(function()
		if SendPetRemote:IsA("RemoteFunction") then
			SendPetRemote:InvokeServer(petArg, coinArg)
		else
			SendPetRemote:FireServer(petArg, coinArg)
		end
	end)
	if not ok then
		warn("[Pets] Ошибка отправки: " .. tostring(err))
	end
end

--------------------------------------------------------------------------------
-- 3. УПРАВЛЕНИЕ ПЕТАМИ
--------------------------------------------------------------------------------
local PetController = {}

-- Все петы на одну монету
function PetController.SendAllToOne(coin)
	if not coin or not coin.Parent then
		warn("[Pets] Монета недействительна")
		return
	end
	for _, pet in ipairs(GetEquippedPets()) do
		fire(pet, coin)
		task.wait(CONFIG.SendDelay)
	end
end

-- Каждый пет на свою ближайшую монету (по кругу, если монет меньше, чем петов).
-- locationName = nil -> берём монеты со всех локаций.
function PetController.Distribute(locationName)
	local pets = GetEquippedPets()
	local origin = getRootPos()
	local coins = CoinManager.GetCoins(locationName, origin)

	if #pets == 0 then return end
	if #coins == 0 then
		warn("[Pets] Нет монет" .. (locationName and (" в локации " .. locationName) or ""))
		return
	end

	for i, pet in ipairs(pets) do
		local coin = coins[((i - 1) % #coins) + 1]
		fire(pet, coin)
		task.wait(CONFIG.SendDelay)
	end
end

-- Случайные монеты
function PetController.Random(locationName)
	local pets = GetEquippedPets()
	local coins = CoinManager.GetCoins(locationName, nil)
	if #pets == 0 or #coins == 0 then return end

	for _, pet in ipairs(pets) do
		fire(pet, coins[math.random(1, #coins)])
		task.wait(CONFIG.SendDelay)
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil } -- Location = nil -> все локации

function AutoFarm.Start(locationName)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locationName

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

--------------------------------------------------------------------------------
-- ИСПОЛЬЗОВАНИЕ
--------------------------------------------------------------------------------
-- AutoFarm.Start()          -- фармить везде, ближайшие монеты в приоритете
-- AutoFarm.Start("Forest")  -- только локация Forest
-- AutoFarm.Stop()
-- PetController.SendAllToOne(workspace.Coins.MegaCoin)

-- Доступ из консоли/других скриптов (LocalScript не может return-ить модуль)
_G.PetTools = {
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
}
