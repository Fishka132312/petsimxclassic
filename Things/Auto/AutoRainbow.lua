-- LocalScript: авто-крафт Rainbow Machine (6 одинаковых golden петов -> rainbow)
-- 1) Сделай ОДИН крафт вручную (ОК + подтверждение): скрипт запомнит Remote.
-- 2) Включай/выключай крафт переменной:
--      _G.AutoRainbowCraft = true   -- крафтит, пока есть подходящие golden петы
--      _G.AutoRainbowCraft = false  -- не крафтит
-- Переменная выключена изначально. Повторный запуск скрипта отключает прошлую копию.

local env = (getgenv and getgenv()) or _G
local KEY, HOOK_KEY = "__AutoRainbow", "__AutoRainbowHook"

-- ===== НАСТРОЙКИ =====
local PETS_PER_CRAFT = 6     -- сколько golden петов в одном крафте
local DELAY          = 0.1   -- пауза между крафтами (сек)
local RANDOM_GROUP   = true  -- true = случайная группа, false = по алфавиту
local SKIP_RARITIES  = {}    -- например { "Secret", "Mythical" } — этих не трогать
local STOP_KEY       = Enum.KeyCode.X   -- выключить
local TOGGLE_KEY     = Enum.KeyCode.Z   -- включить/выключить переменную
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
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Library = require(RS:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do RunService.Heartbeat:Wait() end

-- если прошлую копию оборвали посреди крафта — снимаем флаг машины
if prevWasCrafting then Library.Variables.UsingMachine = false end

-- переменная выключена изначально
_G.AutoRainbowCraft = false

local state = { active = true, running = false, remote = knownRemote, pending = false, thread = nil, connections = {} }
env[KEY] = state

local function inList(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

-- для Rainbow нужны ТОЛЬКО golden петы (не rainbow / не dark matter)
local function eligible(pet)
	local dir = Library.Directory.Pets[pet.id]
	if not dir then return false end
	local r = dir.rarity
	if dir.isPremium or dir.isGift then return false end
	if not pet.g or pet.r or pet.dm or pet.l then return false end
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

	-- оставляем только группы, где хватает петов
	local ready = {}
	for _, key in ipairs(order) do
		if #groups[key].uids >= n then ready[#ready + 1] = key end
	end
	if #ready == 0 then return nil end

	if RANDOM_GROUP then
		for i = #ready, 2, -1 do
			local j = math.random(i)
			ready[i], ready[j] = ready[j], ready[i]
		end
	else
		table.sort(ready)
	end

	for _, key in ipairs(ready) do
		local g = groups[key]
		local chosen = {}
		for i = 1, n do chosen[i] = g.uids[i] end
		if keepsAPet(chosen) then return key, g, chosen end
	end
	return nil
end

-- Один шаг крафта (вызывается циклом, пока переменная включена)
local crafts, fails = 0, 0

local function craftStep()
	local n = PETS_PER_CRAFT
	local key, group, chosen = findGroup(n)
	if not key then
		-- групп нет: ждём новых golden петов и пробуем снова с чистого листа
		used, badGroups = {}, {}
		task.wait(2)
		return
	end

	local blocked = false
	for _, uid in ipairs(chosen) do
		if inBooth(uid) then used[uid] = true; blocked = true end
	end
	if blocked then
		task.wait(0.05)
		return
	end

	local rows = Library.RebornBalance.MachineRows(Library.Shared.RainbowMachineOdds, group.hc)
	if #rows < n then
		n = #rows
		for i = #chosen, n + 1, -1 do chosen[i] = nil end
	end
	local row = rows[math.min(n, #rows)]
	for _, uid in ipairs(chosen) do used[uid] = true end

	warn(string.format("[AutoRainbow] %s x%d | шанс %s%% | цена %s",
		group.name, n, tostring(row.chance), tostring(row.cost)))

	Library.Variables.UsingMachine = true
	local res = table.pack(pcall(function()
		return state.remote:InvokeServer(chosen)
	end))
	Library.Variables.UsingMachine = false

	if res[1] and res[2] then
		crafts += 1
		fails = 0
		warn("[AutoRainbow] Крафт принят сервером (всего: " .. crafts .. ")")
	else
		fails += 1
		badGroups[key] = true
		warn("[AutoRainbow] Отказ. Ответ:", tostring(res[1]), tostring(res[2]), tostring(res[3]))
		if fails >= 3 then
			warn("[AutoRainbow] 3 отказа подряд — пауза 10 сек (проверь валюту).")
			fails = 0
			task.wait(10)
			used, badGroups = {}, {}
		end
	end

	task.wait(DELAY)
end

-- Главный цикл: работает всегда, но крафтит только при _G.AutoRainbowCraft = true
state.thread = task.spawn(function()
	local wasOn = false
	local warnedNoRemote = false

	while state.active do
		local on = _G.AutoRainbowCraft and true or false

		if on and not wasOn then
			used, badGroups = {}, {}
			crafts, fails = 0, 0
			warn("[AutoRainbow] Включено. Выключить: _G.AutoRainbowCraft = false или " .. STOP_KEY.Name)
		elseif wasOn and not on then
			warn("[AutoRainbow] Выключено. Крафтов за запуск: " .. crafts)
		end
		wasOn = on

		if not on then
			state.running = false
			warnedNoRemote = false
			task.wait(0.1)
		elseif not state.remote then
			state.running = false
			if not warnedNoRemote then
				warnedNoRemote = true
				warn("[AutoRainbow] Remote ещё не пойман: сделай ОДИН крафт вручную (ОК + подтверждение)")
			end
			task.wait(0.25)
		else
			state.running = true
			local ok, err = pcall(craftStep)
			if not ok then
				Library.Variables.UsingMachine = false
				warn("[AutoRainbow] Ошибка шага: " .. tostring(err))
				task.wait(1)
			end
		end
	end
end)

function state.onCaptured()
	local idx = table.find(RS:GetChildren(), state.remote)
	warn("[AutoRainbow] Remote пойман: индекс " .. tostring(idx) .. " | " .. state.remote:GetFullName())
	warn("[AutoRainbow] Чтобы крафтить: _G.AutoRainbowCraft = true")
end

-- хук ставится один раз за сессию (читает актуальный state из env, повторный запуск его не дублирует).
-- Ловит InvokeServer(таблица uid) внутри Convert(); проверка «пет golden» делается уже после хука
if not env[HOOK_KEY] then
	env[HOOK_KEY] = true
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if getnamecallmethod() == "InvokeServer" then
			local s = env[KEY]
			if s and s.active and not s.remote and not s.pending and not checkcaller() then
				local uids = ...
				if Library.Variables.UsingMachine and type(uids) == "table" then
					s.pending = true
					local remote = self
					task.defer(function()
						local pet = uids[1] and Library.PetCmds.Get(uids[1])
						-- Rainbow-крафт принимает golden петов; у Golden-крафта петы ещё не golden
						if pet and pet.g and not pet.r and not pet.dm then
							s.remote = remote
							s.onCaptured()
						end
						s.pending = false
					end)
				end
			end
		end
		return old(self, ...)
	end))
end

table.insert(state.connections, UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == STOP_KEY then
		_G.AutoRainbowCraft = false
	elseif input.KeyCode == TOGGLE_KEY then
		_G.AutoRainbowCraft = not _G.AutoRainbowCraft
	end
end))

if state.remote then
	warn("[AutoRainbow] Remote уже известен. Включи: _G.AutoRainbowCraft = true (или клавиша " .. TOGGLE_KEY.Name .. ")")
else
	warn("[AutoRainbow] Готов. Сделай ОДИН крафт вручную (ОК + подтверждение), затем _G.AutoRainbowCraft = true")
end
