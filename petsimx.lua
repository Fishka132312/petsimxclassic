local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----22
local CheatName = "Evade"

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local DEBUG = true -- печатает в F9 что приходит из дропдауна; потом поставь false

local function dprint(...)
	if DEBUG then print("[GUI]", ...) end
end

local scripts = {
  'AutoFarm/AutoCollectOrbsLootBags.lua',
  'AutoFarm/AutoFarm.lua',
  'AutoFarm/FarmStats.lua',
  'Eggs/EggsOpen.lua',
  'Eggs/JustAutoOpen.lua',
  'Auto/AutoGolden.lua',
  'Auto/AutoRainbow.lua',
  'Auto/AutoIndex.lua',
  'Misc/AntiLag.lua',
  'Misc/AntiLag2.lua',
  'Misc/AntiLag3.lua',
  'Misc/AntiLag4.lua',
  'Custom/Teams.lua',
  'Custom/PetChanger.lua',
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

-------------------------Helpers-----------------------

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
		table.sort(list)
		return list
	end
	if type(Value) == "string" and Value ~= "" then
		return { Value }
	end
	return {}
end

-- Обновление списка в дропдауне (подбираем метод, который есть у библиотеки)
local function pushItems(dropdown, items)
	for _, method in ipairs({ "Refresh", "SetItems", "SetOptions", "SetValues" }) do
		if type(dropdown[method]) == "function" then
			if pcall(dropdown[method], dropdown, items) then
				dprint("список обновлён методом", method)
				return true
			end
		end
	end
	dprint("у дропдауна нет метода обновления списка")
	return false
end

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

local function getLocationItems()
	local tools = _G.PetTools
	return tools and tools.CoinManager.GetLocationNames() or {}
end

-- Ждём, пока появятся локации (монеты могут прогрузиться не сразу)
do
	local waited = 0
	while #getLocationItems() == 0 and waited < 15 do
		task.wait(0.5)
		waited += 0.5
	end
	dprint("локаций на старте:", #getLocationItems())
end

local LocationDropdown = AutoFarmSection:Dropdown({
	Name = "Farm Locations",
	Tooltip = "Choose locations for pets farming",
	Flag = "FarmLocations",
	Items = getLocationItems(),
	Multi = true,
	Callback = function(Value)
		if DEBUG then
			dprint("callback:", typeof(Value), Value)
			if type(Value) == "table" then
				for k, v in pairs(Value) do dprint("   ", k, v) end
			end
		end

		selectedLocations = normalize(Value)
		dprint("выбрано:", table.concat(selectedLocations, ", "))

		local tools = _G.PetTools
		if tools and tools.AutoFarm.Enabled and #selectedLocations > 0 then
			tools.AutoFarm.Location = selectedLocations
		end
	end
})

if DEBUG then
	for k, v in pairs(LocationDropdown) do dprint("dropdown:", k, typeof(v)) end
end

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

-- Автообновление списка локаций
task.spawn(function()
	local last = table.concat(getLocationItems(), "|")
	while true do
		task.wait(5)
		local items = getLocationItems()
		local sig = table.concat(items, "|")
		if sig ~= last and #items > 0 then
			last = sig
			pushItems(LocationDropdown, items)
		end
	end
end)

local AutoFarmToggle = AutoFarmSection:Toggle({
    Name = "Auto Collect LootBags/Orbs",
	Tooltip = "Automatically collects Orbs And Lootbags",
    Flag = "AutoCollectOrbsLootbags",
    Default = false,
    Callback = function(Value)
        _G.AutoCollectOrbsLootbags = Value
    end
})

local AutoFarmToggle = AutoFarmSection:Toggle({
    Name = "Stats",
	Tooltip = "Showing stats per hour",
    Flag = "StatsFarm",
    Default = false,
    Callback = function(Value)
        _G.StatsFarm  = Value
    end
})



local ThingsEventSection = EventPage:Section({Name = "Things", Side = 2, icon = "https://i.postimg.cc/cH8VsKQf/Bez-imeni-1.png"})



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

-- Ждём, пока скрипт отсканирует яйца на карте
do
	local waited = 0
	while #getEggItems() == 0 and waited < 10 do
		task.wait(0.5)
		waited += 0.5
	end
	dprint("яиц на старте:", #getEggItems())
end

local EggSection = EggsPage:Section({ Name = "Egg Opener", Side = 1 })

local EggInfo = EggSection:Paragraph({
	Name = "Status",
	Text = "Open any egg manually once so the script learns the remote."
})

EggSection:Divider()

local EggDropdown = EggSection:Dropdown({
	Name = "Egg",
	Tooltip = "Choose the egg to open",
	Flag = "EggSelected",
	Items = getEggItems(),
	Multi = false,
	Callback = function(Value)
		selectedEgg = normalize(Value)[1]
		dprint("яйцо:", tostring(selectedEgg))
		local tools = _G.EggTools
		if tools then tools.AutoOpen.Egg = selectedEgg end
	end
})

EggSection:Dropdown({
	Name = "Amount",
	Tooltip = "How many eggs per purchase",
	Flag = "EggAmount",
	Items = { "1", "3", "8" },
	Default = "1",
	Multi = false,
	Callback = function(Value)
		selectedAmount = tonumber(normalize(Value)[1]) or 1
		local tools = _G.EggTools
		if tools then tools.AutoOpen.Amount = selectedAmount end
	end
})

EggSection:Slider({
	Name = "Delay",
	Tooltip = "Pause between purchases. Do not set too low",
	Flag = "EggDelay",
	Min = 0.05,
	Max = 2,
	Default = 0.3,
	Decimals = 0.05,
	Suffix = " s",
	Callback = function(Value)
		local tools = _G.EggTools
		if tools then tools.AutoOpen.Delay = Value end
	end
})

EggSection:Toggle({
	Name = "Teleport to egg",
	Tooltip = "Teleports to the egg if you are too far away",
	Flag = "EggTeleport",
	Default = false,
	Callback = function(Value)
		local tools = _G.EggTools
		if tools then tools.AutoOpen.Teleport = Value end
	end
})

EggSection:Toggle({
	Name = "Wait animation",
	Tooltip = "Waits for the opening animation before the next purchase",
	Flag = "EggWaitAnim",
	Default = false,
	Callback = function(Value)
		local tools = _G.EggTools
		if tools then tools.AutoOpen.WaitAnimation = Value end
	end
})

local AutoEggToggle
AutoEggToggle = EggSection:Toggle({
	Name = "Auto Open Eggs",
	Tooltip = "Opens the selected egg repeatedly",
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

		local auto = tools.AutoOpen

		if Value then
			local egg = selectedEgg or tools.GetLearnedEgg()
			if not egg then
				Library:Notification({
					Title = "Eggs",
					Description = "Select an egg first",
					Duration = 3
				})
				AutoEggToggle:Set(false)
				return
			end
			auto.Stop()
			auto.Amount = selectedAmount
			auto.Delay = Library.Flags["EggDelay"] or auto.Delay
			auto.Teleport = Library.Flags["EggTeleport"] and true or false
			auto.WaitAnimation = Library.Flags["EggWaitAnim"] and true or false
			auto.Start(egg, selectedAmount)
		else
			auto.Stop()
		end
	end
})

EggSection:Button({
	Name = "Open Once",
	Tooltip = "Buys the selected egg a single time",
	Callback = function()
		local tools = _G.EggTools
		local egg = selectedEgg or (tools and tools.GetLearnedEgg())
		if not tools or not egg then
			Library:Notification({
				Title = "Eggs",
				Description = "Select an egg first",
				Duration = 3
			})
			return
		end
		task.spawn(function()
			local ok, msg = tools.OpenOnce(egg, selectedAmount)
			Library:Notification({
				Title = "Eggs",
				Description = ok and ("Opened: " .. egg) or ("Failed: " .. tostring(msg)),
				Duration = 3
			})
		end)
	end
})

EggSection:Button({
	Name = "Refresh egg list",
	Tooltip = "Rescans eggs on the map",
	Callback = function()
		local tools = _G.EggTools
		if not tools then return end
		task.spawn(function()
			tools.Refresh()
			local items = getEggItems()
			pushItems(EggDropdown, items)
			Library:Notification({
				Title = "Eggs",
				Description = "Found eggs: " .. #items,
				Duration = 3
			})
		end)
	end
})

-- Статус и автообновление списка яиц
task.spawn(function()
	local last = table.concat(getEggItems(), "|")
	local ticks = 0
	while true do
		task.wait(1)
		ticks += 1
		local tools = _G.EggTools
		if tools then
			local learned = tools.GetLearnedEgg()
			local text = learned
				and ("Remote learned (" .. tostring(learned) .. ")")
				or "Remote NOT learned: open any egg manually once"
			if tools.AutoOpen.Enabled then
				text = text .. "\nOpened: " .. tostring(tools.AutoOpen.Opened)
			end
			pcall(function() EggInfo:SetText(text) end)

			-- если авто-открытие остановилось само (ошибки) — снимаем переключатель
			if not tools.AutoOpen.Enabled and Library.Flags["AutoOpenEggs"] then
				pcall(function() AutoEggToggle:Set(false) end)
			end

			if ticks % 5 == 0 then
				local items = getEggItems()
				local sig = table.concat(items, "|")
				if sig ~= last and #items > 0 then
					last = sig
					pushItems(EggDropdown, items)
				end
			end
		end
	end
end)

local EggSection = EggsPage:Section({ Name = "Egg Opener1", Side = 2 })

local AutoOpenToggle = EggSection:Toggle({
    Name = "Just Auto Open",
	Tooltip = "AutoOpenLastEgg",
    Flag = "AutoOpenLastEgg",
    Default = false,
    Callback = function(Value)
        _G.AutoOpenLastEgg  = Value
    end
})

local NoAnimToggle = EggSection:Toggle({
	Name = "No Egg Animation",
	Tooltip = "Opens eggs instantly, without the hatch animation",
	Flag = "NoEggAnimation",
	Default = false,
	Callback = function(Value)
		_G.NoEggAnimation = Value

		if Value then
			local tools = _G.EggTools
			if not tools or not tools.IsNoAnimationReady then
				Library:Notification({
					Title = "Eggs",
					Description = "EggsOpen.lua not loaded. Check console (F9)",
					Duration = 4
				})
			elseif not tools.IsNoAnimationReady() then
				Library:Notification({
					Title = "Eggs",
					Description = "Animation hook is not ready yet or failed. Check console (F9)",
					Duration = 4
				})
			end
		end
	end
})


-------------------------Home Things-----------------------

local AutoCat = Window:Category("Auto")
local AutoPage = Window:Page({
	Name = "Auto",
	Icon = "https://i.postimg.cc/cH8VsKQf/Bez-imeni-1.png",
	Category = AutoCat
})

local CraftSection = AutoPage:Section({ Name = "Crafting", Side = 1 })

local CraftInfo = CraftSection:Paragraph({
	Name = "Status",
	Text = "Do one craft manually for each machine so the script learns the remote."
})

CraftSection:Divider()

local AutoGoldenToggle = CraftSection:Toggle({
	Name = "Auto Golden",
	Tooltip = "Crafts golden pets in the Golden Machine (5-6 same pets)",
	Flag = "AutoGoldenCraft",
	Default = false,
	Callback = function(Value)
		_G.AutoGoldenCraft = Value
	end
})

local AutoRainbowToggle = CraftSection:Toggle({
	Name = "Auto Rainbow",
	Tooltip = "Crafts rainbow pets in the Rainbow Machine (6 same golden pets)",
	Flag = "AutoRainbowCraft",
	Default = false,
	Callback = function(Value)
		_G.AutoRainbowCraft = Value
	end
})

-- Статус Remote + синхронизация тогглов с переменными
-- (переменные могут меняться клавишами Z / X внутри скриптов крафта)
task.spawn(function()
	local genv = (getgenv and getgenv()) or _G
	while true do
		task.wait(1)

		local golden = genv.__AutoGolden
		local rainbow = genv.__AutoRainbow
		local text = "Golden: " .. ((golden and golden.remote) and "remote learned" or "NOT learned")
			.. "\nRainbow: " .. ((rainbow and rainbow.remote) and "remote learned" or "NOT learned")
		pcall(function() CraftInfo:SetText(text) end)

		local g = _G.AutoGoldenCraft and true or false
		if g ~= (Library.Flags["AutoGoldenCraft"] and true or false) then
			pcall(function() AutoGoldenToggle:Set(g) end)
		end

		local r = _G.AutoRainbowCraft and true or false
		if r ~= (Library.Flags["AutoRainbowCraft"] and true or false) then
			pcall(function() AutoRainbowToggle:Set(r) end)
		end
	end
end)

local AutoRainbowToggle = CraftSection:Toggle({
	Name = "Auto Index",
	Tooltip = "Hatching, craftings pets for ur index",
	Flag = "AutoIndex",
	Default = false,
	Callback = function(Value)
		_G.AutoIndexFarm  = Value
	end
})

local AutoRainbowToggle = CraftSection:Toggle({
	Name = "Pets Changer",
	Tooltip = "You can change youre pets to any and open eggs/gifts",
	Flag = "PetsChanger",
	Default = false,
	Callback = function(Value)
		_G.PetsChanger = Value
	end
})

CraftSection:Button({
    Name = "Unlock Hoverboards",
    Callback = function()
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Custom/UnlockAllHoverboard.lua'))()
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
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Misc/AntiAfk.lua'))()
    end
})

local AntiLagToggle = MiscSection:Toggle({
    Name = "AntiLag1",
	Tooltip = "AntiLag1",
    Flag = "AntiLag1",
    Default = false,
    Callback = function(Value)
        _G.AntiLagEnabled = Value
    end
})

local AntiLagToggle = MiscSection:Toggle({
    Name = "AntiLag2",
	Tooltip = "AntiLag2",
    Flag = "AntiLag2",
    Default = false,
    Callback = function(Value)
        _G.AntiLag2Enabled = Value
    end
})

local AntiLagToggle = MiscSection:Toggle({
    Name = "AntiLag3",
	Tooltip = "AntiLag3",
    Flag = "AntiLag3",
    Default = false,
    Callback = function(Value)
        _G.AntiLag3Enabled = Value
    end
})

local AntiLagToggle = MiscSection:Toggle({
    Name = "AntiLag4",
	Tooltip = "AntiLag4",
    Flag = "AntiLag4",
    Default = false,
    Callback = function(Value)
        _G.AntiLag4Enabled = Value
    end
})

local Disable3dRenderToggle = MiscSection:Toggle({
    Name = "Disable 3d Render",
	Tooltip = "Disables world rendering. FPS boost",
    Flag = "Disable3d",
    Default = false,
    Callback = function(Value)
       local RunService = game:GetService("RunService")
        RunService:Set3dRenderingEnabled(not Value)
    end
})

CraftSection:Button({
    Name = "Rejoin",
    Callback = function()
        loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Misc/Rejoin.lua'))()
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

-------------------------Custom-----------------------

local CustomCat = Window:Category("Custom")
local CustomPage = Window:Page({
	Name = "Custom",
	Icon = "https://i.postimg.cc/CxnfNm71/Bez-imeni-1.png",
	Category = CustomCat
})

local CustomSection = CustomPage:Section({ Name = "Teams", Side = 1 })

CustomSection:Paragraph({
	Name = "Pet Teams",
	Text = "Shows the Teams star in your inventory (bottom bar). Turn off to hide it completely."
})

CustomSection:Divider()

local TeamsToggle = CustomSection:Toggle({
	Name = "Teams",
	Tooltip = "Enable / disable Pet Teams in the inventory",
	Flag = "TeamsEnabled",
	Default = false,
	Callback = function(Value)
		local genv = (getgenv and getgenv()) or _G
		genv.TeamsEnabled = Value and true or false
	end
})

-- Синхронизация: если переменную поменяли из консоли - тоггл тоже переключится
task.spawn(function()
	local genv = (getgenv and getgenv()) or _G
	while true do
		task.wait(1)
		local t = genv.TeamsEnabled == true
		if t ~= (Library.Flags["TeamsEnabled"] and true or false) then
			pcall(function() TeamsToggle:Set(t) end)
		end
	end
end)

local SettingsCat = Window:Category("Settings")

local UiPage = Library:CreateUiPage(Window)
table.insert(SettingsCat.Elements, UiPage)
local SettingsPage = Library:CreateSettingsPage(Window, KeybindList)
table.insert(SettingsCat.Elements, SettingsPage)
Window:Init()
