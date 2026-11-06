-- LocalScript: IndexFarm v2 (fix удаления)
-- Индекс: обычный пет -> golden (Golden Machine) -> rainbow (Rainbow Machine)
-- Пока открывает яйца, следит за инвентарём и крафтит сам.
--
-- Remote-ы игры меняются при каждом входе, поэтому они ловятся хуком, а не хардкодятся:
--   * яйца: откроешь одно яйцо руками (нужно только если прямой вызов не сработал)
--   * Golden Machine: сделай ОДИН крафт вручную (ОК + подтверждение)
--   * Rainbow Machine: сделай ОДИН крафт вручную
--   * УДАЛЕНИЕ: удали вручную ОДНОГО ненужного пета (корзина -> выбрать пета -> Delete -> подтвердить)
-- Скрипт сам скажет в логе, когда ему нужен какой-то Remote. Фарм при этом НЕ останавливается (кроме яиц/крафта).
--
-- УПРАВЛЕНИЕ ПЕРЕМЕННОЙ (выключена изначально):
--   _G.AutoIndexFarm = true   -- включить фарм индекса
--   _G.AutoIndexFarm = false  -- выключить (останавливается и ждёт; можно включить снова)
-- Повторный запуск скрипта полностью отключает прошлую копию (пойманные Remote сохраняются).

local env = (getgenv and getgenv()) or _G
local KEY, HOOK_KEY, HANDLER_KEY = "__IndexFarm2", "__IndexFarm2Hook_v4", "__IndexFarm2Handler"

-- ===== НАСТРОЙКИ =====
local VARIANTS           = { 1, 2, 3 }  -- порядок: 1 = обычные, 2 = golden, 3 = rainbow (можно { 1 } или { 3 })
local OPEN_MODE          = 0     -- 0 = авто (максимум, что доступно: 8 > 3 > 1), либо 1 / 3 / 8 вручную
local DELAY              = 0.4   -- пауза между открытиями (сек)
local WAIT_EGG_ANIMATION = false -- false = БЫСТРО: не ждать конца анимации яйца перед следующей покупкой (как в авто-опенере). true = ждать анимацию (медленно)
local FLUSH_INTERVAL    = 2     -- как часто (сек) проверять инвентарь на удаление; раньше проверялось каждый цикл
local MAX_EXPECTED_OPENS = 3000  -- цели, на которые в среднем нужно больше открытий, пропускаются
local MIN_CHANCE         = 0     -- минимальный суммарный шанс яйца на пета в % (0 = любой)
local GOLDEN_PETS        = 6     -- обычных петов на один golden-крафт (минимум 5)
local RAINBOW_PETS       = 6     -- golden петов на один rainbow-крафт (минимум 5)
local CRAFT_DELAY        = 0.3   -- пауза после крафта
local COOLDOWN           = 300   -- на сколько секунд откладывать цель после неудачи
local USE_GOLDEN_EGGS    = true  -- golden-яйца дают golden пета сразу (без крафта), если так выгоднее
local SKIP_RARITIES      = {}    -- например { "Secret" } - этих для крафта не трогать
local CONTINUE_AFTER     = true  -- после получения брать следующую цель
local MIXED_VARIANTS    = true  -- true = искать недостающих сразу по ВСЕМ вариантам из VARIANTS (обычные, Golden, Rainbow) и брать самую выгодную цель; false = по очереди: сначала все обычные, потом golden...
local TRAVEL_COST_AREA  = 30    -- штраф к цели за смену области в том же мире (в "эквиваленте открытых яиц"), чтобы скрипт не прыгал без нужды
local TRAVEL_COST_WORLD = 300   -- штраф за смену МИРА (самая тяжёлая и глючная телепортация)
local TELEPORT_RETRIES = 10    -- кругов попыток телепорта (в каждом пробуются 3 способа); паузы между кругами короткие
local BOOTSTRAP		 = true  -- при старте: если не пойманы Remote (яйца/удаление/Golden/Rainbow) - сам телепортирует куда надо и пишет в консоль, что сделать вручную
local GUIDED_SETUP	= true  -- пошаговая подготовка: скрипт ведёт тебя по шагам (яйцо -> пет на удаление -> golden-яйцо -> удаление -> Golden -> Rainbow) и подсказывает, что нажать. false = старая подготовка
local BOOTSTRAP_WAIT	= 180   -- сколько секунд ждать твоё ручное действие на каждом шаге подготовки
local MACHINE_AREA	= "Town" -- область с машинами Golden/Rainbow (если такой области нет - авто: первая область первого мира)
local MACHINE_FAIL_COOLDOWN = 45 -- сколько секунд не пытаться снова дойти до машины после неудачи (фарм яиц при этом идёт дальше)
local MACHINE_OFFSET	= 8	 -- на каком расстоянии от машины встаём (студы)

-- удаление ненужных петов (ТОЛЬКО тех, что выпали из яиц за этот запуск скрипта)
local DELETE_JUNK        = true  -- включить авто-удаление
local DRY_RUN            = false -- true = только писать в лог, что удалил бы
local DELETE_DEBUG       = true  -- раз в 30 сек писать в лог, сколько петов оставлено и почему
local DELETE_BATCH       = 10    -- удалять пачкой, когда набралось столько ненужных
local DELETE_MAX         = 50    -- максимум петов за один проход удаления (защита)
local MIN_PETS_LEFT      = 20    -- если после удаления в инвентаре останется меньше - НЕ удаляем (защита)
local KEEP_RARITIES      = { "Mythical", "Mythic", "Secret", "Event", "Exclusive" } -- эти редкости не удаляем никогда (Mythic/Mythical защищены всегда, даже если пет просто выбит или скрафчен)
local KEEP_SHINY         = true  -- shiny петов не удаляем
local KEEP_EXTRA_COPIES  = 4     -- запас копий сверх нужного для крафта
local STOP_KEY           = Enum.KeyCode.X
local SKIP_KEY           = Enum.KeyCode.C  -- бросить текущую цель и перейти на СЛУЧАЙНУЮ другую нужную
local STOP_ON_MOVE       = true  -- true = если сам пошёл персонажем, фарм выключается (как раньше); false = не реагировать на движение

-- фарм валюты: если на яйцо не хватает - идём в лучшую область нужного мира, бьём монеты петами и копим
local CURRENCY_FARM = {
	ENABLED      = true,
	ANY_WORLD    = { ["Halloween Candy"] = true }, -- валюты, которые падают В ЛЮБОМ мире: для них берём лучшую область всей игры
	MIN_OPENS    = 20,    -- копить минимум на столько открытий яйца (чтобы не бегать туда-сюда)
	MAX_OPENS    = 400,   -- потолок запаса: на сколько открытий копить максимум
	BUFFER       = 1.5,   -- запас к ожидаемому числу открытий
	MAX_TIME     = 1200,  -- сек: после этого возвращаемся к яйцам, если хватает хотя бы на 1 открытие
	GIVE_UP_TIME = 3600,  -- сек: если за это время не набралось даже на 1 яйцо - цель откладывается
	STAGNATION   = 60,    -- сек без роста валюты -> область считается плохой, пробуем следующую
	AREA_BAD_COOLDOWN = 900, -- сек не возвращаться в «плохую» область
	COINS_WAIT   = 10,    -- сек ждать монеты после телепорта
	LEARN_WAIT   = 180,   -- сек ждать, пока ты кликнешь по монете (для поимки Remote-ов)
	LOG_INTERVAL = 30,    -- как часто писать прогресс в лог
	-- параметры боя с монетами (из Farm.lua)
	-- какую монету бить: после замера урона петов берём самую «толстую», которую петы ломают за MAX_BREAK_TIME сек
	CENTER_TP      = true,  -- при нехватке валюты вставать не у точки телепорта, а в ЦЕНТР области (по монетам)
	CENTER_SETTLE  = 6,     -- сек ждать, пока подгрузятся монеты области, прежде чем считать центр
	BEST_COIN      = true,
	TP_TO_COIN     = true,  -- телепортировать игрока к выбранной монете (false = стоять на месте)
	MAX_BREAK_TIME = 40,    -- сек: дольше этого монету «лучшей» не считаем
	MAX_COIN_TIME  = 120,   -- сек на одну монету, потом бросаем её
	TOUGH_COOLDOWN = 600,   -- сек не трогать слишком крепкую монету
	TP_OFFSET = 6, TP_TOLERANCE = 6, TP_MIN_INTERVAL = 1.5, TP_SETTLE = 0.4, -- отступ от монеты (+ её радиус), пауза между телепортами, пауза перед назначением петов
	NEAR_RADIUS = 9999, PETS_PER_COIN = 2, ASSIGN_INTERVAL = 1.0, HIT_INTERVAL = 0.5, SEND_DELAY = 0.05,
	TRAVEL_GRACE = 20, STUCK_TIMEOUT = 10, MAX_ASSIGN_TIME = 30, REJECT_COOLDOWN = 25, MAX_HITS = 60,
}
-- ======================

-- выключаем старую копию, но сохраняем пойманные Remote
local prev = env[KEY]
local prevWasRunning = prev and prev.running
if prev then
	prev.active, prev.running = false, false
	-- прошлая копия перестаёт работать: оба её потока (управляющий и основной) останавливаются
	if prev.thread then pcall(task.cancel, prev.thread) end
	if prev.mainThread then pcall(task.cancel, prev.mainThread) end
	for _, c in ipairs(prev.connections) do pcall(function() c:Disconnect() end) end
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local Library = require(RS:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do RunService.Heartbeat:Wait() end

local Dir = Library.Directory
local HC = Library.Shared.IsHardcore

-- если прошлую копию оборвали посреди работы - снимаем флаги, которые она могла оставить включёнными
if prevWasRunning then
	Library.Variables.UsingMachine = false
	Library.Variables.Teleporting = false
end

-- переменная управления: выключена изначально
_G.AutoIndexFarm = false

local function remoteOk(r)
	return typeof(r) == "Instance" and r.Parent ~= nil
end

local state = {
	active = true, running = false, connections = {},
	eggRemote = prev and remoteOk(prev.eggRemote) and prev.eggRemote or nil,
	eggMethod = prev and prev.eggMethod,
	goldRemote = prev and remoteOk(prev.goldRemote) and prev.goldRemote or nil,
	rainbowRemote = prev and remoteOk(prev.rainbowRemote) and prev.rainbowRemote or nil,
	deleteRemote = prev and remoteOk(prev.deleteRemote) and prev.deleteRemote or nil,
	coinRF = prev and remoteOk(prev.coinRF) and prev.coinRF or nil,
	coinRE = prev and remoteOk(prev.coinRE) and prev.coinRE or nil,
	deleteDirectFailed = false,
	deleteHintAt = 0,
	skipRequested = false,
	pinned = nil,
	lastEgg = nil,
}
env[KEY] = state

if Library.Shared.IsTradingPlaza then
	return warn("[IndexFarm] В Trading Plaza телепорты отключены. Зайди в обычный мир.")
end

-- ===== вспомогательное =====
local isExec = isexecutorclosure or checkclosure or function() return false end
local GC

local function findFn(name, marker)
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

local CostFn = findFn("GetEggCost", "hardcoreCost")

local function isMoving()
	if not STOP_ON_MOVE then return false end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.MoveDirection.Magnitude > 0.1
end

local function stop(reason)
	if state.running then warn("[IndexFarm] Стоп: " .. reason) end
	state.running = false
	_G.AutoIndexFarm = false -- иначе управляющий поток сразу включил бы фарм снова
end

local cooldown = {}
local function isCooling(k) return (cooldown[k] or 0) > os.clock() end
local function coolDown(k, sec) cooldown[k] = os.clock() + (sec or COOLDOWN) end

-- анти-АФК
do
	local ok, VU = pcall(function() return game:GetService("VirtualUser") end)
	if ok and VU then
		table.insert(state.connections, player.Idled:Connect(function()
			pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new()) end)
		end))
	end
end

table.insert(state.connections, player.CharacterAdded:Connect(function() state.lastEgg, state.lastArea, state.atMachine = nil, nil, nil end))

-- ===== телепорт =====
local function findTeleportFn()
	if getsenv then
		for _, d in ipairs(player.PlayerScripts:GetDescendants()) do
			if d.Name == "Teleport" and (d:IsA("LocalScript") or d:IsA("ModuleScript")) then
				local ok, senv = pcall(getsenv, d)
				if ok and type(senv) == "table" and type(senv.Teleport) == "function" then
					return senv.Teleport
				end
			end
		end
	end
	return findFn("Teleport", "You are already teleporting!")
end

local function manualTeleport(area)
	local WC = Library.WorldCmds
	if Library.Variables.Teleporting then return false, "You are already teleporting!" end
	if not WC.CanDoAction() then return false, "Cannot perform actions right now" end

	local a = Dir.Areas[area]
	if not a then return false, "Unknown area!" end
	if not (WC.HasAccess(a.world) and WC.HasArea(area) and WC.HasTeleport(area)) then
		return false, "Нет доступа к миру/области или не куплен телепорт"
	end
	if WC.Get() ~= a.world and not WC.Load(a.world) then
		return false, "World failed to load!"
	end

	local map = WC.GetMap()
	local tp = map and map.Teleports and map.Teleports:FindFirstChild(area)
	if not tp then return false, "No such teleport for area!" end

	local char = player.Character or player.CharacterAdded:Wait()
	local hum = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")

	Library.Variables.Teleporting = true
	Library.Signal.Fire("Teleporting")
	task.wait(0.25)
	local cf = tp.CFrame
	char:PivotTo(cf + cf.UpVector * (hum.HipHeight + root.Size.Y / 2))
	pcall(Library.Network.Fire, "Performed Teleport", area)
	task.wait(0.25)
	Library.Variables.Teleporting = false
	return true
end

local TeleportFn = findTeleportFn()
if TeleportFn then
	warn("[IndexFarm] Телепорт: функция игры найдена.")
else
	TeleportFn = manualTeleport
	warn("[IndexFarm] Телепорт: использую запасной вариант.")
end

-- ===== телепорт между мирами =====
-- Смена мира делается через WorldCmds.Load внутри функции игры. Если вызывать её из потока executor,
-- игра может отклонять внутренние сетевые вызовы (как с яйцами), и мир не меняется.
-- Поэтому пробуем по очереди 3 способа и каждый раз ПРОВЕРЯЕМ, что мир реально сменился:
--   1) функция Teleport игры;  2) нажатие кнопки области в окне Teleport (выполняется в контексте игры);
--   3) Force Teleport (локальный BindableFunction игры).
local function curWorld()
	local ok, w = pcall(Library.WorldCmds.Get)
	return ok and w or nil
end

local function arrived(area)
	local a = Dir.Areas[area]
	if not a or curWorld() ~= a.world then return false end
	local ok, map = pcall(Library.WorldCmds.GetMap)
	return ok and typeof(map) == "Instance" and map.Parent ~= nil and map:FindFirstChild("Teleports") ~= nil
end

-- можно ли сейчас телепортироваться (не идёт анимация яйца, игра разрешает действия)
local function canAct()
	local oe = Library.Variables.OpeningEgg
	if oe and oe > 0 then return false end
	local ok, res = pcall(Library.WorldCmds.CanDoAction)
	if ok and res == false then return false end
	return true
end

-- ждём, пока можно действовать (яйца открываются быстро, поэтому перед телепортом даём анимации закончиться)
local function waitCanAct(sec)
	local t0 = os.clock()
	while state.running and not canAct() and os.clock() - t0 < sec do
		task.wait(0.1)
	end
end

-- ждём окончания телепорта/загрузки мира и появления персонажа
-- если телепорт даже не начался (игра отказала) - не ждём весь таймаут, а сразу возвращаем false для новой попытки
local function waitArrived(area, sec)
	local t0 = os.clock()
	local started = false
	task.wait(0.3)
	while os.clock() - t0 < sec do
		if Library.Variables.Teleporting then started = true end
		if not Library.Variables.Teleporting and arrived(area) then
			local c0 = os.clock()
			while not (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) and os.clock() - c0 < 10 do
				task.wait(0.2)
			end
			return true
		end
		if not started and os.clock() - t0 > 4 then return false end
		task.wait(0.2)
	end
	return false
end

local function viaGame(area)
	local ok, success, msg = pcall(TeleportFn, area)
	if not ok then
		Library.Variables.Teleporting = false -- функция игры упала и оставила флаг включённым
		return false, tostring(success)
	end
	if not success then return false, tostring(msg) end
	return true
end

local function viaUI(area)
	local gui = Library.GUI and Library.GUI.Teleport
	local holder = gui and gui.Holder
	local btn = holder and holder:FindFirstChild(area)
	if not btn then return false, "кнопка области «" .. area .. "» не найдена в окне телепортов" end
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

local function viaForce(area)
	local a = Dir.Areas[area]
	if not (a and Library.WorldCmds.HasAccess(a.world) and Library.WorldCmds.HasArea(area)) then
		return false, "нет доступа к области"
	end
	local ok, res, msg = pcall(Library.Network.Invoke, "Force Teleport", area)
	if not ok then return false, tostring(res) end
	if res == false then return false, tostring(msg) end
	return true
end

local TELEPORT_STRATEGIES = {
	{ "функция игры", viaGame },
	{ "кнопка в окне Teleport", viaUI },
	{ "Force Teleport", viaForce },
}

local function safeTeleport(area)
	local lastErr = "unknown"
	for attempt = 1, TELEPORT_RETRIES do
		if not state.running then return false, "остановлено" end
		for i, st in ipairs(TELEPORT_STRATEGIES) do
			if not state.running then return false, "остановлено" end
			waitCanAct(20) -- анимация яйца / запрет действий: ждём только пока это реально мешает
			local okS, errS = st[2](area)
			if okS and waitArrived(area, 25) then
				if attempt > 1 or i > 1 then
					warn(string.format("[IndexFarm] Телепорт в «%s» сработал (%s, попытка %d)", area, st[1], attempt))
				end
				task.wait(0.3)
				return true
			end
			errS = tostring(errS or "телепорт не начался / мир не загрузился")
			lastErr = st[1] .. ": " .. errS
			if attempt == 1 or attempt % 3 == 0 then
				warn(string.format("[IndexFarm] Телепорт в «%s» (%s, попытка %d/%d): %s | мир сейчас: %s",
					area, st[1], attempt, TELEPORT_RETRIES, errS, tostring(curWorld())))
			end
			if errS:find("do not have access", 1, true) or errS:find("do not own", 1, true)
				or errS:find("Unknown area", 1, true) or errS:find("нет доступа", 1, true) then
				return false, lastErr
			end
			if errS:find("already teleporting", 1, true) then
				if attempt >= 3 then Library.Variables.Teleporting = false end
				break
			end
			-- игра сейчас не даёт действовать: другие способы не помогут, ждём и пробуем заново
			if errS:find("Cannot perform actions", 1, true) or errS:find("right now", 1, true) then
				break
			end
		end
		if attempt < TELEPORT_RETRIES then task.wait(0.5) end
	end
	return false, lastErr
end

-- ===== машины Golden / Rainbow (стоят в первом мире, область Town) =====
-- Из любого другого мира скрипт сам телепортирует в область машин, находит там модель и подходит к ней.
-- Крафт без подхода к машине НЕ делается: если дойти не вышло, цель продолжает фармиться яйцами, а крафт повторяется позже.
local machineCache, machineFail, machineWarnAt = {}, {}, 0

local function machinePos(inst)
	if inst:IsA("Model") then return inst:GetPivot().Position end
	return inst.Position
end

local function areaUsable(an)
	local a = an and Dir.Areas[an]
	if not a then return false end
	local ok, res = pcall(function()
		local WC = Library.WorldCmds
		return WC.HasAccess(a.world) and WC.HasArea(an) and WC.HasTeleport(an)
	end)
	return ok and res and true or false
end

-- область, где стоят машины: MACHINE_AREA -> "Town" -> авто (самая первая область первого мира)
local loggedMachineArea
local function machineArea()
	local pick
	if MACHINE_AREA and areaUsable(MACHINE_AREA) then
		pick = MACHINE_AREA
	elseif areaUsable("Town") then
		pick = "Town"
	else
		local firstWorld, order
		for wn, w in pairs(Dir.Worlds) do
			local o = w.worldOrder or math.huge
			if not order or o < order then firstWorld, order = wn, o end
		end
		local bestMult
		for an, a in pairs(Dir.Areas) do
			if a.world == firstWorld and not a.hidden then
				local m = a.mult or math.huge
				if not bestMult or m < bestMult then pick, bestMult = an, m end
			end
		end
	end
	if pick and loggedMachineArea ~= pick then
		loggedMachineArea = pick
		local a = Dir.Areas[pick]
		warn(string.format("[IndexFarm] Область с машинами: «%s» (мир «%s»)", pick, tostring(a and a.world)))
	end
	return pick
end

-- мы сейчас в том мире, где стоят машины?
local function inMachineWorld()
	local mArea = machineArea()
	local a = mArea and Dir.Areas[mArea]
	return a ~= nil and curWorld() == a.world
end

-- ищем модель машины по имени (ID/Remote игры не нужны): "Golden Machine" / "Rainbow Machine"
-- ВАЖНО: ищем только когда мы в мире машин, иначе можно найти устаревшую/чужую модель и "подойти" к ней не в том мире
local function findMachine(kind)
	if not inMachineWorld() then
		machineCache[kind] = nil
		return nil
	end
	local cached = machineCache[kind]
	if cached and cached.Parent and cached:IsDescendantOf(workspace) then return cached end
	machineCache[kind] = nil

	local words = (kind == "golden") and { "golden", "gold" } or { "rainbow" }
	local function match(n)
		n = n:lower()
		if not n:find("machine", 1, true) then return false end
		for _, w in ipairs(words) do
			if n:find(w, 1, true) then return true end
		end
		return false
	end
	local roots = {}
	local okMap, map = pcall(Library.WorldCmds.GetMap)
	if okMap and typeof(map) == "Instance" then roots[#roots + 1] = map end
	roots[#roots + 1] = workspace
	local camera = workspace.CurrentCamera
	for _, root in ipairs(roots) do
		local part
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("Model") or d:IsA("BasePart")) and match(d.Name)
				and not (camera and d:IsDescendantOf(camera))
				and not (player.Character and d:IsDescendantOf(player.Character)) then
				if d:IsA("Model") then
					machineCache[kind] = d
					return d
				end
				part = part or d
			end
		end
		if part then
			machineCache[kind] = part
			return part
		end
	end
	return nil
end

local function listMachineNames()
	local names, seen = {}, {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower():find("machine", 1, true) then
			local full = d:GetFullName()
			if not seen[full] and #names < 12 then
				seen[full] = true
				names[#names + 1] = full
			end
		end
	end
	return names
end

-- телепорт к машине: kind = "golden" | "rainbow". Возвращает true | false, причина
local function goToMachine(kind)
	local mArea = machineArea()
	if not mArea then return false, "не нашёл область с машинами" end
	local mWorld = Dir.Areas[mArea].world

	-- уже стоим у этой машины в нужном мире
	if state.atMachine == kind and inMachineWorld()
		and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
		return true
	end
	if (machineFail[kind] or 0) > os.clock() then return false, "машина недоступна (повторю позже)" end

	local function fail(msg)
		machineFail[kind] = os.clock() + MACHINE_FAIL_COOLDOWN
		state.atMachine = nil
		return false, msg
	end

	-- 1) мы не в мире машин (яйцо в другом мире) -> сначала телепорт в Town
	local teleported = false
	if not inMachineWorld() then
		warn(string.format("[IndexFarm] Крафт: телепортирую к машинам в «%s» (мир «%s»), сейчас мир: %s",
			mArea, tostring(mWorld), tostring(curWorld())))
		local ok, err = safeTeleport(mArea)
		if not ok then return fail("телепорт в «" .. mArea .. "» не удался: " .. tostring(err)) end
		teleported = true
		if not inMachineWorld() then
			return fail("после телепорта мир не сменился (сейчас: " .. tostring(curWorld()) .. ")")
		end
	end

	-- 2) ищем модель машины
	local inst = findMachine(kind)
	if not inst and not teleported then
		-- мы в нужном мире, но не рядом с машинами (карта могла не подгрузиться) - телепорт в область машин
		local ok, err = safeTeleport(mArea)
		if not ok then return fail("телепорт в «" .. mArea .. "» не удался: " .. tostring(err)) end
		teleported = true
	end
	local t0 = os.clock()
	while not inst and os.clock() - t0 < 12 and state.running do
		inst = findMachine(kind)
		if not inst then task.wait(0.5) end
	end
	if not inst then
		local names = listMachineNames()
		return fail("модель машины не найдена. Похожие объекты: " ..
			(#names > 0 and table.concat(names, "; ") or "нет"))
	end

	-- 3) подходим к машине
	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:WaitForChild("HumanoidRootPart")
	local pos = machinePos(inst)
	local away = (root.Position - pos) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
	char:PivotTo(CFrame.new(pos + away * MACHINE_OFFSET + Vector3.new(0, 3, 0)))
	task.wait(0.5)

	state.atMachine = kind
	state.lastEgg = nil          -- чтобы после крафта скрипт вернулся к яйцу
	state.lastArea = mArea
	state.lastWorld = mWorld
	return true
end

-- режим открытия
-- как в оригинальном Eggs.lua: 3 = геймпасс "Triple Egg Open", 8 = save.OwnsOctupleEggs
local MAX_MODE = 1
do
	local save = Library.Save.Get()
	local hasTriple = Library.Gamepasses.Owns(Dir.Gamepasses["Triple Egg Open"].ID)
	local hasOctuple = save and save.OwnsOctupleEggs
	local best = hasOctuple and 8 or (hasTriple and 3 or 1)
	if OPEN_MODE == 0 then
		MAX_MODE = best
	elseif OPEN_MODE == 8 then
		MAX_MODE = hasOctuple and 8 or best
	elseif OPEN_MODE == 3 then
		MAX_MODE = (hasTriple or hasOctuple) and 3 or 1
	else
		MAX_MODE = 1
	end
	warn(string.format("[IndexFarm] Яиц за раз: %d (доступно максимум %d)", MAX_MODE, best))
end

-- сколько яиц открыть за раз: максимум из доступных, на который хватает валюты
-- сколько у игрока валюты (как в Currency.lua: в хардкоре отдельные валюты лежат в HardcoreCurrency)
local function getCurrency(name)
	local save = Library.Save.Get()
	if not save then return 0 end
	local d = Dir.Currency and Dir.Currency[name]
	if HC and d and d.HardcoreSeparate then
		return (save.HardcoreCurrency and save.HardcoreCurrency[name]) or 0
	end
	return save[name] or 0
end

local function modeFor(cost, currency)
	local have = getCurrency(currency)
	for _, m in ipairs({ 8, 3, 1 }) do
		if m <= MAX_MODE and have >= cost * m then return m end
	end
	return nil
end

-- ===== доступность яйца =====
local function eggUnlocked(name, save, depth)
	depth = depth or 0
	if depth > 6 then return false end
	local e = Dir.Eggs[name]
	if not e then return false end
	if e.areaRequired and not Library.WorldCmds.HasArea(e.area) then return false end
	local req = e.eggRequired or ""
	if req ~= "" and req ~= name and not eggUnlocked(req, save, depth + 1) then return false end
	if (e.eggRequiredOpenAmount or 0) > 0 and req ~= "" then
		local opened = (HC and save.Hardcore.EggsOpened or save.EggsOpened)[req]
		if not opened or opened < e.eggRequiredOpenAmount then return false end
	end
	if name == "Dominus Egg" then
		if HC then
			if not save.Hardcore.OwnsDominusGate then return false end
		elseif not save.OwnsDominusGate then return false end
	end
	if name == "Hacker Egg" or name == "Hacker Golden Egg" then
		if HC then
			if not save.Hardcore.OwnsHackerGate then return false end
		elseif not save.OwnsHackerGate then return false end
	end
	return true
end

local function eggCost(egg)
	if CostFn then
		local ok, c = pcall(CostFn, egg)
		if ok and type(c) == "number" then return c end
	end
	return (HC and egg.hardcoreCost or egg.cost) or 0
end

local function resolveDrops(egg)
	local d = egg.drops
	if type(d) == "string" then
		local o = Dir.Eggs[d]
		d = o and o.drops
	end
	return type(d) == "table" and d or nil
end

-- ===== инвентарь и крафт =====
local used = {}
local craftSnap, craftLast = nil, 0 -- снимок инвентаря перед крафтом (чтобы найти скрафченных петов и потом удалить их, когда они засчитаны в индекс)

local CRAFT = {
	golden = {
		label = "Golden", input = "normal", odds = "GoldMachineOdds",
		remote = "goldRemote", machine = "golden", n = math.max(5, GOLDEN_PETS),
	},
	rainbow = {
		label = "Rainbow", input = "golden", odds = "RainbowMachineOdds",
		remote = "rainbowRemote", machine = "rainbow", n = math.max(5, RAINBOW_PETS),
	},
}

local function inList(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

-- обычный/golden пет (rainbow, dark matter и прочие мутации в крафте не участвуют)
local function kindOf(pet)
	if pet.r or pet.dm or pet.l then return nil end
	return pet.g and "golden" or "normal"
end

-- можно ли вообще крафтить этого пета в машинах
local function craftable(petId)
	local d = Dir.Pets[petId]
	if not d then return false end
	if d.isPremium or d.isGift then return false end
	if d.rarity == "Event" or d.rarity == "Exclusive" then return false end
	if inList(SKIP_RARITIES, d.rarity) then return false end
	return true
end

-- самая большая группа одинаковых петов (одинаковые hc/shiny), которую можно положить в машину
local function bestGroup(petId, kind)
	local save = Library.Save.Get()
	if not save then return {}, false end
	local groups, best = {}, nil
	for _, pet in ipairs(save.Pets) do
		if tostring(pet.id) == petId and not used[pet.uid] and kindOf(pet) == kind and (not HC or pet.hc) then
			local k = (pet.hc and "hc" or "") .. "|" .. (pet.sh and "sh" or "")
			local g = groups[k]
			if not g then
				g = { hc = pet.hc or false, uids = {} }
				groups[k] = g
			end
			g.uids[#g.uids + 1] = pet.uid
			if not best or #g.uids > #best.uids then best = g end
		end
	end
	if best then return best.uids, best.hc end
	return {}, false
end

local function countOf(petId, kind)
	local uids = bestGroup(petId, kind)
	return #uids
end

local function inBooth(uid)
	local ok, res = pcall(Library.Signal.Invoke, "Is Trading Booth Pet", uid)
	return ok and res
end

local function keepsAPet(chosen)
	local save = Library.Save.Get()
	if not save then return false end
	for _, p in ipairs(save.Pets) do
		if not (table.find(chosen, p.uid) or (not p.hc and HC)) then
			return true
		end
	end
	return false
end

-- сколько ещё нужно ОТКРЫТЬ петов (обычных, либо golden из golden-яиц), чтобы дойти до цели
local function needFor(petId, variant, direct)
	if variant == 1 or (variant == 2 and direct) then return 1 end
	local GP, RP = CRAFT.golden.n, CRAFT.rainbow.n
	if variant == 2 then
		return math.max(0, GP - countOf(petId, "normal"))
	end
	local goldNeed = math.max(0, RP - countOf(petId, "golden"))
	if direct then return goldNeed end
	return math.max(0, goldNeed * GP - countOf(petId, "normal"))
end

-- один крафт. Возвращает "crafted" | "refused" | "wait" | "noremote" | "nomachine", craftInfo
local function craft(petId, what)
	local c = CRAFT[what]
	local uids, hc = bestGroup(petId, c.input)
	if #uids < c.n then return "wait" end

	local remote = state[c.remote]
	if not remoteOk(remote) then
		state[c.remote] = nil
		return "noremote", c
	end

	local chosen = {}
	for _, uid in ipairs(uids) do
		if inBooth(uid) then
			used[uid] = true
		else
			chosen[#chosen + 1] = uid
			if #chosen >= c.n then break end
		end
	end
	if #chosen < c.n or not keepsAPet(chosen) then return "wait" end

	-- машины стоят в первом мире: сначала подходим к машине (если не вышло - пробуем крафт и так)
	local okM, errM = goToMachine(c.machine)
	if not okM then
		if os.clock() - machineWarnAt > 60 then
			machineWarnAt = os.clock()
			warn("[IndexFarm] Не удалось подойти к " .. c.label .. " Machine: " .. tostring(errM) .. ". Крафт отложен, продолжаю фарм, повторю позже.")
		end
		return "nomachine", c
	end

	local row
	local okRows, rows = pcall(Library.RebornBalance.MachineRows, Library.Shared[c.odds], hc)
	if okRows and type(rows) == "table" and #rows > 0 then
		for i = #chosen, #rows + 1, -1 do chosen[i] = nil end
		row = rows[#chosen]
	end
	for _, uid in ipairs(chosen) do used[uid] = true end

	local dirPet = Dir.Pets[petId]
	warn(string.format("[IndexFarm] %s-крафт: %s x%d | шанс %s%% | цена %s",
		c.label, dirPet and dirPet.name or petId, #chosen,
		tostring(row and row.chance), tostring(row and row.cost)))

	-- снимок инвентаря до крафта: петы, которые появятся после него, считаем нашими (для авто-удаления)
	if not craftSnap then
		local snapNow, sv = {}, Library.Save.Get()
		if sv then
			for _, p in ipairs(sv.Pets) do snapNow[p.uid] = true end
		end
		craftSnap = snapNow
	end
	craftLast = os.clock()

	Library.Variables.UsingMachine = true
	local res = table.pack(pcall(function() return remote:InvokeServer(chosen) end))
	task.wait(0.5)
	Library.Variables.UsingMachine = false

	if res[1] and res[2] then return "crafted" end
	warn("[IndexFarm] Крафт отклонён:", tostring(res[1]), tostring(res[2]), tostring(res[3]))
	return "refused"
end

-- что крафтить для цели прямо сейчас
local function tryCraft(t)
	if t.variant == 1 then return "wait" end
	if t.variant == 2 then
		if t.direct then return "wait" end
		return craft(t.petId, "golden")
	end
	-- rainbow: сначала rainbow из 6 golden, иначе golden из 6 обычных
	local s, c = craft(t.petId, "rainbow")
	if s ~= "wait" and s ~= "nomachine" then return s, c end
	if not t.direct then
		local s2, c2 = craft(t.petId, "golden")
		if s2 ~= "wait" then return s2, c2 end
	end
	return s
end

-- ===== удаление ненужных петов (только выпавших из яиц в этом запуске) =====
local farmed = {}                 -- uid -> true: пет выпал из яйца, которое открыл скрипт
local snapUids, snapEgg, snapTries = nil, nil, 0
local deletedTotal = 0
local lastDebug = 0
local lastFlushAt = 0

local collectableAll = {}         -- "id-вариант" -> true для всех петов индекса
for _, p in ipairs(Library.Shared.GetAllCollectablePets()) do
	local v = p.isGolden and 2 or (p.isRainbow and 3 or (p.isDarkMatter and 4 or 1))
	collectableAll[tostring(p.petId) .. "-" .. v] = true
end

local function snapshotPets()
	local s = {}
	local save = Library.Save.Get()
	if save then
		for _, pet in ipairs(save.Pets) do s[pet.uid] = true end
	end
	return s
end

-- после открытия яйца: новые uid, которых не было до покупки и которые реально есть в дропе этого яйца
-- если новых петов ещё нет (сейв не успел обновиться) - снимок сохраняется, проверим ещё раз (до 3 раз)
local function harvest()
	if not snapUids then return end
	local save = Library.Save.Get()
	local egg = Dir.Eggs[snapEgg]
	local drops = egg and resolveDrops(egg)
	local found = 0
	if save and drops then
		local ids = {}
		for _, d in ipairs(drops) do ids[tostring(d[1])] = true end
		local goldenEgg = egg.isGolden and true or false
		for _, pet in ipairs(save.Pets) do
			if not snapUids[pet.uid] and ids[tostring(pet.id)]
				and (pet.g and true or false) == goldenEgg and not pet.r and not pet.dm then
				if not farmed[pet.uid] then found += 1 end
				farmed[pet.uid] = true
			end
		end
	end
	snapTries += 1
	if found > 0 or snapTries >= (WAIT_EGG_ANIMATION and 3 or 12) or not (save and drops) then
		snapUids, snapTries = nil, 0
	end
end

-- после крафта: новые golden/rainbow петы (результат крафта) добавляем в список "наших" петов, чтобы удалить их, когда они засчитаны в индекс
local function harvestCrafts()
	if not craftSnap then return end
	local save = Library.Save.Get()
	if save then
		for _, pet in ipairs(save.Pets) do
			if not craftSnap[pet.uid] and (pet.g or pet.r) and not pet.dm then
				farmed[pet.uid] = true
			end
		end
	end
	if os.clock() - craftLast > 15 then craftSnap = nil end
end

local function pendingVariant(id, v, owned)
	return inList(VARIANTS, v) and collectableAll[id .. "-" .. v] and not owned[id .. "-" .. v]
end

-- сколько копий нужно держать для крафта (nil = пет для крафта не нужен)
local function capFor(id, kind, owned)
	if kind == "normal" then
		if pendingVariant(id, 3, owned) then return CRAFT.rainbow.n * CRAFT.golden.n + KEEP_EXTRA_COPIES end
		if pendingVariant(id, 2, owned) then return CRAFT.golden.n + KEEP_EXTRA_COPIES end
	elseif kind == "golden" and pendingVariant(id, 3, owned) then
		return CRAFT.rainbow.n + KEEP_EXTRA_COPIES
	end
	return nil
end

-- nil = можно удалить; "need" = нужен для крафта (удаляем только излишек); иначе причина, почему оставляем
local function keepReason(pet, save, owned)
	local id = tostring(pet.id)
	local d = Dir.Pets[id]
	if not d then return "нет в Directory" end
	if pet.l then return "locked" end
	if d.huge or d.titanic then return "huge/titanic" end
	if d.isPremium or d.isGift or pet.merchData or d.rarity == "Event" or d.rarity == "Exclusive" then return "ценный" end
	if tostring(d.rarity or ""):lower():find("mythic", 1, true) then return "Mythic (всегда оставляем)" end
	if inList(KEEP_RARITIES, d.rarity) then return "редкость " .. tostring(d.rarity) end
	if pet.dm then return "мутация" end
	if KEEP_SHINY and pet.sh then return "shiny" end
	local okEq, eq = pcall(Library.Shared.HasPetEquipped, save, pet)
	if okEq and eq then return "надет" end
	if inBooth(pet.uid) then return "trading booth" end

	local kind = kindOf(pet)
	local variant
	if pet.r then
		variant = 3
	elseif kind == "golden" then
		variant = 2
	elseif kind == "normal" then
		variant = 1
	else
		return "мутация"
	end
	-- пет ещё не засчитан в индекс - оставляем; как только засчитан (и не нужен для крафта) - можно удалять
	if collectableAll[id .. "-" .. variant] and not owned[id .. "-" .. variant] then
		return "ещё нет в индексе"
	end
	if kind and craftable(id) and capFor(id, kind, owned) then return "need" end
	return nil
end

-- сколько uid из chunk реально исчезло из инвентаря (ждём обновления сейва до 3 сек)
local function removedCount(chunk)
	local n = 0
	local t0 = os.clock()
	repeat
		task.wait(0.25)
		local save = Library.Save.Get()
		n = 0
		if save then
			local present = {}
			for _, pet in ipairs(save.Pets) do present[pet.uid] = true end
			for _, u in ipairs(chunk) do
				if not present[u] then n += 1 end
			end
		end
	until n == #chunk or os.clock() - t0 > 3
	return n
end

local function sendDelete(chunk)
	local res
	if remoteOk(state.deleteRemote) then
		res = table.pack(pcall(function() return state.deleteRemote:InvokeServer(chunk) end))
	else
		res = table.pack(pcall(Library.Network.Invoke, "Delete Several Pets", chunk))
	end
	local n = removedCount(chunk)
	if n == 0 then
		warn("[IndexFarm] Ответ на удаление:", tostring(res[1]), tostring(res[2]), tostring(res[3]))
	end
	return n
end

local function flushDeletes(force)
	if not DELETE_JUNK then return end
	if not force and os.clock() - lastFlushAt < FLUSH_INTERVAL then return end
	lastFlushAt = os.clock()
	harvestCrafts()
	local save = Library.Save.Get()
	if not (save and next(farmed)) then return end

	-- Remote удаления не пойман и прямой вызов уже не сработал: ждём ручное удаление, фарм не блокируем
	if not remoteOk(state.deleteRemote) and state.deleteDirectFailed and not DRY_RUN then
		if os.clock() - state.deleteHintAt > 60 then
			state.deleteHintAt = os.clock()
			warn("[IndexFarm] Для авто-удаления нужен Remote: удали вручную ОДНОГО ненужного пета (инвентарь -> корзина -> выбери пета -> Delete -> подтверди). Скрипт поймает Remote и дальше удаляет сам, фарм не останавливается.")
		end
		return
	end

	local owned = {}
	for _, k in ipairs(save.Collection) do owned[k] = true end

	local present, counts = {}, {}
	for _, pet in ipairs(save.Pets) do
		present[pet.uid] = true
		local k = kindOf(pet)
		if k then
			local ck = tostring(pet.id) .. "|" .. k
			counts[ck] = (counts[ck] or 0) + 1
		end
	end
	for uid in pairs(farmed) do
		if not present[uid] then farmed[uid] = nil end
	end

	local del, needGroups, reasons, farmedCount = {}, {}, {}, 0
	for _, pet in ipairs(save.Pets) do
		if farmed[pet.uid] then
			farmedCount += 1
			local r = keepReason(pet, save, owned)
			if r == nil then
				del[#del + 1] = pet
			elseif r == "need" then
				local k = tostring(pet.id) .. "|" .. kindOf(pet)
				needGroups[k] = needGroups[k] or {}
				table.insert(needGroups[k], pet)
			else
				reasons[r] = (reasons[r] or 0) + 1
			end
		end
	end
	-- излишек сверх нужного для крафта (из выбитых скриптом)
	for k, list in pairs(needGroups) do
		local id, kind = k:match("^(.-)|(.+)$")
		local cap = capFor(id, kind, owned)
		local excess = cap and ((counts[k] or 0) - cap) or 0
		local delN = math.max(0, math.min(excess, #list))
		for i = 1, delN do del[#del + 1] = list[i] end
		if #list - delN > 0 then
			reasons["запас для крафта"] = (reasons["запас для крафта"] or 0) + (#list - delN)
		end
	end

	-- диагностика: почему ничего не удаляется
	if DELETE_DEBUG and #del < DELETE_BATCH and os.clock() - lastDebug > 30 then
		lastDebug = os.clock()
		local rp = {}
		for r, n in pairs(reasons) do rp[#rp + 1] = r .. " x" .. n end
		table.sort(rp)
		warn(string.format("[IndexFarm] Удаление: выбито в списке %d, к удалению %d (пачка от %d), оставлено: %s",
			farmedCount, #del, DELETE_BATCH, #rp > 0 and table.concat(rp, ", ") or "-"))
	end

	if #del == 0 or (#del < DELETE_BATCH and not force) then return end

	-- защиты
	if #del > DELETE_MAX then
		for i = #del, DELETE_MAX + 1, -1 do del[i] = nil end
	end
	if #save.Pets - #del < MIN_PETS_LEFT then
		warn(string.format("[IndexFarm] Удаление отменено: в инвентаре %d, после удаления осталось бы меньше %d.", #save.Pets, MIN_PETS_LEFT))
		return
	end

	local summary = {}
	for _, pet in ipairs(del) do
		local nm = Dir.Pets[tostring(pet.id)].name
		summary[nm] = (summary[nm] or 0) + 1
	end
	local parts = {}
	for nm, n in pairs(summary) do parts[#parts + 1] = nm .. " x" .. n end
	table.sort(parts)
	warn(string.format("[IndexFarm] %s %d петов: %s",
		DRY_RUN and "(DRY_RUN) Удалил бы" or "Удаляю", #del, table.concat(parts, ", ")))

	local uids = {}
	for i, pet in ipairs(del) do uids[i] = pet.uid end

	if DRY_RUN then
		for _, u in ipairs(uids) do farmed[u] = nil end
		return
	end

	local removedTotal = 0
	for i = 1, #uids, 25 do
		local chunk = table.move(uids, i, math.min(i + 24, #uids), 1, {})
		local n = sendDelete(chunk)

		if n == 0 and not remoteOk(state.deleteRemote) then
			-- прямой вызов не сработал: ждём ручное удаление (хук поймает Remote), uid остаются в списке
			state.deleteDirectFailed = true
			state.deleteHintAt = os.clock()
			warn("[IndexFarm] Прямое удаление не сработало. Удали вручную ОДНОГО ненужного пета (инвентарь -> корзина -> выбери пета -> Delete -> подтверди): скрипт поймает Remote и дальше удаляет сам. Фарм продолжается.")
			break
		end

		if n == 0 then
			-- Remote есть, но ничего не удалилось: не долбим его, пока не поймаем заново
			state.deleteRemote = nil
			state.deleteDirectFailed = true
			state.deleteHintAt = os.clock()
			warn("[IndexFarm] Remote удаления ничего не удалил, сбрасываю. Удали вручную одного пета, чтобы поймать заново.")
			break
		end

		removedTotal += n
		for _, u in ipairs(chunk) do farmed[u] = nil end
		task.wait(0.3)
	end
	deletedTotal += removedTotal
	if removedTotal > 0 then
		warn(string.format("[IndexFarm] Удалено %d из %d (всего за запуск: %d)", removedTotal, #uids, deletedTotal))
	end
end

-- ===== поиск целей =====
local function buildCandidates(variant, wantBroke)
	local save = Library.Save.Get()
	if not (save and save.Collection) then return {} end

	local owned = {}
	for _, k in ipairs(save.Collection) do owned[k] = true end

	local collectable = {}
	for _, p in ipairs(Library.Shared.GetAllCollectablePets()) do
		local v = p.isGolden and 2 or (p.isRainbow and 3 or (p.isDarkMatter and 4 or 1))
		if v == variant then collectable[tostring(p.petId)] = true end
	end

	local needCache = {}
	local function need(petId, direct)
		local k = petId .. (direct and "|d" or "|n")
		if needCache[k] == nil then needCache[k] = needFor(petId, variant, direct) end
		return needCache[k]
	end

	local best = {}
	for eggName, egg in pairs(Dir.Eggs) do
		local direct = egg.isGolden and true or false
		local route = (variant == 1 and not direct) or (variant >= 2 and (not direct or USE_GOLDEN_EGGS))
		local area = egg.area and Dir.Areas[egg.area]
		if route and area and not area.hidden
			and not isCooling("egg:" .. eggName)
			and Library.RebornLock.AreaOpen(egg.area)
			and Library.WorldCmds.HasAccess(area.world)
			and Library.WorldCmds.HasArea(egg.area)
			and Library.WorldCmds.HasTeleport(egg.area)
			and eggUnlocked(eggName, save) then

			local cost = eggCost(egg)
			local drops = resolveDrops(egg)
			local afford = getCurrency(egg.currency) >= cost
			if drops then
				local total = 0
				for _, d in ipairs(drops) do total += d[2] end

				if total > 0 then
					for _, d in ipairs(drops) do
						local petId, weight = tostring(d[1]), d[2]
						local key = petId .. "-" .. variant
						if weight > 0 and not (d[3] and not HC)
							and collectable[petId] and not owned[key] and not isCooling(key)
							and (variant == 1 or (variant == 2 and direct) or craftable(petId)) then

							local n = need(petId, direct)
							local chance = weight / total
							local score = (n == 0) and 0 or (n / chance)
							local cur = best[petId]
							if (n == 0 or afford or wantBroke) and chance * 100 >= MIN_CHANCE and score <= MAX_EXPECTED_OPENS
								and (not cur or score < cur.score or (score == cur.score and cost < cur.cost)) then
								best[petId] = {
									petId = petId, key = key, variant = variant,
									name = Dir.Pets[petId] and Dir.Pets[petId].name or petId,
									egg = eggName, area = egg.area, direct = direct,
									chance = chance, cost = cost, currency = egg.currency,
									need = n, score = score, broke = (n > 0 and not afford) or nil,
								}
							end
						end
					end
				end
			end
		end
	end

	local list = {}
	for _, v in pairs(best) do list[#list + 1] = v end
	table.sort(list, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.petId < b.petId
	end)
	return list
end

-- все варианты сразу: выбираем самую выгодную цель среди обычных / Golden / Rainbow
local function buildAllCandidates(wantBroke)
	local all = {}
	for _, v in ipairs(VARIANTS) do
		for _, c in ipairs(buildCandidates(v, wantBroke)) do all[#all + 1] = c end
	end
	table.sort(all, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		if a.variant ~= b.variant then return a.variant > b.variant end -- при равенстве: сначала rainbow/golden
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.key < b.key
	end)
	return all
end

-- штраф за дорогу: цели рядом (то же яйцо / та же область / тот же мир) выгоднее, чтобы не телепортироваться часто
local function applyTravel(list)
	local curWorld = state.lastWorld
	if not curWorld then
		local ok, w = pcall(Library.WorldCmds.Get)
		curWorld = ok and w or nil
	end
	for _, c in ipairs(list) do
		local cost = 0
		if c.need > 0 and c.egg ~= state.lastEgg then
			local world = Dir.Areas[c.area] and Dir.Areas[c.area].world
			if state.lastArea and c.area == state.lastArea then
				cost = 2
			elseif curWorld and world == curWorld then
				cost = TRAVEL_COST_AREA
			else
				cost = TRAVEL_COST_WORLD
			end
		end
		c.rank = c.score + cost
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.score ~= b.score then return a.score < b.score end
		if a.variant ~= b.variant then return a.variant > b.variant end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.key < b.key
	end)
end

-- ===== телепорт к яйцу =====
local function goTo(t)
	state.atMachine = nil
	-- уже стоим в этой области (соседнее яйцо) - заново в область не телепортируемся, просто подходим к яйцу
	local sameSpot = state.lastArea == t.area and Library.WorldCmds.GetMap() ~= nil and player.Character ~= nil
	if not sameSpot then
		local okT, errT = safeTeleport(t.area)
		if not okT then return false, errT end
	end
	state.lastArea = t.area
	state.lastWorld = Dir.Areas[t.area] and Dir.Areas[t.area].world

	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:WaitForChild("HumanoidRootPart")

	-- все яйца карты: у модели яйца атрибут ID, внутри Center (как в оригинальном Eggs.lua)
	local function scanEggs()
		local map = Library.WorldCmds.GetMap()
		local found = {}
		if not map then return found end
		local eggsFolder = map:FindFirstChild("Eggs") or map
		for _, d in ipairs(eggsFolder:GetDescendants()) do
			local id = d:GetAttribute("ID")
			if id and Dir.Eggs[id] then
				local c = d:FindFirstChild("Center")
				if c then found[id] = c end
			end
		end
		return found
	end

	local eggs, center = {}, nil
	local deadline = os.clock() + 12
	while not center and os.clock() < deadline and state.running do
		eggs = scanEggs()
		center = eggs[t.egg]
		if not center then task.wait(0.5) end
	end

	if not center then
		-- не открываем «с любой точки»: там стоит соседнее яйцо
		return false, "модель яйца «" .. t.egg .. "» не найдена на карте (возможно, не подгрузилась)"
	end

	-- встаём в 4 студах от нужного яйца, со стороны точки телепорта (соседние яйца близко, поэтому без больших смещений)
	local away = (root.Position - center.Position) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
	char:PivotTo(CFrame.new(center.Position + away * 4 + Vector3.new(0, 3, 0)))
	task.wait(0.5)

	-- проверка: ближайшее яйцо должно быть нужным
	local nearestId, nearestDist = nil, math.huge
	for id, c in pairs(eggs) do
		local dist = (c.Position - root.Position).Magnitude
		if dist < nearestDist then nearestId, nearestDist = id, dist end
	end
	if nearestId ~= t.egg then
		warn(string.format("[IndexFarm] Рядом оказалось «%s», а нужно «%s». Подхожу вплотную.", tostring(nearestId), t.egg))
		char:PivotTo(CFrame.new(center.Position + Vector3.new(0, 3, 0)))
		task.wait(0.5)
	else
		warn(string.format("[IndexFarm] Стою у «%s» (%.1f студов).", t.egg, nearestDist))
	end
	return true
end

-- ===== открытие яйца =====
local openCount = 0
table.insert(state.connections, Library.Signal.Fired("Opening Egg"):Connect(function()
	openCount += 1
end))

-- ждать окончания анимации открытия (только если WAIT_EGG_ANIMATION = true)
local function waitEggAnim()
	if not WAIT_EGG_ANIMATION then return end
	while Library.Variables.OpeningEgg > 0 and state.running do task.wait(0.1) end
end

local function buy(eggName, mode)
	local triple, octuple = (mode == 3), (mode == 8)
	if state.eggRemote and remoteOk(state.eggRemote) then
		return table.pack(pcall(function()
			return state.eggRemote[state.eggMethod](state.eggRemote, eggName, triple, octuple)
		end))
	end
	state.eggRemote = nil
	return table.pack(pcall(Library.Network.Invoke, "Buy Egg", eggName, triple, octuple))
end

local function hasPet(key)
	local save = Library.Save.Get()
	return save and Library.Functions.SearchArray(save.Collection, key) or false
end

-- возвращает "owned" | "failed" | "stopped" | "replan"
local function farm(t)
	local opens, fails, craftFails = 0, 0, 0
	local limit = math.max(20, math.ceil((t.need * 1.5 + 7) / t.chance))

	while state.active and state.running do
		if isMoving() then stop("движение") return "stopped" end
		waitEggAnim()
		if snapUids and WAIT_EGG_ANIMATION then task.wait(0.2) end
		harvest()
		flushDeletes(false)

		if hasPet(t.key) then return "owned" end
		if state.skipRequested then
			state.skipRequested = false
			return "skipped"
		end

		-- 1) крафт, если в инвентаре уже хватает петов
		local status, info = tryCraft(t)
		if status == "crafted" then
			craftFails = 0
			task.wait(CRAFT_DELAY)
			continue
		elseif status == "refused" then
			craftFails += 1
			if craftFails >= 3 then
				warn("[IndexFarm] 3 отказа крафта подряд (проверь валюту). Пропускаю цель.")
				return "failed"
			end
			task.wait(CRAFT_DELAY)
			continue
		elseif status == "noremote" then
			local okM, errM = goToMachine(info.machine)
			if not okM then
				warn("[IndexFarm] Хватает петов для " .. info.label .. "-крафта, но не удалось подойти к машине: " .. tostring(errM) .. ". Пропускаю цель.")
				return "failed"
			end
			warn("[IndexFarm] Хватает петов для " .. info.label .. "-крафта, но Remote не пойман. " ..
				"Сделай ОДИН " .. info.label .. "-крафт вручную (ОК + подтверждение), скрипт продолжит сам.")
			local w0 = os.clock()
			while state.running and not remoteOk(state[info.remote]) and os.clock() - w0 < 180 do task.wait(0.5) end
			if not remoteOk(state[info.remote]) then stop("Remote " .. info.label .. " не пойман") return "stopped" end
			continue
		end

		-- 2) дальше нужны яйца
		local need = needFor(t.petId, t.variant, t.direct)
		if need == 0 then
			if status == "nomachine" then
				warn("[IndexFarm] Петов хватает, но до машины добраться не вышло. Пропускаю цель, вернусь к ней позже.")
			else
				warn("[IndexFarm] Петов хватает, но крафт сейчас невозможен (trading booth или это последний пет). Пропускаю цель.")
			end
			return "failed"
		end
		if not t.here then return "replan" end

		-- после крафта мы стоим у машины: возвращаемся к яйцу
		if state.lastEgg ~= t.egg then
			local okG, errG = goTo(t)
			if not okG then
				warn("[IndexFarm] Не удалось вернуться к яйцу: " .. tostring(errG))
				coolDown("egg:" .. t.egg, 60)
				return "replan"
			end
			state.lastEgg = t.egg
		end

		if opens >= limit then
			warn("[IndexFarm] Лимит яиц достигнут: " .. t.name)
			return "failed"
		end

		local mode = modeFor(t.cost, t.currency)
		if not mode then
			warn("[IndexFarm] Не хватает валюты даже на 1 яйцо (" .. tostring(t.currency) .. ")." .. (CURRENCY_FARM.ENABLED and " Иду фармить валюту." or " Пропускаю цель."))
			return CURRENCY_FARM.ENABLED and "broke" or "failed"
		end

		local before = openCount
		-- снимок инвентаря до покупки (если прошлый снимок ещё не обработан и яйцо то же - оставляем его)
		if not snapUids or snapEgg ~= t.egg then
			snapUids, snapEgg, snapTries = snapshotPets(), t.egg, 0
		end
		local res = buy(t.egg, mode)
		local success = res[1] and res[2] and true or false

		local t0 = os.clock()
		while not success and openCount == before and os.clock() - t0 < 2 do task.wait(0.05) end
		success = success or openCount > before

		if success then
			opens += mode
			fails = 0
		else
			fails += 1
			warn("[IndexFarm] Отказ:", tostring(res[1]), tostring(res[2]), tostring(res[3]))
			if fails >= 3 then
				if state.eggRemote then
					warn("[IndexFarm] 3 отказа подряд (проверь валюту). Пропускаю цель.")
					return "failed"
				end
				warn("[IndexFarm] Не получилось открыть напрямую. Открой любое яйцо вручную ОДИН раз - скрипт подхватит Remote и продолжит.")
				local w0 = os.clock()
				while state.running and not state.eggRemote and os.clock() - w0 < 120 do task.wait(0.5) end
				if not state.eggRemote then stop("Remote яиц не пойман") return "stopped" end
				fails = 0
			end
		end

		task.wait(DELAY)
	end
	return "stopped"
end

local CF -- модуль фарма валюты объявлен ниже, перед главным циклом
-- ===== подготовка: поймать Remote-ы (яйца / удаление / Golden / Rainbow) =====
local function waitFor(getter, seconds)
	local t0 = os.clock()
	while state.running and not getter() and os.clock() - t0 < seconds do task.wait(0.5) end
	return getter() and true or false
end

local function worldOrderOf(areaName)
	local a = Dir.Areas[areaName]
	local w = a and Dir.Worlds[a.world]
	return w and w.worldOrder or math.huge
end

-- самое простое дешёвое яйцо (обычное или golden), которое сейчас доступно и по карману
local function cheapestEgg(golden)
	local save = Library.Save.Get()
	if not save then return nil end
	local best
	for eggName, egg in pairs(Dir.Eggs) do
		local isG = egg.isGolden and true or false
		local area = egg.area and Dir.Areas[egg.area]
		if isG == golden and area and not area.hidden
			and Library.RebornLock.AreaOpen(egg.area)
			and Library.WorldCmds.HasAccess(area.world)
			and Library.WorldCmds.HasArea(egg.area)
			and Library.WorldCmds.HasTeleport(egg.area)
			and eggUnlocked(eggName, save) then
			local cost = eggCost(egg)
			local drops = resolveDrops(egg)
			if drops and getCurrency(egg.currency) >= cost then
				local cand = {
					egg = eggName, area = egg.area, cost = cost, currency = egg.currency,
					wo = worldOrderOf(egg.area), mult = area.mult or math.huge,
				}
				if not best
					or cand.wo < best.wo
					or (cand.wo == best.wo and cand.mult < best.mult)
					or (cand.wo == best.wo and cand.mult == best.mult and cand.cost < best.cost) then
					best = cand
				end
			end
		end
	end
	return best
end

-- есть ли в инвентаре пет нужного вида для крафта (и ещё хотя бы один, чтобы один пет остался)
local function haveCraftable(kind)
	local save = Library.Save.Get()
	if not save or #save.Pets < 2 then return false end
	for _, pet in ipairs(save.Pets) do
		if kindOf(pet) == kind and craftable(tostring(pet.id)) and not inBooth(pet.uid) and (not HC or pet.hc) then
			return true
		end
	end
	return false
end

-- открывать по 1 яйцу, пока не выполнится cond()
local function openUntil(e, cond, limit)
	local opens, fails = 0, 0
	while state.running and not cond() and opens < limit do
		waitEggAnim()
		if not modeFor(e.cost, e.currency) then
			warn("[IndexFarm] Не хватает валюты на яйцо «" .. e.egg .. "».")
			return false
		end
		local before = openCount
		snapUids, snapEgg, snapTries = snapshotPets(), e.egg, 0
		local res = buy(e.egg, 1)
		local success = res[1] and res[2] and true or false
		local t0 = os.clock()
		while not success and openCount == before and os.clock() - t0 < 2 do task.wait(0.05) end
		success = success or openCount > before
		if success then
			opens += 1
			fails = 0
		else
			fails += 1
			if fails >= 3 then
				warn("[IndexFarm] Яйцо «" .. e.egg .. "» не открывается (3 отказа подряд).")
				return false
			end
		end
		waitEggAnim()
		task.wait(0.2)
		harvest()
		task.wait(DELAY)
	end
	return cond() and true or false
end

local function bootstrap()
	-- 0. Remote-ы монет (клик по монете + тест фарма)
	if CURRENCY_FARM.ENABLED and not CF.ready() and state.running then
		CF.learnCoins(nil)
	end

	-- A. Remote яиц
	if not remoteOk(state.eggRemote) and state.running then
		local e = cheapestEgg(false)
		if not e then
			warn("[IndexFarm] Подготовка: не нашёл доступного дешёвого яйца для теста.")
		else
			warn(string.format("[IndexFarm] Подготовка: Remote яиц неизвестен. Телепорт к самому дешёвому яйцу «%s»...", e.egg))
			local ok, err = goTo(e)
			if not ok then
				warn("[IndexFarm] Телепорт к яйцу не удался: " .. tostring(err))
			else
				state.lastEgg = e.egg
				local before = openCount
				snapUids, snapEgg, snapTries = snapshotPets(), e.egg, 0
				local res = buy(e.egg, 1)
				local success = res[1] and res[2] and true or false
				local t0 = os.clock()
				while not success and openCount == before and os.clock() - t0 < 2 do task.wait(0.05) end
				success = success or openCount > before
				if success then
					warn("[IndexFarm] Прямое открытие яиц работает, ручное открытие не нужно.")
				else
					warn("[IndexFarm] >>> ОТКРОЙ ЭТО ЯЙЦО ВРУЧНУЮ ОДИН РАЗ (подойди и нажми E / купи) - скрипт запомнит Remote и продолжит. <<<")
					if not waitFor(function() return remoteOk(state.eggRemote) end, BOOTSTRAP_WAIT) then
						warn("[IndexFarm] Remote яиц не пойман, продолжаю как есть.")
					end
				end
				waitEggAnim()
				task.wait(0.3)
				harvest()
			end
		end
	end

	-- B. Remote удаления
	if DELETE_JUNK and not DRY_RUN and not remoteOk(state.deleteRemote) and state.running then
		warn("[IndexFarm] >>> УДАЛЕНИЕ: удали вручную ОДНОГО ненужного пета (инвентарь -> корзина -> выбери пета -> Delete -> подтверди). Скрипт запомнит Remote и дальше удаляет выбитых ненужных сам. <<<")
		if waitFor(function() return remoteOk(state.deleteRemote) end, BOOTSTRAP_WAIT) then
			warn("[IndexFarm] Подготовка: Remote удаления готов.")
		else
			warn("[IndexFarm] Remote удаления не пойман: авто-удаление заработает после ручного удаления пета, фарм идёт дальше.")
		end
	end

	local needGold = inList(VARIANTS, 2) or inList(VARIANTS, 3)
	local needRainbow = inList(VARIANTS, 3)

	-- C. Remote Golden Machine
	if needGold and not remoteOk(state.goldRemote) and state.running then
		if not haveCraftable("normal") then
			local e = cheapestEgg(false)
			if e then
				warn(string.format("[IndexFarm] Подготовка: нужен пет для Golden-крафта. Открываю дешёвое яйцо «%s»...", e.egg))
				local ok, err = goTo(e)
				if ok then
					state.lastEgg = e.egg
					openUntil(e, function() return haveCraftable("normal") end, 20)
				else
					warn("[IndexFarm] Телепорт к яйцу не удался: " .. tostring(err))
				end
			else
				warn("[IndexFarm] Подготовка: нет доступного дешёвого яйца.")
			end
		end
		local ok, err = goToMachine("golden")
		if not ok then warn("[IndexFarm] Не удалось подойти к Golden Machine: " .. tostring(err)) end
		warn("[IndexFarm] >>> GOLDEN MACHINE: открой машину, выбери ЛЮБОГО обычного пета (хватит одного), нажми OK и подтверди - скрипт запомнит Remote. <<<")
		if waitFor(function() return remoteOk(state.goldRemote) end, BOOTSTRAP_WAIT) then
			warn("[IndexFarm] Подготовка: Remote Golden Machine готов.")
		else
			warn("[IndexFarm] Remote Golden Machine не пойман (скрипт попросит снова, когда понадобится крафт).")
		end
	end

	-- D. Remote Rainbow Machine
	if needRainbow and not remoteOk(state.rainbowRemote) and state.running then
		if not haveCraftable("golden") then
			local e = cheapestEgg(true)
			if e then
				warn(string.format("[IndexFarm] Подготовка: нужен golden пет для Rainbow-крафта. Открываю дешёвое golden-яйцо «%s»...", e.egg))
				local ok, err = goTo(e)
				if ok then
					state.lastEgg = e.egg
					openUntil(e, function() return haveCraftable("golden") end, 20)
				else
					warn("[IndexFarm] Телепорт к яйцу не удался: " .. tostring(err))
				end
			else
				warn("[IndexFarm] Подготовка: нет доступного golden-яйца (не хватает валюты/доступа). Получи golden пета сам (например в Golden Machine) и перезапусти скрипт.")
			end
		end
		if haveCraftable("golden") then
			local ok, err = goToMachine("rainbow")
			if not ok then warn("[IndexFarm] Не удалось подойти к Rainbow Machine: " .. tostring(err)) end
			warn("[IndexFarm] >>> RAINBOW MACHINE: открой машину, выбери ЛЮБОГО golden пета (хватит одного), нажми OK и подтверди - скрипт запомнит Remote. <<<")
			if waitFor(function() return remoteOk(state.rainbowRemote) end, BOOTSTRAP_WAIT) then
				warn("[IndexFarm] Подготовка: Remote Rainbow Machine готов.")
			else
				warn("[IndexFarm] Remote Rainbow Machine не пойман (скрипт попросит снова, когда понадобится крафт).")
			end
		end
	end

	warn("[IndexFarm] Подготовка завершена.")
end

-- ===== пошаговая подготовка (GUIDED_SETUP) =====
-- Порядок: 1) ты открываешь обычное яйцо вручную (ловим Remote яиц)  2) скрипт сам открывает ещё одно - этого пета ты удалишь
-- 3) скрипт идёт к golden-версии яйца и выбивает golden пета для Rainbow  4) просит удалить пета (ловим Remote удаления)
-- 5) Golden Machine: крафтишь обычного пета  6) Rainbow Machine: крафтишь golden пета
local function notify(text, dur)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", { Title = "IndexFarm", Text = text, Duration = dur or 12 })
	end)
end

-- ru - строка для консоли, en - текст уведомления на экране
local function prompt(ru, en)
	warn("[IndexFarm] >>> " .. ru .. " <<<")
	notify(en or ru, 12)
end

local function header(n, total, text)
	warn(string.format("[IndexFarm] ===== Шаг %d/%d: %s =====", n, total, text))
end

local function petName(pet)
	local d = pet and Dir.Pets[tostring(pet.id)]
	return (pet and pet.g and "Golden " or "") .. (d and d.name or tostring(pet and pet.id))
end

local function petByUid(uid)
	local save = Library.Save.Get()
	if save then
		for _, p in ipairs(save.Pets) do
			if p.uid == uid then return p end
		end
	end
end

local function isNormal(pet) return kindOf(pet) == "normal" end
local function isGoldenPet(pet) return kindOf(pet) == "golden" end

-- первый пет, которого не было в снимке и который подходит под accept
local function newPetSince(snap, accept)
	local save = Library.Save.Get()
	if not save then return nil end
	for _, pet in ipairs(save.Pets) do
		if not snap[pet.uid] and accept(pet) then return pet end
	end
end

-- золотая версия этого же яйца (та же область), иначе самое дешёвое golden-яйцо
local function goldenCounterpart(e)
	local save = Library.Save.Get()
	if not save then return nil end
	local normalDrops = e and Dir.Eggs[e.egg] and resolveDrops(Dir.Eggs[e.egg])
	local best
	for eggName, egg in pairs(Dir.Eggs) do
		if egg.isGolden and e and egg.area == e.area then
			local area = Dir.Areas[egg.area]
			local drops = resolveDrops(egg)
			local cost = eggCost(egg)
			if area and not area.hidden and drops and eggUnlocked(eggName, save) and getCurrency(egg.currency) >= cost then
				local same = (egg.drops == e.egg) or (normalDrops ~= nil and drops == normalDrops)
				if not best or (same and not best.same) or (same == best.same and cost < best.cost) then
					best = { egg = eggName, area = egg.area, cost = cost, currency = egg.currency, same = same }
				end
			end
		end
	end
	return best or cheapestEgg(true)
end

-- открывать яйцо по 1, пока не выпадет пет, подходящий под accept (не удаляет и не трогает старых петов)
-- если напрямую открыть не вышло - просит открыть вручную
local function openForPet(e, accept, limit)
	local snap = snapshotPets()
	local opens, fails = 0, 0
	while state.running and opens < limit do
		local pet = newPetSince(snap, accept)
		if pet then return pet end
		if not modeFor(e.cost, e.currency) then
			warn("[IndexFarm] Не хватает валюты на яйцо «" .. e.egg .. "».")
			return nil
		end
		local before = openCount
		local res = buy(e.egg, 1)
		local success = res[1] and res[2] and true or false
		local t0 = os.clock()
		while not success and openCount == before and os.clock() - t0 < 2 do task.wait(0.05) end
		success = success or openCount > before
		if success then
			opens += 1
			fails = 0
			local w0 = os.clock()
			while state.running and os.clock() - w0 < 2.5 do
				pet = newPetSince(snap, accept)
				if pet then return pet end
				task.wait(0.15)
			end
		else
			fails += 1
			if fails >= 3 then
				prompt("Напрямую открыть не вышло: открой яйцо «" .. e.egg .. "» ВРУЧНУЮ ещё раз",
					"Auto-open failed. Please open egg [" .. e.egg .. "] manually once more")
				local w0 = os.clock()
				while state.running and os.clock() - w0 < BOOTSTRAP_WAIT do
					pet = newPetSince(snap, accept)
					if pet then return pet end
					task.wait(0.3)
				end
				return nil
			end
			task.wait(0.4)
		end
		task.wait(DELAY)
	end
	return newPetSince(snap, accept)
end

local function standAt(e)
	if state.lastEgg == e.egg then return true end
	local ok, err = goTo(e)
	if ok then
		state.lastEgg = e.egg
		return true
	end
	warn("[IndexFarm] Телепорт к яйцу «" .. e.egg .. "» не удался: " .. tostring(err))
	return false
end

local function bootstrapGuided()
	local needEgg = not remoteOk(state.eggRemote)
	local needDelete = DELETE_JUNK and not DRY_RUN and not remoteOk(state.deleteRemote)
	local needGold = (inList(VARIANTS, 2) or inList(VARIANTS, 3)) and not remoteOk(state.goldRemote)
	local needRainbow = inList(VARIANTS, 3) and not remoteOk(state.rainbowRemote)
	local needCoin = CURRENCY_FARM.ENABLED and not CF.ready()

	if not (needEgg or needDelete or needGold or needRainbow or needCoin) then
		warn("[IndexFarm] Подготовка: все Remote уже пойманы, настройка не нужна.")
		return
	end

	local e1 = (needEgg or needDelete or needGold) and cheapestEgg(false) or nil
	if not e1 and (needEgg or needDelete or needGold) then
		warn("[IndexFarm] Не нашёл доступного дешёвого яйца: шаги с яйцами будут пропущены, остальное - вручную.")
	end

	local total = 0
	for _, f in ipairs({ needCoin, needEgg and e1, needDelete and e1, needRainbow, needDelete, needGold, needRainbow }) do
		if f then total += 1 end
	end
	local n = 0
	local setup = {}
	warn(string.format("[IndexFarm] Пошаговая подготовка: %d шагов. Делай то, что просит скрипт.", total))

	-- Шаг: Remote-ы монет (кликаешь по монете сам, заодно тест фарма)
	if needCoin and state.running then
		n += 1
		header(n, total, "Remote-ы монет (тест фарма)")
		CF.learnCoins(e1 and e1.currency or nil)
	end

	-- Шаг: Remote яиц (открываешь яйцо сам)
	if needEgg and e1 and state.running then
		n += 1
		header(n, total, "Remote яиц (getchildren)")
		standAt(e1)
		local snap = snapshotPets()
		prompt("ОТКРОЙ ЯЙЦО «" .. e1.egg .. "» ВРУЧНУЮ 1 РАЗ - скрипт запомнит Remote",
			"Open egg [" .. e1.egg .. "] manually ONCE so I can catch the remote")
		if waitFor(function() return remoteOk(state.eggRemote) end, BOOTSTRAP_WAIT) then
			-- пет из этого яйца пригодится для Golden-крафта
			waitFor(function()
				setup.manualPet = setup.manualPet or newPetSince(snap, isNormal)
				return setup.manualPet
			end, 8)
			if setup.manualPet then
				warn("[IndexFarm] Из твоего яйца выпал: " .. petName(setup.manualPet) .. " (его скрафтишь в Golden)")
			end
		else
			warn("[IndexFarm] Remote яиц не пойман, продолжаю как есть.")
		end
	end

	-- Шаг: скрипт сам открывает яйцо - этого пета ты потом удалишь
	if needDelete and e1 and state.running then
		n += 1
		header(n, total, "Пет на удаление")
		if standAt(e1) then
			local manualUid = setup.manualPet and setup.manualPet.uid
			local pet = openForPet(e1, function(p) return isNormal(p) and p.uid ~= manualUid end, 25)
			if pet then
				setup.deletePet = pet
				warn("[IndexFarm] Выпал пет на удаление: " .. petName(pet))
			else
				warn("[IndexFarm] Не удалось выбить пета на удаление: удалишь любого ненужного сам.")
			end
		end
	end

	-- Шаг: golden-версия яйца -> golden пет для Rainbow-крафта
	if needRainbow and state.running then
		n += 1
		header(n, total, "Golden пет для Rainbow")
		local eg = goldenCounterpart(e1)
		if not eg then
			warn("[IndexFarm] Нет доступного golden-яйца (не хватает валюты/доступа): golden пета для Rainbow возьмёшь сам.")
		else
			setup.goldEgg = eg
			warn(string.format("[IndexFarm] Golden-яйцо: «%s»", eg.egg))
			if standAt(eg) then
				local pet = openForPet(eg, isGoldenPet, 80)
				if pet then
					setup.goldPet = pet
					warn("[IndexFarm] Выпал golden пет: " .. petName(pet))
				else
					warn("[IndexFarm] Golden пета выбить не вышло: возьми golden пета сам.")
				end
			end
		end
	end

	-- Шаг: Remote удаления
	if needDelete and state.running then
		n += 1
		header(n, total, "Remote удаления")
		local target = setup.deletePet and petByUid(setup.deletePet.uid)
		if target then
			prompt("УДАЛИ ПЕТА «" .. petName(target) .. "» (инвентарь -> корзина -> выбери его -> Delete -> подтверди)",
				"Delete this pet manually: [" .. petName(target) .. "] (Inventory > Trash > select > Delete > confirm)")
		else
			prompt("УДАЛИ ОДНОГО НЕНУЖНОГО ПЕТА (инвентарь -> корзина -> выбери -> Delete -> подтверди)",
				"Delete any unneeded pet manually (Inventory > Trash > select > Delete > confirm)")
		end
		if waitFor(function() return remoteOk(state.deleteRemote) end, BOOTSTRAP_WAIT) then
			warn("[IndexFarm] Remote удаления готов.")
		else
			warn("[IndexFarm] Remote удаления не пойман: авто-удаление заработает после ручного удаления, фарм идёт дальше.")
		end
	end

	-- Шаг: Golden Machine (обычный -> golden)
	if needGold and state.running then
		n += 1
		header(n, total, "Golden Machine")
		if not haveCraftable("normal") and e1 and standAt(e1) then
			openForPet(e1, isNormal, 20)
		end
		local ok, err = goToMachine("golden")
		if not ok then warn("[IndexFarm] Не удалось подойти к Golden Machine: " .. tostring(err)) end
		local mp = setup.manualPet and petByUid(setup.manualPet.uid)
		prompt("GOLDEN MACHINE: выбери обычного пета" .. (mp and (" «" .. petName(mp) .. "»") or "") ..
			" (хватит одного), нажми OK и подтверди",
			"Golden Machine: pick a normal pet" .. (mp and (" [" .. petName(mp) .. "]") or "") .. " (one is enough), press OK and confirm")
		if waitFor(function() return remoteOk(state.goldRemote) end, BOOTSTRAP_WAIT) then
			warn("[IndexFarm] Remote Golden Machine готов.")
		else
			warn("[IndexFarm] Remote Golden Machine не пойман (скрипт попросит снова, когда понадобится крафт).")
		end
	end

	-- Шаг: Rainbow Machine (golden -> rainbow)
	if needRainbow and state.running then
		n += 1
		header(n, total, "Rainbow Machine")
		if not haveCraftable("golden") and setup.goldEgg and standAt(setup.goldEgg) then
			setup.goldPet = openForPet(setup.goldEgg, isGoldenPet, 80) or setup.goldPet
		end
		if haveCraftable("golden") then
			local ok, err = goToMachine("rainbow")
			if not ok then warn("[IndexFarm] Не удалось подойти к Rainbow Machine: " .. tostring(err)) end
			local gp = setup.goldPet and petByUid(setup.goldPet.uid)
			prompt("RAINBOW MACHINE: выбери golden пета" .. (gp and (" «" .. petName(gp) .. "»") or "") ..
				" (хватит одного), нажми OK и подтверди",
				"Rainbow Machine: pick a golden pet" .. (gp and (" [" .. petName(gp) .. "]") or "") .. " (one is enough), press OK and confirm")
			if waitFor(function() return remoteOk(state.rainbowRemote) end, BOOTSTRAP_WAIT) then
				warn("[IndexFarm] Remote Rainbow Machine готов.")
			else
				warn("[IndexFarm] Remote Rainbow Machine не пойман (скрипт попросит снова, когда понадобится крафт).")
			end
		else
			warn("[IndexFarm] Нет golden пета для Rainbow-крафта: Remote поймается позже, когда понадобится.")
		end
	end

	warn("[IndexFarm] Подготовка завершена. Дальше фарм индекса.")
	notify("Setup complete, starting the index farm", 6)
end

-- ===== уведомления: пет добавился в индекс =====
local VARIANT_PREFIX = { [1] = "", [2] = "Golden ", [3] = "Rainbow ", [4] = "Dark Matter " }

local indexTotal = 0
for _ in pairs(collectableAll) do indexTotal += 1 end

local function indexKeyName(key)
	local id, v = tostring(key):match("^(.*)-(%d+)$")
	local d = id and Dir.Pets[id]
	return (VARIANT_PREFIX[tonumber(v)] or "") .. (d and d.name or tostring(id or key))
end

local function indexCount(save)
	local n = 0
	for _, k in ipairs(save.Collection) do
		if collectableAll[k] then n += 1 end
	end
	return n
end

-- раз в секунду сравниваем коллекцию: новые записи = пет засчитан в индекс (выбит, скрафчен, получен вручную - неважно)
local function startIndexWatcher()
	task.spawn(function()
		local known
		while state.active do
			local save = Library.Save.Get()
			if save and save.Collection then
				if not known then
					known = {}
					for _, k in ipairs(save.Collection) do known[k] = true end
				else
					local fresh = {}
					for _, k in ipairs(save.Collection) do
						if not known[k] then
							known[k] = true
							if collectableAll[k] then fresh[#fresh + 1] = k end
						end
					end
					if #fresh > 0 and state.running then
						local total = indexCount(save)
						local base = total - #fresh
						for i = 1, math.min(#fresh, 4) do
							local name = indexKeyName(fresh[i])
							warn(string.format("[IndexFarm] В индекс добавлен: %s | в индексе %d/%d", name, base + i, indexTotal))
							notify(string.format("%s added to the Index! Index: %d/%d pets", name, base + i, indexTotal), 6)
							task.wait(0.4)
						end
						if #fresh > 4 then
							notify(string.format("+%d more pets added to the Index! Index: %d/%d pets", #fresh - 4, total, indexTotal), 6)
						end
					end
				end
			end
			task.wait(1)
		end
	end)
end

-- ===== ФАРМ ВАЛЮТЫ (когда на яйцо не хватает) =====
-- Логика: яйцо нужно, а валюты не хватает -> смотрим, в каком мире эта валюта падает, берём ЛУЧШУЮ доступную область
-- (как в окне Teleport: сначала порядок мира, потом множитель области), телепортируемся и бьём монеты петами (Remote-ы ловятся хуком).
-- Копим, пока не хватит на нужное число открытий (см. CURRENCY_FARM), и возвращаемся к яйцам.
-- Валюта читается как в Currency.lua: save[имя], а в хардкоре для HardcoreSeparate-валют - save.HardcoreCurrency[имя].
CF = { rejected = setmetatable({}, { __mode = "k" }), maxHp = setmetatable({}, { __mode = "k" }), assign = {}, warned = {}, lastTp = 0 }

function CF.warnOnce(key, text)
	if not CF.warned[key] then CF.warned[key] = true warn(text) end
end

function CF.fmt(n)
	local ok, s = pcall(Library.Functions.NumberShorten, n, false)
	if ok and type(s) == "string" then return s end
	return tostring(math.floor(n))
end

function CF.reset() CF.assign, CF.focus = {}, nil end

function CF.ready()
	return remoteOk(state.coinRF) and remoteOk(state.coinRE)
end

-- ----- выбор области -----
function CF.areaOk(name, a)
	if not a or a.hidden or a.isShop then return false end
	if isCooling("farmarea:" .. name) then return false end
	local ok, res = pcall(function()
		if name == "VIP" and not Library.Gamepasses.Owns(Dir.Gamepasses.VIP.ID) then return false end
		return Library.RebornLock.AreaOpen(name)
			and Library.WorldCmds.HasAccess(a.world)
			and Library.WorldCmds.HasArea(name)
			and Library.WorldCmds.HasTeleport(name)
	end)
	return (ok and res) and true or false
end

function CF.areaScore(a)
	local w = Dir.Worlds[a.world]
	return { (w and w.worldOrder) or 0, a.mult or 0, (a.gate and a.gate.cost) or 0 }
end

function CF.better(x, y)
	for i = 1, 3 do
		if x[i] ~= y[i] then return x[i] > y[i] end
	end
	return false
end

-- миры, где падает валюта: сначала те, где она основная, потом те, где она дополнительная
function CF.worldsFor(currency)
	local main, extra = {}, {}
	for wname, w in pairs(Dir.Worlds) do
		if w.mainCurrency == currency then
			main[wname] = true
		elseif type(w.additionalCurrencies) == "table" and table.find(w.additionalCurrencies, currency) then
			extra[wname] = true
		end
	end
	return main, extra
end

-- области от лучшей к худшей для данной валюты
function CF.rankAreas(currency)
	local restrict
	if currency ~= nil and not CURRENCY_FARM.ANY_WORLD[currency] then
		local main, extra = CF.worldsFor(currency)
		if next(main) then
			restrict = main
		elseif next(extra) then
			restrict = extra
		else
			CF.warnOnce("anyworld:" .. tostring(currency), "[IndexFarm] ФАРМ: не знаю, в каком мире падает «" .. currency .. "». Беру лучшую область всей игры (добавь валюту в ANY_WORLD, если она падает везде).")
		end
	end
	local out = {}
	for name, a in pairs(Dir.Areas) do
		if (not restrict or restrict[a.world]) and CF.areaOk(name, a) then
			out[#out + 1] = { name = name, s = CF.areaScore(a) }
		end
	end
	table.sort(out, function(x, y)
		if CF.better(x.s, y.s) then return true end
		if CF.better(y.s, x.s) then return false end
		return x.name < y.name
	end)
	return out
end

-- ----- монеты и петы (логика из Farm.lua) -----
function CF.folders()
	local things = workspace:FindFirstChild("__THINGS")
	if not things then return nil, nil end
	return things:FindFirstChild("Coins"), things:FindFirstChild("Pets")
end

function CF.coinPos(coin)
	local p = coin:FindFirstChild("POS") or coin:FindFirstChild("Coin")
	if p and p:IsA("BasePart") then return p.Position end
	return nil
end

function CF.rootPos()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

function CF.coinId(coin)
	return tostring(coin:GetAttribute("ID") or coin.Name)
end

function CF.coinCount()
	local coinsF = CF.folders()
	if not coinsF then return 0 end
	local n = 0
	for _, c in ipairs(coinsF:GetChildren()) do
		if CF.coinPos(c) then n += 1 end
	end
	return n
end

-- монету можно бить: приземлилась, не падает, жива, не в закрытой области (у закрытых на части Coin стоит PreventClick)
function CF.eligible(coin, now)
	local rej = CF.rejected[coin]
	if rej then
		if now < rej then return false end
		CF.rejected[coin] = nil
	end
	if coin:GetAttribute("HasLanded") == false or coin:GetAttribute("IsFalling") == true then return false end
	local hp = coin:GetAttribute("Health")
	if type(hp) ~= "number" or hp <= 0 then return false end
	local part = coin:FindFirstChild("Coin")
	if part and part:GetAttribute("PreventClick") then return false end
	return CF.coinPos(coin) ~= nil
end

function CF.coins(coinsF, origin)
	local now, list = os.clock(), {}
	for _, coin in ipairs(coinsF:GetChildren()) do
		if CF.eligible(coin, now) then
			local d = (CF.coinPos(coin) - origin).Magnitude
			if d <= CURRENCY_FARM.NEAR_RADIUS then list[#list + 1] = { coin = coin, dist = d } end
		end
	end
	table.sort(list, function(x, y) return x.dist < y.dist end)
	local out = table.create(#list)
	for i, item in ipairs(list) do out[i] = item.coin end
	return out
end

function CF.petIds(petsF)
	local ids = {}
	if not petsF then return ids end
	for _, pet in ipairs(petsF:GetChildren()) do
		if pet:GetAttribute("Owner") == player.Name then
			local id = pet:GetAttribute("ID")
			if id then ids[#ids + 1] = tostring(id) end
		end
	end
	return ids
end

function CF.chunk(list, size)
	local groups = {}
	for i = 1, #list, size do
		local g = {}
		for j = i, math.min(i + size - 1, #list) do g[#g + 1] = list[j] end
		groups[#groups + 1] = g
	end
	return groups
end

function CF.assignGroup(coin, a)
	if not coin.Parent or #a.pets == 0 or not CF.ready() then return false end
	local RF = state.coinRF
	task.spawn(function()
		local ok, res = pcall(function() return RF:InvokeServer(a.id, a.pets) end)
		local accepted = 0
		if ok and type(res) == "table" then
			for _, v in pairs(res) do
				if v == true then accepted += 1 end
			end
		end
		if (not ok or accepted == 0) and CF.assign[coin] == a then
			CF.assign[coin] = nil
			CF.rejected[coin] = os.clock() + CURRENCY_FARM.REJECT_COOLDOWN -- сервер не принял: пока не трогаем
		end
	end)
	return true
end

function CF.hitAll()
	if not remoteOk(state.coinRE) then return end
	local RE, sent = state.coinRE, 0
	for coin, a in pairs(CF.assign) do
		if coin.Parent then
			for _, petId in ipairs(a.pets) do
				if sent >= CURRENCY_FARM.MAX_HITS then return end
				RE:FireServer(a.id, petId)
				sent += 1
			end
		end
	end
end

-- снять «зависшие» назначения, замерить урон петов, вернуть занятых петов
function CF.review(now)
	local cfg, busy = CURRENCY_FARM, {}
	for coin, a in pairs(CF.assign) do
		local release, penalty = false, nil
		if not coin.Parent or not CF.coinPos(coin) then
			release = true
		else
			local hp = coin:GetAttribute("Health")
			if hp ~= nil then
				if hp ~= a.lastHealth then
					CF.damageSeen = true
					if not a.started then a.tFirst, a.hpFirst = now, hp end
					a.lastHealth, a.lastProgress, a.started = hp, now, true
				end
				local limit = a.started and cfg.STUCK_TIMEOUT or cfg.TRAVEL_GRACE
				if now - a.lastProgress > limit then
					release, penalty = true, cfg.REJECT_COOLDOWN
				elseif a.focus and now - a.assignedAt > cfg.MAX_COIN_TIME then
					release, penalty = true, cfg.TOUGH_COOLDOWN -- слишком крепкая: не трогаем надолго
				end
				-- замер урона: падение здоровья за окно >= 3 сек, в пересчёте на одного пета
				if not release and a.started and a.hpFirst and now - a.tFirst >= 3 then
					local dmg = a.hpFirst - hp
					if dmg > 0 and #a.pets > 0 then
						local dpp = dmg / (now - a.tFirst) / #a.pets
						local first = CF.dpsPerPet == nil
						CF.dpsPerPet = first and dpp or (CF.dpsPerPet * 0.7 + dpp * 0.3)
						if first and cfg.BEST_COIN then
							warn(string.format("[IndexFarm] ФАРМ: урон ≈ %s HP/сек на пета. Дальше бью самые толстые монеты, которые ломаются за ≤ %d сек.",
								CF.fmt(dpp), cfg.MAX_BREAK_TIME))
						end
					end
					a.tFirst, a.hpFirst = now, hp
				end
			elseif now - a.assignedAt > cfg.MAX_ASSIGN_TIME then
				release, penalty = true, cfg.REJECT_COOLDOWN
			end
		end
		if release then
			CF.assign[coin] = nil
			if penalty then CF.rejected[coin] = now + penalty end
		else
			for _, id in ipairs(a.pets) do busy[id] = true end
		end
	end
	return busy
end

function CF.newAssign(coin, pets, now, focus)
	return {
		id = CF.coinId(coin), pets = pets, assignedAt = now, focus = focus,
		lastHealth = coin:GetAttribute("Health"), lastProgress = now, started = false,
	}
end

-- режим «разброс» (как в Farm.lua): по PETS_PER_COIN петов на ближайшие монеты. Нужен, пока не замерен урон петов
function CF.assignSpread(coinsF, origin, free, now)
	local cfg, targets = CURRENCY_FARM, {}
	for _, coin in ipairs(CF.coins(coinsF, origin)) do
		if not CF.assign[coin] then targets[#targets + 1] = coin end
	end
	for i, group in ipairs(CF.chunk(free, math.max(1, cfg.PETS_PER_COIN))) do
		local coin = targets[i]
		if not coin then break end
		local a = CF.newAssign(coin, group, now, false)
		CF.assign[coin] = a
		task.delay((i - 1) * cfg.SEND_DELAY, function()
			if CF.assign[coin] == a and not CF.assignGroup(coin, a) then CF.assign[coin] = nil end
		end)
	end
end

-- лучшая монета: самая «толстая» (по максимальному наблюдавшемуся Health), которую все петы сломают за MAX_BREAK_TIME сек.
-- Если таких нет - самая лёгкая. Берём монеты области фарма (атрибут Area), а если их нет - любые доступные.
function CF.pickBest(coinsF, origin, nPets)
	local cfg, now = CURRENCY_FARM, os.clock()
	local pool, inArea = {}, {}
	for _, coin in ipairs(coinsF:GetChildren()) do
		if CF.eligible(coin, now) then
			pool[#pool + 1] = coin
			if coin:GetAttribute("Area") == CF.area then inArea[#inArea + 1] = coin end
		end
	end
	if #inArea > 0 then pool = inArea end

	local rate = math.max(1e-9, (CF.dpsPerPet or 0) * math.max(1, nPets))
	local best, bestVal, bestDist, easiest, easiestHp
	for _, coin in ipairs(pool) do
		local hp = coin:GetAttribute("Health")
		local val = math.max(CF.maxHp[coin] or 0, hp)
		CF.maxHp[coin] = val
		local dist = (CF.coinPos(coin) - origin).Magnitude
		if hp / rate <= cfg.MAX_BREAK_TIME and (not best or val > bestVal or (val == bestVal and dist < bestDist)) then
			best, bestVal, bestDist = coin, val, dist
		end
		if not easiest or hp < easiestHp then easiest, easiestHp = coin, hp end
	end
	return best or easiest, rate
end

-- встать рядом с монетой (с учётом её размера), чтобы петы долетели, а сервер принял назначение
function CF.goNear(coin)
	local cfg = CURRENCY_FARM
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local pos = CF.coinPos(coin)
	if not (root and pos) then return false end
	local part = coin:FindFirstChild("Coin")
	local radius = (part and part:IsA("BasePart")) and math.max(part.Size.X, part.Size.Z) / 2 or 0
	local off = math.clamp(radius + cfg.TP_OFFSET, cfg.TP_OFFSET, 60)
	if (root.Position - pos).Magnitude <= off + cfg.TP_TOLERANCE then return true end
	local away = (root.Position - pos) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
	char:PivotTo(CFrame.new(pos + away * off + Vector3.new(0, 4, 0)))
	CF.lastTp = os.clock()
	return true
end

-- режим «лучшая монета»: все свободные петы на одну самую выгодную монету, игрок телепортируется к ней
function CF.assignBest(coinsF, origin, free, now)
	local cfg = CURRENCY_FARM
	if CF.focus and CF.assign[CF.focus] then return end -- уже бьём
	local coin, rate = CF.pickBest(coinsF, origin, #free)
	if not coin then return end
	if cfg.TP_TO_COIN then
		if now - CF.lastTp < cfg.TP_MIN_INTERVAL then return end
		CF.goNear(coin)
	end
	local a = CF.newAssign(coin, free, now, true)
	CF.assign[coin], CF.focus = a, coin
	local hp = coin:GetAttribute("Health")
	warn(string.format("[IndexFarm] ФАРМ: цель - «%s» (HP %s, ~%d сек)", tostring(coin:GetAttribute("Name") or coin.Name), CF.fmt(hp), math.ceil(hp / rate)))
	task.delay(cfg.TP_SETTLE, function()
		if CF.assign[coin] == a and not CF.assignGroup(coin, a) then
			CF.assign[coin] = nil
			CF.focus = nil
		end
	end)
end

function CF.distribute()
	local cfg = CURRENCY_FARM
	local coinsF, petsF = CF.folders()
	if not coinsF then return end
	local ids = CF.petIds(petsF)
	if #ids == 0 then
		CF.warnOnce("nopets", "[IndexFarm] ФАРМ: не найдено экипированных петов (Owner = " .. player.Name .. ")")
		return
	end
	local origin = CF.rootPos()
	if not origin then return end

	local now = os.clock()
	local busy = CF.review(now)
	local free = {}
	for _, id in ipairs(ids) do
		if not busy[id] then free[#free + 1] = id end
	end
	if #free == 0 then return end

	if cfg.BEST_COIN and CF.dpsPerPet then
		CF.assignBest(coinsF, origin, free, now)
	else
		CF.assignSpread(coinsF, origin, free, now)
	end
end

-- ----- подготовка Remote-ов -----
function CF.ensureRemotes()
	if CF.ready() then return true end
	prompt("ФАРМ: КЛИКНИ ВРУЧНУЮ ПО ЛЮБОЙ МОНЕТЕ 1 РАЗ и подожди, пока петы начнут бить - скрипт запомнит Remote-ы монет (жду до " .. CURRENCY_FARM.LEARN_WAIT .. " сек)",
		"Click any coin ONCE and wait until your pets start hitting it, so I can catch the coin remotes")
	local t0 = os.clock()
	while state.active and state.running and os.clock() - t0 < CURRENCY_FARM.LEARN_WAIT do
		if CF.ready() then
			warn("[IndexFarm] ФАРМ: Remote-ы монет пойманы, продолжаю.")
			return true
		end
		task.wait(0.5)
	end
	return CF.ready()
end

-- ----- центр области -----
-- Монеты создаются на клиенте для всего мира (атрибут Area = область), поэтому центр считаем по ним:
-- центр масс монет области, а встаём у монеты, ближайшей к этому центру (чтобы оказаться на настоящей земле).
function CF.areaCenter(area)
	local coinsF = CF.folders()
	if not coinsF then return nil end
	local inArea, all = {}, {}
	for _, coin in ipairs(coinsF:GetChildren()) do
		local pos = CF.coinPos(coin)
		local part = coin:FindFirstChild("Coin")
		if pos and not (part and part:GetAttribute("PreventClick")) then
			all[#all + 1] = { coin = coin, pos = pos }
			if coin:GetAttribute("Area") == area then inArea[#inArea + 1] = all[#all] end
		end
	end
	local pts = #inArea > 0 and inArea or all
	if #pts == 0 then return nil end
	local sum = Vector3.zero
	for _, p in ipairs(pts) do sum += p.pos end
	local center = sum / #pts
	local flat = Vector3.new(1, 0, 1)
	local best, bestD = pts[1], math.huge
	for _, p in ipairs(pts) do
		local d = ((p.pos - center) * flat).Magnitude
		if d < bestD then best, bestD = p, d end
	end
	return best.coin, center, #pts
end

function CF.toCenter(area)
	local coin, _, n = CF.areaCenter(area)
	if not coin then return false end
	CF.goNear(coin)
	warn(string.format("[IndexFarm] ФАРМ: встал в центр области «%s» (монет в расчёте: %d).", area, n))
	return true
end

-- монеты подгружаются клиентом постепенно (до ~10 сек после смены мира): ждём, пока их число перестанет расти
function CF.settleCoins(maxSec)
	local t0, last, stable = os.clock(), -1, 0
	while state.active and state.running and os.clock() - t0 < maxSec do
		local n = CF.coinCount()
		if n > 0 and n == last then
			stable += 0.5
			if stable >= 1.5 then break end
		else
			stable = 0
		end
		last = n
		task.wait(0.5)
	end
end

-- короткая проверка: петы реально бьют монеты (заодно замеряет урон для режима «лучшая монета»)
function CF.selfTest(sec)
	local cfg = CURRENCY_FARM
	warn("[IndexFarm] ТЕСТ МОНЕТ: проверяю, что петы бьют монеты (до " .. tostring(sec or 12) .. " сек)...")
	CF.reset()
	CF.damageSeen = false
	local t0, nextA, nextH = os.clock(), 0, 0
	while state.active and state.running and os.clock() - t0 < (sec or 12) do
		local now = os.clock()
		if now >= nextA then
			nextA = now + cfg.ASSIGN_INTERVAL
			pcall(CF.distribute)
		end
		if now >= nextH then
			nextH = now + cfg.HIT_INTERVAL
			pcall(CF.hitAll)
		end
		if CF.damageSeen and CF.dpsPerPet then break end
		task.wait(0.1)
	end
	CF.reset()
	if CF.damageSeen then
		warn("[IndexFarm] ТЕСТ МОНЕТ: ОК, петы бьют монеты" .. (CF.dpsPerPet and (" (урон ≈ " .. CF.fmt(CF.dpsPerPet) .. " HP/сек на пета)") or "") .. ".")
		notify("Coin farm test passed: your pets are hitting coins", 6)
		return true
	end
	warn("[IndexFarm] ТЕСТ МОНЕТ: урон по монетам не замечен. Кликни по монете вручную ещё раз (возможно, Remote устарел).")
	notify("Coin farm test failed: no damage seen. Click a coin again", 8)
	return false
end

-- подготовка: телепорт в лучшую область, встать в центр, попросить кликнуть по монете (ловим Remote-ы) и проверить фарм
function CF.learnCoins(currency)
	local cfg = CURRENCY_FARM
	if not cfg.ENABLED then return true end
	if not CF.ready() then
		local areas = CF.rankAreas(currency)
		local area = areas[1] and areas[1].name
		if area then
			local a = Dir.Areas[area]
			if not (state.lastArea == area and arrived(area)) then
				warn("[IndexFarm] Монеты: телепорт в «" .. area .. "» для теста.")
				local okT, errT = safeTeleport(area)
				if not (state.active and state.running) then return false end
				if not okT then warn("[IndexFarm] Монеты: телепорт не удался: " .. tostring(errT)) end
			end
			if arrived(area) then
				state.lastArea, state.lastWorld, state.lastEgg, state.atMachine = area, a.world, nil, nil
				local w0 = os.clock()
				while state.active and state.running and CF.coinCount() == 0 and os.clock() - w0 < cfg.COINS_WAIT do task.wait(0.5) end
				if cfg.CENTER_TP then
					CF.settleCoins(cfg.CENTER_SETTLE)
					CF.toCenter(area)
				end
			end
		else
			warn("[IndexFarm] Монеты: не нашёл подходящую область, кликни по монете там, где стоишь.")
		end
		if not CF.ensureRemotes() then
			warn("[IndexFarm] Remote-ы монет не пойманы: попрошу снова, когда понадобится фарм валюты.")
			return false
		end
	end
	return CF.selfTest(12)
end

-- ----- сам фарм -----
-- возвращает "ok" | "failed" | "skip" | "stopped"
function CF.run(t)
	local cfg, cur = CURRENCY_FARM, t.currency
	local opens = math.min(cfg.MAX_OPENS, math.max(cfg.MIN_OPENS, math.ceil(t.score * cfg.BUFFER) + 8))
	local target = t.cost * opens
	local started, have0 = os.clock(), getCurrency(cur)
	warn(string.format("[IndexFarm] === ФАРМ ВАЛЮТЫ «%s»: сейчас %s, цель %s (≈%d открытий «%s» ради «%s») ===",
		cur, CF.fmt(have0), CF.fmt(target), opens, t.egg, t.name))

	while state.active and state.running do
		local areas = CF.rankAreas(cur)
		if #areas == 0 then
			warn("[IndexFarm] ФАРМ: нет доступной области для «" .. cur .. "» (недоступны или временно отложены).")
			return "failed"
		end
		local area = areas[1].name
		local a = Dir.Areas[area]

		if not (state.lastArea == area and arrived(area)) then
			warn(string.format("[IndexFarm] ФАРМ: лучшая область для «%s» - «%s» (×%s). Телепортируюсь.", cur, area, tostring(a.mult)))
			local okT, errT = safeTeleport(area)
			if not (state.active and state.running) then return "stopped" end
			if not okT then
				warn("[IndexFarm] ФАРМ: телепорт в «" .. area .. "» не удался: " .. tostring(errT))
				coolDown("farmarea:" .. area, 120)
				continue
			end
		end
		state.lastArea, state.lastWorld, state.lastEgg, state.atMachine = area, a.world, nil, nil

		local w0 = os.clock()
		while state.active and state.running and CF.coinCount() == 0 and os.clock() - w0 < cfg.COINS_WAIT do task.wait(0.5) end
		if not (state.active and state.running) then return "stopped" end
		if CF.coinCount() == 0 then
			warn("[IndexFarm] ФАРМ: в «" .. area .. "» нет монет, пробую следующую область.")
			coolDown("farmarea:" .. area, cfg.AREA_BAD_COOLDOWN)
			continue
		end

		if cfg.CENTER_TP then
			CF.settleCoins(cfg.CENTER_SETTLE)
			if not (state.active and state.running) then return "stopped" end
			if not CF.toCenter(area) then
				warn("[IndexFarm] ФАРМ: центр области определить не вышло, остаюсь у точки телепорта.")
			end
		end

		if not CF.ensureRemotes() then
			if state.running then stop("Remote-ы монет не пойманы") end
			return "stopped"
		end

		CF.reset()
		CF.area = area
		local best, lastGrow = getCurrency(cur), os.clock()
		local areaStart = os.clock()
		local nextAssign, nextHit, nextLog = 0, 0, os.clock() + cfg.LOG_INTERVAL
		warn(string.format("[IndexFarm] ФАРМ: бью монеты в «%s»...", area))

		while state.active and state.running do
			if isMoving() then stop("движение") CF.reset() return "stopped" end
			if state.skipRequested then
				state.skipRequested = false
				CF.reset()
				warn("[IndexFarm] ФАРМ прерван (" .. SKIP_KEY.Name .. "): откладываю эту цель.")
				return "skip"
			end

			local now = os.clock()
			local have = getCurrency(cur)
			if have > best then best, lastGrow = have, now end
			local elapsed = now - started

			if have >= target or (elapsed >= cfg.MAX_TIME and have >= t.cost) then
				CF.reset()
				warn(string.format("[IndexFarm] === ФАРМ готов: «%s» %s -> %s за %d сек. Возвращаюсь к яйцам. ===",
					cur, CF.fmt(have0), CF.fmt(have), math.floor(elapsed)))
				state.lastEgg = nil
				return "ok"
			end
			if elapsed >= cfg.GIVE_UP_TIME then
				CF.reset()
				warn("[IndexFarm] ФАРМ: за " .. cfg.GIVE_UP_TIME .. " сек не набралось даже на 1 яйцо. Откладываю цель.")
				return "failed"
			end
			if now - lastGrow > cfg.STAGNATION then
				warn(string.format("[IndexFarm] ФАРМ: «%s» не растёт %d сек в «%s». Пробую другую область (если петы не бьют - кликни по монете вручную, чтобы обновить Remote).",
					cur, cfg.STAGNATION, area))
				coolDown("farmarea:" .. area, cfg.AREA_BAD_COOLDOWN)
				break
			end
			if state.lastArea ~= area or not arrived(area) then
				warn("[IndexFarm] ФАРМ: область сменилась (респавн?), возвращаюсь.")
				break
			end

			if now >= nextAssign then
				nextAssign = now + cfg.ASSIGN_INTERVAL
				local ok, err = pcall(CF.distribute)
				if not ok then warn("[IndexFarm] ФАРМ: ошибка назначения: " .. tostring(err)) end
			end
			if now >= nextHit then
				nextHit = now + cfg.HIT_INTERVAL
				local ok, err = pcall(CF.hitAll)
				if not ok then warn("[IndexFarm] ФАРМ: ошибка ударов: " .. tostring(err)) end
			end
			if now >= nextLog then
				nextLog = now + cfg.LOG_INTERVAL
				local gained = have - have0
				local perMin = gained / math.max(1, now - areaStart) * 60
				local eta = perMin > 0 and string.format("~%d мин", math.ceil((target - have) / perMin)) or "?"
				warn(string.format("[IndexFarm] ФАРМ «%s»: %s / %s | +%s/мин | осталось %s", cur, CF.fmt(have), CF.fmt(target), CF.fmt(perMin), eta))
			end
			task.wait(0.1)
		end
		CF.reset()
	end
	return "stopped"
end

function CF.runFor(t)
	local r = CF.run(t)
	if r == "failed" then
		coolDown(t.key, CURRENCY_FARM.AREA_BAD_COOLDOWN) -- недостижимую цель не крутим по кругу
	elseif r == "skip" then
		coolDown(t.key, 600)
	end
	return r
end

-- самая «дешёвая» недоступная цель: минимум валюты, которую надо потратить (цена яйца * ожидаемое число открытий)
function CF.pickBroke(variant)
	local all = (variant == 0) and buildAllCandidates(true) or buildCandidates(variant, true)
	local best, bestTotal, farmable = nil, nil, {}
	for _, c in ipairs(all) do
		if c.broke then
			local total = c.cost * c.score
			if not best or total < bestTotal then
				if farmable[c.currency] == nil then farmable[c.currency] = #CF.rankAreas(c.currency) > 0 end
				if farmable[c.currency] then best, bestTotal = c, total end
			end
		end
	end
	return best
end

-- ===== главный цикл =====
local VARIANT_NAME = { "обычные", "golden", "rainbow" }

local function main()
	state.running = true
	warn("[IndexFarm] Старт. Остановка: _G.AutoIndexFarm = false или " .. STOP_KEY.Name .. (STOP_ON_MOVE and " или движение" or ""))
	if CURRENCY_FARM.ENABLED and not BOOTSTRAP and not CF.ready() then
		prompt("Для фарма валюты нужны Remote-ы монет: заранее кликни ВРУЧНУЮ по любой монете - скрипт их поймает; иначе попрошу, когда понадобятся",
			"Click any coin ONCE so I can catch the coin remotes for currency farming")
	end
	if DELETE_JUNK then
		warn(DRY_RUN
			and "[IndexFarm] Авто-удаление: ТЕСТОВЫЙ режим (DRY_RUN), ничего не удаляется, только лог."
			or "[IndexFarm] Авто-удаление: ВКЛЮЧЕНО (удаляются только петы, выбитые этим скриптом).")
		if not DRY_RUN and not remoteOk(state.deleteRemote) then
			warn("[IndexFarm] Remote удаления ещё не пойман: можешь сразу удалить вручную одного ненужного пета, чтобы скрипт его запомнил.")
		end
	end

	if BOOTSTRAP then
		local okB, errB = pcall(GUIDED_SETUP and bootstrapGuided or bootstrap)
		if not okB then warn("[IndexFarm] Подготовка: ошибка: " .. tostring(errB)) end
		if not (state.active and state.running) then return end
		state.lastEgg = nil
	end

	local finished = false
	local passes = MIXED_VARIANTS and { 0 } or VARIANTS
	for _, variant in ipairs(passes) do
		if finished or not (state.active and state.running) then break end
		warn("[IndexFarm] === Вариант: " .. (variant == 0 and "все сразу" or VARIANT_NAME[variant] or tostring(variant)) .. " ===")

		while state.active and state.running do
			used = {}
			local list = (variant == 0) and buildAllCandidates() or buildCandidates(variant)
			applyTravel(list)
			if #list == 0 then
				local bt = CURRENCY_FARM.ENABLED and CF.pickBroke(variant)
				if bt then
					warn(string.format("[IndexFarm] Не хватает «%s» на яйцо «%s» (цель %s). Иду фармить валюту.", bt.currency, bt.egg, bt.name))
					local r = CF.runFor(bt)
					if r == "stopped" then
						finished = true
						break
					end
					task.wait(1)
					continue
				end
				warn("[IndexFarm] Для этого варианта целей нет (всё получено или не хватает доступа/валюты).")
				break
			end

			warn("[IndexFarm] Топ целей:")
			for i = 1, math.min(5, #list) do
				local c = list[i]
				warn(string.format("  %d. %s [%s] | %s%s | шанс %.4f%% | нужно открыть ~%d | цена %s",
					i, c.name, VARIANT_NAME[c.variant] or "?", c.egg, c.direct and " (golden-яйцо)" or "",
					c.chance * 100, math.ceil(c.score), tostring(c.cost)))
			end

			local t = list[1]
			if state.pinned then
				local found
				for _, c in ipairs(list) do
					if c.key == state.pinned then found = c break end
				end
				if found then t = found else state.pinned = nil end
			end
			warn(string.format("[IndexFarm] Цель: %s (%s) из «%s»%s", t.name, VARIANT_NAME[t.variant], t.egg,
				state.pinned and " [выбрана вручную: случайная]" or ""))

			local proceed = true
			if t.need > 0 then
				if state.lastEgg ~= t.egg then
					local ok, err = goTo(t)
					if not ok then
						warn("[IndexFarm] Телепорт не удался: " .. tostring(err))
						coolDown("egg:" .. t.egg, 60)
						proceed = false
					else
						state.lastEgg = t.egg
					end
				end
				t.here = proceed
			end

			if proceed then
				local result = farm(t)
				if result ~= "stopped" then harvest() flushDeletes(true) end
				if result == "owned" then
					warn("[IndexFarm] Получен: " .. t.name .. " (" .. VARIANT_NAME[t.variant] .. ")")
					if state.pinned == t.key then state.pinned = nil end
					if not CONTINUE_AFTER then finished = true break end
				elseif result == "failed" then
					if state.pinned == t.key then state.pinned = nil end
					coolDown(t.key)
				elseif result == "skipped" then
					local others = {}
					for _, c in ipairs(list) do
						if c.key ~= t.key then others[#others + 1] = c end
					end
					if #others == 0 then
						warn("[IndexFarm] Других доступных целей нет, продолжаю текущую.")
					else
						local pick = others[math.random(#others)]
						state.pinned = pick.key
						warn(string.format("[IndexFarm] Пропускаю «%s». Случайная новая цель: %s из «%s»",
							t.name, pick.name, pick.egg))
					end
				elseif result == "broke" then
					-- валюта кончилась прямо во время фарма яиц: докапливаем и возвращаемся к этой же цели
					local r = CF.runFor(t)
					if r == "stopped" then
						finished = true
						break
					end
				elseif result == "stopped" then
					finished = true
					break
				end
			end
			task.wait(1)
		end
	end

	-- если фарм дошёл до конца сам (никто не останавливал) - снимаем переменную
	local natural = state.running
	state.running = false
	if natural then _G.AutoIndexFarm = false end
	warn("[IndexFarm] Готово.")
end

-- ===== хук: запоминает Remote яиц, машин и удаления (они меняются при каждом входе) =====
-- Сам хук ставится один раз за сессию и просто вызывает env[HANDLER_KEY].
-- Обработчик перезаписывается при каждом запуске скрипта, поэтому обновлённая логика работает без перезахода.
env[HANDLER_KEY] = function(self, method, ...)
	local s = env[KEY]
	if not (s and s.active) then return end
	local first, second = ...

	if typeof(first) == "string" and Dir.Eggs[first] then
		local isNew = s.eggRemote ~= self
		s.eggRemote, s.eggMethod = self, method
		if isNew then
			local remote = self
			task.defer(function()
				warn(string.format("[IndexFarm] Remote яиц пойман: индекс %s | %s",
					tostring(table.find(RS:GetChildren(), remote)), remote:GetFullName()))
			end)
		end
		return
	end

	-- Remote-ы фарма монет: RF:InvokeServer("<id монеты>", { "id...", ... }) и RE:FireServer("<id монеты>", "id...")
	if typeof(self) == "Instance" and type(first) == "string" and tonumber(first) then
		if method == "InvokeServer" and type(second) == "table" and type(second[1]) == "string"
			and string.sub(second[1], 1, 2) == "id" then
			if s.coinRF ~= self then
				s.coinRF = self
				local remote = self
				task.defer(function() warn("[IndexFarm] Remote монет (RF) пойман: " .. remote:GetFullName()) end)
			end
			return
		elseif method == "FireServer" and select("#", ...) == 2 and type(second) == "string"
			and string.sub(second, 1, 2) == "id" then
			if s.coinRE ~= self then
				s.coinRE = self
				local remote = self
				task.defer(function() warn("[IndexFarm] Remote монет (RE) пойман: " .. remote:GetFullName()) end)
			end
			return
		end
	end

	if method ~= "InvokeServer" or type(first) ~= "table" or #first == 0 or type(first[1]) ~= "string" then
		return
	end

	-- машины Golden / Rainbow
	if Library.Variables.UsingMachine then
		local remote, uids = self, first
		task.defer(function()
			local uid = uids[1]
			local pet = uid and Library.PetCmds.Get(uid)
			if not pet or pet.r or pet.dm then return end
			local which = pet.g and "rainbowRemote" or "goldRemote"
			s[which] = remote
			local idx = table.find(RS:GetChildren(), remote)
			warn(string.format("[IndexFarm] Remote %s пойман: индекс %s | %s",
				pet.g and "Rainbow" or "Golden", tostring(idx), remote:GetFullName()))
		end)
		return
	end

	-- возможное удаление петов (массив uid).
	-- 1) в инвентаре должен быть включён режим удаления (кнопка Delete/Cancel видна),
	-- 2) пет должен реально существовать до вызова,
	-- 3) все эти петы должны реально пропасть из инвентаря. Иначе Remote не запоминаем.
	local okV, vis = pcall(function() return Library.GUI.Inventory.Bottom.VerifyDelete.Visible end)
	if okV and vis ~= true then return end

	local remote, list = self, table.clone(first)
	if not Library.PetCmds.Get(list[1]) then return end
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 6 do
			task.wait(0.25)
			local save = Library.Save.Get()
			if save then
				local present = {}
				for _, pet in ipairs(save.Pets) do present[pet.uid] = true end
				local allGone = true
				for _, u in ipairs(list) do
					if present[u] then allGone = false break end
				end
				if allGone then
					s.deleteRemote = remote
					s.deleteDirectFailed = false
					local idx = table.find(RS:GetChildren(), remote)
					warn(string.format("[IndexFarm] Remote удаления пойман: индекс %s | %s",
						tostring(idx), remote:GetFullName()))
					return
				end
			end
		end
	end)
end

if not env[HOOK_KEY] then
	env[HOOK_KEY] = true
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()
		if (method == "InvokeServer" or method == "FireServer") and not checkcaller() then
			local h = env[HANDLER_KEY]
			if h then pcall(h, self, method, ...) end
		end
		return old(self, ...)
	end))
end

table.insert(state.connections, UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == STOP_KEY then
		stop("клавиша " .. STOP_KEY.Name)
	elseif input.KeyCode == SKIP_KEY and state.running then
		state.skipRequested = true
		warn("[IndexFarm] Запрошен переход на другую цель (" .. SKIP_KEY.Name .. ")...")
	end
end))

-- ===== управление переменной _G.AutoIndexFarm =====
-- Следит за переменной: true -> запускает основной цикл, false -> останавливает его.
-- Основной цикл можно включать и выключать сколько угодно раз.
local function resetRunState()
	state.lastEgg, state.lastArea, state.lastWorld, state.atMachine = nil, nil, nil, nil
	state.skipRequested, state.pinned = false, nil
	snapUids, snapTries = nil, 0
	pcall(CF.reset)
end

startIndexWatcher() -- один раз за запуск скрипта (раньше стартовал внутри main)

state.mainActive = false
state.thread = task.spawn(function()
	while state.active do
		local on = _G.AutoIndexFarm and true or false

		if on and not state.mainActive then
			state.mainActive = true
			resetRunState()
			state.mainThread = task.spawn(function()
				local ok, err = pcall(main)
				if not ok then
					warn("[IndexFarm] Ошибка: " .. tostring(err))
					state.running = false
					_G.AutoIndexFarm = false
				end
				state.mainActive = false
			end)
		elseif not on and state.running then
			state.running = false
			warn("[IndexFarm] Выключено переменной, останавливаюсь...")
		end

		task.wait(0.2)
	end
end)

warn("[IndexFarm] Готов. Включить: _G.AutoIndexFarm = true, выключить: _G.AutoIndexFarm = false")
