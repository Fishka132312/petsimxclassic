local env = (getgenv and getgenv()) or _G

-- Повторный запуск: выгружаем прошлую копию (возвращаем оригинальные клики, отключаем свои), чтобы ничего не накладывалось
if env.HoverboardUnload then
	pcall(env.HoverboardUnload)
	env.HoverboardUnload = nil
end

local dead = false
local myConns = {}      -- наши подключения
local disabledConns = {} -- оригинальные подключения игры, которые мы отключили
local hooked = {}

local function unload()
	dead = true
	for _, c in ipairs(myConns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(myConns)
	for _, c in ipairs(disabledConns) do
		pcall(function() c:Enable() end)
	end
	table.clear(disabledConns)
	table.clear(hooked)
	if env.HoverboardUnload == unload then
		env.HoverboardUnload = nil
	end
end
-- регистрируем сразу: если скрипт запустят ещё раз, пока эта копия грузится, она тоже остановится
env.HoverboardUnload = unload

local Library = require(game.ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
	task.wait()
	if dead then return end
end
if dead then return end

local holder = Library.GUI.Hoverboards.Container.Holder

local function EquipLocal(name)
	if not Library.Directory.Hoverboards[name] then
		return
	end
	local save = Library.Save.Get()
	local ok, err = pcall(function()
		save.EquippedHoverboard = name
	end)
	if not ok then
		return
	end
	pcall(function()
		Library.Signal.Fire("Stat Changed", "EquippedHoverboard")
	end)
end

local function HookButton(btn)
	if dead or hooked[btn] or not btn:IsA("GuiButton") then return end
	if not Library.Directory.Hoverboards[btn.Name] then return end
	hooked[btn] = true

	-- отключаем оригинальный клик (он шлёт запрос на сервер) и запоминаем, чтобы вернуть при выгрузке
	for _, conn in ipairs(getconnections(btn.Activated)) do
		conn:Disable()
		disabledConns[#disabledConns + 1] = conn
	end

	-- свой клик: экипировка локально
	myConns[#myConns + 1] = btn.Activated:Connect(function()
		EquipLocal(btn.Name)
	end)
end

for _, child in ipairs(holder:GetChildren()) do
	HookButton(child)
end

-- на случай, если игра пересоздаст кнопки
myConns[#myConns + 1] = holder.ChildAdded:Connect(function(child)
	task.wait()
	HookButton(child)
end)
