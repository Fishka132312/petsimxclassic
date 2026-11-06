--------------------------------------------------------------------------------
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	TeleportDistance = 10, -- если включён телепорт и ты дальше этого от яйца, телепортируемся к нему
	MaxFailures      = 5,  -- столько неудач подряд (нет денег, нет места и т.д.) -> автооткрытие останавливается
	FailDelay        = 1,  -- пауза после неудачной покупки
	RescanInterval   = 15, -- как часто пересканировать яйца на карте
	Debug            = false,
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

-- Повторный запуск: останавливаем старую версию и гасим её цикл сканирования
if _G.EggTools and _G.EggTools.AutoOpen then
	pcall(_G.EggTools.AutoOpen.Stop)
end
_G.EggToolsGen = (_G.EggToolsGen or 0) + 1
local myGen = _G.EggToolsGen

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Eggs", Text = text, Duration = 6 })
	end)
end

local function log(text)
	if CONFIG.Debug then
		print("[Eggs] " .. text)
	end
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

--------------------------------------------------------------------------------
-- 1. ИГРОВОЙ Network.Invoke
-- Eggs.lua покупает яйцо так: Network.Invoke("Buy Egg", eggId, triple, octuple)
--------------------------------------------------------------------------------
local Lib, Net

local function pickNetwork(m)
	if type(m) ~= "table" then return nil end
	if type(m.Invoke) == "function" then return m end
	local n = m.Network
	if type(n) == "table" and type(n.Invoke) == "function" then return n end
	return nil
end

local function resolveNetwork()
	if Net then return Net end

	local list = {}
	local function add(x)
		if x then list[#list + 1] = x end
	end

	local fw = ReplicatedStorage:FindFirstChild("Framework")
	add(fw and fw:FindFirstChild("Library"))
	local lib = ReplicatedStorage:FindFirstChild("Library")
	add(lib)
	local client = lib and lib:FindFirstChild("Client")
	add(client and client:FindFirstChild("Network"))

	for _, mod in ipairs(list) do
		if mod:IsA("ModuleScript") then
			local ok, res = pcall(require, mod)
			if ok then
				if not Lib and type(res) == "table" and type(res.Variables) == "table" then
					Lib = res
				end
				local net = pickNetwork(res)
				if net then
					Net = net
					return Net
				end
			end
		end
	end
	return nil
end

local function isOpening()
	local v = Lib and Lib.Variables
	return v and (tonumber(v.OpeningEgg) or 0) > 0 or false
end

--------------------------------------------------------------------------------
-- 2. ПОИСК ЯИЦ НА КАРТЕ
-- Яйцо = объект с атрибутом ID (строка), с дочерними Center и PriceHUD.
--------------------------------------------------------------------------------
local eggCache = {} -- [eggId] = { inst, inst, ... }

local function scanEggs()
	local found = {}
	local map = Workspace:FindFirstChild("__MAP")
	local root = map or Workspace
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		n = n + 1
		if n % 3000 == 0 then
			task.wait()
		end
		local id = d:GetAttribute("ID")
		if type(id) == "string" and d:FindFirstChild("Center") and d:FindFirstChild("PriceHUD") then
			local list = found[id]
			if not list then
				list = {}
				found[id] = list
			end
			list[#list + 1] = d
		end
	end
	eggCache = found
end

-- Ближайший к игроку экземпляр яйца: egg, center, distance
local function nearestEgg(eggId)
	local list = eggCache[eggId]
	if not list then return nil end
	local rootPart = getRoot()
	local origin = rootPart and rootPart.Position
	local best, bestCenter, bestDist
	for i = #list, 1, -1 do
		local inst = list[i]
		if not inst.Parent then
			table.remove(list, i)
		else
			local c = inst:FindFirstChild("Center")
			if c and c:IsA("BasePart") then
				local dist = origin and (c.Position - origin).Magnitude or 0
				if not bestDist or dist < bestDist then
					best, bestCenter, bestDist = inst, c, dist
				end
			end
		end
	end
	return best, bestCenter, bestDist
end

--------------------------------------------------------------------------------
-- 3. ОТКРЫТИЕ ЯИЦ
--------------------------------------------------------------------------------
local EggTools = {}

function EggTools.Refresh()
	scanEggs()
end

-- Названия доступных (не заблокированных) яиц, отсортированные по алфавиту
function EggTools.GetEggNames()
	local names = {}
	for id, list in pairs(eggCache) do
		for _, inst in ipairs(list) do
			if inst.Parent and inst:GetAttribute("Unlocked") ~= false then
				names[#names + 1] = id
				break
			end
		end
	end
	table.sort(names)
	return names
end

-- Один вызов покупки. amount: 1, 3 или 8. Возвращает success, message
function EggTools.OpenOnce(eggId, amount)
	if type(eggId) ~= "string" or eggId == "" then
		return false, "Egg not selected"
	end
	local net = resolveNetwork()
	if not net then
		return false, "Network module not found"
	end

	amount = tonumber(amount) or 1
	local triple = amount == 3
	local octuple = amount == 8

	local ok, success, msg = pcall(net.Invoke, "Buy Egg", eggId, triple, octuple)
	if not ok then
		return false, tostring(success)
	end
	return success and true or false, msg
end

local AutoOpen = {
	Enabled = false,
	Egg = nil,
	Amount = 1,
	Delay = 0.3,           -- пауза между покупками, сек
	Teleport = false,      -- телепортироваться к яйцу, если далеко
	WaitAnimation = false, -- ждать конца анимации открытия перед следующей покупкой
	Opened = 0,
	Token = nil,
}

function AutoOpen.Start(eggId, amount)
	if AutoOpen.Enabled then return end
	if eggId then AutoOpen.Egg = eggId end
	if amount then AutoOpen.Amount = tonumber(amount) or 1 end
	if not AutoOpen.Egg then
		warn("[Eggs] Не выбрано яйцо")
		return
	end

	local token = {}
	AutoOpen.Token = token
	AutoOpen.Enabled = true
	AutoOpen.Opened = 0

	task.spawn(function()
		local fails = 0
		while AutoOpen.Enabled and AutoOpen.Token == token do
			local id = AutoOpen.Egg

			-- подойти к яйцу, если нужно
			if AutoOpen.Teleport then
				local egg, center, dist = nearestEgg(id)
				if egg and center and dist and dist > CONFIG.TeleportDistance then
					local rootPart = getRoot()
					if rootPart then
						rootPart.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 6))
						task.wait(0.3)
					end
				end
			end

			if AutoOpen.WaitAnimation then
				local t = os.clock()
				while isOpening() and os.clock() - t < 15 and AutoOpen.Enabled and AutoOpen.Token == token do
					task.wait(0.1)
				end
			end

			local amountNow = AutoOpen.Amount
			local ok, msg = EggTools.OpenOnce(id, amountNow)
			if ok then
				fails = 0
				AutoOpen.Opened = AutoOpen.Opened + (tonumber(amountNow) or 1)
				log("открыто: " .. tostring(AutoOpen.Opened))
				task.wait(math.max(0.05, AutoOpen.Delay))
			else
				fails = fails + 1
				local text = tostring(msg)
				local egg, _, dist = nearestEgg(id)
				warn(string.format("[Eggs] Не вышло (%d/%d): %s | расстояние до яйца: %s",
					fails, CONFIG.MaxFailures, text,
					(egg and dist) and string.format("%.1f", dist) or "?"))
				if fails >= CONFIG.MaxFailures then
					AutoOpen.Enabled = false
					notify("Stopped: " .. text)
					break
				end
				task.wait(CONFIG.FailDelay)
			end
		end
	end)
end

function AutoOpen.Stop()
	AutoOpen.Enabled = false
end

EggTools.AutoOpen = AutoOpen
_G.EggTools = EggTools

-- Первое сканирование и периодический пересчёт (яйца меняются при смене мира)
task.spawn(function()
	while _G.EggToolsGen == myGen do
		local ok, err = pcall(scanEggs)
		if not ok then
			warn("[Eggs] Ошибка сканирования: " .. tostring(err))
		end
		task.wait(CONFIG.RescanInterval)
	end
end)

task.spawn(resolveNetwork)

print("[Eggs] Готово. _G.EggTools.AutoOpen.Start('Cracked Egg', 3) / .Stop()")
