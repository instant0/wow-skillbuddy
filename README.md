# Skilly (development README)

WoW Forever 1.60.1 craft advisor. `Interface: 16001`. Author: `faslkjd56`.

**This is NOT the user readme.** The shipped file is `README.txt`. This file is
development information only: it is not a task tracker and is not updated for
intermediate feature work.

## Documentation roles

- `README.md` — this file: design, layout, checks, and build instructions.
- `AGENTS.md` — short agent contract (goal, areas, layout, task rules).
- `.agent/tasks-contract.md` — task-system paths, limits, roles, and handoffs.
- `TASKS.md` — ordered pending-task list; the top pending entry is next.
- `tasks/<area>/<ID>-<slug>.md` — one plan per pending task.
- `tasks/archive/` — completed plans, kept verbatim.
- `README.txt` — shipped user guide: what the addon does and its commands.
  Updated only for a release.

## Current status

Version **0.3.1**. Test build. The recommendation engine is real and wired to
`/skilly`, `/skilly best|cheap`, `/skilly debug`, `/skilly export`, `/skilly bank`,
and `/skilly trainer`. Bank cache (SB-59/SB-62), Professions companion anchor
(SB-63, opt-in), auto-advice on profession open (SB-64, opt-in), and persisted
learned-recipe/trainer caches (SB-66) have implementation/evidence; some tasks
await review/archive consolidation. Chat remains authoritative.

## Layout

| File | Role |
|---|---|
| `Skilly.toc` | Load order, interface version, saved variables, version |
| `Data.lua` | Bundled game data: thresholds, vendor prices, material pressure, difficulty bands |
| `Core.lua` | Command registry, defaults/DB init, feature registry, internal helpers |
| `Probe.lua` | Read-only diagnostics / probe report |
| `Trainer.lua` | Live trainer capture and account-wide trainer cache |
| `Scan.lua` | Profession/trade-skill snapshot and learned-recipe cache refresh |
| `Sources.lua` | Price/count source adapters and reset hooks |
| `Bank.lua` | Per-character bank cache capture/report/clear |
| `Cost.lua` | Material cost and availability resolution |
| `Observe.lua` | Bounded craft observation hooks |
| `Rank.lua` | Probability, ranking, descriptions |
| `Hints.lua` | Unlock/cross-skill hint helpers |
| `UI.lua` | Result/export windows, companion anchor, auto-advice hooks |
| `Skilly.lua` | Settings, commands, bootstrap/events |
| `Bindings.xml` | Keybinding target |
| `README.txt` | User-facing readme (shipped) |
| `README.md` | This file (not shipped) |
| `AGENTS.md` | Agent contract (not shipped) |
| `TASKS.md` | Pending-task priority list (not shipped) |

Task priorities are in `TASKS.md`; design decisions are in
`plans/skilly.md`. `tests/`, `tasks/`, and `plans/` are gitignored. None of
these development files are shipped.

## Design rules

- **Safety.** Every external call is `pcall`-wrapped and type-checked. Zero,
  stale, wrong-type, or errored values mean "no data".
- **Prices.** Manual overrides always win. Otherwise **cheapest reliable price
  wins**; the source only breaks ties (`as-if` → `vendor` → full AH → TSM).
  Labels stay separate: `manual`, `as-if`, `vendor`, `auctionator`,
  `auctioneer`, `tsm`, `default`.
- **Adapters.** Optional and read-only. Register only when a public API global
  exists. No `IsAddOnLoaded`, no SavedVariable reads of other addons, no UI
  opening.
- **Ranking.** Live client color is authoritative for skill-up probability.
  Thresholds come from the pinned game-data table, then band estimates.
  Partial/missing prices use scarcity estimates (tier, ease, rarity,
  cross-skill). Known prices stay literal; `fullCost` is never polluted with
  estimates. Equal-color recipes rank by out-of-pocket cost per expected point
  plus acquisition grade. Any crafts-per-point observation stays bounded and
  never overrides orange or gray.
- **Scope.** WoW Forever 1.60.1 only. No Ace3, no embedded libs, no generated
  tables copied from other addons. Bundled data is independently derived from
  public game data and pinned to build `1.60.1.71037`.

## Data provenance

- Thresholds: wago.tools `SkillLineAbility` CSV, build `1.60.1.71037`.
- Vendor prices and material metadata: public item data (WoWhead item XML),
  cross-checked against wago.tools `SpellReagents` for the same build.
- Guide cross-check: public Forever leveling guides were used only as anchors
  for material tier chains and cross-skill patterns. Guide skill bands are
  routes, not color thresholds, and were not copied.

## Checks

```sh
luac -p *.lua tests/*.lua
```

Inline Lua checks are run from the shell against a fake-WoW harness; the two
tiny committed tests are `tests/rank_test.lua` and `tests/load_test.lua`.

## Build

Copy **only** these files into a folder named `Skilly`:

```
Skilly.toc  Data.lua  Core.lua  UI.lua  Skilly.lua  Bindings.xml  README.txt
```

Exclude: `README.md`, `AGENTS.md`, `TASKS.md`, `tests/`, `tasks/`, `plans/`,
`.agent/`, `.gitignore`, `.git/`.

The current build target is `/mnt/r/Skilly/`.

## Version history

- 0.1.0 — scaffolding.
- 0.2.0 — thresholds, cheapest-price resolution, scarcity helpers, extended
  vendor/pressure data, settings and commands; recommendations still pending.
- 0.3.0 — two-mode ranker, explanation strings, chat output, real `/skilly help`,
  `Recommend` wiring, `/skilly debug`, and the two committed tests.
- 0.3.1 — `/skilly export` copyable feedback window, bounded output log, expanded
  profession/trainer probe, and `evidence:` debug lines with spell ID/color.
