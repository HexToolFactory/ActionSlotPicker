# Changelog

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
