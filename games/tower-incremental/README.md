# Tower Incremental — Nyx

Script for **[UPD7] Tower Incremental** by Lucky CStudios (placeId `75766778174856`).

Obsidian UI, dark rose skin, shared with every other Nyx script through `nyx-hub`.

## Install

Drop `loader.lua` in Opiumware's autoexec folder, or run the loadstring directly:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dylankirkgirg/nyx-hub/main/loader.lua"))()
```

RightShift toggles the window.

## Layout

```
nyx-hub/loader.lua        the loadstring entry point — the hub, not this game
main.lua      everything that needs the live game
core.lua      every decision that could be wrong without throwing
test/core_spec.lua  run from this folder with: luau test/core_spec.lua
```

`core.lua` holds the number formatter, cost maths, buy chooser, pacing jitter, world-target
predicates and the full remote path table. It has no Roblox API calls in it, which is why it runs
under plain `luau` and is covered by 32 assertions. `main.lua` fetches it over HTTP and only
does the things that need the running game.

## What's built

**Farm** — auto stairs, auto doors, buy/collect delay sliders.

**Gather** — auto mine, auto chop, auto gather, auto deposit. Mining and chopping call the game's
own `Activated` handler on the tool rather than firing the remote, so the payload is always the one
the server expects.

**Upgrades** — auto buy upgrades and tree nodes. Both read their **id lists and costs out of the
game's own `Shared.UpgradeConfig` and `Shared.TreeConfig` at runtime**, then buy the most expensive
thing the balance covers. Nothing is hardcoded, so a patch that adds a tier doesn't break it.

**Loot** — the eight loot systems (EmberWheel, Heart, Pearl, SalvageCrane, SkyBalloon, Stardust,
Vault, Wish). Off by default, each on its own timer.

**Shop** — auto potions, auto prize wheel, a redeem-code box.

**ESP** — ore veins, crystals, trees, essence orbs. These are `Highlight` objects on **named
parts**, not raycasts. `Mine.IronOre` carries a `Veins` part that pays and a `Stone` part that
doesn't, and a tree's decoration parts all sit beside the `Trunk` that actually takes a hit.

**Recon** — reports which remotes resolved this session and which configs loaded. This is the tab
you look at when a feature greys out.

**Player** — walk speed, jump, gravity, noclip, fly, teleport to the highest stair.

## Deliberately NOT built

- **Writing balances.** The game keeps saves behind ProfileStore, server-side and profile-locked.
  A client-side write does nothing except get you flagged.
- **Global `__namecall` hooking.** That approach kicked us in Steal An Egg. Nothing here hooks
  anything at the global level.
- **Auto-redeem of leaked codes, auto-join, anything that talks to other players.** GiftAnswer,
  GiftIntent and LeaderboardUpdate exist and are mapped, unused.
- **Anti-AFK.** It's a remote in most scripts of these hubs but there's no AFK remote in this
  place's tree, and faking it server-side isn't worth the attention.
- **ESP on players.** No wallhack. The object ESP above is for gathering nodes.

## What's unverified

The remote **names and paths are read off this place's ReplicatedStorage tree and are correct**.
What isn't verified is the **payload each one expects** — we never captured a live call.

That matters for the ones that need arguments:

| Remote | What we send | Confidence |
|---|---|---|
| `BuyUpgrade`, `BuyTreeNode` | an id taken from the game's own config | high — the id comes from their table |
| `BuyStair`, `Rebirth`, `SpinWheel`, `BuyPotion` | no arguments | medium — likely zero-arg, unconfirmed |
| `UnlockDoor` | `1..5` | low — door ids unconfirmed |
| the eight loot systems | no arguments | low |

Everything zero-arg and low-confidence is a one-line fix in `fire(...)` calls in `main.lua`.
To confirm: open OpenDex's Remote Spy, click the real button once, read the argument list, and put
it in. Each is already wrapped so a bad guess fails silently rather than erroring the loop.

## Risks

- **Movement mods are probably fine here.** Walk speed, fly, noclip and jump power all appear in
  the paid hubs for this game, so they aren't hard-blocked. They're off by default anyway — this
  tab is one toggle away and touches nothing on the server.
- **Auto-buy sends real remote traffic** on a timer. Keep the delays human. Every loop here
  jitters its wait rather than firing on a fixed beat.
- **The game ships an `AdminAction` and `AdminGive` remote.** We map both and never touch them.
- This place updates often (last patched a day before this was written). The tolerant remote
  resolution means a rename greys a feature out instead of breaking the script — check the
  **Recon** tab first when something stops working.

## Testing

```sh
cd tower-incremental
luau test/core_spec.lua     # 32 assertions
luau-compile main.lua   # syntax
luau-compile core.lua
```