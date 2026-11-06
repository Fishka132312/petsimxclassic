-- PerHourCounter
-- Под каждой валютой в PlayerGui.Main.Right показывает уменьшенную копию с доходом в час.
--
-- Подсчёт идёт ВСЕГДА, с момента запуска скрипта. Переменная только показывает/прячет GUI:
--   _G.StatsFarm = true   -> копии с доходом в час на экране
--   _G.StatsFarm = false  -> копий нет, но подсчёт продолжается
-- Включишь снова: цифры сразу актуальные, счёт не сбрасывается.
--
-- Повторный запуск скрипта останавливает прошлую копию и запускает новую (ничего не накладывается).
-- Новая копия считает с нуля, потому что это новый запуск.
-- Если _G.StatsFarm не задана, при запуске она ставится в true.

local FLAG = "StatsFarm"

local CLEANUP = FLAG .. "_Cleanup"
if _G[CLEANUP] then
	pcall(_G[CLEANUP])
	_G[CLEANUP] = nil
end
if _G[FLAG] == nil then
	_G[FLAG] = true -- запустил скрипт = хочешь видеть статы. Хочешь, чтобы GUI стартовал скрытым — false
end

local function enabled()
	return _G[FLAG] and true or false
end

local Players = game:GetService("Players")

---------------- НАСТРОЙКИ ----------------
local WINDOW      = 300      -- за сколько последних секунд считать среднее (5 мин)
local SCALE_W     = 0.8      -- ширина копии относительно оригинала
local SCALE_H     = 0.75     -- высота копии относительно оригинала
local SUFFIX      = "/h"     -- подпись: "/ч" или "/h"
local IGNORE      = { Rank = true } -- какие фреймы пропускать
-------------------------------------------

local alive = true
local shown = false      -- показан ли сейчас GUI
local conns = {}         -- общие подключения
local tracked = {}       -- [frame] = st (подсчёт + копия)
local right

local function disconnectAll(list)
	for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
	table.clear(list)
end

local function destroyClone(st)
	disconnectAll(st.cloneConns)
	if st.clone then pcall(function() st.clone:Destroy() end) end
	st.clone, st.cAmount = nil, nil
end

-- убрать все копии, в том числе оставшиеся от старой версии скрипта
local function removeAllClones()
	for _, st in pairs(tracked) do destroyClone(st) end
	if right then
		for _, ch in ipairs(right:GetChildren()) do
			if ch:GetAttribute("PerHourClone") then pcall(function() ch:Destroy() end) end
		end
	end
end

-- выгрузка (регистрируем сразу, чтобы повторный запуск мог остановить копию, которая ещё ждёт загрузку GUI)
_G[CLEANUP] = function()
	alive = false
	shown = false
	disconnectAll(conns)
	for _, st in pairs(tracked) do
		disconnectAll(st.conns)
		destroyClone(st)
	end
	table.clear(tracked)
	removeAllClones()
end

local player = Players.LocalPlayer
right = player:WaitForChild("PlayerGui"):WaitForChild("Main"):WaitForChild("Right")
if not alive then return end

local MULT = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, QA = 1e15, QI = 1e18, SX = 1e21, SP = 1e24 }
local SHORT = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function parse(text)
	text = tostring(text):gsub("<[^>]->", ""):gsub("[,%s]", "")
	local num, suf = text:match("^([%d%.]+)(%a*)")
	num = tonumber(num)
	if not num then return nil end
	if suf ~= "" then
		local m = MULT[suf:upper()]
		if m then num *= m end
	end
	return num
end

local function short(n)
	if n < 1000 then return tostring(math.floor(n + 0.5)) end
	local i = 1
	while n >= 1000 and i < #SHORT do n /= 1000; i += 1 end
	local s = n >= 100 and string.format("%.0f", n) or n >= 10 and string.format("%.1f", n) or string.format("%.2f", n)
	if s:find("%.") then
		s = s:gsub("%.?0+$", "") -- нули убираем только после точки ("1.50" -> "1.5", "150" остаётся "150")
	end
	return s .. SHORT[i]
end

-- ================== ПОДСЧЁТ (работает всегда) ==================
local function updateText(st)
	local now = os.clock()
	local sum, i = 0, 1
	while i <= #st.events do
		local e = st.events[i]
		if now - e.t > WINDOW then table.remove(st.events, i) else sum += e.d; i += 1 end
	end
	if not st.cAmount then return end
	local elapsed = math.min(WINDOW, now - st.start)
	if elapsed < 5 then st.cAmount.Text = "..." return end
	st.cAmount.Text = "+" .. short(sum / elapsed * 3600) .. SUFFIX
end

-- ================== GUI (зависит от переменной) ==================
local function makeClone(st)
	if st.clone or not alive then return end
	local frame = st.frame
	if not frame.Parent then return end

	-- 1:1 копия
	local clone = frame:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then d:Destroy() end
	end
	clone.Name = frame.Name .. " PerHour"
	clone:SetAttribute("PerHourClone", true)
	clone.Size = UDim2.new(
		frame.Size.X.Scale * SCALE_W, frame.Size.X.Offset * SCALE_W,
		frame.Size.Y.Scale * SCALE_H, frame.Size.Y.Offset * SCALE_H
	)
	clone.LayoutOrder = frame.LayoutOrder + 1
	clone.Visible = frame.Visible

	-- в копии оставляем только наш текст, все остальные надписи удаляем
	local cAmount = clone:FindFirstChild("Amount")
	if not cAmount then
		clone:Destroy()
		return
	end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			if d ~= cAmount then d:Destroy() end
		end
	end
	cAmount.Visible = true
	cAmount.Text = "..."
	clone.Parent = right

	st.clone, st.cAmount = clone, cAmount
	table.insert(st.cloneConns, frame:GetPropertyChangedSignal("LayoutOrder"):Connect(function()
		clone.LayoutOrder = frame.LayoutOrder + 1
	end))
	table.insert(st.cloneConns, frame:GetPropertyChangedSignal("Visible"):Connect(function()
		clone.Visible = frame.Visible
	end))

	updateText(st) -- сразу показать актуальное значение
end

local function setup(frame)
	if tracked[frame] or IGNORE[frame.Name] or frame:GetAttribute("PerHourClone") then return end
	if not frame:IsA("GuiObject") then return end
	local amount = frame:FindFirstChild("Amount")
	if not (amount and amount:IsA("TextLabel")) then return end

	-- источник числа: видимая надпись с числом в оригинале (или Amount)
	local icon = frame:FindFirstChild("Icon")
	local function readValue()
		for _, d in ipairs(frame:GetDescendants()) do
			if d:IsA("TextLabel") and d.Visible and d ~= amount
				and not (icon and d:IsDescendantOf(icon)) then
				local v = parse(d.Text)
				if v then return v end
			end
		end
		return parse(amount.Text)
	end

	local st = {
		frame = frame, last = readValue(), events = {}, start = os.clock(),
		conns = {}, cloneConns = {},
	}
	tracked[frame] = st

	st.poll = function()
		local v = readValue()
		if not v then return end
		if st.last and v > st.last then
			table.insert(st.events, { t = os.clock(), d = v - st.last })
		end
		st.last = v -- траты (уменьшение) не считаем как минус фарма
	end

	table.insert(st.conns, frame.AncestryChanged:Connect(function(_, parent)
		if parent then return end
		disconnectAll(st.conns)
		destroyClone(st)
		tracked[frame] = nil
	end))

	if shown then makeClone(st) end
end

for _, child in ipairs(right:GetChildren()) do setup(child) end
table.insert(conns, right.ChildAdded:Connect(function(child)
	task.wait(0.1) -- даём игре создать надписи внутри
	if alive then setup(child) end
end))

-- цикл подсчёта: идёт всегда
task.spawn(function()
	local acc = 0
	while alive do
		acc += task.wait(0.2)
		if not alive then break end
		for _, st in pairs(tracked) do st.poll() end
		if acc >= 1 then
			acc = 0
			for _, st in pairs(tracked) do updateText(st) end
		end
	end
end)

-- ================== ПЕРЕКЛЮЧАТЕЛЬ GUI ==================
removeAllClones() -- копии от старой версии скрипта, если остались

task.spawn(function()
	while alive do
		local want = enabled()
		if want and not shown then
			shown = true
			for _, st in pairs(tracked) do makeClone(st) end
		elseif not want and shown then
			shown = false
			removeAllClones()
		end
		task.wait(0.2)
	end
end)

print(("[StatsFarm] загружен, подсчёт идёт. Показать GUI: _G.%s = true, спрятать: _G.%s = false"):format(FLAG, FLAG))
