# Gamepad QoL Suite

[简体中文](README.md) | **English**

**A gamepad quality-of-life suite for Project Zomboid Build 42**

Fills in the parts of B42's controller support that still feel awkward: multi-item selection and quick transfers, Y-button panel shortcuts, D-pad radial extensions, a furniture rotation fix, panel info enhancements, and more.

> Every change lives in its own `GQS`-prefixed module. **No vanilla Lua is edited, and no CustomGamepadUI file is modified.** Delete the folder and the mod is completely gone.

| | |
|---|---|
| Game version | Build 42.21.0 (B42 only, not compatible with B41) |
| Required dependency | [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) |
| Current version | `1.5.1.50` |
| Author | Akatsuki_w |
| Languages | English / Simplified Chinese |

---

## What problem does this solve?

B42's controller support works, but inventory and panel handling still assume a mouse. Typical pain points:

- Looting a dozen items means pressing A a dozen times
- Moving items between your backpack and a crate means switching containers back and forth
- Health / building / crafting / fitness panels are scattered across wheels and menus
- Turning off a light or smashing a window means putting the controller down
- **Furniture rotates, you confirm, and it snaps back to its original facing** (a vanilla bug — see below)
- Recipe and building lists can only be scrolled one row at a time

This mod addresses each of these.

---

## Feature overview

| Feature | Default input | Summary |
|---|---|---|
| [Multi-selection](#1-multi-selection) | `R3` / `L3` / `L3+R3` | Toggle, range-select, select all or clear |
| [X quick transfer](#2-x-quick-transfer) | tap / hold `X` | Send selected items to the other pane's container |
| [Hold-B drag](#3-hold-b-drag-disabled-by-default) | hold `B` | Drag items to a target container like a mouse |
| [Y panel shortcuts](#4-y-panel-shortcuts) | `Y` + D-pad / left stick | Jump straight to a panel, chain multiple panels |
| [RB chords](#5-rb-chords) | `RB` + D-pad / `Y` / `A` | Camera zoom, moodle cycling |
| [RT+B](#6-rtb-focus-reset--close-panels) | `RT` + `B` | Return focus to the player / close all panels |
| [D-pad radial extensions](#7-d-pad-radial-extensions) | D-pad radials | Light switch and smash window on Up, fitness and skills on Right |
| [Furniture rotation fix](#8-furniture-rotation-fixautomatic) | none (automatic) | Fixes "rotates then snaps back" |
| [Panel info enhancements](#9-panel-info-and-trait-details) | `X` / `Y` / `RT`+Up/Down | Recipe favorites, paging, trait details, XP hints |
| [Fitness panel](#10-fitness-panel-enhancements) | none (automatic) | Auto-select exercise, default duration, one-press start |
| [Layout and paging](#11-container-layout-paging-and-sorting) | `RT` + Up/Down | Adjustable panel size/position, page scrolling |
| [Mixed liquid auto-drink](#12-mixed-liquid-auto-drink) | none (automatic) | Auto-drink from water+alcohol mixes |
| [Misc](#13-miscellaneous) | — | Disable B smash-window, map R3 focus |

Every binding can be changed in **Options → Mod Options → Gamepad QoL Suite**.

---

## Installation

### 1. Install the dependency

This mod requires **CustomGamepadUI**. Install and enable it first:

- Steam Workshop: [CustomGamepadUI (ID 3001154607)](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607)

### 2. Install this mod

**Option A: Download the ZIP (recommended)**

1. Click **Code → Download ZIP** on this repository page
2. Extract it — you get a folder like `GamepadQoLSuite-main`
3. **Rename that folder to `GamepadQoLSuite`** (the name must match the mod ID)
4. Place it in your mods directory:

   ```
   Windows:  C:\Users\<you>\Zomboid\mods\GamepadQoLSuite\
   Linux:    ~/Zomboid/mods/GamepadQoLSuite/
   macOS:    ~/Zomboid/mods/GamepadQoLSuite/
   ```

   The structure should look like:

   ```
   Zomboid/mods/GamepadQoLSuite/
   ├── 42/
   │   ├── mod.info
   │   └── media/
   ├── common/
   └── CHANGELOG_zh-CN.txt
   ```

**Option B: git clone**

```bash
cd "C:/Users/<you>/Zomboid/mods"
git clone https://github.com/akatsukiw/GamepadQoLSuite.git
```

(The cloned folder is already named `GamepadQoLSuite`, so no renaming is needed.)

### 3. Enable the mods

1. Launch the game → **Mods** menu
2. Enable **CustomGamepadUI** first, then **Gamepad QoL Suite**
3. Order matters: CustomGamepadUI must come first (it provides classes and the settings API this mod builds on)
4. In-game, open **Options → Mod Options** to tune the switches

---

## Usage

### 1. Multi-selection

Works in your inventory, containers, and the loot window.

| Action | Default input | Effect |
|---|---|---|
| Toggle a single row | `R3` (right stick click) | Select/deselect the focused row and mark it as the range anchor |
| Range select | `L3` (left stick click) | Set the anchor with `R3`, move to the end row, press `L3` to select the whole span |
| Select all / clear | `L3` + `R3` together | **If anything is selected, it clears first.** Select-all only runs when nothing is selected |

Details:

- Selection **persists across pages**
- Moving the camera, switching containers, or closing the panel clears the selection
- Pressing `A` with items selected applies the action to all of them
- Select-all/clear is strictly two-stage: as long as one item is selected, the button clears rather than stacking another select-all

### 2. X quick transfer

| Action | Effect |
|---|---|
| Tap `X` and release | Transfer all **currently selected** items to the other pane's current container |
| Hold `X` (200 ms by default) | Enter destination mode: pick a container with the D-pad, **release X to transfer** |

- The hold threshold is configurable (lower = easier to trigger, higher = fewer accidents)
- **Favorite protection**: starred favorite items can only move between containers the character carries — never into crates, loot containers, or the ground. Applies in both single-player and multiplayer
- Only `X` is intercepted; `L3` / `R3` and other buttons pass through untouched

### 3. Hold-B drag (disabled by default)

Emulates mouse dragging:

1. Multi-select some items
2. Hold `B` past the threshold → a virtual drag cursor appears
3. Push the left stick to move the cursor onto a container button or item list
4. Release `B` to complete the transfer

A short `B` press keeps its vanilla behavior (expand/collapse). Enable it in Mod Options first.

### 4. Y panel shortcuts

**Y + D-pad** (defaults, each remappable)

| Chord | Default action |
|---|---|
| `Y` + Up | Open the health panel and focus it |
| `Y` + Down | Open the backpack and focus it |
| `Y` + Left | Open the building panel (vanilla) |
| `Y` + Right | Open the crafting panel (vanilla) |

Each direction can also be set to Player Info, Fitness, or Disabled.

**Chaining**: hold `Y`, press Up to open health, then — without releasing — press Right to switch to crafting, then Left for building. Releasing `Y` afterwards does not also fire the normal Y action.

**Y + left stick**: while standing still, holding `Y` locks character movement; pushing the left stick switches focus between open windows in that direction, with the vanilla green highlight. Release `Y` to hand focus back. If the stick was already moving when you pressed Y, panel selection does not start.

**Contextual hints** (automatic):

- Opening the Select wheel and highlighting "Building / Crafting / Player Info" shows `Y + D-pad` icons on the second line of the slice text
- While `Y` is held, D-pad icons appear next to the matching icons in the left sidebar, disappearing on release

Turning off "Enable all Y-button enhancements" restores vanilla Y behavior immediately: it fires on press instead of waiting for release.

### 5. RB chords

**Only active when the world has focus and both inventory and loot windows are closed** (with a window open, RB+Up/Down keeps its vanilla container-switching role).

| Chord | Default action | Options |
|---|---|---|
| `RB` + Up / Down | Previous / next moodle state | Disabled / previous / next |
| `RB` + Left / Right | Zoom out / in | Disabled / zoom in / zoom out |
| `RB` + `Y` | Zoom in | Disabled / zoom in / zoom out |
| `RB` + `A` | Zoom out | Disabled / zoom in / zoom out |

### 6. RT+B focus reset / close panels

Hold `RT`, then press `B`:

- **Focus is on a panel**: only the gamepad focus returns to your character; the panel stays open
- **Keep RT held and press `B` again**: attempts to close every recognizable visible panel (fixed HUD elements are never closed)

The on-screen hint reads **"Close panels"**.

### 7. D-pad radial extensions

**Right D-pad wheel** (optional, individually toggleable)

- Fitness panel
- Skills panel (focus jumps to the skills page on open)

**Up D-pad wheel** (context-sensitive — options only appear when a valid target is nearby)

| Option | Appears when |
|---|---|
| Smash glass | An intact window is nearby (facing direction first, then adjacent tiles) |
| Turn light on / off | A powered light switch is nearby |
| Remove broken glass | Broken glass is nearby (existing feature) |
| Toggle radio | A radio is nearby (existing feature) |

The two new entries have independent switches ("Add smash glass to the Up wheel", "Add light switch to the Up wheel"), both on by default.

**Extra Select wheel entries** (off by default): adds safety toggle, player panel, admin panel (admins only), and PvP/war management to the Select wheel.

### 8. Furniture rotation fix (automatic)

**The most important fix in this mod, and it needs no configuration.**

Vanilla has a long-standing bug: you rotate furniture with a controller, the preview turns, and the moment you confirm it snaps back to the original facing. It looks intermittent because three independent defects stack up:

1. **Fallback facings** — vanilla always returns four facing indexes, filling missing ones with the object's own facing. Furniture that only ships N/S sprites lands on index 2 and 4, both resolving back to its own sprite, so the preview appears not to turn at all
2. **Pointer hijack** — while the place button is held, vanilla calls `rotateMouse(x, y)` **every frame**, deriving facing from the mouse pointer's position relative to the cursor centre. Controller players never move the pointer, so the parked pointer rewrites the direction right before the action is created
3. **Duplicate create plus cache reset** — one confirm runs the create path twice. Vanilla clears the facing fields at the end of the first call and the cache resets the index to -1, so the second call can only reverse-derive direction from the sprite name — landing back on the original facing

The fix: cycle only through facings that **actually have sprites**, ignore pointer-derived facing while the controller is in use, and replay the direction from mod-owned fields when the create path runs twice.

Result: both two-facing and four-facing furniture rotate correctly and keep the direction you saw.

> We wrote this up as an English bug report for the developers, with vanilla source line numbers, reproduction steps, and the elimination process for all three root causes. The report is not included in this repository — ask the author if you need a copy.

### 9. Panel info and trait details

| Panel | Enhancement |
|---|---|
| Info panel | Press `X` to open the trait detail sidebar; use the D-pad to browse traits grouped into positive / negative / other |
| Skills panel | Shows a "next level XP" hint on the focused skill; `RT` + Up/Down pages through the list |
| Building / crafting | `RT` + Up/Down paging, `X` to favorite a recipe, `Y` to show/hide all recipes or building versions |
| Item tooltips | Extra item properties and side-by-side comparison highlighting |

### 10. Fitness panel enhancements

- Automatically selects the available priority exercise when the panel opens
- Press `X` to start the workout and close the panel automatically
- **Default workout duration**: 10–60 minutes in steps of 10, default 30. Filled in automatically on open; changes apply immediately
- Enlarged panel and progress bars

### 11. Container layout, paging and sorting

**Layout** (Mod Options → Inventory and Loot)

| Option | Notes |
|---|---|
| Combined width of both panes | Screen percentage. At least 50% is recommended on Steam Deck or below 1600px width |
| Character inventory height | Screen percentage. Above 50% may clip on low resolutions |
| Loot pane height | Same as above |
| Position | Default / left / right / bottom center / top center |

Split-screen has separate width/height settings, calculated per player's own screen region.

**Paging**: `RT` + Up / Down

- Scheme 1 (default): skips 7 items at a time, e.g. 1 → 8 → 15
- Scheme 2: pages by the current viewport to the screen edge, then continues page by page
- Stops at the start and end of the list

**Sorting**: `Select` key, 6 modes (4 vanilla + 2 extended), including combinations like "category + weight descending"

### 12. Mixed liquid auto-drink

Vanilla only lets pure water participate in auto-drinking. With this enabled, mixed containers where **water is the main liquid and the mix is untainted and non-poisonous** (water + alcohol, for example) can be drunk automatically too.

To exclude a specific container, use the "Liquid" context menu on that item.

### 13. Miscellaneous

| Feature | Notes |
|---|---|
| Disable B smash-window | Removes the vanilla B binding for smashing windows at runtime to prevent accidents. Does not rewrite InputBindings XML, so the Controller settings page may still show the original binding |
| World map R3 focus | Press `R3` on the world map to recenter on your character |
| Select/Start input fixes | Fixes focus misalignment after switching containers with A, lost focus when a menu opens, and refresh/search-box focus issues |

---

## Mod Options panel

**Options → Mod Options → Gamepad QoL Suite** contains these groups:

| Group | Contents |
|---|---|
| Inventory and Loot | Pane width, inventory/loot heights, position, split-screen sizes |
| Container operations | Multi-select, X quick transfer, hold-B drag and their thresholds |
| Key feature extensions | Y master switch, Y+D-pad mapping, Y+left stick |
| RB chords | RB+D-pad, RB+Y, RB+A mappings |
| RT + B focus reset / close panels | Toggle |
| D-pad radial extensions | Up wheel smash/light, Right wheel fitness/skills |
| Panel enhancements | Panel info, fitness panel, default workout duration |
| Select key sorting | 6 sort modes, double-press window |
| Miscellaneous | Disable B smash-window, mixed liquid auto-drink |

**About duplicated upstream options**: CustomGamepadUI's own "Inventory and Loot" entries and sort setting are taken over and hidden by this mod — the functionality is fully provided here, so **changing those entries in the upstream panel has no effect**. Use this mod's panel instead.

**About hidden options**: a few threshold options (double-press window, B hold threshold) are not rendered, but their values are still saved normally. To change them, edit `Zomboid/ModOptions.ini`.

---

## FAQ

**I don't see the new radial entries after installing.**
Make sure CustomGamepadUI is enabled and loads before this mod. The Up-wheel entries are context-sensitive: "Smash glass" needs an intact window nearby, "Turn light on/off" needs a powered switch nearby.

**I can't find a specific option.**
A few threshold options are intentionally hidden (see above). Also make sure you opened the **Gamepad QoL Suite** panel, not CustomGamepadUI's.

**Does this conflict with CustomGamepadUI?**
No — CustomGamepadUI is the required dependency. This mod simply takes over some of its settings (layout, sorting); the features do not conflict.

**Will it conflict with other inventory mods?**
This mod rewrites container layout, selection state, and item transfer paths, so mods that modify the same logic may conflict. Test alone first.

**Does uninstalling break my save?**
No. All changes are runtime behavior; nothing is written into save data. Delete the folder to uninstall completely.

**Furniture rotation still misbehaves.**
Check that you are running `1.5.1.34` or later (the rotation fix starts there). Other mods that touch placement logic may also interfere.

**Where are the logs?**
`%USERPROFILE%\Zomboid\console.txt`. This mod ships categorized debug logging, all off by default; enable a category temporarily when troubleshooting (see Development below).

---

## Compatibility

- **Game version**: Build 42.21.0. Not for B41
- **Required**: CustomGamepadUI (Workshop 3001154607)
- **Not recommended alongside**: other mods that rewrite inventory layout, selection state, or item transfer (duplicate key interception)
- **Multiplayer**: includes one server-side module (liquid-type sync for mixed-liquid auto-drink); both client and server need the mod
- **Never modified**: vanilla Lua, CustomGamepadUI's Workshop files, CleanUI

---

## Known limitations

- Broken-window names occasionally fail to display (vanilla behavior, root cause not yet located)
- Recognition of external mixed-liquid water sources has not been fully tested
- Up-wheel entries depend on nearby targets; not appearing in open areas is expected
- Radial and registry-style menus handle one target at a time

---

## Changelog

See [CHANGELOG_zh-CN.txt](CHANGELOG_zh-CN.txt) — reverse-chronological from `1.5.1.50` back to `1.5.1.30` (Simplified Chinese).

---

## Development

**Repository layout**

```
GamepadQoLSuite/            <- repo root == mod root
├── 42/
│   ├── mod.info
│   └── media/
│       ├── lua/
│       │   ├── client/     <- 30 GQS modules
│       │   ├── server/     <- 1 server module
│       │   └── shared/Translate/{CN,EN}/
│       └── ui/             <- 3 icons
├── common/README.txt
└── CHANGELOG_zh-CN.txt
```

**Conventions**

- All custom code lives in `GQS`-prefixed files. Never edit vanilla Lua, CustomGamepadUI, or CleanUI
- **Never ship a resource with the same name as an upstream mod's file** — this mod loads later and will override the upstream asset (`1.5.1.42` hit this; fixed in `1.5.1.50`)
- Debug logging is centralized in `GQSDebugLog.lua` with 18 category switches. Set the relevant category to `true` while investigating, set it back to `false` when done — **do not delete the log statements**

**Reporting issues**

Please include: game version, mod version, exact reproduction steps, and the relevant part of `console.txt`. Mentioning whether it reproduces with this mod alone helps a lot.

---

## Credits

- [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) — provides the gamepad UI infrastructure this mod builds on
- Project Zomboid community controller players for the feedback

## License

Free mod made for personal use. Please credit the author when redistributing or bundling.
