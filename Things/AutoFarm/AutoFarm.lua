--------------------------------------------------------------------------------11
-- AUTOFARM v2
-- Что изменилось относительно старой версии (по скриптам игры Coins/Pets/Select Pets):
--  1. Ремоуты берутся через игровой Library.Network ("Join Coin" / "Farm Coin"),
--     так же как это делает сама игра -> больше не нужно кликать по монете вручную,
--     доп. аргументы/токены подставляет сама игра. Старый перехват оставлен как запасной.
--  2. Пропускаются монеты, которые сервер всё равно отклонит:
--     - закрытые зоны (у части "Coin" стоит атрибут PreventClick),
--     - ещё падающие монеты (нужен HasLanded),
--     - монеты с Health <= 0 (умирают).
--  3. Радиус поиска авто-подстраивается под CoinGrabDistance игры, и раз в
--     ProbeInterval секунд проверяется, не принимает ли сервер монеты дальше.
--  4. Пет подбирается ближайший к монете (как GetClosestPet в игре), а не по порядку.
--  5. Если свободных монет меньше, чем петов - лишние петы присоединяются к самым
--     "толстым" монетам (раньше стояли без дела).
--  6. Удары: пока урон не пошёл - шлём часто; когда Health начал падать - перестаём
--     спамить (игра сама шлёт "Farm Coin" один раз при прибытии). Если урон
--     встал - возобновляем; если так случилось 3 раза, скрипт сам переключается на
--     постоянные удары (как в старой версии).
--  7. Бьём только тех петов, которых сервер реально принял (по ответу Join Coin).
--  8. Монеты с Health <= 0 освобождаются сразу, TravelGrace сокращён.
--
-- Управление: AutoFarm.Start(локации) / AutoFarm.Stop() / AutoFarm.SetLocation(...)
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	LocationAttr = "Area",
	IdAttr       = "ID",
	OwnerAttr    = "Owner",

	SearchRadius   = "auto", -- "auto" | число | math.huge (без ограничения)
	ProbeInterval  = 15,     -- раз в N сек пробуем монету дальше текущего радиуса
	ProbeFactor    = 1.5,    -- во сколько раз дальше пробуем
	RequireLanded  = true,   -- брать только приземлившиеся монеты

	PetsPerCoin    = 1,      -- стартовое число петов на монету
	MaxPetsPerCoin = 100,    -- потолок при добавлении лишних петов
	JoinExtraPets  = true,   -- лишних петов отправлять на уже занятые монеты

	LoopInterval   = 0.2,    -- страховочный цикл назначения (основное - по событию)
	HitInterval    = 0.2,    -- как часто слать удары, когда они нужны
	StallResume    = 2.5,    -- сек без падения Health -> снова слать удары
	SendDelay      = 0.02,   -- сдвиг между назначениями
	TravelGrace    = 10,     -- сек на дорогу: пока Health не менялся, монету не бросаем
	StuckTimeout   = 6,      -- сек без изменения Health после начала боя -> освобождаем
	MaxAssignTime  = 15,     -- сек на монету без атрибута Health
	RejectCooldown = 5,      -- сек, пока отклонённая монета пропускается
	RejectMsgCooldown = 20,  -- то же, если сервер вернул текстовую причину
	MaxHitsPerTick = 100,    -- максимум FireServer за один тик

	Stats         = false,
	StatsInterval = 10,
	Debug         = false,
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

if _G.PetTools then
	if _G.PetTools.AutoFarm then _G.PetTools.AutoFarm.Stop() end
	if _G.PetTools.Destroy then _G.PetTools.Destroy() end
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
	return nil
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

local function coinId(coin)
	return tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name)
end

local function coinLocation(coin)
	return tostring(coin:GetAttribute(CONFIG.LocationAttr) or "Unknown")
end

-- locations: nil (все) | "Имя" | { "Имя1", "Имя2" } | { Имя1 = true, ... }
local function makeFilter(locations)
	if type(locations) == "string" then
		return { [locations] = true }
	elseif type(locations) == "table" then
		local filter = {}
		for k, v in pairs(locations) do
			if type(k) == "number" then
				filter[tostring(v)] = true
			elseif v then
				filter[tostring(k)] = true
			end
		end
		return filter
	end
	return nil
end

--------------------------------------------------------------------------------
-- 0. СВЯЗЬ С СЕРВЕРОМ
--   Основной путь: игровой Library.Network (как в Pets/Coins скриптах игры).
--   Запасной путь: перехват настоящего вызова через hookmetamethod (клик по монете).
--------------------------------------------------------------------------------
local Library
do
	local ok, lib = pcall(function()
		local fw = ReplicatedStorage:WaitForChild("Framework", 5)
		local mod = fw and fw:WaitForChild("Library", 5)
		return mod and require(mod)
	end)
	if ok and type(lib) == "table" then
		local t0 = os.clock()
		while not lib.Loaded and os.clock() - t0 < 15 do task.wait(0.1) end
		if lib.Loaded and type(lib.Network) == "table"
			and lib.Network.Invoke and lib.Network.Fire then
			Library = lib
		end
	end
end

local Net = { useLibrary = Library ~= nil, libFails = 0, libOk = 0 }

local function valid(inst)
	return typeof(inst) == "Instance" and inst.Parent ~= nil
end
local function needRF() return not valid(_G.PetRF) end
local function needRE() return not valid(_G.PetRE) end

local function installHook()
	if _G.PetsHooked then return end
	if hookmetamethod and getnamecallmethod and newcclosure and checkcaller then
		_G.PetsHooked = true
		local old
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if (method == "InvokeServer" or method == "FireServer")
				and (needRF() or needRE())
				and not checkcaller()
			then
				local a, b = ...
				local n = select("#", ...)
				if typeof(self) == "Instance" and type(a) == "string" and tonumber(a) then
					if method == "InvokeServer" and needRF()
						and type(b) == "table" and type(b[1]) == "string"
						and string.sub(b[1], 1, 2) == "id"
					then
						_G.PetRF = self
						_G.PetRFExtra = table.pack(select(3, ...))
					elseif method == "FireServer" and needRE()
						and n == 2 and type(b) == "string"
						and string.sub(b, 1, 2) == "id"
					then
						_G.PetRE = self
					end
					if not needRF() and not needRE() then
						task.defer(notify, "Farm Ready")
					end
				end
			end
			return old(self, ...)
		end))
	else
	end
end

if not Net.useLibrary then installHook() end

local function switchToHook(reason)
	if not Net.useLibrary then return end
	Net.useLibrary = false
	installHook()
end

local function remotesReady()
	if Net.useLibrary then return true end
	if not needRF() and not needRE() then
		warned.learn = nil
		return true
	end
	if not warned.learn then
		warned.learn = true
		notify("Send ur pets on breakable")
	end
	return false
end

-- Join Coin: возвращает ok, результат ({ [uid] = true | "текст причины" })
local function netJoin(id, pets)
	if Net.useLibrary then
		local ok, res = pcall(Library.Network.Invoke, "Join Coin", id, pets)
		if ok and type(res) == "table" then
			Net.libOk += 1
		else
			Net.libFails += 1
			if Net.libOk == 0 and Net.libFails >= 5 then switchToHook(ok and "пустой ответ" or res) end
		end
		return ok, res
	end
	if needRF() then return false end
	return pcall(function()
		local extra = _G.PetRFExtra
		if extra and extra.n > 0 then
			return _G.PetRF:InvokeServer(id, pets, table.unpack(extra, 1, extra.n))
		end
		return _G.PetRF:InvokeServer(id, pets)
	end)
end

-- Farm Coin: удар пета по монете
local function netHit(id, petId)
	if Net.useLibrary then
		Library.Network.Fire("Farm Coin", id, petId)
	elseif not needRE() then
		_G.PetRE:FireServer(id, petId)
	end
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
--------------------------------------------------------------------------------
local CoinManager = { AllCoins = {}, Rejected = {}, Connections = {} }

for _, c in ipairs(CoinsFolder:GetChildren()) do
	CoinManager.AllCoins[c] = true
end
table.insert(CoinManager.Connections, CoinsFolder.ChildAdded:Connect(function(c)
	CoinManager.AllCoins[c] = true
end))
table.insert(CoinManager.Connections, CoinsFolder.ChildRemoved:Connect(function(c)
	CoinManager.AllCoins[c] = nil
	CoinManager.Rejected[c] = nil
end))

function CoinManager.Reject(coin, seconds)
	CoinManager.Rejected[coin] = os.clock() + (seconds or CONFIG.RejectCooldown)
end

function CoinManager.IsRejected(coin, now)
	local untilT = CoinManager.Rejected[coin]
	if not untilT then return false end
	if now >= untilT then
		CoinManager.Rejected[coin] = nil
		return false
	end
	return true
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

-- пригодна ли монета для фарма (то, что сервер точно примет)
local function coinUsable(coin)
	if not coin.Parent then return false end
	if coin:GetAttribute("IsFalling") == true then return false end
	if CONFIG.RequireLanded and coin:GetAttribute("HasLanded") ~= true then return false end
	local hp = coin:GetAttribute("Health")
	if hp ~= nil and hp <= 0 then return false end
	local model = coin:FindFirstChild("Coin")
	if not model then return false end -- модель ещё не создана игрой
	if model:GetAttribute("PreventClick") then return false end -- закрытая зона
	return true
end

-- монеты выбранных локаций (nil = все), ближайшие первыми
function CoinManager.GetCoins(locations, origin, radius, skip)
	local filter = makeFilter(locations)
	local now = os.clock()
	local list = {}
	for coin in pairs(CoinManager.AllCoins) do
		if not (skip and skip[coin])
			and not CoinManager.IsRejected(coin, now)
			and (not filter or filter[coinLocation(coin)])
			and coinUsable(coin)
		then
			local pos = getPos(coin)
			if pos then
				local dist = origin and (pos - origin).Magnitude or 0
				if dist <= radius then
					list[#list + 1] = { coin = coin, dist = dist, pos = pos }
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	return list
end

--------------------------------------------------------------------------------
-- 2. ПЕТЫ
--------------------------------------------------------------------------------
local function isMine(pet)
	local owner = pet:GetAttribute(CONFIG.OwnerAttr)
	return owner ~= nil
		and (owner == LocalPlayer.Name or tostring(owner) == tostring(LocalPlayer.UserId))
end

-- список { id, pos } моих петов
local function GetEquippedPets()
	local pets = {}
	if not PetsFolder then return pets end
	for _, pet in ipairs(PetsFolder:GetChildren()) do
		if isMine(pet) then
			local id = pet:GetAttribute(CONFIG.IdAttr) or pet.Name
			if id then
				local ok, cf = pcall(pet.GetPivot, pet)
				pets[#pets + 1] = { id = tostring(id), pos = ok and cf.Position or nil }
			end
		end
	end
	return pets
end

-- [coin] = { id, pets (принятые), pending (отправленные, ждём ответ), accepted,
--            assignedAt, lastHealth, lastProgress, started, quiet }
local assignments = {}
local stats = { accepted = 0, rejected = 0, maxDist = 0 }
local Learn = { stalls = 0, needRepeat = false } -- самообучение режима ударов
local Radius = { current = nil, lastProbe = 0 }

local function baseRadius()
	if CONFIG.SearchRadius ~= "auto" then return CONFIG.SearchRadius end
	if not Radius.current then
		local d = Library and Library.Settings and Library.Settings.CoinGrabDistance
		Radius.current = (type(d) == "number" and d > 0) and d or math.huge
		dbg("стартовый радиус:", Radius.current)
	end
	return Radius.current
end

-- отправка набора петов на монету (isExtra - добавка к уже принятой монете)
local function sendPets(coin, a, pets, isExtra)
	if #pets == 0 then return end
	if not remotesReady() then
		if not isExtra and assignments[coin] == a then assignments[coin] = nil end
		return
	end
	for _, id in ipairs(pets) do a.pending[id] = true end

	task.spawn(function()
		local ok, res = netJoin(a.id, pets)
		for _, id in ipairs(pets) do a.pending[id] = nil end

		local acc, reason = {}, nil
		if ok and type(res) == "table" then
			for _, id in ipairs(pets) do
				local v = res[id]
				if v == true then
					acc[#acc + 1] = id
				elseif type(v) == "string" then
					reason = v
				end
			end
			if #acc == 0 then -- неизвестный формат ключей: считаем любые true
				local n = 0
				for _, v in pairs(res) do
					if v == true then n += 1 elseif type(v) == "string" then reason = v end
				end
				if n > 0 then acc = table.clone(pets) end
			end
		end

		if CONFIG.Debug then
				a.id, #pets, #acc, reason and ("(" .. reason .. ")") or ""))
		end

		if #acc > 0 then
			local now = os.clock()
			for _, id in ipairs(acc) do a.pets[#a.pets + 1] = id end
			if not a.accepted then
				a.accepted = true
				a.lastProgress = now
				a.lastHealth = coin:GetAttribute("Health")
			end
			stats.accepted += 1
			local pos, origin = getPos(coin), getRootPos()
			if pos and origin then
				local d = (pos - origin).Magnitude
				if d > stats.maxDist then stats.maxDist = d end
				-- сервер принял монету дальше радиуса -> расширяем
				if CONFIG.SearchRadius == "auto" and Radius.current and d > Radius.current then
					Radius.current = d
					dbg("радиус расширен до", math.floor(d))
				end
			end
		else
			stats.rejected += 1
			if isExtra then
				a.noExtraUntil = os.clock() + 10
			elseif assignments[coin] == a and #a.pets == 0 and next(a.pending) == nil then
				assignments[coin] = nil
				CoinManager.Reject(coin, reason and CONFIG.RejectMsgCooldown or CONFIG.RejectCooldown)
			end
		end
	end)
end

-- Удары по принятым монетам
local function hitAll()
	local now = os.clock()
	local sent = 0
	for coin, a in pairs(assignments) do
		if a.accepted and coin.Parent then
			local fire = false
			if not a.started or Learn.needRepeat then
				fire = true
			elseif now - a.lastProgress > CONFIG.StallResume then
				fire = true
				if not a.quiet then
					a.quiet = true
					Learn.stalls += 1
					if Learn.stalls >= 3 and not Learn.needRepeat then
						Learn.needRepeat = true
						dbg("урон идёт только при повторных ударах -> постоянный режим")
					end
				end
			end
			if fire then
				for _, petId in ipairs(a.pets) do
					if sent >= CONFIG.MaxHitsPerTick then return end
					netHit(a.id, petId)
					sent += 1
				end
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

local function trackProgress(coin, a, now)
	local hp = coin:GetAttribute("Health")
	if hp ~= nil and hp ~= a.lastHealth then
		if a.accepted then a.started = true end
		a.lastHealth = hp
		a.lastProgress = now
		a.quiet = false
	end
	return hp
end

function PetController.Distribute(locations)
	local pets = GetEquippedPets()
	if #pets == 0 then
		return
	end

	local origin = getRootPos()
	if not origin then return end

	local filter = makeFilter(locations)
	local now = os.clock()
	local busy = {}

	-- 1) проверяем текущие назначения
	for coin, a in pairs(assignments) do
		local release, penalize = false, false
		if not coin.Parent or not getPos(coin) then
			release = true
		elseif filter and not filter[coinLocation(coin)] then
			release = true
		else
			local hp = trackProgress(coin, a, now)
			if hp ~= nil and hp <= 0 then
				release = true
			elseif a.accepted then
				if hp ~= nil then
					local limit = a.started and CONFIG.StuckTimeout or CONFIG.TravelGrace
					if now - a.lastProgress > limit then
						release, penalize = true, true
					end
				elseif now - a.assignedAt > CONFIG.MaxAssignTime then
					release, penalize = true, true
				end
			elseif now - a.assignedAt > CONFIG.MaxAssignTime then
				release, penalize = true, true
			end
		end

		if release then
			assignments[coin] = nil
			if penalize then CoinManager.Reject(coin) end
		else
			for _, id in ipairs(a.pets) do busy[id] = true end
			for id in pairs(a.pending) do busy[id] = true end
		end
	end

	local free = {}
	for _, p in ipairs(pets) do
		if not busy[p.id] then free[#free + 1] = p end
	end
	if #free == 0 then return end

	-- 2) радиус (+ редкая проба монеты подальше)
	local radius = baseRadius()
	local probeRadius = nil
	if CONFIG.SearchRadius == "auto" and radius ~= math.huge
		and now - Radius.lastProbe >= CONFIG.ProbeInterval then
		probeRadius = radius * CONFIG.ProbeFactor
	end

	local list = CoinManager.GetCoins(locations, origin, probeRadius or radius, assignments)
	local targets, probed = {}, false
	for _, item in ipairs(list) do
		if item.dist <= radius then
			targets[#targets + 1] = item
		elseif not probed then
			probed = true
			Radius.lastProbe = now
			targets[#targets + 1] = item
		end
	end
	if probeRadius and not probed then Radius.lastProbe = now end

	dbg(string.format("петов %d (свободно %d), доступно монет %d, радиус %s",
		#pets, #free, #targets, tostring(math.floor(radius))))

	-- 3) пет <-> монета: для каждой монеты (от ближних) берём ближайшего свободного пета
	local idx = 0
	local perCoin = math.max(1, CONFIG.PetsPerCoin)
	for _, item in ipairs(targets) do
		if #free == 0 then break end
		local group = {}
		for _ = 1, perCoin do
			if #free == 0 then break end
			local bestI, bestD = 1, math.huge
			for i, p in ipairs(free) do
				local d = p.pos and (p.pos - item.pos).Magnitude or math.huge
				if d < bestD then bestD, bestI = d, i end
			end
			group[#group + 1] = free[bestI].id
			table.remove(free, bestI)
		end

		local coin = item.coin
		local a = {
			id = coinId(coin),
			pets = {}, pending = {},
			accepted = false,
			assignedAt = now,
			lastHealth = coin:GetAttribute("Health"),
			lastProgress = now,
			started = false,
			quiet = false,
		}
		assignments[coin] = a
		idx += 1
		task.delay((idx - 1) * CONFIG.SendDelay, function()
			if assignments[coin] == a then sendPets(coin, a, group, false) end
		end)
	end

	-- 4) лишние петы -> на самые "толстые" принятые монеты
	if CONFIG.JoinExtraPets and #free > 0 then
		local cands = {}
		for coin, a in pairs(assignments) do
			if a.accepted and coin.Parent and (a.noExtraUntil or 0) < now then
				local hp = coin:GetAttribute("Health")
				if hp and hp > 0 then
					local load = #a.pets
					for _ in pairs(a.pending) do load += 1 end
					cands[#cands + 1] = { coin = coin, a = a, hp = hp, load = load }
				end
			end
		end

		if #cands > 0 then
			local batches = {} -- [cand] = { ids }
			for _, p in ipairs(free) do
				local best, bestScore = nil, -1
				for _, c in ipairs(cands) do
					if c.load < CONFIG.MaxPetsPerCoin then
						local score = c.hp / (c.load + 1) -- оценка времени убийства
						if score > bestScore then bestScore, best = score, c end
					end
				end
				if not best then break end
				best.load += 1
				batches[best] = batches[best] or {}
				table.insert(batches[best], p.id)
			end
			for c, ids in pairs(batches) do
				idx += 1
				task.delay((idx - 1) * CONFIG.SendDelay, function()
					if assignments[c.coin] == c.a then sendPets(c.coin, c.a, ids, true) end
				end)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil }
local farmConnections = {}
local runId = 0

local function loop(id, interval, fn, label)
	task.spawn(function()
		while AutoFarm.Enabled and runId == id do
			local ok, err = pcall(fn)
			if not ok then end
			task.wait(interval)
		end
	end)
end

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locations
	runId += 1
	local id = runId
	PetController.Reset()
	warned.learn = nil

	loop(id, CONFIG.LoopInterval, function()
		PetController.Distribute(AutoFarm.Location)
	end, "назначение")
	loop(id, CONFIG.HitInterval, hitAll, "удары")

	-- монета сломана/появилась -> сразу переназначаем, не ждём цикл
	local pending = false
	local function quick()
		if pending then return end
		pending = true
		task.defer(function()
			pending = false
			if AutoFarm.Enabled and runId == id then
				local ok, err = pcall(PetController.Distribute, AutoFarm.Location)
				if not ok then end
			end
		end)
	end
	table.insert(farmConnections, CoinsFolder.ChildRemoved:Connect(function(c)
		if assignments[c] then assignments[c] = nil end
		quick()
	end))
	-- игра шлёт "Remove Coin" раньше, чем папка удаляется (есть анимация исчезновения)
	if Library then
		pcall(function()
			table.insert(farmConnections, Library.Network.Fired("Remove Coin"):Connect(function(cid)
				for coin, a in pairs(assignments) do
					if a.id == tostring(cid) then assignments[coin] = nil end
				end
				quick()
			end))
		end)
	end

	if CONFIG.Stats then
		loop(id, CONFIG.StatsInterval, function()
			local n = 0
			for _ in pairs(assignments) do n += 1 end
				stats.accepted, stats.rejected, math.floor(stats.maxDist),
				tostring(Radius.current and math.floor(Radius.current) or "-"), n,
				Learn.needRepeat and "постоянный" or "авто"))
		end, "статистика")
	end
end

function AutoFarm.Stop()
	AutoFarm.Enabled = false
	runId += 1
	PetController.Reset()
	for _, c in ipairs(farmConnections) do c:Disconnect() end
	table.clear(farmConnections)
end

function AutoFarm.SetLocation(locations)
	AutoFarm.Location = locations
end

_G.PetTools = {
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
	Destroy = function()
		AutoFarm.Stop()
		for _, c in ipairs(CoinManager.Connections) do c:Disconnect() end
		table.clear(CoinManager.Connections)
	end,
}
