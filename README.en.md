# Gamepad QoL Suite

[简体中文](README.md) | **English**

**A gamepad quality-of-life suite for Project Zomboid Build 42**

Fills in the parts of B42's controller support that still feel awkward: multi-item selection and quick transfers, Y-button panel shortcuts, D-pad radial extensions, a furniture rotation fix, panel info enhancements.

> I'm new to PZ — only about a week in — so some areas (animal husbandry, farming, etc.) aren't covered yet, and a few panels still have issues. I'll publish to the Steam Workshop once it's cleaned up. Please do not re-upload this mod.

| | |
|---|---|
| Game version | Build 42.21.0 (B42 only, not compatible with B41) |
| Required dependency | [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) |
| Build version | `1.5.9.16` |
| Author | Akatsuki_w |
| Languages | English / Simplified Chinese |

---

## What problem does this solve?

B42's controller support works, but inventory and panel handling still assume a mouse. Typical pain points:

- Looting a dozen items means pressing X a dozen times
- Mouse and keyboard users can grab items from several crates and move them to another crate in seconds — what about us?
- Health / building / crafting / fitness panels are buried in that absurd Select wheel. I happen to have extra shoulder buttons; what about everyone else?
- Turning off a light, drinking water, filling a bottle — I'm sick of "X, down, down, down, A, down, down, A"
- Furniture rotates, you confirm, and it snaps back to its original facing (a vanilla bug)
- Recipe and building lists only scroll one row at a time. And favoriting needs a mouse?
- Moodle states, trait info and other details need a mouse to inspect?
- Opening a TV or an animal feed trough, then the panel just won't close. ~~One panel, one bug.~~

---

## Feature overview

| Feature | Default input | Summary |
|---|---|---|
| [Multi-selection](#1-multi-selection) | `R3` / `L3` / `L3+R3` | Toggle, range-select, select all or clear |
| [Containers and paging](#9-container-layout-paging-and-sorting) | `RT` + Up/Down | Jump 8 items down, or page the whole list |
| [X quick transfer](#2-x-quick-transfer) | hold `X` in a container | Send selected items to a nearby container (favorites excluded) |
| [Y panel shortcuts](#3-y-panel-shortcuts) | `Y` + D-pad / left stick | Hold Y + D-pad to open a panel; Y + left stick to switch between panels |
| [RB chords](#4-rb-chords) | `RB` + D-pad / `Y` / `A` | RB+Left/Right and Y/A zoom, RB+Up/Down cycles moodle states |
| [RT+B close panels](#5-rtb-close-panels) | `RT` + `B` | Return focus to the player / close all panels. A few still won't close — looking into it |
| [D-pad radial extensions](#6-d-pad-radial-extensions) | D-pad radials | Up wheel: CGUI position fix plus light switch / smash glass / drop backpack. Right wheel: fitness and skills |
| [Panel info](#7-panel-info-and-trait-details) | `X` / `Y` / `RT`+Up/Down | Recipe favorites and paging, trait details, skill XP hints |
| [Fitness panel](#8-fitness-panel) | open from the right wheel | Auto-select exercise, default duration, one-press start |
| [Misc](#11-miscellaneous) | — | Disable B smash-window, map R3 focus |
| [Info-panel nutrition readout](#12-info-panel-nutrition-readout) | Info panel `Y` | Expand lipids / carbs / protein / calories, independent toggle |
| [Hold-B to exit fishing](#13-hold-b-to-exit-fishing) | hold `B` while fishing | Closing a panel no longer mis-retracts the rod; shows a progress ring |
| [Drying-rack and other workstation panels](#14-drying-rack-and-other-workstation-panels) | D-pad / `A` `X` `Y` `L3` `R3` | Full gamepad control of leather / plant drying racks |
| [Recipe sort shortcut](#15-recipe-sort-shortcut) | `L3` | One-key cycle sort in build / craft / drying-rack panels |

Every binding can be changed in **Options → Mod Options → Gamepad QoL Suite**.

---

## Other notes

- Split-screen gets its own container layout width/height values.
- Mixed-liquid (mostly light alcoholic drinks) auto-drink, toggleable in Mod Options.
- Dragging the name/type/weight column dividers now persists, stored separately for single-player and split-screen.
- Setting the vanilla **Options → Accessibility → container switching** to scheme 3 (LB, RB+Up/Down) also keeps scheme 1's tap-LB/RB switching working — there is a switch in Mod Options.
- Fixes the vanilla furniture rotation bug on gamepad.
- Fixes a vanilla crash when pressing B to exit the building/crafting panel after opening the rightmost optional item list.
- Fixes a CleanUI edge case in carried-container selection: LB+Up can now jump to the last item (requires container switching scheme 3 in the vanilla accessibility settings).
- Fixes CleanUI's out-of-order gamepad switching after sorting carried containers. (Do not enable CleanUI's sortable loot container — it has the same bug, unfixed.)
- Fixes a CleanUI crash in tutorial mode when it prompts "press Y to open container".
- Fixes CGUI's Start-key double-press emulation crashing on the equipped-items row.
- Split-screen: the 2nd and later local players now also get a melee target outline (vanilla only draws player 1).
- Fixes RT+B accidentally closing HUD status indicators (e.g. Modern Status) and hover detail popups.
- New: info-panel nutrition readout, hold-B fishing exit, and drying-rack workstation panel gamepad support — see sections 12–15 below.

---

## Installation

### 1. Install the dependency

This mod requires **CustomGamepadUI**: [Workshop (ID 3001154607)](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607).

### 2. Install this mod

**Option A: Download from Releases (recommended)**

Grab the latest `GamepadQoLSuite_v<version>_Full.zip` from [Releases](https://github.com/akatsukiw/GamepadQoLSuite/releases). It already contains a `GamepadQoLSuite` folder — **no renaming needed**. Move the whole folder into your mods directory:

```
Windows:  C:\Users\<you>\Zomboid\mods\
Linux:    ~/Zomboid/mods/
macOS:    ~/Zomboid/mods/
```

**Option B: Download the source ZIP**

Click **Code → Download ZIP**, extract it to get a folder like `GamepadQoLSuite-main`, **rename it to `GamepadQoLSuite`** (otherwise the mod ID won't match), then move it into the same directory.

**Option C: git clone**

```bash
cd "C:/Users/<you>/Zomboid/mods"
git clone https://github.com/akatsukiw/GamepadQoLSuite.git
```

Resulting structure:

```
Zomboid/mods/GamepadQoLSuite/
├── 42/
│   ├── mod.info
│   └── media/
└── common/
```

### 3. Enable the mods

1. Launch the game → **Mods** menu
2. **Enable CustomGamepadUI first, then Gamepad QoL Suite** (order matters — the dependency provides the classes and settings API this mod builds on)
3. In-game, open **Options → Mod Options** to tune the switches

---

## Usage

### 1. Multi-selection

Works in your inventory, containers, and the loot window.

| Action | Default input | Effect |
|---|---|---|
| Toggle a single row | `R3` (right stick click) | Select/deselect the focused row and mark it as the range anchor |
| Range select | `L3` (left stick click) | Set the anchor with `R3`, move to the end row, press `L3` to select the whole span |
| Select all / clear | `L3` + `R3` together | **If anything is selected, it clears first.** Select-all only runs when nothing is selected |

### 2. X quick transfer

| Action | Effect |
|---|---|
| Tap `X` and release | Transfer all **currently selected** items to the other pane's current container |
| Hold `X` (200 ms by default) | Enter destination mode: pick a container with the D-pad, **release X to transfer** |

Favorite items can only move between containers the character carries — never into crates, loot containers, or the ground.

### 3. Y panel shortcuts

| Chord | Default action |
|---|---|
| `Y` + Up | Open the health panel and focus it |
| `Y` + Down | Open the backpack and focus it |
| `Y` + Left | Open the building panel (vanilla) |
| `Y` + Right | Open the crafting panel (vanilla) |

Each direction can also be set to Player Info, Fitness, or Disabled.

**Y + left stick**: while standing still, holding `Y` locks character movement; pushing the left stick switches focus between open windows in that direction, with the vanilla green highlight. Release `Y` to hand focus back. If the stick was already moving when you pressed Y, panel selection does not start. Very handy for checking the skills panel while repairing a car.

**UI hints**: opening the Select wheel and highlighting "Building / Crafting / Player Info" shows `Y + D-pad` icons on the second line of the slice. While `Y` is held, D-pad icons also appear next to the matching sidebar icons and disappear on release.

Turning off "Enable all Y-button enhancements" restores vanilla Y behavior immediately: it fires on press instead of waiting for release.

### 4. RB chords

**Only active when the world has focus and both inventory and loot windows are closed** (with a window open, RB+Up/Down keeps its vanilla container-switching role).

| Chord | Default action | Options |
|---|---|---|
| `RB` + Up / Down | Previous / next moodle state | Disabled / previous / next |
| `RB` + Left / Right | Zoom out / in | Disabled / zoom in / zoom out |
| `RB` + `Y` | Zoom in | Disabled / zoom in / zoom out |
| `RB` + `A` | Zoom out | Disabled / zoom in / zoom out |

### 5. RT+B close panels

Hold `RT`, then press `B`:

- **Focus is on a panel**: only the gamepad focus returns to your character; the panel stays open
- **Press again**: attempts to close every recognizable visible panel (fixed HUD elements are never closed)
- A few panels still refuse to close — still investigating

### 6. D-pad radial extensions

**Right D-pad wheel** (optional, individually toggleable): fitness panel, skills panel (focus jumps to the skills page on open).

**Up D-pad wheel** (context-sensitive — options only appear when a valid target is nearby):

| Option | Appears when |
|---|---|
| Smash glass | An intact window is nearby (facing direction first, then adjacent tiles) |
| Turn light on / off | A powered light switch is nearby |
| Remove broken glass | Broken glass is nearby (existing CGUI feature) |
| Toggle radio | A radio is nearby (existing CGUI feature) |
| Drop worn backpack | You are wearing a backpack; same as the keyboard shortcut |

The two new entries have independent switches ("Add smash glass to the Up wheel", "Add light switch to the Up wheel"), both on by default.

**Extra Select wheel entries** (CGUI feature, off by default): adds safety toggle, player panel, admin panel (admins only), and PvP/war management.

### 7. Panel info and trait details

| Panel | Enhancement |
|---|---|
| Info panel | Press `X` to open the trait detail sidebar; use the D-pad to browse traits grouped into positive / negative / other |
| Skills panel | Shows a "next level XP" hint on the focused skill; `RT` + Up/Down pages quickly |
| Building / crafting | `RT` + Up/Down paging, `X` to favorite a recipe, `Y` to show/hide all recipes or building versions |

### 8. Fitness panel

- Automatically selects the available priority exercise when the panel opens
- Press `X` to start the workout and close the panel automatically
- **Default workout duration**: 10–60 minutes in steps of 10, default 30. Filled in on open; changes apply immediately
- Enlarged panel and progress bars

### 9. Container layout, paging and sorting

**Layout (CGUI feature)**: combined pane width, inventory height, loot pane height, and position (default / left / right / bottom center / top center). Heights above 50% may clip on low resolutions. Split-screen has separate width/height settings, calculated per player's own screen region.

**Paging**: `RT` + Up / Down

- Scheme 1 (default): skips 7 items at a time, e.g. 1 → 8 → 15
- Scheme 2: pages by the current viewport to the screen edge, then continues page by page
- Stops at the start and end of the list

**Sorting**: `Select` key, 6 modes (4 vanilla + 2 extended), including combinations like "category + weight descending".

### 10. Mixed liquid auto-drink

Vanilla only lets pure water participate in auto-drinking. With this enabled, mixed containers where **water is the main liquid and the mix is untainted and non-poisonous** (water + alcohol, for example) can be drunk automatically too. To exclude a container, use its "Liquid" context menu.

### 11. Miscellaneous

| Feature | Notes |
|---|---|
| Disable B smash-window | Removes the vanilla B binding for smashing windows at runtime to prevent accidents. Does not rewrite InputBindings XML, so the Controller settings page may still show the original binding |
| World map R3 focus | Press `R3` on the world map to recenter on your character |

---

### 12. Info-panel nutrition readout

On the character info panel (Info page), press `Y` to expand a narrow panel showing current **lipids / carbs / protein / calories**.

These values are only visible in the debug menu in vanilla, so this is exposed as a standalone toggle (Mod Options → Panel enhancements, on by default). It is mutually exclusive with the `X` trait detail panel; while expanded, the D-pad still operates the info panel normally, and `B` closes it.

### 13. Hold-B to exit fishing

In vanilla, a single tap of `B` while fishing retracts the rod — worse, pressing `B` to close a health or build panel also retracts the rod, and doing so while not idle wears down the fishing-line durability.

Now:

- While focus is on any panel, the fishing logic **entirely ignores** `B`;
- With world focus, you must **hold for 500 ms** to exit;
- While fishing, the bottom-right shows `[B] Hold to exit`; a progress ring fills around the B icon as you hold, and it exits when full.

Keyboard is unaffected (vanilla keyboard uses movement / attack / cancel keys, not B). Can be disabled in Mod Options → Other features.

### 14. Drying-rack and other workstation panels

Workstations like the leather and plant drying racks use the `CraftLogic` panel, which vanilla **has zero gamepad support for** (open it and you can only press B to exit — everything else needs a mouse). Now every binding works:

| Button | Action |
|---|---|
| D-pad | Scroll within the current list |
| `RB` + D-pad | Switch region (recipe list / craft button / available items / contained items) |
| `A` | Select recipe, insert materials, start crafting |
| `X` | Smart key: if the craft button is lit, craft directly; otherwise auto-insert the next available material |
| `Y` | Take all |
| `L3` | Cycle recipe sort mode |
| `R3` | Retrieve items from "contained items" (prompt greys out when empty) |
| `B` | Close |

The top-right of the title bar shows the full button hints; an icon hint also sits to the left of the craft button and to the right of "Take all".

### 15. Recipe sort shortcut

In the build, craft, and drying-rack panels you can press `L3` to cycle the sort mode among "recipe name / most recent / most used" — typing to search recipes on a gamepad is impractical, so sorting is the one that's actually useful.

---

## Mod Options panel

**Options → Mod Options → Gamepad QoL Suite** contains: Inventory and Loot, Container operations, Key feature extensions, RB chords, RT+B focus reset, D-pad radial extensions, Panel enhancements, Select key sorting, and Miscellaneous.

CustomGamepadUI's own "Inventory and Loot" entries and sort setting are taken over and hidden by this mod — **changing those in the upstream panel has no effect**, use this mod's panel instead. A few threshold options (double-press window, B hold threshold) are not rendered but their values are still saved; edit `Zomboid/ModOptions.ini` if you need to change them.

---

## FAQ

**I don't see the new radial entries after installing.**
Make sure CustomGamepadUI is enabled and loads before this mod. The Up-wheel entries are context-sensitive: "Smash glass" needs an intact window nearby, "Turn light on/off" needs a powered switch.

**I can't find a specific option.**
A few threshold options are intentionally hidden (see above). Also make sure you opened the **Gamepad QoL Suite** panel, not CustomGamepadUI's.

**Will it conflict with other inventory mods?**
This mod rewrites container layout, selection state, and item transfer paths, so mods that modify the same logic may conflict. Test alone first.

**Does uninstalling break my save?**
No. All changes are runtime behavior; nothing is written into save data. Delete the folder to uninstall completely.

**Where are the logs?**
`%USERPROFILE%\Zomboid\console.txt`. The mod ships categorized debug logging, all off by default.

**How do I report a bug?**
Include your game version, mod version, reproduction steps, and the relevant lines from `console.txt`. Mentioning whether it reproduces with this mod alone helps a lot.

---

## Compatibility

- **Game version**: Build 42.21.0. Other versions untested
- **Required**: CustomGamepadUI (Workshop 3001154607)
- **Not recommended alongside**: other mods that rewrite inventory layout, selection state, or item transfer (duplicate key interception)
- **Multiplayer**: includes one server-side module (liquid-type sync for mixed-liquid auto-drink); both client and server need the mod
- **Never modified**: vanilla Lua, CustomGamepadUI's Workshop files, CleanUI

## Known limitations

- Broken-window names occasionally fail to display
- Recognition of external mixed-liquid water sources has not been fully tested
- Up-wheel entries depend on nearby targets; not appearing in open areas is expected

---

## Credits and license

- [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) — provides the gamepad UI infrastructure this mod builds on
- Project Zomboid community controller players for the feedback

Free mod made for personal use. **Please do not re-upload it to the Steam Workshop.** Credit the author when redistributing or bundling.
