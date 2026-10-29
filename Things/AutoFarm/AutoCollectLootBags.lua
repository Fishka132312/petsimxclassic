local RunService = game:GetService("RunService")

local RunId = {}
_G.LootBagsRunId = RunId

local Library = require(game.ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
    RunService.Heartbeat:Wait()
end

local Lootbags = Library.Things.Lootbags

if _G.AutoCollectLootBags == nil then
    _G.AutoCollectLootBags = false
end

task.spawn(function()
    while _G.LootBagsRunId == RunId do
        task.wait(0.2)

        if _G.AutoCollectLootBags then
            local root = Library.Player.UpperTorso()
            if root then
                for _, bag in ipairs(Lootbags:GetChildren()) do
                    if bag:IsA("BasePart")
                        and bag:GetAttribute("ReadyForCollection")
                        and not bag:GetAttribute("Collected") then
                        bag.CFrame = root.CFrame
                    end
                end
            end
        end
    end
end)
