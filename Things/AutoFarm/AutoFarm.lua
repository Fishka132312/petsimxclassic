local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- Инициализация глобальных переменных
_G.AutoFarmCoins = false
_G.SelectedLocation = "All"
_G.FarmType = "Aggressive"

-- Подключение библиотеки игры
local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))

-- Функция получения всех имеющихся локаций
function GetMapLocations()
    local locations = {"All"}
    
    local worldMap = Library.WorldCmds and Library.WorldCmds.GetMap and Library.WorldCmds.GetMap()
    if worldMap then
        local areas = worldMap:FindFirstChild("Areas") or worldMap:FindFirstChild("Zones")
        if areas then
            for _, area in ipairs(areas:GetChildren()) do
                table.insert(locations, area.Name)
            end
        end
    end
    
    return locations
end

-- Фоновый процесс фарма
task.spawn(function()
    while true do
        pcall(function()
            if not _G.AutoFarmCoins then return end
            if not Library.WorldCmds or not Library.WorldCmds.HasLoaded() then return end

            local character = LocalPlayer.Character
            if not character or not character.PrimaryPart then return end
            local playerPos = character.PrimaryPart.Position

            local coinsFolder = Library.Things and Library.Things:FindFirstChild("Coins")
            if not coinsFolder then return end

            local validCoins = {}

            -- Перебираем монеты на карте
            for _, coin in ipairs(coinsFolder:GetChildren()) do
                local posPart = coin:FindFirstChild("POS")
                if posPart then
                    local coinArea = coin:GetAttribute("Area") or coin:GetAttribute("Zone") or "Unknown"
                    
                    -- Проверяем совпадение по локации
                    if _G.SelectedLocation == "All" or coinArea == _G.SelectedLocation then
                        local dist = (posPart.Position - playerPos).Magnitude
                        table.insert(validCoins, {
                            instance = coin,
                            distance = dist
                        })
                    end
                end
            end

            if #validCoins == 0 then return end

            -- Сортируем монеты по близости к игроку
            table.sort(validCoins, function(a, b)
                return a.distance < b.distance
            end)

            -- Отправка петов в зависимости от выбранного режима
            if _G.FarmType == "Aggressive" then
                -- Все петы идут на 1 ближайший коин
                Library.Signal.Fire("Group Select Coin", validCoins[1].instance)
            elseif _G.FarmType == "Distributed" then
                -- Петы распределяются по разным ближайшим коинам
                for i = 1, math.min(#validCoins, 10) do
                    Library.Signal.Fire("Select Coin", validCoins[i].instance)
                end
            end
        end)
        
        task.wait(0.35)
    end
end)
