-- ═══════════════════════════════════════════════════════════
--  [UPD7] Tower Incremental — Nyx
--
--  Remote inventory and world-object names were read off this place's
--  ReplicatedStorage tree with OpenDex. Every decision the script makes
--  that could be wrong without throwing lives in core.lua, which is
--  tested with `luau test/core_spec.lua` from this folder.
--
--  The game keeps a full ProfileStore-backed save server-side, so
--  nothing here writes a balance. Everything drives the same actions the
--  buttons do, on the same remotes, at a human cadence.
--
--  Loaded by nyx-hub's loader.lua.
-- ═══════════════════════════════════════════════════════════

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local Workspace  = game:GetService("Workspace")
local UIS        = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local function char()   return LocalPlayer and LocalPlayer.Character end
local function humanoid() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end
local function root()   local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end

-- ═══════════════════════════════════════════════════════════
--  core (tested; no Roblox API inside it)
-- ═══════════════════════════════════════════════════════════

local REPO = "https://raw.githubusercontent.com/dylankirkgirg/nyx-hub/main/"
local Core = loadstring(game:HttpGet(REPO .. "games/tower-incremental/core.lua"))()

local function notify(text, dur)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Nyx", Text = text, Duration = dur or 4 })
	end)
end

-- ═══════════════════════════════════════════════════════════
--  remotes — tolerant resolution, so a rename greys a feature out
--  instead of erroring the whole script
-- ═══════════════════════════════════════════════════════════

local Remotes, Missing = {}, {}
for name, path in pairs(Core.REMOTES) do
	local obj = Core.resolve(RS, path)
	if obj then Remotes[name] = obj else Missing[path[2] .. "/" .. path[3]] = name end
end

-- The arguments are packed before crossing into pcall: '...' belongs to
-- this function, not to the closure, so it can't be referenced inside one.
local function fire(name, ...)
	local r = Remotes[name]
	if r == nil then return false end
	local args = table.pack(...)
	pcall(function() r:FireServer(table.unpack(args, 1, args.n)) end)
	return true
end

-- ═══════════════════════════════════════════════════════════
--  game config — requireable at runtime, so costs, floors, ids and
--  cooldowns come from this place's own tables instead of being
--  hardcoded and going stale the next patch
-- ═══════════════════════════════════════════════════════════

local Config = {}
for _, mod in ipairs({
	"StairConfig", "UpgradeConfig", "TreeConfig", "RebirthConfig", "DoorConfig",
	"WoodConfig", "MineConfig", "SmelterConfig", "StarforgeConfig", "CrystalConfig",
	"EssenceConfig", "GlyphConfig", "PotionConfig", "TrailConfig", "TotemConfig",
	"RefractorConfig", "WheelConfig", "CodeConfig", "PassConfig", "NumberFormat",
}) do
	local ok, module = pcall(function()
		return require(RS:WaitForChild("Shared"):WaitForChild(mod))
	end)
	if ok then Config[mod:gsub("Config$", "")] = module end
end

-- Upgrade and tree-node catalogues are the ones auto-buy needs an id list
-- for. Shape isn't known ahead of time, so pull the first array of tables
-- that carries an id-ish key out of whatever the config actually returned.
local function catalogue(module, ...)
	if type(module) ~= "table" then return {} end
	local keys = { ... }
	for _, key in ipairs(keys) do
		local value = module[key]
		if type(value) == "table" then
			local out = {}
			for _, entry in ipairs(value) do
				if type(entry) == "table" then
					local id = entry.Id or entry.ID or entry.Name or entry.Key
					if id ~= nil then table.insert(out, { id = id, raw = entry }) end
				end
			end
			if #out > 0 then return out end
		end
	end
	return {}
end

local Upgrades = catalogue(Config.Upgrade, "Upgrades", "List", "Nodes", "Data")
local TreeNodes = catalogue(Config.Tree, "Nodes", "Tree", "List", "Data")

local function costOf(raw)
	if type(raw) ~= "table" then return nil end
	local cost = raw.Cost or raw.Price or raw.cost or raw.price
	if type(cost) == "number" then return cost end
	if type(cost) == "function" then
		local ok, v = pcall(cost, raw)
		if ok and type(v) == "number" then return v end
	end
	return nil
end

for _, entry in ipairs(Upgrades)   do entry.cost = costOf(entry.raw) end
for _, entry in ipairs(TreeNodes)  do entry.cost = costOf(entry.raw) end

-- ═══════════════════════════════════════════════════════════
--  live balance
--
--  Read off the mirrored save rather than tracked locally, so the UI
--  shows what the server actually thinks we hold.
-- ═══════════════════════════════════════════════════════════

local state = {
	gold = 0, silver = 0, crystals = 0, essence = 0,
	rebirths = 0, floor = 1,
}

local function scanPlayerData()
	local function dig(node, depth)
		if type(node) ~= "table" or depth > 3 then return end
		for key, value in pairs(node) do
			if type(value) == "number" and key:lower():match("gold") then state.gold = value
			elseif type(value) == "number" and key:lower():match("silver") then state.silver = value
			elseif type(value) == "number" and key:lower():match("^crystals?$") then state.crystals = value
			elseif type(value) == "number" and key:lower():match("essence") then state.essence = value
			elseif type(value) == "number" and key:lower():match("rebi") then state.rebirths = value
			end
			if type(value) == "table" then dig(value, depth + 1) end
		end
	end

	for _, holder in ipairs({ LocalPlayer, LocalPlayer and LocalPlayer:FindFirstChild("leaderstats") }) do
		if type(holder) == "table" then
			for _, child in ipairs(holder:GetChildren()) do
				if child:IsA("StringValue") or child:IsA("IntValue") then
					local k = child.Name:lower()
					if k:match("gold") then state.gold = child.Value
					elseif k:match("silver") then state.silver = child.Value
					elseif k:match("crystals") then state.crystals = child.Value
					elseif k:match("essence") then state.essence = child.Value
					end
				elseif child:IsA("Folder") then
					dig(child:GetAttributes(), 1)
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════
--  loop engine — one thread per toggle, clean stop on disable
-- ═══════════════════════════════════════════════════════════

local threads = {}

local function stopLoop(key)
	local thread = threads[key]
	if thread then
		pcall(task.cancel, thread)
		threads[key] = nil
	end
end

local function startLoop(key, body)
	if threads[key] then return end
	threads[key] = task.spawn(function()
		while threads[key] do
			local alive = body()
			if alive == false then break end
			task.wait()
		end
		threads[key] = nil
	end)
end

--- Wire an Obsidian toggle to a loop.
---
--- Deliberately not the `self.Value and start() or stop()` idiom: start
--- returns nil, so that expression always falls through and stops the
--- loop it just started.
local function onToggle(self, key, start)
	if self.Value then start() else stopLoop(key) end
end

-- ═══════════════════════════════════════════════════════════
--  pacing sliders
-- ═══════════════════════════════════════════════════════════

local PACE = { buy = 0.35, collect = 0.5, rebirth = 3 }

local function pause(key)
	task.wait(Core.jitter(PACE[key] or 0.5, (PACE[key] or 0.5) * 0.4))
end

-- ═══════════════════════════════════════════════════════════
--  Obsidian + Nyx skin
-- ═══════════════════════════════════════════════════════════

local lib = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library      = loadstring(game:HttpGet(lib .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(lib .. "addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(lib .. "addons/SaveManager.lua"))()

local NyxTheme = (getgenv and getgenv().Nyx and getgenv().Nyx.theme) or {
	BackgroundColor = Color3.fromRGB(16, 12, 15),
	MainColor       = Color3.fromRGB(25, 19, 23),
	AccentColor     = Color3.fromRGB(233, 122, 173),
	OutlineColor    = Color3.fromRGB(50, 39, 46),
	FontColor       = Color3.fromRGB(240, 232, 237),
}

local Window = Library:CreateWindow({
	Title             = "Nyx",
	Footer            = "tower incremental",
	Scheme            = NyxTheme,
	Size              = UDim2.fromOffset(720, 600),
	Center            = true,
	AutoShow          = true,
	ToggleKeybind     = Enum.KeyCode.RightShift,
	ShowCustomCursor  = false,
	ShowMobileButtons = true,
	MobileButtonsSide = "Left",
})

ThemeManager:SetTheme(NyxTheme)
SaveManager:SetFolder("Nyx")

local T = {
	Farm     = Window:AddTab({ Name = "Farm",     Icon = "chevron-up" }),
	Gather   = Window:AddTab({ Name = "Gather",   Icon = "pickaxe" }),
	Upgrades = Window:AddTab({ Name = "Upgrades", Icon = "layer-group" }),
	Loot     = Window:AddTab({ Name = "Loot",     Icon = "gift" }),
	Shop     = Window:AddTab({ Name = "Shop",     Icon = "bag-shopping" }),
	ESP      = Window:AddTab({ Name = "ESP",      Icon = "eye" }),
	Recon    = Window:AddTab({ Name = "Recon",    Icon = "binoculars" }),
	Player   = Window:AddTab({ Name = "Player",   Icon = "user" }),
	Settings = Window:AddTab({ Name = "Settings", Icon = "settings" }),
}

-- ═══════════════════════════════════════════════════════════
--  FARM
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Farm
	tab:AddSection({ Name = "Climb" })

	tab:AddToggle({
		Name = "Auto Stairs",
		Callback = function(self)
			if not self.Value then return stopLoop("stairs") end
			startLoop("stairs", function()
				if not fire("BuyStair") then return false end
				pause("buy")
				return true
			end)
		end,
	})

	tab:AddToggle({
		Name = "Auto Doors",
		Callback = function(self)
			if not self.Value then return stopLoop("doors") end
			startLoop("doors", function()
				for _, door in ipairs(Remotes.UnlockDoor and { 1, 2, 3, 4, 5 } or {}) do
					fire("UnlockDoor", door)
				end
				pause("collect")
				return true
			end)
		end,
	})

	tab:AddSection({ Name = "Timing" })
	tab:AddSlider({
		Name = "Buy Delay", Min = 0.1, Max = 3, Default = 0.35, Increment = 0.05,
		Callback = function(self) PACE.buy = self.Value end,
	})
	tab:AddSlider({
		Name = "Collect Delay", Min = 0.1, Max = 5, Default = 0.5, Increment = 0.1,
		Callback = function(self) PACE.collect = self.Value end,
	})
end

-- ═══════════════════════════════════════════════════════════
--  GATHER
-- ═══════════════════════════════════════════════════════════

--- Equip a tool by name, so a swing only ever happens with the right one held.
local function equip(toolName)
	local c = char()
	if not c then return nil end
	local tool = c:FindFirstChild(toolName)
	if not tool or not tool:IsA("Tool") then return nil end
	local hum = humanoid()
	if hum and c:FindFirstChildOfClass("Tool") ~= tool then hum:EquipTool(tool) end
	return tool
end

--- Call the game's own Activated handler instead of firing the remote
--- ourselves. The handler already builds the arguments the way the
--- server expects, so nothing here has to guess a payload or track a
--- change to one. Falls back to the remote when the handler can't be
--- reached (tool swapped mid-swing, executor without getconnections).
local function swing(toolName, remoteName)
	local tool = equip(toolName)
	if tool == nil then return false end

	local fired = false
	if type(getconnections) == "function" then
		for _, connection in ipairs(getconnections(tool:FindFirstChild("Activated") or tool)) do
			if type(connection.Function) == "function" then
				if pcall(connection.Function) then
					fired = true
					break
				end
			end
		end
	end
	if not fired then fired = fire(remoteName) end
	return fired
end

do
	local tab = T.Gather

	tab:AddToggle({ Name = "Auto Mine", Callback = function(self)
		onToggle(self, "mine", function() startLoop("mine", function()
			if not swing("Pickaxe", "MineBlock") then return false end
			pause("collect"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Chop", Callback = function(self)
		onToggle(self, "chop", function() startLoop("chop", function()
			if not swing("Axe", "MineBlock") then return false end
			pause("collect"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Gather", Callback = function(self)
		onToggle(self, "gather", function() startLoop("gather", function()
			fire("Essence")
			pause("collect"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Deposit", Callback = function(self)
		onToggle(self, "deposit", function() startLoop("deposit", function()
			fire("SmelterDeposit")
			fire("StarforgeDeposit")
			fire("RefractorDeposit")
			pause("collect"); return true
		end) end)
	end })

	tab:AddLabel("Mining and chopping drive the game's own tool handler, so the payload can't drift.")
end

-- ═══════════════════════════════════════════════════════════
--  UPGRADES — driven by the game's own config ids
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Upgrades

	tab:AddLabel(#Upgrades > 0
		and ("Upgrade catalogue: " .. #Upgrades .. " entries read from UpgradeConfig")
		or "UpgradeConfig gave us nothing — auto-buy is off")

	tab:AddToggle({ Name = "Auto Buy Upgrades", Callback = function(self)
		if not self.Value then return stopLoop("upgrades") end
		startLoop("upgrades", function()
			if #Upgrades == 0 then return false end
			scanPlayerData()
			local pick = Core.pickBest(Upgrades, state.gold)
			if pick then fire("BuyUpgrade", pick.id) end
			pause("buy")
			return true
		end)
	end })

	tab:AddToggle({ Name = "Auto Buy Tree Nodes", Callback = function(self)
		if not self.Value then return stopLoop("tree") end
		startLoop("tree", function()
			if #TreeNodes == 0 then return false end
			scanPlayerData()
			local pick = Core.pickBest(TreeNodes, state.silver)
			if pick then fire("BuyTreeNode", pick.id) end
			pause("buy")
			return true
		end)
	end })

	tab:AddButton({ Name = "Refresh Config", Callback = function()
		local before = #Upgrades
		scanPlayerData()
		notify(("Upgrades %d, tree nodes %d, gold %s")
			:format(#Upgrades, #TreeNodes, Core.format(state.gold)), 5)
		if before == #Upgrades then notify("Config unchanged", 2) end
	end })
end

-- ═══════════════════════════════════════════════════════════
--  LOOT — the eight systems, left off by default
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Loot
	tab:AddLabel("Off by default. Each one fires a reward remote on its own timer.")

	for _, game_ in pairs(Core.MINIGAMES) do
		local key = game_.name
		tab:AddToggle({
			Name = "Auto " .. key,
			Callback = function(self)
				if not self.Value then return stopLoop(key) end
				startLoop(key, function()
					if not fire(key .. "_Action") then return false end
					pause("collect")
					return true
				end)
			end,
		})
	end
end

-- ═══════════════════════════════════════════════════════════
--  SHOP
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Shop
	tab:AddToggle({ Name = "Auto Potions", Callback = function(self)
		onToggle(self, "potions", function() startLoop("potions", function()
			fire("BuyPotion")
			pause("buy"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Spin Wheel", Callback = function(self)
		onToggle(self, "wheel", function() startLoop("wheel", function()
			fire("SpinWheel")
			pause("buy"); return true
		end) end)
	end })
	tab:AddButton({ Name = "Redeem Code", Callback = function()
		local box = Library:CreateWindow({ Title = "Redeem", Footer = "code", Size = UDim2.fromOffset(380, 220), Center = true })
		local input = box:AddInput({ Name = "Code", PlaceholderText = "RELEASE" })
		box:AddButton({ Name = "Redeem", Callback = function()
			fire("RedeemCode", input and input.Value or "")
			notify("Sent — watch chat for the result", 4)
		end })
		box:Close()
	end })
end

-- ═══════════════════════════════════════════════════════════
--  ESP — highlights named parts. No raycasts, no guessing.
-- ═══════════════════════════════════════════════════════════

local ESP = { active = {}, pool = {}, folder = nil }

local function espFolder()
	if ESP.folder and ESP.folder.Parent then return ESP.folder end
	local folder = Instance.new("Folder")
	folder.Name = "NyxESP"
	folder.Parent = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	ESP.folder = folder
	return folder
end

local function makeHighlight(part, colour)
	local highlight = Instance.new("Highlight")
	highlight.Adornee = part
	highlight.FillColor  = colour
	highlight.FillTransparency  = 0.75
	highlight.OutlineColor = colour
	highlight.OutlineTransparency = 0.1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = espFolder()
	return highlight
end

--- Scan once, describe every part matching a predicate.
local function scanTargets(root, match)
	local found = {}
	local function walk(node, depth)
		if depth > 8 then return end
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("BasePart") and match(child.Name) then table.insert(found, child) end
			walk(child, depth + 1)
		end
	end
	walk(root, 0)
	return found
end

local ESP_SETS = {
	{ key = "ores",     label = "Ore Veins",     colour = Color3.fromRGB(120, 200, 255), scan = function() return scanTargets(Workspace, Core.isOrePart) end },
	{ key = "crystals", label = "Crystals",      colour = Color3.fromRGB(190, 120, 255), scan = function() return scanTargets(Workspace, Core.isCrystalName) end },
	{ key = "trees",    label = "Trees",         colour = Color3.fromRGB(120, 255, 160), scan = function() return scanTargets(Workspace, Core.isTreePart) end },
	{ key = "essence",  label = "Essence Orbs",  colour = Color3.fromRGB(255, 200, 90),  scan = function() return scanTargets(Workspace, Core.isEssenceName) end },
}

do
	local tab = T.ESP
	for _, set in ipairs(ESP_SETS) do
		tab:AddToggle({
			Name = set.label,
			Callback = function(self)
				ESP.active[set.key] = self.Value
				if not self.Value then
					for _, highlight in pairs(ESP.pool) do
						if highlight._set == set.key then highlight:Destroy() end
					end
				end
			end,
		})
	end
	tab:AddSlider({ Name = "Refresh", Min = 0.5, Max = 10, Default = 3, Increment = 0.5,
		Callback = function(self) ESP.interval = self.Value end })
	tab:AddButton({ Name = "Clear All", Callback = function()
		for _, highlight in pairs(ESP.pool) do highlight:Destroy() end
		ESP.pool = {}
	end })
end

-- Refresh on a slow loop rather than every frame: the targets move, but
-- not fast enough for per-frame rescan to be worth the cost.
task.spawn(function()
	while true do
		task.wait(ESP.interval or 3)
		for _, set in ipairs(ESP_SETS) do
			if ESP.active[set.key] then
				for _, highlight in pairs(ESP.pool) do
					if highlight._set == set.key then highlight:Destroy() end
				end
				for _, part in ipairs(set.scan()) do
					local highlight = makeHighlight(part, set.colour)
					highlight._set = set.key
					highlight._part = part
					ESP.pool[highlight] = true
				end
			end
		end
	end
end)

-- ═══════════════════════════════════════════════════════════
--  PLAYER
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Player
	local FLY_SPEED = 80

	local function setSpeed(value)
		local h = humanoid()
		if h then h.WalkSpeed = value end
	end

	tab:AddSlider({ Name = "Walk Speed", Min = 0, Max = 500, Default = 32, Increment = 1,
		Callback = function(self) setSpeed(self.Value) end })

	tab:AddSlider({ Name = "Jump Power", Min = 0, Max = 300, Default = 50, Increment = 1,
		Callback = function(self)
			local h = humanoid()
			if h then h.JumpPower = self.Value end
		end })

	tab:AddSlider({ Name = "Gravity", Min = 0, Max = 500, Default = 196.2, Increment = 0.1,
		Callback = function(self) Workspace.Gravity = self.Value end })

	tab:AddToggle({ Name = "Noclip", Callback = function(self)
		if not self.Value then
			stopLoop("noclip")
			local c = char()
			if c then for _, part in ipairs(c:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = true end
			end end
			return
		end
		startLoop("noclip", function()
			local c = char()
			if not c then return false end
			for _, part in ipairs(c:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
			return true
		end)
	end })

	tab:AddToggle({ Name = "Fly", Callback = function(self)
		if not self.Value then
			stopLoop("fly")
			local h = humanoid()
			if h then h.PlatformStand = false end
			return
		end
		startLoop("fly", function()
			local r, h = root(), humanoid()
			if not r or not h then return false end
			h.PlatformStand = true

			local dir = Vector3.zero
			if UIS:IsKeyDown(Enum.KeyCode.W) then dir += r.CFrame.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= r.CFrame.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.D) then dir += r.CFrame.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= r.CFrame.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
			if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end

			r.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * FLY_SPEED or Vector3.zero
			return true
		end)
	end })

	tab:AddButton({ Name = "Teleport to Highest Stair", Callback = function()
		local r = root()
		if not r then return end
		-- highest stair we can see
		local best
		for _, child in ipairs(Workspace:GetDescendants()) do
			if child:IsA("BasePart") and child.Name:lower():find("stair") then
				if not best or child.Position.Y > best.Position.Y then best = child end
			end
		end
		if best then
			r.CFrame = CFrame.new(best.Position + Vector3.new(0, 4, 0))
			notify("Teleported to " .. best.Name, 2)
		else
			notify("No part with 'stair' in its name", 3)
		end
	end })
end

-- ═══════════════════════════════════════════════════════════
--  RECON — what we can see from in here, for when we need to check
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Recon

	tab:AddSection({ Name = "Remotes" })
	local resolved, absent = 0, 0
	for _, name in ipairs({ "BuyStair", "BuyUpgrade", "Rebirth", "UnlockDoor", "DataService_Function" }) do
		if Remotes[name] then resolved += 1 else absent += 1 end
	end
	tab:AddLabel(("Core remotes resolved %d/%d, %d not found this session")
		:format(resolved, resolved + absent, absent))

	tab:AddSection({ Name = "Config" })
	tab:AddButton({ Name = "Dump Loaded Configs", Callback = function()
		local names = {}
		for key in pairs(Config) do table.insert(names, key) end
		table.sort(names)
		notify("Loaded: " .. table.concat(names, ", "), 9)
	end })

	tab:AddSection({ Name = "Args" })
	tab:AddLabel("Remote shapes aren't guessed here. Fire a feature once, then check the Spy window in OpenDex to confirm.")
end

-- ═══════════════════════════════════════════════════════════
--  SETTINGS
-- ═══════════════════════════════════════════════════

do
	local tab = T.Settings
	tab:AddButton({ Name = "Save Config", Callback = function() SaveManager:Save() notify("Saved", 2) end })
	tab:AddButton({ Name = "Load Config", Callback = function() SaveManager:Load() notify("Loaded", 2) end })
	tab:AddButton({ Name = "Destroy Window", Callback = function() Window:Destroy() end })
end

scanPlayerData()
notify(("Nyx ready — %d upgrades, %d tree nodes, %s gold")
	:format(#Upgrades, #TreeNodes, Core.format(state.gold)), 6)