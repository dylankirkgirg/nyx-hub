-- ═══════════════════════════════════════════════════════════
--  Tower Incremental — core logic
--
--  Everything here is a decision the script makes that can be wrong
--  without throwing: number formatting, cost maths, which upgrade to
--  buy next, pacing jitter, which world parts are real targets.
--
--  No Roblox API calls except the one optional instance lookup at the
--  bottom, which is why the whole file runs under plain `luau` and is
--  covered by test/core_spec.lua. Anything that needs the live game
--  lives in main.lua instead.
-- ═══════════════════════════════════════════════════════════

local Core = {}

-- ═══════════════════════════════════════════════════════════
--  numbers
-- ═══════════════════════════════════════════════════════════

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

--- Three significant digits with a magnitude suffix, the way every game
--- in this genre shows a balance. 12345 becomes "12.3K", not "12.35K".
--- Anything that isn't a usable number becomes "0" rather than throwing,
--- because balances arrive off the network and a formatter that blows up
--- would take the whole auto-buy loop down with it.
function Core.format(n)
	if type(n) ~= "number" or n ~= n or n < 1 then return "0" end

	local tier = math.clamp(math.floor(math.log(n, 10) / 3), 0, #SUFFIX - 1)

	-- Below a thousand the number is short enough to read as-is. Padding
	-- it out to three significant figures would turn 7 gold into "7.00".
	if tier == 0 then return string.format("%.0f", n) end

	local value = n / (1000 ^ tier)

	-- Round to three significant digits. 999999 lands exactly on 1000
	-- here, which is correct: "1000K" reads better than "1000.0K" and the
	-- tier is not recomputed afterwards.
	local magnitude = 10 ^ (2 - math.floor(math.log(value, 10)))
	value = math.floor(value * magnitude + 0.5) / magnitude

	local places = math.max(0, 2 - math.floor(math.log(value, 10)))
	return string.format("%." .. places .. "f%s", value, SUFFIX[tier + 1])
end

-- ═══════════════════════════════════════════════════════════
--  choosing what to buy
-- ═══════════════════════════════════════════════════════════

--- Pick the most expensive entry the balance covers.
---
--- Buying the most expensive affordable thing is the right default in an
--- incremental: cheap buys stall progress and cost the same click. When
--- nothing is affordable we return nil plus the exact shortfall so the UI
--- can say "90 more gold" instead of silently doing nothing.
---
--- entries: array of { id = <any>, cost = <number> }
--- opts.maxTier: only consider the first N entries, so a maxed-out table
---   doesn't get spammed at its last row forever.
function Core.pickBest(entries, balance, opts)
	opts = opts or {}
	if type(entries) ~= "table" then return nil, 0 end

	-- opts.balance: currency -> amount held. When it is absent every
	-- entry is judged against the single balance argument, which is the
	-- old behaviour and still right when the whole shop is one currency.
	-- When it is present each row is judged against its own, because an
	-- upgrade priced in embers cannot be paid for with gold.
	local hasBag = type(opts.balance) == "function"
	if not hasBag and (type(balance) ~= "number" or balance ~= balance) then return nil, 0 end

	local function available(entry)
		if not hasBag then return balance end
		local ok, amount = pcall(opts.balance, entry.currency)
		if ok and type(amount) == "number" and amount == amount then return amount end
		return 0
	end

	local limit = opts.maxTier
	if type(limit) ~= "number" or limit < 1 then limit = math.huge end

	local best, cheapest = nil, nil
	local seen = 0

	for _, entry in ipairs(entries) do
		seen += 1
		if seen > limit then break end

		local cost = type(entry) == "table" and entry.cost or nil
		-- A config row can be locked, disabled, or shaped differently from
		-- its siblings; one bad row must not stop the whole auto-buy.
		if type(cost) == "number" and cost == cost and cost >= 0 then
			if not cheapest or cost < cheapest.cost then cheapest = entry end
			if cost <= available(entry) and (not best or cost > best.cost) then
				best = entry
			end
		end
	end

	if best then return best, 0 end
	if cheapest then
		local gap = math.ceil(cheapest.cost - available(cheapest))
		return nil, gap > 0 and gap or 0
	end
	return nil, 0
end

-- ═══════════════════════════════════════════════════════════
--  priced from a config row
-- ═══════════════════════════════════════════════════════════

--- Price of the next level of an UpgradeConfig row.
---
--- Rows are { baseCost, growth, cap, currency }. The nth purchase costs
--- baseCost * growth^(owned) — read straight off this place's own
--- UpgradeConfig, e.g. moreMoney baseCost=10 growth=1.15 cap=100 and
--- speedBuff baseCost=100 growth=2.2 cap=5. A row past its cap returns
--- nil rather than a price the server will refuse, which is what stops
--- a maxed upgrade being spammed forever.
function Core.upgradePrice(row, owned)
	if type(row) ~= "table" then return nil end
	local base = tonumber(row.baseCost)
	local growth = tonumber(row.growth) or 1
	if base == nil or base < 0 or growth < 1 then return nil end

	owned = math.max(0, math.floor(tonumber(owned) or 0))
	local cap = tonumber(row.cap)
	if cap ~= nil and owned >= cap then return nil end

	-- The epsilon absorbs float representation error. 100 * 2.2 comes out
	-- of the multiply as 220.00000000000003, and a bare ceil would price a
	-- 220 upgrade at 221 — an off-by-one the server never charged.
	return math.ceil(base * (growth ^ owned) - 1e-9)
end

--- Next tree node to buy, respecting the `requires` chain.
---
--- TreeConfig.NODES is 566 rows and each one names the node above it, so
--- buying cheapest-first would offer leaves whose parent is still unowned
--- and the server would reject every one. Walks for nodes whose parent is
--- already owned, then takes the cheapest of those.
---
--- nodes:   array of { id, cost, currency, tier, requires }
--- owned:   set of ids already bought
--- canAfford: entry -> boolean, so the caller owns the balance lookup
function Core.nextNode(nodes, owned, canAfford)
	if type(nodes) ~= "table" or type(canAfford) ~= "function" then return nil end
	owned = owned or {}

	local best = nil
	for _, node in ipairs(nodes) do
		if type(node) == "table" and type(node.id) == "string" and type(node.cost) == "number" then
			local needs = node.requires
			-- A requires pointing at a node we have never heard of is just
			-- locked. Not a reason to stop the loop.
			local unlocked = needs == nil or owned[needs] == true
			if not owned[node.id] and unlocked and canAfford(node) then
				if best == nil or node.cost < best.cost then best = node end
			end
		end
	end
	return best
end

-- ═══════════════════════════════════════════════════════════
--  pacing
-- ═══════════════════════════════════════════════════════════

--- Base delay plus a random spread, so a loop never fires on a metronome.
--- Clamped at zero because a spread wider than the base would otherwise
--- hand task.wait a negative number, which errors and kills the loop.
function Core.jitter(base, spread, rng)
	base = math.max(0, tonumber(base) or 0)
	spread = math.max(0, tonumber(spread) or 0)
	rng = rng or math.random
	return math.max(0, base + (rng() * 2 - 1) * spread)
end

-- ═══════════════════════════════════════════════════════════
--  world targets
--
--  Every one of these is a part name taken from this place's instance
--  tree. Trees carry Branch/Canopy/CanopyTop/Root decoration parts around
--  a separate Trunk; ore nodes carry a Stone dud beside the Veins that
--  actually pay out. Matching on the name is far cheaper and far steadier
--  than raycasting for whatever happens to be in front.
-- ═══════════════════════════════════════════════════════════

function Core.isOrePart(name) return name == "Veins" end

function Core.isCrystalName(name)
	return name == "Crystal" or name:match("^Crystal%d+$") ~= nil
end

function Core.isTreePart(name) return name == "Trunk" end

function Core.isEssenceName(name) return name == "EssenceInner" end

-- ═══════════════════════════════════════════════════════════
--  remote inventory
--
--  Every path below was read off this place's ReplicatedStorage tree.
--  Resolution is tolerant: a missing remote returns nil and the feature
--  that wanted it greys out, rather than the whole script erroring on a
--  name the developers changed last patch.
-- ═══════════════════════════════════════════════════════════

local RS = "ReplicatedStorage"
local function flat(name) return { RS, "Remotes", name } end
local function sys(folder, name) return { RS, folder, name } end

Core.REMOTES = {
	-- ── economy ──────────────────────────────────────────
	BuyStair        = flat("BuyStair"),
	BuyUpgrade      = flat("BuyUpgrade"),
	BuyTreeNode     = flat("BuyTreeNode"),
	Rebirth         = flat("Rebirth"),
	UnlockDoor      = flat("UnlockDoor"),
	SpinWheel       = flat("SpinWheel"),
	WheelResult     = flat("WheelResult"),

	-- ── shop ─────────────────────────────────────────────
	BuyPotion       = flat("BuyPotion"),
	BuyTrail        = flat("BuyTrail"),
	EquipTrail      = flat("EquipTrail"),
	PassesOwned     = flat("PassesOwned"),

	-- ── gathering ────────────────────────────────────────
	MineBlock       = flat("MineBlock"),
	MineCycle       = flat("MineCycle"),
	MineReset       = flat("MineReset"),
	Essence         = flat("Essence"),
	SmelterCollect  = flat("SmelterCollect"),
	SmelterDeposit  = flat("SmelterDeposit"),
	StarforgeDeposit= flat("StarforgeDeposit"),
	RefractorDeposit= flat("RefractorDeposit"),

	-- ── rewards and gifts ────────────────────────────────
	RedeemCode      = flat("RedeemCode"),
	CodeResult      = flat("CodeResult"),
	GiftIntent      = flat("GiftIntent"),
	GiftAnswer      = flat("GiftAnswer"),
	Totem           = flat("Totem"),

	-- ── client/server traffic ────────────────────────────
	ClientInfo      = flat("ClientInfo"),
	IncomeRates     = flat("IncomeRates"),
	LeaderboardUpdate = flat("LeaderboardUpdate"),
	SaveSetting     = flat("SaveSetting"),
	RequestRejoin   = flat("RequestRejoin"),

	-- ── developer-only, kept for detection research ──────
	AdminAction     = flat("AdminAction"),
	AdminGive       = flat("AdminGive"),

	-- ── loot systems ─────────────────────────────────────
	EmberWheel_Action  = sys("EmberWheelRemotes", "Spin"),
	EmberWheel_Result  = sys("EmberWheelRemotes", "Result"),

	Heart_Action       = sys("HeartRemotes", "Feed"),
	Heart_Result       = sys("HeartRemotes", "Result"),

	Pearl_Action       = sys("PearlRemotes", "Feed"),

	SalvageCrane_Action = sys("SalvageCraneRemotes", "Haul"),
	SalvageCrane_Result = sys("SalvageCraneRemotes", "Result"),

	SkyBalloon_Action  = sys("SkyBalloonRemotes", "Fly"),
	SkyBalloon_Result  = sys("SkyBalloonRemotes", "Result"),

	Stardust_Action    = sys("StardustRemotes", "Star"),

	Vault_Action       = sys("VaultRemotes", "Crack"),
	Vault_Result       = sys("VaultRemotes", "Result"),
	Vault_Start        = sys("VaultRemotes", "Start"),

	Wish_Action        = sys("WishRemotes", "Wish"),
	Wish_Result        = sys("WishRemotes", "Result"),

	-- ── the mirrored save layer ──────────────────────────
	DataService_Function = { RS, "Packages", "DataService", "Network", "remotes", "DataService", "RemoteFunction" },
	DataService_Event    = { RS, "Packages", "DataService", "Network", "remotes", "DataService", "RemoteEvent" },
}

--- The eight loot systems. Six answer through a Result RemoteFunction;
--- Pearl and Stardust hand their outcome back over a different remote,
--- so their auto has nothing to read and is left off by default.
Core.MINIGAMES = {
	{ name = "EmberWheel",   folder = "EmberWheelRemotes",   action = "Spin",   result = "Result" },
	{ name = "Heart",         folder = "HeartRemotes",         action = "Feed",   result = "Result" },
	{ name = "Pearl",         folder = "PearlRemotes",         action = "Feed",   result = false },
	{ name = "SalvageCrane",  folder = "SalvageCraneRemotes",  action = "Haul",   result = "Result" },
	{ name = "SkyBalloon",    folder = "SkyBalloonRemotes",    action = "Fly",    result = "Result" },
	{ name = "Stardust",      folder = "StardustRemotes",      action = "Star",   result = false },
	{ name = "Vault",         folder = "VaultRemotes",         action = "Crack",  result = "Result" },
	{ name = "Wish",          folder = "WishRemotes",          action = "Wish",   result = "Result" },
}

-- ═══════════════════════════════════════════════════════════
--  lookup
-- ═══════════════════════════════════════════════════════════

--- Walk a path from a root instance. Returns nil rather than erroring,
--- which is what keeps a rename from taking the script down.
function Core.resolve(root, path)
	local node = root
	for _, segment in ipairs(path) do
		if type(node) ~= "Instance" then return nil end
		node = node:FindFirstChild(segment)
		if node == nil then return nil end
	end
	return node
end

return Core
