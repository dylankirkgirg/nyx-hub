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
-- cost maths
-- ───────────────────────────────────────────────────────────
print("cost maths")

check("scales geometrically from base and multiplier", function()
	eq(Core.scaledCost(10, 1.5, 1), 10)  -- first costs base
	eq(Core.scaledCost(10, 1.5, 2), 15)  -- then base * mult
	eq(Core.scaledCost(10, 1.5, 3), 23)  -- 22.5 rounds up
end)

check("a fractional cost never leaks out as a fraction", function()
	-- a cost that reads 11.5 in the UI but charges 12 is the kind of
	-- off-by-one that makes a script look broken, so always round up
	local c = Core.scaledCost(10, 1.15, 2)
	eq(c, math.ceil(c), "cost was not a whole number")
end)

check("index below one clamps to base", function()
	-- config tables are 1-indexed; a 0 slipping through should not
	-- produce a cheaper-than-real stair and buy one the server rejects
	eq(Core.scaledCost(10, 1.5, 0), 10)
	eq(Core.scaledCost(10, 1.5, -5), 10)
end)

check("rounds a fractional cost up to a whole number", function()
	-- these costs get compared against whole gold balances and shown
	-- to the player; a 22.5 stair that displays as 22 but charges 23
	-- is exactly the kind of off-by-one that reads as a broken script
	eq(Core.scaledCost(10, 1.15, 2), 12) -- 11.5 -> 12
end)

check("total cost sums the whole climb", function()
	-- 10, 15, 22.5->23, 33.75->34
	eq(Core.totalCost(10, 1.5, 4), 10 + 15 + 23 + 34)
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

check("the tool's active part is its swing", function()
	eq(Core.isToolSwing("Swing"), true)
	eq(Core.isToolSwing("Handle"), false)
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
print("")
if failed == 0 then
	print(string.format("%d passed", passed))
	os.exit(0)
else
	print(string.format("%d passed, %d FAILED", passed, failed))
	os.exit(1)
end
