# Changelog

## 0.2.2
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
