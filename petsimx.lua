local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----2
local CheatName = "Evade"

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local scripts = {
  'AutoFarm/AutoCollectLootBags.lua',
  'AutoFarm/AutoCollectOrbs.lua',
}

local baseUrl = 'https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/'

for i, scriptName in ipairs(scripts) do
    local fullUrl = baseUrl .. scriptName
    
    local success, err = pcall(function()
        local code = game:HttpGet(fullUrl)
        if code then
            loadstring(code)()
        else
            warn("Не удалось получить код для: " .. scriptName)
        end
    end)
    
    if not success then
        warn("Ошибка при загрузке " .. scriptName .. ": " .. tostring(err))
    end
    
    task.wait(0.5)
end

-- ===== ФАРМ ПЕТАМИ (создаёт _G.PetTools) =====
task.spawn(function()
    local ok, err = pcall(function()
--------------------------------------------------------------------------------
-- КОНФИГ (значения сняты с реальной игры)
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsPath = { "__THINGS", "Coins" },
	PetsPath  = { "__THINGS", "Pets" },

	-- Индекс ремоута в ReplicatedStorage:GetChildren() (из Cobalt).
	-- Если фарм перестал работать, снова сними вызов в Cobalt и поменяй число.
	RemoteIndex = 182,

	LocationAttr = "Area",  -- атрибут монеты с названием локации
	IdAttr       = "ID",    -- атрибут ID у монет и петов
	OwnerAttr    = "Owner", -- атрибут владельца у пета

	PetsPerCoin  = 3,    -- сколько петов отправлять на одну монету
	SendDelay    = 0.05, -- пауза между вызовами
	LoopInterval = 1.5,  -- как часто автофарм пересчитывает цели
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ И УТИЛИТЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local warned = {}
local function warnOnce(key, text)
	if not warned[key] then
		warned[key] = true
		warn(text)
	end
end

local function getByPath(root, path)
	local cur = root
	for _, name in ipairs(path) do
		cur = cur:WaitForChild(name, 5)
		if not cur then
			warn(string.format("[Pets] Не найден '%s' (путь: %s)", name, table.concat(path, ".")))
			return nil
		end
	end
	return cur
end

local CoinsFolder = getByPath(Workspace, CONFIG.CoinsPath)
local PetsFolder = getByPath(Workspace, CONFIG.PetsPath)

if not CoinsFolder then
	return
end

-- Позиция монеты: часть POS, иначе меш Coin
local function getPos(coin)
	local p = coin:FindFirstChild("POS") or coin:FindFirstChild("Coin")
	if p and p:IsA("BasePart") then
		return p.Position
	end
	if coin:IsA("Model") then
		return coin:GetPivot().Position
	end
	if coin:IsA("BasePart") then
		return coin.Position
	end
	return Vector3.zero
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

--------------------------------------------------------------------------------
-- 1. МОНЕТЫ
-- Атрибуты (Area, HasLanded...) могут проставляться уже после появления монеты,
-- поэтому локацию читаем в момент запроса, а не при регистрации.
--------------------------------------------------------------------------------
local CoinManager = {}
CoinManager.AllCoins = {} -- [coin] = true

local function registerCoin(coin)
	CoinManager.AllCoins[coin] = true
end

local function unregisterCoin(coin)
	CoinManager.AllCoins[coin] = nil
end

for _, c in ipairs(CoinsFolder:GetChildren()) do
	registerCoin(c)
end
CoinsFolder.ChildAdded:Connect(registerCoin)
CoinsFolder.ChildRemoved:Connect(unregisterCoin)

local function coinLocation(coin)
	return tostring(coin:GetAttribute(CONFIG.LocationAttr) or "Unknown")
end

-- Имена всех локаций, где сейчас есть монеты
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

-- Живые монеты, отсортированные по расстоянию от origin.
-- locations: nil (все), строка или список строк.
function CoinManager.GetCoins(locations, origin)
	local filter
	if type(locations) == "string" then
		filter = { [locations] = true }
	elseif type(locations) == "table" then
		filter = {}
		for _, name in ipairs(locations) do
			filter[name] = true
		end
	end

	local list = {}
	for coin in pairs(CoinManager.AllCoins) do
		if coin.Parent
			and coin:GetAttribute("HasLanded") ~= false
			and coin:GetAttribute("IsFalling") ~= true
			and (not filter or filter[coinLocation(coin)])
		then
			table.insert(list, coin)
		end
	end

	if origin then
		table.sort(list, function(a, b)
			return (getPos(a) - origin).Magnitude < (getPos(b) - origin).Magnitude
		end)
	end
	return list
end

--------------------------------------------------------------------------------
-- 2. ПЕТЫ И РЕМОУТ
--------------------------------------------------------------------------------
-- ID моих петов: дети Pets с атрибутом Owner == мой ник
local function GetEquippedPetIds()
	local ids = {}
	local folder = PetsFolder or Workspace:FindFirstChild("__THINGS") and Workspace.__THINGS:FindFirstChild("Pets")
	if not folder then return ids end

	for _, pet in ipairs(folder:GetChildren()) do
		if pet:GetAttribute(CONFIG.OwnerAttr) == LocalPlayer.Name then
			local id = pet:GetAttribute(CONFIG.IdAttr)
			if id then
				table.insert(ids, tostring(id))
			end
		end
	end
	return ids
end

local cachedRemote
local function getRemote()
	if cachedRemote and cachedRemote.Parent then
		return cachedRemote
	end
	local r = ReplicatedStorage:GetChildren()[CONFIG.RemoteIndex]
	if r and r:IsA("RemoteFunction") then
		cachedRemote = r
		return r
	end
	warnOnce("remote", string.format(
		"[Pets] По индексу %d нет RemoteFunction (индекс мог сдвинуться). Сними вызов в Cobalt и обнови CONFIG.RemoteIndex.",
		CONFIG.RemoteIndex
	))
	return nil
end

-- Один вызов = группа петов на одну монету
local function sendGroup(coin, petIds)
	if not coin or not coin.Parent or #petIds == 0 then return end
	local remote = getRemote()
	if not remote then return end

	local coinId = tostring(coin:GetAttribute(CONFIG.IdAttr) or coin.Name)
	task.spawn(function()
		local ok, err = pcall(function()
			remote:InvokeServer(coinId, petIds)
		end)
		if not ok then
			warn("[Pets] Ошибка вызова: " .. tostring(err))
		end
	end)
end

-- Делит список петов на группы по PetsPerCoin
local function chunk(list, size)
	local groups = {}
	for i = 1, #list, size do
		local g = {}
		for j = i, math.min(i + size - 1, #list) do
			g[#g + 1] = list[j]
		end
		groups[#groups + 1] = g
	end
	return groups
end

--------------------------------------------------------------------------------
-- 3. УПРАВЛЕНИЕ ПЕТАМИ
--------------------------------------------------------------------------------
local PetController = {}

-- Все петы на одну монету
function PetController.SendAllToOne(coin)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end
	sendGroup(coin, ids)
end

-- Группы петов на ближайшие монеты выбранных локаций
function PetController.Distribute(locations)
	local ids = GetEquippedPetIds()
	if #ids == 0 then
		warnOnce("nopets", "[Pets] Не найдено петов с Owner = " .. LocalPlayer.Name)
		return
	end

	local coins = CoinManager.GetCoins(locations, getRootPos())
	if #coins == 0 then return end

	local groups = chunk(ids, math.max(1, CONFIG.PetsPerCoin))
	for i, group in ipairs(groups) do
		local coin = coins[((i - 1) % #coins) + 1]
		sendGroup(coin, group)
		task.wait(CONFIG.SendDelay)
	end
end

-- Группы петов на случайные монеты
function PetController.Random(locations)
	local ids = GetEquippedPetIds()
	local coins = CoinManager.GetCoins(locations, nil)
	if #ids == 0 or #coins == 0 then return end

	for _, group in ipairs(chunk(ids, math.max(1, CONFIG.PetsPerCoin))) do
		sendGroup(coins[math.random(1, #coins)], group)
		task.wait(CONFIG.SendDelay)
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil } -- Location: nil / строка / список

function AutoFarm.Start(locations)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locations

	task.spawn(function()
		while AutoFarm.Enabled do
			PetController.Distribute(AutoFarm.Location)
			task.wait(CONFIG.LoopInterval)
		end
	end)
end

function AutoFarm.Stop()
	AutoFarm.Enabled = false
end

_G.PetTools = {
	CoinManager = CoinManager,
	PetController = PetController,
	AutoFarm = AutoFarm,
	Config = CONFIG,
}

    end)
    if not ok then warn('[Pets] Ошибка в фарм-скрипте: ' .. tostring(err)) end
end)
-- ждём фарм максимум 4 сек, чтобы дропдаун сразу получил список локаций
do
    local waited = 0
    while not _G.PetTools and waited < 4 do task.wait(0.25) waited += 0.25 end
end

Library.Folders = {
    Directory = CheatName,
    Configs = CheatName .. "/Configs",
    Assets = CheatName .. "/Assets",
}

local Accent = Color3.fromRGB(0, 162, 255)
local Gradient = Color3.fromRGB(0, 80, 180)

Library.Theme.Accent = Accent
Library.Theme.AccentGradient = Gradient
Library:ChangeTheme("Accent", Accent)
Library:ChangeTheme("AccentGradient", Gradient)
local Window = Library:Window({
    Name = "Pet Sim X",
    SubName = "Meowl Sploit",
    Logo = "https://i.postimg.cc/R09KZw72/Bez-imeni-1.png"
})

-------------------------Event-----------------------

local AutoFarmCat = Window:Category("Event")
local EventPage = Window:Page({
		Name = "Auto Farm",
		Icon = "https://i.postimg.cc/6q7p8GSZ/Bez-imeni-2.png",
		Category = AutoFarmCat
})

--AutoFarm--
local AutoFarmSection = EventPage:Section({Name = "Auto Farm", Side = 1, Icon = "https://i.postimg.cc/tCDF4BRx/Bez-imeni-1.png"})

AutoFarmSection:Image({
    Id = "https://tr.rbxcdn.com/180DAY-e56b664ddfffd78fa53a7674d75d7841/768/432/Image/Webp/noFilter",
    Height = 90,
    Rounded = true
})

AutoFarmSection:Paragraph({
    Name = "Auto Farm",
    Text = "Bubble farming is recommended only on VIP servers."
})

AutoFarmSection:Divider()

-- ===== УПРАВЛЕНИЕ ФАРМОМ ПЕТАМИ =====
local selectedLocations = {}

local function normalize(Value)
	if type(Value) == "table" then
		local list = {}
		for k, v in pairs(Value) do
			if type(v) == "string" then
				table.insert(list, v)
			elseif v == true and type(k) == "string" then
				table.insert(list, k)
			end
		end
		return list
	end
	return Value and { Value } or {}
end

local function getLocationItems()
	local tools = _G.PetTools
	if tools then
		return tools.CoinManager.GetLocationNames()
	end
	return {}
end

local LocationDropdown = AutoFarmSection:Dropdown({
	Name = "Farm Locations",
	Tooltip = "Choose locations for pets farming",
	Flag = "FarmLocations",
	Items = getLocationItems(),
	Default = {},
	Multi = true,
	Size = 125,
	OptionHolderSize = 125,
	Callback = function(Value)
		selectedLocations = normalize(Value)
		local tools = _G.PetTools
		if tools and tools.AutoFarm.Enabled and #selectedLocations > 0 then
			tools.AutoFarm.Location = selectedLocations
		end
	end
})

local PetsFarmToggle = AutoFarmSection:Toggle({
	Name = "Pets Auto Farm",
	Tooltip = "Sends pets to coins in selected locations",
	Flag = "PetsAutoFarm",
	Default = false,
	Callback = function(Value)
		local tools = _G.PetTools
		if not tools then
			Library:Notification({
				Title = "Pets Farm",
				Description = "Farm script not loaded. Check console (F9)",
				Duration = 4
			})
			return
		end

		if Value then
			if #selectedLocations == 0 then
				Library:Notification({
					Title = "Pets Farm",
					Description = "Select at least one location",
					Duration = 3
				})
				return
			end
			tools.AutoFarm.Stop()
			tools.AutoFarm.Start(selectedLocations)
		else
			tools.AutoFarm.Stop()
		end
	end
})

-- Автообновление списка локаций (если у дропдауна есть метод обновления)
task.spawn(function()
	local last = ""
	while true do
		task.wait(5)
		local items = getLocationItems()
		local sig = table.concat(items, "|")
		if sig ~= last then
			last = sig
			for _, method in ipairs({ "Refresh", "SetItems", "SetOptions", "SetValues" }) do
				if type(LocationDropdown[method]) == "function" then
					if pcall(LocationDropdown[method], LocationDropdown, items) then break end
				end
			end
		end
	end
end)

local AutoFarmToggle = AutoFarmSection:Toggle({
    Name = "Auto Collect LootBags",
	Tooltip = "Automatically collects event bubbles on the map",
    Flag = "AutoCollectLootBags",
    Default = false,
    Callback = function(Value)
        _G.AutoCollectLootBags = Value
    end
})

local AutoFarmToggle = AutoFarmSection:Toggle({
    Name = "Auto Collect Orbs",
	Tooltip = "Automatically collects event bubbles on the map",
    Flag = "AutoCollectOrbs",
    Default = false,
    Callback = function(Value)
        _G.AutoCollectOrbs = Value
    end
})

local ThingsEventSection = EventPage:Section({Name = "Things", Side = 2, icon = "https://i.postimg.cc/cH8VsKQf/Bez-imeni-1.png"})

local Disable3dRenderToggle = ThingsEventSection:Toggle({
    Name = "Disable 3d Render",
	Tooltip = "Disables world rendering. FPS boost",
    Flag = "Disable3d",
    Default = false,
    Callback = function(Value)
       local RunService = game:GetService("RunService")
        RunService:Set3dRenderingEnabled(not Value)
    end
})


local EspBubblesToggle = ThingsEventSection:Toggle({
    Name = "Esp Bubbles",
	Tooltip = "Shows bubbles through the walls",
    Flag = "EspBubbles",
    Default = false,
    Callback = function(Value)
        _G.EspTickets = Value
    end
})

-------------------------Misc-----------------------

local MiscPage = Window:Page({
		Name = "Misc",
		Icon = "https://i.postimg.cc/CxnfNm71/Bez-imeni-1.png",
		Category = GameCat
})

--Misc--
local MiscSection = MiscPage:Section({Name = "Misc", Side = 1, Icon = "https://i.postimg.cc/CxnfNm71/Bez-imeni-1.png"})

MiscSection:Button({
    Name = "Anti Afk",
    Callback = function()
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/Evade/refs/heads/main/Things/Misc/AntiAfk.lua'))()
    end
})

MiscSection:Button({
    Name = "Anti Lag",
    Callback = function()
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/Evade/refs/heads/main/Things/Misc/AntiLag.lua'))()
    end
})

MiscSection:Button({
    Name = "Remote Spy",
    Callback = function()
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/Evade/refs/heads/main/Things/Misc/RemoteSpy.lua'))()
    end
})

MiscSection:Slider({
    Name = "FPS Cap",
    Tooltip = "Frame limit. Apply using the button below",
    Flag = "FpsCap",
    Min = 25,
    Max = 240,
    Default = 60,
    Suffix = " fps",
    Decimals = 1
})

MiscSection:Button({
    Name = "Apply FPS Cap",
    Tooltip = "Apply the selected FPS Cap",
    Callback = function()
        local Value = Library.Flags["FpsCap"]

        if setfpscap then
            setfpscap(Value)

            Library:Notification({
                Title = "Performance",
                Description = "FPS cap set to " .. Value,
                Duration = 3
            })
        else
            Library:Notification({
                Title = "Error",
                Description = "Exec dont support setfpscap",
                Duration = 4
            })
        end
    end
})

local SettingsCat = Window:Category("Settings")

local UiPage = Library:CreateUiPage(Window)
table.insert(SettingsCat.Elements, UiPage)
local SettingsPage = Library:CreateSettingsPage(Window, KeybindList)
table.insert(SettingsCat.Elements, SettingsPage)
Window:Init()
