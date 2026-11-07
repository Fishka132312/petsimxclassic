--// PetSkins.lua
--// Local pet skin changer: only YOU see the change (inventory icon + the pet model in the world).
--// Nothing is sent to the server, your real pets / stats / trades stay untouched.
--// No window of its own: open the inventory, RIGHT-CLICK the pet you want to re-skin, and the inventory
--// itself turns into a full list of every pet in the game (same cell design, same search box).
--// CHANCES: button "Chances" (left edge) or RightControl = panel to set luck / Golden / Rainbow / Shiny / Dark Matter % and a favourite pet for local egg & gift opening.
--// Click a skin to apply it. Esc cancels. The picker opens only on the RIGHT mouse button; choosing a skin is a normal left click. Left click on a pet with a gift/egg skin opens it locally.

-- one instance only: running the script again fully stops the previous run first, then starts fresh
local ENV = (type(getgenv) == "function" and getgenv()) or _G
for _, holder in ipairs({ ENV, _G }) do
	if type(holder) == "table" and type(holder.PetSkinsUnload) == "function" then
		pcall(holder.PetSkinsUnload)
		holder.PetSkinsUnload = nil
	end
end

-- _G.PetsChanger: true = skin changer works, false = every skin is rolled back and nothing can be changed.
-- Always OFF when the script starts; set _G.PetsChanger = true to turn it on.
_G.PetsChanger = false
local changerOn = false

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
	RunService.Heartbeat:Wait()
end

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local PetCmds = Library.PetCmds

for _, parent in ipairs({ PlayerGui, (type(gethui) == "function" and gethui()) or nil, game:GetService("CoreGui") }) do
	pcall(function()
		for _, g in ipairs(parent:GetChildren()) do
			if g.Name == "PetSkinsGui" then
				g:Destroy()
			end
		end
	end)
end
local PetDir = Library.Directory.Pets

local FILE_NAME = "PetSkins.json"

----------------------------------------------------------------------
-- state / persistence
----------------------------------------------------------------------
local skins = {} -- [petUid] = skinPetId (Directory.Pets key)
local iconCache = {} -- [petUid] = { skin = skinId, image = "rbxassetid://..." }
local nameHistory = {} -- [petUid] = { [oldName] = true } (names the hover card might still show)
local spawnedByUid = {} -- [petUid] = spawned table returned by PetCmds.Spawn
local connections = {}
local previewPets = {} -- [previewUid] = { uid, id }: fake pets that only exist so the game's own UI can draw picker cells
local scratchPets = {} -- same, for hidden cells used only to read the game's background per rarity (never cleared)
local USE_GAME_HOVER = false -- true = picker cells use the game's PetUI hover card (can break on fake pets); false = own tip with the exact directory name + rarity background
local unloaded = false

local function loadSkins()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		return
	end
	local ok, data = pcall(function()
		if isfile(FILE_NAME) then
			return HttpService:JSONDecode(readfile(FILE_NAME))
		end
		return nil
	end)
	if ok and type(data) == "table" then
		for uid, skinId in pairs(data) do
			if type(uid) == "string" and (type(skinId) == "string" or type(skinId) == "number") then
				skins[uid] = tostring(skinId)
			end
		end
	end
end

local function saveSkins()
	if type(writefile) ~= "function" then
		return
	end
	pcall(function()
		writefile(FILE_NAME, HttpService:JSONEncode(skins))
	end)
end

loadSkins()

-- chosen look per skinned pet: [petUid] = { g = bool, r = bool, sh = bool } (nil / empty table = normal)
-- stored in its own file so the old PetSkins.json format keeps working
local VARIANT_FILE = "PetSkinVariants.json"
local variants = {}

local function loadVariants()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		return
	end
	local ok, data = pcall(function()
		if isfile(VARIANT_FILE) then
			return HttpService:JSONDecode(readfile(VARIANT_FILE))
		end
		return nil
	end)
	if ok and type(data) == "table" then
		for uid, v in pairs(data) do
			if type(uid) == "string" and type(v) == "table" then
				variants[uid] = { g = v.g == true, r = v.r == true, sh = v.sh == true, dm = v.dm == true }
			end
		end
	end
end

local function saveVariants()
	if type(writefile) ~= "function" then
		return
	end
	pcall(function()
		writefile(VARIANT_FILE, HttpService:JSONEncode(variants))
	end)
end

loadVariants()

-- changer starts OFF: the saved skins wait in this stash until _G.PetsChanger = true
local stash = { skins = {}, variants = {} }
for uid, v in pairs(skins) do stash.skins[uid] = v end
for uid, v in pairs(variants) do stash.variants[uid] = v end
table.clear(skins)
table.clear(variants)

-- put the chosen look onto a (cloned) pet table
local function applyVariant(data, uid)
	local v = uid and variants[uid]
	if v then
		data.g = v.g or nil
		data.r = v.r or nil
		data.sh = v.sh or nil
		data.dm = v.dm or nil
	end
	return data
end

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
-- eggs / gifts: no strength, no mutation, no pet in the world
local function hasNoStrength(dir)
	return type(dir) == "table"
		and (dir.isGift == true or string.find(string.lower(tostring(dir.rarity or "")), "egg", 1, true) ~= nil)
end

local function trySet(tbl, key, value)
	local ok = pcall(function()
		tbl[key] = value
	end)
	if ok then
		return true
	end
	if type(setreadonly) == "function" then
		pcall(setreadonly, tbl, false)
		ok = pcall(function()
			tbl[key] = value
		end)
	end
	return ok
end

do
	local saved = ENV.__PetSkinsOrig
	if saved then -- a previous run died without cleaning up: put the game's real functions back first
		if saved.Spawn then trySet(PetCmds, "Spawn", saved.Spawn) end
		if saved.Get then trySet(PetCmds, "Get", saved.Get) end
		if saved.Strength then trySet(Library.Shared, "ComputePetStrength", saved.Strength) end
	else
		ENV.__PetSkinsOrig = {
			Spawn = PetCmds.Spawn,
			Get = PetCmds.Get,
			Strength = Library.Shared.ComputePetStrength,
		}
	end
end

local function skinName(id)
	local dir = id and PetDir[id]
	if dir and type(dir.name) == "string" then
		return dir.name
	end
	return tostring(id)
end

local function imageFor(petData, skinId)
	local dir = PetDir[skinId]
	if not dir then
		return nil
	end
	local img
	if petData and petData.dm and dir.darkMatterThumbnail then
		img = dir.darkMatterThumbnail
	elseif petData and petData.g and dir.goldenThumbnail then
		img = dir.goldenThumbnail
	else
		img = dir.thumbnail
	end
	if type(img) == "string" and img ~= "" then
		return img
	end
	return nil
end

----------------------------------------------------------------------
-- tooltip / stats: the game reads pet data through PetCmds.Get and Shared.ComputePetStrength,
-- so for skinned pets we hand it a copy of the pet with the skin's id. The hover card then shows
-- the skin's name and the skin's strength. Real data / server are untouched.
----------------------------------------------------------------------
local Shared = Library.Shared
local origGet = PetCmds.Get
local origStrength = Shared.ComputePetStrength

local function skinnedPet(pet)
	if type(pet) == "table" and pet.uid then
		local sid = skins[pet.uid]
		if sid and PetDir[sid] and (pet.id ~= sid or variants[pet.uid]) then
			local copy = table.clone(pet)
			copy.id = sid
			return applyVariant(copy, pet.uid)
		end
	end
	return pet
end

local function hookedGet(...)
	local req = ...
	if not unloaded and type(req) == "string" then
		local pv = previewPets[req] or scratchPets[req]
		if pv then
			return pv
		end
	end
	local a, b, c = origGet(...)
	if unloaded then
		return a, b, c
	end
	-- Get(uid) must hand back the skin ONLY for that exact pet, never for any other pet
	if type(req) == "string" and type(a) == "table" and a.uid ~= req then
		return a, b, c
	end
	return skinnedPet(a), b, c
end

local function hookedStrength(pet, ...)
	if unloaded then
		return origStrength(pet, ...)
	end
	return origStrength(skinnedPet(pet), ...)
end

local getHooked = trySet(PetCmds, "Get", hookedGet)
local strengthHooked = type(origStrength) == "function" and trySet(Shared, "ComputePetStrength", hookedStrength)

----------------------------------------------------------------------
-- in-world model: wrap PetCmds.Spawn (only for the local player)
----------------------------------------------------------------------
local origSpawn = PetCmds.Spawn

local function hookedSpawn(petData, player, ...)
	local data = petData
	if player == LocalPlayer and type(petData) == "table" then
		local skinId = skins[petData.uid]
		if skinId and PetDir[skinId] then
			data = table.clone(petData)
			data.id = skinId
			applyVariant(data, petData.uid)
		end
	end
	local spawned = origSpawn(data, player, ...)
	if player == LocalPlayer and type(spawned) == "table" and spawned.uid then
		spawnedByUid[spawned.uid] = spawned
	end
	return spawned
end

local hookInstalled = trySet(PetCmds, "Spawn", hookedSpawn)

-- Swap the model of an already-spawned pet IN PLACE. The Pets script keeps a reference to this
-- exact `spawned` table, so we build a fresh one with the right id and copy its fields over.
local hiddenParent = {} -- [uid] = real parent of a pet model that is hidden (egg / gift skin)
local KEEP = { uid = true, owner = true, coinSelection = true, spinTick = true }
local clickMemo = {} -- [uid] = CursorIcon of the pet's ClickDetector (remembered, an egg skin has none)

-- where do pet models live in the world? (taken from any other pet that is currently out)
local function findPetParent(excludeUid)
	for u, sp in pairs(spawnedByUid) do
		local part = type(sp) == "table" and sp.part
		if u ~= excludeUid and typeof(part) == "Instance" and part.Parent then
			return part.Parent
		end
	end
	return nil
end

-- egg / gift skin: the pet model stays IN the world (so the game never notices anything and never
-- respawns the pet), it is just invisible, silent and unclickable. Called every frame for such pets.
local HIDE_ENABLED = {
	ParticleEmitter = true, Beam = true, Trail = true, Fire = true, Smoke = true, Sparkles = true,
	PointLight = true, SpotLight = true, SurfaceLight = true, BillboardGui = true, SurfaceGui = true,
	Highlight = true,
}
local function hideOne(o)
	if o:IsA("BasePart") then
		if o.LocalTransparencyModifier ~= 1 then
			o.LocalTransparencyModifier = 1
		end
		if o.CanQuery then
			o.CanQuery = false
		end
	elseif o:IsA("Decal") or o:IsA("Texture") then
		if o.Transparency ~= 1 then
			o.Transparency = 1
		end
	elseif o:IsA("ClickDetector") then
		if o.MaxActivationDistance ~= 0 then
			o.MaxActivationDistance = 0
		end
	elseif HIDE_ENABLED[o.ClassName] then
		if o.Enabled then
			o.Enabled = false
		end
	end
end
local function hidePetModel(spawned)
	if type(spawned) ~= "table" then
		return
	end
	for _, root in ipairs({ spawned.part, spawned.model }) do
		if typeof(root) == "Instance" then
			pcall(hideOne, root)
			for _, o in ipairs(root:GetDescendants()) do
				pcall(hideOne, o)
			end
		end
	end
end

local function respawn(uid)
	local spawned = spawnedByUid[uid]
	if not spawned or not spawned.part then
		return
	end
	local petData = origGet(uid)
	if not petData then
		return
	end
	local oldPart = spawned.part
	local oldCFrame = oldPart.CFrame
	local oldParent = oldPart.Parent
	local hadClick = oldPart:FindFirstChildOfClass("ClickDetector")
	if hadClick then
		clickMemo[uid] = hadClick.CursorIcon
	end

	local fresh = hookedSpawn(petData, LocalPlayer) -- goes through the skin logic
	if type(fresh) ~= "table" or not fresh.part then
		return
	end
	for k, v in pairs(fresh) do
		if not KEEP[k] then
			spawned[k] = v
		end
	end
	spawnedByUid[uid] = spawned

	local newPart = spawned.part
	-- the game's Spawn may already have put the fresh model into the world: remember where
	local freshParent = newPart.Parent
	newPart.CFrame = oldCFrame
	local skinNow = skins[uid]
	local isEggNow = skinNow and hasNoStrength(PetDir[skinNow])
	if (hadClick or clickMemo[uid] ~= nil) and not isEggNow and not newPart:FindFirstChildOfClass("ClickDetector") then
		local cd = Instance.new("ClickDetector")
		cd.MaxActivationDistance = math.huge
		cd.CursorIcon = hadClick and hadClick.CursorIcon or clickMemo[uid]
		cd.Parent = newPart
	end
	oldParent = oldParent or freshParent or findPetParent(uid)
	hiddenParent[uid] = nil
	newPart.Parent = oldParent
	if isEggNow then
		hidePetModel(spawned)
	end
	oldPart.Parent = nil
	pcall(function()
		oldPart:Destroy()
	end)
end

-- Pets that were already out before this script loaded: find their live `spawned` tables.
local function adoptExisting()
	if type(getgc) ~= "function" then
		return
	end
	local ok, gc = pcall(getgc, true)
	if not ok then
		return
	end
	for _, t in ipairs(gc) do
		if type(t) == "table" then
			local okf = pcall(function()
				if rawget(t, "owner") == LocalPlayer and rawget(t, "uid") and rawget(t, "part")
					and typeof(rawget(t, "part")) == "Instance" and rawget(t, "part").Parent then
					spawnedByUid[t.uid] = t
				end
			end)
			if not okf then
				-- ignore weird tables
			end
		end
	end
end

----------------------------------------------------------------------
-- inventory icon
----------------------------------------------------------------------
local invGui = Library.GUI.Inventory

local function getInventoryItem(uid)
	local main = invGui and invGui.Main
	local pets = main and main.Pets
	if not pets then
		return nil
	end
	local normal = pets:FindFirstChild("Normal")
	local titanic = pets:FindFirstChild("Titanic")
	return (normal and normal:FindFirstChild(uid)) or (titanic and titanic:FindFirstChild(uid))
end

local hoveredUid = nil

-- The game builds the hover card once per inventory item. To make it show the new pet (name, outline,
-- strength) we delete that item and let the game's own inventory update create it again.
local function rebuildItem(uid)
	local item = getInventoryItem(uid)
	if item then
		pcall(function()
			item:Destroy()
		end)
	end
	if hoveredUid == uid then
		hoveredUid = nil
	end
	local real = origGet(uid)
	pcall(function()
		Library.Signal.Fire("Lock Changed", uid, real and real.l)
	end)
end

local function getInventoryIcon(uid)
	local item = getInventoryItem(uid)
	local icon = item and item:FindFirstChild("PetIcon")
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		return icon
	end
	return nil
end

-- which inventory item the mouse is over
local hoverHooked = setmetatable({}, { __mode = "k" }) -- [item] = true

local function hookHover(uid, item)
	if not item or hoverHooked[item] or not item:IsA("GuiObject") then
		return
	end
	hoverHooked[item] = true
	item.MouseEnter:Connect(function()
		hoveredUid = uid
	end)
	item.MouseLeave:Connect(function()
		if hoveredUid == uid then
			hoveredUid = nil
		end
	end)
end

local function restoreIcon(uid)
	iconCache[uid] = nil
	local icon = getInventoryIcon(uid)
	if not icon then
		return
	end
	local petData = origGet(uid)
	if petData then
		local img = imageFor(petData, petData.id)
		if img then
			icon.Image = img
		end
	end
end

-- strength label of an inventory cell ("Level" in the game's gui): the game prints "???" for Huge
-- pets and "????" for Titanic pets, a number ("42m") for everything else.
local LIGHT_PURPLE = Color3.fromRGB(175, 125, 255)
local levelStyle = {} -- colours copied from the game's own labels
local levelCache = {} -- [uid] = { skin = id, text = "42m" }
local SUFFIXES = { "", "k", "m", "b", "t", "qd", "qn", "sx", "sp", "oc", "no", "dc" }

local function formatStrength(n)
	if type(n) ~= "number" or n ~= n or n < 0 then
		return nil
	end
	local i = 1
	while n >= 1000 and i < #SUFFIXES do
		n = n / 1000
		i = i + 1
	end
	local str
	if i == 1 then
		str = tostring(math.floor(n + 0.5))
	else
		str = string.format("%.1f", n)
		str = string.gsub(str, "%.0$", "")
	end
	return str .. SUFFIXES[i]
end

local function applyLevelText(uid, skinId, item)
	local lvl = item and item:FindFirstChild("Level")
	if not lvl or not lvl:IsA("TextLabel") then
		return
	end
	local dir = PetDir[skinId]
	if not dir then
		return
	end
	if hasNoStrength(dir) then
		-- egg / gift skin: hide the strength label completely
		if lvl.Visible then
			lvl.Visible = false
			lvl:SetAttribute("PetSkinsHidden", true)
		end
		return
	elseif lvl:GetAttribute("PetSkinsHidden") then
		lvl:SetAttribute("PetSkinsHidden", nil)
		lvl.Visible = true
	end
	local marks = dir.titanic and 4 or (dir.huge and 3 or nil)
	if marks then
		local want = string.rep("?", marks)
		if lvl.Text ~= want then
			lvl.Text = want
		end
		local color = levelStyle.huge or Color3.fromRGB(245, 235, 255)
		if lvl.TextColor3 ~= color then
			lvl.TextColor3 = color
		end
		-- purple "???" with the game's outline, copied from a real Huge cell when one is on screen
		local stroke = lvl:FindFirstChildOfClass("UIStroke")
		if stroke then
			local outline = LIGHT_PURPLE
			local sampled = levelStyle.hugeStroke
			if sampled then
				local _, sat = sampled:ToHSV()
				if sat > 0.2 then -- only trust the game's colour when it is really coloured, not white/grey
					outline = sampled
				end
			end
			if stroke.Color ~= outline then
				stroke.Color = outline
			end
		end
		if levelStyle.hugeGradient and not lvl:FindFirstChild("PetSkinsGradient") then
			local existing = lvl:FindFirstChildOfClass("UIGradient")
			if existing then
				existing:Destroy()
			end
			local g = levelStyle.hugeGradient:Clone()
			g.Name = "PetSkinsGradient"
			g.Parent = lvl
		end
	elseif string.match(lvl.Text, "^%s*%?+%s*$") then
		-- the real pet is Huge/Titanic but the skin is a normal pet: show a normal number
		local cached = levelCache[uid]
		if not cached or cached.skin ~= skinId then
			local real = origGet(uid)
			local ok, val = pcall(origStrength, skinnedPet(real))
			cached = { skin = skinId, text = ok and formatStrength(val) or nil }
			levelCache[uid] = cached
		end
		if cached.text then
			lvl.Text = cached.text
			if levelStyle.normal then
				lvl.TextColor3 = levelStyle.normal
			end
			local stroke = lvl:FindFirstChildOfClass("UIStroke")
			if stroke and levelStyle.normalStroke then
				stroke.Color = levelStyle.normalStroke
			end
			local ours = lvl:FindFirstChild("PetSkinsGradient")
			if ours then
				ours:Destroy()
			end
		end
	end
end

-- egg / gift skins: keep the in-world pet model invisible (also when the game spawns it again later)
connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	if unloaded then
		return
	end
	for uid, skinId in pairs(skins) do
		if hasNoStrength(PetDir[skinId]) then
			hidePetModel(spawnedByUid[uid])
		end
	end
end)

-- inventory cells are built by the game from the REAL pet, so its rainbow tint / shine would stay on
-- the cell. Remove whatever the chosen look (variants[uid], {} = normal) does not have.
local rainbowGuard = setmetatable({}, { __mode = "k" }) -- [icon] = connection
local lastFxScan = 0
local function cleanMutationFx(uid, cell)
	if not cell then
		return
	end
	local v = variants[uid] or {}
	if not v.r then
		local icon = cell:FindFirstChild("PetIcon")
		if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
			if icon.ImageColor3 ~= Color3.new(1, 1, 1) then
				icon.ImageColor3 = Color3.new(1, 1, 1)
			end
			if not rainbowGuard[icon] then
				rainbowGuard[icon] = icon:GetPropertyChangedSignal("ImageColor3"):Connect(function()
					local vv = variants[uid]
					if not unloaded and skins[uid] and not (vv and vv.r) and icon.ImageColor3 ~= Color3.new(1, 1, 1) then
						icon.ImageColor3 = Color3.new(1, 1, 1)
					end
				end)
				connections[#connections + 1] = rainbowGuard[icon]
			end
		end
	end
	if os.clock() - lastFxScan > 0.1 then
		for _, d in ipairs(cell:GetDescendants()) do
			local n = string.lower(d.Name)
			if d:IsA("GuiObject") and not d:FindFirstAncestor("PetSkinsGui") then
				if not v.sh and string.sub(n, 1, 5) == "shine" then
					d:Destroy()
				elseif not v.r and string.find(n, "rainbow", 1, true) then
					d:Destroy()
				end
			end
		end
	end
end

local lastHookScan = 0
connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	if os.clock() - lastHookScan < 0.3 then
		return
	end
	lastHookScan = os.clock()
	local main = invGui and invGui.Main
	local pets = main and main:FindFirstChild("Pets")
	if not pets then
		return
	end
	for _, frameName in ipairs({ "Normal", "Titanic" }) do
		local frame = pets:FindFirstChild(frameName)
		if frame then
			for _, child in ipairs(frame:GetChildren()) do
				if child:IsA("GuiObject") and child.Name ~= "Empty" then
					hookHover(child.Name, child)
					local lvl = child:FindFirstChild("Level")
					if lvl and lvl:IsA("TextLabel") and not skins[child.Name] then
						local stroke = lvl:FindFirstChildOfClass("UIStroke")
						local grad = lvl:FindFirstChildOfClass("UIGradient")
						if not levelStyle.hugeStroke then
							for _, d in ipairs(child:GetDescendants()) do
								if d:IsA("TextLabel") and string.match(d.Text, "^%s*%?+%s*$") then
									local st = d:FindFirstChildOfClass("UIStroke")
									local gr = d:FindFirstChildOfClass("UIGradient")
									levelStyle.huge = d.TextColor3
									levelStyle.hugeStroke = st and st.Color or Color3.fromRGB(255, 255, 255)
									if gr then
										levelStyle.hugeGradient = gr:Clone()
									end
									break
								end
							end
						end
						if string.match(lvl.Text, "^%s*%?+%s*$") then
							levelStyle.huge = lvl.TextColor3
							levelStyle.hugeStroke = stroke and stroke.Color or levelStyle.hugeStroke
							if grad and not levelStyle.hugeGradient then
								levelStyle.hugeGradient = grad:Clone()
							end
						elseif lvl.Text ~= "" then
							levelStyle.normal = lvl.TextColor3
							levelStyle.normalStroke = stroke and stroke.Color or levelStyle.normalStroke
							levelStyle.normalHadGradient = grad ~= nil
						end
					end
				end
			end
		end
	end
end)

connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	if next(skins) == nil then
		return
	end
	local gui = invGui and invGui.Gui
	if not gui or not gui.Enabled then
		return
	end
	for uid, skinId in pairs(skins) do
		local cell = getInventoryItem(uid)
		hookHover(uid, cell)
		applyLevelText(uid, skinId, cell)
		pcall(cleanMutationFx, uid, cell)
		local icon = getInventoryIcon(uid)
		if icon then
			local cached = iconCache[uid]
			if not cached or cached.skin ~= skinId then
				cached = { skin = skinId, image = imageFor(skinnedPet(origGet(uid)), skinId) }
				iconCache[uid] = cached
			end
			if cached.image and icon.Image ~= cached.image then
				icon.Image = cached.image
			end
		end
	end
	if os.clock() - lastFxScan > 0.1 then
		lastFxScan = os.clock()
	end
end)

local function rememberName(uid, id)
	local dir = id and PetDir[id]
	if dir and type(dir.name) == "string" then
		nameHistory[uid] = nameHistory[uid] or {}
		nameHistory[uid][dir.name] = true
	end
end

----------------------------------------------------------------------
-- hover card fallback: if the game's card still shows an old name, or the wrong number of "?"
-- for strength (Huge = ???, Titanic = ????), fix the text while you hover the pet.
----------------------------------------------------------------------
local function stripTags(text)
	return (string.gsub(text, "<[^>]+>", ""))
end

local function isReallyVisible(obj)
	local cur = obj
	while cur and cur ~= PlayerGui do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("ScreenGui") and not cur.Enabled then
			return false
		end
		cur = cur.Parent
	end
	return cur == PlayerGui
end

local trackedLabels = {} -- { label = TextLabel, kind = "strength"|"name", old = string }
local lastScan = 0

local function scanTooltip(uid, skinId)
	trackedLabels = {}
	local real = origGet(uid)
	if not real then
		return
	end
	skinId = skinId or real.id
	local isSkinned = skins[uid] ~= nil
	local skinDir = PetDir[skinId]
	if not skinDir then
		return
	end
	local names = nameHistory[uid] or {}
	rememberName(uid, real.id)
	names = nameHistory[uid]
	names[skinDir.name] = nil -- the current name is never "stale"

	for _, d in ipairs(PlayerGui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text ~= "" and not d:FindFirstAncestor("PetSkinsGui") then
			local plain = stripTags(d.Text)
			if string.match(plain, "^%s*%?+%s*$") then
				if isSkinned and isReallyVisible(d) and (skinDir.huge or skinDir.titanic) then
					trackedLabels[#trackedLabels + 1] = { label = d, kind = "strength" }
				end
			elseif plain ~= skinDir.name and isReallyVisible(d) then
				for old in pairs(names) do
					if plain == old or (#plain > #old and string.sub(plain, -#old - 1) == " " .. old) then
						trackedLabels[#trackedLabels + 1] = { label = d, kind = "name", old = old }
						break
					end
				end
				-- already the skin's name but with a wrong mutation prefix ("Rainbow Egg")
				local nm = skinDir.name
				if isSkinned and variants[uid] and #plain > #nm and string.sub(plain, -#nm - 1) == " " .. nm then
					trackedLabels[#trackedLabels + 1] = { label = d, kind = "name", old = nm }
				end
			end
		end
	end
end

connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	local uid = hoveredUid
	local skinId = uid and skins[uid]
	if not uid or not (skinId or nameHistory[uid]) then
		if #trackedLabels > 0 then
			trackedLabels = {}
		end
		return
	end
	local gui2 = invGui and invGui.Gui
	if not gui2 or not gui2.Enabled then
		hoveredUid = nil
		trackedLabels = {}
		return
	end
	local hoverItem = getInventoryItem(uid)
	if not hoverItem or not hoverItem.Parent then
		hoveredUid = nil
		trackedLabels = {}
		return
	end
	if UserInputService.MouseEnabled then
		local mp = UserInputService:GetMouseLocation()
		local pos, size = hoverItem.AbsolutePosition, hoverItem.AbsoluteSize
		local inset = GuiService:GetGuiInset()
		local function inside(x, y)
			return x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y
		end
		if not (inside(mp.X, mp.Y) or inside(mp.X - inset.X, mp.Y - inset.Y)) then
			hoveredUid = nil
			trackedLabels = {}
			return
		end
	end
	if os.clock() - lastScan > 0.1 then
		lastScan = os.clock()
		pcall(scanTooltip, uid, skinId)
	end
	if #trackedLabels == 0 then
		return
	end
	local targetId = skinId
	if not targetId then
		local realPet = origGet(uid)
		targetId = realPet and realPet.id
	end
	local skinDir = targetId and PetDir[targetId]
	if not skinDir then
		return
	end
	local wantMarks = skinDir.titanic and 4 or (skinDir.huge and 3 or nil)
	for _, t in ipairs(trackedLabels) do
		local label = t.label
		if label.Parent then
			if t.kind == "strength" then
				-- Huge pets show "???", Titanic pets show "????" (same as the game does for real ones)
				if wantMarks and stripTags(label.Text):match("^%s*%?+%s*$") then
					local fixed = string.gsub(label.Text, "%?+", string.rep("?", wantMarks), 1)
					if label.Text ~= fixed then
						label.Text = fixed
					end
				end
			else
				local old = t.old
				local text = label.Text
				if old and string.sub(text, -#old) == old then
					local prefix = string.sub(text, 1, #text - #old)
					local want = variants[uid]
					if want then
						-- the card shows the REAL pet's mutation ("Rainbow ..."): swap it for the chosen look
						for _, w in ipairs({ "Dark Matter", "Golden", "Rainbow", "Shiny" }) do
							prefix = string.gsub(prefix, w .. " ?", "")
						end
						prefix = (want.sh and "Shiny " or "") .. (want.g and "Golden " or "")
							.. (want.r and "Rainbow " or "") .. (want.dm and "Dark Matter " or "") .. prefix
					end
					label.Text = prefix .. skinDir.name
				end
			end
		end
	end
end)

----------------------------------------------------------------------
-- LOCAL GIFT / EXCLUSIVE EGG OPENING
-- If the skin you picked for a pet is a gift / exclusive egg (Directory.Pets[skin].isGift),
-- clicking that pet in the inventory plays the game's own exclusive egg animation locally.
-- The pet that "drops" is rolled on your side and is fake: nothing is sent to the server,
-- nothing is added to your save.
----------------------------------------------------------------------
local Network = Library.Network
local fakeUids = {} -- [uid] = true, uids of the fake pets that only exist for the animation
local giftOpening = false
local ANIM_REMOTE = "Exclusive Eggs: Animation"

do
	local savedNet = ENV.__PetSkinsNetOrig
	if savedNet then -- previous run died: put the real functions back first
		if savedNet.Invoke then trySet(Network, "Invoke", savedNet.Invoke) end
		if savedNet.Fire then trySet(Network, "Fire", savedNet.Fire) end
	else
		ENV.__PetSkinsNetOrig = { Invoke = Network.Invoke, Fire = Network.Fire }
	end
end

local origNetInvoke = Network.Invoke
local origNetFire = Network.Fire

-- the animation script asks the server to equip the "new" pet at the end and may send
-- "Lucky" clicks: for fake pets we swallow those calls so the server never sees fake uids
local suppressEquipUntil = 0 -- set when the picker opens: a click that opened it must never equip the real pet

local function hookedNetInvoke(name, uid, ...)
	if not unloaded and suppressEquipUntil > os.clock() and (name == "Equip Pet" or name == "Unequip Pet") then
		return false, "Skin picker"
	end
	if not unloaded and type(uid) == "string" and fakeUids[uid] then
		return false, "local"
	end
	return origNetInvoke(name, uid, ...)
end

local function hookedNetFire(name, uid, ...)
	if not unloaded and type(uid) == "string" and fakeUids[uid] then
		return
	end
	return origNetFire(name, uid, ...)
end

local netInvokeHooked = trySet(Network, "Invoke", hookedNetInvoke)
local netFireHooked = trySet(Network, "Fire", hookedNetFire)

local function notify(text)
	pcall(function()
		Library.Message.New(tostring(text))
	end)
end

local function isGiftSkin(skinId)
	local dir = skinId and PetDir[skinId]
	return dir ~= nil and dir.isGift == true
end

-- which egg does this gift open? (the exact field is not visible in the decompiled scripts,
-- so try the likely ones and print what the gift entry contains if nothing matches)
local EggDir = Library.Directory.Eggs
local function resolveEggId(giftId)
	local dir = PetDir[giftId]
	if not dir then
		return nil
	end
	for _, key in ipairs({ "giftEggId", "eggId", "egg", "eggName", "exclusiveEgg", "exclusiveEggId", "opensInto", "container", "parentEgg" }) do
		local v = dir[key]
		if type(v) == "string" and EggDir[v] then
			return v
		end
	end
	if EggDir[giftId] then
		return tostring(giftId)
	end
	if type(dir.name) == "string" then
		local base = dir.name
		for _, cand in ipairs({ base, (string.gsub(base, "%s*[Gg]ift$", "")), (string.gsub(base, "^[Gg]ift%s*", "")) }) do
			if EggDir[cand] then
				return cand
			end
		end
	end
	local want = type(dir.giftEggId) == "string" and dir.giftEggId or dir.name
	if type(want) == "string" then
		local norm = string.lower((string.gsub(want, "[%s%p]", "")))
		for eggId, egg in pairs(EggDir) do
			local n1 = string.lower((string.gsub(tostring(eggId), "[%s%p]", "")))
			local n2 = type(egg) == "table" and type(egg.name) == "string"
				and string.lower((string.gsub(egg.name, "[%s%p]", ""))) or nil
			if n1 == norm or n2 == norm then
				return tostring(eggId)
			end
		end
	end
	-- any egg whose entry points at this gift
	for eggId, egg in pairs(EggDir) do
		if type(egg) == "table" then
			for _, v in pairs(egg) do
				if v == giftId then
					return tostring(eggId)
				end
			end
		end
	end
	return nil
end

local function dumpGift(giftId)
	local dir = PetDir[giftId]
	local keys = {}
	if dir then
		for k, v in pairs(dir) do
			if type(v) ~= "table" and type(v) ~= "userdata" then
				keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
			else
				keys[#keys + 1] = tostring(k) .. "=<" .. typeof(v) .. ">"
			end
		end
	end
	table.sort(keys)
	local egg = {}
	for eggId, e in pairs(EggDir) do
		if type(e) == "table" and (e.isExclusive or e.exclusive or e.isGift) then
			egg[#egg + 1] = tostring(eggId)
		end
	end
	local hint = type(dir) == "table" and dir.giftEggId
	if hint then
		local word = string.lower(string.match(tostring(hint), "%a+") or "")
		local similar = {}
		for eggId in pairs(EggDir) do
			if word ~= "" and string.find(string.lower(tostring(eggId)), word, 1, true) then
				similar[#similar + 1] = tostring(eggId)
			end
		end
	end
end

local rng = Random.new()
local rollVariant, rollDrop
local CHX = {} -- chance helpers shared with the panel (kept in one table: Luau allows max 200 locals per scope)
local settings = { global = {}, eggs = {} }
;(function() -- own function scope: keeps the main chunk under the 200 locals limit

----------------------------------------------------------------------
-- CHANCE SETTINGS (local egg / gift opening only)
-- settings.global applies to ALL eggs; settings.eggs[eggId] overrides single fields for one egg.
-- A field that is nil = "game default". Edit them in the "Chances" panel (button at the left of the screen).
--   luck   : x multiplier for rare pets inside the egg (1 = normal, 5 = much rarer pets, 1000 = almost all equal)
--   g/r/sh/dm : percent chance for Golden / Rainbow / Shiny / Dark Matter (100 = always)
--   fav    : pet name or id you want to get, favPct : percent chance that exactly this pet drops
----------------------------------------------------------------------
local SETTINGS_FILE = "PetSkinChances.json"
local FIELDS = { "luck", "g", "r", "sh", "dm", "fav", "favPct" }

local function cleanCfg(src)
	local out = {}
	if type(src) == "table" then
		for _, k in ipairs(FIELDS) do
			local v = src[k]
			if k == "fav" then
				if type(v) == "string" and v ~= "" then
					out[k] = v
				end
			elseif type(v) == "number" then
				out[k] = v
			end
		end
	end
	return out
end

local function loadSettings()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		return
	end
	local ok, data = pcall(function()
		if isfile(SETTINGS_FILE) then
			return HttpService:JSONDecode(readfile(SETTINGS_FILE))
		end
	end)
	if ok and type(data) == "table" then
		settings.global = cleanCfg(data.global)
		if type(data.eggs) == "table" then
			for eggId, c in pairs(data.eggs) do
				settings.eggs[tostring(eggId)] = cleanCfg(c)
			end
		end
	end
end

local function saveSettings()
	if type(writefile) ~= "function" then
		return
	end
	pcall(function()
		writefile(SETTINGS_FILE, HttpService:JSONEncode(settings))
	end)
end

loadSettings()

-- effective settings for one egg: per-egg override first, then global, then nil (= game default)
local function effectiveCfg(eggId)
	local ov = eggId and settings.eggs[eggId] or {}
	local out = {}
	for _, k in ipairs(FIELDS) do
		if ov[k] ~= nil then
			out[k] = ov[k]
		else
			out[k] = settings.global[k]
		end
	end
	return out
end

local petLookup = {}
local function resolvePetId(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	if PetDir[text] then
		return text
	end
	local key = string.lower(text)
	if petLookup[key] ~= nil then
		return petLookup[key] or nil
	end
	local found
	for id, dir in pairs(PetDir) do
		local n = type(dir) == "table" and type(dir.name) == "string" and string.lower(dir.name) or nil
		if string.lower(tostring(id)) == key or n == key then
			found = tostring(id)
			break
		end
	end
	petLookup[key] = found or false
	return found
end

-- variant chances come from the egg itself: goldenChance / rainbowChance are PERCENTS (10 = 10%).
-- shiny has no field in the egg module, so it uses this default (percent). Your settings override all of them.
local SHINY_PERCENT = 0.1
function rollVariant(eggId)
	local egg = EggDir[eggId]
	local cfg = effectiveCfg(eggId)
	local gc = cfg.g or (type(egg) == "table" and tonumber(egg.goldenChance)) or 0
	local rc = cfg.r or (type(egg) == "table" and tonumber(egg.rainbowChance)) or 0
	local dc = cfg.dm or 0
	local sc = cfg.sh or SHINY_PERCENT
	local v = {}
	local x = rng:NextNumber(0, 100)
	if x < dc then
		v.dm = true
	elseif x < dc + rc then
		v.r = true
	elseif x < dc + rc + gc then
		v.g = true
	end
	if rng:NextNumber(0, 100) < sc then
		v.sh = true
	end
	return v
end

-- weighted roll from the egg's drop table: drops = { {petId, weight, hardcoreOnly?}, ... }
function rollDrop(eggId)
	local egg = EggDir[eggId]
	local cfg = effectiveCfg(eggId)

	-- favourite pet: with favPct percent it drops no matter what the egg contains
	if cfg.fav and (cfg.favPct or 0) > 0 then
		local fid = resolvePetId(cfg.fav)
		if fid and rng:NextNumber(0, 100) < cfg.favPct then
			return fid, math.clamp(cfg.favPct, 0, 100) / 100
		end
	end

	local drops = egg and egg.drops
	if type(drops) == "string" then
		drops = EggDir[drops] and EggDir[drops].drops
	end
	if type(drops) ~= "table" then
		return nil
	end
	local total = 0
	local pool = {}
	local maxW = 0
	for _, d in ipairs(drops) do
		if type(d) == "table" and PetDir[d[1]] and type(d[2]) == "number" and d[2] > 0 and not d[3] then
			pool[#pool + 1] = { d[1], d[2] }
			maxW = math.max(maxW, d[2])
		end
	end
	-- luck: pulls every weight towards the most common one, so rare pets become more likely
	local luck = math.max(tonumber(cfg.luck) or 1, 1)
	for _, d in ipairs(pool) do
		if luck > 1 then
			d[2] = d[2] * (maxW / d[2]) ^ (1 - 1 / luck)
		end
		total = total + d[2]
	end
	if total <= 0 then
		return nil
	end
	local pick = rng:NextNumber(0, total)
	local acc = 0
	for _, d in ipairs(pool) do
		acc = acc + d[2]
		if pick <= acc then
			return tostring(d[1]), d[2] / total
		end
	end
	local last = pool[#pool]
	return tostring(last[1]), last[2] / total
end

CHX.FIELDS, CHX.save, CHX.eff, CHX.resolve = FIELDS, saveSettings, effectiveCfg, resolvePetId
CHX.SHINY = SHINY_PERCENT
end)()

-- spots on the ground in a ring around the player (like the game's own computePositions:
-- the first egg is right in front of the character, the rest are spread evenly around)
local activeRadii = {}
local ringRadius = 0
local lastFlats = {}
local function localPositions(count)
	local char = LocalPlayer.Character
	local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
	if not root then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local Sh = Library.Shared
	local spacing = tonumber(Sh.ExclusiveEggSpacingRadius) or 4
	local range = Sh.ExclusiveEggRadiusRange
	local minR = (typeof(range) == "Vector2" and range.X or 0) + spacing
	local maxHeight = tonumber(Sh.ExclusiveEggMaxHeight) or 30
	local heightOffset = tonumber(Sh.ExclusiveEggHeightOffset) or 5

	-- ring radius: big enough that neighbouring eggs are at least 2 * spacing apart
	local radius = minR
	if count > 1 then
		radius = math.max(minR, (2 * spacing) / (2 * math.sin(math.pi / count)))
	end

	local pivot = char:GetPivot()
	local look = pivot.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)

	-- flat (x,z) spots of every egg that is still opening (world space, so walking away does not break it)
	local busy = {}
	for _, flats in pairs(activeRadii) do
		for _, p in ipairs(flats) do
			busy[#busy + 1] = p
		end
	end
	local minDist = 2 * spacing
	local function spotsAt(r, off)
		local spots = {}
		for i = 1, count do
			local angle = off + (i - 1) * (2 * math.pi / count)
			local dir = CFrame.Angles(0, -angle, 0):VectorToWorldSpace(look)
			local flat = root.Position + dir * r
			for _, b in ipairs(busy) do
				if (Vector3.new(flat.X, 0, flat.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude < minDist then
					return nil
				end
			end
			spots[i] = flat
		end
		return spots
	end
	-- smallest circle (still a proper circle) where this whole batch fits without touching eggs that are still opening
	local flatSpots
	for _ = 1, 80 do
		-- same circle, rotated a bit: free gaps between earlier eggs get reused before growing the radius
		for k = 0, 11 do
			flatSpots = spotsAt(radius, k * (2 * math.pi / 12) / math.max(count, 1))
			if flatSpots then
				break
			end
		end
		if flatSpots then
			break
		end
		radius = radius + spacing * 0.5
	end
	if not flatSpots then
		flatSpots = {}
		for i = 1, count do
			local angle = (i - 1) * (2 * math.pi / count)
			flatSpots[i] = root.Position + CFrame.Angles(0, -angle, 0):VectorToWorldSpace(look) * radius
		end
	end
	ringRadius = radius
	lastFlats = flatSpots

	local feetY = root.Position.Y - ((hum and hum.HipHeight or 2) + root.Size.Y / 2)

	-- ground raycast against the map when possible, otherwise everything except the character
	local params = RaycastParams.new()
	params.IgnoreWater = false
	params.RespectCanCollide = false
	local okMap, map = pcall(function()
		return Library.WorldCmds.GetMap()
	end)
	local comets = Library.Things and Library.Things:FindFirstChild("Comets")
	if okMap and typeof(map) == "Instance" then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { map, comets }
	else
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
	end

	local out = {}
	for i = 1, count do
		local flat = flatSpots[i]
		local from = Vector3.new(flat.X, root.Position.Y + heightOffset, flat.Z)
		local hit = workspace:Raycast(from, Vector3.new(0, -(maxHeight + heightOffset), 0), params)
		out[i] = hit and hit.Position or Vector3.new(flat.X, feetY, flat.Z)
	end
	return out, root.Position
end

-- find the game's own performOpen (global function of the Exclusive Eggs script) in memory
local performOpenFn = nil
local function findPerformOpen()
	if performOpenFn then
		return performOpenFn
	end
	if type(getgc) ~= "function" then
		return nil
	end
	local ok, gc = pcall(getgc, true)
	if not ok or type(gc) ~= "table" then
		return nil
	end
	local best, any = nil, nil
	for _, f in ipairs(gc) do
		if type(f) == "function" then
			local name
			pcall(function()
				name = debug.info(f, "n")
			end)
			if name == "performOpen" then
				any = any or f
				local scr
				pcall(function()
					scr = getfenv(f).script
				end)
				if typeof(scr) == "Instance" and string.find(string.lower(scr:GetFullName()), "exclusive", 1, true) then
					best = f
					break
				end
			end
		end
	end
	performOpenFn = best or any
	return performOpenFn
end

-- fire the game's own "Exclusive Eggs: Animation" handler with our fake data
local function fireAnimation(...)
	local args = table.pack(...)
	local errors = {}

	-- 1) call performOpen directly (most reliable)
	local fn = findPerformOpen()
	if fn then
		task.spawn(function()
			local okc, errc = xpcall(fn, debug.traceback, table.unpack(args, 1, args.n))
			if not okc then
			end
		end)
		return true
	end
	errors[#errors + 1] = "performOpen not found in memory"

	local net = ReplicatedStorage:FindFirstChild("Network")
	local remote = net and net:FindFirstChild(ANIM_REMOTE)
	if remote and remote:IsA("RemoteEvent") then
		if type(firesignal) == "function" then
			local ok, err = pcall(firesignal, remote.OnClientEvent, table.unpack(args, 1, args.n))
			if ok then
				return true
			end
			errors[#errors + 1] = "firesignal: " .. tostring(err)
		end
		if type(getconnections) == "function" then
			local ok, conns = pcall(getconnections, remote.OnClientEvent)
			if ok and type(conns) == "table" and #conns > 0 then
				local fired = false
				for _, c in ipairs(conns) do
					local okc = pcall(function()
						if c.Fire then
							c:Fire(table.unpack(args, 1, args.n))
						elseif c.Function then
							task.spawn(c.Function, table.unpack(args, 1, args.n))
						end
					end)
					fired = fired or okc
				end
				if fired then
					return true
				end
			end
			errors[#errors + 1] = "getconnections: nothing to fire"
		end
	else
		errors[#errors + 1] = "remote not found in ReplicatedStorage.Network"
	end

	-- last resort: the game's Network.Fired object may be fireable itself
	local okSig, sig = pcall(Network.Fired, ANIM_REMOTE)
	if okSig and sig then
		if typeof(sig) == "RBXScriptSignal" and type(firesignal) == "function" then
			if pcall(firesignal, sig, table.unpack(args, 1, args.n)) then
				return true
			end
		elseif type(sig) == "table" and type(sig.Fire) == "function" then
			if pcall(sig.Fire, sig, table.unpack(args, 1, args.n)) then
				return true
			end
		end
	end
	return false, table.concat(errors, "; ")
end

-- own confirmation dialog (the game's Message.New did not show up for us)
local function askAmount(amounts)
	local result, done = nil, false
	local dlg = Instance.new("ScreenGui")
	dlg.Name = "PetSkinsGiftDialog"
	dlg.ResetOnSpawn = false
	dlg.DisplayOrder = 1000
	dlg.IgnoreGuiInset = true
	dlg.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(340, 60 + #amounts * 40 + 44)
	frame.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
	frame.BorderSizePixel = 0
	frame.Parent = dlg
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 50)
	title.Position = UDim2.fromOffset(10, 6)
	title.Text = "Are you sure you want to open this?\n(local only)"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextWrapped = true
	title.Parent = frame

	local function addButton(text, y, color, value)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -40, 0, 34)
		b.Position = UDim2.fromOffset(20, y)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 15
		b.Parent = frame
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = b
		b.Activated:Connect(function()
			result = value
			done = true
		end)
	end

	for i, a in ipairs(amounts) do
		addButton("Open " .. a, 60 + (i - 1) * 40, Color3.fromRGB(60, 160, 80), i)
	end
	addButton("Cancel", 60 + #amounts * 40, Color3.fromRGB(200, 60, 60), nil)

	while not done and not unloaded and dlg.Parent do
		task.wait(0.1)
	end
	pcall(function()
		dlg:Destroy()
	end)
	return result
end

local function openGiftLocal(uid)
	if unloaded then
		return
	end
	local giftId = skins[uid]
	if not isGiftSkin(giftId) then
		return
	end
	local eggId = resolveEggId(giftId)
	if not eggId then
		dumpGift(giftId)
		return
	end

	-- all open amounts the game offers (1 / 3 / 10 ...), no cap: it is local anyway
	local amounts = {}
	local src = Library.Shared.ExclusiveEggOpenAmounts
	if type(src) ~= "table" or #src == 0 then
		src = { 1, 3, 10 }
	end
	for _, a in ipairs(src) do
		amounts[#amounts + 1] = a
	end
	local choice
	local okMsg, resMsg = pcall(function()
		if #amounts == 1 then
			return Library.Message.New("Are you sure you want to open this?", true) and 1 or nil
		end
		local labels = {}
		for _, a in ipairs(amounts) do
			labels[#labels + 1] = "Open " .. a
		end
		return Library.Message.New("Are you sure you want to open this?", table.unpack(labels))
	end)
	if okMsg then
		choice = resMsg
	else
		choice = askAmount(amounts)
	end
	if not choice then
		return
	end
	local amount = amounts[choice] or 1

	local positions, origin = localPositions(amount)
	if not positions then
		return
	end

	local petDatas, chances = {}, {}
	for i = 1, amount do
		local petId, chance = rollDrop(eggId)
		if not petId then
			return
		end
		local fake = "local_" .. HttpService:GenerateGUID(false)
		fakeUids[fake] = true
		local pd = { id = petId, uid = fake }
		for k, val in pairs(rollVariant(eggId)) do
			pd[k] = val
		end
		petDatas[i] = pd
		chances[i] = chance
	end

	local ringId = {}
	activeRadii[ringId] = lastFlats
	giftOpening = true
	pcall(function()
		invGui.Gui.Enabled = false
		Library.Variables.GuiThatWasEnabled = nil
	end)

	local ok, err = fireAnimation(LocalPlayer, origin, eggId, petDatas, positions, chances)
	if not ok then
		activeRadii[ringId] = nil
		giftOpening = false
		pcall(function()
			invGui.Gui.Enabled = true
		end)
		return
	end

	-- animation is over when the game's OpeningEgg counter is back to 0
	task.spawn(function()
		local started = os.clock()
		task.delay(5, function()
			if giftOpening and (Library.Variables.OpeningEgg or 0) <= 0 then
			end
		end)
		repeat
			task.wait(0.05)
		until unloaded or (os.clock() - started > 0.5 and (Library.Variables.OpeningEgg or 0) <= 0) or os.clock() - started > 90
		-- keep the ring reserved a bit longer so the next eggs never land inside it
		task.wait(4)
		activeRadii[ringId] = nil
		giftOpening = next(activeRadii) ~= nil
		task.delay(10, function()
			for _, pd in ipairs(petDatas) do
				fakeUids[pd.uid] = nil
			end
		end)
	end)
end

-- invisible button over the inventory cell of a pet whose skin is a gift: it swallows the click
-- (so the real pet is not equipped / unequipped) and opens the gift locally instead
local function shiftHeld()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local OVERLAY = "PetSkinsGiftClick"

local function syncGiftOverlays()
	for uid, skinId in pairs(skins) do
		local cell = getInventoryItem(uid)
		if cell and cell:IsA("GuiObject") then
			local overlay = cell:FindFirstChild(OVERLAY)
			if isGiftSkin(skinId) then
				if not overlay then
					local btn = Instance.new("TextButton")
					btn.Name = OVERLAY
					btn.BackgroundTransparency = 1
					btn.Text = ""
					btn.Size = UDim2.fromScale(1, 1)
					btn.ZIndex = 100
					btn.AutoButtonColor = false
					btn.Parent = cell
					btn.Activated:Connect(function()
						if skins[uid] and isGiftSkin(skins[uid]) then
							task.spawn(function()
								local ok, err = xpcall(openGiftLocal, debug.traceback, uid)
								if not ok then
									giftOpening = false
								end
							end)
						end
					end)
				end
			elseif overlay then
				overlay:Destroy()
			end
		end
	end
end

local function clearGiftOverlays()
	local pets = invGui and invGui.Main and invGui.Main:FindFirstChild("Pets")
	if not pets then
		return
	end
	for _, d in ipairs(pets:GetDescendants()) do
		if d.Name == OVERLAY then
			pcall(function()
				d:Destroy()
			end)
		end
	end
end

local lastOverlaySync = 0
connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	if os.clock() - lastOverlaySync < 0.25 then
		return
	end
	lastOverlaySync = os.clock()
	if next(skins) == nil then
		return
	end
	local g = invGui and invGui.Gui
	if not g or not g.Enabled then
		return
	end
	pcall(syncGiftOverlays)
end)

----------------------------------------------------------------------
-- apply / reset
----------------------------------------------------------------------
local function applySkin(uid, skinId, variant)
	if not changerOn then
		return
	end
	rememberName(uid, skins[uid])
	local real = origGet(uid)
	rememberName(uid, real and real.id)
	skins[uid] = tostring(skinId)
	variants[uid] = variant or {}
	iconCache[uid] = nil
	saveSkins()
	saveVariants()
	respawn(uid)
	rebuildItem(uid)
end

local function resetSkin(uid)
	if not changerOn then
		return
	end
	rememberName(uid, skins[uid])
	skins[uid] = nil
	variants[uid] = nil
	saveSkins()
	saveVariants()
	restoreIcon(uid)
	respawn(uid)
end

local function resetAll()
	if not changerOn then
		return
	end
	local list = {}
	for uid in pairs(skins) do
		list[#list + 1] = uid
	end
	for _, uid in ipairs(list) do
		rememberName(uid, skins[uid])
		skins[uid] = nil
		variants[uid] = nil
		restoreIcon(uid)
		respawn(uid)
		rebuildItem(uid)
	end
	saveSkins()
	saveVariants()
end

----------------------------------------------------------------------
-- SKIN PICKER: lives inside the game's own inventory window (no windows / buttons of its own)
----------------------------------------------------------------------
local CHUNK = 150 -- cells created per step while scrolling (keeps 1000+ pets smooth)
local ACTIVE_RENAME_IMAGE = "rbxassetid://6958936267"

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

-- nothing is created at start. The small hover label for the picker is built when the picker opens
-- and destroyed again when it closes.
local tipGui, tip = nil, nil

local function ensureTip()
	if tip and tip.Parent then
		return
	end
	tipGui = new("ScreenGui", {
		Name = "PetSkinsGui",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1002,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, PlayerGui)
	-- hover card in the style of the game's own pet card: light rounded card, big title, pills
	tip = new("Frame", {
		Name = "Tip",
		Visible = false,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(240, 0),
		BackgroundColor3 = Color3.fromRGB(236, 236, 240),
		BorderSizePixel = 0,
		ZIndex = 10,
	}, tipGui)
	new("UICorner", { CornerRadius = UDim.new(0, 16) }, tip)
	new("UIStroke", {
		Color = Color3.fromRGB(190, 165, 255),
		Thickness = 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, tip)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, tip)
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 6),
	}, tip)
end

local function destroyTip()
	if tipGui then
		pcall(function()
			tipGui:Destroy()
		end)
	end
	tipGui, tip = nil, nil
end

local picker = {
	open = false,
	uid = nil,
	scroll = nil,
	sections = nil, -- { normal = {frame, list, rendered}, titanic = {...} }
	prevQuery = "",
	prevCanvas = Vector2.new(),
	ignoreUntil = 0,
	label = "",
	conns = {},
	token = 0,
	lastGridSync = 0,
}
local closePicker -- forward declaration

local function getPetsFrame()
	local ok, pets = pcall(function()
		return invGui.Main.Pets
	end)
	if ok and typeof(pets) == "Instance" then
		return pets
	end
	return nil
end

local function getQueryBox()
	local ok, q = pcall(function()
		return invGui.Query
	end)
	if ok and typeof(q) == "Instance" and q:IsA("TextBox") then
		return q
	end
	local ok2, q2 = pcall(function()
		return invGui.Frame.Bottom.Search.Query
	end)
	if ok2 and typeof(q2) == "Instance" and q2:IsA("TextBox") then
		return q2
	end
	return nil
end

local function inventoryOpen()
	local ok, res = pcall(function()
		return invGui.Gui.Enabled
	end)
	return ok and res == true
end

-- delete / lock / rename modes of the game: a click there must keep its normal meaning
local function inSpecialMode()
	local ok, res = pcall(function()
		local b = invGui.Bottom
		if b.VerifyDelete.Visible or b.VerifyLock.Visible then
			return true
		end
		return b.Rename.Image == ACTIVE_RENAME_IMAGE
	end)
	return ok and res == true
end

local function refreshInventory(uid)
	local real = uid and origGet(uid)
	pcall(function()
		Library.Signal.Fire("Lock Changed", uid, real and real.l)
	end)
end

-- every pet of the game, strongest first (like the inventory's own sort); built once
local catalog = nil
-- picker order: Titanic > Huge > Exclusive > Eggs (gift / exclusive-egg pets) > Event > Secret > Mythical >
-- Legendary > Epic > Rare > Basic. Inside one group: strongest first, then by name. Edit RARITY_ORDER to reorder.
local RARITY_ORDER = {
	exclusive = 3,
	event = 5,
	secret = 6,
	mythical = 7,
	mythic = 7,
	legendary = 8,
	epic = 9,
	rare = 10,
	basic = 11,
	common = 11,
}
local TIER_EGGS = 4
local TIER_UNKNOWN = 12

local function tierOf(e)
	if e.titanic then
		return 1
	end
	if e.huge then
		return 2
	end
	if e.gift or string.find(e.rarity, "egg", 1, true) then
		return TIER_EGGS
	end
	return RARITY_ORDER[e.rarity] or TIER_UNKNOWN
end

local function buildCatalog()
	if catalog then
		return catalog
	end
	catalog = {}
	for id, dir in pairs(PetDir) do
		if type(dir) == "table" and type(dir.name) == "string" then
			local strength = -1
			if type(origStrength) == "function" then
				local ok, v = pcall(origStrength, { id = tostring(id), uid = "skin_preview" })
				if ok and type(v) == "number" and v == v then
					strength = v
				end
			end
			catalog[#catalog + 1] = {
				id = tostring(id),
				name = dir.name,
				lower = string.lower(dir.name),
				rarity = string.lower(tostring(dir.rarity or "")),
				rarityName = tostring(dir.rarity or ""), -- as written in Directory (shown in the tip)
				titanic = dir.titanic == true,
				huge = dir.huge == true,
				gift = dir.isGift == true,
				strength = strength,
			}
		end
	end
	for _, e in ipairs(catalog) do
		e.tier = tierOf(e)
	end
	table.sort(catalog, function(a, b)
		if a.tier ~= b.tier then
			return a.tier < b.tier
		end
		if a.strength ~= b.strength then
			return a.strength > b.strength
		end
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.id < b.id
	end)
	return catalog
end

local function matches(entry, q)
	if q == "" then
		return true
	end
	if string.find(entry.lower, q, 1, true) or string.find(entry.rarity, q, 1, true) then
		return true
	end
	if entry.huge and string.find("huge", q, 1, true) then
		return true
	end
	if entry.titanic and string.find("titanic", q, 1, true) then
		return true
	end
	if entry.gift and (string.find("gift", q, 1, true) or string.find("exclusive", q, 1, true)) then
		return true
	end
	return false
end

local template = nil
do
	local ok, t = pcall(function()
		return Library.Assets.UI.Inventory.Pet
	end)
	if ok and typeof(t) == "Instance" then
		template = t
	end
end

local function styleLevel(lvl, marks)
	if not (lvl and lvl:IsA("TextLabel")) then
		return
	end
	if not marks then
		lvl.Visible = false
		return
	end
	lvl.Visible = true
	lvl.Text = string.rep("?", marks)
	lvl.TextColor3 = levelStyle.huge or Color3.fromRGB(245, 235, 255)
	local stroke = lvl:FindFirstChildOfClass("UIStroke")
	if stroke then
		local outline = LIGHT_PURPLE
		local sampled = levelStyle.hugeStroke
		if sampled then
			local _, sat = sampled:ToHSV()
			if sat > 0.2 then
				outline = sampled
			end
		end
		stroke.Color = outline
	end
end

local escapeRich
local tipCurrent = nil

local function shade(c, mul)
	local h, sat, v = c:ToHSV()
	return Color3.fromHSV(h, sat, math.clamp(v * mul, 0, 1))
end

local function fmtNumber(n)
	local suffixes = { "", "k", "m", "b", "t", "qd", "qn", "sx", "sp", "oc", "no", "dc" }
	local i = 1
	while n >= 1000 and i < #suffixes do
		n = n / 1000
		i = i + 1
	end
	local str = string.format("%.2f", n)
	str = string.gsub(str, "%.?0+$", "")
	return str .. suffixes[i]
end

local function tipPill(text, color, order)
	local pill = new("TextLabel", {
		Name = "Pill",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.FredokaOne,
		TextSize = 20,
		LayoutOrder = order,
		ZIndex = 11,
	}, tip)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, pill)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	}, pill)
	new("UIStroke", { Color = shade(color, 0.8), Thickness = 2 }, pill)
	return pill
end

local function showTip(data)
	ensureTip()
	tipCurrent = data
	for _, c in ipairs(tip:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local base = data.rarityColor or Color3.fromRGB(160, 100, 255)
	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	local title = new("TextLabel", {
		Name = "Title",
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		Text = data.name,
		TextWrapped = true,
		TextColor3 = base,
		Font = Enum.Font.FredokaOne,
		TextSize = 28,
		LayoutOrder = nextOrder(),
		ZIndex = 11,
	}, tip)
	new("UIStroke", { Color = shade(base, 1.0):Lerp(Color3.new(1, 1, 1), 0.55), Thickness = 1.5 }, title)

	if data.prefix then
		title.Text = data.prefix .. data.name
	end
	if data.rarity and data.rarity ~= "" then
		tipPill(data.rarity, base, nextOrder())
	end
	for _, tag in ipairs(data.tags or {}) do
		tipPill(tag[1], tag[2], nextOrder())
	end
	if data.strength then
		new("TextLabel", {
			Name = "Strength",
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			BackgroundTransparency = 1,
			RichText = true,
			TextWrapped = true,
			Text = '<font color="#ff2bd6">Strength</font> <font color="#9a9a9a">' .. escapeRich(data.strength) .. "</font>",
			Font = Enum.Font.FredokaOne,
			TextSize = 20,
			TextColor3 = Color3.new(1, 1, 1),
			LayoutOrder = nextOrder(),
			ZIndex = 11,
		}, tip)
	end
	if data.extra then
		new("TextLabel", {
			Name = "Extra",
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			BackgroundTransparency = 1,
			TextWrapped = true,
			Text = data.extra,
			Font = Enum.Font.FredokaOne,
			TextSize = 16,
			TextColor3 = Color3.fromRGB(150, 150, 150),
			LayoutOrder = nextOrder(),
			ZIndex = 11,
		}, tip)
	end
	tip.Visible = true
end

local function hideTip(data)
	if tip and tipCurrent == data then
		tip.Visible = false
		tipCurrent = nil
	end
end

----------------------------------------------------------------------
-- picker backgrounds: the game colours a cell's "RarityGradient" by rarity. We take that exact
-- look from (1) a real inventory cell of the same rarity, (2) a hidden cell built by the game's
-- PetUI.Create, (3) a fallback colour. One look per rarity, cached while the picker is open.
----------------------------------------------------------------------
local RARITY_COLORS = {
	basic = Color3.fromRGB(175, 175, 175),
	common = Color3.fromRGB(175, 175, 175),
	rare = Color3.fromRGB(70, 160, 255),
	epic = Color3.fromRGB(185, 85, 255),
	legendary = Color3.fromRGB(255, 175, 30),
	mythical = Color3.fromRGB(255, 70, 70),
	secret = Color3.fromRGB(70, 70, 80),
	exclusive = Color3.fromRGB(255, 90, 210),
	event = Color3.fromRGB(40, 220, 170),
}
local lookCache = {} -- [key] = { inst = RarityGradient clone, score = number }

local function rarityColor(rarityName)
	return RARITY_COLORS[string.lower(tostring(rarityName or ""))] or Color3.fromRGB(200, 200, 200)
end

local function lookKey(dir, kindToo)
	local r = string.lower(tostring(dir and dir.rarity or ""))
	if not kindToo then
		return r
	end
	return r .. "|" .. ((dir.titanic and "titanic") or (dir.huge and "huge") or "")
end

local function lookSignature(rg)
	local parts = {}
	for _, o in ipairs(rg:GetDescendants()) do
		if o:IsA("UIGradient") then
			parts[#parts + 1] = tostring(o.Color) .. tostring(o.Rotation)
		end
	end
	pcall(function() parts[#parts + 1] = tostring(rg.BackgroundColor3) end)
	pcall(function() parts[#parts + 1] = tostring(rg.ImageColor3) .. tostring(rg.Image) end)
	for _, o in ipairs(rg:GetChildren()) do
		if o:IsA("UIGradient") then
			parts[#parts + 1] = tostring(o.Color)
		end
	end
	return table.concat(parts, ";")
end

local templateSig = nil
local function getTemplateSig()
	if templateSig == nil then
		templateSig = false
		local rg = template and template:FindFirstChild("RarityGradient")
		if rg then
			templateSig = lookSignature(rg)
		end
	end
	return templateSig
end

local function putLook(key, rg, score)
	local have = lookCache[key]
	if have and have.score >= score then
		return
	end
	local ok, c = pcall(function()
		return rg:Clone()
	end)
	if ok and c then
		lookCache[key] = { inst = c, score = score }
	end
end

-- read the backgrounds the game already drew on the real inventory cells
local function sampleRealLooks()
	local pets = getPetsFrame()
	if not pets then
		return
	end
	local tSig = getTemplateSig()
	for _, secName in ipairs({ "Normal", "Titanic" }) do
		local sec = pets:FindFirstChild(secName)
		for _, cell in ipairs(sec and sec:GetChildren() or {}) do
			local rg = cell.Name ~= "Empty" and cell:FindFirstChild("RarityGradient")
			if rg and not skins[cell.Name] then
				local real = origGet(cell.Name)
				local dir = real and PetDir[real.id]
				if dir and (not tSig or lookSignature(rg) ~= tSig) then
					local score = 1
					if not (real.g or real.r or real.dm or real.sh) then
						score = score + 2 -- plain pets first (no golden / rainbow tint)
					end
					if cell:GetAttribute("isVisible") ~= false then
						score = score + 1
					end
					putLook(lookKey(dir, true), rg, score + 10)
					putLook(lookKey(dir, false), rg, score)
				end
			end
		end
	end
end

local function makePreviewPet(id, pv)
	local base = picker.uid and origGet(picker.uid)
	local p = type(base) == "table" and table.clone(base) or {}
	p.uid, p.id = pv, id
	p.nk, p.g, p.r, p.dm, p.sh, p.l, p.hc, p.powers = nil, nil, nil, nil, nil, nil, nil, nil
	if type(origStrength) == "function" then
		local ok, v = pcall(origStrength, { id = id, uid = "skin_preview" })
		if ok and type(v) == "number" then
			p.s = v
		end
	end
	return p
end

-- build a hidden cell with the game's own PetUI just to read its background (no hover card shown)
local function lookFromGameUI(id)
	local pui = Library.PetUI
	if not template or type(pui) ~= "table" or type(pui.Create) ~= "function" then
		return nil
	end
	local pv = "scratch_" .. id
	scratchPets[pv] = makePreviewPet(id, pv)
	local scratch = template:Clone()
	local ok = pcall(pui.Create, scratch, pv)
	local rg = ok and scratch:FindFirstChild("RarityGradient")
	local out = nil
	if rg and lookSignature(rg) ~= getTemplateSig() then
		out = rg:Clone()
	end
	pcall(function()
		scratch:Destroy()
	end)
	return out
end

local function getLook(id)
	local dir = PetDir[id]
	if not dir then
		return nil
	end
	local exact = lookCache[lookKey(dir, true)]
	if exact then
		return exact.inst
	end
	local k = lookKey(dir, true) .. "#game"
	if lookCache[k] == nil then
		local inst = lookFromGameUI(id)
		lookCache[k] = inst and { inst = inst, score = 0 } or false
	end
	if lookCache[k] then
		return lookCache[k].inst
	end
	local any = lookCache[lookKey(dir, false)]
	return any and any.inst or nil
end

local function applyLook(cell, id)
	local old = cell:FindFirstChild("RarityGradient")
	local look = getLook(id)
	if look then
		local ok, fresh = pcall(function()
			return look:Clone()
		end)
		if ok and fresh then
			fresh.Name = "RarityGradient"
			pcall(function()
				fresh.Visible = true
			end)
			if old then
				pcall(function()
					fresh.ZIndex = old.ZIndex
				end)
				old:Destroy()
			end
			fresh.Parent = cell
			return
		end
	end
	-- fallback: tint the template background with the rarity colour
	if not old then
		return
	end
	pcall(function()
		old.Visible = true
	end)
	local dir = PetDir[id]
	local color = rarityColor(dir and dir.rarity)
	local h, sat, v = color:ToHSV()
	local dark = Color3.fromHSV(h, sat, v * 0.55)
	local grad = old:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(color, dark)
	end
	pcall(function()
		if old:IsA("ImageLabel") or old:IsA("ImageButton") then
			old.ImageColor3 = grad and Color3.new(1, 1, 1) or color
		else
			old.BackgroundColor3 = grad and Color3.new(1, 1, 1) or color
		end
	end)
end

function escapeRich(t)
	t = string.gsub(tostring(t), "&", "&amp;")
	t = string.gsub(t, "<", "&lt;")
	t = string.gsub(t, ">", "&gt;")
	return t
end

local function tipData(id, extra)
	local dir = PetDir[id]
	local data = {
		name = dir and dir.name or tostring(id),
		rarity = dir and tostring(dir.rarity or "") or "",
		rarityColor = rarityColor(dir and dir.rarity),
		tags = {},
		extra = extra,
	}
	if dir then
		if dir.titanic then
			data.tags[#data.tags + 1] = { "Titanic", Color3.fromRGB(170, 225, 20) }
		elseif dir.huge then
			data.tags[#data.tags + 1] = { "Huge", Color3.fromRGB(255, 150, 40) }
		end
		if dir.isGift then
			data.tags[#data.tags + 1] = { "Gift", Color3.fromRGB(70, 190, 255) }
		end
	end
	if type(origStrength) == "function" and not hasNoStrength(dir) then
		local ok, v = pcall(origStrength, { id = id, uid = "skin_preview" })
		if ok and type(v) == "number" and v > 0 and v == v and v < math.huge then
			data.strength = fmtNumber(v)
		end
	end
	return data
end

-- drops card for gift / egg entries: what can drop and how likely (shown next to the cursor while hovering)
local dropsCard = nil
local function fmtPct(p)
	local str
	if p >= 10 then
		str = string.format("%.1f", p)
	elseif p >= 1 then
		str = string.format("%.2f", p)
	else
		str = string.format("%.3f", p)
	end
	str = string.gsub(str, "(%.%d-)0+$", "%1")
	str = string.gsub(str, "%.$", "")
	return str .. "%"
end

local function hideDrops()
	if dropsCard then
		dropsCard.Visible = false
	end
end

local function showDrops(skinId)
	local eggId = resolveEggId(skinId)
	local egg = eggId and EggDir[eggId]
	if type(egg) ~= "table" then
		return
	end
	local src = egg.drops
	if type(src) == "string" then
		src = EggDir[src] and EggDir[src].drops
	end
	if type(src) ~= "table" then
		return
	end
	local list, total = {}, 0
	for _, d in ipairs(src) do
		if type(d) == "table" and PetDir[d[1]] and type(d[2]) == "number" and d[2] > 0 and not d[3] then
			list[#list + 1] = d
			total = total + d[2]
		end
	end
	if total <= 0 then
		return
	end
	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)

	ensureTip()
	if not (dropsCard and dropsCard.Parent) then
		dropsCard = new("Frame", {
			Name = "Drops",
			Visible = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromOffset(250, 0),
			BackgroundColor3 = Color3.fromRGB(236, 236, 240),
			BorderSizePixel = 0,
			ZIndex = 10,
		}, tipGui)
		new("UICorner", { CornerRadius = UDim.new(0, 16) }, dropsCard)
		new("UIStroke", { Color = Color3.fromRGB(70, 190, 255), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, dropsCard)
		new("UIPadding", {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}, dropsCard)
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, dropsCard)
	end
	for _, c in ipairs(dropsCard:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local order = 0
	local function line(text, color, size, align)
		order = order + 1
		new("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			BackgroundTransparency = 1,
			RichText = true,
			TextWrapped = true,
			Text = text,
			Font = Enum.Font.FredokaOne,
			TextSize = size or 16,
			TextColor3 = color or Color3.fromRGB(60, 60, 70),
			TextXAlignment = align or Enum.TextXAlignment.Left,
			LayoutOrder = order,
			ZIndex = 11,
		}, dropsCard)
	end
	line("Drops", Color3.fromRGB(70, 150, 230), 22, Enum.TextXAlignment.Center)
	local MAX = 20
	for i, d in ipairs(list) do
		if i > MAX then
			line("+" .. (#list - MAX) .. " more", Color3.fromRGB(150, 150, 150), 14, Enum.TextXAlignment.Center)
			break
		end
		local dir = PetDir[d[1]]
		local c = rarityColor(dir and dir.rarity) or Color3.fromRGB(80, 80, 90)
		local hex = string.format("#%02x%02x%02x", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
		line('<font color="' .. hex .. '">' .. escapeRich(dir and dir.name or tostring(d[1])) .. '</font>  <font color="#8a8a8a">' .. fmtPct(d[2] / total * 100) .. "</font>")
	end
	local gc, rc = tonumber(egg.goldenChance) or 0, tonumber(egg.rainbowChance) or 0
	if gc > 0 or rc > 0 then
		local parts = {}
		if gc > 0 then
			parts[#parts + 1] = '<font color="#e6b400">Golden ' .. fmtPct(gc) .. "</font>"
		end
		if rc > 0 then
			parts[#parts + 1] = '<font color="#d040c0">Rainbow ' .. fmtPct(rc) .. "</font>"
		end
		line(table.concat(parts, "   "), nil, 15, Enum.TextXAlignment.Center)
	end
	dropsCard.Visible = true
end

-- Preferred way: let the game's own hover card (InfoOverlay, same one PetUI uses) show the
-- "Contains:" block with the drop icons + percents, exactly like on a real gift.
-- We add the same two blocks PetUI adds ("Nickname" = "Contains:", "GiftPetOdds") when the cell is a gift cell.
local giftCells = setmetatable({}, { __mode = "k" }) -- [cell] = skinId
local overlayHooked = false
local function hookOverlay()
	if overlayHooked then
		return true
	end
	local ov = Library.InfoOverlay
	if type(ov) ~= "table" or type(ov.Add) ~= "function" then
		return false
	end
	local origAdd = ov.Add
	local ok = pcall(function()
		ov.Add = function(target, ...)
			local sid = giftCells[target]
			if sid then
				local okB, extra = pcall(function()
					local eggId = resolveEggId(sid)
					local egg = eggId and EggDir[eggId]
					local drops = type(egg) == "table" and egg.drops
					if type(drops) == "string" then
						drops = EggDir[drops] and EggDir[drops].drops
					end
					if type(drops) == "table" then
						return { { "Nickname", "Contains:" }, { "GiftPetOdds", eggId, drops } }
					end
				end)
				if okB and extra then
					local args = table.pack(...)
					for _, b in ipairs(extra) do
						args.n = args.n + 1
						args[args.n] = b
					end
					return origAdd(target, table.unpack(args, 1, args.n))
				end
			end
			return origAdd(target, ...)
		end
	end)
	overlayHooked = ok and ov.Add ~= origAdd
	return overlayHooked
end

-- one cell, built from the game's own inventory cell template (same design)
-- Look picker shown after choosing a skin. Built in the style of the game's inventory window:
-- same window frame (cloned from the real inventory), same round pet cells with the rarity background,
-- the real thumbnail of every look (golden / dark matter), rainbow tint and shine like in PetUI.
-- Returns a variant table ({} = normal) or nil when cancelled.
local TweenService = game:GetService("TweenService")
local STROKE_COLOR = Color3.fromRGB(28, 69, 82) -- same dark teal as the game's Message popup

local function addStroke(label, thickness)
	local st = Instance.new("UIStroke")
	st.Color = STROKE_COLOR
	st.Thickness = thickness or 3
	st.Parent = label
	return st
end

local function askVariant(skinId)
	local dir = PetDir[skinId] or {}
	local options = {
		{ name = "Normal", flags = {}, thumb = dir.thumbnail, color = Color3.new(1, 1, 1) },
	}
	if dir.goldenThumbnail then
		options[#options + 1] = { name = "Golden", flags = { g = true }, thumb = dir.goldenThumbnail, color = Color3.fromRGB(255, 205, 50) }
	end
	options[#options + 1] = { name = "Rainbow", flags = { r = true }, thumb = dir.thumbnail, rainbow = true }
	options[#options + 1] = { name = "Shiny", flags = { sh = true }, thumb = dir.thumbnail, shine = true, color = Color3.fromRGB(150, 235, 255) }
	if dir.goldenThumbnail then
		options[#options + 1] = { name = "Golden Shiny", flags = { g = true, sh = true }, thumb = dir.goldenThumbnail, shine = true, color = Color3.fromRGB(255, 225, 120) }
	end
	options[#options + 1] = { name = "Rainbow Shiny", flags = { r = true, sh = true }, thumb = dir.thumbnail, rainbow = true, shine = true }
	if dir.darkMatterThumbnail then
		options[#options + 1] = { name = "Dark Matter", flags = { dm = true }, thumb = dir.darkMatterThumbnail, color = Color3.fromRGB(190, 120, 255) }
	end

	local CELL, GAP, PADX = 100, 16, 30
	local cols = #options -- one horizontal row
	local rows = math.ceil(#options / cols)
	local ROW_H = CELL + 30
	local width = cols * CELL + (cols - 1) * GAP + PADX * 2
	local TOP, BOTTOM = 100, 50
	local height = TOP + rows * ROW_H + (rows - 1) * 10 + BOTTOM

	local result, done = nil, false
	local raisedGuis = {} -- [ScreenGui] = original DisplayOrder (restored when the dialog closes)
	local activeVariantTip = nil

	-- The window is a clone of the game's own "Message" popup (PlayerGui.Message): same bubble frame,
	-- stroke, tilted colour layers, pattern, "Hey!" tag, Desc text style and Cancel button.
	local dlg, frame, msgCancel
	local styled = false
	pcall(function()
		local src = PlayerGui:FindFirstChild("Message")
		if not (src and src:IsA("ScreenGui") and src:FindFirstChild("Frame")) then
			return
		end
		local d = src:Clone()
		local f = d:FindFirstChild("Frame")
		for _, c in ipairs(d:GetChildren()) do
			if c ~= f then
				c:Destroy()
			end
		end
		local drop = { Ok = true, No = true, Yes = true, ["Option 1"] = true, ["Option 2"] = true, OptionA = true, OptionB = true, OptionC = true }
		for _, c in ipairs(f:GetChildren()) do
			if drop[c.Name] or c:IsA("UIAspectRatioConstraint") or c:IsA("UIScale") then
				c:Destroy()
			end
		end
		for _, c in ipairs(f:GetChildren()) do
			if c.Name == "bg" and c:IsA("GuiObject") then
				c.Active = true -- clicks on the coloured edge do not fall through to the backdrop
			end
		end
		local t = f:FindFirstChild("Title")
		if t and t:IsA("TextLabel") then
			t.Text = "Mutation!"
		end
		local desc = f:FindFirstChild("Desc")
		if desc and desc:IsA("TextLabel") then
			desc.Text = "Which version of " .. skinName(skinId) .. "?"
			desc.AnchorPoint = Vector2.new(0.5, 0)
			desc.Position = UDim2.new(0.5, 0, 0, 46)
			desc.Size = UDim2.new(0.9, 0, 0, 46)
			for _, c in ipairs(desc:GetChildren()) do
				if c:IsA("TextLabel") then
					c.Text = desc.Text
				end
			end
		end
		local cb = f:FindFirstChild("Cancel")
		if not (cb and cb:IsA("GuiButton")) then
			return
		end
		cb.Visible = true
		cb.AnchorPoint = Vector2.new(0.5, 0.5)
		cb.Position = UDim2.new(0.5, 0, 1, 0)
		cb.Size = UDim2.fromOffset(150, 52)
		d.Enabled = true
		dlg, frame, msgCancel = d, f, cb
		styled = true
	end)

	if not dlg then
		dlg = Instance.new("ScreenGui")
	end
	dlg.Name = "PetSkinsGiftDialog"
	dlg.ResetOnSpawn = false
	dlg.DisplayOrder = 1000
	dlg.IgnoreGuiInset = true
	dlg.Parent = PlayerGui

	-- dark backdrop: click outside = cancel (very low ZIndex so it stays behind the tilted layers too)
	local back = Instance.new("TextButton")
	back.Name = "Backdrop"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.new(0, 0, 0)
	back.BackgroundTransparency = 0.45
	back.BorderSizePixel = 0
	back.Text = ""
	back.AutoButtonColor = false
	back.ZIndex = -100
	back.Parent = dlg
	back.Activated:Connect(function()
		done = true
	end)

	-- fallback window (only if the Message popup could not be cloned): clone of the real inventory frame
	if not frame then
		pcall(function()
			local src = invGui.Main.Parent
			if typeof(src) == "Instance" and src:IsA("Frame") then
				frame = src:Clone()
				for _, c in ipairs(frame:GetChildren()) do
					if c:IsA("GuiObject") and c.Name ~= "pattern" then
						c:Destroy()
					elseif c:IsA("UIAspectRatioConstraint") or c:IsA("UIScale") then
						c:Destroy()
					end
				end
			end
		end)
	end
	if not frame then
		frame = Instance.new("Frame")
		frame.BackgroundColor3 = Color3.fromRGB(28, 40, 62)
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 18)
		fc.Parent = frame
	end
	frame.Name = "Window"
	frame.Visible = true
	frame.Active = true
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(width, height)
	frame.Parent = dlg

	-- shrink on small screens (phones)
	do
		local cam = workspace.CurrentCamera
		if cam then
			local sc = math.min(1, (cam.ViewportSize.Y * 0.85) / (height + 40), (cam.ViewportSize.X * 0.95) / width)
			if sc < 1 then
				local us = Instance.new("UIScale")
				us.Scale = sc
				us.Parent = frame
			end
		end
	end

	-- the Message popup uses Global ZIndex (its tilted layers have negative ZIndex), so everything we
	-- add inside has to be lifted above the frame / pattern
	local function boostZ(root)
		if not styled then
			return
		end
		if root:IsA("GuiObject") then
			root.ZIndex = root.ZIndex + 10
		end
		for _, o in ipairs(root:GetDescendants()) do
			if o:IsA("GuiObject") then
				o.ZIndex = o.ZIndex + 10
			end
		end
	end

	if not styled then
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(10, 10)
		title.Size = UDim2.new(1, -20, 0, 50)
		title.Text = "Choose a version of " .. skinName(skinId)
		title.TextColor3 = Color3.new(1, 1, 1)
		title.Font = Enum.Font.FredokaOne
		title.TextScaled = true
		title.ZIndex = 20
		addStroke(title, 3)
		title.Parent = frame
	end

	local cells = {} -- for the per-frame animation
	local origin = TOP
	for i, o in ipairs(options) do
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		-- centre the last row if it has fewer cells
		local inRow = math.min(cols, #options - row * cols)
		local rowWidth = inRow * CELL + (inRow - 1) * GAP
		local x = (width - rowWidth) / 2 + col * (CELL + GAP)
		local y = origin + row * (ROW_H + 10)

		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(x, y)
		holder.Size = UDim2.fromOffset(CELL, ROW_H)
		holder.ZIndex = 2
		holder.Parent = frame

		local cell
		if template then
			local okc, c = pcall(function()
				return template:Clone()
			end)
			if okc then
				cell = c
			end
		end
		if not cell then
			cell = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false }, nil)
			new("UICorner", { CornerRadius = UDim.new(1, 0) }, cell)
			new("ImageLabel", {
				Name = "PetIcon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.05, 1.05),
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
			}, cell)
		end
		pcall(function()
			cell.BackgroundTransparency = 1
		end)
		for _, c in ipairs(cell:GetChildren()) do
			if c:IsA("GuiObject") and c.Name ~= "PetIcon" and c.Name ~= "RarityGradient" then
				c:Destroy()
			end
		end
		cell.Name = "Variant" .. i
		cell.Position = UDim2.fromOffset(0, 0)
		cell.Size = UDim2.fromOffset(CELL, CELL)
		cell.AnchorPoint = Vector2.new(0, 0)
		cell.LayoutOrder = i
		cell.Visible = true
		pcall(applyLook, cell, skinId)
		local rg = cell:FindFirstChild("RarityGradient")
		if rg and rg:IsA("GuiObject") then
			rg.Visible = true
		end
		local icon = cell:FindFirstChild("PetIcon")
		if icon then
			local img = o.thumb or dir.thumbnail
			if type(img) == "string" and img ~= "" then
				icon.Image = img
			end
			icon.ImageTransparency = 0
			icon.ImageColor3 = Color3.new(1, 1, 1)
			if o.rainbow then
				cells[#cells + 1] = icon
			end
		end
		pcall(function()
			Library.GUIFX.ButtonFX(cell)
		end)

		-- shine like the game's shiny pets
		if o.shine then
			pcall(function()
				local assets = Library.Assets.UI.Inventory
				local pulse = assets.ShinePulse:Clone()
				pulse.Parent = cell
				local sh = pulse:FindFirstChild("ShineImage")
				if sh then
					task.spawn(function()
						while dlg.Parent and not unloaded do
							local t = 0.5 + math.random() * 0.5
							TweenService:Create(sh, TweenInfo.new(t, Enum.EasingStyle.Linear), { Size = UDim2.new(1.7, 0, 1.7, 0) }):Play()
							task.wait(t)
							TweenService:Create(sh, TweenInfo.new(t, Enum.EasingStyle.Linear), { Size = UDim2.new(1.05, 0, 1.05, 0) }):Play()
							task.wait(t)
						end
					end)
				end
				task.spawn(function()
					while dlg.Parent and not unloaded do
						pcall(function()
							local s = assets.Shine:Clone()
							s.Position = UDim2.new(0.5, 0, 0.5, 0)
							s.Parent = cell
							boostZ(s)
							local si = s:FindFirstChild("ShineImage")
							if si then
								TweenService:Create(si, TweenInfo.new(0.75, Enum.EasingStyle.Linear), { Position = UDim2.new(1.2, 0, 1.2, 0) }):Play()
							end
							task.delay(0.8, function()
								s:Destroy()
							end)
						end)
						task.wait(0.5 + math.random() * 2.5)
					end
				end)
			end)
		end

		boostZ(cell)
		cell.Parent = holder
		cell.Activated:Connect(function()
			result = o.flags
			done = true
		end)

		-- hover card (same as in the skin list) with the mutation in the title: "Rainbow <pet>"
		do
			local variantTip = tipData(skinId)
			variantTip.name = (o.name == "Normal" and "" or (o.name .. " ")) .. (dir.name or tostring(skinId))
			variantTip.extra = nil
			cell.MouseEnter:Connect(function()
				local okO = pcall(function()
					local overlay = Library.InfoOverlay
					overlay.Add(cell, { "Title", variantTip.name, dir.rarity }, { "Rarity", dir.rarity })
				end)
				if okO then
					-- the game's overlay must be drawn above our dialog
					pcall(function()
						for _, g in ipairs(PlayerGui:GetChildren()) do
							if g:IsA("ScreenGui") and g ~= dlg and g.Name ~= "PetSkinsGui" and g.DisplayOrder >= 0
								and string.find(string.lower(g.Name), "overlay", 1, true) then
								if raisedGuis[g] == nil then
									raisedGuis[g] = g.DisplayOrder
								end
								g.DisplayOrder = 1001
							end
						end
					end)
				else
					showTip(variantTip)
					activeVariantTip = variantTip
				end
			end)
			cell.MouseLeave:Connect(function()
				pcall(function()
					Library.InfoOverlay.Remove()
				end)
				hideTip(variantTip)
			end)
		end

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(-10, CELL + 6)
		label.Size = UDim2.new(1, 20, 0, 22)
		label.Text = o.name
		label.TextColor3 = o.color or Color3.new(1, 1, 1)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.ZIndex = 20
		addStroke(label, 2.5)
		label.Parent = holder
		if o.rainbow then
			cells[#cells + 1] = label
		end
	end

	-- cancel button: the Message popup's own red Cancel button when styled, else a plain one
	local cancel = msgCancel
	if cancel then
		pcall(function()
			Library.GUIFX.ButtonFX(cancel)
		end)
	else
		cancel = Instance.new("TextButton")
		cancel.AnchorPoint = Vector2.new(0.5, 1)
		cancel.Position = UDim2.new(0.5, 0, 1, -14)
		cancel.Size = UDim2.fromOffset(140, 38)
		cancel.BackgroundColor3 = Color3.fromRGB(235, 70, 70)
		cancel.BorderSizePixel = 0
		cancel.Text = "Cancel"
		cancel.TextColor3 = Color3.new(1, 1, 1)
		cancel.Font = Enum.Font.FredokaOne
		cancel.TextSize = 22
		cancel.AutoButtonColor = true
		cancel.ZIndex = 20
		addStroke(cancel, 2)
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 10)
		cc.Parent = cancel
		cancel.Parent = frame
	end
	cancel.Activated:Connect(function()
		done = true
	end)
	-- the stroke above is on the button text; it is fine for this style

	while not done and not unloaded and dlg.Parent do
		local hue = Color3.fromHSV((os.clock() * 0.5) % 1, 1, 1)
		for _, obj in ipairs(cells) do
			if obj:IsA("ImageLabel") then
				obj.ImageColor3 = hue
			else
				obj.TextColor3 = hue
			end
		end
		-- own hover card (fallback when the game's InfoOverlay is not available) follows the mouse
		if tip and tip.Parent and tip.Visible then
			local mp = UserInputService:GetMouseLocation()
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
			local x = math.min(mp.X + 16, vp.X - tip.AbsoluteSize.X - 6)
			local y = math.min(mp.Y + 16, vp.Y - tip.AbsoluteSize.Y - 6)
			tip.Position = UDim2.fromOffset(math.max(x, 0), math.max(y, 0))
		end
		RunService.RenderStepped:Wait()
	end
	pcall(function()
		Library.InfoOverlay.Remove()
	end)
	if activeVariantTip then
		hideTip(activeVariantTip)
		destroyTip()
	end
	for g, order in pairs(raisedGuis) do
		pcall(function()
			g.DisplayOrder = order
		end)
	end
	pcall(function()
		dlg:Destroy()
	end)
	return result
end

local function makeCell(parent, order, entry, resetPet)
	local cell
	if template then
		local ok, c = pcall(function()
			return template:Clone()
		end)
		if ok then
			cell = c
		end
	end
	if not cell then
		cell = new("TextButton", {
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		}, nil)
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, cell)
		new("ImageLabel", {
			Name = "PetIcon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.05, 1.05),
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
		}, cell)
	end

	for _, n in ipairs({ "Equipped", "DeleteOverlay", "Stars", "HC", "Locked" }) do
		local c = cell:FindFirstChild(n)
		if c then
			c:Destroy()
		end
	end
	-- the template button has its own (blue) fill that the game hides on real cells: hide it here too,
	-- otherwise it is drawn on top of / under the rarity background. Also drop any other leftover layers.
	pcall(function()
		cell.BackgroundTransparency = 1
	end)
	for _, c in ipairs(cell:GetChildren()) do
		if c:IsA("GuiObject") and c.Name ~= "PetIcon" and c.Name ~= "RarityGradient" and c.Name ~= "Level" then
			c:Destroy()
		end
	end

	local icon = cell:FindFirstChild("PetIcon")
	local text
	if resetPet then
		cell.Name = "Reset"
		text = tipData(resetPet.id, "Click to remove the skin")
		text.prefix = "Original: "
		if icon then
			icon.Image = imageFor(resetPet, resetPet.id) or icon.Image
			icon.ImageTransparency = 0
		end
		local lvl = cell:FindFirstChild("Level")
		if lvl and lvl:IsA("TextLabel") then
			lvl.Visible = true
			lvl.Text = "Reset"
			lvl.TextColor3 = Color3.fromRGB(255, 120, 120)
		end
	else
		cell.Name = entry.id
		text = tipData(entry.id)
		if icon then
			icon.Image = imageFor(nil, entry.id) or icon.Image
			icon.ImageTransparency = 0
		end
		styleLevel(cell:FindFirstChild("Level"), entry.titanic and 4 or (entry.huge and 3 or nil))
	end

	-- same background + hover card as the real inventory cells: the game builds those with
	-- PetUI.Create(cell, uid), which reads the pet through PetCmds.Get. We hand it a fake pet.
	local usedGameUI = false
	if USE_GAME_HOVER and not resetPet and entry then
		local pui = Library.PetUI
		if type(pui) == "table" and type(pui.Create) == "function" then
			local pv = "preview_" .. entry.id
			previewPets[pv] = makePreviewPet(entry.id, pv)
			local okUI, errUI = pcall(pui.Create, cell, pv)
			if okUI then
				usedGameUI = true
			else
				previewPets[pv] = nil
			end
		end
	end
	if not usedGameUI then
		-- own background per rarity (same look as the real inventory cells)
		pcall(applyLook, cell, resetPet and resetPet.id or entry.id)
	end
	local rg = cell:FindFirstChild("RarityGradient")
	if rg and rg:IsA("GuiObject") then
		rg.Visible = true -- keep the cell background (it used to be hidden)
	end
	cell.Visible = true
	cell.LayoutOrder = order
	pcall(function()
		Library.GUIFX.ButtonFX(cell)
	end)

	if not usedGameUI then
		-- hover card: the game's own InfoOverlay (same design as PetUI), own tip only as a fallback
		cell.MouseEnter:Connect(function()
			local okO = pcall(function()
				local petId = resetPet and resetPet.id or entry.id
				local dir = PetDir[petId]
				local overlay = Library.InfoOverlay
				local blocks = {
					{ "Title", (resetPet and "Original: " or "") .. (dir and dir.name or tostring(petId)), dir and dir.rarity },
					{ "Rarity", dir and dir.rarity },
				}
				if text.extra then
					blocks[#blocks + 1] = { "ClickToOpen", text.extra }
				end
				overlay.Add(cell, unpack(blocks))
			end)
			if not okO then
				showTip(text)
			end
		end)
		cell.MouseLeave:Connect(function()
			pcall(function()
				Library.InfoOverlay.Remove()
			end)
			hideTip(text)
		end)
	end
	local isDropCell = entry and not resetPet and (entry.gift or string.find(entry.rarity or "", "egg", 1, true))
	if isDropCell then
		giftCells[cell] = entry.id
	end
	if isDropCell and not hookOverlay() then
		cell.MouseEnter:Connect(function()
			pcall(showDrops, entry.id)
		end)
		cell.MouseLeave:Connect(function()
			pcall(hideDrops)
		end)
	end
	cell.Activated:Connect(function()
		if os.clock() < picker.ignoreUntil or not picker.open then
			return
		end
		pcall(hideDrops)
		pcall(function()
			Library.InfoOverlay.Remove()
		end)
		local uid = picker.uid
		closePicker()
		if not uid then
			return
		end
		if resetPet then
			resetSkin(uid)
			rebuildItem(uid)
		else
			if not spawnedByUid[uid] then
				pcall(adoptExisting)
			end
			-- eggs / gifts are always normal; pets ask which look to use
			local variant = {}
			local sdir = PetDir[entry.id]
			local isEgg = isGiftSkin(entry.id) or (sdir and string.find(string.lower(tostring(sdir.rarity or "")), "egg", 1, true) ~= nil)
			if not isEgg then
				variant = askVariant(entry.id)
				if not variant then
					return -- cancelled: keep the current look
				end
			end
			applySkin(uid, entry.id, variant)
		end
	end)

	cell.Parent = parent
	return cell
end

local COPY_PROPS = {
	"Position", "Size", "AnchorPoint", "ZIndex", "LayoutOrder", "BackgroundColor3", "BackgroundTransparency",
	"BorderSizePixel", "ClipsDescendants", "ScrollBarThickness", "ScrollBarImageColor3",
	"ScrollBarImageTransparency", "ScrollingDirection", "ElasticBehavior", "VerticalScrollBarInset",
	"VerticalScrollBarPosition", "TopImage", "MidImage", "BottomImage",
}

local function createSection(name, realFrame, parent)
	local frame = new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = realFrame and realFrame.LayoutOrder or (name == "Normal" and 1 or 0),
	}, parent)
	local realGrid = realFrame and realFrame:FindFirstChildOfClass("UIGridLayout")
	local grid
	if realGrid then
		grid = realGrid:Clone()
	else
		grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(91, 91)
		grid.CellPadding = UDim2.fromOffset(20, 20)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
	end
	grid.Parent = frame
	local realPad = realFrame and realFrame:FindFirstChildOfClass("UIPadding")
	if realPad then
		realPad:Clone().Parent = frame
	end
	return { frame = frame, grid = grid, real = realFrame, list = {}, rendered = 0 }
end

local function renderMore(sec)
	if not sec or sec.rendered >= #sec.list then
		return
	end
	local last = math.min(#sec.list, sec.rendered + CHUNK)
	for i = sec.rendered + 1, last do
		makeCell(sec.frame, i, sec.list[i])
	end
	sec.rendered = last
end

local function maybeLoadMore()
	local s = picker.scroll
	if not picker.open or not s or not s.Parent then
		return
	end
	if s.CanvasPosition.Y + s.AbsoluteWindowSize.Y > s.AbsoluteCanvasSize.Y - 700 then
		renderMore(picker.sections.normal)
		renderMore(picker.sections.titanic)
	end
end

local function rebuild()
	if not picker.open or not picker.scroll then
		return
	end
	local qb = getQueryBox()
	local q = qb and string.lower(qb.Text) or ""
	q = string.match(q, "^%s*(.-)%s*$") or ""

	local normalList, titanicList = {}, {}
	for _, e in ipairs(buildCatalog()) do
		if matches(e, q) then
			if e.titanic then
				titanicList[#titanicList + 1] = e
			else
				normalList[#normalList + 1] = e
			end
		end
	end

	for _, sec in pairs(picker.sections) do
		for _, c in ipairs(sec.frame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		sec.rendered = 0
	end
	table.clear(previewPets)
	picker.sections.normal.list = normalList
	picker.sections.titanic.list = titanicList
	picker.sections.titanic.frame.Visible = #titanicList > 0

	local real = origGet(picker.uid)
	if real and skins[picker.uid] and (q == "" or string.find("reset", q, 1, true) or string.find("original", q, 1, true)) then
		makeCell(picker.sections.normal.frame, 0, nil, real)
	end

	renderMore(picker.sections.titanic)
	renderMore(picker.sections.normal)
	picker.scroll.CanvasPosition = Vector2.new()

	local petName = real and skinName(real.id) or "pet"
	picker.label = "Skin for " .. petName .. ": " .. (#normalList + #titanicList) .. " pets"
	task.delay(0.15, maybeLoadMore)
end

local function openPicker(uid)
	if picker.open then
		return
	end
	local pets = getPetsFrame()
	local real = origGet(uid)
	if not pets or not real then
		return
	end

	picker.open = true
	picker.uid = uid
	picker.ignoreUntil = os.clock() + 0.3
	table.clear(lookCache)
	pcall(sampleRealLooks) -- read the rarity backgrounds before the real cells get hidden
	picker.prevCanvas = pets.CanvasPosition
	pets.Visible = false -- hides every real pet cell at once (the click that opened us can no longer equip it)

	local qb = getQueryBox()
	picker.prevQuery = qb and qb.Text or ""
	if qb and qb.Text ~= "" then
		qb.Text = ""
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "PetSkinsPicker"
	for _, p in ipairs(COPY_PROPS) do
		pcall(function()
			scroll[p] = pets[p]
		end)
	end
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Visible = true
	local list = pets:FindFirstChildOfClass("UIListLayout")
	if list then
		list:Clone().Parent = scroll
	else
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 20) }, scroll)
	end
	local pad = pets:FindFirstChildOfClass("UIPadding")
	if pad then
		pad:Clone().Parent = scroll
	end
	picker.sections = {
		normal = createSection("Normal", pets:FindFirstChild("Normal"), scroll),
		titanic = createSection("Titanic", pets:FindFirstChild("Titanic"), scroll),
	}
	scroll.Parent = pets.Parent
	picker.scroll = scroll

	picker.conns[#picker.conns + 1] = scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(maybeLoadMore)
	picker.conns[#picker.conns + 1] = scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(maybeLoadMore)
	if qb then
		picker.conns[#picker.conns + 1] = qb:GetPropertyChangedSignal("Text"):Connect(function()
			picker.token = picker.token + 1
			local mine = picker.token
			task.delay(0.15, function()
				if mine == picker.token then
					rebuild()
				end
			end)
		end)
	end
	rebuild()
end

function closePicker()
	if not picker.open then
		return
	end
	picker.open = false
	picker.token = picker.token + 1
	for _, c in ipairs(picker.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	picker.conns = {}
	destroyTip()
	if picker.scroll then
		pcall(function()
			picker.scroll:Destroy()
		end)
		picker.scroll = nil
	end
	picker.sections = nil
	table.clear(previewPets)

	local pets = getPetsFrame()
	if pets then
		pets.Visible = true
	end
	local qb = getQueryBox()
	if qb and qb.Text ~= picker.prevQuery then
		qb.Text = picker.prevQuery
	end
	-- the game's own update runs after this: put the real list back where it was
	local pos = picker.prevCanvas
	for _, delay in ipairs({ 0, 0.1 }) do
		task.delay(delay, function()
			local p = getPetsFrame()
			if p and not picker.open then
				p.CanvasPosition = pos
			end
		end)
	end
	refreshInventory(picker.uid)
end

-- which real pet cell is under the mouse (returns its uid)
local function cellUnderMouse()
	local pets = getPetsFrame()
	if not pets or not pets.Visible then
		return nil
	end
	local mp = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	for _, probe in ipairs({ Vector2.new(mp.X - inset.X, mp.Y - inset.Y), mp }) do
		local ok, objs = pcall(function()
			return PlayerGui:GetGuiObjectsAtPosition(probe.X, probe.Y)
		end)
		if ok and objs and objs[1] then
			-- the top-most thing under the mouse must belong to the inventory window itself
			if not objs[1]:IsDescendantOf(invGui.Gui) then
				return nil
			end
			for _, o in ipairs(objs) do
				local cur = o
				while cur and cur ~= PlayerGui do
					local par = cur.Parent
					if par and (par.Name == "Normal" or par.Name == "Titanic") and par.Parent == pets then
						local real = origGet(cur.Name)
						if type(real) == "table" then
							return cur.Name
						end
						return nil
					end
					cur = par
				end
			end
		end
	end
	return nil
end

local DEBUG = true -- prints why a click did not open the picker (executor console / F9)
local function dbg(...)
	if DEBUG then
	end
end

connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input)
	if unloaded then
		return
	end
	-- the picker opens ONLY on the right mouse button (MouseButton2); the left button is the game's normal click
	if picker.open then
		if input.KeyCode == Enum.KeyCode.Escape then
			closePicker()
		end
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
		return
	end
	if not changerOn then
		return
	end
	if not inventoryOpen() then
		return
	end
	if shiftHeld() then
		return dbg("click ignored: Shift is held (normal game click)")
	end
	if inSpecialMode() then
		return dbg("click ignored: delete / lock / rename mode is on in the inventory")
	end
	local uid = cellUnderMouse()
	if not uid and hoveredUid then
		-- fallback: the cell the mouse entered last (tracked through MouseEnter/MouseLeave)
		local item = getInventoryItem(hoveredUid)
		if item and item.Parent and item.Visible and origGet(hoveredUid) then
			uid = hoveredUid
			dbg("cell found by hover fallback")
		end
	end
	if not uid then
		return dbg("click ignored: no pet cell under the mouse (hoveredUid = " .. tostring(hoveredUid) .. ")")
	end
	dbg("opening picker for " .. tostring(uid))
	suppressEquipUntil = os.clock() + 0.6
	local ok, err = pcall(openPicker, uid)
	if not ok then
		pcall(closePicker)
	end
end)

connections[#connections + 1] = RunService.RenderStepped:Connect(function()
	if not picker.open then
		return
	end
	if not inventoryOpen() then
		closePicker()
		return
	end
	local pets = getPetsFrame()
	if pets and pets.Visible then
		pets.Visible = false -- the game must not bring its own cells back while the picker is open
	end
	pcall(function()
		local pa = invGui.PetAmount
		if pa.Text ~= picker.label then
			pa.Text = picker.label
		end
	end)
	if tip and tip.Visible then
		local mp = UserInputService:GetMouseLocation()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local x = math.min(mp.X + 16, vp.X - tip.AbsoluteSize.X - 6)
		local y = math.min(mp.Y + 16, vp.Y - tip.AbsoluteSize.Y - 6)
		tip.Position = UDim2.fromOffset(math.max(x, 0), math.max(y, 0))
	end
	if dropsCard and dropsCard.Parent and dropsCard.Visible then
		local mp = UserInputService:GetMouseLocation()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local w, h = dropsCard.AbsoluteSize.X, dropsCard.AbsoluteSize.Y
		local x = mp.X - w - 16 -- left of the cursor: the pet card sits on the right
		if x < 6 then
			x = math.min(mp.X + 16, vp.X - w - 6)
		end
		local y = math.min(mp.Y + 16, vp.Y - h - 6)
		dropsCard.Position = UDim2.fromOffset(math.max(x, 0), math.max(y, 0))
	end
	-- keep our grids the same size as the game's (resolution / grid-view changes)
	if os.clock() - picker.lastGridSync > 0.5 and picker.sections then
		picker.lastGridSync = os.clock()
		for _, sec in pairs(picker.sections) do
			local rg = sec.real and sec.real:FindFirstChildOfClass("UIGridLayout")
			if rg then
				if sec.grid.CellSize ~= rg.CellSize then
					sec.grid.CellSize = rg.CellSize
				end
				if sec.grid.CellPadding ~= rg.CellPadding then
					sec.grid.CellPadding = rg.CellPadding
				end
			end
		end
	end
end)

----------------------------------------------------------------------
-- CHANCES PANEL
-- small button "Chances" at the left edge of the screen (or RightControl) opens / closes it.
-- Scope button: ALL eggs, or one single egg (the eggs of the gift skins you currently use).
-- Empty box = game default. Values are saved in PetSkinChances.json.
----------------------------------------------------------------------
local chancesGui
;(function()
	local FIELDS, saveSettings, effectiveCfg, resolvePetId = CHX.FIELDS, CHX.save, CHX.eff, CHX.resolve
	local SHINY_PERCENT = CHX.SHINY
	local chancesPanel
	local scopes = { "ALL" }
	local scopeIdx = 1
	local boxes = {}
	local scopeBtn, infoLabel

	local function eggTitle(eggId)
		local egg = EggDir[eggId]
		return (type(egg) == "table" and type(egg.displayName) == "string" and egg.displayName) or tostring(eggId)
	end

	local function refreshScopes()
		local cur = scopes[scopeIdx]
		scopes = { "ALL" }
		local seen = {}
		for _, skinId in pairs(skins) do
			if isGiftSkin(skinId) then
				local eggId = resolveEggId(skinId)
				if eggId and not seen[eggId] then
					seen[eggId] = true
					scopes[#scopes + 1] = eggId
				end
			end
		end
		table.sort(scopes, function(a, b)
			if a == "ALL" or b == "ALL" then
				return a == "ALL"
			end
			return a < b
		end)
		scopeIdx = 1
		for i, s in ipairs(scopes) do
			if s == cur then
				scopeIdx = i
			end
		end
	end

	local function currentTable(create)
		local s = scopes[scopeIdx]
		if s == "ALL" then
			return settings.global
		end
		if create and not settings.eggs[s] then
			settings.eggs[s] = {}
		end
		return settings.eggs[s] or {}
	end

	local function fmtNum(n)
		return (string.gsub(string.format("%.4f", n), "%.?0+$", ""))
	end

	local function refreshBoxes()
		local s = scopes[scopeIdx]
		local t = currentTable(false)
		local egg = s ~= "ALL" and EggDir[s] or nil
		if scopeBtn then
			scopeBtn.Text = "Scope: " .. (s == "ALL" and "ALL eggs" or eggTitle(s)) .. "  (click to switch)"
		end
		local defaults = {
			luck = "1 (normal)",
			g = egg and tonumber(egg.goldenChance) and fmtNum(tonumber(egg.goldenChance)) or "game default",
			r = egg and tonumber(egg.rainbowChance) and fmtNum(tonumber(egg.rainbowChance)) or "game default",
			sh = fmtNum(SHINY_PERCENT),
			dm = "0",
			fav = "pet name / id",
			favPct = "0",
		}
		for _, k in ipairs(FIELDS) do
			local b = boxes[k]
			if b then
				b.PlaceholderText = defaults[k]
				b.Text = t[k] ~= nil and (type(t[k]) == "number" and fmtNum(t[k]) or tostring(t[k])) or ""
			end
		end
		if infoLabel then
			local cfg = effectiveCfg(s ~= "ALL" and s or nil)
			local parts = {}
			if cfg.fav and (cfg.favPct or 0) > 0 then
				local fid = resolvePetId(cfg.fav)
				parts[#parts + 1] = fid and ("Favourite: " .. fid .. " " .. fmtNum(cfg.favPct) .. "%")
					or ("Favourite '" .. cfg.fav .. "' not found")
			end
			if (cfg.luck or 1) > 1 then
				parts[#parts + 1] = "Luck x" .. fmtNum(cfg.luck)
			end
			infoLabel.Text = #parts > 0 and table.concat(parts, "  |  ") or "Everything on game defaults"
		end
	end

	local function setField(k, text)
		local t = currentTable(true)
		text = string.gsub(tostring(text or ""), "^%s+", "")
		text = string.gsub(text, "%s+$", "")
		if k == "fav" then
			t.fav = text ~= "" and text or nil
		else
			local n = tonumber(text)
			if n == nil then
				t[k] = nil
			elseif k == "luck" then
				t[k] = math.clamp(n, 1, 1000000)
			else
				t[k] = math.clamp(n, 0, 100)
			end
		end
		local s = scopes[scopeIdx]
		if s ~= "ALL" and next(t) == nil then
			settings.eggs[s] = nil
		end
		saveSettings()
		refreshBoxes()
	end

	chancesGui = new("ScreenGui", {
		Name = "PetSkinsGui",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1003,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, PlayerGui)

	local toggle = new("TextButton", {
		Name = "ChancesButton",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 120),
		Size = UDim2.fromOffset(74, 30),
		BackgroundColor3 = Color3.fromRGB(28, 32, 44),
		BorderSizePixel = 0,
		Text = "Chances",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 13,
	}, chancesGui)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, toggle)

	chancesPanel = new("Frame", {
		Name = "ChancesPanel",
		Visible = false,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 84, 0.5, 0),
		Size = UDim2.fromOffset(340, 420),
		BackgroundColor3 = Color3.fromRGB(28, 32, 44),
		BorderSizePixel = 0,
		Active = true,
		Draggable = true,
	}, chancesGui)
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, chancesPanel)

	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -50, 0, 28),
		Text = "Egg chances (local only)",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, chancesPanel)

	local closeBtn = new("TextButton", {
		Position = UDim2.new(1, -34, 0, 6),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = Color3.fromRGB(200, 60, 60),
		BorderSizePixel = 0,
		Text = "X",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, chancesPanel)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, closeBtn)

	scopeBtn = new("TextButton", {
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.new(1, -24, 0, 30),
		BackgroundColor3 = Color3.fromRGB(60, 90, 160),
		BorderSizePixel = 0,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, chancesPanel)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, scopeBtn)

	local rows = {
		{ "luck", "Luck x (rare pets)" },
		{ "g", "Golden %" },
		{ "r", "Rainbow %" },
		{ "sh", "Shiny %" },
		{ "dm", "Dark Matter %" },
		{ "fav", "Favourite pet" },
		{ "favPct", "Favourite pet %" },
	}
	for i, row in ipairs(rows) do
		local y = 80 + (i - 1) * 38
		new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.fromOffset(150, 30),
			Text = row[2],
			TextColor3 = Color3.fromRGB(220, 224, 235),
			Font = Enum.Font.Gotham,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, chancesPanel)
		local box = new("TextBox", {
			Position = UDim2.fromOffset(166, y),
			Size = UDim2.new(1, -178, 0, 30),
			BackgroundColor3 = Color3.fromRGB(44, 50, 68),
			BorderSizePixel = 0,
			Text = "",
			PlaceholderText = "",
			PlaceholderColor3 = Color3.fromRGB(130, 136, 155),
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.Gotham,
			TextSize = 14,
			ClearTextOnFocus = false,
		}, chancesPanel)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, box)
		boxes[row[1]] = box
		box.FocusLost:Connect(function()
			setField(row[1], box.Text)
		end)
	end

	local function presetButton(text, x, w, y, color, fn)
		local b = new("TextButton", {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(w, 28),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 12,
		}, chancesPanel)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		b.Activated:Connect(fn)
	end

	local function preset(values)
		local t = currentTable(true)
		for _, k in ipairs({ "g", "r", "sh", "dm" }) do
			t[k] = values[k]
		end
		saveSettings()
		refreshBoxes()
	end
	presetButton("100% Gold", 12, 98, 352, Color3.fromRGB(190, 150, 30), function()
		preset({ g = 100, r = 0, sh = 0, dm = 0 })
	end)
	presetButton("100% Rainbow", 118, 104, 352, Color3.fromRGB(150, 70, 190), function()
		preset({ g = 0, r = 100, sh = 0, dm = 0 })
	end)
	presetButton("100% Shiny", 230, 98, 352, Color3.fromRGB(50, 150, 190), function()
		preset({ g = 0, r = 0, sh = 100, dm = 0 })
	end)
	presetButton("Reset this scope", 12, 316, 384, Color3.fromRGB(200, 60, 60), function()
		local s = scopes[scopeIdx]
		if s == "ALL" then
			settings.global = {}
		else
			settings.eggs[s] = nil
		end
		saveSettings()
		refreshBoxes()
	end)

	infoLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 322),
		Size = UDim2.new(1, -24, 0, 26),
		Text = "",
		TextColor3 = Color3.fromRGB(150, 220, 160),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextWrapped = true,
	}, chancesPanel)

	scopeBtn.Activated:Connect(function()
		scopeIdx = scopeIdx % #scopes + 1
		refreshBoxes()
	end)
	local function setOpen(v)
		if v then
			refreshScopes()
			refreshBoxes()
		end
		chancesPanel.Visible = v
	end
	toggle.Activated:Connect(function()
		setOpen(not chancesPanel.Visible)
	end)
	closeBtn.Activated:Connect(function()
		setOpen(false)
	end)
	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, gp)
		if not unloaded and not gp and input.KeyCode == Enum.KeyCode.RightControl then
			setOpen(not chancesPanel.Visible)
		end
	end)
	refreshScopes()
	refreshBoxes()
end)()

----------------------------------------------------------------------
-- _G.PetsChanger switch (ON = works, OFF = all pets back to normal, changing is locked)
----------------------------------------------------------------------
local function setChanger(on)
	if on == changerOn then
		return
	end
	if on then
		changerOn = true
		local uids = {}
		for uid, v in pairs(stash.skins) do
			skins[uid] = v
			uids[#uids + 1] = uid
		end
		for uid, v in pairs(stash.variants) do
			variants[uid] = v
		end
		table.clear(stash.skins)
		table.clear(stash.variants)
		table.clear(iconCache)
		for _, uid in ipairs(uids) do
			pcall(respawn, uid)
			pcall(rebuildItem, uid)
		end
	else
		changerOn = false -- locks applySkin / resetSkin / picker first
		pcall(closePicker)
		local uids = {}
		for uid, v in pairs(skins) do
			stash.skins[uid] = v
			uids[#uids + 1] = uid
		end
		for uid, v in pairs(variants) do
			stash.variants[uid] = v
		end
		for _, uid in ipairs(uids) do
			skins[uid] = nil
			variants[uid] = nil
		end
		table.clear(iconCache)
		pcall(clearGiftOverlays)
		for _, uid in ipairs(uids) do
			pcall(restoreIcon, uid)
			pcall(respawn, uid)
			pcall(rebuildItem, uid)
		end
	end
end

connections[#connections + 1] = RunService.Heartbeat:Connect(function()
	if unloaded then
		return
	end
	local want = _G.PetsChanger == true
	if want ~= changerOn then
		local ok, err = pcall(setChanger, want)
		if not ok then
		end
	end
end)

----------------------------------------------------------------------
-- unload
----------------------------------------------------------------------
ENV.PetSkinsResetAll = function()
	resetAll()
end

ENV.PetSkinsUnload = function()
	if unloaded then
		return
	end
	pcall(closePicker)
	unloaded = true
	for _, conn in ipairs(connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	pcall(trySet, PetCmds, "Spawn", origSpawn)
	pcall(trySet, PetCmds, "Get", origGet)
	pcall(trySet, Shared, "ComputePetStrength", origStrength)
	pcall(trySet, Network, "Invoke", origNetInvoke)
	pcall(trySet, Network, "Fire", origNetFire)
	pcall(clearGiftOverlays)
	pcall(function()
		if chancesGui then chancesGui:Destroy() end
	end)
	pcall(function()
		local d = PlayerGui:FindFirstChild("PetSkinsGiftDialog")
		if d then d:Destroy() end
	end)
	local uids = {}
	for uid in pairs(skins) do
		uids[#uids + 1] = uid
	end
	for _, uid in ipairs(uids) do
		skins[uid] = nil -- in memory only, the saved file keeps your skins
	end
	for _, uid in ipairs(uids) do
		pcall(restoreIcon, uid)
		pcall(respawn, uid)
		pcall(rebuildItem, uid)
	end
	destroyTip()
	ENV.PetSkinsUnload = nil
	ENV.PetSkinsResetAll = nil
end

-- saved skins: pick up already-spawned pets and apply their skins right away
adoptExisting()
task.defer(function()
	for uid in pairs(skins) do
		pcall(respawn, uid)
		pcall(rebuildItem, uid)
	end
end)
