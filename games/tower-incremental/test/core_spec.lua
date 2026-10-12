-- ═══════════════════════════════════════════════════════════
--  Tower Incremental — core logic tests
--  Run from this directory:  luau test/core_spec.lua
--
--  core.lua holds every decision the script makes that can be
--  wrong without throwing: number formatting, cost maths, which
--  upgrade to buy next, pacing jitter, which world parts are real
--  targets. None of it touches a Roblox API, so it all runs here.
--  Anything that needs the game lives in main.lua instead.
-- ═══════════════════════════════════════════════════════════

local Core = require("../core")

local passed, failed = 0, 0

local function check(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok    " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. "  --  " .. tostring(err))
	end
end

local function eq(got, want, msg)
	if got ~= want then
		error((msg or "mismatch") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
	end
end

-- ───────────────────────────────────────────────────────────
-- format
-- ───────────────────────────────────────────────────────────
print("format")

check("plain numbers keep their digits", function()
	eq(Core.format(0), "0")
	eq(Core.format(7), "7")
	eq(Core.format(999), "999")
end)

check("crosses each suffix at the right magnitude", function()
	eq(Core.format(1000), "1.00K")
	eq(Core.format(1500), "1.50K")
	eq(Core.format(1e6), "1.00M")
	eq(Core.format(2.5e9), "2.50B")
	eq(Core.format(1e12), "1.00T")
	eq(Core.format(1e15), "1.00Qa")
	eq(Core.format(1e18), "1.00Qi")
end)

check("keeps three significant digits, never zero-pads to four", function()
	-- 12345 -> 12.3K, not 12.35K. incremental UIs drop the noise digit.
	eq(Core.format(12345), "12.3K")
	eq(Core.format(1234), "1.23K")
	eq(Core.format(999999), "1000K") -- rounds up into the next suffix, not "1000.0K"
end)

check("survives garbage input without throwing", function()
	-- balances come off the network and can be nil/NaN; a formatter that
	-- throws would take the whole auto-buy loop down with it.
	eq(Core.format(nil), "0")
	eq(Core.format(0 / 0), "0")
	eq(Core.format(-5), "0")
	eq(Core.format("nope"), "0")
end)

check("rates read like the game does", function()
	eq(Core.format(216000), "216K")
	eq(Core.format(328000000), "328M")
end)

-- ───────────────────────────────────────────────────────────
-- picking what to buy next
-- ───────────────────────────────────────────────────────────
print("pickBest")

local SHOP = {
	{ id = "a", cost = 100 },
	{ id = "b", cost = 5000 },
	{ id = "c", cost = 250 },
	{ id = "d", cost = 10000 },
}

check("buys the most expensive thing affordable", function()
	-- in an incremental, spending the most gold you can is almost always
	-- the right move: cheap buys stall progress and cost the same click
	local pick, short = Core.pickBest(SHOP, 6000)
	eq(pick.id, "b")
	eq(short, 0)
end)

check("falls back down the price ladder when richer", function()
	local pick = Core.pickBest(SHOP, 999999)
	eq(pick.id, "d")
end)

check("buys the cheapest when barely starting", function()
	local pick = Core.pickBest(SHOP, 100)
	eq(pick.id, "a")
end)

check("exact balance is affordable, not short", function()
	local pick, short = Core.pickBest(SHOP, 5000)
	eq(pick.id, "b")
	eq(short, 0)
end)

check("one coin short of the top item drops to the next one down", function()
	-- doing nothing here would be wrong: 4999 buys the 250 upgrade fine,
	-- and in an incremental stalling on a save is worse than buying less
	local pick, short = Core.pickBest(SHOP, 4999)
	eq(pick.id, "c")
	eq(short, 0)
end)

check("nothing affordable returns nil and the exact shortfall", function()
	local pick, short = Core.pickBest(SHOP, 10)
	eq(pick, nil)
	eq(short, 90) -- cheapest entry is a at 100
end)

check("a rich balance still reports no shortfall", function()
	local _, short = Core.pickBest(SHOP, 1e12)
	eq(short, 0)
end)

check("empty or nil catalogue never throws", function()
	local pick, short = Core.pickBest({}, 1000)
	eq(pick, nil)
	eq(short, 0)
	eq(select(1, Core.pickBest(nil, 1000)), nil)
end)

-- An upgrade priced in embers cannot be paid for with gold. Judging the
-- whole catalogue against one balance is how a script ends up firing buys
-- the server refuses every tick.
check("each entry is judged against its own currency", function()
	local MIXED = {
		{ id = "goldCheap", cost = 100, currency = "gold" },
		{ id = "emberFat",  cost = 900, currency = "embers" },
		{ id = "silverMid", cost = 250, currency = "silver" },
	}
	local bag = { gold = 5000, silver = 9000, embers = 100 }

	-- The most expensive row is priced in embers and we hold 100 of them.
	-- Judged against the gold balance it would look affordable and win;
	-- judged against its own currency it loses to the 250 silver row.
	local pick = Core.pickBest(MIXED, 0, {
		balance = function(c) return bag[c] or 0 end,
	})
	eq(pick.id, "silverMid")

	-- With enough embers the same row does win.
	bag.embers = 5000
	pick = Core.pickBest(MIXED, 0, {
		balance = function(c) return bag[c] or 0 end,
	})
	eq(pick.id, "emberFat")
end)

check("a per-currency buyer still reports a shortfall", function()
	local MIXED = {
		{ id = "a", cost = 100, currency = "gold" },
		{ id = "b", cost = 900, currency = "gold" },
	}
	local bag = { gold = 10 }
	local pick, short = Core.pickBest(MIXED, 0, {
		balance = function(c) return bag[c] or 0 end,
	})
	eq(pick, nil)
	eq(short, 90)
end)

check("without a balance function it behaves exactly as before", function()
	local pick = Core.pickBest(SHOP, 999999)
	eq(pick.id, "d")
end)

check("a currency the bag has never heard of is worth zero", function()
	local bag = { gold = 99999 }
	local row = { { id = "x", cost = 40, currency = "prisms" } }
	local pick, short = Core.pickBest(row, 0, {
		balance = function(c) return bag[c] or 0 end,
	})
	eq(pick, nil)
	eq(short, 40) -- gold cannot buy prisms, no matter how much of it there is

	bag.prisms = 40
	pick = Core.pickBest(row, 0, {
		balance = function(c) return bag[c] or 0 end,
	})
	eq(pick.id, "x")
end)

check("skips entries with an unusable cost", function()
	-- a config entry can be locked, disabled, or shaped differently from
	-- its siblings; one bad row must not stop the whole auto-buy
	local pick = Core.pickBest({ { id = "x", cost = 0 }, { id = "y" }, { id = "z", cost = 50 } }, 100)
	eq(pick.id, "z")
end)

check("honours a max tier so it does not spam the last row", function()
	-- once every upgrade is maxed the entries stop leaving the table, and
	-- firing the last one forever looks nothing like a person clicking
	local pick = Core.pickBest(SHOP, 999999, { maxTier = 2 })
	eq(pick.id, "b")
end)

-- ───────────────────────────────────────────────────────────
-- pacing
-- ───────────────────────────────────────────────────────────
print("pacing")

check("jitter stays inside the stated spread", function()
	local seed = 0
	local function rng() -- deterministic stand-in for math.random
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 200 do
		local d = Core.jitter(1000, 200, rng)
		if d < 800 or d > 1200 then error("jitter escaped the band: " .. tostring(d), 2) end
	end
end)

check("zero spread is exactly the base delay", function()
	eq(Core.jitter(750, 0, function() return 0.5 end), 750)
end)

check("delay never goes negative on a silly spread", function()
	-- a spread wider than the base would otherwise emit negative waits,
	-- and task.wait(-n) errors and kills the loop
	local d = Core.jitter(100, 500, function() return 1 end)
	if d < 0 then error("negative delay: " .. tostring(d), 2) end
end)

-- ───────────────────────────────────────────────────────────
-- world targets
-- ───────────────────────────────────────────────────────────
print("targets")

check("ore is the veins, never the stone", function()
	-- Mine.IronOre holds a Veins part and a Stone part; only Veins pays out
	eq(Core.isOrePart("Veins"), true)
	eq(Core.isOrePart("Stone"), false)
end)

check("recognises every crystal tier by name", function()
	eq(Core.isCrystalName("Crystal"), true)
	eq(Core.isCrystalName("Crystal1"), true)
	eq(Core.isCrystalName("Crystal4"), true)
	-- Deliberately open-ended: this place ships Crystal through Crystal4
	-- today, and if a fifth tier lands we want it highlighted without a
	-- code change. The pattern is anchored, so CrystalCavern and friends
	-- still don't match.
	eq(Core.isCrystalName("Crystal5"), true)
	eq(Core.isCrystalName("CrystalCavern"), false)
	eq(Core.isCrystalName("Essence"), false)
end)

check("the chop target is the trunk", function()
	eq(Core.isTreePart("Trunk"), true)
	eq(Core.isTreePart("Canopy"), false)
	eq(Core.isTreePart("Branch"), false)
	eq(Core.isTreePart("Root"), false)
end)

check("essense orbs are found by their inner marker", function()
	-- Currency.Essence nests the real marker under an EssenceInner part
	eq(Core.isEssenceName("EssenceInner"), true)
	eq(Core.isEssenceName("EssenceGlow"), false)
end)

-- ───────────────────────────────────────────────────────────
-- remote inventory
-- ───────────────────────────────────────────────────────────
print("remotes")

check("every remote path we rely on is rooted at ReplicatedStorage", function()
	-- one game ships a Packages/DataService layer and the rest sit flat;
	-- a path missing its root would resolve to nil at runtime
	for name, path in pairs(Core.REMOTES) do
		eq(path[1], "ReplicatedStorage", name .. " has no ReplicatedStorage root")
		eq(type(path[2]), "string", name .. " has no first segment")
	end
end)

check("every minigame has the action remote it needs", function()
	-- eight loot systems, all shaped the same way; Pearl and Stardust are
	-- the two that answer on a different remote instead of Result
	for _, g in pairs(Core.MINIGAMES) do
		eq(Core.REMOTES[g.name .. "_Action"] ~= nil, true, g.name .. " has no action remote")
		if g.result then
			eq(Core.REMOTES[g.name .. "_Result"] ~= nil, true, g.name .. " has no Result remote")
		end
	end
end)

check("the minigame list is the whole set, not a subset", function()
	local n = 0
	for _ in pairs(Core.MINIGAMES) do n += 1 end
	eq(n, 8)
end)

check("known remotes are all still accounted for", function()
	-- if the game renames one, this is the line that tells us which
	eq(Core.REMOTES.BuyStair ~= nil, true)
	eq(Core.REMOTES.Rebirth ~= nil, true)
	eq(Core.REMOTES.UnlockDoor ~= nil, true)
end)

-- ───────────────────────────────────────────────────────────
-- upgrade price
--
-- UpgradeConfig rows are {baseCost, growth, cap, currency}. The real
-- nth price is baseCost * growth^(owned) -- verified against the game:
-- moreMoney baseCost=10 growth=1.15, speedBuff baseCost=100 growth=2.2.
-- ───────────────────────────────────────────────────────────
print("upgradePrice")

check("first purchase is the base cost", function()
	local row = { baseCost = 10, growth = 1.15, cap = 100 }
	eq(Core.upgradePrice(row, 0), 10)
end)

check("price compounds by growth per level owned", function()
	local row = { baseCost = 10, growth = 1.15, cap = 100 }
	eq(Core.upgradePrice(row, 1), 12)   -- ceil(11.5)
	eq(Core.upgradePrice(row, 2), 14)   -- ceil(13.225)
	eq(Core.upgradePrice(row, 3), 16)   -- ceil(15.20875)
end)

check("a steep growth row steps hard", function()
	-- speedBuff baseCost=100 growth=2.2 cap=5
	local row = { baseCost = 100, growth = 2.2, cap = 5 }
	eq(Core.upgradePrice(row, 0), 100)
	eq(Core.upgradePrice(row, 1), 220)
	eq(Core.upgradePrice(row, 2), 484)  -- exactly 484; the raw multiply reads 484.00000000000006
	eq(Core.upgradePrice(row, 3), 1065)  -- ceil(1064.8)
end)

check("a capped upgrade reports nothing rather than a price it won't sell", function()
	local row = { baseCost = 10, growth = 1.15, cap = 3 }
	eq(Core.upgradePrice(row, 3), nil)
end)

check("growth 1 means one flat price forever", function()
	-- the keepers are growth=1 cap=1 permanent
	local row = { baseCost = 500, growth = 1, cap = 1 }
	eq(Core.upgradePrice(row, 0), 500)
	eq(Core.upgradePrice(row, 1), nil)
end)

check("a flat-cost row without growth still prices once", function()
	eq(Core.upgradePrice({ baseCost = 42 }, 0), 42)
end)

check("a malformed row prices to nil instead of throwing", function()
	eq(Core.upgradePrice(nil, 0), nil)
	eq(Core.upgradePrice({}, 0), nil)
	eq(Core.upgradePrice({ baseCost = "free" }, 0), nil)
	eq(Core.upgradePrice({ baseCost = 10, growth = 0 }, 0), nil)
end)

check("the next price still compounds past level cap when cap is absent", function()
	eq(Core.upgradePrice({ baseCost = 10, growth = 2 }, 4), 160)
end)

-- ───────────────────────────────────────────────────────────
-- tree dependencies
--
-- TreeConfig.NODES has 566 rows; each carries a `requires` naming the
-- node above it. Cheapest-first therefore buys leaves whose parent is
-- still unowned and stalls. Real rows:
--   GoldMiddle1 tier1 root   cost=100 silver
--   GoldLeft1   tier2 left   cost=250 requires=GoldMiddle1
--   LuckLeft1   tier3 left   cost=600 requires=GoldLeft1
-- ───────────────────────────────────────────────────────────
print("treeOrder")

local GOLD_NODES = {
	{ id = "GoldMiddle1", cost = 100, tier = 1, currency = "silver", requires = nil },
	{ id = "GoldLeft1",   cost = 250, tier = 2, currency = "silver", requires = "GoldMiddle1" },
	{ id = "LuckLeft1",   cost = 600, tier = 3, currency = "silver", requires = "GoldLeft1" },
}

check("a node whose parent is unowned is not offered", function()
	local pick = Core.nextNode(GOLD_NODES, {}, function() return true end)
	eq(pick.id, "GoldMiddle1")
end)

check("once the parent is owned the next link in the chain unlocks", function()
	local owned = { GoldMiddle1 = true }
	local pick = Core.nextNode(GOLD_NODES, owned, function() return true end)
	eq(pick.id, "GoldLeft1")
end)

check("the chain walks all the way down", function()
	local owned = { GoldMiddle1 = true, GoldLeft1 = true }
	local pick = Core.nextNode(GOLD_NODES, owned, function() return true end)
	eq(pick.id, "LuckLeft1")
end)

check("the cheapest unlocked node wins, not the most expensive", function()
	-- LuckLeft1 (600) is unlocked and affordable but is three tiers deep;
	-- buying it over GoldLeft1 (250) would spend the wrong currency first.
	local owned = { GoldMiddle1 = true }
	local pick = Core.nextNode(GOLD_NODES, owned, function(entry) return entry.cost <= 300 end)
	eq(pick.id, "GoldLeft1")
end)

check("a node in its own currency the player cannot afford is skipped", function()
	local pick = Core.nextNode(GOLD_NODES, {}, function(entry) return entry.currency ~= "silver" end)
	eq(pick, nil)
end)

check("no unlocked affordable node returns nil, not a throw", function()
	eq(Core.nextNode(GOLD_NODES, { GoldMiddle1 = true, GoldLeft1 = true, LuckLeft1 = true },
		function() return true end), nil)
	eq(Core.nextNode({}, {}, function() return true end), nil)
	eq(Core.nextNode(nil, {}, function() return true end), nil)
end)

check("a requires pointing at a node that does not exist is simply locked", function()
	local rows = { { id = "Orphan", cost = 10, tier = 1, requires = "NoSuchNode" } }
	eq(Core.nextNode(rows, {}, function() return true end), nil)
end)

check("a node already owned is never re-offered", function()
	local owned = { GoldMiddle1 = true }
	local pick = Core.nextNode(GOLD_NODES, owned, function() return true end)
	eq(pick.id, "GoldLeft1")
	eq(pick.id == "GoldMiddle1", false)
end)

-- ───────────────────────────────────────────────────────────
print("pickCheapest")

local SHOP_ROWS = {
	{ id = "gold5x",   cost = 5000,  currency = "gold" },
	{ id = "gold",     cost = 1000,  currency = "gold" },
	{ id = "volts2x",  cost = 2000,  currency = "volts" },
}

check("pickCheapest takes the cheapest thing the balance covers", function()
	local bal = { gold = 3000, volts = 0 }
	local of = function(c) return bal[c] or 0 end
	eq(Core.pickCheapest(SHOP_ROWS, of).id, "gold")
end)

check("pickCheapest judges each row against its own currency", function()
	-- rich in volts, broke in gold. A gold-only check would see nothing
	-- affordable at all and sit idle next to a buy it can actually make.
	local bal = { gold = 300, volts = 2500 }
	local of = function(c) return bal[c] or 0 end
	eq(Core.pickCheapest(SHOP_ROWS, of).id, "volts2x")
end)

check("pickCheapest returns nil when nothing is affordable", function()
	eq(Core.pickCheapest(SHOP_ROWS, function() return 0 end), nil)
end)

check("a row with no cost is not treated as free", function()
	local rows = { { id = "unknown" }, { id = "paid", cost = 10, currency = "gold" } }
	eq(Core.pickCheapest(rows, function() return 100 end).id, "paid")
end)

-- ───────────────────────────────────────────────────────────
print("nextRebirth")

local REBIRTH_TIERS = {
	{ index = 1, currency = "gold",    cost = 1e9,   floor = 40 },
	{ index = 2, currency = "gold",    cost = 9.7e10, floor = 60 },
	{ index = 9, currency = "essence", cost = 1.2e10, floor = 90 },
}

check("nextRebirth returns the lowest tier we can afford and reach", function()
	local bal = { gold = 2e9, essence = 0 }
	local t = Core.nextRebirth(REBIRTH_TIERS, {
		balance = function(c) return bal[c] or 0 end, floor = 100, rebirths = 0 })
	eq(t.index, 1)
end)

check("nextRebirth skips tiers we are short on gold for", function()
	-- too broke for either gold tier, but sitting on essence
	local bal = { gold = 5e8, essence = 1e12 }
	local t = Core.nextRebirth(REBIRTH_TIERS, {
		balance = function(c) return bal[c] or 0 end, floor = 100, rebirths = 0 })
	eq(t.index, 9)
end)

check("nextRebirth skips tiers above the floor we have climbed to", function()
	-- rich enough for all three, but not high enough on the tower for any
	local bal = { gold = 1e12, essence = 1e12 }
	local t = Core.nextRebirth(REBIRTH_TIERS, {
		balance = function(c) return bal[c] or 0 end, floor = 30, rebirths = 0 })
	eq(t, nil)
end)

check("nextRebirth skips a tier already owned", function()
	local bal = { gold = 1e12, essence = 0 }
	local t = Core.nextRebirth(REBIRTH_TIERS, {
		balance = function(c) return bal[c] or 0 end, floor = 200, rebirths = 0,
		owned = { [1] = true } })
	eq(t.index, 2)
end)

check("nextRebirth honours a tier's rebirth requirement", function()
	local tiers = {
		{ index = 1, currency = "gold",    cost = 1e9 },
		{ index = 9, currency = "essence", cost = 1.2e10, rebirths = 2 },
	}
	local bal = { gold = 5e8, essence = 1e12 }
	local of = function(c) return bal[c] or 0 end
	-- tier 9 is affordable in essence but wants 2 rebirths: locked at 0,
	-- open once we have them. tier 1 is owned either way so it can't win.
	local done = { owned = { [1] = true } }
	eq(Core.nextRebirth(tiers, { balance = of, floor = 200, rebirths = 0, owned = done.owned }), nil)
	eq(Core.nextRebirth(tiers, { balance = of, floor = 200, rebirths = 5, owned = done.owned }).index, 9)
end)

-- ───────────────────────────────────────────────────────────
print("")
if failed == 0 then
	print(string.format("%d passed", passed))
	os.exit(0)
else
	print(string.format("%d passed, %d FAILED", passed, failed))
	os.exit(1)
end
