local TS = game:GetService("TeleportService")
local lp = game:GetService("Players").LocalPlayer

print("PlaceId:", game.PlaceId, "| GameId:", game.GameId, "| JobId:", game.JobId)
print("PrivateServerId:", game.PrivateServerId, "| VIP:", game.PrivateServerOwnerId)

TS.TeleportInitFailed:Connect(function(_, result, msg)
    warn("FAILED:", tostring(result), msg)
end)
TS.LocalPlayerArrivedFromTeleport:Connect(function() print("прибыл") end)

local function try(name, fn)
    local ok, err = pcall(fn)
    print(name, ok and "вызван без ошибки" or ("ОШИБКА: " .. tostring(err)))
    task.wait(6) -- если телепорт пошёл, мы уже вылетим из игры
end

try("1) Teleport", function()
    TS:Teleport(game.PlaceId, lp)
end)

try("2) TeleportToPlaceInstance (тот же сервер)", function()
    TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
end)

try("3) TeleportAsync", function()
    local opt = Instance.new("TeleportOptions")
    opt.ServerInstanceId = game.JobId
    TS:TeleportAsync(game.PlaceId, {lp}, opt)
end)
