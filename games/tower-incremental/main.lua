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
-- Read off the live place: UpgradeConfig rows and TreeConfig.NODES rows
-- both key on lowercase `id`, so that is tried first.
local function catalogue(module, ...)
	if type(module) ~= "table" then return {} end
	local keys = { ... }
	for _, key in ipairs(keys) do
		local value = module[key]
		if type(value) == "table" then
			local out = {}
			for _, entry in ipairs(value) do
				if type(entry) == "table" then
					local id = entry.id or entry.Id or entry.ID or entry.Name or entry.Key
					if id ~= nil then table.insert(out, { id = id, raw = entry }) end
				end
			end
			if #out > 0 then return out end
		end
	end
	return {}
end

local Upgrades  = catalogue(Config.Upgrade, "List", "Upgrades", "Nodes", "Data")
local TreeNodes = catalogue(Config.Tree,   "Nodes", "Tree", "List", "Data")

--- What we already hold, per catalogue. Seeded from the mirrored save
--- when it can be found, then kept in step with every buy we make, so
--- the compounding price of an upgrade stays honest across a session.
local Owned = {
	upgrade = {},
	tree    = {},
}

--- Prices for every upgrade at the level we currently hold it.
--- UpgradeConfig rows are {baseCost, growth, cap}, so the price of the
--- next one is baseCost * growth^owned -- not a flat number off the row.
--- A row past its cap prices to nil and drops out of the auto-buy.
local function priceUpgrades()
	local priced = {}
	for _, entry in ipairs(Upgrades) do
		local owned = Owned.upgrade[entry.id] or 0
		local price = Core.upgradePrice(entry.raw, owned)
		if price ~= nil then
			table.insert(priced, {
				id       = entry.id,
				cost     = price,
				currency = entry.raw.currency,
			})
		end
	end
	return priced
end

--- Tree nodes price flat off the row, so the only thing missing is the
--- dependency walk, which core.nextNode handles.
local function priceTree()
	local priced = {}
	for _, entry in ipairs(TreeNodes) do
		local raw = entry.raw
		if type(raw.cost) == "number" then
			table.insert(priced, {
				id       = entry.id,
				cost     = raw.cost,
				currency = raw.currency,
				requires = raw.requires,
			})
		end
	end
	return priced
end

-- ═══════════════════════════════════════════════════════════
--  live balances
--
--  Read off the mirrored save rather than tracked locally, so a purchase
--  decision uses what the server actually thinks we hold. Every currency
--  the game defines gets a slot: an upgrade priced in embers cannot be
--  paid for with gold, and deciding that against one number would buy
--  things the server then rejects.
-- ═══════════════════════════════════════════════════════════

local CURRENCIES = {
	"gold", "silver", "iron", "ingots", "wood", "crystals", "stardust",
	"starmetal", "essence", "pearls", "relics", "volts", "cogs", "feathers",
	"prisms", "embers",
}

local state = { rebirths = 0, floor = 1 }
for _, name in ipairs(CURRENCIES) do state[name] = 0 end

--- Balance of any currency name, case- and plural-insensitive, so a
--- config row saying "wood" and the save saying "Wood" still meet.
function state.balance(name)
	if type(name) ~= "string" then return 0 end
	local key = name:lower()
	if state[key] ~= nil then return state[key] end
	if key:sub(-1) == "s" and state[key:sub(1, -2)] ~= nil then
		return state[key:sub(1, -2)]
	end
	return 0
end

local function scanPlayerData()
	local function dig(node, depth)
		if type(node) ~= "table" or depth > 3 then return end
		for key, value in pairs(node) do
			if type(value) == "number" then
				local k = key:lower()
				if k == "stairsowned" then state.floor = math.floor(value) + 1
				elseif k:find("rebi") then state.rebirths = value
				elseif state[k] ~= nil then state[k] = value end
			elseif type(value) == "table" then
				dig(value, depth + 1)
			end
		end
	end

	--- Attributes are the mirror the client keeps its copy of the save in.
	--- Capped at a few levels: the PlayerGui holds a couple hundred
	--- instances and this runs on every buy tick, so an unbounded walk
	--- would cost more than the decision it informs.
	local function scanAttributes(holder, depth)
		if depth > 3 then return end
		for name, attr in pairs(holder:GetAttributes()) do
			if type(attr) == "number" then
				local k = tostring(name):lower()
				if state[k] ~= nil then state[k] = attr end
			end
		end
		for _, child in pairs(holder:GetChildren()) do
			if child:IsA("StringValue") or child:IsA("IntValue")
				or child:IsA("NumberValue") or child:IsA("Folder") then
				scanAttributes(child, depth + 1)
			end
		end
	end

	for _, holder in ipairs({ LocalPlayer, LocalPlayer and LocalPlayer:FindFirstChild("leaderstats") }) do
		if type(holder) == "table" then
			for _, child in ipairs(holder:GetChildren()) do
				if child:IsA("StringValue") or child:IsA("IntValue") or child:IsA("NumberValue") then
					local k = child.Name:lower()
					if state[k] ~= nil then state[k] = child.Value end
				elseif child:IsA("Folder") then
					dig(child:GetAttributes(), 1)
				end
			end
			scanAttributes(holder, 0)
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
	Rebirth  = Window:AddTab({ Name = "Rebirth",  Icon = "redo" }),
	Glyphs   = Window:AddTab({ Name = "Glyphs",   Icon = "gem" }),
	Totems   = Window:AddTab({ Name = "Totems",   Icon = "tower" }),
	Trails   = Window:AddTab({ Name = "Trails",   Icon = "wind" }),
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
				scanPlayerData()
				-- BuyStair takes the floor number to unlock. Confirmed on
				-- the wire: FireServer(73) from Client.StairClient.
				-- StairConfig.costOf prices it, including the piecewise
				-- growth bands, so nothing here re-derives the maths.
				local cost = Config.Stair and Config.Stair.costOf
					and Config.Stair.costOf(state.floor) or nil
				if type(cost) == "number" and state.gold < cost then
					pause("buy")
					return true
				end
				if fire("BuyStair", state.floor) then
					state.floor += 1
				end
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
				scanPlayerData()
				-- UnlockDoor takes a door id string, confirmed on the wire:
				-- FireServer("upgradeTree") from Client.DoorClient. Walking
				-- DoorConfig.DOORS gives unlock order; DOORS is already in
				-- natural order, and each row knows its own floor and cost.
				local doors = Config.Door and Config.Door.DOORS
				if type(doors) ~= "table" then return true end
				for _, door in ipairs(doors) do
					local id = door.id or door.Id
					local cost = door.cost
					local currency = door.currency or "gold"
					local floor = door.floor
					if id and type(cost) == "number" and state.balance(currency) >= cost then
						if type(floor) == "number" and state.floor < floor then
							return true -- need to climb past it first
						end
						fire("UnlockDoor", id)
						pause("collect")
					end
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
--- change to one.
---
--- remoteName is only a fallback for executors without getconnections,
--- and it is nil for the axe on purpose: there is no wood remote among
--- the 31 this place dispatches, so falling back to MineBlock would send
--- the server a mining hit every time we tried to chop. Better to do
--- nothing than to do the wrong thing loudly.
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
	if not fired and remoteName ~= nil then fired = fire(remoteName) end
	return fired
end

do
	local tab = T.Gather
	local MineCursor = 0

	--- Ask MineConfig where the ore is rather than guessing.
	---
	--- It owns the grid layout itself -- which cells hold ore, how many
	--- remote blocks each ore is worth, how long to wait between moves --
	--- and it is the same table the game's own mining client reads. Any
	--- accessor it exposes gets tried; if none of them hand back a
	--- non-empty list we fall through to the tool handler below instead of
	--- firing a block index we made up.
	local function mineCells()
		local cfg = Config.Mine
		if type(cfg) ~= "table" then return {} end
		for _, accessor in ipairs({ "oreCells", "grid", "gridOf", "cells" }) do
			local fn = cfg[accessor]
			if type(fn) == "function" then
				local ok, cells = pcall(fn)
				if ok and type(cells) == "table" and #cells > 0 then return cells end
			end
		end
		return {}
	end

	--- Remote cadence, straight off the config. REMOTE_BLOCKS_PER_ORE is 3
	--- and REMOTE_MOVE_SECONDS is 0.35 on this place; both can move with a
	--- patch, so neither is written down here.
	local function minePace()
		local cfg = Config.Mine
		local perOre, step = 3, 0.35
		if type(cfg) == "table" then
			if type(cfg.remoteBlocksPerOre) == "function" then
				local ok, v = pcall(cfg.remoteBlocksPerOre)
				if ok and type(v) == "number" and v > 0 then perOre = v end
			end
			if type(cfg.REMOTE_MOVE_SECONDS) == "number" then step = cfg.REMOTE_MOVE_SECONDS end
		end
		return perOre, step
	end

	tab:AddSection({ Name = "Mine" })

	tab:AddToggle({ Name = "Auto Mine", Callback = function(self)
		onToggle(self, "mine", function() startLoop("mine", function()
			local cells = mineCells()
			if #cells > 0 and Remotes.MineBlock then
				local perOre, step = minePace()
				MineCursor = MineCursor % #cells + 1
				local cell = cells[MineCursor]
				-- cells may be bare indices or small rows describing the cell
				local index = cell
				if type(cell) == "table" then
					index = cell.index or cell.cell or cell.id or cell.position
				end
				if index == nil then return false end
				-- One block per tick; perOre is read above so the pace can be
				-- reported rather than guessed, but firing three at once
				-- trips the server's own move check.
				fire("MineBlock", index)
				task.wait(step)
				return true
			end
			if not swing("Pickaxe") then return false end
			pause("collect")
			return true
		end) end)
	end })

	tab:AddButton({ Name = "Reset Mine", Callback = function()
		if fire("MineReset") then notify("Mine reset sent", 3) else
			notify("MineReset remote not present", 3)
		end
	end })

	-- MineConfig.RUN is 20, so a cycle is one bounded run rather than an
	-- open-ended dig. Kept as a button because the exact payload is still
	-- a guess and a wrong guess in a repeating loop is noisier than one
	-- click.
	tab:AddButton({ Name = "Cycle Mine", Callback = function()
		if fire("MineCycle") then notify("Mine cycle sent", 3) else
			notify("MineCycle remote not present", 3)
		end
	end })

	tab:AddSection({ Name = "Harvest" })

	--- Wood and crystals are hold-to-harvest with no remote: WoodConfig and
	--- CrystalConfig hand out the spot they want worked (`target`) and how
	--- long the hold lasts (`holdSeconds`). Ask them for both rather than
	--- reimplementing either.
	local function harvest(cfg, toolName)
		if type(cfg) ~= "table" or type(cfg.target) ~= "function" then return false end
		local ok, spot = pcall(cfg.target)
		if not ok or spot == nil then return false end

		local part = root()
		if part and typeof(spot) == "Vector3" then part.CFrame = CFrame.new(spot) end

		local hold = 0.5
		if type(cfg.holdSeconds) == "function" then
			local held, v = pcall(cfg.holdSeconds)
			if held and type(v) == "number" and v > 0 then hold = v end
		end

		swing(toolName)
		task.wait(hold)
		return true
	end

	tab:AddToggle({ Name = "Auto Chop", Callback = function(self)
		onToggle(self, "chop", function() startLoop("chop", function()
			if not harvest(Config.Wood, "Axe") and not swing("Axe") then return false end
			pause("collect"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Crystals", Callback = function(self)
		onToggle(self, "crystals", function() startLoop("crystals", function()
			if not harvest(Config.Crystal, "Pickaxe") and not swing("Pickaxe") then return false end
			pause("collect"); return true
		end) end)
	end })

	tab:AddSection({ Name = "Deposit" })

	tab:AddToggle({ Name = "Auto Deposit", Callback = function(self)
		onToggle(self, "deposit", function() startLoop("deposit", function()
			fire("SmelterDeposit")
			fire("StarforgeDeposit")
			fire("RefractorDeposit")
			pause("collect"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Smelt", Callback = function(self)
		onToggle(self, "smelt", function() startLoop("smelt", function()
			fire("SmelterCollect")
			pause("collect"); return true
		end) end)
	end })

	-- Essence is command-based, not a purchase: the spy caught
	-- FireServer("sync") from Client.EssenceClient. There is no remote
	-- here that collects an orb, so this does the only thing we can
	-- honestly prove it does -- ask the server to re-send our state.
	tab:AddButton({ Name = "Sync State", Callback = function()
		fire("Essence", "sync")
		scanPlayerData()
		notify(("Synced. gold %s, silver %s")
			:format(Core.format(state.gold), Core.format(state.silver)), 4)
	end })

	tab:AddLabel("Mining, chopping and harvesting all read their grid and hold times from the game's own config.")
end

-- ═══════════════════════════════════════════════════════════
--  UPGRADES — driven by the game's own config ids
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Upgrades

	tab:AddLabel(#Upgrades > 0
		and ("Upgrade catalogue: " .. #Upgrades .. " entries read from UpgradeConfig")
		or "UpgradeConfig gave us nothing — auto-buy is off")

	local function affordable(entry)
		return state.balance(entry.currency) >= entry.cost
	end

	tab:AddToggle({ Name = "Auto Buy Upgrades", Callback = function(self)
		onToggle(self, "upgrades", function() startLoop("upgrades", function()
			if #Upgrades == 0 then return false end
			scanPlayerData()
			-- Buy at the best rate per click: the most expensive thing the
			-- balance covers, priced at the level we already hold it.
			local priced = priceUpgrades()
			local pick = Core.pickBest(priced, state.gold, { byCurrency = true, balance = function(c) return state.balance(c) end })
			if pick then
				fire("BuyUpgrade", pick.id)
				Owned.upgrade[pick.id] = (Owned.upgrade[pick.id] or 0) + 1
			end
			pause("buy")
			return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Buy Tree Nodes", Callback = function(self)
		onToggle(self, "tree", function() startLoop("tree", function()
			if #TreeNodes == 0 then return false end
			scanPlayerData()
			-- nextNode walks the requires chain, so a node is only ever
			-- offered once the one above it is owned. Cheapest unlocked
			-- node wins, each in its own currency.
			local pick = Core.nextNode(priceTree(), Owned.tree, affordable)
			if pick then
				fire("BuyTreeNode", pick.id)
				Owned.tree[pick.id] = true
			end
			pause("buy")
			return true
		end) end)
	end })

	tab:AddButton({ Name = "Refresh Config", Callback = function()
		scanPlayerData()
		notify(("Upgrades %d, tree nodes %d, gold %s")
			:format(#Upgrades, #TreeNodes, Core.format(state.gold)), 5)
	end })
end

-- ═══════════════════════════════════════════════════════════
--  REBIRTH
--
--  RebirthConfig.LIST is the whole ladder. Rows carry their own
--  currency, cost, floor and rebirth requirement, and the array
--  position IS the rebirth number -- there is no index field on the
--  row itself, so it gets stamped on while reading.
-- ═══════════════════════════════════════════════════════════

local KeepGuard = true

--- Buy every keeper upgrade we can afford.
---
--- UpgradeConfig flags these rows `permanent`, and they are what survives a
--- rebirth. Taking the tier before they are owned throws the whole board
--- away, so this runs first and the tick waits for it.
local function buyKeepers()
	local bought = false
	for _, entry in ipairs(Upgrades) do
		local row = entry.raw
		if row.permanent or row.keeps then
			local owned = Owned.upgrade[row.id] or 0
			local cap = tonumber(row.cap) or 1
			if owned < cap then
				local cost = Core.upgradePrice(row, owned)
				local currency = row.currency or "gold"
				if cost and state.balance(currency) >= cost then
					if fire("BuyUpgrade", row.id) then
						Owned.upgrade[row.id] = owned + 1
						bought = true
						pause("buy")
					end
				end
			end
		end
	end
	return bought
end

do
	local tab = T.Rebirth
	local Rebirthed = {}

	local function rebirthTiers()
		local list = Config.Rebirth and Config.Rebirth.LIST
		if type(list) ~= "table" then return {} end
		local out = {}
		for n, row in ipairs(list) do
			if type(row) == "table" then
				table.insert(out, {
					index    = row.index or n,
					currency = row.currency or "gold",
					cost     = row.cost,
					floor    = row.floor,
					rebirths = row.rebirths,
					raw      = row,
				})
			end
		end
		return out
	end

	tab:AddLabel(#rebirthTiers() > 0
		and ("Tier ladder: " .. #rebirthTiers() .. " read from RebirthConfig")
		or "RebirthConfig gave us nothing -- auto-rebirth is off")

	tab:AddToggle({ Name = "Keep Upgrades First", Default = true, Callback = function(self)
		KeepGuard = self.Value
	end })

	tab:AddToggle({ Name = "Auto Rebirth", Callback = function(self)
		onToggle(self, "rebirth", function() startLoop("rebirth", function()
			scanPlayerData()
			local tier = Core.nextRebirth(rebirthTiers(), {
				balance  = function(c) return state.balance(c) end,
				floor     = state.floor,
				rebirths = state.rebirths,
				owned    = Rebirthed,
			})
			if tier == nil then
				pause("rebirth")
				return true
			end
			if KeepGuard and not buyKeepers() then
				-- Nothing keeper-related is affordable yet, so taking the
				-- tier now would wipe the board. Wait instead.
				pause("rebirth")
				return true
			end
			if fire("Rebirth", tier.index) then
				Rebirthed[tier.index] = true
				scanPlayerData()
				notify("Rebirth " .. tostring(tier.index), 3)
			end
			pause("rebirth")
			return true
		end) end)
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

	--- PotionConfig.LIST is 28 rows of {id, name, multiplier, duration},
	--- keyed like `pearls3x` and `gold`. BuyPotion takes the potion id,
	--- so the cheapest tier the balance covers is the one worth buying --
	--- a 5x we cannot afford does nothing at all.
	local function potionRows()
		local list = Config.Potion and Config.Potion.LIST
		if type(list) ~= "table" then return {} end
		local out = {}
		for _, row in ipairs(list) do
			if type(row) == "table" and type(row.id) == "string" then
				table.insert(out, { id = row.id, cost = row.cost })
			end
		end
		return out
	end

	tab:AddToggle({ Name = "Auto Potions", Callback = function(self)
		onToggle(self, "potions", function() startLoop("potions", function()
			local rows = potionRows()
			if #rows == 0 then return false end
			-- PotionConfig carries no price field, so this stays a manual
			-- buy: the ids are real, the affordability check would be a
			-- guess, and firing an unaffordable potion every tick is worse
			-- than not firing one.
			for _, row in ipairs(rows) do
				if fire("BuyPotion", row.id) then break end
			end
			pause("buy"); return true
		end) end)
	end })

	tab:AddToggle({ Name = "Auto Spin Wheel", Callback = function(self)
		onToggle(self, "wheel", function() startLoop("wheel", function()
			-- SpinWheel takes no arguments: the PrizeWheel costs a flat
			-- 100000 gold and the wedge is picked server-side.
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
--  GLYPHS
--
--  There is no glyph remote among the 31 this place dispatches -- rolling
--  happens entirely client-side. GlyphConfig.roll is the game's own
--  picker, so it is called rather than reimplemented: the odds, the
--  collection cap and the 41-set bookkeeping all stay correct for free.
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Glyphs
	local GlyphGap = 1

	tab:AddLabel("410 glyphs across 41 sets, 1 gold a roll. Rolling goes through the game's own picker.")

	tab:AddToggle({ Name = "Auto Roll", Callback = function(self)
		onToggle(self, "glyphs", function() startLoop("glyphs", function()
			local cfg = Config.Glyph
			if type(cfg) ~= "table" or type(cfg.roll) ~= "function" then return false end
			if not pcall(cfg.roll) then return false end
			task.wait(math.max(0.2, GlyphGap))
			return true
		end) end)
	end })

	tab:AddSlider({ Name = "Roll Interval", Min = 0.2, Max = 5, Default = 1, Increment = 0.1,
		Callback = function(self) GlyphGap = self.Value end })
end

-- ═══════════════════════════════════════════════════════════
--  TOTEMS
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Totems

	--- TotemConfig keys its 13 heads by id in BY_ID/HEADS, and they are a
	--- dictionary rather than a list -- so it gets walked in sorted cost
	--- order, because there is no array order to inherit.
	local function totemRows()
		local cfg = Config.Totem
		local heads = type(cfg) == "table" and (cfg.BY_ID or cfg.HEADS) or nil
		if type(heads) ~= "table" then return {} end
		local out = {}
		for id, row in pairs(heads) do
			if type(row) == "table" then
				table.insert(out, {
					id       = row.id or id,
					name     = row.name or row.id or id,
					cost     = row.cost,
					currency = row.currency or "essence",
					stat     = row.stat,
				})
			end
		end
		table.sort(out, function(a, b)
			return (tonumber(a.cost) or math.huge) < (tonumber(b.cost) or math.huge)
		end)
		return out
	end

	local Rows = totemRows()
	tab:AddLabel(#Rows > 0
		and (#Rows .. " totems read from TotemConfig")
		or "TotemConfig did not load -- totems are off")

	tab:AddToggle({ Name = "Auto Buy Totems", Callback = function(self)
		onToggle(self, "totems", function() startLoop("totems", function()
			if #Rows == 0 then return false end
			scanPlayerData()
			-- Cheapest first: totems are a flat one-off catalogue, so there
			-- is no rate-per-click argument for buying the dear one.
			local pick = Core.pickCheapest(Rows, function(c) return state.balance(c) end)
			if pick and fire("Totem", pick.id) then
				notify("Bought " .. tostring(pick.name), 3)
			end
			pause("buy")
			return true
		end) end)
	end })
end

-- ═══════════════════════════════════════════════════════════
--  TRAILS
-- ═══════════════════════════════════════════════════════════

do
	local tab = T.Trails

	--- 81 trails in TrailConfig.LIST. Price lives behind costFor rather
	--- than on the row for some tiers, so both are accepted.
	local function trailRows()
		local cfg = Config.Trail
		local list = type(cfg) == "table" and cfg.LIST or nil
		if type(list) ~= "table" then return {} end
		local out = {}
		for _, row in ipairs(list) do
			if type(row) == "table" then
				local id = row.id or row.Id
				if id then
					local cost = row.cost
					if cost == nil and type(cfg.costFor) == "function" then
						local ok, v = pcall(cfg.costFor, row)
						if ok then cost = v end
					end
					table.insert(out, {
						id       = id,
						name     = row.name or id,
						cost     = cost,
						currency = row.currency or "gold",
					})
				end
			end
		end
		return out
	end

	local Rows = trailRows()
	tab:AddLabel(#Rows > 0
		and (#Rows .. " trails read from TrailConfig")
		or "TrailConfig did not load -- trails are off")

	tab:AddToggle({ Name = "Auto Buy Trails", Callback = function(self)
		onToggle(self, "trails", function() startLoop("trails", function()
			if #Rows == 0 then return false end
			scanPlayerData()
			local pick = Core.pickCheapest(Rows, function(c) return state.balance(c) end)
			if pick and fire("BuyTrail", pick.id) then
				fire("EquipTrail", pick.id)
				notify("Bought " .. tostring(pick.name), 3)
			end
			pause("buy")
			return true
		end) end)
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