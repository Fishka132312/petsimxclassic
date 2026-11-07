--------------------------------------------------------------------------------ккув
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
--        AutoFarm.SetCoinTypes({ "Chests", "Diamonds", ... })  -- какие группы монет ломать (пусто/nil = все)
--        AutoFarm.SetChestSizes({ "Small", "Medium", "Large" }) -- размер сундуков (только для группы Chests; пусто/nil = все размеры)
--        CoinManager.GetCoinTypes()              -- список групп: Coins, Chests, Safes, Vaults + найденные (Diamonds, Presents...)
--        CoinManager.PrintTypes()                -- напечатать в консоль группы, какие монеты в них попали и сколько их на карте
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

-- фильтр групп монет: groups = { [normKey] = true } или nil (ломаем все группы).
-- Группы: Coins, Chests, Safes, Vaults + то, что нашлось на карте (Diamonds, Presents, ...).
local TypeFilter = { groups = nil }

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

-- ===== ГРУППЫ МОНЕТ =====
-- Каждая монета попадает ровно в одну группу:
--   1) по ключевым словам в названии (Diamonds, Presents) - они идут первыми, потому что у них своя категория в игре;
--   2) по категории игры (landSound): coin -> Coins, chest -> Chests, safe -> Safes, vault -> Vaults;
--   3) любая другая категория игры становится отдельной группой с её названием (lucky_block -> "Lucky Block");
--   4) если игровой Directory недоступен - угадываем по названию, иначе "Other".
local BASE_GROUPS = { "Coins", "Chests", "Safes", "Vaults" } -- есть в списке всегда
local BASE_SET = {}
for _, g in ipairs(BASE_GROUPS) do BASE_SET[g] = true end

local CATEGORY_GROUP = {
	coin = "Coins", cardboard_coin = "Coins",
	chest = "Chests", cardboard_chest = "Chests",
	safe = "Safes", vault = "Vaults",
	luckyblock = "Lucky Blocks",
}
local NAME_GROUP = { -- { подстрока в названии (нижний регистр), группа }
	{ "diamond", "Diamonds" },
	{ "present", "Presents" },
	{ "gift", "Presents" },
}

local function normKey(s)
	local k = tostring(s):lower():gsub("[%s_%-]+", "")
	k = k:gsub("s$", "")
	return k
end

local function prettify(s)
	s = tostring(s):gsub("_", " ")
	return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

local groupCache = {}  -- [полное название монеты] = { name, key }
local knownGroups = {} -- дополнительные группы, которые уже встречались на карте (остаются в списке)

local function classify(typeName)
	local cached = groupCache[typeName]
	if cached then return cached end

	local lname = typeName:lower()
	local group
	for _, rule in ipairs(NAME_GROUP) do
		if lname:find(rule[1], 1, true) then group = rule[2]; break end
	end
	if not group then
		local cat = coinCategory(typeName)
		if cat ~= "?" then
			group = CATEGORY_GROUP[cat] or prettify(cat)
		elseif lname:find("chest", 1, true) then group = "Chests"
		elseif lname:find("safe", 1, true) then group = "Safes"
		elseif lname:find("vault", 1, true) then group = "Vaults"
		elseif lname:find("coin", 1, true) then group = "Coins"
		else group = "Other" end
	end

	cached = { name = group, key = normKey(group) }
	groupCache[typeName] = cached
	return cached
end

-- ===== РАЗМЕР СУНДУКОВ (Small / Medium / Large) =====
-- 1) по ключевым словам в названии сундука (Mini/Tiny/Small, Medium, Large/Big/Huge/Giant/Mega);
-- 2) если слов нет - по максимальному здоровью сундука: самые слабые = Small, самые крепкие = Large.
local CHEST_SIZES = { "Small", "Medium", "Large" }
local SizeFilter = { sizes = nil }  -- { ["Small"] = true, ... } или nil (все размеры)

local SIZE_WORDS = {
	{ "mini", "Small" }, { "tiny", "Small" }, { "small", "Small" },
	{ "medium", "Medium" },
	{ "large", "Large" }, { "big", "Large" }, { "huge", "Large" }, { "giant", "Large" }, { "mega", "Large" },
}

local typeMaxHp = {}        -- [полное название монеты] = максимальное увиденное здоровье
local sizeByHp = {}         -- [полное название монеты] = размер (для сундуков без ключевых слов)
local sizeDirty = false

local function sizeByWords(typeName)
	local l = typeName:lower()
	for _, rule in ipairs(SIZE_WORDS) do
		if l:find(rule[1], 1, true) then return rule[2] end
	end
	return nil
end

local function rebuildHpSizes()
	sizeDirty = false
	table.clear(sizeByHp)
	local list = {}
	for tn, hp in pairs(typeMaxHp) do
		if classify(tn).key == normKey("Chests") and not sizeByWords(tn) then
			list[#list + 1] = { name = tn, hp = hp }
		end
	end
	table.sort(list, function(a, b) return a.hp < b.hp end)
	local n = #list
	for i, e in ipairs(list) do
		local size = "Medium"
		if n > 1 then
			local r = (i - 1) / (n - 1)
			size = r < 0.34 and "Small" or (r > 0.66 and "Large" or "Medium")
		end
		sizeByHp[e.name] = size
	end
end

local function chestSize(coin)
	local tn = coinTypeName(coin)
	local hp = coin:GetAttribute("Health")
	if type(hp) == "number" and hp > (typeMaxHp[tn] or 0) then
		typeMaxHp[tn] = hp
		sizeDirty = true
	end
	local byWords = sizeByWords(tn)
	if byWords then return byWords end
	if sizeDirty then rebuildHpSizes() end
	return sizeByHp[tn] or "Medium"
end

local function typeAllowed(coin)
	local info = classify(coinTypeName(coin))
	local groups = TypeFilter.groups
	if groups and groups[info.key] ~= true then return false end
	-- размер применяется только к сундукам, остальные группы не трогаем
	local sizes = SizeFilter.sizes
	if sizes and info.key == normKey("Chests") then
		return sizes[chestSize(coin)] == true
	end
	return true
end

-- список для GUI: Coins, Chests, Safes, Vaults + найденные на карте (Diamonds, Presents, ...)
function CoinManager.GetCoinTypes()
	for coin in pairs(CoinManager.AllCoins) do
		local g = classify(coinTypeName(coin)).name
		if not BASE_SET[g] then knownGroups[g] = true end
	end
	local labels = {}
	for _, g in ipairs(BASE_GROUPS) do labels[#labels + 1] = g end
	local extra = {}
	for g in pairs(knownGroups) do extra[#extra + 1] = g end
	table.sort(extra)
	for _, g in ipairs(extra) do labels[#labels + 1] = g end
	return labels
end

function CoinManager.GetChestSizes()
	return table.clone(CHEST_SIZES)
end

-- в консоль: какие монеты в какую группу попали (удобно, если что-то оказалось не в той группе)
function CoinManager.PrintTypes()
	local groups, order = {}, {}
	for coin in pairs(CoinManager.AllCoins) do
		local tn = coinTypeName(coin)
		local g = classify(tn).name
		local e = groups[g]
		if not e then
			e = { n = 0, names = {} }
			groups[g] = e
			order[#order + 1] = g
		end
		e.n += 1
		local label = coinBaseName(coin) .. " <" .. coinCategory(tn) .. ">"
		if classify(tn).key == normKey("Chests") then label = label .. " [" .. chestSize(coin) .. "]" end
		e.names[label] = (e.names[label] or 0) + 1
	end
	table.sort(order)
	for _, g in ipairs(order) do
		local e = groups[g]
		print(string.format("[Pets] %s x%d", g, e.n))
		local lines = {}
		for label, n in pairs(e.names) do lines[#lines + 1] = label .. " x" .. n end
		table.sort(lines)
		for _, line in ipairs(lines) do print("[Pets]    " .. line) end
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

	-- 3) pet <-> coin: for each coin (nearest first) take the closest free pet
	local idx = 0
	local perCoin = math.min(#pets, math.max(1, math.floor(tonumber(CONFIG.PetsPerCoin) or 1)))
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
local AutoFarm = { Enabled = false, Location = nil }
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

-- types: nil / {} = ломать все группы
--   { "Chests", "Diamonds", "Presents", ... }  (имена из GetCoinTypes; регистр не важен, "ALL: chest" тоже понимается)
-- Незнакомое имя группы тоже принимается: она может появиться на карте позже (например из сохранённого конфига).
function AutoFarm.SetCoinTypes(types)
	local groups, n = {}, 0
	local function add(entry)
		local name = (tostring(entry):gsub("^%s*[Aa][Ll][Ll]%s*:%s*", ""))
		name = name:match("^%s*(.-)%s*$")
		if name == "" then return end
		local mapped = CATEGORY_GROUP[name:lower()] -- старый формат: "chest", "coin"...
		groups[normKey(mapped or name)] = true
		n += 1
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

	TypeFilter.groups = (n > 0) and groups or nil
end

-- sizes: nil / {} = все размеры; { "Small", "Large" } = только эти (регистр не важен). Работает только для группы Chests.
function AutoFarm.SetChestSizes(sizes)
	local set, n = {}, 0
	local function add(entry)
		local l = tostring(entry):lower():match("^%s*(.-)%s*$")
		for _, sz in ipairs(CHEST_SIZES) do
			if l == sz:lower() then set[sz] = true; n += 1 end
		end
	end
	if type(sizes) == "table" then
		for k, v in pairs(sizes) do
			if type(k) == "number" then add(v) elseif v then add(k) end
		end
	elseif type(sizes) == "string" then
		add(sizes)
	end
	SizeFilter.sizes = (n > 0 and n < #CHEST_SIZES) and set or nil -- выбраны все 3 = без фильтра
end

_G.PetTools = {
	GetPetCount = function() return #GetEquippedPets() end, -- сколько петов сейчас экипировано
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
