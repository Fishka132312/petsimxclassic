local RunService = game:GetService("RunService")

local RunId = {}
_G.OrbsRunId = RunId

local Library = require(game.ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
    RunService.Heartbeat:Wait()
end

local Orbs = Library.Things:WaitForChild("Orbs")

if _G.AutoCollectOrbs == nil then
    _G.AutoCollectOrbs = false
end

task.spawn(function()
    while _G.OrbsRunId == RunId do
        task.wait(0.2)

        if _G.AutoCollectOrbs then
            local root = Library.Player.PrimaryPart()
            if root then
                for _, orb in ipairs(Orbs:GetChildren()) do
                    if orb:IsA("BasePart") then
                        orb.CFrame = root.CFrame
                    end
                end
            end
        end
    end
end)
