# Tower Incremental — Nyx

Script for `[UPD7] Tower Incremental` (Lucky CStudios, placeId `75766778174856`,
universeId `10765067592`).

Loaded by `nyx-hub/loader.lua`. To run it directly:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dylankirkgirg/nyx-hub/main/loader.lua"))()
```

---

## How this was built

Recon was done with OpenDex against a live session, not against a wiki or a
public API. Three things came out of that and they shape everything below.

**The decompiler is dead on this place.** Every script reads back as
`lines: 1, functions: 0`, `source` returns `failed to decompile script`, and
`search` matches nothing — including for `FireServer`. All static analysis is a
dead end here. Confirmed three separate ways before switching approach.

**Every remote goes through one generic dispatcher.** `Shared.Remotes` names
31 remotes, but no script references any of them by name — they all funnel
through `NetworkerClient.fire()`. That is exactly why name search returned
nothing.

**Remote Spy is the only working lens.** Arguments do not exist in the object
tree; they exist at the moment of the call. Everything below marked *verified*
was captured that way.

---

## What's verified on the wire

Captured by Remote Spy, with the client script it came from.

| Remote | Payload | Fired from |
| --- | --- | --- |
| `BuyStair` | `FireServer(<int floor>)` | `Client.StairClient` L157 |
| `UnlockDoor` | `FireServer(<door id string>)` | `Client.DoorClient` L75 |
| `BuyTreeNode` | `FireServer(<node id string>)` | `Client.TreeClient` L91 |
| `MineBlock` | `FireServer(<int>)` | `Client.MineClient` L127 |
| `Essence` | `FireServer("sync")` | `Client.EssenceClient` L35 |

`BuyUpgrade(<upgrade id>)` and `BuyPotion(<potion id>)` are not spied, but
`UpgradeConfig.BY_ID` and `PotionConfig.LIST` are keyed by exactly those
strings, so the payload is taken from the game's own table rather than guessed.

## What's still a guess

| Remote | Confidence | Why |
| --- | --- | --- |
| `Rebirth` | medium | no capture; array position is the tier number |
| `SpinWheel` | medium | costs a flat 100000 gold server-side, so a zero-arg call is likely right |
| `MineCycle`, `MineReset` | medium | no capture; both are one-shot buttons, not loops |
| `BuyTrail`, `EquipTrail`, `Totem` | medium | ids read from the config's own tables |
| `SmelterCollect`, `SmelterDeposit`, `StarforgeDeposit`, `RefractorDeposit` | low | no capture, no argument data |
| the 8 loot systems | low | no capture, and all eight sit behind doors that cost more than any balance reached so far |

Every guess is a single `fire(...)` call site and costs one edit to correct.

---

## Bugs the recon caught

These are listed because each one produced a feature that looked alive and did
nothing at all.

**`BuyStair` was fired with no arguments.** The remote takes a floor number.

**`UnlockDoor` was fired with the integers `1,2,3,4,5`.** It takes a door id
string — the spy caught the real one going out as `"upgradeTree"`.

**`Essence("sync")` was being spammed as an auto-collect.** It is a state
request. It is now a single button that does what its name says.

**The upgrade catalogue was reading `entry.Id`.** The rows key on lowercase
`id`, so `catalogue()` was returning **0 of 142 upgrades and 0 of 566 tree
nodes**. The feature had never loaded anything.

**Upgrade prices were read as a flat number.** Rows are
`{baseCost, growth, cap}` — the price is `baseCost * growth^owned`, so capped
upgrades were being re-bought forever at a price that no longer existed.

**Affordability was judged against gold for every upgrade.** Each row declares
its own currency, so an ember-priced upgrade was being offered against a gold
balance and would have been rejected on arrival.

**Stair cost was modelled as a flat 1.1 multiplier.** `StairConfig` uses seven
piecewise growth bands. Floor 720 costs 10.5 trillion where the flat model said
5.8e30 — twenty orders of magnitude. It now calls the game's own `costOf`.

**Tree nodes have a `requires` chain.** Cheapest-first was offering nodes whose
parent did not exist yet.

---

## Coverage

46 remotes are declared and resolved tolerantly. **18 are fired.** The rest are
not oversights:

- **2 are admin-only** (`AdminAction`, `AdminGive`). Firing them is admin abuse
  and the loudest possible detection signal. Left unwired on purpose.
- **14 are inbound** — `CodeResult`, `GiftAnswer`, `LeaderboardUpdate`,
  `PassesOwned`, `IncomeRates`, `ClientInfo`, `RequestRejoin`, `WheelResult` and
  the six `*_Result` remotes. The server sends these; there is nothing to fire.
- **`SaveSetting`** is skipped because Obsidian persists its own toggles.

Config modules required: 20. Used: 14.

## Tabs

Farm · Gather · Upgrades · Rebirth · Glyphs · Totems · Trails · Loot · Shop ·
ESP · Recon · Player · Settings.

Systems that have no remote at all are driven through the game's own config
functions rather than a remote we would have to invent a payload for:

- **Glyphs** — `GlyphConfig.roll`, the game's own picker, so the odds and the
  41-set bookkeeping stay correct.
- **Chopping and crystals** — `WoodConfig.target` / `CrystalConfig.target` hand
  out the spot to work and `holdSeconds` says how long to hold it.
- **Mining** — `MineConfig.oreCells` / `remoteBlocksPerOre` / `REMOTE_MOVE_SECONDS`.
  Falls back to driving the pickaxe handler when no cell list is available,
  rather than firing a made-up index.

---

## Layout and verification

```
main.lua        1187 lines   Roblox side
core.lua         380 lines   pure logic, no Roblox API
test/core_spec.lua           55 assertions
```

```sh
cd games/tower-incremental
luau test/core_spec.lua      # 55 passed
luau-compile --null main.lua
luau-analyze main.lua core.lua
```

`core.lua` holds every decision that can be wrong without throwing — number
formatting, cost maths, buy ordering, rebirth tier selection, pacing jitter,
world-target predicates and the full remote path table. It contains no Roblox
calls, which is the entire reason it can be tested. `main.lua` fetches it at
runtime and holds everything that needs the live game.

## Known limits

- **Owned counts start at zero each session.** Prices are therefore session
  estimates; the buy loop will offer a capped upgrade once more at the start of
  a session before the server rejects it.
- **The decompiler is unavailable**, so no script in this place has been read
  line by line. Every id and price comes from a config table read at runtime,
  which is a stronger source anyway, but it does not describe the logic.
- **`Rebirth` payload is unverified.** Take one manually in-game with Remote Spy
  running and it can be confirmed the same way the other five were.