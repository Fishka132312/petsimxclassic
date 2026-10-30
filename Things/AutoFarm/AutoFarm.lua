--------------------------------------------------------------------------------1111
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	LocationAttr = "Area",
	IdAttr       = "ID",
	OwnerAttr    = "Owner",

	PetsPerCoin  = 3,
	SendDelay    = 0.05,
	LoopInterval = 1.5,
	StuckTimeout = 8,
	Debug        = false, -- true = печатать каждую отправку в F9
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

-- Если скрипт запущен повторно, останавливаем старый автофарм
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
-- 0. ХУК НА ИГРОВОЙ Network.Invoke
-- Игра шлёт выбор монеты через ReplicatedStorage.Library.Client.Network.Invoke
-- (Game.Pets -> SelectCoin). Скрипт запоминает такой вызов при твоём ручном
-- клике по монете и дальше повторяет его через оригинальную функцию игры.
--------------------------------------------------------------------------------
do
	local okReq, Network = pcall(function()
		return require(ReplicatedStorage.Library.Client.Network)
	end)

	if not okReq then
		warn("[Pets] Не удалось require Network: " .. tostring(Network))
	elseif _G.PetsHooked then
		-- уже захукано при прошлом запуске, _G.PetsPrefix/_G.PetsInvoke сохранились
	elseif not hookfunction then
		warn("[Pets] Экзекутор не поддерживает hookfunction")
	elseif type(Network.Invoke) ~= "function" then
		warn("[Pets] Network.Invoke не является функцией")
	else
		_G.PetsHooked = true
		local orig
		orig = hookfunction(Network.Invoke, function(...)
			if not _G.PetsPrefix then
				-- ВАЖНО: ... можно использовать только здесь, не во вложенной функции
				local args = table.pack(...)
				pcall(function()
					for i = 1, args.n - 1 do
						local a, b = args[i], args[i + 1]
						if type(a) == "string" and tonumber(a)
							and type(b) == "table" and type(b[1]) == "string"
							and string.sub(b[1], 1, 2) == "id"
						then
							-- всё, что стоит перед ID монеты, запоминаем как префикс
							local prefix = { n = i - 1 }
							for j = 1, i - 1 do
								prefix[j] = args[j]
							end
							_G.PetsPrefix = prefix
							task.defer(function()
								print("[Pets] Вызов запомнен (аргументов в префиксе: " .. (i - 1) .. ")")
								notify("Call saved, farm is ready")
							end)
							break
						end
					end
				end)
			end
			return orig(...)
		end)
		_G.PetsInvoke = orig
	end
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
--------------------------------------------------------------------------------
local CoinManager = {}
CoinManager.AllCoins = {}

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
-- 2. ПЕТЫ И ОТПРАВКА
--------------------------------------------------------------------------------
local function GetEquippedPetIds()
	local ids = {}
	local folder = PetsFolder
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

local assignments = {}

-- Один вызов = группа петов на одну монету. true, если вызов отправлен.
local function sendGroup(coin, petIds)
	if not coin or not coin.Parent or #petIds == 0 then return false end

	if not (_G.PetsPrefix and _G.PetsInvoke) then
		if not warned.learn then
			warned.learn = true
			warn("[Pets] Кликни вручную по любой монете один раз, чтобы скрипт запомнил вызов")
			notify("Click any coin once so the script can learn the call")
		end
		return false
	end

	local coinId = tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name)
	local prefix = _G.PetsPrefix
	local args, n = {}, prefix.n
	for i = 1, n do
		args[i] = prefix[i]
	end
	args[n + 1] = coinId
	args[n + 2] = petIds

	task.spawn(function()
		local ok, res = pcall(function()
			return _G.PetsInvoke(table.unpack(args, 1, n + 2))
		end)

		-- сервер отвечает таблицей { [idПета] = true/false }
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

		if not ok then
			warn("[Pets] Ошибка вызова: " .. tostring(res))
			assignments[coin] = nil
		elseif accepted == 0 then
			-- сервер никого не принял: освобождаем петов, попробуем другую монету
			assignments[coin] = nil
		end
	end)
	return true
end

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

function PetController.SendAllToOne(coin)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end
	sendGroup(coin, ids)
end

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
			-- таймаут "застряли" только если у монеты вообще есть Health
			if hp ~= nil and now - a.lastProgress > CONFIG.StuckTimeout then
				assignments[coin] = nil
			else
				for _, id in ipairs(a.pets) do
					busy[id] = true
				end
			end
		end
	end

	local free = {}
	for _, id in ipairs(ids) do
		if not busy[id] then
			free[#free + 1] = id
		end
	end
	if #free == 0 then return end

	local targets = {}
	for _, coin in ipairs(CoinManager.GetCoins(locations, getRootPos())) do
		if not assignments[coin] then
			targets[#targets + 1] = coin
		end
	end
	if #targets == 0 then return end

	for i, group in ipairs(chunk(free, math.max(1, CONFIG.PetsPerCoin))) do
		local coin = targets[i]
		if not coin then break end
		assignments[coin] = {
			pets = group,
			lastHealth = coin:GetAttribute("Health"),
			lastProgress = now,
		}
		if not sendGroup(coin, group) then
			assignments[coin] = nil
		end
		task.wait(CONFIG.SendDelay)
	end
end

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
local AutoFarm = { Enabled = false, Location = nil }

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locations
	PetController.Reset()
	warned.learn = nil

	task.spawn(function()
		while AutoFarm.Enabled do
			local ok, err = pcall(PetController.Distribute, AutoFarm.Location)
			if not ok then
				warn("[Pets] Ошибка в цикле: " .. tostring(err))
			end
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

print("[Pets] Готово. Кликни вручную по любой монете (скрипт запомнит вызов), потом запускай автофарм")
