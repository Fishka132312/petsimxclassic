--[[
	Inventory: Pet Teams  (LocalScript addon)
	- Команды петов: сохранить текущих экипированных, экипировать одним кликом
	- Undo: вернуть предыдущий набор
	- Хоткеи Shift+1..9 (пока открыт инвентарь)
	- Переименование, обновление, удаление (с подтверждением)
	- Сохранение в файл (если executor умеет writefile)
	Повторный запуск сам выгружает старую версию (даже если она ещё грузится) - копии не накладываются.
	Антиспам: CONFIG.Cooldown. Уведомления об экипировке/снятии убраны (остались только ошибки).

	ВКЛ/ВЫКЛ:  getgenv().TeamsEnabled = true / false
	По умолчанию выключено (CONFIG.StartEnabled). Когда выключено - Teams полностью скрыты из инвентаря.
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.InventoryTeamsUnload then
	pcall(env.InventoryTeamsUnload)
	env.InventoryTeamsUnload = nil
end
-- Эта копия "жива", пока dead == false. Заглушка регистрируется СРАЗУ: если запустить скрипт ещё раз,
-- пока эта копия ещё грузится (WaitForChild / Library), она получит dead = true и сама остановится.
local dead = false
env.InventoryTeamsUnload = function()
	dead = true
end

----------------------------------------------------------------------
-- Настройки
----------------------------------------------------------------------
local CONFIG = {
	MaxTeams = 20,
	MaxNameLength = 20,
	-- Где стоит кнопка "Teams":
	--   "BottomBar" - иконка в нижней панели игры (рядом с корзиной/карандашом/замком)
	--   "TopCenter" / "Left" / "Right" - обычная кнопка у рамки (запасной вариант)
	TogglePlacement = "BottomBar",
	-- Звезда в нижней панели. Offset - сдвиг по вертикали (доля высоты кнопки): минус = выше, плюс = ниже.
	-- Если звезда чуть ниже остальных иконок - уменьши (-0.09), если выше - увеличь (-0.04).
	StarOffsetY = -0.07,
	StarSize = 1.1, -- размер звезды относительно кнопки (было 1.28 - слишком крупная)
	StarStroke = 2.6, -- толщина обводки звезды
	-- Размер одной плитки узора на фоне карточек (px). Больше = крупнее узор, меньше = мельче.
	PatternTile = 80,
	-- Если знаешь индекс ремоута "Unequip All" (ReplicatedStorage:GetChildren()[N]) - впиши N сюда, Learn не нужен.
	-- Если nil - скрипт сам ищет ремоут по имени "Unequip All Pets", а если не нашёл - выучишь через Learn.
	UnequipAllIndex = nil,
	-- false = ходим на сервер ТОЛЬКО так же, как сама игра (Library.Network.Invoke "Equip Pet"/"Unequip Pet"/"Unequip All Pets").
	-- Выученные через Learn ремоуты (могут быть не те) игнорируются. true = старое поведение.
	UseLearned = false,
	-- true = экипировка/снятие через НАСТОЯЩИЕ кнопки игры (карточка пета / Unequip All): игра сама шлёт свои ремоуты,
	-- индексы и Learn не нужны. Если не сработало - запасной путь через Library.Network.Invoke.
	UseUI = true,
	-- Антиспам: минимальная пауза между действиями (экипировка / снятие / Undo / сохранить / обновить), секунды.
	Cooldown = 0.7,
	-- Антиспам вкладки Teams: пока идёт анимация входа/выхода, повторные клики по звезде игнорируются (секунды).
	TabCooldown = 0.45,
	-- Стартовое состояние: false = Teams скрыты, пока не включишь getgenv().TeamsEnabled = true
	StartEnabled = false,
}

if env.TeamsEnabled == nil then
	env.TeamsEnabled = CONFIG.StartEnabled
end

-- ОДИН акцент (голубой, как у игры). Всё остальное - нейтральные оттенки того же цвета.
-- Красный - только для опасных действий (Unequip / удалить / ошибки), янтарный - только для предупреждений.
local ACCENT = Color3.fromRGB(59, 177, 252)
local WARN = Color3.fromRGB(255, 200, 100)
local THEME = {
	Panel = Color3.fromRGB(255, 255, 255),
	Card = Color3.fromRGB(207, 232, 255), -- обычная карточка
	CardTop1 = Color3.fromRGB(194, 224, 252), -- сильная команда (чуть насыщеннее)
	CardTop2 = Color3.fromRGB(178, 214, 248), -- самая сильная
	Toast = Color3.fromRGB(19, 48, 57),
	Dark = Color3.fromRGB(19, 48, 57),
	Stroke = Color3.fromRGB(19, 48, 57),
	StrokeTop = Color3.fromRGB(24, 84, 124), -- обводка самой сильной команды
	Accent = ACCENT,
	AccentLight = Color3.fromRGB(165, 224, 255),
	Field = Color3.fromRGB(246, 248, 252), -- поле имени команды (светлое, не синее)
	FieldPlaceholder = Color3.fromRGB(132, 150, 165),
	Soft = Color3.fromRGB(84, 122, 150), -- второстепенные кнопки (Update / X / Undo / Learn)
	IconBlue = Color3.fromRGB(66, 176, 248), -- заливка иконок нижней панели
	IconYellow = Color3.fromRGB(255, 205, 50), -- как у иконок игры, когда режим включён (карандаш / сетка / замок)
	IconStroke = Color3.fromRGB(19, 53, 68), -- обводка иконок нижней панели
	Green = ACCENT, -- совместимость: зелёного больше нет, "успех" = акцент
	Red = Color3.fromRGB(238, 82, 82),
	Orange = WARN, -- совместимость: предупреждения
	Gray = Color3.fromRGB(110, 128, 146),
	White = Color3.new(1, 1, 1),
}

local SOUNDS = {
	Equip = "8863194499",
	Unequip = "8863194418",
	Pop = "7139317934",
	Soft = "7139317909",
	Close = "8951380772",
	Error = "11524408191",
}

local PLACEHOLDER_ICON = "70582157891773"

----------------------------------------------------------------------
-- Библиотека игры
----------------------------------------------------------------------
local okLib, Library = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
end)
if dead then
	return
end
if not okLib or type(Library) ~= "table" then
	warn("[Teams] Не удалось загрузить Library: " .. tostring(Library))
	return
end

do
	local t0 = os.clock()
	while not Library.Loaded do
		task.wait()
		if dead then
			return
		end
		if os.clock() - t0 > 30 then
			warn("[Teams] Library не загрузилась за 30 секунд")
			return
		end
	end
end

local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local invGui = playerGui:WaitForChild("Inventory")
local frame = invGui:WaitForChild("Frame")
local petsRoot = frame:WaitForChild("Main"):WaitForChild("Pets")
if dead then
	return
end

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local teams = {} -- { {name = "", pets = { {uid, id, g, r, sh, img} } } }
local cards = {} -- [team] = { frame, stroke, status, equipBtn, equipLabel, icons }
local previousSet = nil
local lastTeam = nil -- последняя команда, надетая кнопкой
local busy = false
local drawerOpen = false
local conns = {}
local created = {}
local net = {} -- выученные ремоуты: net.equip / net.unequip
local learnStep = nil -- nil | "equip" | "unequip" | "unequipAll"
local learnClickAt = 0
local learnClickConn = nil
local lastActionAt = 0 -- антиспам: когда закончилось/началось последнее действие

local function cooldownOk()
	return os.clock() - lastActionAt >= CONFIG.Cooldown
end

local function track(c)
	if c then
		conns[#conns + 1] = c
	end
	return c
end

----------------------------------------------------------------------
-- Утилиты
----------------------------------------------------------------------
local rng = Random.new()

local function tween(obj, t, style, dir, props)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style, dir), props)
	tw:Play()
	return tw
end

local function playSound(id, pitch, volume)
	task.spawn(function()
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://" .. id
		s.Volume = volume or 0.6
		s.PlaybackSpeed = pitch or rng:NextNumber(0.95, 1.05)
		s.Parent = SoundService
		s:Play()
		Debris:AddItem(s, 5)
	end)
end

local function trim(s)
	return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	if o:IsA("GuiObject") and props.ZIndex == nil and parent and parent:IsA("GuiObject") then
		o.ZIndex = parent.ZIndex + 1
	end
	o.Parent = parent
	return o
end

local function label(parent, props)
	props = table.clone(props)
	local maxSize = props.MaxTextSize or 20
	local noStroke = props.NoStroke
	local strokeThick = props.StrokeThickness or (maxSize >= 16 and 2.6 or 2)
	props.MaxTextSize = nil
	props.NoStroke = nil
	props.StrokeThickness = nil
	local base = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.FredokaOne,
		TextColor3 = THEME.White,
		TextScaled = true,
		Text = "",
	}
	for k, v in pairs(props) do
		base[k] = v
	end
	local l = new("TextLabel", base, parent)
	new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = 6 }, l)
	if not noStroke then
		new("UIStroke", { Color = THEME.Stroke, Thickness = strokeThick }, l)
	end
	return l
end

-- Шаблон: настоящая цветная кнопка из инвентаря игры (Equip Best / Unequip All).
-- Берём у неё рамку, скругление, обводку и градиент, чтобы наши кнопки выглядели один в один.
local btnTemplate = nil
local function getTemplate()
	if btnTemplate == nil then
		btnTemplate = false
		for _, name in ipairs({ "EquipBest", "UnequipAll" }) do
			local o = invGui:FindFirstChild(name, true)
			if o and o:IsA("GuiButton") and o.BackgroundTransparency < 0.5 then
				btnTemplate = o
				break
			end
		end
	end
	return btnTemplate
end

local function cloneStyled(parent, p)
	local tpl = getTemplate()
	if not tpl then
		return nil
	end
	local ok, c = pcall(function()
		local c = tpl:Clone()
		for _, d in ipairs(c:GetChildren()) do
			if not (d:IsA("UICorner") or d:IsA("UIStroke") or d:IsA("UIGradient")) then
				d:Destroy()
			end
		end
		-- у шаблона скругление/обводка могут быть в долях размера -> на маленьких кнопках выглядят криво
		local cr = c:FindFirstChildOfClass("UICorner")
		if cr then
			cr.CornerRadius = UDim.new(0, p.Radius or 8)
		end
		local sk = c:FindFirstChildOfClass("UIStroke")
		if sk then
			sk.Thickness = p.Stroke or 3
			sk.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		end
		c.Name = p.Name or "Button"
		c.Visible = true
		c.AutoButtonColor = false
		c.BorderSizePixel = 0
		c.BackgroundTransparency = 0
		c.BackgroundColor3 = p.Color
		c.Size = p.Size
		c.Position = p.Position or UDim2.new()
		c.AnchorPoint = p.AnchorPoint or Vector2.new()
		c.Rotation = 0
		if c:IsA("TextButton") then
			c.Text = ""
		end
		if not c:FindFirstChildOfClass("UICorner") then
			new("UICorner", { CornerRadius = UDim.new(0, p.Radius or 8) }, c)
		end
		if not c:FindFirstChildOfClass("UIStroke") then
			new("UIStroke", { Color = THEME.Stroke, Thickness = p.Stroke or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, c)
		end
		local g = c:FindFirstChildOfClass("UIGradient")
		if g then
			local ge = p.Grad or 185
			g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(ge, ge, ge))
			g.Rotation = 90
		end
		c.ZIndex = parent.ZIndex + 1
		c.Parent = parent
		return c
	end)
	if ok and c then
		return c
	end
	return nil
end

-- UIScale масштабирует объект ОТНОСИТЕЛЬНО AnchorPoint. Если якорь (1,0) или (0,0) -
-- кнопка при наведении "уезжает" в одну сторону и наезжает на соседей.
-- Пересчитываем позицию так, чтобы якорь был в центре (визуально кнопка на том же месте).
local function centerAnchor(p)
	local a = p.AnchorPoint or Vector2.new()
	local pos = p.Position or UDim2.new()
	local sz = p.Size
	p = table.clone(p)
	p.Position = UDim2.new(
		pos.X.Scale + (0.5 - a.X) * sz.X.Scale, pos.X.Offset + (0.5 - a.X) * sz.X.Offset,
		pos.Y.Scale + (0.5 - a.Y) * sz.Y.Scale, pos.Y.Offset + (0.5 - a.Y) * sz.Y.Offset
	)
	p.AnchorPoint = Vector2.new(0.5, 0.5)
	return p
end

local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.95

local function makeButton(parent, p)
	p = centerAnchor(p)
	local btn = cloneStyled(parent, p)
	if not btn then
		btn = new("TextButton", {
			Name = p.Name or "Button",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = p.Color,
			Size = p.Size,
			Position = p.Position or UDim2.new(),
			AnchorPoint = p.AnchorPoint or Vector2.new(),
		}, parent)
		new("UICorner", { CornerRadius = UDim.new(0, p.Radius or 8) }, btn)
		new("UIStroke", {
			Color = THEME.Stroke,
			Thickness = p.Stroke or 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, btn)
		local ge = p.Grad or 185
		new("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(ge, ge, ge)),
			Rotation = 90,
		}, btn)
	end
	local scale = new("UIScale", { Scale = 1 }, btn)
	local lbl = label(btn, {
		Name = "Label",
		Text = p.Text or "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -6),
		MaxTextSize = p.TextSize or 18,
		StrokeThickness = p.TextStroke,
	})

	local hovered = false
	btn.MouseEnter:Connect(function()
		hovered = true
		tween(scale, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = HOVER_SCALE })
	end)
	btn.MouseLeave:Connect(function()
		hovered = false
		tween(scale, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = 1 })
	end)
	btn.MouseButton1Down:Connect(function()
		tween(scale, 0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = PRESS_SCALE })
	end)
	btn.MouseButton1Up:Connect(function()
		tween(scale, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = hovered and HOVER_SCALE or 1 })
	end)
	return btn, lbl
end

----------------------------------------------------------------------
-- Данные игры
----------------------------------------------------------------------
local function hasEquipped(save, pet)
	local ok, r = pcall(Library.Shared.HasPetEquipped, save, pet)
	return ok and r and true or false
end

local function maxSlots(save)
	if save.InfPetsEnabled then
		return math.huge
	end
	local ok, n = pcall(Library.Shared.GetMaxEquippedSlots, save)
	if ok and type(n) == "number" then
		return n
	end
	return math.huge
end

local function petButton(uid)
	local normal = petsRoot:FindFirstChild("Normal")
	local titanic = petsRoot:FindFirstChild("Titanic")
	return (normal and normal:FindFirstChild(uid)) or (titanic and titanic:FindFirstChild(uid)) or nil
end

local function iconFor(entry)
	local btn = petButton(entry.uid)
	if btn then
		local pi = btn:FindFirstChild("PetIcon")
		if pi and pi:IsA("ImageLabel") and pi.Image ~= "" and not string.find(pi.Image, PLACEHOLDER_ICON, 1, true) then
			return pi.Image
		end
	end
	if entry.img and entry.img ~= "" then
		return entry.img
	end
	local okD, dir = pcall(function()
		return Library.Directory.Pets[entry.id]
	end)
	if okD and dir then
		if entry.g and dir.goldenThumbnail then
			return dir.goldenThumbnail
		end
		return dir.thumbnail or ""
	end
	return ""
end

local function snapshotEquipped()
	local save = Library.Save.Get()
	if not save or type(save.Pets) ~= "table" then
		return nil
	end
	local list = {}
	for _, pet in ipairs(save.Pets) do
		if hasEquipped(save, pet) then
			local entry = {
				uid = pet.uid,
				id = pet.id,
				g = pet.g and true or nil,
				r = pet.r and true or nil,
				sh = pet.sh and true or nil,
			}
			local img = iconFor(entry)
			if img ~= "" then
				entry.img = img
			end
			list[#list + 1] = entry
		end
	end
	return list
end

----------------------------------------------------------------------
-- Ремоуты экипировки (выучиваются через кнопку Learn)
----------------------------------------------------------------------
local UID_MARK = "<<UID>>"

local function mapDeep(v, fn, depth)
	if type(v) == "table" and depth < 5 then
		local c = {}
		for k, x in pairs(v) do
			c[k] = mapDeep(x, fn, depth + 1)
		end
		return c
	end
	return fn(v)
end

local function mapArgs(args, n, fn)
	local out = {}
	for i = 1, n do
		out[i] = mapDeep(args[i], fn, 0)
	end
	return out
end

local function isPlain(v, depth)
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" then
		return true
	end
	if t == "table" and depth < 5 then
		for k, x in pairs(v) do
			if type(k) ~= "string" and type(k) ~= "number" then
				return false
			end
			if not isPlain(x, depth + 1) then
				return false
			end
		end
		return true
	end
	return false
end

local function netForSave()
	local out = {}
	for _, key in ipairs({ "equip", "unequip", "unequipAll" }) do
		local e = net[key]
		if e then
			local good = true
			for i = 1, e.n do
				if e.args[i] == nil or not isPlain(e.args[i], 0) then
					good = false
					break
				end
			end
			if good then
				out[key] = { index = e.index, method = e.method, n = e.n, args = e.args }
			end
		end
	end
	return out
end

local function loadNet(raw)
	if type(raw) ~= "table" then
		return
	end
	for _, key in ipairs({ "equip", "unequip", "unequipAll" }) do
		local e = raw[key]
		if type(e) == "table" and type(e.index) == "number" and type(e.n) == "number"
			and type(e.args) == "table" and (e.method == "FireServer" or e.method == "InvokeServer") then
			net[key] = { index = e.index, method = e.method, n = e.n, args = e.args }
		end
	end
end

local onNetStale -- задаётся ниже (UI)
local function staleEntry(entry)
	for k, e in pairs(net) do
		if e == entry then
			net[k] = nil
		end
	end
	if onNetStale then
		task.defer(onNetStale)
	end
end

local function resolveRemote(entry)
	local r = entry.remote
	if r and r.Parent == ReplicatedStorage then
		return r
	end
	local cand = ReplicatedStorage:GetChildren()[entry.index]
	if cand and (cand:IsA("RemoteEvent") or cand:IsA("RemoteFunction")) then
		entry.remote = cand
		return cand
	end
	return nil
end

-- возвращает то же, что pcall: ok, результат...
local function callNet(entry, uid)
	local remote = resolveRemote(entry)
	if not remote then
		staleEntry(entry)
		return false, ("remote [%d] not found - press Learn"):format(entry.index)
	end
	local args = mapArgs(entry.args, entry.n, function(v)
		if v == UID_MARK then
			return uid
		end
		return v
	end)
	if entry.method == "InvokeServer" and remote:IsA("RemoteFunction") then
		return pcall(remote.InvokeServer, remote, table.unpack(args, 1, entry.n))
	elseif entry.method == "FireServer" and remote:IsA("RemoteEvent") then
		return pcall(remote.FireServer, remote, table.unpack(args, 1, entry.n))
	end
	staleEntry(entry)
	return false, "remote type changed - press Learn"
end

-- ищем ремоут "Unequip All" без Learn: по индексу из CONFIG или по имени
local function detectUnequipAll()
	if net.unequipAll then
		return false
	end
	local kids = ReplicatedStorage:GetChildren()
	local r
	if type(CONFIG.UnequipAllIndex) == "number" then
		r = kids[CONFIG.UnequipAllIndex]
	end
	if not r then
		for _, c in ipairs(kids) do
			if c:IsA("RemoteFunction") or c:IsA("RemoteEvent") then
				local n = (string.lower(c.Name):gsub("[^%a]", ""))
				if n == "unequipallpets" then
					r = c
					break
				end
			end
		end
	end
	if r and (r:IsA("RemoteFunction") or r:IsA("RemoteEvent")) then
		net.unequipAll = {
			index = table.find(kids, r),
			method = r:IsA("RemoteFunction") and "InvokeServer" or "FireServer",
			n = 0,
			args = {},
			remote = r,
		}
		return true
	end
	return false
end

----------------------------------------------------------------------
-- Экипировка / снятие (общие функции)
----------------------------------------------------------------------
local function isEq(uid)
	local sv = Library.Save.Get()
	if sv and type(sv.Pets) == "table" then
		for _, p in ipairs(sv.Pets) do
			if p.uid == uid then
				return hasEquipped(sv, p)
			end
		end
	end
	return false
end

local function equippedUids()
	local sv = Library.Save.Get()
	local list = {}
	if sv and type(sv.Pets) == "table" then
		for _, p in ipairs(sv.Pets) do
			if hasEquipped(sv, p) then
				list[#list + 1] = p.uid
			end
		end
	end
	return list
end

local function anyEquipped(list)
	for _, uid in ipairs(list) do
		if isEq(uid) then
			return true
		end
	end
	return false
end

-- ждём, пока условие станет true (данные сейва приходят с сервера с задержкой)
local function waitUntil(fn, timeout)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if dead then
			return false
		end
		if fn() then
			return true
		end
		task.wait(0.05)
	end
	return fn()
end

local function stillEquipped(list)
	local out = {}
	for _, uid in ipairs(list) do
		if isEq(uid) then
			out[#out + 1] = uid
		end
	end
	return out
end


----------------------------------------------------------------------
-- Экипировка через настоящий UI игры (игра сама шлёт свои ремоуты - Learn не нужен)
----------------------------------------------------------------------
local function fireButton(btn, variant)
	if not btn then
		return false
	end
	local order = variant % 2 == 1 and { "firesignal", "getconnections" } or { "getconnections", "firesignal" }
	for _, how in ipairs(order) do
		if how == "firesignal" and type(firesignal) == "function" then
			if pcall(firesignal, btn.Activated) then
				return true
			end
		elseif how == "getconnections" and type(getconnections) == "function" then
			local ok, conns = pcall(getconnections, btn.Activated)
			if ok and type(conns) == "table" and #conns > 0 then
				for _, c in ipairs(conns) do
					pcall(function()
						c:Fire()
					end)
				end
				return true
			end
		end
	end
	return false
end

local function findPetCard(uid)
	local c = petsRoot:FindFirstChild(uid, true)
	if c and c:IsA("GuiButton") then
		return c
	end
	return nil
end

local function findUnequipAllButton()
	local bottom = frame:FindFirstChild("Bottom")
	local b = bottom and bottom:FindFirstChild("UnequipAll")
	if b and b:IsA("GuiButton") then
		return b
	end
	for _, d in ipairs(invGui:GetDescendants()) do
		if d.Name == "UnequipAll" and d:IsA("GuiButton") and d.Parent and d.Parent.Name == "Bottom" then
			return d
		end
	end
	return nil
end

-- один пет: жмём его карточку как игрок. true только если сейв реально поменялся
local function uiTogglePet(uid, equip)
	if CONFIG.UseUI == false then
		return false
	end
	local card = findPetCard(uid)
	if not card then
		return false
	end
	for attempt = 1, 3 do
		if isEq(uid) == equip then
			return true
		end
		if not fireButton(card, attempt) then
			return false
		end
		if waitUntil(function()
			return isEq(uid) == equip
		end, 1.5) then
			task.wait(0.1) -- даём игре освободить свой busy-флаг
			return true
		end
	end
	return isEq(uid) == equip
end

local function uiUnequipAll()
	if CONFIG.UseUI == false then
		return false
	end
	return fireButton(findUnequipAllButton(), 1)
end

-- один пет: вызов сервера как в самой игре + повторы (сервер режет слишком частые запросы).
-- Успех засчитываем ТОЛЬКО когда сервер ответил true или сейв реально поменялся,
-- иначе раньше LocalEquipPet "рисовал" пета надетым, хотя сервер его не надел.
local function petCall(uid, equip)
	if isEq(uid) == equip then
		return true
	end
	if uiTogglePet(uid, equip) then
		return true
	end
	local entry = CONFIG.UseLearned and net[equip and "equip" or "unequip"] or nil
	local name = equip and "Equip Pet" or "Unequip Pet"
	local lastMsg
	for attempt = 1, 4 do
		local okI, res, msg
		if entry then
			okI, res, msg = callNet(entry, uid)
		else
			okI, res, msg = pcall(Library.Network.Invoke, name, uid)
		end
		if okI and res == true then
			-- как в игре: сервер подтвердил - обновляем локально
			pcall(Library.PetCmds.LocalEquipPet, LocalPlayer, uid, equip)
			return true
		end
		-- FireServer / непонятный ответ: ждём подтверждения от сервера через сейв
		if okI and res ~= false and waitUntil(function()
			return isEq(uid) == equip
		end, 1) then
			return true
		end
		lastMsg = okI and msg or res
		if type(lastMsg) ~= "string" then
			lastMsg = nil
		end
		local via = entry and ("learned [%d] %s"):format(entry.index, entry.method) or "Library.Network.Invoke (NOT learned)"
		warn(("[Teams] %s %s via %s (попытка %d): ok=%s res=%s msg=%s"):format(
			name, tostring(uid), via, attempt, tostring(okI), tostring(res), tostring(msg)))
		task.wait(0.15 * attempt)
		if isEq(uid) == equip then
			return true
		end
	end
	return false, lastMsg
end

-- Снять петов из list (по умолчанию - всех экипированных).
-- Сначала "Unequip All" одним запросом, ПРОВЕРЯЕМ что петы реально сняты, остаток - по одному.
-- Возвращает: сколько не удалось снять, текст ошибки
local function unequipPets(list)
	list = list or equippedUids()
	if #list == 0 then
		return 0
	end
	local entry = CONFIG.UseLearned and net.unequipAll or nil
	local function allOff()
		return not anyEquipped(list)
	end
	-- 1) настоящая кнопка Unequip All из инвентаря игры
	for _ = 1, 2 do
		if uiUnequipAll() and waitUntil(allOff, 3) then
			return 0
		end
		if allOff() then
			return 0
		end
		task.wait(0.3)
	end
	if entry then
		for attempt = 1, 2 do
			local okI, res = callNet(entry)
			if okI and res ~= false and waitUntil(allOff, 2.5) then
				return 0
			end
			warn(("[Teams] Unequip All [%d] (попытка %d): ok=%s res=%s, ещё надето: %d"):format(
				entry.index, attempt, tostring(okI), tostring(res), #stillEquipped(list)))
			if allOff() then
				return 0
			end
			task.wait(0.2 * attempt)
		end
	else
		-- как в самой игре
		local okI, res = pcall(Library.Network.Invoke, "Unequip All Pets")
		if okI and res and waitUntil(allOff, 2.5) then
			return 0
		end
	end
	-- запасной путь: снимаем по одному только тех, кто ещё надет
	local failed, lastErr = 0, nil
	for _, uid in ipairs(stillEquipped(list)) do
		local okR, msg = petCall(uid, false)
		if not okR then
			failed += 1
			lastErr = msg or lastErr
		end
		task.wait(0.08)
	end
	waitUntil(allOff, 1.5)
	-- финальная проверка по реальному состоянию сейва
	failed = math.max(failed, #stillEquipped(list))
	return failed, lastErr
end

----------------------------------------------------------------------
-- Сохранение в файл
----------------------------------------------------------------------
local canFS = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local fileName = ("InventoryTeams_%d.json"):format(LocalPlayer.UserId)

local function saveTeams()
	if not canFS then
		return
	end
	pcall(function()
		writefile(fileName, HttpService:JSONEncode({ version = 2, teams = teams, net = netForSave() }))
	end)
end

local function loadTeams()
	if not canFS then
		return
	end
	local ok, raw = pcall(function()
		if isfile(fileName) then
			return readfile(fileName)
		end
		return nil
	end)
	if not ok or type(raw) ~= "string" or raw == "" then
		return
	end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if ok2 and type(data) == "table" then
		loadNet(data.net)
	end
	if not ok2 or type(data) ~= "table" or type(data.teams) ~= "table" then
		return
	end
	for _, t in ipairs(data.teams) do
		if type(t) == "table" and type(t.pets) == "table" and #teams < CONFIG.MaxTeams then
			local pets = {}
			for _, p in ipairs(t.pets) do
				if type(p) == "table" and type(p.uid) == "string" then
					pets[#pets + 1] = {
						uid = p.uid,
						id = p.id,
						g = p.g and true or nil,
						r = p.r and true or nil,
						sh = p.sh and true or nil,
						img = type(p.img) == "string" and p.img or nil,
					}
				end
			end
			teams[#teams + 1] = {
				name = trim(tostring(t.name or "Team")):sub(1, CONFIG.MaxNameLength),
				pets = pets,
			}
		end
	end
end

----------------------------------------------------------------------
-- UI: тост (всплывающее уведомление)
----------------------------------------------------------------------
local toastGroup, toastLabel
local toastToken = 0

local function toast(text, color, sticky)
	if not toastGroup or not toastGroup.Parent then
		return
	end
	toastToken += 1
	local tok = toastToken
	toastLabel.Text = text
	toastLabel.TextColor3 = color or THEME.White
	toastGroup.Visible = true
	toastGroup.Position = UDim2.new(0.5, 0, 0, 2)
	toastGroup.GroupTransparency = 1
	tween(toastGroup, 0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out, {
		Position = UDim2.new(0.5, 0, 0, 14),
		GroupTransparency = 0,
	})
	task.delay(2.4, function()
		if sticky or tok ~= toastToken or not toastGroup.Parent then
			return
		end
		tween(toastGroup, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
			Position = UDim2.new(0.5, 0, 0, 2),
			GroupTransparency = 1,
		})
		task.delay(0.32, function()
			if tok == toastToken and toastGroup.Parent then
				toastGroup.Visible = false
			end
		end)
	end)
end

----------------------------------------------------------------------
-- Логика экипировки
----------------------------------------------------------------------
local updateStates -- forward
local needLearnHint -- forward (задаётся ниже)

local function applyUids(wantedIn, title, team)
	if busy then
		return
	end
	local save = Library.Save.Get()
	if not save or type(save.Pets) ~= "table" then
		toast("Save data is not loaded yet.", THEME.Red)
		playSound(SOUNDS.Error)
		return
	end
	busy = true
	task.spawn(function()
		local ok, err = pcall(function()
			local owned = {}
			for _, pet in ipairs(save.Pets) do
				owned[pet.uid] = true
			end

			local unique, seen, missing = {}, {}, 0
			for _, uid in ipairs(wantedIn) do
				if not seen[uid] then
					seen[uid] = true
					if owned[uid] then
						unique[#unique + 1] = uid
					else
						missing += 1
					end
				end
			end

			local cap = maxSlots(save)
			local wanted, wantedSet = {}, {}
			for _, uid in ipairs(unique) do
				if #wanted < cap then
					wanted[#wanted + 1] = uid
					wantedSet[uid] = true
				end
			end
			local trimmed = #unique - #wanted

			local current, curSet = {}, {}
			for _, pet in ipairs(save.Pets) do
				if hasEquipped(save, pet) then
					current[#current + 1] = pet.uid
					curSet[pet.uid] = true
				end
			end

			local same = (#current == #wanted)
			if same then
				for _, uid in ipairs(wanted) do
					if not curSet[uid] then
						same = false
						break
					end
				end
			end
			if same then
				return
			end

			previousSet = current
			lastTeam = team

			local failed, lastErr = 0, nil

			local failedU = 0

			-- 1) сначала снимаем текущую команду
			local extras = {}
			for _, uid in ipairs(current) do
				if not wantedSet[uid] then
					extras[#extras + 1] = uid
				end
			end
			if #extras > 0 then
				-- есть Unequip All: снимаем всех разом (нужных наденем заново), иначе только лишних
				local f, msg = unequipPets((net.unequipAll or not CONFIG.UseLearned) and current or extras)
				failedU += f
				lastErr = msg or lastErr
			end

			-- 2) надеваем нужных (2 прохода: сейв с сервера может прийти позже и "снять" пета обратно)
			for pass = 1, 2 do
				if dead then
					return
				end
				failed = 0
				for _, uid in ipairs(wanted) do
					if not isEq(uid) then
						local okR, msg = petCall(uid, true)
						if not okR then
							failed += 1
							lastErr = msg or lastErr
						end
						task.wait(0.06)
					end
				end
				-- ждём, пока сейв подтвердит итог
				local done = waitUntil(function()
					for _, uid in ipairs(wanted) do
						if not isEq(uid) then
							return false
						end
					end
					return true
				end, 1)
				if done then
					failed = 0
					break
				end
			end
			-- реальный итог по сейву, а не по ответам ремоутов
			failed = 0
			for _, uid in ipairs(wanted) do
				if not isEq(uid) then
					failed += 1
				end
			end
			failedU = 0
			for _, uid in ipairs(extras) do
				if isEq(uid) then
					failedU += 1
				end
			end

			-- уведомление "надел/снял" убрано: показываем только ошибки
			if failed > 0 or failedU > 0 then
				local parts = {}
				if failedU > 0 then
					parts[#parts + 1] = ("%d not removed"):format(failedU)
				end
				if failed > 0 then
					parts[#parts + 1] = ("%d failed"):format(failed)
				end
				local text = title .. ": " .. table.concat(parts, " · ")
				if failed > 0 and needLearnHint and needLearnHint() then
					text ..= " · press Learn"
				end
				if type(lastErr) == "string" then
					text ..= " (" .. lastErr .. ")"
				end
				toast(text, THEME.Red)
				playSound(SOUNDS.Error)
			else
				playSound(SOUNDS.Equip)
			end
		end)
		busy = false
		lastActionAt = os.clock()
		if not ok then
			warn("[Teams] Ошибка экипировки: " .. tostring(err))
			toast("Something went wrong. Try again!", THEME.Red)
		end
		if updateStates then
			updateStates()
		end
	end)
end

local function equipTeam(team)
	local uids = {}
	for _, e in ipairs(team.pets) do
		uids[#uids + 1] = e.uid
	end
	applyUids(uids, team.name, team)
end

-- какая команда считается надетой: надеты РОВНО её петы (те, что есть в инвентаре и влезают в слоты),
-- без лишних. Раньше хватало "все петы команды надеты" - и после Equip Best (где они тоже есть)
-- команда ложно показывалась надетой, а кнопка снимала всех. При нескольких совпадениях - последняя надетая.
local function activeTeams()
	local res = {}
	local sv = Library.Save.Get()
	if not sv or type(sv.Pets) ~= "table" then
		return res
	end
	local owned, eq, eqCount = {}, {}, 0
	for _, pet in ipairs(sv.Pets) do
		owned[pet.uid] = true
		if hasEquipped(sv, pet) then
			eq[pet.uid] = true
			eqCount += 1
		end
	end
	if eqCount == 0 then
		return res
	end
	local cap = maxSlots(sv)
	local pick
	for _, team in ipairs(teams) do
		local expected, seen, n = 0, {}, 0
		local ok = true
		for _, e in ipairs(team.pets) do
			if owned[e.uid] and not seen[e.uid] and n < cap then
				seen[e.uid] = true
				n += 1
				if not eq[e.uid] then
					ok = false
					break
				end
			end
		end
		expected = n
		if ok and expected > 0 and expected == eqCount then
			if team == lastTeam then
				pick = team
				break
			end
			pick = pick or team
		end
	end
	if pick then
		res[pick] = true
	end
	return res
end

-- экипирована ли сейчас эта команда
local function teamActive(team)
	return activeTeams()[team] == true
end

-- кнопка "Unequip": сразу снимает ВСЕХ надетых петов
local function unequipEverything()
	if busy then
		return
	end
	local cur = equippedUids()
	if #cur == 0 then
		return
	end
	busy = true
	task.spawn(function()
		local failed, lastErr = 0, nil
		local ok, err = pcall(function()
			previousSet = cur
			failed, lastErr = unequipPets(cur)
			if failed == 0 then
				lastTeam = nil
			end
			if failed > 0 then
				local text = ("Unequip failed (%d)"):format(failed)
				if needLearnHint and needLearnHint() then
					text ..= " · press Learn"
				end
				if type(lastErr) == "string" then
					text ..= " (" .. lastErr .. ")"
				end
				toast(text, THEME.Red)
				playSound(SOUNDS.Error)
			else
				playSound(SOUNDS.Unequip)
			end
		end)
		busy = false
		lastActionAt = os.clock()
		if not ok then
			warn("[Teams] Ошибка снятия: " .. tostring(err))
			toast("Something went wrong. Try again!", THEME.Red)
		end
		if updateStates then
			updateStates()
		end
	end)
end

local function toggleTeam(team)
	if busy or not cooldownOk() then
		return
	end
	if teamActive(team) then
		unequipEverything()
	else
		equipTeam(team)
	end
end

local function undoEquip()
	if busy or not cooldownOk() then
		return
	end
	if not previousSet then
		playSound(SOUNDS.Error)
		return
	end
	applyUids(previousSet, "Previous pets", nil)
end

----------------------------------------------------------------------
-- UI: основа
----------------------------------------------------------------------
local drawer, list, emptyLabel, subLabel, activeLabel
local toggleBtn, toggleLabel, toggleStar
local restoreFns = {}
local learnBtn, learnLbl
needLearnHint = function()
	return learnBtn ~= nil and learnBtn.Parent ~= nil and learnBtn.Visible
end
local refreshLearnBtn
local rebuild

-- пока открыты Teams: прячем сетку петов и меняем заголовок "Your Pets"
local hiddenGui = {}
local mainWrap = nil -- { group, main, pos, size } пока Main в обёртке
local titleObj, titleOldText, titleNewText
local amountObj, amountOld, amountNew

local function findTitle()
	for _, d in ipairs(invGui:GetDescendants()) do
		if d:IsA("TextLabel") and not (drawer and d:IsDescendantOf(drawer)) then
			local t = string.lower(d.Text):gsub("[^%a]", "")
			if t == "yourpets" or string.lower(d.Name) == "yourpets" then
				return d
			end
		end
	end
	return nil
end

-- deferMain: сетку петов игры не прячем мгновенно - её плавно гасит обёртка (см. wrapMain), прячем после анимации
local function setUnderlying(hide, deferMain)
	if hide then
		local main = frame:FindFirstChild("Main") or (mainWrap and mainWrap.main)
		if main and main:IsA("GuiObject") and hiddenGui[main] == nil then
			hiddenGui[main] = main.Visible
			main:SetAttribute("TeamsHidden", true)
			if not deferMain then
				main.Visible = false
			end
		end
		if not titleObj then
			titleObj = findTitle()
			if titleObj then
				titleOldText = titleObj.Text
				titleNewText = (titleOldText:gsub("[Pp]ets", "Teams"))
				titleObj:SetAttribute("TeamsOrigText", titleOldText)
				titleObj.Text = titleNewText -- текст меняется сразу, без анимации
			end
		end
		if not amountObj then
			local o = invGui:FindFirstChild("PetAmount", true)
			if o and o:IsA("TextLabel") then
				amountObj, amountOld = o, o.Text
				amountNew = ("%d/%d Teams"):format(#teams, CONFIG.MaxTeams)
				o:SetAttribute("TeamsOrigText", amountOld)
				o.Text = amountNew
			end
		end
	else
		for obj, vis in pairs(hiddenGui) do
			if obj.Parent then
				obj.Visible = vis
				obj:SetAttribute("TeamsHidden", nil)
			end
			hiddenGui[obj] = nil
		end
		if titleObj then
			if titleObj.Parent and titleObj.Text == titleNewText then
				titleObj.Text = titleOldText
			end
			if titleObj.Parent then
				titleObj:SetAttribute("TeamsOrigText", nil)
			end
			titleObj, titleOldText = nil, nil
		end
		if amountObj then
			if amountObj.Parent and amountObj.Text == amountNew then
				amountObj.Text = amountOld
			end
			if amountObj.Parent then
				amountObj:SetAttribute("TeamsOrigText", nil)
			end
			amountObj, amountOld = nil, nil
		end
	end
end

-- Обёртка для плавного исчезновения сетки петов игры.
-- Frame.Main нельзя "погасить" одним свойством, поэтому на время анимации кладём его в CanvasGroup и гасим группу:
-- тогда плавно уходят ВСЕ элементы сразу (петы, обводки, скругления). После анимации Main возвращается на место.
-- Группа чуть больше Main (WRAP_MARGIN), чтобы ничего не обрезалось по краям (например, полоса прокрутки).
local WRAP_MARGIN = 30

local function unwrapMain()
	local w = mainWrap
	if not w then
		return
	end
	mainWrap = nil
	local m = w.main
	if m and m.Parent == w.group then
		m.Position, m.Size = w.pos, w.size
		m.Parent = frame
	end
	if w.group then
		w.group:Destroy()
	end
end

local function wrapMain(startAlpha)
	if mainWrap and mainWrap.group.Parent then
		return mainWrap.group
	end
	local main = frame:FindFirstChild("Main")
	if not (main and main:IsA("GuiObject")) then
		return nil
	end
	local abs = main.AbsoluteSize
	if abs.X < 1 or abs.Y < 1 then
		return nil
	end
	local M = WRAP_MARGIN
	local g = Instance.new("CanvasGroup")
	g.Name = "TeamsMainFade"
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.ZIndex = main.ZIndex
	g.GroupTransparency = startAlpha
	local op, os = main.Position, main.Size
	g.Position = UDim2.new(op.X.Scale, op.X.Offset - M, op.Y.Scale, op.Y.Offset - M)
	g.Size = UDim2.fromOffset(abs.X + 2 * M, abs.Y + 2 * M)
	g.Parent = frame
	mainWrap = { group = g, main = main, pos = op, size = os }
	main.Position = UDim2.fromOffset(M, M)
	main.Size = UDim2.fromOffset(abs.X, abs.Y)
	main.Parent = g
	return g
end

-- Панель шире рамки на SCROLL_EXTRA (как Pets у игры: Size = (1, 22, 1, 0)), центр сдвинут на половину
local SCROLL_EXTRA = 14
local openPos = UDim2.new(0.5, SCROLL_EXTRA / 2, 0.5, 0)
local closedPos = UDim2.new(0.5, SCROLL_EXTRA / 2, 0.5, 28)
local drawerToken = 0
local drawerLockUntil = 0 -- антиспам вкладки: до этого момента клики по звезде игнорируются

local function hideMainNow()
	for obj in pairs(hiddenGui) do
		if obj.Parent then
			obj.Visible = false
		end
	end
end

local function setDrawer(open, instant)
	if drawerOpen == open and not instant then
		return
	end
	drawerOpen = open
	drawerToken += 1
	setUnderlying(open, true)
	if toggleStar then
		toggleStar.TextColor3 = open and THEME.IconYellow or THEME.IconBlue
	elseif toggleBtn then
		toggleBtn.BackgroundColor3 = open and THEME.AccentLight or THEME.Accent
	end
	-- Без анимации: и открытие, и закрытие мгновенные
	unwrapMain()
	if open then
		drawer.Visible = true
		drawer.Position = openPos
		drawer.GroupTransparency = 0
		hideMainNow()
		if updateStates then
			updateStates()
		end
	else
		drawer.Visible = false
		drawer.GroupTransparency = 1
		drawer.Position = closedPos
		drawerLockUntil = 0
	end
end

local function uniqueName()
	local n = #teams + 1
	while true do
		local name = "Team " .. n
		local clash = false
		for _, t in ipairs(teams) do
			if t.name == name then
				clash = true
				break
			end
		end
		if not clash then
			return name
		end
		n += 1
	end
end

local function saveEquippedAsTeam()
	if not cooldownOk() then
		return
	end
	lastActionAt = os.clock()
	local snap = snapshotEquipped()
	if not snap then
		toast("Save data is not loaded yet.", THEME.Red)
		playSound(SOUNDS.Error)
		return
	end
	if #snap == 0 then
		toast("Equip some pets first!", THEME.Orange)
		playSound(SOUNDS.Error)
		return
	end
	if #teams >= CONFIG.MaxTeams then
		toast(("You can have up to %d teams"):format(CONFIG.MaxTeams), THEME.Orange)
		playSound(SOUNDS.Error)
		return
	end
	table.insert(teams, { name = uniqueName(), pets = snap })
	saveTeams()
	rebuild(#teams, false)
	playSound(SOUNDS.Pop)
	task.spawn(function()
		task.wait()
		task.wait()
		if list and list.Parent then
			list.CanvasPosition = Vector2.new(0, 1e6)
		end
	end)
end

----------------------------------------------------------------------
-- Обучение: ловим ремоуты экипировки / снятия
----------------------------------------------------------------------
local canHook = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function"
	and type(checkcaller) == "function"
local hookState = env.InventoryTeamsHook
local learnToken = 0

local function ensureHook()
	if not canHook then
		return false
	end
	if not hookState then
		hookState = {}
		env.InventoryTeamsHook = hookState
	end
	if not hookState.installed then
		local old
		local ok = pcall(function()
			old = hookmetamethod(game, "__namecall", (newcclosure or function(f)
				return f
			end)(function(self, ...)
				local m = getnamecallmethod()
				local cb = hookState.callback
				if cb and (m == "FireServer" or m == "InvokeServer") and not checkcaller() then
					pcall(cb, self, m, table.pack(...))
				end
				return old(self, ...)
			end))
		end)
		hookState.installed = ok
		hookState.old = old
	end
	return hookState.installed == true
end

-- после обучения хук снимаем: он перехватывает ВСЕ вызовы игры и мог мешать оригинальному инвентарю
local function releaseHook()
	if hookState then
		hookState.callback = nil
		if hookState.installed and hookState.old then
			local ok = pcall(hookmetamethod, game, "__namecall", hookState.old)
			if ok then
				hookState.installed = false
				hookState.old = nil
			end
		end
	end
end

function refreshLearnBtn()
	if not learnBtn or not learnBtn.Parent then
		return
	end
	if list and list.Parent then
		local uiOnly = CONFIG.UseUI ~= false and not CONFIG.UseLearned
		local complete = uiOnly or (net.equip and net.unequip and net.unequipAll and not learnStep)
		list.Size = UDim2.new(1, 0, 1, complete and -98 or -116)
	end
	if learnStep then
		learnBtn.Visible = true
		learnBtn.BackgroundColor3 = THEME.Red
		learnLbl.Text = "Cancel"
	elseif (CONFIG.UseUI ~= false and not CONFIG.UseLearned) or (net.equip and net.unequip and net.unequipAll) then
		learnBtn.Visible = false -- всё выучено - кнопка не нужна
	else
		learnBtn.Visible = true
		learnBtn.BackgroundColor3 = THEME.Soft
		learnLbl.Text = "Learn"
	end
end

local function stopLearn(text, color)
	learnStep = nil
	learnToken += 1
	if learnClickConn then
		pcall(function()
			learnClickConn:Disconnect()
		end)
		learnClickConn = nil
	end
	releaseHook()
	refreshLearnBtn()
	if text then
		toast(text, color)
	end
end

local learnCands = {}

-- следит за числом надетых петов: когда оно резко падает (>=2 или до нуля) - берём вызов, случившийся перед этим
local function watchUnequipAll(tok)
	table.clear(learnCands)
	task.spawn(function()
		local hist = {}
		while learnStep == "unequipAll" and tok == learnToken do
			local now = os.clock()
			local cnt = #equippedUids()
			hist[#hist + 1] = { now, cnt }
			while #hist > 0 and now - hist[1][1] > 4 do
				table.remove(hist, 1)
			end
			local peak = 0
			for _, h in ipairs(hist) do
				if h[2] > peak then
					peak = h[2]
				end
			end
			if peak >= 2 and cnt <= peak - 2 then
				local stats = {}
				for _, c in ipairs(learnCands) do
					if now - c.t <= 4.5 then
						local st = stats[c.index]
						if not st then
							st = { count = 0, c = c }
							stats[c.index] = st
						end
						st.count += 1
						st.c = c
					end
				end
				local best
				for _, st in pairs(stats) do
					if st.count <= 2 then -- повторяющиеся (фоновые) вызовы отбрасываем
						local score = st.count * 10 + (st.c.n == 0 and 0 or 5)
						if not best or score < best.score then
							best = { score = score, c = st.c }
						end
					end
				end
				if best then
					local c = best.c
					net.unequipAll = { index = c.index, method = c.method, n = c.n, args = c.args, remote = c.remote }
					saveTeams()
					playSound(SOUNDS.Pop)
					warn(("[Teams] Unequip All выучен: [%d] %s (%d args)"):format(c.index, c.method, c.n))
					stopLearn(("Learned! Equip [%d]  ·  Unequip [%d]  ·  Unequip All [%d]"):format(
						net.equip and net.equip.index or 0, net.unequip and net.unequip.index or 0, c.index), THEME.Green)
					return
				end
				local seen = {}
				for _, c in ipairs(learnCands) do
					seen[#seen + 1] = ("[%d]x%d"):format(c.index, c.n)
				end
				warn("[Teams] Unequip All: петы сняты, но подходящий вызов не найден. Видел вызовы: "
					.. (#seen > 0 and table.concat(seen, ", ") or "нет ни одного"))
				toast("Pets were removed, but no remote call was seen. Try again", THEME.Orange, true)
				hist = { { now, cnt } }
				table.clear(learnCands)
			end
			task.wait(0.1)
		end
	end)
end

-- вызывается уже вне хука (task.defer)
local function handleCall(remote, method, args)
	local step = learnStep
	if not step then
		return
	end
	local save = Library.Save.Get()
	if not save or type(save.Pets) ~= "table" then
		return
	end
	local owned = {}
	for _, pet in ipairs(save.Pets) do
		owned[pet.uid] = true
	end
	-- есть ли в аргументах uid пета
	local found = false
	local template = mapArgs(args, args.n, function(v)
		if type(v) == "string" and owned[v] then
			found = true
			return UID_MARK
		end
		return v
	end)
	local index = table.find(ReplicatedStorage:GetChildren(), remote)
	if not index then
		return
	end

	-- шаг 3: "Unequip All" - вызов БЕЗ uid в аргументах (как Event:InvokeServer()); просто запоминаем вызовы,
	-- а выбирает нужный watchUnequipAll по тому, что после него петы реально сняты
	if step == "unequipAll" then
		if found then
			return
		end
		if (net.equip and net.equip.index == index) or (net.unequip and net.unequip.index == index) then
			return
		end
		learnCands[#learnCands + 1] = {
			index = index, method = method, n = args.n, args = template, remote = remote, t = os.clock(),
		}
		if #learnCands > 80 then
			table.remove(learnCands, 1)
		end
		return
	end

	if not found then
		return
	end

	if step == "equip" then
		net.equip = { index = index, method = method, n = args.n, args = template, remote = remote }
		learnStep = "unequip"
		playSound(SOUNDS.Pop)
		toast(("Equip captured [%d]   Step 2/3: now UNEQUIP any pet"):format(index), THEME.Green, true)
	else
		local e = net.equip
		if e and e.index == index and tostring(e.args[1]) == tostring(template[1]) then
			toast("That looked like EQUIP. Click an equipped pet to UNEQUIP it", THEME.Orange, true)
			return
		end
		net.unequip = { index = index, method = method, n = args.n, args = template, remote = remote }
		saveTeams()
		playSound(SOUNDS.Pop)
		learnStep = "unequipAll"
		watchUnequipAll(learnToken)
		toast(("Unequip captured [%d]   Step 3/3: equip 2+ pets (Equip Best), then click UNEQUIP ALL"):format(index), THEME.Green, true)
	end
end

local function startLearn()
	if busy then
		return
	end
	if detectUnequipAll() and net.equip and net.unequip then
		saveTeams()
		refreshLearnBtn()
		toast("Unequip All found automatically - Learn is not needed", THEME.Green)
		return
	end
	if not ensureHook() then
		toast("Executor has no hookmetamethod - learning is unavailable", THEME.Red)
		playSound(SOUNDS.Error)
		return
	end
	if net.equip and net.unequip and not net.unequipAll then
		learnStep = "unequipAll" -- осталось выучить только Unequip All
	else
		learnStep = "equip"
	end
	learnToken += 1
	local tok = learnToken
	if learnClickConn then
		pcall(function()
			learnClickConn:Disconnect()
		end)
		learnClickConn = nil
	end
	do
		local ub = invGui:FindFirstChild("UnequipAll", true)
		if ub and ub:IsA("GuiButton") then
			learnClickAt = 0
			learnClickConn = ub.Activated:Connect(function()
				learnClickAt = os.clock()
			end)
		end
	end
	hookState.callback = function(remote, method, args)
		if learnStep and typeof(remote) == "Instance" and remote.Parent == ReplicatedStorage then
			task.defer(handleCall, remote, method, args)
		end
	end
	setDrawer(false)
	refreshLearnBtn()
	if learnStep == "unequipAll" then
		watchUnequipAll(tok)
		toast("Step 3/3: equip 2+ pets (Equip Best), then click UNEQUIP ALL in the inventory", THEME.Accent, true)
	else
		toast("Step 1/3: click any pet in the inventory to EQUIP it", THEME.Accent, true)
	end
	task.delay(120, function()
		if learnStep and tok == learnToken then
			stopLearn("Learning timed out", THEME.Orange)
		end
	end)
end

----------------------------------------------------------------------
-- UI: кнопка пета (копия настоящей из инвентаря игры)
----------------------------------------------------------------------
local function setVis(btn, name, v)
	local o = btn:FindFirstChild(name)
	if o and o:IsA("GuiObject") then
		o.Visible = v
	end
end

local function makePetSlot(parent, entry, i, pet)
	local tpl
	pcall(function()
		tpl = Library.Assets.UI.Inventory.Pet
	end)
	local btn
	if tpl then
		btn = tpl:Clone()
	else
		btn = Instance.new("TextButton")
		btn.BackgroundTransparency = 1
		btn.Text = ""
		new("ImageLabel", { Name = "PetIcon", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5 }, btn)
	end
	btn.Name = "Slot" .. i
	btn.Size = UDim2.fromOffset(44, 44)
	btn.Position = UDim2.new()
	btn.LayoutOrder = i
	btn.Visible = true
	btn.AutoButtonColor = false
	btn.Text = ""

	-- ZIndexBehavior у игры Global: поднимаем всю кнопку над панелью
	local base = parent.ZIndex
	btn.ZIndex = base + btn.ZIndex
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = base + d.ZIndex
		end
	end

	-- иконка, уровень, звёзды и подсказка со статами при наведении - делает сама игра
	local viaGame = false
	if pet and Library.PetUI and Library.PetUI.Create then
		viaGame = pcall(Library.PetUI.Create, btn, entry.uid)
	end
	-- ButtonFX игры НЕ вызываем: он рассчитан на клетки 91px с отступом 20px, у нас клетки маленькие -
	-- пет раздувается и залезает на соседей (а PetUI.Create может уже повесить свой эффект -> двойной зум).
	if not viaGame then
		local pi = btn:FindFirstChild("PetIcon")
		if pi then
			pi.Image = iconFor(entry)
		end
		setVis(btn, "Level", false)
		setVis(btn, "Stars", false)
		setVis(btn, "HC", false)
	end
	for _, n in ipairs({ "Level", "HC" }) do
		local o = btn:FindFirstChild(n)
		local st = o and o:FindFirstChildOfClass("UIStroke")
		if st then
			st.Thickness = 2
		end
	end
	setVis(btn, "DeleteOverlay", false)

	-- свой hover: небольшой зум от центра + наведённый пет рисуется поверх соседей
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	local sc = btn:FindFirstChild("ButtonUIScale") or btn:FindFirstChildOfClass("UIScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Name = "ButtonUIScale"
		sc.Parent = btn
	end
	sc.Scale = 1
	local function lift(d)
		btn.ZIndex += d
		for _, o in ipairs(btn:GetDescendants()) do
			if o:IsA("GuiObject") then
				o.ZIndex += d
			end
		end
	end
	local lifted = false
	btn.MouseEnter:Connect(function()
		if not lifted then
			lifted = true
			lift(20)
		end
		tween(sc, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = 1.08 })
	end)
	btn.MouseLeave:Connect(function()
		if lifted then
			lifted = false
			lift(-20)
		end
		tween(sc, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = 1 })
	end)

	btn.Parent = parent
	return { entry = entry, btn = btn, viaGame = viaGame }
end

----------------------------------------------------------------------
-- "Сила" команды: чем сильнее - тем чуть насыщеннее фон и толще обводка карточки
----------------------------------------------------------------------
local tierOf = {} -- [team] = 0 (обычная) | 1 (сильная) | 2 (самая сильная)

local function teamPower(team)
	local p = 0
	for _, e in ipairs(team.pets) do
		p += 1 -- сам пет
		if e.g then p += 1 end -- golden
		if e.sh then p += 1.5 end -- shiny
		if e.r then p += 2 end -- rainbow
	end
	return p
end

local function computeTiers()
	table.clear(tierOf)
	local ranked = {}
	for _, t in ipairs(teams) do
		ranked[#ranked + 1] = { t = t, p = teamPower(t) }
	end
	local n = #ranked
	if n < 2 then
		return
	end
	table.sort(ranked, function(a, b)
		return a.p > b.p
	end)
	local top, low = ranked[1].p, ranked[n].p
	if top == low then
		return -- все одинаковые - подсвечивать нечего
	end
	for i, r in ipairs(ranked) do
		if r.p == top then
			tierOf[r.t] = 2
		elseif i <= math.ceil(n / 3) and r.p > low then
			tierOf[r.t] = 1
		end
	end
end

----------------------------------------------------------------------
-- UI: карточка команды
----------------------------------------------------------------------
local function buildCard(index, team, pop)
	local tier = tierOf[team] or 0
	local cardBg = tier == 2 and THEME.CardTop2 or (tier == 1 and THEME.CardTop1 or THEME.Card)
	local baseStroke = tier == 2 and THEME.StrokeTop or THEME.Stroke
	local baseW = tier == 2 and 3.5 or 2.5
	local patAlpha = tier == 2 and 0.8 or (tier == 1 and 0.86 or 0.9)
	local card = new("Frame", {
		Name = "Team" .. index,
		BackgroundColor3 = cardBg,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = index,
	}, list)
	new("UICorner", { CornerRadius = UDim.new(0, 12) }, card)
	new("UISizeConstraint", { MinSize = Vector2.new(0, 126) }, card)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 12),
	}, card)
	-- тот же тайловый узор, что и на панели игры (rbxassetid://6511368117)
	local pat = new("ImageLabel", {
		Name = "pattern",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(-14, -12),
		Size = UDim2.new(1, 26, 1, 24),
		Image = "rbxassetid://6511368117",
		ImageColor3 = THEME.Accent,
		ImageTransparency = patAlpha,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(CONFIG.PatternTile, CONFIG.PatternTile),
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0, 12) }, pat)
	local stroke = new("UIStroke", {
		Color = baseStroke,
		Thickness = baseW,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, card)
	local cardScale = new("UIScale", { Scale = pop and 0.85 or 1 }, card)
	if pop then
		tween(cardScale, 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out, { Scale = 1 })
	end

	local info = new("Frame", {
		Name = "Info",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -116, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, card)
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 10),
	}, info)

	-- имя команды: синяя "пилюля" с градиентом и обводкой, как кнопки игры; текст с тёмным контуром
	local nameHolder = new("Frame", {
		Name = "NameHolder",
		LayoutOrder = 1,
		BackgroundColor3 = THEME.Field,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 30),
	}, info)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, nameHolder)
	new("UIStroke", { Color = THEME.Stroke, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, nameHolder)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(230, 233, 238)),
		Rotation = 90,
	}, nameHolder)
	local nameBox = new("TextBox", {
		Name = "NameBox",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.FredokaOne,
		Text = team.name,
		PlaceholderText = "Team name",
		TextColor3 = THEME.Dark,
		PlaceholderColor3 = THEME.FieldPlaceholder,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
	}, nameHolder)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8) }, nameBox)
	new("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 8 }, nameBox)
	
	nameBox:GetPropertyChangedSignal("Text"):Connect(function()
		local t = nameBox.Text
		if utf8.len(t) and utf8.len(t) > CONFIG.MaxNameLength then
			local cut = utf8.offset(t, CONFIG.MaxNameLength + 1)
			if cut then
				nameBox.Text = t:sub(1, cut - 1)
			end
		end
	end)
	nameBox.FocusLost:Connect(function()
		local n = trim(nameBox.Text):sub(1, CONFIG.MaxNameLength)
		if n == "" then
			n = team.name
		end
		nameBox.Text = n
		if n ~= team.name then
			team.name = n
			saveTeams()
		end
	end)

	-- один ряд петов, прокручивается по горизонтали (колесо мыши / перетаскивание)
	local iconsHolder = new("ScrollingFrame", {
		Name = "Icons",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 78),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = THEME.Soft,
		ScrollBarImageTransparency = 0.1,
		Active = true,
	}, info)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 2),
	}, iconsHolder)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 2),
	}, iconsHolder)
	iconsHolder.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local maxX = math.max(0, iconsHolder.AbsoluteCanvasSize.X - iconsHolder.AbsoluteWindowSize.X)
			iconsHolder.CanvasPosition = Vector2.new(
				math.clamp(iconsHolder.CanvasPosition.X - input.Position.Z * 56, 0, maxX), 0)
		end
	end)

	local byUid = {}
	do
		local sv = Library.Save.Get()
		if sv and type(sv.Pets) == "table" then
			for _, pt in ipairs(sv.Pets) do
				byUid[pt.uid] = pt
			end
		end
	end
	local icons = {}
	for i, entry in ipairs(team.pets) do
		local cell = new("Frame", {
			Name = "Cell" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(54, 62),
			LayoutOrder = i,
		}, iconsHolder)
		local slot = makePetSlot(cell, entry, i, byUid[entry.uid])
		-- центр клетки чуть выше середины: снизу место под уровень (Level вылезает за кнопку на 20%)
		slot.btn.Position = UDim2.new(0.5, 0, 0, 26)
		icons[i] = slot
	end

	local status = label(info, {
		Name = "Status",
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 13,
		StrokeThickness = 1.6,
		Text = "",
	})

	local right = new("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 96, 0, 70),
	}, card)

	-- Все три кнопки одного стиля: одинаковая обводка/скругление/градиент, разница только в роли.
	-- Equip - главный (акцент), Update и X - второстепенные (нейтральные), красный только у Unequip и при подтверждении удаления.
	local equipBtn, equipLabel = makeButton(right, {
		Name = "Equip",
		Text = "Equip",
		Color = THEME.Accent,
		Size = UDim2.new(1, 0, 0, 32),
		TextSize = 17,
		TextStroke = 1.8,
		Stroke = 2.5,
		Grad = 215,
	})
	local updateBtn = makeButton(right, {
		Name = "Update",
		Text = "Update",
		Color = THEME.Soft,
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, -42, 0, 28),
		TextSize = 13,
		TextStroke = 1.5,
		Stroke = 2.5,
		Grad = 215,
	})
	local delBtn, delLabel = makeButton(right, {
		Name = "Delete",
		Text = "X",
		Color = THEME.Soft,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 42),
		Size = UDim2.fromOffset(34, 28),
		TextSize = 14,
		TextStroke = 1.5,
		Stroke = 2.5,
		Grad = 215,
	})

	equipBtn.Activated:Connect(function()
		toggleTeam(team)
	end)

	updateBtn.Activated:Connect(function()
		if not cooldownOk() then
			return
		end
		lastActionAt = os.clock()
		local snap = snapshotEquipped()
		if not snap or #snap == 0 then
			toast("Equip some pets first!", THEME.Orange)
			playSound(SOUNDS.Error)
			return
		end
		team.pets = snap
		saveTeams()
		local pos = list.CanvasPosition
		rebuild(nil, true)
		task.spawn(function()
			task.wait()
			task.wait()
			if list and list.Parent then
				list.CanvasPosition = pos
			end
		end)
		playSound(SOUNDS.Pop)
	end)

	local armed = false
	delBtn.Activated:Connect(function()
		if armed then
			if not cooldownOk() then
				return
			end
			lastActionAt = os.clock()
			local idx = table.find(teams, team)
			if idx then
				table.remove(teams, idx)
				saveTeams()
				local pos = list.CanvasPosition
				rebuild(nil, true)
				task.spawn(function()
					task.wait()
					task.wait()
					if list and list.Parent then
						list.CanvasPosition = pos
					end
				end)
				playSound(SOUNDS.Soft)
			end
		else
			armed = true
			lastActionAt = os.clock()
			delLabel.Text = "OK?"
			delBtn.BackgroundColor3 = THEME.Red
			task.delay(2.5, function()
				if armed and delBtn.Parent then
					armed = false
					delLabel.Text = "X"
					delBtn.BackgroundColor3 = THEME.Soft
				end
			end)
		end
	end)

	cards[team] = {
		frame = card,
		stroke = stroke,
		status = status,
		baseStroke = baseStroke,
		baseW = baseW,
		equipBtn = equipBtn,
		equipLabel = equipLabel,
		icons = icons,
	}
end

----------------------------------------------------------------------
-- Обновление состояний
----------------------------------------------------------------------
function updateStates()
	if not drawer or not drawer.Parent then
		return
	end
	local save = Library.Save.Get()
	local owned, eq, eqCount, lockedMap = {}, {}, 0, {}
	if save and type(save.Pets) == "table" then
		for _, pet in ipairs(save.Pets) do
			owned[pet.uid] = true
			lockedMap[pet.uid] = pet.l == true
			if hasEquipped(save, pet) then
				eq[pet.uid] = true
				eqCount += 1
			end
		end
	end

	-- число команд показывает заголовок окна ("1/20 Teams")
	if amountObj and amountObj.Parent then
		amountNew = ("%d/%d Teams"):format(#teams, CONFIG.MaxTeams)
		amountObj.Text = amountNew
	end

	local actSet = activeTeams()
	if activeLabel and activeLabel.Parent then
		local activeName
		for _, t in ipairs(teams) do
			if actSet[t] then
				activeName = t.name
				break
			end
		end
		if activeName then
			activeLabel.Text = "Active: " .. activeName
			activeLabel.TextColor3 = THEME.AccentLight
		else
			activeLabel.Text = "No team equipped"
			activeLabel.TextColor3 = THEME.White
		end
	end
	for team, c in pairs(cards) do
		if c.frame.Parent then
			local total, ownedCount, equippedCount = #team.pets, 0, 0
			for i, slot in ipairs(c.icons) do
				local has = owned[slot.entry.uid] == true
				local isEq = eq[slot.entry.uid] == true
				if has then
					ownedCount += 1
					if isEq then
						equippedCount += 1
					end
				end
				local b = slot.btn
				setVis(b, "Equipped", isEq)
				local lk = has and lockedMap[slot.entry.uid] == true
				setVis(b, "Locked", lk)
				if slot.viaGame then
					setVis(b, "Stars", has and not lk)
				end
				local pi = b:FindFirstChild("PetIcon")
				if pi and pi:IsA("ImageLabel") then
					if not slot.viaGame then
						local img = iconFor(slot.entry)
						if pi.Image ~= img then
							pi.Image = img
						end
					end
					pi.ImageTransparency = has and 0 or 0.6
					pi.ImageColor3 = has and THEME.White or THEME.Gray
				end
			end
			local missing = total - ownedCount
			local active = actSet[team] == true

			c.stroke.Color = active and THEME.Accent or c.baseStroke
			c.stroke.Thickness = active and (c.baseW + 1.5) or c.baseW
			c.equipLabel.Text = active and "Unequip" or "Equip"
			c.equipBtn.BackgroundColor3 = active and THEME.Red or THEME.Accent

			local text, color
			if ownedCount == 0 then
				text, color = "All pets are missing", THEME.Red
			else
				text = active and "● Equipped" or ("%d pets ready"):format(ownedCount)
				color = active and THEME.AccentLight or THEME.White
				if missing > 0 then
					text ..= ("   ·   %d missing"):format(missing)
					color = THEME.Orange
				end
			end
			c.status.Text = text
			c.status.TextColor3 = color
		end
	end
end

function rebuild(popIndex, silent)
	computeTiers()
	for _, c in pairs(cards) do
		c.frame:Destroy()
	end
	table.clear(cards)
	emptyLabel.Visible = (#teams == 0)
	for i, team in ipairs(teams) do
		buildCard(i, team, popIndex == i)
	end
	updateStates()
end

----------------------------------------------------------------------
-- Зачистка хвостов старых копий + сборка интерфейса
----------------------------------------------------------------------
pcall(function()
	-- если прошлая копия оборвалась посреди анимации, Main мог остаться внутри обёртки - возвращаем на место
	for _, d in ipairs(invGui:GetDescendants()) do
		if d.Name == "TeamsMainFade" and d:IsA("CanvasGroup") then
			local m = d:FindFirstChild("Main")
			if m then
				m.Position = UDim2.new(0, 0, 0, 0)
				m.Size = UDim2.new(1, 0, 1, 0)
				m.Parent = frame
			end
			d:Destroy()
		end
	end
	for _, d in ipairs(invGui:GetDescendants()) do
		if d.Name == "TeamsDrawer" or d.Name == "TeamsCover" or d.Name == "TeamsToast" or d.Name == "TeamsToggle" then
			pcall(d.Destroy, d)
		end
	end
	for _, d in ipairs(invGui:GetDescendants()) do
		if d:GetAttribute("TeamsHidden") and d:IsA("GuiObject") then
			d.Visible = true
			d:SetAttribute("TeamsHidden", nil)
		end
		local ot = d:GetAttribute("TeamsOrigText")
		if ot and d:IsA("TextLabel") then
			d.Text = ot
			d:SetAttribute("TeamsOrigText", nil)
		end
	end
end)
if dead then
	return
end

do
	-- Панель
	drawer = new("CanvasGroup", {
		Name = "TeamsDrawer",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = closedPos,
		Size = UDim2.new(1, SCROLL_EXTRA, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Visible = false,
		Active = true, -- пока Main ещё виден под панелью, клики не проходят к петам игры
		ZIndex = 60,
	}, frame)
	created[#created + 1] = drawer

	-- Шапка
	local header = new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 52),
	}, drawer)

	-- выровнена по правому краю кнопок в карточках (Unequip / X)
	local saveBtn = makeButton(header, {
		Name = "SaveEquipped",
		Text = "+ New team",
		Color = THEME.Accent,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(SCROLL_EXTRA + 26), 0.5, 0),
		Size = UDim2.fromOffset(120, 30),
		TextSize = 15,
		TextStroke = 1.8,
		Stroke = 2.5,
		Grad = 215,
	})

	saveBtn.Activated:Connect(saveEquippedAsTeam)

	-- слева в шапке: какая команда сейчас надета (обычный текст в стиле игры, не кнопка)
	activeLabel = label(header, {
		Name = "Active",
		Text = "",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 28, 0.5, 0),
		Size = UDim2.new(1, -(SCROLL_EXTRA + 26 + 120 + 28 + 12), 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 20,
	})

	learnBtn, learnLbl = makeButton(drawer, {
		Name = "Learn",
		Text = "Learn",
		Color = THEME.Soft,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -8),
		Size = UDim2.fromOffset(80, 26),
		TextSize = 13,
		TextStroke = 1.5,
		Stroke = 2.5,
		Grad = 215,
	})
	learnBtn.Activated:Connect(function()
		if learnStep then
			stopLearn("Learning cancelled", THEME.Gray)
		else
			startLearn()
		end
	end)
	refreshLearnBtn()
	onNetStale = function()
		saveTeams()
		refreshLearnBtn()
	end

	-- Список
	list = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 68),
		Size = UDim2.new(1, 0, 1, -116),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = THEME.Accent,
		ClipsDescendants = true,
	}, drawer)
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 14),
	}, list)
	local listPad = new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, SCROLL_EXTRA + 14),
	}, list)
	-- полоса прокрутки как у списка петов игры (толщина и картинки берём у настоящей)
	pcall(function()
		local th = math.clamp(petsRoot.ScrollBarThickness, 6, 16)
		list.ScrollBarThickness = th
		list.TopImage = petsRoot.TopImage
		list.MidImage = petsRoot.MidImage
		list.BottomImage = petsRoot.BottomImage
		listPad.PaddingRight = UDim.new(0, SCROLL_EXTRA + 14)
	end)

	refreshLearnBtn() -- подгоняет высоту списка под кнопку Learn

	emptyLabel = label(drawer, {
		Name = "Empty",
		Text = "No teams yet.\nEquip your pets and press \"+ New team\".",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, -SCROLL_EXTRA / 2, 0.5, 6),
		Size = UDim2.new(0.8, 0, 0, 60),
		MaxTextSize = 18,
	})

	-- Тост
	toastGroup = new("CanvasGroup", {
		Name = "TeamsToast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = THEME.Toast,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 100,
	}, frame)
	created[#created + 1] = toastGroup
	new("UICorner", { CornerRadius = UDim.new(0, 17) }, toastGroup)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, toastGroup)
	toastLabel = new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Enum.Font.FredokaOne,
		TextSize = 17,
		TextColor3 = THEME.White,
		Text = "",
	}, toastGroup)

	-- Кнопка открытия
	local function findBar()
		for _, d in ipairs(invGui:GetDescendants()) do
			if d.Name == "Lock" and d:IsA("GuiButton") and d.Parent and d.Parent:FindFirstChild("Grid") then
				return d.Parent, d
			end
		end
		return nil, nil
	end

	local placed = false
	if CONFIG.TogglePlacement == "BottomBar" then
		local bar, lockBtn = findBar()
		if bar then
			local gridBtn = bar:FindFirstChild("Grid")
			local search = bar:FindFirstChild("Search")
			local hasLayout = bar:FindFirstChildWhichIsA("UIListLayout") or bar:FindFirstChildWhichIsA("UIGridLayout")

			toggleBtn = Instance.new("TextButton")
			toggleBtn.Name = "TeamsToggle"
			toggleBtn.BackgroundTransparency = 1
			toggleBtn.BorderSizePixel = 0
			toggleBtn.Text = ""
			toggleBtn.AutoButtonColor = false
			toggleBtn.AnchorPoint = lockBtn.AnchorPoint
			toggleBtn.Size = lockBtn.Size
			toggleBtn.ZIndex = lockBtn.ZIndex
			toggleBtn.LayoutOrder = lockBtn.LayoutOrder

			toggleStar = Instance.new("TextLabel")
			toggleStar.Name = "Star"
			toggleStar.BackgroundTransparency = 1
			toggleStar.AnchorPoint = Vector2.new(0.5, 0.5)
			toggleStar.Position = UDim2.new(0.5, 0, 0.5 + CONFIG.StarOffsetY, 0)
			toggleStar.Size = UDim2.fromScale(CONFIG.StarSize, CONFIG.StarSize)
			toggleStar.Font = Enum.Font.FredokaOne
			toggleStar.Text = "★"
			toggleStar.TextScaled = true
			toggleStar.TextColor3 = THEME.IconBlue
			toggleStar.ZIndex = lockBtn.ZIndex + 1
			toggleStar.Parent = toggleBtn
			new("UIStroke", { Color = THEME.IconStroke, Thickness = CONFIG.StarStroke }, toggleStar)
			local sc = Instance.new("UIScale")
			sc.Name = "ButtonUIScale"
			sc.Parent = toggleBtn

			-- место под кнопку: двигаем / сжимаем поиск
			local shrink
			if hasLayout then
				local pad = hasLayout.Padding
				shrink = UDim.new(lockBtn.Size.X.Scale + pad.Scale, lockBtn.Size.X.Offset + pad.Offset)
			else
				local dx = gridBtn and UDim.new(
					lockBtn.Position.X.Scale - gridBtn.Position.X.Scale,
					lockBtn.Position.X.Offset - gridBtn.Position.X.Offset
				) or UDim.new(0, lockBtn.AbsoluteSize.X + 10)
				if dx.Scale * bar.AbsoluteSize.X + dx.Offset < 0 then
					dx = UDim.new(-dx.Scale, -dx.Offset)
				end
				toggleBtn.Position = UDim2.new(
					lockBtn.Position.X.Scale + dx.Scale, lockBtn.Position.X.Offset + dx.Offset,
					lockBtn.Position.Y.Scale, lockBtn.Position.Y.Offset
				)
				shrink = dx
			end
			if search and search:IsA("GuiObject") then
				local sp0, ss0 = search:GetAttribute("TeamsOrigPos"), search:GetAttribute("TeamsOrigSize")
				if typeof(sp0) == "UDim2" and typeof(ss0) == "UDim2" then
					search.Position, search.Size = sp0, ss0 -- хвост старой копии: возвращаем оригинал
				end
				local oldPos, oldSize = search.Position, search.Size
				search:SetAttribute("TeamsOrigPos", oldPos)
				search:SetAttribute("TeamsOrigSize", oldSize)
				local a = search.AnchorPoint.X
				local function comp(p, sz, d)
					local left = p - a * sz
					local ns = sz - d
					return left + d + a * ns, ns
				end
				local ps, ss = comp(oldPos.X.Scale, oldSize.X.Scale, shrink.Scale)
				local po, so = comp(oldPos.X.Offset, oldSize.X.Offset, shrink.Offset)
				local newPos = UDim2.new(ps, po, oldPos.Y.Scale, oldPos.Y.Offset)
				local newSize = UDim2.new(ss, so, oldSize.Y.Scale, oldSize.Y.Offset)
				local function applySearch()
					if not hasLayout then
						search.Position = newPos
					end
					search.Size = newSize
				end
				local function resetSearch()
					search.Position = oldPos
					search.Size = oldSize
				end
				applySearch()
				restoreFns.search = { apply = applySearch, reset = resetSearch }
				restoreFns[#restoreFns + 1] = function()
					search.Position = oldPos
					search.Size = oldSize
					search:SetAttribute("TeamsOrigPos", nil)
					search:SetAttribute("TeamsOrigSize", nil)
				end
			end
			toggleBtn.Parent = bar
			pcall(function()
				Library.GUIFX.Tooltip(toggleBtn, "Pet Teams")
			end)
			local okFx = pcall(function()
				Library.GUIFX.ButtonFX(toggleBtn)
			end)
			if not okFx then
				toggleBtn.MouseEnter:Connect(function()
					tween(sc, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = 1.1 })
				end)
				toggleBtn.MouseLeave:Connect(function()
					tween(sc, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Scale = 1 })
				end)
			end
			created[#created + 1] = toggleBtn
			placed = true
		end
	end

	if not placed then
		local PLACE = {
			TopCenter = { UDim2.new(0.5, 0, 0, 6), Vector2.new(0.5, 1), UDim2.fromOffset(132, 42) },
			Left = { UDim2.new(0, -8, 0.5, 0), Vector2.new(1, 0.5), UDim2.fromOffset(116, 46) },
			Right = { UDim2.new(1, 8, 0.5, 0), Vector2.new(0, 0.5), UDim2.fromOffset(116, 46) },
		}
		local place = PLACE[CONFIG.TogglePlacement] or PLACE.TopCenter
		toggleBtn, toggleLabel = makeButton(frame, {
			Name = "TeamsToggle",
			Text = "★ Teams",
			Color = THEME.Accent,
			Size = place[3],
			Position = place[1],
			AnchorPoint = place[2],
			TextSize = 22,
		})
		toggleBtn.ZIndex = 40
		for _, d in ipairs(toggleBtn:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.ZIndex = 41
			end
		end
		created[#created + 1] = toggleBtn
	end

	toggleBtn.Activated:Connect(function()
		if env.TeamsEnabled ~= true then
			return
		end
		-- антиспам: пока идёт анимация входа/выхода из вкладки, новые клики игнорируем (и без звука)
		local now = os.clock()
		if now < drawerLockUntil then
			return
		end
		drawerLockUntil = now + CONFIG.TabCooldown
		playSound(SOUNDS.Pop, nil, 0.4)
		setDrawer(not drawerOpen)
	end)
end

----------------------------------------------------------------------
-- События
----------------------------------------------------------------------
local function hookSignal(name, fn)
	local ok, sig = pcall(Library.Signal.Fired, name)
	if ok and sig then
		local ok2, c = pcall(function()
			return sig:Connect(fn)
		end)
		if ok2 and c then
			track(c)
		end
	end
end

local refreshQueued = false
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if drawerOpen then
			updateStates()
		end
	end)
end

hookSignal("Pet Equips Changed", queueRefresh)
-- страховка: сейв иногда обновляется без сигнала (Equip Best / Unequip All) - раз в секунду сверяемся
do
	local alive = true
	track({ Disconnect = function()
		alive = false
	end })
	task.spawn(function()
		while alive do
			task.wait(1)
			if alive and drawerOpen and not busy then
				pcall(updateStates)
			end
		end
	end)
end
hookSignal("Loaded Stats", queueRefresh)
hookSignal("Stat Changed", function(stat)
	if stat == "Pets" or stat == "PetsEquipped" or stat == "MaxEquipped" or stat == "InfPetsEnabled" or stat == "Gamepasses" then
		queueRefresh()
	end
end)

track(invGui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if not invGui.Enabled then
		setDrawer(false, true)
	end
end))

----------------------------------------------------------------------
-- Выгрузка
----------------------------------------------------------------------
local function unload()
	dead = true
	releaseHook()
	if learnClickConn then
		pcall(function()
			learnClickConn:Disconnect()
		end)
		learnClickConn = nil
	end
	pcall(setUnderlying, false)
	pcall(unwrapMain)
	for _, fn in ipairs(restoreFns) do
		pcall(fn)
	end
	table.clear(restoreFns)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	for _, o in ipairs(created) do
		pcall(function()
			o:Destroy()
		end)
	end
	table.clear(created)
	table.clear(cards)
	if env.InventoryTeamsUnload == unload then
		env.InventoryTeamsUnload = nil
	end
end
if dead then
	unload()
	return
end
env.InventoryTeamsUnload = unload

----------------------------------------------------------------------
-- Старт
----------------------------------------------------------------------
loadTeams()
if detectUnequipAll() then
	saveTeams()
end
refreshLearnBtn()
rebuild(nil, true)
print(("[Teams] Загружено. Команд: %d. Хранение в файле: %s"):format(#teams, canFS and "да" or "нет"))

----------------------------------------------------------------------
-- Вкл/выкл через getgenv().TeamsEnabled
----------------------------------------------------------------------
do
	local enabled = nil
	local function setEnabled(on)
		on = on == true
		if enabled == on then
			return
		end
		enabled = on
		if on then
			if toggleBtn then
				toggleBtn.Visible = true
			end
			if restoreFns.search then
				restoreFns.search.apply()
			end
		else
			if learnStep then
				stopLearn()
			end
			setDrawer(false, true)
			if toggleBtn then
				toggleBtn.Visible = false
			end
			if restoreFns.search then
				restoreFns.search.reset()
			end
		end
	end

	setEnabled(env.TeamsEnabled)
	task.spawn(function()
		while not dead do
			setEnabled(env.TeamsEnabled)
			task.wait(0.2)
		end
	end)
end
