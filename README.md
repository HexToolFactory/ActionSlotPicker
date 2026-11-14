# Action Slot Picker

WoW: Forever addon for filling action bars without dragging things out of the spellbook.

**Shift + right-click** an action button to open a menu for that slot:

- **Spells/Abilities**: spellbook tab (General, specs ...) → spell → rank, with the spell tooltip on hover
- **Bag**: item type (Consumable, Trade Goods ...) → item
- **Macros**: account-wide or character-specific
- **Spell rank**: per slot. Keep this rank, Latest (highest rank you know), Latest -1 or Latest -2 (one or two ranks
  below it, e.g. a cheaper rank). The slot follows its choice when you learn a new rank
- **Clear this slot**

**Loadout window** (click the minimap button or `/asp`): loadouts of all action bars together. Create from your bars,
apply, edit on the bars (change them, then save or cancel), overwrite, rename, copy, delete. Every slot of a loadout
is shown bar by bar: click a slot to pick its spell, item or macro or its spell rank, or drop one onto it. Red slots
are not available on this character, yellow ones wait to be learned. Loadouts are stored per class for the whole
account; spells and macros are matched by name. Right-click the minimap button for a quick menu; drag it to move it.

Each loadout can equip an equipment set from the character window's Equipment Manager (loadout -> "Equipment set").
The set is bound by name, so every character of the class with a set of that name uses it.

Spells of a loadout that your character does not know right now (other talents, runes) leave their slot empty and are
placed automatically as soon as you learn them, for example after switching talents. The loadout window shows them
while they wait.

Slots can only be changed out of combat.

## Commands

- `/asp`: open the loadout window
- `/asp menu`: open the quick loadout menu
- `/asp help`: list the commands
- `/asp minimap`: show or hide the minimap button
- `/asp rank`: list the slots with a spell rank option
- `/asp save <name>`, `/asp load <name>`, `/asp list`: action bar loadouts
- `/asp probe on|off|bars|check <name>|clear`: diagnostics for loadouts; records every step per slot into the saved
  variables (written at `/reload`), useful for bug reports

## Install

Copy the `ActionSlotPicker` folder into `_forever_\Interface\AddOns`, or install it from CurseForge.

## License

MIT
