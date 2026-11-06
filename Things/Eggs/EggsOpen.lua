--------------------------------------------------------------------------------
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	TeleportDistance = 10, -- если включён телепорт и ты дальше этого от яйца, телепортируемся к нему
	MaxFailures      = 5,  -- столько неудач подряд -> автооткрытие останавливается
	FailDelay        = 1,  -- пауза после неудачной покупки
	RescanInterval   = 15, -- как часто пересканировать яйца на карте
	Debug            = false,
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

-- Повторный запуск: останавливаем старую версию
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
	if CONFIG.Debug then print("[Eggs] " .. text) end
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

--------------------------------------------------------------------------------
-- 0. ПЕРЕХВАТ РЕАЛЬНОГО ВЫЗОВА ПОКУПКИ
-- Ремоуты зашифрованы, поэтому ждём, пока ты откроешь яйцо вручную один раз.
-- Хук запоминает ремоут, метод и аргументы. Дальше мы повторяем этот вызов,
-- подставляя своё яйцо и количество.
-- Данные лежат в env, поэтому переживают перезапуск скрипта.
--------------------------------------------------------------------------------
local Captured = env.__EggCaptured
if not Captured then
	Captured = { remote = nil, method = nil, args = nil }
	env.__EggCaptured = Captured
end

local Lib, Net
local eggCache = {} -- [eggId] = { inst, ... }

-- проверка "это название яйца?" (хук читает актуальную версию через env)
env.__EggIsEgg = function(name)
	if type(name) ~= "string" then return false end
	if eggCache[name] then return true end
	local d = Lib and Lib.Directory and Lib.Directory.Eggs
	return d ~= nil and d[name] ~= nil
end

if not env.__EggHookInstalled then
	if hookmetamethod and getnamecallmethod and newcclosure then
		env.__EggHookInstalled = true
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if (method == "InvokeServer" or method == "FireServer")
				and not (checkcaller and checkcaller()) then
				local first = ...
				local check = env.__EggIsEgg
				if check and check(first) then
					local c = env.__EggCaptured
					if c then
						c.remote = self
						c.method = method
						c.args = table.pack(...)
					end
				end
			end
			return oldNamecall(self, ...)
		end))
	else
		warn("[Eggs] Executor не поддерживает hookmetamethod — перехват невозможен")
	end
end

--------------------------------------------------------------------------------
-- 1. ИГРОВОЙ Network.Invoke (запасной вариант, если ремоут ещё не пойман)
--------------------------------------------------------------------------------
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
	local function add(x) if x then list[#list + 1] = x end end

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
--------------------------------------------------------------------------------
local function scanEggs()
	local found = {}
	local map = Workspace:FindFirstChild("__MAP")
	local root = map or Workspace
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		n = n + 1
		if n % 3000 == 0 then task.wait() end
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

function EggTools.Refresh() scanEggs() end

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

-- Пойман ли ремоут (true/false) и с каким яйцом
function EggTools.IsLearned()
	return Captured.remote ~= nil and Captured.args ~= nil
end

function EggTools.GetLearnedEgg()
	return Captured.args and Captured.args[1] or nil
end

-- Собираем аргументы из пойманного шаблона:
-- [1] = яйцо, а если дальше идут два boolean — это triple и octuple
local function buildArgs(eggId, amount)
	local src = Captured.args
	local args = table.pack(table.unpack(src, 1, src.n))
	args[1] = eggId
	if type(args[2]) == "boolean" and type(args[3]) == "boolean" then
		args[2] = (amount == 3)
		args[3] = (amount == 8)
	end
	return args
end

-- Один вызов покупки. amount: 1, 3 или 8. Возвращает success, message
function EggTools.OpenOnce(eggId, amount)
	if type(eggId) ~= "string" or eggId == "" then
		return false, "Egg not selected"
	end
	amount = tonumber(amount) or 1

	-- основной путь: повторяем пойманный вызов
	if Captured.remote and Captured.args then
		local args = buildArgs(eggId, amount)
		local remote, method = Captured.remote, Captured.method
		local res = table.pack(pcall(function()
			return remote[method](remote, table.unpack(args, 1, args.n))
		end))
		if not res[1] then
			return false, tostring(res[2])
		end
		if method == "InvokeServer" and res[2] == false then
			return false, res[3] or "server refused"
		end
		return true, res[3]
	end

	-- запасной путь: игровой Network.Invoke
	local net = resolveNetwork()
	if not net then
		return false, "Remote not learned: open any egg manually once"
	end
	local ok, success, msg = pcall(net.Invoke, "Buy Egg", eggId, amount == 3, amount == 8)
	if not ok then return false, tostring(success) end
	return success and true or false, msg
end

local AutoOpen = {
	Enabled = false,
	Egg = nil,
	Amount = 1,
	Delay = 0.3,
	Teleport = false,
	WaitAnimation = false,
	Opened = 0,
	Token = nil,
}

function AutoOpen.Start(eggId, amount)
	if AutoOpen.Enabled then return end
	if eggId then AutoOpen.Egg = eggId end
	if amount then AutoOpen.Amount = tonumber(amount) or 1 end
	-- если яйцо не выбрано — берём то, что открывали вручную
	if not AutoOpen.Egg then AutoOpen.Egg = EggTools.GetLearnedEgg() end
	if not AutoOpen.Egg then
		warn("[Eggs] Не выбрано яйцо")
		return
	end
	if not EggTools.IsLearned() then
		warn("[Eggs] Ремоут ещё не пойман: открой любое яйцо вручную один раз (иначе пробую Network.Invoke)")
	end

	local token = {}
	AutoOpen.Token = token
	AutoOpen.Enabled = true
	AutoOpen.Opened = 0

	task.spawn(function()
		local fails = 0
		while AutoOpen.Enabled and AutoOpen.Token == token do
			local id = AutoOpen.Egg

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

task.spawn(function()
	while _G.EggToolsGen == myGen do
		local ok, err = pcall(scanEggs)
		if not ok then warn("[Eggs] Ошибка сканирования: " .. tostring(err)) end
		task.wait(CONFIG.RescanInterval)
	end
end)

task.spawn(resolveNetwork)

print("[Eggs] Готово. Открой яйцо вручную ОДИН раз (скрипт поймает ремоут), затем _G.EggTools.AutoOpen.Start('Cracked Egg', 3) / .Stop()")
