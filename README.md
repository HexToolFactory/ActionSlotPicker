# Loadout Manager

WoW: Forever addon for action bar loadouts: one loadout per talent spec with its equipment set, gear sets to and from
the bank, and a slot picker that fills action bars without dragging things out of the spellbook.

Called **Action Slot Picker** before version 2.0.0. Your loadouts and settings are taken over at the first login
under the new name, and `/asp` still works next to `/lm`.

**Shift + right-click** an action button to open a menu for that slot:

- **Spells/Abilities**: spellbook tab (General, specs ...) → spell → rank, with the spell tooltip on hover
- **Bag**: item type (Consumable, Trade Goods ...) → item
- **Macros**: account-wide or character-specific
- **Spell rank**: per slot. Latest (the default: the highest rank you know, also after learning a new one), Latest -1
  or Latest -2 (one or two ranks below it, e.g. a cheaper rank) or Keep this rank. A lower rank you pick from the
  menu or drag onto the bar is kept. Each loadout keeps its own rank options, so they switch with the loadout and
  the talent spec
- **Clear this slot**

**Loadout window** (click the minimap button or `/lm`): loadouts of all action bars together. Create from your bars,
apply, edit on the bars (change them, then save or cancel), overwrite, rename, copy, delete. Every slot of a loadout
is shown bar by bar: click a slot to pick its spell, item or macro or its spell rank, or drop one onto it. Red slots
are not available on this character, yellow ones wait to be learned. Loadouts are stored per class for the whole
account; spells and macros are matched by name. Right-click the minimap button for a quick menu; drag it to move it.

**Gear** (right-click the minimap button, or the "Gear sets" button at the bank window):

- **Store set in bank / Pick up set from bank**: moves the pieces of an equipment set between you and the bank while
  the bank is open. Store takes the pieces in your bags and the ones you wear; a worn piece stays on when another set
  you carry uses it too. `/lm store <set>`, `/lm pickup <set>`
- **Set swap at the bank**: with the bank open, switching the loadout or the talent spec fetches the new loadout's set
  from the bank, equips it and stores the set of the loadout before. "Swap at bank" checkbox in the gear sets window,
  or `/lm bankswap`
- **Naked mode**: armor and weapons go into your bags, so dying costs no durability; switch it off and the same pieces
  go back on. `/lm naked`
- **Gear sets window** (`/lm sets`): every equipment set with its pieces and where each one is: worn, bags, bank or
  missing. The bank's gear is remembered from the last visit, so the window also works away from the bank
- **Comparison window**: Shift + Alt + left click an item to compare it with the piece every gear set uses in that
  slot. One column per set (with its loadout and talent spec), all stats, and the difference in green or red.
  Attack Power, Spell Power and Crit are totals: the item's own lines plus what its stats give your class under
  each set's talent spec, talents included. `/lm compare [item link]` does the same

**Saved variables**: the items of every equipment set are stored per character in `LoadoutManagerCharDB.sets`
(`[set name].items[inventory slot] = { id, name, link, where }`, `where` = worn, bags, bank or missing), with the
time in `setsSaved`. The game writes the file at `/reload` and logout.

**Loadout macro**: drag the book icon next to the loadout's name onto an action bar. Clicking that button applies the
loadout (`/lm load <name>`, created as a character macro the first time).

**Talent spec**: bind a loadout to Spec 1 or Spec 2 ("Spec" button in the window). Switching to that spec applies the
loadout. This is stored per character, so each character of the class can use its own loadouts for its specs.

The loadout you applied or saved last is the **active** one. When you change your bars afterwards, a prompt asks
whether to save them into it; when your gear changes and the active loadout has an equipment set, a prompt asks
whether to save the gear into that set. Switch either prompt off in the loadout window.

Each loadout can equip an equipment set from the character window's Equipment Manager (loadout -> "Equipment set").
The set is bound by name, so every character of the class with a set of that name uses it.

Spells of a loadout that your character does not know right now (other talents, runes) leave their slot empty and are
placed automatically as soon as you learn them, for example after switching talents. The loadout window shows them
while they wait.

Slots can only be changed out of combat.

## Commands

- `/lm`: open the loadout window
- `/lm menu`: open the quick loadout menu
- `/lm help`: list the commands
- `/lm minimap`: show or hide the minimap button
- `/lm rank`: list the slots with a spell rank option
- `/lm save <name>`, `/lm load <name>`, `/lm list`: action bar loadouts
- `/lm probe on|off|bars|check <name>|clear`: diagnostics for loadouts; records every step per slot into the saved
  variables (written at `/reload`), useful for bug reports

## Install

Copy the `LoadoutManager` folder into `_forever_\Interface\AddOns`, or install it from CurseForge. The second folder,
`ActionSlotPicker`, holds only the saved data of the old name; keep it until every character has logged in once.

## License

MIT
