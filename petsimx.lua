local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----22
local CheatName = "Evade"

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local scripts = {
  'AutoFarm/AutoCollectLootBags.lua',
  'AutoFarm/AutoCollectOrbs.lua',
  'AutoFarm/AutoFarm.lua',
  'Eggs/EggsOpen.lua',
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
-- Логика лежит в AutoFarm/AutoFarm.lua (он создаёт _G.PetTools при загрузке)
do
	local waited = 0
	while not _G.PetTools and waited < 4 do
		task.wait(0.25)
		waited += 0.25
	end
end

local selectedLocations = {}

-- Приводит значение дропдауна к списку строк
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
	return tools and tools.CoinManager.GetLocationNames() or {}
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
				Description = "AutoFarm.lua not loaded. Check console (F9)",
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
	local last = table.concat(getLocationItems(), "|")
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

-------------------------Eggs-----------------------
-- Логика лежит в Eggs/EggsOpen.lua (он создаёт _G.EggTools при загрузке)
do
	local waited = 0
	while not _G.EggTools and waited < 4 do
		task.wait(0.25)
		waited += 0.25
	end
end

local EggsCat = Window:Category("Eggs")
local EggsPage = Window:Page({
		Name = "Eggs",
		Icon = "https://i.postimg.cc/6q7p8GSZ/Bez-imeni-2.png",
		Category = EggsCat
})

local selectedEgg = nil
local selectedAmount = 1

local function getEggItems()
	local tools = _G.EggTools
	return tools and tools.GetEggNames() or {}
end

-- Обновление списка в дропдауне (подбираем метод, который есть у твоей библиотеки)
local function pushItems(dropdown, items)
	for _, method in ipairs({ "Refresh", "SetItems", "SetOptions", "SetValues" }) do
		if type(dropdown[method]) == "function" then
			if pcall(dropdown[method], dropdown, items) then return true end
		end
	end
	return false
end

local EggsSection = EggsPage:Section({Name = "Auto Open", Side = 1, Icon = "https://i.postimg.cc/tCDF4BRx/Bez-imeni-1.png"})

EggsSection:Paragraph({
	Name = "Auto Open Eggs",
	Text = "Pick an egg and an amount, then enable the toggle. Stand near the egg or enable Teleport To Egg."
})

EggsSection:Divider()

local EggDropdown = EggsSection:Dropdown({
	Name = "Egg",
	Tooltip = "Eggs available in the current world",
	Flag = "EggToOpen",
	Items = getEggItems(),
	Multi = false,
	Size = 125,
	OptionHolderSize = 125,
	Callback = function(Value)
		selectedEgg = normalize(Value)[1]
	end
})

local EggAmountDropdown = EggsSection:Dropdown({
	Name = "Amount",
	Tooltip = "How many eggs to open per purchase (3 needs the Triple Egg gamepass)",
	Flag = "EggAmount",
	Items = { "1", "3" },
	Default = "1",
	Multi = false,
	Size = 60,
	OptionHolderSize = 60,
	Callback = function(Value)
		selectedAmount = tonumber(normalize(Value)[1]) or 1
	end
})

local EggOpenToggle = EggsSection:Toggle({
	Name = "Auto Open Eggs",
	Tooltip = "Keeps buying the selected egg",
	Flag = "AutoOpenEggs",
	Default = false,
	Callback = function(Value)
		local tools = _G.EggTools
		if not tools then
			Library:Notification({
				Title = "Eggs",
				Description = "EggsOpen.lua not loaded. Check console (F9)",
				Duration = 4
			})
			return
		end

		if Value then
			if not selectedEgg then
				Library:Notification({
					Title = "Eggs",
					Description = "Select an egg first",
					Duration = 3
				})
				return
			end
			tools.AutoOpen.Stop()
			tools.AutoOpen.Start(selectedEgg, selectedAmount)
		else
			tools.AutoOpen.Stop()
		end
	end
})

EggsSection:Button({
	Name = "Open Once",
	Tooltip = "Buys the selected egg a single time",
	Callback = function()
		local tools = _G.EggTools
		if not tools or not selectedEgg then
			Library:Notification({
				Title = "Eggs",
				Description = "Select an egg first",
				Duration = 3
			})
			return
		end
		task.spawn(function()
			local ok, msg = tools.OpenOnce(selectedEgg, selectedAmount)
			Library:Notification({
				Title = "Eggs",
				Description = ok and "Opened" or tostring(msg or "Failed"),
				Duration = 3
			})
		end)
	end
})

EggsSection:Button({
	Name = "Refresh Egg List",
	Tooltip = "Rescan eggs in the current world",
	Callback = function()
		local tools = _G.EggTools
		if not tools then return end
		task.spawn(function()
			tools.Refresh()
			pushItems(EggDropdown, getEggItems())
		end)
	end
})

local EggsOptionsSection = EggsPage:Section({Name = "Options", Side = 2, Icon = "https://i.postimg.cc/cH8VsKQf/Bez-imeni-1.png"})

EggsOptionsSection:Slider({
	Name = "Open Delay",
	Tooltip = "Pause between purchases. Lower = faster spam",
	Flag = "EggDelay",
	Min = 50,
	Max = 3000,
	Default = 300,
	Suffix = " ms",
	Decimals = 1
})

EggsOptionsSection:Toggle({
	Name = "Teleport To Egg",
	Tooltip = "Teleports you next to the selected egg if you are far from it",
	Flag = "EggTeleport",
	Default = false,
	Callback = function(Value)
		local tools = _G.EggTools
		if tools then tools.AutoOpen.Teleport = Value and true or false end
	end
})

EggsOptionsSection:Toggle({
	Name = "Wait For Hatch Animation",
	Tooltip = "Enable if the server rejects purchases while an egg is opening",
	Flag = "EggWaitAnim",
	Default = false,
	Callback = function(Value)
		local tools = _G.EggTools
		if tools then tools.AutoOpen.WaitAnimation = Value and true or false end
	end
})

-- Подхват значения слайдера + автообновление списка яиц
task.spawn(function()
	local last = table.concat(getEggItems(), "|")
	while true do
		task.wait(3)
		local tools = _G.EggTools
		if tools then
			local ms = tonumber(Library.Flags["EggDelay"]) or 300
			tools.AutoOpen.Delay = math.max(0.05, ms / 1000)
		end
		local items = getEggItems()
		local sig = table.concat(items, "|")
		if sig ~= last then
			last = sig
			pushItems(EggDropdown, items)
		end
	end
end)

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
