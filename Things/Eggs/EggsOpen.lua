--------------------------------------------------------------------------------
-- КОНФИГ
--------------------------------------------------------------------------------
local CONFIG = {
	TeleportDistance = 10, -- если включён телепорт и ты дальше этого от яйца, телепортируемся к нему
	MaxFailures      = 5,  -- столько неудач подряд -> автооткрытие останавливается
	FailDelay        = 1,  -- пауза после неудачной покупки
	RescanInterval   = 15, -- как часто пересканировать яйца на карте
	TeleportRetries  = 4,  -- кругов попыток телепорта в другой мир (в каждом пробуются 3 способа)
	WorldLoadTimeout = 25, -- сколько ждать загрузку мира после телепорта (сек)
	EggWaitTimeout   = 12, -- сколько ждать появления модели яйца после телепорта (сек)
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
local function currentMap()
	local wc = Lib and Lib.WorldCmds
	if wc and wc.GetMap then
		local ok, m = pcall(wc.GetMap)
		if ok and typeof(m) == "Instance" and m.Parent then return m end
	end
	return Workspace:FindFirstChild("__MAP")
end

local function scanEggs()
	local found = {}
	local root = currentMap() or Workspace
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
-- 2.5. ТЕЛЕПОРТ МЕЖДУ МИРАМИ (логика взята из AutoIndex)
-- Яйцо -> Directory.Eggs[яйцо].area -> Directory.Areas[area].world.
-- Если мир другой (или модель яйца не загружена) — телепортируемся в область
-- яйца, ждём загрузку мира и только потом идём к самому яйцу.
--------------------------------------------------------------------------------
local isExec = isexecutorclosure or checkclosure or function() return false end

local function curWorld()
	local wc = Lib and Lib.WorldCmds
	if not (wc and wc.Get) then return nil end
	local ok, w = pcall(wc.Get)
	return ok and w or nil
end

-- яйцо -> имя области, мир
local function eggLocation(eggId)
	local d = getLib() and Lib.Directory
	local egg = d and d.Eggs and d.Eggs[eggId]
	local areaName = egg and egg.area
	local area = areaName and d.Areas and d.Areas[areaName]
	return areaName, area and area.world
end

-- доступна ли область игроку (мир открыт, область открыта, телепорт куплен)
local function areaAccessible(areaName)
	local d = getLib() and Lib.Directory
	local area = d and d.Areas and d.Areas[areaName]
	if not area or area.hidden then return false end
	local wc = Lib.WorldCmds
	local ok, res = pcall(function()
		return wc.HasAccess(area.world) and wc.HasArea(areaName) and wc.HasTeleport(areaName)
	end)
	return ok and res and true or false
end

local function waitCanAct(sec, alive)
	local t0 = os.clock()
	while alive() and os.clock() - t0 < sec do
		local oe = Lib and Lib.Variables and Lib.Variables.OpeningEgg
		local busy = oe and oe > 0
		if not busy and Lib and Lib.WorldCmds and Lib.WorldCmds.CanDoAction then
			local ok, res = pcall(Lib.WorldCmds.CanDoAction)
			busy = ok and res == false
		end
		if not busy then return end
		task.wait(0.1)
	end
end

local function arrivedAt(areaName)
	local d = Lib and Lib.Directory
	local area = d and d.Areas and d.Areas[areaName]
	if not area or curWorld() ~= area.world then return false end
	local ok, map = pcall(Lib.WorldCmds.GetMap)
	return ok and typeof(map) == "Instance" and map.Parent ~= nil and map:FindFirstChild("Teleports") ~= nil
end

local function waitArrived(areaName, sec, alive)
	local t0 = os.clock()
	local started = false
	task.wait(0.3)
	while alive() and os.clock() - t0 < sec do
		if Lib.Variables.Teleporting then started = true end
		if not Lib.Variables.Teleporting and arrivedAt(areaName) then
			local c0 = os.clock()
			while not getRoot() and os.clock() - c0 < 10 do task.wait(0.2) end
			return true
		end
		if not started and os.clock() - t0 > 4 then return false end -- телепорт даже не начался
		task.wait(0.2)
	end
	return false
end

-- запасной ручной телепорт (если функцию игры найти не удалось)
local function manualTeleport(areaName)
	local wc = Lib.WorldCmds
	local d = Lib.Directory
	if Lib.Variables.Teleporting then return false, "You are already teleporting!" end
	if not wc.CanDoAction() then return false, "Cannot perform actions right now" end
	local a = d.Areas[areaName]
	if not a then return false, "Unknown area!" end
	if not (wc.HasAccess(a.world) and wc.HasArea(areaName) and wc.HasTeleport(areaName)) then
		return false, "нет доступа к миру/области или не куплен телепорт"
	end
	if wc.Get() ~= a.world and not wc.Load(a.world) then return false, "World failed to load!" end
	local map = wc.GetMap()
	local tp = map and map.Teleports and map.Teleports:FindFirstChild(areaName)
	if not tp then return false, "No such teleport for area!" end
	local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local hum = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")
	Lib.Variables.Teleporting = true
	Lib.Signal.Fire("Teleporting")
	task.wait(0.25)
	local cf = tp.CFrame
	char:PivotTo(cf + cf.UpVector * (hum.HipHeight + root.Size.Y / 2))
	pcall(Lib.Network.Fire, "Performed Teleport", areaName)
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
	if getgc and islclosure and debug.info then
		for _, f in ipairs(getgc()) do
			if type(f) == "function" and islclosure(f) and not isExec(f) and debug.info(f, "n") == "Teleport" then
				local ok, consts = pcall(debug.getconstants, f)
				if not ok or type(consts) ~= "table" or table.find(consts, "You are already teleporting!") then
					TeleportFn = f
					return TeleportFn
				end
			end
		end
	end
	TeleportFn = manualTeleport
	return TeleportFn
end

local function viaGame(areaName)
	local ok, success, msg = pcall(getTeleportFn(), areaName)
	if not ok then
		Lib.Variables.Teleporting = false -- функция игры упала и оставила флаг включённым
		return false, tostring(success)
	end
	if not success then return false, tostring(msg) end
	return true
end

local function viaUI(areaName)
	local gui = Lib.GUI and Lib.GUI.Teleport
	local holder = gui and gui.Holder
	local btn = holder and holder:FindFirstChild(areaName)
	if not btn then return false, "кнопка области «" .. areaName .. "» не найдена" end
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
	if not fired then return false, "firesignal/getconnections недоступны в этом executor" end
	task.wait(0.6)
	return true
end

local function viaForce(areaName)
	local ok, res, msg = pcall(Lib.Network.Invoke, "Force Teleport", areaName)
	if not ok then return false, tostring(res) end
	if res == false then return false, tostring(msg) end
	return true
end

local STRATEGIES = {
	{ "функция игры", viaGame },
	{ "кнопка в окне Teleport", viaUI },
	{ "Force Teleport", viaForce },
}

-- Телепорт в область с проверкой, что мир реально сменился
local function safeTeleport(areaName, alive)
	local lastErr = "unknown"
	for attempt = 1, CONFIG.TeleportRetries do
		if not alive() then return false, "остановлено" end
		for _, st in ipairs(STRATEGIES) do
			if not alive() then return false, "остановлено" end
			waitCanAct(20, alive) -- ждём конец анимации яйца
			local okS, errS = st[2](areaName)
			if okS and waitArrived(areaName, CONFIG.WorldLoadTimeout, alive) then
				task.wait(0.3)
				return true
			end
			errS = tostring(errS or "телепорт не начался / мир не загрузился")
			lastErr = st[1] .. ": " .. errS
			log(string.format("телепорт в «%s» (%s, попытка %d/%d): %s | мир сейчас: %s",
				areaName, st[1], attempt, CONFIG.TeleportRetries, errS, tostring(curWorld())))
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

-- Главная функция: оказаться у яйца (сменить мир, если надо, потом подойти).
local function goToEgg(eggId, alive)
	alive = alive or function() return true end
	getLib()
	local areaName, world = eggLocation(eggId)
	local egg, center, dist = nearestEgg(eggId)

	local wrongWorld = world ~= nil and curWorld() ~= nil and curWorld() ~= world
	if wrongWorld or not center then
		if not areaName then
			return false, "яйцо «" .. tostring(eggId) .. "» не найдено ни на карте, ни в директории игры"
		end
		if not areaAccessible(areaName) then
			return false, "нет доступа к области «" .. areaName .. "» (мир «" .. tostring(world) .. "»)"
		end
		log(string.format("яйцо «%s»: область «%s», мир «%s» (сейчас «%s») — телепортируюсь",
			eggId, areaName, tostring(world), tostring(curWorld())))
		local ok, err = safeTeleport(areaName, alive)
		if not ok then return false, "телепорт в мир не удался: " .. tostring(err) end

		-- ждём, пока в новом мире появится модель яйца
		local deadline = os.clock() + CONFIG.EggWaitTimeout
		repeat
			scanEggs()
			egg, center, dist = nearestEgg(eggId)
			if not center then task.wait(0.5) end
		until center or os.clock() > deadline or not alive()
		if not center then
			return false, "модель яйца «" .. tostring(eggId) .. "» не появилась после телепорта"
		end
	end

	if dist and dist > CONFIG.TeleportDistance then
		local rootPart = getRoot()
		if rootPart then
			rootPart.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 6))
			task.wait(0.3)
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- 3. ОТКРЫТИЕ ЯИЦ
--------------------------------------------------------------------------------
local EggTools = {}

function EggTools.Refresh() scanEggs() end

function EggTools.GetEggNames()
	local set = {}
	-- яйца текущей карты
	for id, list in pairs(eggCache) do
		for _, inst in ipairs(list) do
			if inst.Parent and inst:GetAttribute("Unlocked") ~= false then
				set[id] = true
				break
			end
		end
	end
	-- яйца из других миров (по директории игры, только доступные тебе)
	local d = getLib() and Lib.Directory
	if d and type(d.Eggs) == "table" then
		for id, egg in pairs(d.Eggs) do
			if type(id) == "string" and type(egg) == "table" and egg.area and areaAccessible(egg.area) then
				set[id] = true
			end
		end
	end
	local names = {}
	for id in pairs(set) do names[#names + 1] = id end
	table.sort(names)
	return names
end

-- В каком мире/области лежит яйцо: возвращает area, world
function EggTools.GetEggLocation(eggId)
	return eggLocation(eggId)
end

-- Телепортироваться к яйцу (со сменой мира, если надо). Возвращает ok, ошибка
function EggTools.GoToEgg(eggId)
	return goToEgg(eggId)
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

			local alive = function() return AutoOpen.Enabled and AutoOpen.Token == token end

			if AutoOpen.Teleport then
				-- сменит мир, если яйцо в другом, и подойдёт к нему
				local okTp, errTp = goToEgg(id, alive)
				if not okTp then
					fails = fails + 1
					warn(string.format("[Eggs] Телепорт к яйцу не вышел (%d/%d): %s", fails, CONFIG.MaxFailures, tostring(errTp)))
					if fails >= CONFIG.MaxFailures then
						AutoOpen.Enabled = false
						notify("Stopped: " .. tostring(errTp))
						break
					end
					task.wait(CONFIG.FailDelay)
					continue
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
print("[Eggs] Телепорт со сменой мира: _G.EggTools.AutoOpen.Teleport = true, затем Start('Название яйца', 3)")
print("[Eggs] Список доступных яиц (всех миров): _G.EggTools.GetEggNames(); мир яйца: _G.EggTools.GetEggLocation('Название')")
print("[Eggs] Анимация яиц: _G.NoEggAnimation = true / false")
