-- LocalScript: авто-открытие яиц, которые ты открывал вручную.
-- Управление через переменную:
--   _G.AutoOpenLastEgg = true   -- включить
--   _G.AutoOpenLastEgg = false  -- выключить
-- Сначала открой яйцо вручную один раз: скрипт запомнит вызов и будет его повторять.

local env = (getgenv and getgenv()) or _G
local KEY = "__AutoEggLast"            -- новое состояние (старый __AutoEggOpener не трогаем)
local HOOK_KEY = "__AutoEggLastHook"   -- новый хук

local DELAY = 0.4          -- пауза между открытиями (сек), не ставь слишком низко
local MAX_FAILS = 3        -- ошибок вызова подряд -> переменная сбрасывается в false
local MAX_REFUSALS = 10   -- отказов сервера подряд (нет денег и т.д.) -> сброс в false
local STOP_KEY = Enum.KeyCode.X  -- клавиша экстренной остановки
local STOP_ON_MOVE = false -- true = выключать при движении персонажа

-- выключаем предыдущие копии (и этого скрипта, и старой версии)
for _, k in ipairs({ KEY, "__AutoEggOpener" }) do
	local prev = env[k]
	if prev then
		prev.active = false
		prev.running = false
		if prev.thread then pcall(task.cancel, prev.thread) end
		for _, c in ipairs(prev.connections or {}) do pcall(function() c:Disconnect() end) end
	end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
	RunService.Heartbeat:Wait()
end

local state = {
	active = true,
	connections = {},
	thread = nil,
	eggs = Library.Directory.Eggs or {},
	event = nil,
	method = nil,
	args = nil,
}
env[KEY] = state

if _G.AutoOpenLastEgg == nil then
	_G.AutoOpenLastEgg = false
end

local function isMoving()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.MoveDirection.Magnitude > 0.1
end

local function turnOff(reason)
	_G.AutoOpenLastEgg = false
end

-- Главный цикл: работает всегда, но покупает только когда переменная = true
state.thread = task.spawn(function()
	local fails, refusals = 0, 0
	local warnedNoData = false
	local wasOn = false
	local seenArgs = nil

	while state.active do
		-- сообщаем, когда хук поймал вызов (после ручного открытия яйца)
		if state.args ~= seenArgs then
			seenArgs = state.args
		end

		local on = _G.AutoOpenLastEgg and true or false
		wasOn = on

		if not on then
			fails, refusals = 0, 0
			warnedNoData = false
			task.wait(0.1)
		else
			local ev, method, args = state.event, state.method, state.args

			if not (ev and method and args) then
				task.wait(0.25)
			elseif STOP_ON_MOVE and isMoving() then
				turnOff("движение")
			else
				warnedNoData = false

				local res = table.pack(pcall(function()
					return ev[method](ev, table.unpack(args, 1, args.n))
				end))

				local stopReason
				if not res[1] then
					fails += 1
					refusals = 0
					if fails >= MAX_FAILS then stopReason = "ошибки вызова: " .. tostring(res[2]) end
				elseif method == "InvokeServer" and res[2] == false then
					fails = 0
					refusals += 1
					if refusals >= MAX_REFUSALS then stopReason = "сервер отказывает: " .. tostring(res[3]) end
				else
					fails, refusals = 0, 0
				end

				if stopReason then
					turnOff(stopReason)
					fails, refusals = 0, 0
				else
					task.wait(DELAY)
				end
			end
		end
	end
end)

-- Хук ставится один раз за сессию и только запоминает вызов.
-- Ничего не запускает сам: включает/выключает только переменная.
if not env[HOOK_KEY] then
	env[HOOK_KEY] = true

	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()

		if method == "InvokeServer" or method == "FireServer" then
			local s = env[KEY]
			if s and s.active and not checkcaller() then
				local first = ...
				if typeof(first) == "string" and s.eggs[first] then
					s.event = self
					s.method = method
					s.args = table.pack(...)
				end
			end
		end

		return oldNamecall(self, ...)
	end))
end

table.insert(state.connections, UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == STOP_KEY then
		turnOff("клавиша " .. STOP_KEY.Name)
	end
end))
