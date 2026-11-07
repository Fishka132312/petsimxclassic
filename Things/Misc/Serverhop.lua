local TS = game:GetService("TeleportService")
local HS = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer

print("PlaceId:", game.PlaceId, "| JobId:", game.JobId)

local tried = {}      -- сервера, куда уже пытались зайти
local busy = false

-- запрос к API (под разные эксплойт-окружения)
local function httpGet(url)
    local req = (syn and syn.request) or http_request or request
    if req then
        local res = req({Url = url, Method = "GET"})
        return res and res.Body
    end
    return game:HttpGet(url)
end

-- получаем список серверов (с пагинацией)
local function getServers()
    local list, cursor = {}, ""
    for _ = 1, 3 do -- максимум 3 страницы по 100 серверов
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s")
            :format(game.PlaceId, cursor ~= "" and ("&cursor=" .. cursor) or "")
        local ok, body = pcall(httpGet, url)
        if not ok or not body then
            warn("Не удалось получить список серверов:", tostring(body))
            break
        end
        local okJson, data = pcall(HS.JSONDecode, HS, body)
        if not okJson or type(data) ~= "table" or not data.data then
            warn("Некорректный ответ API (возможно, rate limit)")
            break
        end
        for _, s in ipairs(data.data) do
            if s.id ~= game.JobId
                and not tried[s.id]
                and s.playing < s.maxPlayers - 1 then -- оставляем запас в 1 слот
                table.insert(list, s)
            end
        end
        cursor = data.nextPageCursor or ""
        if cursor == "" then break end
    end
    return list
end

local function serverHop()
    if busy then return end
    busy = true

    local servers = getServers()
    if #servers == 0 then
        warn("Подходящих серверов не найдено")
        busy = false
        return
    end

    local s = servers[math.random(#servers)]
    tried[s.id] = true
    print(("Телепорт на сервер %s (%d/%d игроков)"):format(s.id, s.playing, s.maxPlayers))

    local ok, err = pcall(function()
        TS:TeleportToPlaceInstance(game.PlaceId, s.id, lp)
    end)
    if not ok then
        warn("ОШИБКА вызова:", tostring(err))
        busy = false
    end
end

TS.TeleportInitFailed:Connect(function(_, result, msg)
    warn("FAILED:", tostring(result), msg)
    busy = false
    task.wait(1)
    serverHop() -- пробуем другой сервер
end)

TS.LocalPlayerArrivedFromTeleport:Connect(function()
    print("прибыл")
end)

serverHop()
