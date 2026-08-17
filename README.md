# Classic GmbH Quartermaster

WoW Classic Era addon for raid sheet bosses/assignments, officer wishlist, and guild peer sync.

**Version:** 1.8.75

## Install

Copy this folder into:

`World of Warcraft\_classic_era_\Interface\AddOns\ClassicGmbHQuartermaster`

Then /reload in-game. Slash command: /gmbh.

Or download the zip from the guild site (Download addon).

## Fill HelperData without the site API

Officers can generate `HelperData.lua` (raid groups + boss assignments only; wishlist stays empty) with the included script. Requires Python 3.

Print a sample JSON file:

```
python write_helperdata.py --example-json
```

Or edit the included `example_helperdata.json`, then write the Lua file into your AddOns folder:

```
python write_helperdata.py --from-json example_helperdata.json --out "D:\Games\World of Warcraft\_classic_era_\Interface\AddOns\ClassicGmbHQuartermaster\HelperData.lua"
```

Interactive questions (raid slug, title, announced, groups, assignments), then output path:

```
python write_helperdata.py
```

Optional: set `WOW_PATH` to your `_classic_era_` folder so the default output path is filled in.

After writing, `/reload` in WoW.

Assignment lines in interactive mode look like:

`section | slot | player [| class [| role]]`

Example: `C'Thun | MT | Hardzor | Warrior | Tank`

## Contents

- `ClassicGmbHQuartermaster.toc`
- `GmbHLootTracker.lua`
- `GmbHLootTrackerComm.lua`
- `GmbHLootTrackerRaidSheet.lua`
- `GmbHLootTrackerSync.lua`
- `HelperData.lua` (filled by helper or `write_helperdata.py`; ships as nil)
- `write_helperdata.py` â€” build HelperData from JSON or questions
- `example_helperdata.json` â€” sample input for the script
- `CURSEFORGE.md` â€” paste-ready CurseForge project description
- `Libs/`
- `Textures/`

Source of truth for development lives in the loottracker app repo; this repository is the public addon distribution mirror.
