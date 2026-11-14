# Changelog

## 1.0.1
- Fix: in the loadout window the Spec button reached past the right edge of the window. The button rows start
  at the left edge again and the window is a little wider.

## 1.0.0
- First stable release. Same features as 0.3.0: slot picker with spell rank options (latest, -1, -2), loadout window,
  loadout macro for your bars, loadouts per talent spec, equipment sets on loadouts and prompts to save bar and gear
  changes.

## 0.3.0
- New loadout window: click the minimap button or type `/asp`. List of the class's loadouts on the left; Apply,
  Edit on bars, Overwrite from bars, Rename, Copy, Delete and the equipment set on the right, plus every slot bar by
  bar. Click a slot to pick its spell, item or macro or its rank option; drop a spell, item or macro onto a slot.
  Slots that are not available on this character are red, spells waiting to be learned yellow. Right-click on the
  minimap button (or `/asp menu`) still opens the quick menu.
- Spell rank per slot: Keep this rank, Latest, Latest -1 or Latest -2 (submenu "Spell rank" in the slot menu,
  replaces the checkbox). Latest -1 / -2 follow one or two ranks below the highest known rank, also after learning
  a new one. Loadouts save this option per slot. Old "latest" settings carry over.
- Loadouts can be copied.
- Loadout macro: drag the book icon next to the loadout's name in the window onto an action bar. It is a character
  macro (`/asp load <name>`, created the first time) that applies the loadout; renaming the loadout updates it.
- Talent spec per loadout ("Spec" button in the window, "Talent spec" in the quick menu): switching to that spec
  (dual spec) applies the loadout. Stored per character, one loadout per spec.
- Save prompts: the loadout you applied or saved last is the active one (marked in the window and the quick menu).
  When you change your action bars afterwards, a prompt asks whether to save them into it; when your gear changes
  and the active loadout has an equipment set, a prompt asks whether to save the gear into that set. "Not now" is
  remembered until you change something else. Both can be switched off in the loadout window. No prompts while
  editing a loadout or in combat.
- Cancelling an edit brings back the spells that were waiting to be learned before the edit.
- Loadouts can equip an equipment set (loadout window or quick menu -> loadout -> "Equipment set"). Applying the loadout equips it;
  cancelling an edit puts the set back that was worn before. Sets are bound by name, so every character of the class
  with a set of that name can use it.
- Fix: Lua error at login ("attempt to call a nil value") while the loadout probe was switched on.
- Fix: switching loadouts ignored the "Update spell rank to the latest available" option of a slot. The option now
  belongs to the slot: a slot with it gets the highest known rank from every loadout, and applying a loadout no longer
  switches it off (a loadout saved with the option still switches it on).

## 0.2.1
- Loadouts: spells the character does not know when a loadout is applied (other talents, runes) no longer leave the
  old action in their slot. The slot is cleared and the spell is placed as soon as it is learned; the minimap menu shows
  the waiting spells. Saving a loadout keeps its waiting spells.
- New `/asp probe` diagnostics for loadouts (off by default).

## 0.2.0
- First public release: shift + right-click slot menu (spells by tab and rank, bag items, macros), per-slot
  "latest rank" option, minimap button with action bar loadouts and edit mode.
