local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----33
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
local failedScripts = {}

for i, scriptName in ipairs(scripts) do
    local fullUrl = baseUrl .. scriptName
    
    local success, err = pcall(function()
        local code = game:HttpGet(fullUrl)
        if code then
            loadstring(code)()
        else
            warn("Не удалось получить код для: " .. scriptName)
            table.insert(failedScripts, scriptName)
        end
    end)
    
    if not success then
        warn("Ошибка при загрузке " .. scriptName .. ": " .. tostring(err))
        table.insert(failedScripts, scriptName)
    end
    
    task.wait(0.5)
end

Library.Folders = {
    Directory = CheatName,
    Configs = CheatName .. "/Configs",
    Assets = CheatName .. "/Assets",
}

-- ===== ТЕМА =====
-- Поменяй THEME на: "Neon" | "Ocean" | "Toxic" | "Sunset" | "Rose"
local THEME = "Neon"

local THEMES = {
	Neon   = { Accent = Color3.fromRGB(150, 90, 255),  Gradient = Color3.fromRGB(255, 70, 170) },
	Ocean  = { Accent = Color3.fromRGB(0, 162, 255),   Gradient = Color3.fromRGB(0, 80, 180)   },
	Toxic  = { Accent = Color3.fromRGB(80, 255, 140),  Gradient = Color3.fromRGB(0, 160, 110)  },
	Sunset = { Accent = Color3.fromRGB(255, 150, 50),  Gradient = Color3.fromRGB(235, 50, 90)  },
	Rose   = { Accent = Color3.fromRGB(255, 110, 170), Gradient = Color3.fromRGB(150, 60, 220) },
}

local picked = THEMES[THEME] or THEMES.Neon
local Accent = picked.Accent
local Gradient = picked.Gradient

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
		Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/autofarm.png",
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

local CollectSection = EventPage:Section({ Name = "Collect & Stats", Side = 2, Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/stats.png" })

CollectSection:Paragraph({
	Name = "Collect",
	Text = "Grabs drops around you and shows your farm stats per hour."
})

CollectSection:Divider()

local AutoCollectToggle = CollectSection:Toggle({
	Name = "Auto Collect LootBags/Orbs",
	Tooltip = "Automatically collects orbs and lootbags near you",
	Flag = "AutoCollectOrbsLootbags",
	Default = false,
	Callback = function(Value)
		_G.AutoCollectOrbsLootbags = Value
	end
})

local StatsToggle = CollectSection:Toggle({
	Name = "Stats",
	Tooltip = "Shows farm stats per hour on screen",
	Flag = "StatsFarm",
	Default = false,
	Callback = function(Value)
		_G.StatsFarm = Value
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
	Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/eggs.png",
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

local EggSection = EggsPage:Section({ Name = "Egg Opener", Side = 1 Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/eggs.png" })

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

local QuickSection = EggsPage:Section({ Name = "Quick Open", Side = 2 Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/quick_open.png" })

QuickSection:Paragraph({
	Name = "Quick Open",
	Text = "No setup needed: repeats the last egg you opened."
})

QuickSection:Divider()

local AutoOpenToggle = QuickSection:Toggle({
    Name = "Just Auto Open",
	Tooltip = "Keeps opening the last egg you opened manually",
    Flag = "AutoOpenLastEgg",
    Default = false,
    Callback = function(Value)
        _G.AutoOpenLastEgg  = Value
    end
})

local NoAnimToggle = QuickSection:Toggle({
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
	Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/auto.png",
	Category = AutoCat
})

local CraftSection = AutoPage:Section({ Name = "Crafting", Side = 1 Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/crafting.png" })

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
-- Тоггл меняем ТОЛЬКО если переменную изменил сам скрипт, а не по сравнению с Library.Flags
task.spawn(function()
	local genv = (getgenv and getgenv()) or _G
	local lastG = _G.AutoGoldenCraft and true or false
	local lastR = _G.AutoRainbowCraft and true or false

	while true do
		task.wait(1)

		local golden = genv.__AutoGolden
		local rainbow = genv.__AutoRainbow
		local text = "Golden: " .. ((golden and golden.remote) and "remote learned" or "NOT learned")
			.. "\nRainbow: " .. ((rainbow and rainbow.remote) and "remote learned" or "NOT learned")
		pcall(function() CraftInfo:SetText(text) end)

		local g = _G.AutoGoldenCraft and true or false
		if g ~= lastG then
			lastG = g
			pcall(function() AutoGoldenToggle:Set(g) end)
		end

		local r = _G.AutoRainbowCraft and true or false
		if r ~= lastR then
			lastR = r
			pcall(function() AutoRainbowToggle:Set(r) end)
		end
	end
end)

local IndexSection = AutoPage:Section({ Name = "Index", Side = 2 Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/index.png" })

local IndexInfo = IndexSection:Paragraph({
	Name = "Status",
	Text = "Waiting for AutoIndex.lua..."
})

IndexSection:Divider()

local AutoIndexToggle = IndexSection:Toggle({
	Name = "Auto Index",
	Tooltip = "Hatches and crafts pets to complete your index",
	Flag = "AutoIndex",
	Default = false,
	Callback = function(Value)
		_G.AutoIndexFarm  = Value
	end
})

-- Статус Auto Index: какие Remote нужно выучить (learn) + что скрипт делает сейчас.
-- Данные берём из состояния AutoIndex.lua (getgenv().__IndexFarm2)
local function remoteLearned(r)
	return typeof(r) == "Instance" and r.Parent ~= nil
end

task.spawn(function()
	local genv = (getgenv and getgenv()) or _G
	local lastOn = _G.AutoIndexFarm and true or false

	while true do
		task.wait(1)

		local s = genv.__IndexFarm2
		local lines = {}

		if not s then
			lines[1] = "AutoIndex.lua not loaded. Check console (F9)"
		else
			lines[#lines + 1] = "Now: " .. tostring(s.status or "Idle")

			if type(s.indexProgress) == "function" then
				local ok, cur, total = pcall(s.indexProgress)
				if ok and cur and total then
					lines[#lines + 1] = "Index: " .. cur .. "/" .. total .. " pets"
				end
			end

			local needs = s.needs or {}
			local function row(label, learned, hint)
				lines[#lines + 1] = label .. ": " .. (learned and "learned" or ("NOT learned - " .. hint))
			end

			row("Eggs", remoteLearned(s.eggRemote), "open any egg manually once")
			if needs.delete then
				row("Delete", remoteLearned(s.deleteRemote), "delete one pet manually")
			end
			if needs.golden then
				row("Golden", remoteLearned(s.goldRemote), "do one Golden craft manually")
			end
			if needs.rainbow then
				row("Rainbow", remoteLearned(s.rainbowRemote), "do one Rainbow craft manually")
			end
			if needs.coin then
				row("Coins", remoteLearned(s.coinRF) and remoteLearned(s.coinRE), "click any coin once")
			end
		end

		pcall(function() IndexInfo:SetText(table.concat(lines, "\n")) end)

		-- если фарм остановился сам (клавиша X, движение, конец целей) - выключаем тоггл
		local on = _G.AutoIndexFarm and true or false
		if on ~= lastOn then
			lastOn = on
			pcall(function() AutoIndexToggle:Set(on) end)
		end
	end
end)

-------------------------Misc-----------------------

local GameCat = Window:Category("Game")
local MiscPage = Window:Page({
	Name = "Misc",
	Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/misc.png",
	Category = GameCat
})

--Performance--
local PerfSection = MiscPage:Section({ Name = "Performance", Side = 1, Icon = "https://i.postimg.cc/CxnfNm71/Bez-imeni-1.png" })

PerfSection:Paragraph({
	Name = "Boost FPS",
	Text = "Pick an Anti Lag level and cap your FPS to keep the game smooth."
})

PerfSection:Divider()

PerfSection:Toggle({
	Name = "Anti Lag 1",
	Tooltip = "Lag reduction, level 1",
	Flag = "AntiLag1",
	Default = false,
	Callback = function(Value)
		_G.AntiLagEnabled = Value
	end
})

PerfSection:Toggle({
	Name = "Anti Lag 2",
	Tooltip = "Lag reduction, level 2",
	Flag = "AntiLag2",
	Default = false,
	Callback = function(Value)
		_G.AntiLag2Enabled = Value
	end
})

PerfSection:Toggle({
	Name = "Anti Lag 3",
	Tooltip = "Lag reduction, level 3",
	Flag = "AntiLag3",
	Default = false,
	Callback = function(Value)
		_G.AntiLag3Enabled = Value
	end
})

PerfSection:Toggle({
	Name = "Anti Lag 4",
	Tooltip = "Lag reduction, level 4 (strongest)",
	Flag = "AntiLag4",
	Default = false,
	Callback = function(Value)
		_G.AntiLag4Enabled = Value
	end
})

PerfSection:Toggle({
	Name = "Disable 3D Render",
	Tooltip = "Disables world rendering. Big FPS boost, screen goes black",
	Flag = "Disable3d",
	Default = false,
	Callback = function(Value)
		game:GetService("RunService"):Set3dRenderingEnabled(not Value)
	end
})

PerfSection:Slider({
	Name = "FPS Cap",
	Tooltip = "Frame limit. Press Apply FPS Cap to use it",
	Flag = "FpsCap",
	Min = 25,
	Max = 240,
	Default = 60,
	Suffix = " fps",
	Decimals = 1
})

PerfSection:Button({
	Name = "Apply FPS Cap",
	Tooltip = "Applies the selected FPS cap",
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
				Description = "Your executor doesn't support setfpscap",
				Duration = 4
			})
		end
	end
})

--Utility--
local UtilSection = MiscPage:Section({ Name = "Utility", Side = 2, Icon = "https://i.postimg.cc/CxnfNm71/Bez-imeni-1.png" })

UtilSection:Paragraph({
	Name = "Tools",
	Text = "Handy extras: stay online, reconnect, inspect remotes."
})

UtilSection:Divider()

UtilSection:Button({
	Name = "Anti AFK",
	Tooltip = "Stops the game from kicking you for being idle",
	Callback = function()
		loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Misc/AntiAfk.lua'))()
	end
})

UtilSection:Button({
	Name = "Rejoin",
	Tooltip = "Rejoins the game",
	Callback = function()
		loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Misc/Rejoin.lua'))()
	end
})

UtilSection:Button({
	Name = "Remote Spy",
	Tooltip = "Opens Remote Spy to watch remote calls",
	Callback = function()
		loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/Evade/refs/heads/main/Things/Misc/RemoteSpy.lua'))()
	end
})

-------------------------Custom-----------------------

local CustomCat = Window:Category("Custom")
local CustomPage = Window:Page({
	Name = "Custom",
	Icon = "https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Icons/custom.png",
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
	local last = genv.TeamsEnabled == true
	while true do
		task.wait(1)
		local t = genv.TeamsEnabled == true
		if t ~= last then
			last = t
			pcall(function() TeamsToggle:Set(t) end)
		end
	end
end)

local CustomPetsSection = CustomPage:Section({ Name = "Pets & Unlocks", Side = 2 })

CustomPetsSection:Paragraph({
	Name = "Customize",
	Text = "Change how your pets look and unlock extra items (visual, client-side)."
})

CustomPetsSection:Divider()

local PetsChangerToggle = CustomPetsSection:Toggle({
	Name = "Pets Changer",
	Tooltip = "Change your pets to any other pet, works with eggs and gifts too",
	Flag = "PetsChanger",
	Default = false,
	Callback = function(Value)
		_G.PetsChanger = Value
	end
})

local hoverboardsBusy = false
CustomPetsSection:Button({
	Name = "Unlock Hoverboards",
	Tooltip = "Unlocks all hoverboards on your client",
	Callback = function()
		if hoverboardsBusy then return end
		hoverboardsBusy = true
		task.spawn(function()
			local ok, err = pcall(function()
				loadstring(game:HttpGet('https://raw.githubusercontent.com/Fishka132312/petsimxclassic/refs/heads/main/Things/Custom/UnlockAllHoverboard.lua'))()
			end)
			Library:Notification({
				Title = "Hoverboards",
				Description = ok and "Hoverboards unlocked" or ("Failed: " .. tostring(err)),
				Duration = 3
			})
			task.wait(2)
			hoverboardsBusy = false
		end)
	end
})

local SettingsCat = Window:Category("Settings")

local UiPage = Library:CreateUiPage(Window)
table.insert(SettingsCat.Elements, UiPage)
local SettingsPage = Library:CreateSettingsPage(Window, KeybindList)
table.insert(SettingsCat.Elements, SettingsPage)
Window:Init()

task.defer(function()
	local desc = "All modules loaded"
	if #failedScripts > 0 then
		desc = "Failed to load: " .. table.concat(failedScripts, ", ")
	end
	pcall(function()
		Library:Notification({
			Title = "Pet Sim X",
			Description = desc,
			Duration = 5
		})
	end)
end)
