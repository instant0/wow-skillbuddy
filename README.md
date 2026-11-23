# SkillBuddy (development README)

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

Version **0.3.1**. Test build. The recommendation engine is now real:
`SkillBuddy.Recommend` scans the open profession, ranks recipes in `best` or
`cheap` mode, and prints explanations plus up to three runners-up through the
chat formatter. `/sb help <cmd>`, `/sb prices`, and `/sb debug` are available.

Use `/sb export` to collect feedback from the live client. It prints the same
report to chat and also opens a pre-highlighted multiline EditBox so the user
can press Ctrl+C. The probe now reports both trade-skill API families, trainer
API presence, and a closed-trainer message without opening any window.
Trainer capture and unlock hints are not implemented yet, so SkillBuddy has no
recipe-availability data.

## Layout

| File | Role |
|---|---|
| `SkillBuddy.toc` | Load order, interface version, saved variables, version |
| `Data.lua` | Bundled game data: thresholds, vendor prices, material pressure, difficulty bands |
| `Core.lua` | Command registry, probe, scanner, price sources, cost, probability, ranking helpers |
| `UI.lua` | Copyable export window, result-window hook, binding-button placeholder |
| `SkillBuddy.lua` | Settings page, `/sb` commands, bootstrap |
| `Bindings.xml` | Keybinding target |
| `README.txt` | User-facing readme (shipped) |
| `README.md` | This file (not shipped) |
| `AGENTS.md` | Agent contract (not shipped) |
| `TASKS.md` | Pending-task priority list (not shipped) |

Task priorities are in `TASKS.md`; design decisions are in
`plans/skillbuddy.md`. `tests/`, `tasks/`, and `plans/` are gitignored. None of
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

Copy **only** these files into a folder named `SkillBuddy`:

```
SkillBuddy.toc  Data.lua  Core.lua  UI.lua  SkillBuddy.lua  Bindings.xml  README.txt
```

Exclude: `README.md`, `AGENTS.md`, `TASKS.md`, `tests/`, `tasks/`, `plans/`,
`docs/`, `.agent/`, `.gitignore`, `.git/`.

The current build target is `/mnt/r/SkillBuddy/`.

## Version history

- 0.1.0 — scaffolding.
- 0.2.0 — thresholds, cheapest-price resolution, scarcity helpers, extended
  vendor/pressure data, settings and commands; recommendations still pending.
- 0.3.0 — two-mode ranker, explanation strings, chat output, real `/sb help`,
  `Recommend` wiring, `/sb debug`, and the two committed tests.
- 0.3.1 — `/sb export` copyable feedback window, bounded output log, expanded
  profession/trainer probe, and `evidence:` debug lines with spell ID/color.
