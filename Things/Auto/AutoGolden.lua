-- LocalScript: авто-крафт Golden Machine (5 одинаковых петов -> golden)
-- 1) Сделай ОДИН крафт вручную (ОК + подтверждение): скрипт запомнит Remote.
-- 2) Включай/выключай крафт переменной:
--      _G.AutoGoldenCraft = true   -- крафтит, пока есть подходящие петы
--      _G.AutoGoldenCraft = false  -- не крафтит
-- Переменная выключена изначально. Повторный запуск скрипта отключает прошлую копию.

local env = (getgenv and getgenv()) or _G
local KEY, HOOK_KEY = "__AutoGolden", "__AutoGoldenHook"

-- ===== НАСТРОЙКИ =====
local PETS_PER_CRAFT = 6     -- минимум 5; больше = выше шанс, но дороже
local DELAY          = 0.5   -- пауза между крафтами (сек)
local SKIP_RARITIES  = {}    -- например { "Secret", "Mythical" } — этих не трогать
-- ======================

-- Выключаем прошлую копию: она перестаёт работать (цикл и подписки убираются),
-- но уже пойманный Remote запоминаем.
local prev = env[KEY]
local knownRemote = prev and prev.remote
local prevWasCrafting = prev and prev.running
if prev then
	prev.active, prev.running = false, false
	if prev.thread then pcall(task.cancel, prev.thread) end
	for _, c in ipairs(prev.connections) do pcall(function() c:Disconnect() end) end
end

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Library = require(RS:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do RunService.Heartbeat:Wait() end

-- если прошлую копию оборвали посреди крафта — снимаем флаг машины
if prevWasCrafting then Library.Variables.UsingMachine = false end

-- переменная выключена изначально
_G.AutoGoldenCraft = false

local state = { active = true, running = false, remote = knownRemote, thread = nil, connections = {} }
env[KEY] = state

local function inList(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

local function eligible(pet)
	local dir = Library.Directory.Pets[pet.id]
	if not dir then return false end
	local r = dir.rarity
	if dir.isPremium or dir.isGift then return false end
	if pet.g or pet.r or pet.dm or pet.l then return false end
	if r == "Event" or r == "Exclusive" then return false end
	if inList(SKIP_RARITIES, r) then return false end
	if Library.Shared.IsHardcore and not pet.hc then return false end
	return true
end

local function inBooth(uid)
	local ok, res = pcall(Library.Signal.Invoke, "Is Trading Booth Pet", uid)
	return ok and res
end

local function keepsAPet(chosen)
	local save = Library.Save.Get()
	if not save then return false end
	for _, p in ipairs(save.Pets) do
		if not (table.find(chosen, p.uid) or (not p.hc and Library.Shared.IsHardcore)) then
			return true
		end
	end
	return false
end

local used, badGroups = {}, {}

local function findGroup(n)
	local save = Library.Save.Get()
	if not save then return nil end

	local groups, order = {}, {}
	for _, pet in ipairs(save.Pets) do
		if not used[pet.uid] and eligible(pet) then
			local key = pet.id .. "|" .. (pet.hc and "hc" or "") .. "|" .. (pet.sh and "sh" or "")
			if not badGroups[key] then
				if not groups[key] then
					groups[key] = { hc = pet.hc or false, uids = {}, name = Library.Directory.Pets[pet.id].name }
					order[#order + 1] = key
				end
				table.insert(groups[key].uids, pet.uid)
			end
		end
	end

	table.sort(order)
	for _, key in ipairs(order) do
		local g = groups[key]
		if #g.uids >= n then
			local chosen = {}
			for i = 1, n do chosen[i] = g.uids[i] end
			if keepsAPet(chosen) then return key, g, chosen end
		end
	end
	return nil
end

-- Один шаг крафта (вызывается циклом, пока переменная включена)
local crafts, fails = 0, 0

local function craftStep()
	local n = math.max(5, PETS_PER_CRAFT)
	local key, group, chosen = findGroup(n)
	if not key then
		-- групп нет: ждём новых петов и пробуем снова с чистого листа
		used, badGroups = {}, {}
		task.wait(2)
		return
	end

	-- пропускаем петов из trading booth
	local blocked = false
	for _, uid in ipairs(chosen) do
		if inBooth(uid) then used[uid] = true; blocked = true end
	end
	if blocked then
		task.wait(0.1)
		return
	end

	local rows = Library.RebornBalance.MachineRows(Library.Shared.GoldMachineOdds, group.hc)
	if #rows < n then
		n = #rows
		for i = #chosen, n + 1, -1 do chosen[i] = nil end
	end
	for _, uid in ipairs(chosen) do used[uid] = true end

	Library.Variables.UsingMachine = true
	local res = table.pack(pcall(function()
		return state.remote:InvokeServer(chosen)
	end))
	task.wait(0.5)
	Library.Variables.UsingMachine = false

	if res[1] and res[2] then
		crafts += 1
		fails = 0
	else
		fails += 1
		badGroups[key] = true
		if fails >= 3 then
			fails = 0
			task.wait(10)
			used, badGroups = {}, {}
		end
	end

	task.wait(DELAY)
end

-- Главный цикл: работает всегда, но крафтит только при _G.AutoGoldenCraft = true
state.thread = task.spawn(function()
	local wasOn = false

	while state.active do
		local on = _G.AutoGoldenCraft and true or false

		if on and not wasOn then
			used, badGroups = {}, {}
			crafts, fails = 0, 0
		end
		wasOn = on

		if not on then
			state.running = false
			task.wait(0.1)
		elseif not state.remote then
			state.running = false
			task.wait(0.25)
		else
			state.running = true
			local ok = pcall(craftStep)
			if not ok then
				Library.Variables.UsingMachine = false
				task.wait(1)
			end
		end
	end
end)

-- хук ставится один раз за сессию; ловит только вызов, который игра делает внутри Convert()
-- (читает актуальный state из env, поэтому повторный запуск его не дублирует)
if not env[HOOK_KEY] then
	env[HOOK_KEY] = true
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if getnamecallmethod() == "InvokeServer" then
			local s = env[KEY]
			if s and s.active and not s.remote and not checkcaller() then
				local vars = Library.Variables
				if vars and vars.UsingMachine and type((...)) == "table" then
					s.remote = self
				end
			end
		end
		return old(self, ...)
	end))
end
