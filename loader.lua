-- ═══════════════════════════════════════════════════════════
--  NYX HUB — one loadstring. Detects your game, launches its script.
--
--  Load this loader from a COMMIT SHA, not from /main/:
--  loadstring(game:HttpGet("https://raw.githubusercontent.com/dylankirkgirg/nyx-hub/main/loader.lua"))()
--
--  raw.githubusercontent sits behind a CDN that can hold a /main/ copy for
--  hours after a push, so a /main/ URL can hand you code from a commit
--  you already replaced — it did exactly that, serving a version that
--  threw on load. SHA-pinned paths are content-addressed, so they cannot
--  go stale. PIN below is the commit each game's script was last verified at.
-- ═══════════════════════════════════════════════════════════

local MPS       = game:GetService("MarketplaceService")
local StarterGui= game:GetService("StarterGui")

local NYX = "https://raw.githubusercontent.com/dylankirkgirg/nyx-hub/"

-- Bumped to the commit each script was last verified green at. A stale
-- /main/ URL is worse than no script: it loads a build you already fixed.
local PIN = "a2cb8c3"

-- game-name match (case-insensitive substring)  ->  main.lua URL
local GAMES = {
	{ match = "anime dice", name = "Anime Dice",
	  url = "https://raw.githubusercontent.com/dylankirkgirg/anime-dice/main/src/main.lua" },
	{ match = "steal a", name = "Steal An Egg", -- catches "Steal a Brainrot"-style renames too
	  url = "https://raw.githubusercontent.com/dylankirkgirg/steal-an-egg/main/src/main.lua" },
	{ match = "tower incremental", name = "Tower Incremental",
	  url = NYX .. PIN .. "/games/tower-incremental/main.lua" },
	-- more games slot in here as we build them
}

-- shared Nyx skin — injected so every game script themes identically
getgenv().Nyx = getgenv().Nyx or {}
getgenv().Nyx.theme = {
	BackgroundColor = Color3.fromRGB(16, 12, 15),
	MainColor       = Color3.fromRGB(25, 19, 23),
	AccentColor     = Color3.fromRGB(233, 122, 173),
	OutlineColor    = Color3.fromRGB(50, 39, 46),
	FontColor       = Color3.fromRGB(240, 232, 237),
}

local function notify(text, dur)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Nyx Hub", Text = text, Duration = dur or 4 })
	end)
end

-- resolve current game's name
local placeName = ""
pcall(function() placeName = MPS:GetProductInfo(game.PlaceId).Name end)
local lower = placeName:lower()

local hit
for _, g in ipairs(GAMES) do
	if lower:find(g.match, 1, true) then hit = g; break end
end

if not hit then
	notify("No Nyx script for this game yet (" .. (placeName ~= "" and placeName or "unknown") .. ")", 6)
	return
end

notify("Loading " .. hit.name .. " …", 3)
local ok, src = pcall(function() return game:HttpGet(hit.url) end)
if not ok then notify("Fetch failed for " .. hit.name, 5); return end

local fn, err = loadstring(src)
if not fn then notify("Compile error: " .. tostring(err), 6); return end
fn()
