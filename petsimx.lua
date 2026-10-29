local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Fishka132312/MeowlGui/refs/heads/main/source/library.lua"))() -----2
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

local AutoFarmCat = Window:Category("AutoFarm")
local EventPage = Window:Page({
		Name = "Auto Farm",
		Icon = "https://i.postimg.cc/6q7p8GSZ/Bez-imeni-2.png",
		Category = AutoFarmCat
})

--AutoFarm--
local AutoFarmSection = AutoFarm:Section({Name = "Auto Farm", Side = 1, Icon = "https://i.postimg.cc/tCDF4BRx/Bez-imeni-1.png"})

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

local LocationDropdown = AutoFarmSection:Dropdown({
    Name = "Select Location",
    Tooltip = "Choose location to farm coins",
    Flag = "FarmLocation",
    Items = GetMapLocations(),
    Default = "All",
    Callback = function(Value)
        _G.SelectedLocation = Value
    end
})

AutoFarmSection:Button({
    Name = "Refresh Locations",
    Tooltip = "Update available locations list",
    Callback = function()
        LocationDropdown:Refresh(GetMapLocations(), _G.SelectedLocation or "All")
    end
})

AutoFarmSection:Dropdown({
    Name = "Farm Mode",
    Tooltip = "Select pet distribution mode",
    Flag = "FarmModeSelect",
    Items = {"Aggressive", "Distributed"},
    Default = "Aggressive",
    Callback = function(Value)
        _G.FarmType = Value
    end
})

AutoFarmSection:Toggle({
    Name = "Enable Auto Farm Coins",
    Tooltip = "Sends pets to farm nearest coins on selected location",
    Flag = "AutoFarmCoins",
    Default = false,
    Callback = function(Value)
        _G.AutoFarmCoins = Value
    end
})

AutoFarmSection:Divider()

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
