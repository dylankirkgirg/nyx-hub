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

`core.lua` holds the number formatter, upgrade pricing, buy choosers, pacing jitter, world-target
predicates and the full remote path table. It has no Roblox API calls in it, which is why it runs
under plain `luau` and is covered by 46 assertions. `main.lua` fetches it over HTTP and only
does the things that need the running game.

## What's built

**Farm** — auto stairs, auto doors, buy/collect delay sliders. Stairs are priced by the game's own
`StairConfig.costOf`, which is piecewise across seven growth bands rather than one flat multiplier —
a flat 1.1 model prices floor 720 at 5.8e30 instead of 10.5 trillion, so nothing here re-derives it.
Doors walk `DoorConfig.DOORS` in unlock order and check each one's own floor and currency.

**Gather** — auto mine, auto chop, auto deposit, and a one-shot state sync. Mining and chopping call
the game's own `Activated` handler on the tool rather than firing the remote, so the payload is always
the one the server expects. Neither has a safe remote fallback: `MineBlock` takes a block index this
script has no way to know, and there is no wood remote among the 31 at all, so with `getconnections`
unavailable they do nothing rather than fire something wrong.

**Upgrades** — auto buy upgrades and tree nodes, both driven by the game's own config. Upgrade rows
are `{baseCost, growth, cap, currency}`, so the price of the next one is `baseCost * growth^owned` and
an upgrade at its cap drops out instead of being spammed forever. Tree nodes price flat but carry a
`requires` chain across 566 rows, so buying cheapest-first would offer nodes whose parent is unowned;
the walk takes the cheapest node whose parent is already owned. **Both are judged against the row's
own currency** — an upgrade priced in embers cannot be paid for with gold.

**Loot** — the eight loot systems (EmberWheel, Heart, Pearl, SalvageCrane, SkyBalloon, Stardust,
Vault, Wish). Off by default, each on its own timer.

**Shop** — auto potions (fired with real ids from `PotionConfig.LIST`), auto prize wheel, a
redeem-code box.

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

## What's verified on the wire

Captured from OpenDex's Remote Spy while the user played the game:

| Remote | Payload | Confidence |
|---|---|---|
| `BuyStair` | `FireServer(floor)` — saw 73, 72, 71 | **confirmed** |
| `UnlockDoor` | `FireServer("upgradeTree")` — a door id | **confirmed** |
| `BuyTreeNode` | `FireServer("GoldMiddle1")` — a node id | **confirmed** |
| `MineBlock` | `FireServer(<int>)` — block index | confirmed shape, index unknown |
| `Essence` | `FireServer("sync")` — a command, not a purchase | **confirmed** |
| `BuyUpgrade` | an upgrade id from `UpgradeConfig.BY_ID` | high — ids read from their table |
| `BuyPotion` | a potion id from `PotionConfig.LIST` | high — ids read from their table |

## What's still a guess

| Remote | What we send | Confidence |
|---|---|---|
| `SpinWheel` | no arguments | medium — PrizeWheel costs a flat 100000, wedge is server-side |
| `Rebirth`, `RedeemCode`, `Totem`, `MineCycle`, `MineReset` | no arguments | medium |
| `SmelterCollect/Deposit`, `StarforgeDeposit`, `RefractorDeposit` | no arguments | low |
| `BuyTrail`, `EquipTrail` | no arguments | low |
| the eight loot systems | no arguments | low |

To confirm any of them: open OpenDex's Remote Spy, click the real button once, read the argument
list, put it in the `fire(...)` call. Each is one line. Where a wrong guess would be actively harmful
rather than merely rejected, the call is simply not made.

## Risks

- **Movement mods are probably fine here.** Walk speed, fly, noclip and jump power all appear in
  the paid hubs for this game, so they aren't hard-blocked. They're off by default anyway — this
  tab is one toggle away and touches nothing on the server.
- **Auto-buy sends real remote traffic** on a timer. Keep the delays human. Every loop here
  jitters its wait rather than firing on a fixed beat.
- **Owned counts start at zero** each session, so the compounding price of an upgrade restarts low
  and drifts upward as we buy. Every price is therefore an estimate for one session, never a write.
- **The game ships an `AdminAction` and `AdminGive` remote.** We map both and never touch them.
- This place updates often (last patched a day before this was written). The tolerant remote
  resolution means a rename greys a feature out instead of breaking the script — check the
  **Recon** tab first when something stops working.

## Testing

```sh
cd nyx-hub/games/tower-incremental
luau test/core_spec.lua       # 46 assertions
luau-compile --null main.lua  # syntax
luau-compile --null core.lua
```

`luau-compile` writes bytecode to stdout without `--null`.