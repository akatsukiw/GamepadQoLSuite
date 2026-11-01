# Gamepad QoL Suite

[简体中文](README.md) | **English**

**A gamepad quality-of-life suite for Project Zomboid Build 42**

Fills in the parts of B42's controller support that still feel awkward: multi-item selection and quick transfers, Y-button panel shortcuts, D-pad radial extensions, a furniture rotation fix, panel info enhancements.

> I'm new to PZ — only about a week in — so some areas (animal husbandry, farming, etc.) aren't covered yet, and a few panels still have issues. I'll publish to the Steam Workshop once it's cleaned up. Please do not re-upload this mod.

| | |
|---|---|
| Game version | Build 42.21.0 (B42 only, not compatible with B41) |
| Required dependency | [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) |
| Build version | `1.5.14.1` |
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
| [Multi-selection](#1-multi-selection) | `R3` / `L3` / `L3+R3` / hold `R3` | Toggle, range-select, select all or clear, hold-and-sweep |
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
| [Drying-rack and other workstation panels](#14-drying-rack-and-other-workstation-panels) | D-pad / `A` `X` `Y` `L3` `R3` | Full gamepad control of leather / plant drying racks, plus drying readouts |
| [Recipe sort shortcut](#15-recipe-sort-shortcut) | `L3` | One-key cycle sort in build / craft / drying-rack panels |
| [Dish-name fix](#16-dish-names-in-non-english-languages) | — | No more `Base.Ramen` in cooked dish names under Chinese and other non-English languages |
| [Hold-B to stop washing](#17-hold-b-to-stop-washing) | hold `B` while washing | Washing yourself or clothes no longer stops on a stray tap |
| [Print-media panels in MP](#18-print-media-panels-in-multiplayer) | `B` `X` `Y` | Flyers / newspapers / magazines respond to the pad in MP again, with no error spam |
| [Smart Radial Menu compatibility](#19-smart-radial-menu-compatibility) | hold Up | This mod's world-object actions merge into SRM's wheel |
| [Quick Clothing Actions compatibility](#20-quick-clothing-actions-compatibility) | right wheel "Clothing" | Full gamepad control of the clothing wheel |

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
- New: info-panel nutrition readout, hold-B fishing exit, drying-rack workstation panel gamepad support, and the non-English dish-name fix — see sections 12–16 below.
- New: hold-B washing exit, print-media panel fix for multiplayer, and Smart Radial Menu / Quick Clothing Actions compatibility — see sections 17–20 below.
- The drying-rack panel's drying readouts (progress, time left, temperature, humidity, drying rate) are now a replay of vanilla's own tooltip, laid out as a card grid; in-progress slots are gamepad-selectable.
- Multi-selection now supports **holding `R3` while pushing the D-pad** to sweep-select a run of rows.
- With Smart Radial Menu installed, this mod's Up-wheel world-object actions merge into SRM's wheel — one ring, both mods, no duplicates.
- With Quick Clothing Actions installed, the right D-pad wheel gains a "Clothing" entry and the clothing wheel is fully playable on a pad.

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
| Sweep select | hold `R3` and push the D-pad | While held, every row the focus crosses is selected — great for grabbing a dozen loot items in one pass |

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
| Building / crafting | `RT` + Up/Down paging, `X` to favorite a recipe, `Y` to show/hide all recipes or building versions, `L3` to cycle sort |

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

**Drying readouts**: move the focus onto an in-progress slot and that slot's full readout appears — progress, time left, temperature, humidity, drying rate. Those five numbers are drawn by vanilla straight into its own tooltip and are unreadable from Lua (`getDryingFactor()` is private, humidity lives in a private `HashMap`, and reflection is blocked by Kahlua), so this mod **replays vanilla's tooltip verbatim**, paints its own card backing, and arranges the cards in a multi-column grid.

**Gamepad selection**: the D-pad moves between in-progress slots; the focused slot gets a highlighted border and shows only its own readout, while with no focus every slot is drawn.

> Want them always on? The old "always show drying info" toggle was removed — always-on covered the recipe list, and showing it on focus turned out to be far more usable.

### 15. Recipe sort shortcut

In the build, craft, and drying-rack panels you can press `L3` to cycle the sort mode among "recipe name / most recent / most used" — typing to search recipes on a gamepad is impractical, so sorting is the one that's actually useful.

### 16. Dish names in non-English languages

In Chinese (and other non-English languages) any recipe that uses an ingredient with an `EvolvedRecipeName` ends up with the internal ID in the dish name — e.g. "Cabbage and Base.Ramen Stir Fry".

The cause is in vanilla: `Item.DoParam` resolves `EvolvedRecipeName` **immediately**, while the item is still unregistered in `ScriptManager`. The lookup fails, falls back to the internal ID, and that value is then **cached permanently in a static map**. Worse, the first line of `Translator.setDefaultItemEvolvedRecipeName` is `if (getLanguage() != getDefaultLanguage()) return;` — non-English languages never write a clean value, so the cache stays dirty forever. That is also why English players have never reported this.

This mod overrides the Lua global `getItemEvolvedRecipeName` from `shared/` and turns "the returned value equals the internal ID" into `nil`, so the dish name falls back to the item's localized name.

- Only affects dishes cooked **after** the change; existing dish names are not rewritten;
- In multiplayer the name is generated on the server, so **the server must load this mod too**;
- Mod Options → Miscellaneous → "Fix Base.XXX in dish names", on by default. **Keep it enabled in Chinese.**

### 17. Hold-B to stop washing

Washing yourself, washing clothes, or wringing clothes: in vanilla a single tap of `B` aborts it — one slip and the whole wash is wasted. Worse, `B` is also bound to "cancel action", so pressing B on a panel stops it too.

Now, while washing:

- With gamepad focus on any panel, `B` only closes the panel and **does not interrupt the wash**;
- With world focus you must **hold `B` for about 500 ms** to abort;
- On the inventory page, `B` still collapses/expands as vanilla does.

Can be disabled in Mod Options → Other features.

### 18. Print-media panels in multiplayer

Opening a flyer, newspaper, or magazine in multiplayer often leaves the pad **completely dead** — no focus, so paging, flipping to the back, and marking the map all do nothing.

The cause is in vanilla: the first statement of `setJoypadFocus()` is `noise("set focus to %s...", uiToString(control), playerID)`, and `noise()`'s arguments are **evaluated unconditionally**. `uiToString()` reaches `ISAtomUIJoypad:toString()`, which runs `self._ATOM_UI_CLASS.class:getSimpleName()` when the window's `UIName` is empty — `_ATOM_UI_CLASS` is the Java class itself, `.class` doesn't resolve, an exception is thrown, and the whole `setJoypadFocus()` aborts **before** `joypadData.focus = control`, so the focus is never set.

Now:

- `ISAtomUIJoypad.toString` is **reimplemented at runtime** (both the class definition and the copy `Apply()` puts on the window object), returning `<AtomUI>` for an empty `UIName` so the throwing line never runs;
- When a print-media window opens, the controller binding and focus are **re-applied as a fallback**, so it works even if vanilla's binding failed;
- `B` closes, `X` flips the newspaper text, `Y` marks the map and closes — all fine.

> A `pcall` wrapper does **not** work here: Kahlua prints the `ERROR` and dumps the stack at the moment the exception is thrown, and `pcall` only stops it from propagating — the log line is already written. The only fix is to never execute that line.

### 19. Smart Radial Menu compatibility

[Smart Radial Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=3494108029) (SRM) defaults to showing its own wheel **only when the vanilla wheel is empty**. This mod used to add entries to the vanilla Up-D-pad wheel, which filled it up — so installing SRM made SRM itself disappear.

Now:

- When SRM is detected, holding **Up opens SRM's wheel directly** instead of the vanilla wheel;
- This mod's **world-object actions** (smash glass, light switch, drop worn backpack, open/close curtains, remove broken glass, drink, fill, reinforce) are **appended to SRM's wheel**, so one ring holds both SRM's item actions and this mod's actions;
- The scan covers the **full 3×3** (including the current tile and the tile in front), so curtains and windows right in front of you are recognised;
- Closing SRM's wheel with `RT+B` no longer locks it — it reopens normally.

Each action's own toggle (smash glass / light switch) still applies. **Without SRM installed, behaviour is completely unchanged** — every SRM-related branch is guarded by an "SRM present" check.

### 20. Quick Clothing Actions compatibility

[Quick Clothing Actions](https://steamcommunity.com/sharedfiles/filedetails/?id=3790742081) (QCA) is a clothing wheel, but it only listens for the keyboard (default `G`) and never sets gamepad focus, so the pad does nothing.

Now:

- The **right D-pad wheel** gains a "**Clothing**" entry (using the inventory T-shirt icon), toggleable in Mod Options;
- It opens QCA's clothing wheel: **right stick** picks a garment → `A` enters the sub-wheel → pick wear / remove / extra action → confirm;
- **Confirm** works with `A` / `R3` / D-pad Up / D-pad Right (`ISRadialMenu` locates the current slice from the stick direction, so `A` alone often finds no target);
- `B` / `X` go back from the sub-wheel to the garment list; the top level closes;
- Closing it with `RT+B` no longer locks it.

> Known limitation: QCA itself hardcodes `getSpecificPlayer(0)` when gathering items, so **split-screen player 2** sees player 1's clothing. Single-player and multiplayer (both player 0) are unaffected.

---

## Mod Options panel

**Options → Mod Options → Gamepad QoL Suite** contains: Inventory and Loot, Container operations, Key feature extensions, RB chords, RT+B focus reset, D-pad radial extensions, Panel enhancements, Select key sorting, and Miscellaneous.

"Panel enhancements" is the master switch for all four panel features — info panel, skills panel, build / craft panels and the drying-rack panel. Turn it off and they immediately fall back to vanilla behaviour (the drying-rack panel then only responds to `B`).

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
- **Verified compatible**:
  - [Smart Radial Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=3494108029) — this mod yields the Up wheel and merges its world-object actions into SRM's wheel, see [section 19](#19-smart-radial-menu-compatibility)
  - [Quick Clothing Actions](https://steamcommunity.com/sharedfiles/filedetails/?id=3790742081) — "Clothing" entry in the right wheel with full gamepad support, see [section 20](#20-quick-clothing-actions-compatibility)
- **Not recommended alongside**: other mods that rewrite inventory layout, selection state, or item transfer (duplicate key interception)
- **Multiplayer**: includes one server-side module (liquid-type sync for mixed-liquid auto-drink); both client and server need the mod. The print-media fix is client-only and runs on each client
- **Never modified**: vanilla Lua, CustomGamepadUI's Workshop files, CleanUI, Smart Radial Menu, Quick Clothing Actions

## Known limitations

- Broken-window names occasionally fail to display
- Recognition of external mixed-liquid water sources has not been fully tested
- Up-wheel entries depend on nearby targets; not appearing in open areas is expected
- With Smart Radial Menu installed the vanilla Up wheel no longer appears (SRM only shows its own wheel when the vanilla one is empty — that is its design)
- Quick Clothing Actions' wheel reads player 1's clothing on **split-screen player 2** (QCA hardcodes `getSpecificPlayer(0)`; single-player and multiplayer are unaffected)

---

## Credits and license

- [CustomGamepadUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3001154607) — provides the gamepad UI infrastructure this mod builds on
- Project Zomboid community controller players for the feedback

Free mod made for personal use. **Please do not re-upload it to the Steam Workshop.** Credit the author when redistributing or bundling.
