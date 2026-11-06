--------------------------------------------------------------------------------
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	TeleportDistance = 10, -- если включён телепорт и ты дальше этого от яйца, телепортируемся к нему
	MaxFailures      = 5,  -- столько неудач подряд -> автооткрытие останавливается
	FailDelay        = 1,  -- пауза после неудачной покупки
	RescanInterval   = 15, -- как часто пересканировать яйца на карте
	TeleportRetries  = 10, -- кругов попыток телепорта между мирами (в каждом пробуются 3 способа)
	TeleportTimeout  = 25, -- сколько ждать загрузку мира после телепорта
	EggFindTimeout   = 12, -- сколько ждать появления модели яйца после смены мира
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
local Captured = env.__EggCapturedV2
if not Captured then
	Captured = { remote = nil, method = nil, args = nil }
	env.__EggCapturedV2 = Captured
end

-- глушим хук старой версии скрипта (он вызывал эту функцию)
env.__EggIsEgg = nil

local Lib, Net
local eggCache = {} -- [eggId] = { inst, ... }

-- Простая таблица-набор названий яиц. Хук только ЧИТАЕТ её и не вызывает
-- никаких функций, чтобы не ломать игровые скрипты.
local EggNames = {}
env.__EggNamesV2 = EggNames

local function rebuildNames()
	local set = {}
	for id in pairs(eggCache) do set[id] = true end
	local d = Lib and Lib.Directory and Lib.Directory.Eggs
	if type(d) == "table" then
		for k in pairs(d) do
			if type(k) == "string" then set[k] = true end
		end
	end
	for k in pairs(EggNames) do EggNames[k] = nil end
	for k in pairs(set) do EggNames[k] = true end
end

if not env.__EggHookV2 then
	if hookmetamethod and getnamecallmethod and newcclosure and checkcaller then
		env.__EggHookV2 = true
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if method == "InvokeServer" or method == "FireServer" then
				if not checkcaller() then
					local first = ...
					local names = env.__EggNamesV2
					if type(first) == "string" and names and names[first] then
						local c = env.__EggCapturedV2
						if c then
							c.remote = self
							c.method = method
							c.args = table.pack(...)
						end
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
-- 1. БИБЛИОТЕКА ИГРЫ И Network.Invoke (запасной вариант)
--------------------------------------------------------------------------------
local function getLib()
	if Lib then return Lib end
	local fw = ReplicatedStorage:FindFirstChild("Framework")
	local m = fw and fw:FindFirstChild("Library")
	if m and m:IsA("ModuleScript") then
		local ok, res = pcall(require, m)
		if ok and type(res) == "table" then Lib = res end
	end
	return Lib
end

local function pickNetwork(m)
	if type(m) ~= "table" then return nil end
	if type(m.Invoke) == "function" then return m end
	local n = m.Network
	if type(n) == "table" and type(n.Invoke) == "function" then return n end
	return nil
end

-- вызывается только если ремоут не пойман, при старте ничего не require-им
local function resolveNetwork()
	if Net then return Net end
	Net = pickNetwork(getLib())
	if Net then return Net end

	local lib = ReplicatedStorage:FindFirstChild("Library")
	local client = lib and lib:FindFirstChild("Client")
	local mod = client and client:FindFirstChild("Network")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok then Net = pickNetwork(res) end
	end
	return Net
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
	-- яйца есть только в ТЕКУЩЕМ мире: берём карту загруженного мира
	local root
	if Lib and Lib.WorldCmds then
		local ok, m = pcall(Lib.WorldCmds.GetMap)
		if ok and typeof(m) == "Instance" and m.Parent then root = m end
	end
	root = root or Workspace:FindFirstChild("__MAP") or Workspace
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
-- 2.5. ТЕЛЕПОРТ МЕЖДУ МИРАМИ
-- Яйца лежат в разных мирах, а на карте загружен только текущий мир.
-- Поэтому мир и область яйца берём из Directory: Eggs[яйцо].area -> Areas[область].world
-- Если мир не тот — сначала телепортируемся в область яйца (3 способа, с проверкой,
-- что мир реально сменился), потом подходим к самой модели яйца.
--------------------------------------------------------------------------------
local isExec = isexecutorclosure or checkclosure or function() return false end
local GC

local function findFn(name, marker)
	if not (getgc and islclosure and debug and debug.info) then return nil end
	GC = GC or getgc()
	for _, f in ipairs(GC) do
		if type(f) == "function" and islclosure(f) and not isExec(f) and debug.info(f, "n") == name then
			local ok, consts = pcall(debug.getconstants, f)
			if not ok or type(consts) ~= "table" or table.find(consts, marker) then
				return f
			end
		end
	end
end

local function curWorld()
	local ok, w = pcall(Lib.WorldCmds.Get)
	return ok and w or nil
end

-- мир, в котором лежит яйцо: { area = "...", world = "..." }
local function eggInfo(eggId)
	local L = getLib()
	local dir = L and L.Directory
	local e = dir and dir.Eggs and dir.Eggs[eggId]
	local a = e and e.area and dir.Areas and dir.Areas[e.area]
	if not a then return nil end
	return { area = e.area, world = a.world }
end

-- мы сейчас в нужном мире и карта загружена?
local function inWorld(world)
	if not Lib or curWorld() ~= world then return false end
	local ok, map = pcall(Lib.WorldCmds.GetMap)
	return ok and typeof(map) == "Instance" and map.Parent ~= nil and map:FindFirstChild("Teleports") ~= nil
end

local function canAct()
	if isOpening() then return false end
	local ok, res = pcall(Lib.WorldCmds.CanDoAction)
	if ok and res == false then return false end
	return true
end

local function waitCanAct(sec, alive)
	local t0 = os.clock()
	while alive() and not canAct() and os.clock() - t0 < sec do
		task.wait(0.1)
	end
end

local function manualTeleport(area)
	local WC = Lib.WorldCmds
	local Dir = Lib.Directory
	if Lib.Variables.Teleporting then return false, "You are already teleporting!" end
	if not WC.CanDoAction() then return false, "Cannot perform actions right now" end
	local a = Dir.Areas[area]
	if not a then return false, "Unknown area!" end
	if not (WC.HasAccess(a.world) and WC.HasArea(area) and WC.HasTeleport(area)) then
		return false, "нет доступа к миру/области или не куплен телепорт"
	end
	if WC.Get() ~= a.world and not WC.Load(a.world) then
		return false, "World failed to load!"
	end
	local map = WC.GetMap()
	local tp = map and map.Teleports and map.Teleports:FindFirstChild(area)
	if not tp then return false, "No such teleport for area!" end

	local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local hum = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")
	Lib.Variables.Teleporting = true
	Lib.Signal.Fire("Teleporting")
	task.wait(0.25)
	local cf = tp.CFrame
	char:PivotTo(cf + cf.UpVector * (hum.HipHeight + root.Size.Y / 2))
	pcall(Lib.Network.Fire, "Performed Teleport", area)
	task.wait(0.25)
	Lib.Variables.Teleporting = false
	return true
end

local TeleportFn
local function getTeleportFn()
	if TeleportFn then return TeleportFn end
	if getsenv then
		for _, d in ipairs(LocalPlayer.PlayerScripts:GetDescendants()) do
			if d.Name == "Teleport" and (d:IsA("LocalScript") or d:IsA("ModuleScript")) then
				local ok, senv = pcall(getsenv, d)
				if ok and type(senv) == "table" and type(senv.Teleport) == "function" then
					TeleportFn = senv.Teleport
					return TeleportFn
				end
			end
		end
	end
	TeleportFn = findFn("Teleport", "You are already teleporting!") or manualTeleport
	return TeleportFn
end

-- ждём окончания телепорта/загрузки мира и появления персонажа
local function waitArrived(world, sec)
	local t0 = os.clock()
	local started = false
	task.wait(0.3)
	while os.clock() - t0 < sec do
		if Lib.Variables.Teleporting then started = true end
		if not Lib.Variables.Teleporting and inWorld(world) then
			local c0 = os.clock()
			while not getRoot() and os.clock() - c0 < 10 do task.wait(0.2) end
			return true
		end
		if not started and os.clock() - t0 > 4 then return false end
		task.wait(0.2)
	end
	return false
end

local function viaGame(area)
	local ok, success, msg = pcall(getTeleportFn(), area)
	if not ok then
		Lib.Variables.Teleporting = false
		return false, tostring(success)
	end
	if not success then return false, tostring(msg) end
	return true
end

local function viaUI(area)
	local gui = Lib.GUI and Lib.GUI.Teleport
	local holder = gui and gui.Holder
	local btn = holder and holder:FindFirstChild(area)
	if not btn then return false, "кнопка области «" .. area .. "» не найдена" end
	local fired = false
	if firesignal then fired = pcall(firesignal, btn.Activated) end
	if not fired and getconnections then
		local okC, conns = pcall(getconnections, btn.Activated)
		if okC and type(conns) == "table" then
			for _, c in ipairs(conns) do
				if pcall(function() c:Fire() end) then fired = true end
			end
		end
	end
	if not fired then return false, "firesignal/getconnections недоступны" end
	task.wait(0.6)
	return true
end

local function viaForce(area)
	local a = Lib.Directory.Areas[area]
	if not (a and Lib.WorldCmds.HasAccess(a.world) and Lib.WorldCmds.HasArea(area)) then
		return false, "нет доступа к области"
	end
	local ok, res, msg = pcall(Lib.Network.Invoke, "Force Teleport", area)
	if not ok then return false, tostring(res) end
	if res == false then return false, tostring(msg) end
	return true
end

local STRATEGIES = {
	{ "функция игры", viaGame },
	{ "кнопка в окне Teleport", viaUI },
	{ "Force Teleport", viaForce },
}

-- телепорт в область (с переходом между мирами). alive() -> false прерывает попытки
local function safeTeleport(area, alive)
	alive = alive or function() return true end
	local a = Lib.Directory.Areas[area]
	if not a then return false, "Unknown area" end
	local lastErr = "unknown"
	for attempt = 1, CONFIG.TeleportRetries do
		if not alive() then return false, "остановлено" end
		for _, st in ipairs(STRATEGIES) do
			if not alive() then return false, "остановлено" end
			waitCanAct(20, alive)
			local okS, errS = st[2](area)
			if okS and waitArrived(a.world, CONFIG.TeleportTimeout) then
				task.wait(0.3)
				return true
			end
			errS = tostring(errS or "телепорт не начался / мир не загрузился")
			lastErr = st[1] .. ": " .. errS
			log(string.format("телепорт в «%s» (%s, %d/%d): %s", area, st[1], attempt, CONFIG.TeleportRetries, errS))
			if errS:find("do not have access", 1, true) or errS:find("do not own", 1, true)
				or errS:find("Unknown area", 1, true) or errS:find("нет доступа", 1, true) then
				return false, lastErr
			end
			if errS:find("already teleporting", 1, true) then
				if attempt >= 3 then Lib.Variables.Teleporting = false end
				break
			end
			if errS:find("Cannot perform actions", 1, true) or errS:find("right now", 1, true) then
				break
			end
		end
		if attempt < CONFIG.TeleportRetries then task.wait(0.5) end
	end
	return false, lastErr
end

-- Телепорт к яйцу: при необходимости меняет мир, потом встаёт рядом с моделью яйца.
-- Возвращает true или false, причина
local function goToEgg(eggId, alive)
	alive = alive or function() return true end
	getLib()
	if not Lib then return false, "библиотека игры не загружена" end
	local info = eggInfo(eggId)
	if not info then return false, "неизвестное яйцо / нет данных о мире" end

	-- 1) нужный мир (и область) — если не тот, телепортируемся
	local teleported = false
	if not inWorld(info.world) then
		log(string.format("яйцо «%s»: мир «%s», сейчас «%s» — телепорт в «%s»",
			eggId, tostring(info.world), tostring(curWorld()), info.area))
		local ok, err = safeTeleport(info.area, alive)
		if not ok then return false, err end
		teleported = true
	end

	-- 2) ждём, пока загрузится модель яйца в новом мире
	local center
	local function findCenter()
		scanEggs()
		local _, c = nearestEgg(eggId)
		return c
	end
	local deadline = os.clock() + CONFIG.EggFindTimeout
	repeat
		center = findCenter()
		if not center then task.wait(0.5) end
	until center or os.clock() > deadline or not alive()

	-- не нашли в этом мире — возможно, нужна именно область яйца: телепортируемся в неё
	if not center and not teleported and alive() then
		local ok = safeTeleport(info.area, alive)
		if ok then
			deadline = os.clock() + CONFIG.EggFindTimeout
			repeat
				center = findCenter()
				if not center then task.wait(0.5) end
			until center or os.clock() > deadline or not alive()
		end
	end
	if not center then
		return false, "модель яйца «" .. eggId .. "» не найдена в мире «" .. tostring(info.world) .. "»"
	end

	-- 3) подходим к яйцу
	local rootPart = getRoot()
	if not rootPart then return false, "нет персонажа" end
	local away = (rootPart.Position - center.Position) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
	local char = LocalPlayer.Character
	char:PivotTo(CFrame.new(center.Position + away * 4 + Vector3.new(0, 3, 0)))
	task.wait(0.4)
	return true
end

--------------------------------------------------------------------------------
-- 3. ОТКРЫТИЕ ЯИЦ
--------------------------------------------------------------------------------
local EggTools = {}

function EggTools.Refresh() scanEggs() end

-- Все яйца игры (включая другие миры): { name, area, world, here }
-- here = яйцо в текущем мире. Список для UI-выбора яйца.
function EggTools.GetAllEggs()
	local L = getLib()
	local dir = L and L.Directory
	local out = {}
	if not (dir and dir.Eggs) then return out end
	local cw = curWorld()
	for name in pairs(dir.Eggs) do
		local info = eggInfo(name)
		if info then
			local okAccess, access = pcall(L.WorldCmds.HasAccess, info.world)
			local okArea, hasArea = pcall(L.WorldCmds.HasArea, info.area)
			if okAccess and access and okArea and hasArea then
				out[#out + 1] = { name = name, area = info.area, world = info.world, here = (info.world == cw) }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.world ~= b.world then return tostring(a.world) < tostring(b.world) end
		return a.name < b.name
	end)
	return out
end

-- Мир и область яйца
function EggTools.GetEggInfo(eggId) return eggInfo(eggId) end

-- Телепорт к яйцу (с переходом в другой мир при необходимости)
function EggTools.GoToEgg(eggId) return goToEgg(eggId) end

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
				local info = eggInfo(id)
				local egg, center, dist = nearestEgg(id)
				local wrongWorld = info and not inWorld(info.world)
				if wrongWorld or (info and not egg) or (egg and center and dist and dist > CONFIG.TeleportDistance) then
					local alive = function() return AutoOpen.Enabled and AutoOpen.Token == token end
					local okGo, errGo = goToEgg(id, alive)
					if not alive() then break end
					if not okGo then
						fails = fails + 1
						warn(string.format("[Eggs] Телепорт к яйцу не удался (%d/%d): %s",
							fails, CONFIG.MaxFailures, tostring(errGo)))
						if fails >= CONFIG.MaxFailures then
							AutoOpen.Enabled = false
							notify("Stopped: " .. tostring(errGo))
							break
						end
						task.wait(CONFIG.FailDelay)
						continue
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

--------------------------------------------------------------------------------
-- 4. ОТКЛЮЧЕНИЕ АНИМАЦИИ ОТКРЫТИЯ ЯИЦ
-- Управление переменной:
--   _G.NoEggAnimation = true   -- анимации нет (яйца открываются мгновенно)
--   _G.NoEggAnimation = false  -- обычная анимация
-- Подмена ставится один раз, дальше переменную можно менять сколько угодно.
--------------------------------------------------------------------------------
if _G.NoEggAnimation == nil then
	_G.NoEggAnimation = false
end

local NoAnim = { Method = nil, Installed = false }

-- Мгновенная замена OpenEgg: те же сигналы и счётчик, но без анимации
local function InstantOpen(eggName, pets)
	local vars = Lib.Variables

	env.__LastEggOpen = {
		egg = eggName,
		count = (type(pets) == "table") and #pets or 1,
	}

	vars.OpeningEgg = vars.OpeningEgg + 1
	Lib.Signal.Fire("Opening Egg", eggName)

	game:GetService("RunService").Heartbeat:Wait() -- кадр, чтобы остальные скрипты успели среагировать

	vars.OpeningEgg = math.max(vars.OpeningEgg - 1, 0)
	Lib.Signal.Fire("Done Opening Egg", eggName)
end

local function installNoAnim()
	if env.__NoEggAnimInstalled then
		NoAnim.Installed = true
		NoAnim.Method = env.__NoEggAnimInstalled
		return
	end

	-- ждём загрузку игровой библиотеки
	local waited = 0
	while not getLib() and waited < 20 do
		task.wait(0.5)
		waited += 0.5
	end
	if not Lib then
		warn("[NoEggAnim] Библиотека игры не найдена")
		return
	end
	while not Lib.Loaded do
		game:GetService("RunService").Heartbeat:Wait()
	end

	local isExec = isexecutorclosure or checkclosure or function() return false end

	local function looksRight(f)
		local ok, consts = pcall(debug.getconstants, f)
		if not ok or type(consts) ~= "table" then return true end
		return table.find(consts, "Opening Egg") ~= nil
	end

	local function findOpenEgg()
		if not (getgc and islclosure and debug.info) then return nil end
		for _, f in ipairs(getgc()) do
			if type(f) == "function" and islclosure(f) and not isExec(f)
				and debug.info(f, "n") == "OpenEgg" and looksRight(f) then
				return f
			end
		end
	end

	local target
	for _ = 1, 20 do -- ждём до ~10 сек, вдруг игра ещё грузится
		target = findOpenEgg()
		if target then break end
		task.wait(0.5)
	end

	local method

	-- Способ 1: подмена функции. Обёртка сама смотрит на переменную:
	-- включено -> мгновенная версия, выключено -> оригинал.
	if target and hookfunction then
		local old
		local ok = pcall(function()
			old = hookfunction(target, function(...)
				if _G.NoEggAnimation then
					return InstantOpen(...)
				end
				return old(...)
			end)
		end)
		if ok and old then method = "hookfunction" end
	end

	-- Способ 2 (запасной): подписки игры выключаются/включаются по переменной
	if not method and getconnections then
		local ok = pcall(function()
			local sources = {
				Lib.Network.Fired("Open Egg"),
				Lib.Signal.Fired("Open Egg"),
			}
			local original = {}
			for _, sig in ipairs(sources) do
				for _, c in ipairs(getconnections(sig)) do
					original[#original + 1] = c
				end
			end
			for _, sig in ipairs(sources) do
				sig:Connect(function(eggName, pets)
					if _G.NoEggAnimation then
						task.spawn(InstantOpen, eggName, pets)
					end
				end)
			end

			local applied = false
			task.spawn(function()
				while _G.EggToolsGen == myGen do
					local want = _G.NoEggAnimation and true or false
					if want ~= applied then
						applied = want
						for _, c in ipairs(original) do
							pcall(function()
								if want then c:Disable() else c:Enable() end
							end)
						end
					end
					task.wait(0.2)
				end
				-- скрипт перезапущен: возвращаем оригинальные подписки
				for _, c in ipairs(original) do pcall(function() c:Enable() end) end
			end)
		end)
		if ok then method = "getconnections" end
	end

	if method then
		env.__NoEggAnimInstalled = method
		NoAnim.Installed = true
		NoAnim.Method = method
		warn("[NoEggAnim] Готово (способ: " .. method .. "). _G.NoEggAnimation = true / false")
	else
		warn("[NoEggAnim] Не удалось: нет hookfunction/getconnections или функция OpenEgg не найдена")
	end
end

function EggTools.SetNoAnimation(value)
	_G.NoEggAnimation = value and true or false
end

function EggTools.IsNoAnimationReady()
	return NoAnim.Installed, NoAnim.Method
end

task.spawn(installNoAnim)

task.spawn(function()
	while _G.EggToolsGen == myGen do
		local ok, err = pcall(function()
			scanEggs()
			getLib()
			rebuildNames()
		end)
		if not ok then warn("[Eggs] Ошибка сканирования: " .. tostring(err)) end
		task.wait(CONFIG.RescanInterval)
	end
end)

task.spawn(getLib)

print("[Eggs] Готово. Открой яйцо вручную ОДИН раз (скрипт поймает ремоут), затем _G.EggTools.AutoOpen.Start('Cracked Egg', 3) / .Stop()")
print("[Eggs] Яйца в других мирах: _G.EggTools.AutoOpen.Teleport = true — скрипт сам сменит мир и подойдёт к яйцу. Список: _G.EggTools.GetAllEggs()")
print("[Eggs] Анимация яиц: _G.NoEggAnimation = true / false")
