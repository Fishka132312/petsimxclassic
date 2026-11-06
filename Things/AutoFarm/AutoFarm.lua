--------------------------------------------------------------------------------13
-- КОНФИГ
-- Логика фарма как в new: все монеты от ближних к дальним, 1 пет на монету,
-- удары только по принятым сервером монетам, мгновенное переназначение.
-- Управление как в старом: AutoFarm.Start(локации) / AutoFarm.Stop() /
-- AutoFarm.Enabled / AutoFarm.Location
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	LocationAttr = "Area",
	IdAttr       = "ID",
	OwnerAttr    = "Owner",

	SearchRadius   = 99999, -- радиус поиска монет (без ограничения)
	PetsPerCoin    = 1,     -- 1 пет на монету = максимум монет одновременно
	LoopInterval   = 0.2,   -- страховочный цикл назначения (основное - по событию)
	HitInterval    = 0.2,   -- как часто слать удары
	SendDelay      = 0.02,  -- сдвиг между назначениями
	TravelGrace    = 20,    -- сек на дорогу: пока Health не менялся, монету не бросаем
	StuckTimeout   = 6,     -- сек без изменения Health после начала боя -> освобождаем
	MaxAssignTime  = 20,    -- сек на монету без атрибута Health
	RejectCooldown = 5,     -- сек, пока отклонённая монета пропускается
	MaxHitsPerTick = 100,   -- максимум FireServer за один тик

	Stats         = false,  -- печатать статистику в консоль
	StatsInterval = 10,

	Debug = false,
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

-- перезапуск скрипта: гасим прошлую версию целиком
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

local function dbg(...)
	if CONFIG.Debug then print("[Pets]", ...) end
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
-- 0. ПЕРЕХВАТ РЕМОУТОВ ИЗ НАСТОЯЩЕГО ВЫЗОВА ИГРЫ
--   _G.PetRF: RemoteFunction, InvokeServer("монета", {id петов}, ...)
--   _G.PetRE: RemoteEvent,    FireServer("монета", "id пета")
--------------------------------------------------------------------------------
local function valid(inst)
	return typeof(inst) == "Instance" and inst.Parent ~= nil
end

local function needRF() return not valid(_G.PetRF) end
local function needRE() return not valid(_G.PetRE) end

if not _G.PetsHooked then
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
						task.defer(print, "[Pets] RemoteFunction запомнен, петов в вызове=" .. #b
							.. ", доп. аргументов=" .. tostring(_G.PetRFExtra.n))
					elseif method == "FireServer" and needRE()
						and n == 2 and type(b) == "string"
						and string.sub(b, 1, 2) == "id"
					then
						_G.PetRE = self
						task.defer(print, "[Pets] RemoteEvent запомнен")
					end
					if not needRF() and not needRE() then
						task.defer(notify, "Ремоуты сохранены, фарм готов")
					end
				end
			end
			return old(self, ...)
		end))
	else
		warn("[Pets] Экзекутор не поддерживает hookmetamethod/newcclosure/checkcaller")
	end
end

local function remotesReady()
	if not needRF() and not needRE() then
		warned.learn = nil
		return true
	end
	if not warned.learn then
		warned.learn = true
		warn("[Pets] Кликни вручную по монете и подожди, пока петы начнут бить")
		notify("Кликни по монете один раз и подожди пару секунд")
	end
	return false
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
--------------------------------------------------------------------------------
-- Connections - слежение за папкой монет (живёт, пока жив скрипт, не зависит от Stop)
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

function CoinManager.Reject(coin)
	CoinManager.Rejected[coin] = os.clock() + CONFIG.RejectCooldown
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

-- монеты выбранных локаций (nil = все), ближайшие первыми
function CoinManager.GetCoins(locations, origin, radius)
	local filter = makeFilter(locations)
	local now = os.clock()
	local list = {}
	for coin in pairs(CoinManager.AllCoins) do
		if coin.Parent
			and coin:GetAttribute("IsFalling") ~= true
			and not CoinManager.IsRejected(coin, now)
			and (not filter or filter[coinLocation(coin)])
		then
			local pos = getPos(coin)
			if pos then
				local dist = origin and (pos - origin).Magnitude or 0
				if dist <= (radius or CONFIG.SearchRadius) then
					list[#list + 1] = { coin = coin, dist = dist }
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)

	local coins = table.create(#list)
	for i, item in ipairs(list) do coins[i] = item.coin end
	return coins
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
			if id then ids[#ids + 1] = tostring(id) end
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

-- [coin] = { id, pets, assignedAt, lastHealth, lastProgress, started, accepted }
local assignments = {}
local stats = { accepted = 0, rejected = 0, maxDist = 0 }

-- Назначаем группу петов на монету (RemoteFunction)
local function assignGroup(coin, a)
	if not coin.Parent or #a.pets == 0 then return false end
	if not remotesReady() then return false end

	local RF = _G.PetRF
	task.spawn(function()
		local ok, res = pcall(function()
			local extra = _G.PetRFExtra
			if extra and extra.n > 0 then
				return RF:InvokeServer(a.id, a.pets, table.unpack(extra, 1, extra.n))
			end
			return RF:InvokeServer(a.id, a.pets)
		end)
		local accepted = 0
		if ok and type(res) == "table" then
			for _, v in pairs(res) do
				if v == true then accepted += 1 end
			end
		end

		if CONFIG.Debug then
			local pos, origin = getPos(coin), getRootPos()
			local dist = (pos and origin) and math.floor((pos - origin).Magnitude) or -1
			print(string.format("[Pets] монета %s, дист=%d, петов %d -> ok=%s принято=%d",
				a.id, dist, #a.pets, tostring(ok), accepted))
		end

		if accepted > 0 then
			a.accepted = true -- бить будем только принятые сервером монеты
			stats.accepted += 1
			local pos, origin = getPos(coin), getRootPos()
			if pos and origin then
				local d = (pos - origin).Magnitude
				if d > stats.maxDist then stats.maxDist = d end
			end
		end
		if (not ok or accepted == 0) and assignments[coin] == a then
			assignments[coin] = nil
			stats.rejected += 1
			CoinManager.Reject(coin)
		end
	end)
	return true
end

-- Удары: FireServer(coinId, petId) по принятым монетам
local function hitAll()
	if needRE() then return end
	local RE = _G.PetRE
	local sent = 0
	for coin, a in pairs(assignments) do
		if coin.Parent and a.accepted then
			for _, petId in ipairs(a.pets) do
				if sent >= CONFIG.MaxHitsPerTick then return end
				RE:FireServer(a.id, petId)
				sent += 1
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

	local origin = getRootPos()
	if not origin then return end

	local filter = makeFilter(locations)
	local now = os.clock()
	local busy = {}

	for coin, a in pairs(assignments) do
		local release, penalize = false, false
		if not coin.Parent then
			release = true
		elseif filter and not filter[coinLocation(coin)] then
			release = true -- локацию сменили/убрали из списка
		elseif not getPos(coin) then
			release = true
		else
			local hp = coin:GetAttribute("Health")
			if hp ~= nil then
				if hp ~= a.lastHealth then
					a.lastHealth = hp
					a.lastProgress = now
					a.started = true
				end
				local limit = a.started and CONFIG.StuckTimeout or CONFIG.TravelGrace
				if now - a.lastProgress > limit then
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
		end
	end

	local free = {}
	for _, id in ipairs(ids) do
		if not busy[id] then free[#free + 1] = id end
	end
	if #free == 0 then return end

	local targets = {}
	for _, coin in ipairs(CoinManager.GetCoins(locations, origin, CONFIG.SearchRadius)) do
		if not assignments[coin] then targets[#targets + 1] = coin end
	end

	dbg(string.format("петов %d (свободно %d), доступно монет %d", #ids, #free, #targets))
	if #targets == 0 then return end

	for i, group in ipairs(chunk(free, math.max(1, CONFIG.PetsPerCoin))) do
		local coin = targets[i]
		if not coin then break end

		local a = {
			id = coinId(coin),
			pets = group,
			assignedAt = now,
			lastHealth = coin:GetAttribute("Health"),
			lastProgress = now,
			started = false,
		}
		assignments[coin] = a

		task.delay((i - 1) * CONFIG.SendDelay, function()
			if assignments[coin] == a and not assignGroup(coin, a) then
				assignments[coin] = nil
			end
		end)
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
			if not ok then warn("[Pets] Ошибка (" .. label .. "): " .. tostring(err)) end
			task.wait(interval)
		end
	end)
end

-- locations: nil (все) | "Имя" | { "Имя1", "Имя2" }
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

	-- монета сломана -> сразу освобождаем пета и назначаем новую, не ждём цикл
	local pending = false
	table.insert(farmConnections, CoinsFolder.ChildRemoved:Connect(function(c)
		if assignments[c] then assignments[c] = nil end
		if pending then return end
		pending = true
		task.defer(function()
			pending = false
			if AutoFarm.Enabled and runId == id then
				local ok, err = pcall(PetController.Distribute, AutoFarm.Location)
				if not ok then warn("[Pets] Ошибка (быстрое назначение): " .. tostring(err)) end
			end
		end)
	end))

	if CONFIG.Stats then
		loop(id, CONFIG.StatsInterval, function()
			local n = 0
			for _ in pairs(assignments) do n += 1 end
			print(string.format("[Pets] принято=%d, отклонено=%d, макс.дист=%d, монет в работе=%d",
				stats.accepted, stats.rejected, math.floor(stats.maxDist), n))
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

-- сменить локации на лету, не останавливая фарм
function AutoFarm.SetLocation(locations)
	AutoFarm.Location = locations
end

_G.PetTools = {
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
	-- полная выгрузка (отключает слежение за монетами)
	Destroy = function()
		AutoFarm.Stop()
		for _, c in ipairs(CoinManager.Connections) do c:Disconnect() end
		table.clear(CoinManager.Connections)
	end,
}

print("[Pets] Готово. Один раз кликни по монете вручную, дождись 'RemoteFunction запомнен' и 'RemoteEvent запомнен'")
