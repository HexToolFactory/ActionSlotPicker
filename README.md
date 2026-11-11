# Action Slot Picker

WoW: Forever addon for filling action bars without dragging things out of the spellbook.

**Shift + right-click** an action button to open a menu for that slot:

- **Spells/Abilities**: spellbook tab (General, specs ...) → spell → rank, with the spell tooltip on hover
- **Bag**: item type (Consumable, Trade Goods ...) → item
- **Macros**: account-wide or character-specific
- **Update spell rank to the latest available**: per slot; the slot follows the highest rank you know
- **Clear this slot**

**Minimap button**: loadouts of all action bars together. Create, apply, edit (change the bars, then save or cancel),
overwrite, rename, delete. Loadouts are stored per class for the whole account; spells and macros are matched by name.
Drag the button to move it around the minimap.

Spells of a loadout that your character does not know right now (other talents, runes) leave their slot empty and are
placed automatically as soon as you learn them, for example after switching talents. The minimap menu lists them
while they wait.

Slots can only be changed out of combat.

## Commands

- `/asp`: open the loadout menu
- `/asp help`: list the commands
- `/asp minimap`: show or hide the minimap button
- `/asp rank`: list the slots that follow the latest spell rank
- `/asp save <name>`, `/asp load <name>`, `/asp list`: action bar loadouts
- `/asp probe on|off|bars|check <name>|clear`: diagnostics for loadouts; records every step per slot into the saved
  variables (written at `/reload`), useful for bug reports

## Install

Copy the `ActionSlotPicker` folder into `_forever_\Interface\AddOns`, or install it from CurseForge.

## License

MIT
