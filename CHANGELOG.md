# Changelog

## 1.4.0
- Set swap at the bank: with the bank open, switching the loadout or the talent spec fetches the new set from the
  bank, equips it and stores the old set, one step after the other. Pieces both sets use stay on. Away from the
  bank a switch works as before. Switch it off with the "Swap at bank" checkbox in the gear sets window or
  `/asp bankswap`.
- Full bags are no obstacle for that swap: a piece that finds no room in the bags is swapped 1 by 1, straight from
  its bank slot onto you, and the piece you wore lands in that bank slot. A full bank works too, because the new
  set leaves its slots before the old one arrives.
- "Store set in bank" also takes the pieces you are wearing, so a set you have on can go straight into the bank.
  A worn piece stays on when another set you carry (worn or in your bags) uses it too; the chat line says so.
- The items of your equipment sets are written into the saved variables (`ActionSlotPickerCharDB.sets`, per
  character): per set its icon and, per slot, item id, name, link and where the piece is (worn, bags, bank,
  missing). Updated when sets, gear, bags or the bank change and at logout, for tools outside the game.

## 1.3.0
- Equipment sets and the bank: "Store set in bank" moves the set's pieces from your bags into the bank, "Pick up set
  from bank" brings them back. Worn pieces stay on. In the minimap button's right-click menu and in a new "Gear sets"
  button at the bank window; needs the bank open. Also `/asp store <set>` and `/asp pickup <set>`.
- Naked mode: armor and weapons go into your bags (no durability loss), the same pieces go back on when you switch
  it off. In the same two menus, or `/asp naked`.
- Gear sets window (`/asp sets`, the "Gear sets" button at the bank, or the minimap menu): every equipment set with
  its pieces and where each one is - worn, bags, bank or missing - plus Store and Pick up buttons. The addon
  remembers what the bank held when it was last open, so you see which set is in the bank from anywhere.
- Item comparison (Shift): next to the equipped item, a third tooltip "Other spec: <set>" shows the piece your
  other talent spec wears in that slot. It uses the equipment set of the loadout bound to the other spec.
- Fix: no more "save bars / save gear?" prompt after switching the loadout or the talent spec. What differs right
  after a switch (used-up items, a spell that turned into another one, missing set pieces) is no longer asked;
  your own changes afterwards still are.

## 1.2.0
- The spell rank option of a slot (Keep, Latest, Latest -1, Latest -2) now belongs to the loadout. Each loadout
  keeps its own options, and applying a loadout or switching the talent spec brings them back. Before, all loadouts
  shared one option per slot, so a setting made in one spec carried over into the other.
- Setting the option in the slot menu stores it in the active loadout right away, without a save prompt.
- Existing settings carry over: at the first login every loadout takes the options your bars have now.

## 1.1.1
- Fix: while one of the addon's questions was on screen (save bars, save gear, name, confirm), Blizzard's guild
  control window raised "action forbidden" errors that named Action Slot Picker. The questions are the addon's own
  windows now and no longer use the game's popup system. They look and work the same: Escape still means "Not now".

## 1.1.0
- The loadout macro uses the icon of the loadout's equipment set (Equipment Manager), in the window too. Existing
  loadout macros follow when a set is bound or its icon changes; unbinding the set brings back the book.

## 1.0.2
- Fix: no prompt to save bar or gear changes until a loadout had been applied or saved. Now the loadout bound to
  your current talent spec counts as the active one until you apply or save another.

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
