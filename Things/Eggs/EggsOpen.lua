--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local CONFIG = {
	TeleportDistance = 10, -- if teleport is on and you are farther than this from the egg, teleport to it
	MaxFailures      = 5,  -- this many failures in a row -> auto-open stops
	FailDelay        = 1,  -- pause after a failed purchase
	RescanInterval   = 15, -- how often to rescan eggs on the map
	AfkArriveWait    = 0.25, -- AFK+TP: minimum pause at the egg so the server sees the new position (ping is added on top)
	AfkAttempts      = 6,    -- AFK+TP: how many purchase attempts at the egg before giving up and going back
	AfkRetryWait     = 0.2,  -- AFK+TP: pause between attempts at the egg
	AfkCooldownMax   = 25,   -- AFK+TP: max wait for the egg-opening animation (the game's cooldown) to finish
}

--------------------------------------------------------------------------------
-- SERVICES AND UTILITIES
--------------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

-- Re-run: stop the old version
if _G.EggTools and _G.EggTools.AutoOpen then
	pcall(_G.EggTools.AutoOpen.Stop)
end
_G.EggToolsGen = (_G.EggToolsGen or 0) + 1
local myGen = _G.EggToolsGen

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Eggs", Text = text, Duration = 6 })
	end)
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

--------------------------------------------------------------------------------
-- 0. CAPTURING THE REAL PURCHASE CALL
-- Remotes are encrypted, so we wait until you open an egg manually once.
-- The hook remembers the remote, the method and the arguments. After that we repeat
-- this call, substituting our own egg and amount.
-- The data is stored in env, so it survives a script restart.
--------------------------------------------------------------------------------
local Captured = env.__EggCapturedV2
if not Captured then
	Captured = { remote = nil, method = nil, args = nil }
	env.__EggCapturedV2 = Captured
end

-- disable the hook of the old script version (it used to call this function)
env.__EggIsEgg = nil

local Lib, Net
local eggCache = {} -- [eggId] = { inst, ... }

-- A simple set table of egg names. The hook only READS it and doesn't call
-- any functions, so it doesn't break the game's scripts.
local EggNames = {}
env.__EggNamesV2 = EggNames

local function rebuildNames()
	local set = {}
	for id in pairs(eggCache) do set[id] = true end
	local d = Lib and Lib.Directory and Lib.Directory.Eggs
	if type(d) == "table" then
		for k in pairs(d) do
			if type(k) == "string" then set[k] = true end
		end
	end
	for k in pairs(EggNames) do EggNames[k] = nil end
	for k in pairs(set) do EggNames[k] = true end
end

if not env.__EggHookV2 then
	if hookmetamethod and getnamecallmethod and newcclosure and checkcaller then
		env.__EggHookV2 = true
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if method == "InvokeServer" or method == "FireServer" then
				if not checkcaller() then
					local first = ...
					local names = env.__EggNamesV2
					if type(first) == "string" and names and names[first] then
						local c = env.__EggCapturedV2
						if c then
							c.remote = self
							c.method = method
							c.args = table.pack(...)
						end
					end
				end
			end
			return oldNamecall(self, ...)
		end))
	end
end

--------------------------------------------------------------------------------
-- 1. GAME LIBRARY AND Network.Invoke (fallback)
--------------------------------------------------------------------------------
local function getLib()
	if Lib then return Lib end
	local fw = ReplicatedStorage:FindFirstChild("Framework")
	local m = fw and fw:FindFirstChild("Library")
	if m and m:IsA("ModuleScript") then
		local ok, res = pcall(require, m)
		if ok and type(res) == "table" then Lib = res end
	end
	return Lib
end

local function pickNetwork(m)
	if type(m) ~= "table" then return nil end
	if type(m.Invoke) == "function" then return m end
	local n = m.Network
	if type(n) == "table" and type(n.Invoke) == "function" then return n end
	return nil
end

-- only called if the remote hasn't been captured, nothing is required at startup
local function resolveNetwork()
	if Net then return Net end
	Net = pickNetwork(getLib())
	if Net then return Net end

	local lib = ReplicatedStorage:FindFirstChild("Library")
	local client = lib and lib:FindFirstChild("Client")
	local mod = client and client:FindFirstChild("Network")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok then Net = pickNetwork(res) end
	end
	return Net
end

local function isOpening()
	local v = Lib and Lib.Variables
	return v and (tonumber(v.OpeningEgg) or 0) > 0 or false
end

--------------------------------------------------------------------------------
-- 2. FINDING EGGS ON THE MAP
--------------------------------------------------------------------------------
local function scanEggs()
	local found = {}
	local map = Workspace:FindFirstChild("__MAP")
	local root = map or Workspace
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		n = n + 1
		if n % 3000 == 0 then task.wait() end
		local id = d:GetAttribute("ID")
		if type(id) == "string" and d:FindFirstChild("Center") and d:FindFirstChild("PriceHUD") then
			local list = found[id]
			if not list then
				list = {}
				found[id] = list
			end
			list[#list + 1] = d
		end
	end
	eggCache = found
end

local function nearestEgg(eggId)
	local list = eggCache[eggId]
	if not list then return nil end
	local rootPart = getRoot()
	local origin = rootPart and rootPart.Position
	local best, bestCenter, bestDist
	for i = #list, 1, -1 do
		local inst = list[i]
		if not inst.Parent then
			table.remove(list, i)
		else
			local c = inst:FindFirstChild("Center")
			if c and c:IsA("BasePart") then
				local dist = origin and (c.Position - origin).Magnitude or 0
				if not bestDist or dist < bestDist then
					best, bestCenter, bestDist = inst, c, dist
				end
			end
		end
	end
	return best, bestCenter, bestDist
end

--------------------------------------------------------------------------------
-- 3. OPENING EGGS
--------------------------------------------------------------------------------
local EggTools = {}

function EggTools.Refresh() scanEggs() end

function EggTools.GetEggNames()
	local names = {}
	for id, list in pairs(eggCache) do
		for _, inst in ipairs(list) do
			if inst.Parent and inst:GetAttribute("Unlocked") ~= false then
				names[#names + 1] = id
				break
			end
		end
	end
	table.sort(names)
	return names
end

-- Whether the remote has been captured (true/false) and with which egg
function EggTools.IsLearned()
	return Captured.remote ~= nil and Captured.args ~= nil
end

function EggTools.GetLearnedEgg()
	return Captured.args and Captured.args[1] or nil
end

-- Build arguments from the captured template:
-- [1] = egg, and if two booleans follow - they are triple and octuple
local function buildArgs(eggId, amount)
	local src = Captured.args
	local args = table.pack(table.unpack(src, 1, src.n))
	args[1] = eggId
	if type(args[2]) == "boolean" and type(args[3]) == "boolean" then
		args[2] = (amount == 3)
		args[3] = (amount == 8)
	end
	return args
end

-- One purchase call. amount: 1, 3 or 8. Returns success, message
function EggTools.OpenOnce(eggId, amount)
	if type(eggId) ~= "string" or eggId == "" then
		return false, "Egg not selected"
	end
	amount = tonumber(amount) or 1

	-- main path: repeat the captured call
	if Captured.remote and Captured.args then
		local args = buildArgs(eggId, amount)
		local remote, method = Captured.remote, Captured.method
		local res = table.pack(pcall(function()
			return remote[method](remote, table.unpack(args, 1, args.n))
		end))
		if not res[1] then
			return false, tostring(res[2])
		end
		if method == "InvokeServer" and res[2] == false then
			return false, res[3] or "server refused"
		end
		return true, res[3]
	end

	-- fallback path: the game's Network.Invoke
	local net = resolveNetwork()
	if not net then
		return false, "Remote not learned: open any egg manually once"
	end
	local ok, success, msg = pcall(net.Invoke, "Buy Egg", eggId, amount == 3, amount == 8)
	if not ok then return false, tostring(success) end
	return success and true or false, msg
end

local AutoOpen = {
	Enabled = false,
	Egg = nil,
	Amount = 1,
	Delay = 0.3,
	Teleport = false,
	WaitAnimation = false,
	Afk = false,      -- AFK+TP: stand at Home, hop to the egg only for the purchase
	Home = nil,       -- CFrame of the spot to return to
	Opened = 0,
	Token = nil,
}

-- Remember the current position as the AFK spot
function EggTools.SetHome()
	local r = getRoot()
	if r then
		AutoOpen.Home = r.CFrame
		return true
	end
	return false
end

-- Remember the position at script launch (wait for the character if needed)
task.spawn(function()
	local t = 0
	while not getRoot() and t < 15 do
		task.wait(0.25)
		t += 0.25
	end
	if not AutoOpen.Home then EggTools.SetHome() end
end)

-- The game's real cooldown = the egg opening animation.
-- We count "Opening Egg" (start) and "Done Opening Egg" (end) signals, so even an
-- instant animation can't be missed and an OLD animation can't be mistaken for ours.
local startCount, doneCount = 0, 0
local signalsHooked = false
local function hookSignals()
	local lib = getLib()
	if not lib then return false end
	local gen = _G.EggToolsGen
	local ok = pcall(function()
		lib.Signal.Fired("Opening Egg"):Connect(function()
			if _G.EggToolsGen == gen then startCount = startCount + 1 end
		end)
		lib.Signal.Fired("Done Opening Egg"):Connect(function()
			if _G.EggToolsGen == gen then doneCount = doneCount + 1 end
		end)
	end)
	if ok then signalsHooked = true end
	return ok
end
task.spawn(function()
	local t = 0
	while not hookSignals() and t < 30 do
		task.wait(0.5)
		t += 0.5
	end
end)

-- true while any egg animation (the cooldown) is still running
local function animActive()
	if isOpening() then return true end
	return signalsHooked and startCount > doneCount
end

-- After a successful purchase: wait for OUR animation to start, then to finish.
-- `startBefore` = startCount right before the purchase call.
local function waitCooldown(startBefore, token)
	local t = os.clock()
	local function alive() return AutoOpen.Enabled and AutoOpen.Token == token end
	-- 1) the animation starts shortly after the purchase
	while startCount <= startBefore and not isOpening()
		and os.clock() - t < 3 and alive() do
		task.wait(0.03)
	end
	-- 2) wait until every animation is over
	while animActive() and os.clock() - t < CONFIG.AfkCooldownMax and alive() do
		task.wait(0.05)
	end
end

local function goHome()
	local home = AutoOpen.Home
	local r = getRoot()
	if r and home then
		r.CFrame = home
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
	end
end

-- One AFK cycle: teleport to the egg -> buy (retry a few times) -> teleport back to Home
local function afkOpenOnce(eggId, amount, token)
	if not AutoOpen.Home then EggTools.SetHome() end
	local rootPart = getRoot()
	if not (AutoOpen.Home and rootPart) then
		return false, "Character not ready"
	end
	local egg, center = nearestEgg(eggId)
	if not (egg and center) then
		return false, "Egg not found on the map"
	end

	rootPart.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 6))
	pcall(function() rootPart.AssemblyLinearVelocity = Vector3.zero end)

	-- give the server time to receive our new position
	local ping = 0
	pcall(function() ping = LocalPlayer:GetNetworkPing() end)
	task.wait(math.max(CONFIG.AfkArriveWait, ping * 2 + 0.1))

	local startBefore = startCount
	local ok, msg = false, "no attempt"
	for attempt = 1, CONFIG.AfkAttempts do
		startBefore = startCount
		local okCall, a, b = pcall(EggTools.OpenOnce, eggId, amount)
		if okCall then ok, msg = a, b else ok, msg = false, tostring(a) end
		if ok then break end
		warn(("[Eggs AFK] attempt %d/%d failed: %s"):format(attempt, CONFIG.AfkAttempts, tostring(msg)))
		if not (AutoOpen.Enabled and AutoOpen.Token == token) then break end
		-- stay at the egg: maybe the previous animation (cooldown) is still running
		local r = getRoot()
		if r and (r.Position - center.Position).Magnitude > 12 then
			r.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 6))
		end
		task.wait(CONFIG.AfkRetryWait)
	end

	-- always go back, even if the purchase failed
	goHome()

	if ok then
		-- stand at home until the animation (cooldown) is over
		waitCooldown(startBefore, token)
	end
	return ok, msg
end

function AutoOpen.Start(eggId, amount)
	if AutoOpen.Enabled then return end
	if eggId then AutoOpen.Egg = eggId end
	if amount then AutoOpen.Amount = tonumber(amount) or 1 end
	-- if no egg is selected - take the one that was opened manually
	if not AutoOpen.Egg then AutoOpen.Egg = EggTools.GetLearnedEgg() end
	if not AutoOpen.Egg then
		return
	end

	local token = {}
	AutoOpen.Token = token
	AutoOpen.Enabled = true
	AutoOpen.Opened = 0

	task.spawn(function()
		local fails = 0
		while AutoOpen.Enabled and AutoOpen.Token == token do
			local id = AutoOpen.Egg

			if AutoOpen.Teleport and not AutoOpen.Afk then
				local egg, center, dist = nearestEgg(id)
				if egg and center and dist and dist > CONFIG.TeleportDistance then
					local rootPart = getRoot()
					if rootPart then
						rootPart.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 6))
						task.wait(0.3)
					end
				end
			end

			if AutoOpen.WaitAnimation or AutoOpen.Afk then
				local t = os.clock()
				while animActive() and os.clock() - t < 25 and AutoOpen.Enabled and AutoOpen.Token == token do
					task.wait(0.05)
				end
			end

			local amountNow = AutoOpen.Amount
			local ok, msg
			if AutoOpen.Afk then
				ok, msg = afkOpenOnce(id, amountNow, token)
			else
				ok, msg = EggTools.OpenOnce(id, amountNow)
			end
			if ok then
				fails = 0
				AutoOpen.Opened = AutoOpen.Opened + (tonumber(amountNow) or 1)
				task.wait(math.max(0.05, AutoOpen.Delay))
			else
				fails = fails + 1
				if fails >= CONFIG.MaxFailures then
					AutoOpen.Enabled = false
					notify("Stopped: " .. tostring(msg))
					break
				end
				task.wait(CONFIG.FailDelay)
			end
		end
	end)
end

function AutoOpen.Stop()
	AutoOpen.Enabled = false
end

EggTools.AutoOpen = AutoOpen
_G.EggTools = EggTools

--------------------------------------------------------------------------------
-- 4. DISABLING THE EGG OPENING ANIMATION
-- Controlled by a variable:
--   _G.NoEggAnimation = true   -- no animation (eggs open instantly)
--   _G.NoEggAnimation = false  -- normal animation
-- The replacement is installed once, after that the variable can be changed freely.
--------------------------------------------------------------------------------
if _G.NoEggAnimation == nil then
	_G.NoEggAnimation = false
end

local NoAnim = { Method = nil, Installed = false }

-- Instant replacement of OpenEgg: same signals and counter, but no animation
local function InstantOpen(eggName, pets)
	local vars = Lib.Variables

	env.__LastEggOpen = {
		egg = eggName,
		count = (type(pets) == "table") and #pets or 1,
	}

	vars.OpeningEgg = vars.OpeningEgg + 1
	Lib.Signal.Fire("Opening Egg", eggName)

	game:GetService("RunService").Heartbeat:Wait() -- one frame so other scripts can react

	vars.OpeningEgg = math.max(vars.OpeningEgg - 1, 0)
	Lib.Signal.Fire("Done Opening Egg", eggName)
end

local function installNoAnim()
	if env.__NoEggAnimInstalled then
		NoAnim.Installed = true
		NoAnim.Method = env.__NoEggAnimInstalled
		return
	end

	-- wait for the game library to load
	local waited = 0
	while not getLib() and waited < 20 do
		task.wait(0.5)
		waited += 0.5
	end
	if not Lib then
		return
	end
	while not Lib.Loaded do
		game:GetService("RunService").Heartbeat:Wait()
	end

	local isExec = isexecutorclosure or checkclosure or function() return false end

	local function looksRight(f)
		local ok, consts = pcall(debug.getconstants, f)
		if not ok or type(consts) ~= "table" then return true end
		return table.find(consts, "Opening Egg") ~= nil
	end

	local function findOpenEgg()
		if not (getgc and islclosure and debug.info) then return nil end
		for _, f in ipairs(getgc()) do
			if type(f) == "function" and islclosure(f) and not isExec(f)
				and debug.info(f, "n") == "OpenEgg" and looksRight(f) then
				return f
			end
		end
	end

	local target
	for _ = 1, 20 do -- wait up to ~10 sec in case the game is still loading
		target = findOpenEgg()
		if target then break end
		task.wait(0.5)
	end

	local method

	-- Method 1: function replacement. The wrapper checks the variable itself:
	-- on -> instant version, off -> original.
	if target and hookfunction then
		local old
		local ok = pcall(function()
			old = hookfunction(target, function(...)
				if _G.NoEggAnimation then
					return InstantOpen(...)
				end
				return old(...)
			end)
		end)
		if ok and old then method = "hookfunction" end
	end

	-- Method 2 (fallback): the game's subscriptions are disabled/enabled by the variable
	if not method and getconnections then
		local ok = pcall(function()
			local sources = {
				Lib.Network.Fired("Open Egg"),
				Lib.Signal.Fired("Open Egg"),
			}
			local original = {}
			for _, sig in ipairs(sources) do
				for _, c in ipairs(getconnections(sig)) do
					original[#original + 1] = c
				end
			end
			for _, sig in ipairs(sources) do
				sig:Connect(function(eggName, pets)
					if _G.NoEggAnimation then
						task.spawn(InstantOpen, eggName, pets)
					end
				end)
			end

			local applied = false
			task.spawn(function()
				while _G.EggToolsGen == myGen do
					local want = _G.NoEggAnimation and true or false
					if want ~= applied then
						applied = want
						for _, c in ipairs(original) do
							pcall(function()
								if want then c:Disable() else c:Enable() end
							end)
						end
					end
					task.wait(0.2)
				end
				-- script was restarted: restore the original subscriptions
				for _, c in ipairs(original) do pcall(function() c:Enable() end) end
			end)
		end)
		if ok then method = "getconnections" end
	end

	if method then
		env.__NoEggAnimInstalled = method
		NoAnim.Installed = true
		NoAnim.Method = method
	end
end

function EggTools.SetNoAnimation(value)
	_G.NoEggAnimation = value and true or false
end

function EggTools.IsNoAnimationReady()
	return NoAnim.Installed, NoAnim.Method
end

task.spawn(installNoAnim)

task.spawn(function()
	while _G.EggToolsGen == myGen do
		pcall(function()
			scanEggs()
			getLib()
			rebuildNames()
		end)
		task.wait(CONFIG.RescanInterval)
	end
end)

task.spawn(getLib)
