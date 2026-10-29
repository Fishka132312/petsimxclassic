local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----5
local CheatName = "Evade"

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local scripts = {
  'AutoFarm/AutoCollectLootBags.lua',
  'AutoFarm/AutoCollectOrbs.lua',
  'AutoFarm/AutoFarm.lua',
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
-- КОНФИГ: ВСЁ, ЧТО НАДО ПОДОГНАТЬ ПОД ИГРУ, ТОЛЬКО ЗДЕСЬ
--------------------------------------------------------------------------------
local CONFIG = {
	CoinsFolderName     = "Coins",
	LocationsFolderName = "Locations",
	RemotesFolderName   = "Remotes",
	RemoteName          = "SendPetToCoin", -- проверь в декомпиле!

	-- Что отправлять в FireServer: "instance" (сам объект) или "id" (имя/UID)
	PetArgMode  = "instance",
	CoinArgMode = "instance",

	-- Атрибут с UID пета/монеты (если PetArgMode/CoinArgMode = "id").
	-- Если атрибута нет, будет использовано Name.
	PetIdAttribute  = "UID",
	CoinIdAttribute = "Id",

	SendDelay    = 0.05, -- пауза между отправками (защита от рейт-лимита)
	LoopInterval = 1.5,  -- как часто автофарм пересчитывает цели
}

--------------------------------------------------------------------------------
-- СЕРВИСЫ
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- WaitForChild с таймаутом, чтобы скрипт не висел вечно, если имя неверное
local function waitFor(parent, name, timeout)
	local obj = parent:WaitForChild(name, timeout or 10)
	if not obj then
		warn(string.format("[Pets] Не найден '%s' в %s. Проверь имя в CONFIG.", name, parent:GetFullName()))
	end
	return obj
end

local CoinsFolder = waitFor(Workspace, CONFIG.CoinsFolderName)
local LocationsFolder = Workspace:FindFirstChild(CONFIG.LocationsFolderName) -- необязательная
local Remotes = waitFor(ReplicatedStorage, CONFIG.RemotesFolderName)
local SendPetRemote = Remotes and waitFor(Remotes, CONFIG.RemoteName)

if not CoinsFolder or not SendPetRemote then
	return -- без монет или ремоута скрипт работать не сможет
end

--------------------------------------------------------------------------------
-- УТИЛИТЫ
--------------------------------------------------------------------------------
local function getPos(obj)
	if obj:IsA("Model") then
		return obj:GetPivot().Position
	end
	return obj.Position
end

local function getRootPos()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position
end

-- Лежит ли точка внутри части/модели (для определения локации по зонам)
local function isPointInside(container, point)
	local cf, size
	if container:IsA("BasePart") then
		cf, size = container.CFrame, container.Size
	elseif container:IsA("Model") then
		cf, size = container:GetBoundingBox()
	else
		return false
	end
	local rel = cf:PointToObjectSpace(point)
	return math.abs(rel.X) <= size.X / 2
		and math.abs(rel.Y) <= size.Y / 2
		and math.abs(rel.Z) <= size.Z / 2
end

-- Определяем локацию: атрибут -> зона из Locations -> "Unknown"
local function detectLocation(coin)
	local attr = coin:GetAttribute("Location")
	if attr then
		return tostring(attr)
	end

	if LocationsFolder then
		local pos = getPos(coin)
		for _, zone in ipairs(LocationsFolder:GetChildren()) do
			if isPointInside(zone, pos) then
				return zone.Name
			end
		end
	end

	return "Unknown"
end

--------------------------------------------------------------------------------
-- 1. МЕНЕДЖЕР МОНЕТ
--------------------------------------------------------------------------------
local CoinManager = {}
CoinManager.CoinsByLocation = {} -- [locationName] = { [coin] = true }
CoinManager.AllCoins = {}        -- [coin] = locationName

local function registerCoin(coin)
	if not (coin:IsA("BasePart") or coin:IsA("Model")) then return end

	local loc = detectLocation(coin)
	CoinManager.CoinsByLocation[loc] = CoinManager.CoinsByLocation[loc] or {}
	CoinManager.CoinsByLocation[loc][coin] = true
	CoinManager.AllCoins[coin] = loc
end

local function unregisterCoin(coin)
	local loc = CoinManager.AllCoins[coin]
	if loc and CoinManager.CoinsByLocation[loc] then
		CoinManager.CoinsByLocation[loc][coin] = nil
	end
	CoinManager.AllCoins[coin] = nil
end

-- Монеты могут лежать не прямо в папке, а во вложенных папках: берём всех потомков
for _, d in ipairs(CoinsFolder:GetDescendants()) do
	registerCoin(d)
end
CoinsFolder.DescendantAdded:Connect(registerCoin)
CoinsFolder.DescendantRemoving:Connect(unregisterCoin)

-- Имена всех найденных локаций (для дропдаунов)
function CoinManager.GetLocationNames()
	local names = {}
	for name in pairs(CoinManager.CoinsByLocation) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Список живых монет локации, отсортированный по расстоянию от origin.
-- locationName = nil -> все локации.
function CoinManager.GetCoins(locationName, origin)
	local list = {}
	local function collect(set)
		for coin in pairs(set) do
			if coin.Parent then
				table.insert(list, coin)
			end
		end
	end

	if type(locationName) == "table" then
		-- список локаций: { "Forest", "Desert" }
		for _, name in ipairs(locationName) do
			collect(CoinManager.CoinsByLocation[name] or {})
		end
	elseif locationName then
		collect(CoinManager.CoinsByLocation[locationName] or {})
	else
		for _, set in pairs(CoinManager.CoinsByLocation) do
			collect(set)
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
-- 2. ПЕТЫ
--------------------------------------------------------------------------------
local function GetEquippedPets()
	local pets = {}
	local folder = LocalPlayer:FindFirstChild("EquippedPets")
		or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Pets"))

	if folder then
		for _, pet in ipairs(folder:GetChildren()) do
			table.insert(pets, pet)
		end
	end
	return pets
end

local function toArg(obj, mode, attrName)
	if mode == "id" then
		return obj:GetAttribute(attrName) or obj.Name
	end
	return obj
end

local function fire(pet, coin)
	local petArg = toArg(pet, CONFIG.PetArgMode, CONFIG.PetIdAttribute)
	local coinArg = toArg(coin, CONFIG.CoinArgMode, CONFIG.CoinIdAttribute)

	local ok, err = pcall(function()
		if SendPetRemote:IsA("RemoteFunction") then
			SendPetRemote:InvokeServer(petArg, coinArg)
		else
			SendPetRemote:FireServer(petArg, coinArg)
		end
	end)
	if not ok then
		warn("[Pets] Ошибка отправки: " .. tostring(err))
	end
end

--------------------------------------------------------------------------------
-- 3. УПРАВЛЕНИЕ ПЕТАМИ
--------------------------------------------------------------------------------
local PetController = {}

-- Все петы на одну монету
function PetController.SendAllToOne(coin)
	if not coin or not coin.Parent then
		warn("[Pets] Монета недействительна")
		return
	end
	for _, pet in ipairs(GetEquippedPets()) do
		fire(pet, coin)
		task.wait(CONFIG.SendDelay)
	end
end

-- Каждый пет на свою ближайшую монету (по кругу, если монет меньше, чем петов).
-- locationName = nil -> берём монеты со всех локаций.
function PetController.Distribute(locationName)
	local pets = GetEquippedPets()
	local origin = getRootPos()
	local coins = CoinManager.GetCoins(locationName, origin)

	if #pets == 0 then return end
	if #coins == 0 then
		warn("[Pets] Нет монет" .. (locationName and (" в локации " .. locationName) or ""))
		return
	end

	for i, pet in ipairs(pets) do
		local coin = coins[((i - 1) % #coins) + 1]
		fire(pet, coin)
		task.wait(CONFIG.SendDelay)
	end
end

-- Случайные монеты
function PetController.Random(locationName)
	local pets = GetEquippedPets()
	local coins = CoinManager.GetCoins(locationName, nil)
	if #pets == 0 or #coins == 0 then return end

	for _, pet in ipairs(pets) do
		fire(pet, coins[math.random(1, #coins)])
		task.wait(CONFIG.SendDelay)
	end
end

--------------------------------------------------------------------------------
-- 4. АВТОФАРМ
--------------------------------------------------------------------------------
local AutoFarm = { Enabled = false, Location = nil } -- Location = nil -> все локации

function AutoFarm.Start(locationName)
	if AutoFarm.Enabled then return end
	AutoFarm.Enabled = true
	AutoFarm.Location = locationName

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

--------------------------------------------------------------------------------
-- ИСПОЛЬЗОВАНИЕ
--------------------------------------------------------------------------------
-- AutoFarm.Start()          -- фармить везде, ближайшие монеты в приоритете
-- AutoFarm.Start("Forest")  -- только локация Forest
-- AutoFarm.Stop()
-- PetController.SendAllToOne(workspace.Coins.MegaCoin)

-- Доступ из консоли/других скриптов (LocalScript не может return-ить модуль)
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
