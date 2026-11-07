--------------------------------------------------------------------------------вв
-- AUTOFARM v2 + выбор типов монет (AutoFarm.SetCoinTypes)в
-- Changes compared to the old version (based on the game's Coins/Pets/Select Pets scripts):
--  1. Remotes are called through the game's own Library.Network ("Join Coin" / "Farm Coin"),
--     the same way the game does it -> no need to click a coin manually anymore,
--     extra arguments/tokens are filled in by the game itself. The old remote hook is kept as a fallback.
--  2. Coins the server would reject anyway are skipped:
--     - locked zones (some "Coin" models have a PreventClick attribute),
--     - coins that are still falling (HasLanded is required),
--     - coins with Health <= 0 (dying).
--  3. The search radius adapts automatically to the game's CoinGrabDistance, and every
--     ProbeInterval seconds the script checks whether the server accepts coins farther away.
--  4. The pet closest to the coin is picked (like GetClosestPet in the game), not in list order.
--  5. If there are fewer free coins than pets, the extra pets join the "fattest" coins
--     (before, they just stood idle).
--  6. Hits: while no damage is being dealt - send them often; once Health starts dropping -
--     stop spamming (the game itself sends "Farm Coin" once on arrival). If damage stalls -
--     resume; if that happens 3 times, the script switches to constant hits
--     (like the old version).
--  7. Only pets that the server actually accepted (from the Join Coin response) are used to hit.
--  8. Coins with Health <= 0 are released immediately, TravelGrace is shortened.
--
-- Usage: AutoFarm.Start(locations) / AutoFarm.Stop() / AutoFarm.SetLocation(...)
--        AutoFarm.SetCoinTypes({ "ALL: chest", "Diamonds", ... }) -- какие типы монет ломать (пусто/nil = все)
--        CoinManager.GetCoinTypes()              -- список: "ALL: категория" и "Имя без локации [категория]"
--        CoinManager.PrintTypes()                -- напечатать в консоль типы и сколько их сейчас на карте
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	LocationAttr = "Area",
	IdAttr       = "ID",
	OwnerAttr    = "Owner",
	NameAttr     = "Name",   -- тип монеты (атрибут ставит игра в Coins.lua)

	SearchRadius   = math.huge, -- "auto" | number | math.huge (unlimited). Как в старом фарме: все монеты на карте
	ProbeInterval  = 15,     -- every N sec try a coin farther than the current radius
	ProbeFactor    = 1.5,    -- how many times farther to probe
	RequireLanded  = false,  -- only take coins that have landed (false = как в старом фарме)

	PetsPerCoin    = 1,      -- initial number of pets per coin
	MaxPetsPerCoin = 100,    -- cap when adding extra pets
	JoinExtraPets  = true,   -- send extra pets to already occupied coins

	LoopInterval   = 0.2,    -- fallback assignment loop (the main trigger is event-based)
	HitInterval    = 0.2,    -- how often to send hits when they are needed
	StallResume    = 2.5,    -- sec without Health dropping -> start sending hits again
	SendDelay      = 0.02,   -- delay between assignments
	TravelGrace    = 10,     -- sec for travel: the coin is not dropped while Health hasn't changed
	StuckTimeout   = 6,      -- sec without Health change after combat started -> release the coin
	MaxAssignTime  = 15,     -- sec per coin without a Health attribute
	RejectCooldown = 5,      -- sec a rejected coin is skipped
	RejectMsgCooldown = 20,  -- same, if the server returned a text reason
	MaxHitsPerTick = 100,    -- max FireServer calls per tick
}

--------------------------------------------------------------------------------
-- SERVICES AND UTILITIES
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

local learnNotified = false

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

local function coinTypeName(coin)
	return tostring(coin:GetAttribute(CONFIG.NameAttr) or "Unknown")
end

-- фильтр типов монет. cats - категории ("coin", "chest", "safe", "vault"...), names - имена БЕЗ названия локации
-- ("Crate", "Large Coins", "Diamonds"...). Оба nil -> ломаем все типы. Монета проходит, если подходит категория ИЛИ имя.
local TypeFilter = { cats = nil, names = nil }
local CAT_PREFIX = "ALL: "
local function stripLabel(s)
	return (tostring(s):gsub("%s*%[[^%]]*%]%s*$", ""))
end

-- locations: nil (all) | "Name" | { "Name1", "Name2" } | { Name1 = true, ... }
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
-- 0. SERVER COMMUNICATION
--   Main path: the game's Library.Network (like the game's Pets/Coins scripts).
--   Fallback path: intercepting a real call via hookmetamethod (clicking a coin).
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
						task.defer(notify, "Remotes saved, farm is ready")
					end
				end
			end
			return old(self, ...)
		end))
	end
end

if not Net.useLibrary then installHook() end

local function switchToHook()
	if not Net.useLibrary then return end
	Net.useLibrary = false
	installHook()
end

local function remotesReady()
	if Net.useLibrary then return true end
	if not needRF() and not needRE() then
		learnNotified = false
		return true
	end
	if not learnNotified then
		learnNotified = true
		notify("Click a coin once and wait a couple of seconds")
	end
	return false
end

-- Join Coin: returns ok, result ({ [uid] = true | "reason text" })
local function netJoin(id, pets)
	if Net.useLibrary then
		local ok, res = pcall(Library.Network.Invoke, "Join Coin", id, pets)
		if ok and type(res) == "table" then
			Net.libOk += 1
		else
			Net.libFails += 1
			if Net.libOk == 0 and Net.libFails >= 5 then switchToHook() end
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

-- Farm Coin: a pet hits the coin
local function netHit(id, petId)
	if Net.useLibrary then
		Library.Network.Fire("Farm Coin", id, petId)
	elseif not needRE() then
		_G.PetRE:FireServer(id, petId)
	end
end

--------------------------------------------------------------------------------
-- 1. COINS
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

-- категория монеты по landSound из игрового Directory (coin, chest, safe, vault, luckyblock...)
local catCache = {}
local function coinCategory(name)
	local cached = catCache[name]
	if cached then return cached end
	local ok, cat = pcall(function()
		return Library.Directory.Coins[name].landSound
	end)
	if ok and cat then
		cat = tostring(cat)
		catCache[name] = cat
		return cat
	end
	return "?"
end

-- имя монеты без названия локации в начале: "Heaven Island Large Coins" -> "Large Coins"
local function coinBaseName(coin)
	local name = coinTypeName(coin)
	local area = coinLocation(coin)
	local prefix = area .. " "
	if area ~= "Unknown" and #name > #prefix and string.sub(name, 1, #prefix) == prefix then
		return string.sub(name, #prefix + 1)
	end
	return name
end

local function typeAllowed(coin)
	if not TypeFilter.cats and not TypeFilter.names then return true end
	if TypeFilter.cats and TypeFilter.cats[coinCategory(coinTypeName(coin))] then return true end
	if TypeFilter.names and TypeFilter.names[coinBaseName(coin)] then return true end
	return false
end

-- список для GUI: сначала категории целиком ("ALL: chest"), потом конкретные типы без локации ("Crate [chest]")
function CoinManager.GetCoinTypes()
	local cats, seen, baseList = {}, {}, {}
	for coin in pairs(CoinManager.AllCoins) do
		local cat = coinCategory(coinTypeName(coin))
		local base = coinBaseName(coin)
		cats[cat] = true
		seen[cat] = seen[cat] or {}
		if not seen[cat][base] then
			seen[cat][base] = true
			baseList[#baseList + 1] = { name = base, cat = cat }
		end
	end

	local catList = {}
	for cat in pairs(cats) do catList[#catList + 1] = cat end
	table.sort(catList)
	table.sort(baseList, function(a, b)
		if a.cat ~= b.cat then return a.cat < b.cat end
		return a.name < b.name
	end)

	local labels = {}
	for _, cat in ipairs(catList) do labels[#labels + 1] = CAT_PREFIX .. cat end
	for _, e in ipairs(baseList) do labels[#labels + 1] = e.name .. " [" .. e.cat .. "]" end
	return labels
end

function CoinManager.PrintTypes()
	local counts, keys = {}, {}
	for coin in pairs(CoinManager.AllCoins) do
		local key = coinBaseName(coin) .. " [" .. coinCategory(coinTypeName(coin)) .. "]"
		if not counts[key] then keys[#keys + 1] = key; counts[key] = 0 end
		counts[key] += 1
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		print(string.format("[Pets] %s x%d", key, counts[key]))
	end
end

-- is the coin suitable for farming (what the server will surely accept)
local function coinUsable(coin)
	if not coin.Parent then return false end
	if coin:GetAttribute("IsFalling") == true then return false end
	if CONFIG.RequireLanded and coin:GetAttribute("HasLanded") == false then return false end
	local hp = coin:GetAttribute("Health")
	if hp ~= nil and hp <= 0 then return false end
	local model = coin:FindFirstChild("Coin")
	if not model then return false end -- model not created by the game yet
	if model:GetAttribute("PreventClick") then return false end -- locked zone
	return true
end

-- coins of the selected locations (nil = all), closest first
function CoinManager.GetCoins(locations, origin, radius, skip)
	local filter = makeFilter(locations)
	local now = os.clock()
	local list = {}
	for coin in pairs(CoinManager.AllCoins) do
		if not (skip and skip[coin])
			and not CoinManager.IsRejected(coin, now)
			and (not filter or filter[coinLocation(coin)])
			and typeAllowed(coin)
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
-- 2. PETS
--------------------------------------------------------------------------------
local function isMine(pet)
	local owner = pet:GetAttribute(CONFIG.OwnerAttr)
	return owner ~= nil
		and (owner == LocalPlayer.Name or tostring(owner) == tostring(LocalPlayer.UserId))
end

-- list of { id, pos } of my pets
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

-- [coin] = { id, pets (accepted), pending (sent, awaiting reply), accepted,
--            assignedAt, lastHealth, lastProgress, started, quiet }
local assignments = {}
local Learn = { stalls = 0, needRepeat = true } -- true = бить постоянно, как в старой версии
local Radius = { current = nil, lastProbe = 0 }

-- Стратегия, которую выставляет Smart Farm (nil = обычный режим по CONFIG)
--   order:    "nearest" | "smallest" | "largest" | "bytype"
--   perCoin:  сколько петов на монету
local Strategy = { order = nil, perCoin = nil, focusType = nil }

-- порядок, в котором монеты раздаются свободным петам
local function sortTargets(targets, order)
	if order == "smallest" or order == "largest" then
		local asc = order == "smallest"
		for _, it in ipairs(targets) do
			local hp = it.coin:GetAttribute("Health")
			it.hp = type(hp) == "number" and hp or (asc and math.huge or -1)
		end
		table.sort(targets, function(a, b)
			if a.hp ~= b.hp then
				if asc then return a.hp < b.hp end
				return a.hp > b.hp
			end
			return a.dist < b.dist
		end)
	elseif order == "bytype" then
		-- ломаем один тип монет до конца, потом берём следующий (самый многочисленный)
		local counts = {}
		for _, it in ipairs(targets) do
			it.base = coinBaseName(it.coin)
			counts[it.base] = (counts[it.base] or 0) + 1
		end
		local focus = Strategy.focusType
		if not (focus and counts[focus]) then
			focus = nil
			local bestN = 0
			for name, n in pairs(counts) do
				if n > bestN or (n == bestN and focus and name < focus) then
					bestN, focus = n, name
				end
			end
			Strategy.focusType = focus
		end
		table.sort(targets, function(a, b)
			local fa, fb = a.base == focus, b.base == focus
			if fa ~= fb then return fa end
			return a.dist < b.dist
		end)
	end
end

local function baseRadius()
	if CONFIG.SearchRadius ~= "auto" then return CONFIG.SearchRadius end
	if not Radius.current then
		local d = Library and Library.Settings and Library.Settings.CoinGrabDistance
		Radius.current = (type(d) == "number" and d > 0) and d or math.huge
	end
	return Radius.current
end

-- send a set of pets to a coin (isExtra - addition to an already accepted coin)
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
			if #acc == 0 then -- unknown key format: count any true
				local n = 0
				for _, v in pairs(res) do
					if v == true then n += 1 elseif type(v) == "string" then reason = v end
				end
				if n > 0 then acc = table.clone(pets) end
			end
		end

		if #acc > 0 then
			local now = os.clock()
			for _, id in ipairs(acc) do a.pets[#a.pets + 1] = id end
			if not a.accepted then
				a.accepted = true
				a.lastProgress = now
				a.lastHealth = coin:GetAttribute("Health")
			end
			local pos, origin = getPos(coin), getRootPos()
			if pos and origin then
				local d = (pos - origin).Magnitude
				-- server accepted a coin beyond the radius -> expand it
				if CONFIG.SearchRadius == "auto" and Radius.current and d > Radius.current then
					Radius.current = d
				end
			end
		else
			if isExtra then
				a.noExtraUntil = os.clock() + 10
			elseif assignments[coin] == a and #a.pets == 0 and next(a.pending) == nil then
				assignments[coin] = nil
				CoinManager.Reject(coin, reason and CONFIG.RejectMsgCooldown or CONFIG.RejectCooldown)
			end
		end
	end)
end

-- Hits on accepted coins
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
-- 3. PET CONTROL
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
	if #pets == 0 then return end

	local origin = getRootPos()
	if not origin then return end

	local filter = makeFilter(locations)
	local now = os.clock()
	local busy = {}

	-- 1) check current assignments
	for coin, a in pairs(assignments) do
		local release, penalize = false, false
		if not coin.Parent or not getPos(coin) then
			release = true
		elseif filter and not filter[coinLocation(coin)] then
			release = true
		elseif not typeAllowed(coin) then
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

	-- 2) radius (+ rare probe of a farther coin)
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

	if Strategy.order then sortTargets(targets, Strategy.order) end

	-- 3) pet <-> coin: for each coin (nearest first) take the closest free pet
	local idx = 0
	local basePer = Strategy.perCoin or CONFIG.PetsPerCoin
	local perCoin = math.min(#pets, math.max(1, math.floor(tonumber(basePer) or 1)))
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

	-- 4) extra pets -> the "fattest" accepted coins
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
						local score = c.hp / (c.load + 1) -- estimated kill time
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
-- 4. AUTOFARM
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil, Restarts = 0 }
local farmConnections = {}
local runId = 0

-- key = имя поля в CONFIG: интервал читается каждый цикл, поэтому слайдеры в GUI работают на лету
local function loop(id, key, fn)
	task.spawn(function()
		local lastErr
		while AutoFarm.Enabled and runId == id do
			local ok, err = pcall(fn)
			if not ok and err ~= lastErr then
				lastErr = err
				warn("[Pets] ошибка в цикле " .. key .. ": " .. tostring(err))
			end
			task.wait(math.max(0.01, tonumber(CONFIG[key]) or 0.2))
		end
	end)
end

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Restarts += 1 -- Smart Farm по этому счётчику понимает, что условия сменились
	AutoFarm.Location = locations
	runId += 1
	local id = runId
	PetController.Reset()
	learnNotified = false

	loop(id, "LoopInterval", function()
		PetController.Distribute(AutoFarm.Location)
	end)
	loop(id, "HitInterval", hitAll)

	-- coin broken/spawned -> reassign right away, don't wait for the loop
	local pending = false
	local function quick()
		if pending then return end
		pending = true
		task.defer(function()
			pending = false
			if AutoFarm.Enabled and runId == id then
				pcall(PetController.Distribute, AutoFarm.Location)
			end
		end)
	end
	table.insert(farmConnections, CoinsFolder.ChildRemoved:Connect(function(c)
		if assignments[c] then assignments[c] = nil end
		quick()
	end))
	-- the game fires "Remove Coin" before the folder is removed (there's a fade-out animation)
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

-- то же самое, что выключить и включить чекбокс: сброс назначений и отказов, новые циклы.
-- GUI вызывает это после любой смены настроек, чтобы фарм не "залипал".
function AutoFarm.Restart()
	if not AutoFarm.Enabled then return end
	local loc = AutoFarm.Location
	AutoFarm.Stop()
	table.clear(CoinManager.Rejected)
	AutoFarm.Start(loc)
end

-- types: nil / {} = ломать все типы
--   { "ALL: chest", "ALL: coin", "Crate [chest]", "Diamonds", ... }  (метки из GetCoinTypes, подходят и просто имена)
-- Неизвестные записи (опечатки, названия локаций и т.п.) игнорируются, чтобы фильтр не отсёк все монеты.
local KNOWN_CATS = {
	coin = true, cardboard_coin = true, chest = true, cardboard_chest = true,
	safe = true, vault = true, special = true, luckyblock = true,
}

local function knownCategory(cat)
	if KNOWN_CATS[cat] then return true end
	for coin in pairs(CoinManager.AllCoins) do
		if coinCategory(coinTypeName(coin)) == cat then return true end
	end
	return false
end

local function knownBaseName(name)
	for coin in pairs(CoinManager.AllCoins) do
		if coinBaseName(coin) == name or coinTypeName(coin) == name then return true end
	end
	return false
end

function AutoFarm.SetCoinTypes(types)
	local cats, names, n = {}, {}, 0
	local function add(entry)
		entry = tostring(entry)
		if string.sub(entry, 1, #CAT_PREFIX) == CAT_PREFIX then
			local cat = string.sub(entry, #CAT_PREFIX + 1)
			if knownCategory(cat) then
				cats[cat] = true
				n += 1
			else
				warn("[Pets] Неизвестная категория монет, пропускаю: " .. cat)
			end
		else
			local name = stripLabel(entry)
			if name == "" then return end
			if knownBaseName(name) then
				names[name] = true
				n += 1
			else
				warn("[Pets] Неизвестный тип монеты, пропускаю: " .. name)
			end
		end
	end

	if type(types) == "table" then
		for k, v in pairs(types) do
			if type(k) == "number" then
				add(v)
			elseif v then
				add(k)
			end
		end
	elseif type(types) == "string" and types ~= "" then
		add(types)
	end

	if n == 0 then
		TypeFilter.cats, TypeFilter.names = nil, nil
	else
		TypeFilter.cats = next(cats) and cats or nil
		TypeFilter.names = next(names) and names or nil
	end
end

--------------------------------------------------------------------------------
-- 5. SMART FARM (самообучающийся режим)
--   Пробует разные стратегии по очереди, меряет, сколько HP монет ломается в секунду,
--   и дальше фармит лучшей. Раз в RecheckEvery сек (или если доход упал) перепроверяет.
--   Стратегия = порядок выдачи монет (ближние / мелкие / крупные / по одному типу)
--               + сколько петов отправлять на одну монету.
--   Что делает и о чём думает - Smart.GetStatus() (GUI показывает это в Status).
--------------------------------------------------------------------------------
local ORDERS = { "nearest", "smallest", "largest", "bytype" }
local ORDER_LABEL = {
	nearest  = "nearest coins first",
	smallest = "smallest coins first",
	largest  = "biggest coins first",
	bytype   = "one coin type at a time",
}

local Smart = {
	Enabled = false,
	TrialTime = 25,     -- сек на один тест
	Warmup = 6,         -- первые сек теста не считаются (петы переключаются)
	RecheckEvery = 300, -- сек между перепроверками
	Phase = "Off",
	Live = nil,
	Scores = {},
	Log = {},
	ForceRetest = false,
}
local smartRun = 0

local function fmtNum(n)
	local suf = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx" }
	local i = 1
	while n >= 1000 and i < #suf do n /= 1000; i += 1 end
	if i == 1 then return string.format("%d", math.floor(n + 0.5)) end
	return string.format(n >= 100 and "%.0f%s" or (n >= 10 and "%.1f%s" or "%.2f%s"), n, suf[i])
end

local function pct(a, b)
	if not a or not b or b <= 0 then return "" end
	return string.format("%+d%%", math.floor((a / b - 1) * 100 + 0.5))
end

local function think(msg)
	if Smart.Log[#Smart.Log] == msg then return end
	table.insert(Smart.Log, msg)
	while #Smart.Log > 6 do table.remove(Smart.Log, 1) end
end

local function mkArm(order, per)
	return { order = order, perCoin = per, key = order .. "|" .. per }
end

local function armLabel(arm)
	return ORDER_LABEL[arm.order] .. ", " .. arm.perCoin .. (arm.perCoin == 1 and " pet" or " pets") .. " per coin"
end

local function record(arm, score, kpm)
	local s = Smart.Scores[arm.key]
	if s then
		s.score = s.score * 0.5 + score * 0.5 -- сглаживание: условия на карте шумят
		s.kpm = kpm
		s.n += 1
	else
		Smart.Scores[arm.key] = { arm = arm, score = score, kpm = kpm, n = 1 }
	end
end

local function ranking()
	local list = {}
	for _, s in pairs(Smart.Scores) do list[#list + 1] = s end
	table.sort(list, function(a, b) return a.score > b.score end)
	return list
end

-- Один замер: включает стратегию и считает, сколько HP монет сломано за секунду.
-- Возвращает score, "ok", монет_в_минуту | nil, причина ("abort" | "restart" | "nocoins")
local function runTrial(id, arm)
	Strategy.order, Strategy.perCoin = arm.order, arm.perCoin
	Strategy.focusType = nil

	local T = math.max(Smart.TrialTime, Smart.Warmup + 6)
	local startT = os.clock()
	local last = startT
	local restarts0 = AutoFarm.Restarts
	local seenCoins = {} -- [coin] = { hp, seen }
	local dmg, kills, measured, busy = 0, 0, 0, 0

	while true do
		task.wait(0.25)
		if not (Smart.Enabled and smartRun == id and AutoFarm.Enabled) then return nil, "abort" end
		if AutoFarm.Restarts ~= restarts0 then return nil, "restart" end

		local now = os.clock()
		local dt = now - last
		last = now
		local elapsed = now - startT
		local counting = elapsed >= Smart.Warmup

		for coin in pairs(assignments) do
			if coin.Parent then
				local hp = coin:GetAttribute("Health")
				if type(hp) == "number" then
					local e = seenCoins[coin]
					if e then
						if counting and hp < e.hp then dmg += e.hp - hp end
						e.hp, e.seen = hp, now
					else
						seenCoins[coin] = { hp = hp, seen = now }
					end
				end
			end
		end
		for coin, e in pairs(seenCoins) do
			if not coin.Parent then
				-- монета исчезла: если мы с ней работали - остаток HP тоже наш (сломали)
				if now - e.seen < 2 and counting then
					if e.hp > 0 then dmg += e.hp end
					kills += 1
				end
				seenCoins[coin] = nil
			elseif now - e.seen > 5 then
				seenCoins[coin] = nil
			end
		end

		if counting then
			measured += dt
			if next(assignments) then busy += dt end
		end

		Smart.Live = {
			left = T - elapsed,
			rate = measured > 2 and dmg / measured or nil,
			warm = not counting,
		}
		if elapsed >= T then break end
	end

	if measured < 3 or busy < measured * 0.6 then return nil, "nocoins" end
	return dmg / measured, "ok", kills / measured * 60
end

local function smartMain(id)
	local function alive() return Smart.Enabled and smartRun == id end

	-- тест стратегии (с повтором, если монет не было)
	local function test(arm, idx, total)
		for _ = 1, 3 do
			if not alive() then return nil, "abort" end
			Smart.Phase = string.format("Testing %d/%d: %s", idx, total, armLabel(arm))
			local score, why, kpm = runTrial(id, arm)
			if score then
				record(arm, score, kpm)
				think(string.format("%s: %s HP/s, ~%d coins/min", armLabel(arm), fmtNum(score), math.floor(kpm + 0.5)))
				return score, "ok"
			end
			if why ~= "nocoins" then return nil, why end
			Smart.Phase = "No coins of the selected types here - waiting..."
			think("No coins to break right now, waiting for spawns")
			task.wait(3)
		end
		return nil, "nocoins"
	end

	-- этап 1: порядок монет (1 пет на монету), этап 2: сколько петов на монету
	local function explore(N)
		Smart.Scores = {}
		local arms = {}
		for _, o in ipairs(ORDERS) do arms[#arms + 1] = mkArm(o, 1) end
		local ks, seen = {}, { [1] = true }
		for _, k in ipairs({ 2, math.ceil(N / 2), N }) do
			if k >= 2 and k <= N and not seen[k] then
				seen[k] = true
				ks[#ks + 1] = k
			end
		end
		table.sort(ks)
		local total = #arms + #ks
		think(string.format("Search started: %d pets, %d strategies to test", N, total))

		for i, arm in ipairs(arms) do
			local sc, why = test(arm, i, total)
			if not sc and why ~= "nocoins" then return false, why end
		end
		local r = ranking()
		if #r == 0 then return false, "nocoins" end

		local bestOrder = r[1].arm.order
		local nearest = Smart.Scores[mkArm("nearest", 1).key]
		think(string.format("Best order: %s (%s vs nearest). Now testing pets per coin",
			ORDER_LABEL[bestOrder], pct(r[1].score, nearest and nearest.score)))

		for j, k in ipairs(ks) do
			local sc, why = test(mkArm(bestOrder, k), #arms + j, total)
			if not sc and why ~= "nocoins" then return false, why end
		end

		local top = ranking()[1]
		local one = Smart.Scores[mkArm(bestOrder, 1).key]
		if top.arm.perCoin == 1 then
			think("1 pet per coin wins: pets work in parallel, nothing is wasted on overkill")
		else
			think(string.format("%d pets per coin wins (%s vs 1 pet): coins die faster, less walking",
				top.arm.perCoin, pct(top.score, one and one.score)))
		end
		return true
	end

	-- перепроверка: 2 ближайших конкурента + одна случайная из остальных
	local function challenge()
		local r = ranking()
		if #r < 2 then return end
		local bestKey = r[1].arm.key
		local picks = {}
		for i = 2, math.min(#r, 3) do picks[#picks + 1] = r[i].arm end
		if #r > 3 then picks[#picks + 1] = r[math.random(4, #r)].arm end
		for i, arm in ipairs(picks) do
			local sc, why = test(arm, i, #picks)
			if not sc and why ~= "nocoins" then return end
		end
		local nr = ranking()
		if nr[1].arm.key ~= bestKey then
			think(string.format("Switching to: %s (%s)", armLabel(nr[1].arm),
				pct(nr[1].score, Smart.Scores[bestKey] and Smart.Scores[bestKey].score)))
		else
			think("Re-check done: staying with " .. armLabel(nr[1].arm))
		end
	end

	while alive() do
		if not AutoFarm.Enabled then
			Strategy.order, Strategy.perCoin, Strategy.focusType = nil, nil, nil
			Smart.Phase = "Waiting: turn on Pets Auto Farm"
			Smart.Live = nil
			task.wait(1)
			continue
		end
		local N = #GetEquippedPets()
		if N == 0 then
			Smart.Phase = "No equipped pets"
			task.wait(2)
			continue
		end

		local ok, why = explore(N)
		if not alive() then break end
		if not ok then
			if why == "restart" then think("Settings changed - search starts over") end
			if why == "nocoins" then task.wait(3) end
			continue
		end

		-- эксплуатация лучшей стратегии с постоянным контролем дохода
		local lastCheck = os.clock()
		local lastChallenge = lastCheck
		while alive() and AutoFarm.Enabled do
			local best = ranking()[1]
			if not best then break end
			Smart.Phase = "Farming with the best: " .. armLabel(best.arm)
			local prev = best.score
			local sc, why2, kpm = runTrial(id, best.arm)
			if not sc then
				if why2 == "restart" or why2 == "abort" then break end
				task.wait(2)
			else
				record(best.arm, sc, kpm)
				if Smart.ForceRetest then
					Smart.ForceRetest = false
					think("Manual re-test requested")
					break
				end
				local now = os.clock()
				local dropped = sc < prev * 0.6 and now - lastChallenge > 60
				if dropped then
					think("Income dropped (" .. pct(sc, prev) .. "), checking alternatives")
				end
				if dropped or now - lastCheck >= Smart.RecheckEvery then
					challenge()
					lastCheck = os.clock()
					lastChallenge = lastCheck
				end
			end
		end
	end
end

function Smart.Start()
	if Smart.Enabled then return end
	Smart.Enabled = true
	smartRun += 1
	Smart.Scores, Smart.Log, Smart.Live = {}, {}, nil
	Smart.Phase = "Starting..."
	task.spawn(smartMain, smartRun)
end

function Smart.Stop()
	Smart.Enabled = false
	smartRun += 1
	Strategy.order, Strategy.perCoin, Strategy.focusType = nil, nil, nil
	Smart.Phase, Smart.Live = "Off", nil
end

function Smart.Retest()
	Smart.ForceRetest = true
end

function Smart.GetStatus()
	if not Smart.Enabled then return "Smart Farm is off" end
	local lines = { Smart.Phase or "..." }
	local live = Smart.Live
	if live and AutoFarm.Enabled then
		table.insert(lines, string.format("Now: %s HP/s | %d s left%s",
			live.rate and fmtNum(live.rate) or "...",
			math.max(0, math.ceil(live.left)),
			live.warm and " (warm-up)" or ""))
	end
	if Strategy.order == "bytype" and Strategy.focusType then
		table.insert(lines, "Focus type: " .. Strategy.focusType)
	end
	local r = ranking()
	if #r > 0 then
		table.insert(lines, "Best: " .. armLabel(r[1].arm) .. " = " .. fmtNum(r[1].score) .. " HP/s")
		if #r > 1 then
			table.insert(lines, "Next: " .. armLabel(r[2].arm) .. " = " .. fmtNum(r[2].score) .. " HP/s")
		end
	end
	if #Smart.Log > 0 then
		table.insert(lines, "Thinking:")
		for i = math.max(1, #Smart.Log - 3), #Smart.Log do
			table.insert(lines, "- " .. Smart.Log[i])
		end
	end
	return table.concat(lines, "\n")
end

_G.PetTools = {
	GetPetCount = function() return #GetEquippedPets() end, -- сколько петов сейчас экипировано
	Smart = Smart,
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
	Destroy = function()
		Smart.Stop()
		AutoFarm.Stop()
		for _, c in ipairs(CoinManager.Connections) do c:Disconnect() end
		table.clear(CoinManager.Connections)
	end,
}
