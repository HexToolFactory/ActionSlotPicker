-- Action Slot Picker
-- Shift + right-click an action button: dropdown with
--   1. Spells/Abilities  -> spellbook tab (General, specs ...) -> spell -> rank (tooltip on hover)
--   2. Bag               -> item type (Consumable, Trade Goods ...) -> item
--   3. Macros            -> Account-wide / Character-specific
--   checkbox "Update spell rank to the latest available" (only for the clicked slot), "Clear this slot"
-- Minimap button: loadouts of all action bars together (new, apply, edit with save/cancel, overwrite,
-- rename, delete). Drag the button to move it around the minimap.
-- Placing actions is blocked in combat; everything here only runs out of combat.

local ADDON = ...
local DB      -- account: loadouts per class
local CharDB  -- character: latest[slot] = true for slots that follow the latest spell rank

local function IsLatest(slot) return CharDB.latest[slot] == true end
local function SetLatest(slot, on) CharDB.latest[slot] = on and true or nil end

local MAX_SLOT = 180
local ACCOUNT_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_ACCOUNT_MACROS) or 120
local BANK = Enum.SpellBookSpellBank.Player
local ITEM_SPELL = Enum.SpellBookItemType.Spell
local ITEM_FLYOUT = Enum.SpellBookItemType.Flyout
local SCROLL_HEIGHT = 520

local function Print(msg)
    print("|cff66bbffAction Slot Picker:|r " .. msg)
end

-- Values can be secret on this client (mostly in combat). Treat a secret as "unknown".
local function Safe(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Icon(tex)
    if not tex then return "" end
    return "|T" .. tex .. ":16:16:0:0:64:64:5:59:5:59|t "
end

local function ByLabel(a, b)
    return (a.sortKey or a.name) < (b.sortKey or b.name)
end

local function RankNumber(sub)
    if type(sub) ~= "string" then return nil end
    return tonumber(sub:match("(%d+)"))
end

local function ClassKey()
    local _, classFile = UnitClass("player")
    return classFile or "UNKNOWN"
end

local function CombatBlocked()
    if InCombatLockdown() then
        Print("not possible in combat.")
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Probe (/asp probe on): records every loadout step per slot into ActionSlotPickerDB.probe.runs,
-- written to disk at /reload or logout. Off by default; costs nothing while off.
------------------------------------------------------------------------

local PROBE_MAX_RUNS = 15
local PROBE_WATCH_SECONDS = 4
local probeRun -- run that receives lines right now
local probeWatch -- run that receives events (slot changes, UI errors) for a few seconds

local function ProbeOn()
    return DB and DB.probe and DB.probe.enabled
end

local function ActionText(slot)
    local t, id, sub = GetActionInfo(slot)
    t, id, sub = Safe(t), Safe(id), Safe(sub)
    if not t then return "empty" end
    local text = t .. ":" .. tostring(id)
    if sub ~= nil and sub ~= "" then text = text .. "/" .. tostring(sub) end
    return text
end

local function CursorText()
    local a, b, c, d = GetCursorInfo()
    a, b, c, d = Safe(a), Safe(b), Safe(c), Safe(d)
    if not a then return "none" end
    return ("%s,%s,%s,%s"):format(tostring(a), tostring(b), tostring(c), tostring(d))
end

local function ProbeLine(fmt, ...)
    if probeRun then probeRun.lines[#probeRun.lines + 1] = fmt:format(...) end
end

local function ProbeBegin(kind, detail)
    if not ProbeOn() then return nil end
    local name, realm = UnitFullName("player")
    local version, build = GetBuildInfo()
    local run = {
        kind = kind, detail = detail, at = date("%Y-%m-%d %H:%M:%S"), t0 = GetTime(),
        char = (name or "?") .. "-" .. (realm or ""), class = ClassKey(), build = tostring(version) .. "." .. tostring(build),
        page = GetActionBarPage and Safe(GetActionBarPage()), bonus = GetBonusBarOffset and Safe(GetBonusBarOffset()),
        combat = InCombatLockdown() and true or nil, lines = {}, events = {},
    }
    local runs = DB.probe.runs
    runs[#runs + 1] = run
    while #runs > PROBE_MAX_RUNS do table.remove(runs, 1) end
    probeRun = run
    return run
end

local function ProbeEnd()
    probeRun = nil
end

-- Events for a few seconds after a run: did the server keep the slots, did the client complain?
local function ProbeWatch(run)
    if not run then return end
    probeWatch = run
    C_Timer.After(PROBE_WATCH_SECONDS, function()
        if probeWatch == run then probeWatch = nil end
    end)
end

-- expected = { [slot] = ActionText right after placing }; compared again after 1 s and 3 s.
local function ProbeVerify(run, expected)
    if not run then return end
    for _, delay in ipairs({ 1, 3 }) do
        C_Timer.After(delay, function()
            local diffs = 0
            for slot, want in pairs(expected) do
                local now = ActionText(slot)
                if now ~= want then
                    diffs = diffs + 1
                    run.lines[#run.lines + 1] = ("verify+%ds slot %d: expected %s, now %s"):format(delay, slot, want, now)
                end
            end
            run.lines[#run.lines + 1] = ("verify+%ds: %d of %d slots differ"):format(delay, diffs, (function()
                local n = 0
                for _ in pairs(expected) do n = n + 1 end
                return n
            end)())
        end)
    end
end

local probeEvents = CreateFrame("Frame")
probeEvents:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
probeEvents:RegisterEvent("UI_ERROR_MESSAGE")
probeEvents:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
probeEvents:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
probeEvents:SetScript("OnEvent", function(_, event, a, b)
    local run = probeWatch
    if not run then return end
    local dt = GetTime() - run.t0
    if event == "ACTIONBAR_SLOT_CHANGED" then
        run.slotEvents = run.slotEvents or {}
        local slot = Safe(a)
        if slot then run.slotEvents[slot] = (run.slotEvents[slot] or 0) + 1 end
        return
    end
    local text = Safe(b) or Safe(a)
    run.events[#run.events + 1] = ("%.2fs %s %s"):format(dt, event, tostring(text))
end)

------------------------------------------------------------------------
-- Data: spellbook
------------------------------------------------------------------------

-- Returns tabs = { { name, icon, spells = { { name, icon, ranks = { {spellID, index, sub, rank, flyout} } } } } }
-- and best = { [spellName] = rankEntry } (highest rank per name) and byID = { [spellID] = rankEntry }.
local function ReadSpellbook()
    local tabs, best, byID = {}, {}, {}
    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for line = 1, numLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info and not info.shouldHide and (info.numSpellBookItems or 0) > 0 then
            local tab = { name = info.name or ("Tab " .. line), icon = info.iconID, spells = {} }
            local byName = {}
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(i, BANK)
                local isSpell = item and item.itemType == ITEM_SPELL and not item.isPassive and item.spellID
                local isFlyout = item and item.itemType == ITEM_FLYOUT
                if (isSpell or isFlyout) and item.name then
                    local name = item.name
                    local sub = item.subName
                    if sub == "" then sub = nil end
                    local entry = {
                        name = name, spellID = item.spellID, index = i, sub = sub,
                        rank = RankNumber(sub) or 0, icon = item.iconID,
                        flyout = isFlyout and item.actionID or nil,
                    }
                    local spell = byName[name]
                    if not spell then
                        spell = { name = name, icon = item.iconID, ranks = {} }
                        byName[name] = spell
                        tab.spells[#tab.spells + 1] = spell
                    end
                    spell.ranks[#spell.ranks + 1] = entry
                    if entry.spellID and not entry.flyout then
                        byID[entry.spellID] = entry
                        local b = best[name]
                        if not b or entry.rank > b.rank then best[name] = entry end
                    end
                end
            end
            table.sort(tab.spells, ByLabel)
            for _, spell in ipairs(tab.spells) do
                table.sort(spell.ranks, function(a, b) return a.rank < b.rank end)
                spell.icon = spell.ranks[#spell.ranks].icon or spell.icon
            end
            if #tab.spells > 0 then tabs[#tabs + 1] = tab end
        end
    end
    return tabs, best, byID
end

------------------------------------------------------------------------
-- Data: bags and macros
------------------------------------------------------------------------

local function ItemName(itemID, link)
    local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not name and link then name = link:match("%[(.-)%]") end
    return name or ("Item " .. itemID)
end

-- Returns types = { { name, items = { { itemID, name, icon, count, bag, slot, link } } } }
local function ReadBags()
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    local byType, types, seen = {}, {}, {}
    for bag = 0, lastBag do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local itemID = info and info.itemID
            if itemID then
                local item = seen[itemID]
                if item then
                    item.count = item.count + (info.stackCount or 1)
                else
                    local _, itemType = C_Item.GetItemInfoInstant(itemID)
                    itemType = itemType or "Other"
                    item = {
                        itemID = itemID, name = ItemName(itemID, info.hyperlink), icon = info.iconFileID,
                        count = info.stackCount or 1, bag = bag, slot = slot,
                    }
                    seen[itemID] = item
                    local group = byType[itemType]
                    if not group then
                        group = { name = itemType, items = {} }
                        byType[itemType] = group
                        types[#types + 1] = group
                    end
                    group.items[#group.items + 1] = item
                end
            end
        end
    end
    table.sort(types, ByLabel)
    for _, group in ipairs(types) do table.sort(group.items, ByLabel) end
    return types
end

local function ReadMacros()
    local numGlobal, numChar = GetNumMacros()
    local account, character = {}, {}
    for i = 1, numGlobal or 0 do
        local name, icon, body = GetMacroInfo(i)
        if name then account[#account + 1] = { index = i, name = name, icon = icon, body = body } end
    end
    for i = ACCOUNT_MACROS + 1, ACCOUNT_MACROS + (numChar or 0) do
        local name, icon, body = GetMacroInfo(i)
        if name then character[#character + 1] = { index = i, name = name, icon = icon, body = body } end
    end
    table.sort(account, ByLabel)
    table.sort(character, ByLabel)
    return account, character
end

------------------------------------------------------------------------
-- Placing actions
------------------------------------------------------------------------

-- pickup() puts something on the cursor; it goes into the slot and whatever was there is dropped.
-- Returns ok, plus (only while a probe run is open) the cursor after pickup and after PlaceAction.
local function PlaceInto(slot, pickup)
    ClearCursor()
    pickup()
    local cursor = probeRun and CursorText() or nil
    if not GetCursorInfo() then return false, cursor end
    PlaceAction(slot)
    local swapped = probeRun and CursorText() or nil
    ClearCursor()
    return true, cursor, swapped
end

local function ClearSlot(slot)
    ClearCursor()
    PickupAction(slot)
    ClearCursor()
end

local function PickupRank(entry)
    return function()
        if entry.index then
            C_SpellBook.PickupSpellBookItem(entry.index, BANK)
        else
            C_Spell.PickupSpell(entry.spellID)
        end
    end
end

local function PickupItemFn(itemID)
    return function() C_Item.PickupItem(itemID) end
end

local function PickupMacroFn(index)
    return function() PickupMacro(index) end
end

------------------------------------------------------------------------
-- Keep spell ranks at the latest known rank (only slots switched on for it)
------------------------------------------------------------------------

local pendingUpgrade = false

local function UpgradeSlot(slot, best, byID)
    local actionType, id = GetActionInfo(slot)
    actionType, id = Safe(actionType), Safe(id)
    local current = actionType == "spell" and id and byID[id]
    local top = current and best[current.name]
    if top and top.spellID ~= current.spellID and top.rank > current.rank then
        local before = probeRun and ActionText(slot)
        local ok, cursor, swapped = PlaceInto(slot, PickupRank(top))
        ProbeLine("upgrade slot %d: %s %s(r%s) -> %s(r%s) book#%s cursor=%s placed=%s swapped=%s ok=%s", slot,
            tostring(before), current.name, tostring(current.rank), tostring(top.spellID), tostring(top.rank),
            tostring(top.index), tostring(cursor), probeRun and ActionText(slot) or "", tostring(swapped), tostring(ok))
        if ok then return top end
    end
end

-- onlySlot: upgrade just that slot (checkbox switched on); otherwise every slot switched on.
local function UpgradeRanks(onlySlot, reason)
    if not next(CharDB.latest) then return end
    if InCombatLockdown() then
        pendingUpgrade = true
        return
    end
    pendingUpgrade = false
    local ownRun = not probeRun and ProbeBegin("upgrade", reason or (onlySlot and ("checkbox slot " .. onlySlot)) or "?")
    local _, best, byID = ReadSpellbook()
    if probeRun then
        local flagged = {}
        for slot in pairs(CharDB.latest) do flagged[#flagged + 1] = slot end
        table.sort(flagged)
        ProbeLine("latest-rank slots: %s", table.concat(flagged, ","))
    end
    for slot in pairs(CharDB.latest) do
        if not onlySlot or slot == onlySlot then
            local top = UpgradeSlot(slot, best, byID)
            if top then
                Print(("slot %d: %s set to %s."):format(slot, top.name, top.sub or "the latest rank"))
            end
        end
    end
    if ownRun then
        ProbeWatch(ownRun)
        ProbeEnd()
    end
end

------------------------------------------------------------------------
-- Loadouts (per class, account-wide)
------------------------------------------------------------------------

local function Loadouts()
    local key = ClassKey()
    DB.loadouts[key] = DB.loadouts[key] or {}
    return DB.loadouts[key]
end

-- Equipment sets bound to loadouts. Bound by name: set IDs differ per character, loadouts are shared per class.
local function EquipmentSets()
    local sets = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then return sets end
    for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
        local name, icon, _, isEquipped, _, _, _, numLost = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            sets[#sets + 1] = { name = name, icon = icon, setID = setID, equipped = isEquipped, lost = numLost }
        end
    end
    table.sort(sets, ByLabel)
    return sets
end

local function FindEquipmentSet(name)
    for _, set in ipairs(EquipmentSets()) do
        if set.name == name then return set end
    end
end

local function EquippedSetName()
    for _, set in ipairs(EquipmentSets()) do
        if set.equipped then return set.name end
    end
end

-- Equips the set bound to a loadout. Called out of combat only (ApplyLoadout checks).
local function EquipBoundSet(name)
    if not name then return end
    local set = FindEquipmentSet(name)
    if not set then
        Print(("no equipment set \"%s\" on this character."):format(name))
        ProbeLine("equipment set %s: not on this character", name)
        return
    end
    if set.equipped then
        ProbeLine("equipment set %s: already equipped", name)
        return
    end
    local ok = C_EquipmentSet.UseEquipmentSet(set.setID)
    ProbeLine("equipment set %s (id %s): UseEquipmentSet -> %s, items lost %s", name, tostring(set.setID), tostring(ok), tostring(set.lost))
    if ok then
        Print(("equipped \"%s\"."):format(name))
    else
        Print(("could not equip \"%s\"."):format(name))
    end
end

local function CaptureSlots()
    local _, _, byID = ReadSpellbook()
    local slots, count = {}, 0
    for slot = 1, MAX_SLOT do
        local actionType, id, subType = GetActionInfo(slot)
        actionType, id = Safe(actionType), Safe(id)
        if actionType and id then
            local entry = { t = actionType, id = id }
            if actionType == "spell" then
                local known = byID[id]
                entry.name = (known and known.name) or C_Spell.GetSpellName(id)
                entry.rank = known and known.rank or nil
            elseif actionType == "item" then
                entry.name = ItemName(id)
            elseif actionType == "macro" then
                entry.name = Safe(GetActionText(slot)) or GetMacroInfo(id)
            end
            entry.latest = IsLatest(slot) or nil
            slots[slot] = entry
            count = count + 1
            ProbeLine("capture slot %d: %s name=%s rank=%s latest=%s text=%s", slot, ActionText(slot),
                tostring(entry.name), tostring(entry.rank), tostring(entry.latest), tostring(Safe(GetActionText(slot))))
        elseif actionType or id then
            ProbeLine("capture slot %d: SKIPPED type=%s id=%s (secret or incomplete)", slot, tostring(actionType), tostring(id))
        end
    end
    return slots, count
end

local function FindFlyoutIndex(flyoutID)
    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for line = 1, numLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info then
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(i, BANK)
                if item and item.itemType == ITEM_FLYOUT and item.actionID == flyoutID then return i end
            end
        end
    end
end

-- Character macros first (they shadow account macros of the same name on the bars).
local function MacroIndexByName(name)
    if not name then return nil end
    if GetMacroIndexByName then
        local index = GetMacroIndexByName(name)
        if index and index > 0 then return index end
    end
    local account, character = ReadMacros()
    for _, list in ipairs({ character, account }) do
        for _, macro in ipairs(list) do
            if macro.name == name then return macro.index end
        end
    end
end

-- Returns a pickup function for a saved slot entry (nil if it cannot be restored) and how it was resolved.
-- latest: the target slot follows the latest rank, so a known lower rank is replaced by the best rank.
local function PickupForEntry(entry, best, byID, latest)
    if entry.t == "spell" then
        local known = byID[entry.id]
        local top = entry.name and best[entry.name]
        local how = known and "same id" or "not in book"
        if top and (not known or (latest and top.rank > known.rank)) then
            known = top
            how = how .. ", by name -> best rank"
        end
        if known then
            return PickupRank(known), ("%s: book#%s id %s r%s"):format(how, tostring(known.index), tostring(known.spellID), tostring(known.rank))
        end
        if IsSpellKnown and IsSpellKnown(entry.id) then
            return function() C_Spell.PickupSpell(entry.id) end, "IsSpellKnown -> C_Spell.PickupSpell"
        end
        -- Not known right now (other talents, rune not engraved): try the id anyway; the caller sees an empty cursor.
        return function() C_Spell.PickupSpell(entry.id) end, "spell not known, trying C_Spell.PickupSpell"
    elseif entry.t == "item" then
        return PickupItemFn(entry.id), "C_Item.PickupItem " .. tostring(entry.id)
    elseif entry.t == "macro" then
        local index = MacroIndexByName(entry.name)
        if index then return PickupMacroFn(index), "macro by name -> index " .. index end
        return nil, "no macro named " .. tostring(entry.name)
    elseif entry.t == "flyout" then
        local index = FindFlyoutIndex(entry.id)
        if index then return function() C_SpellBook.PickupSpellBookItem(index, BANK) end, "flyout book#" .. index end
        return nil, "flyout not in book"
    elseif entry.t == "equipmentset" and C_EquipmentSet then
        local setID = C_EquipmentSet.GetEquipmentSetID(entry.id)
        if setID then return function() C_EquipmentSet.PickupEquipmentSet(setID) end, "equipment set " .. setID end
        return nil, "no equipment set " .. tostring(entry.id)
    end
    return nil, "unsupported action type " .. tostring(entry.t)
end

local function EntryText(entry)
    return ("%s:%s name=%s rank=%s latest=%s"):format(tostring(entry.t), tostring(entry.id), tostring(entry.name),
        tostring(entry.rank), tostring(entry.latest))
end

-- Spells of a loadout that the character does not know yet (other talents, runes): their slot is left empty and
-- filled as soon as the spell is learned. CharDB.pending = { loadout = name, slots = { [slot] = entry } }.
local function PendingCount()
    local n = 0
    for _ in pairs(CharDB.pending and CharDB.pending.slots or {}) do n = n + 1 end
    return n
end

local function PendingNames()
    local names = {}
    for slot, entry in pairs(CharDB.pending and CharDB.pending.slots or {}) do
        names[#names + 1] = ("%s (slot %d)"):format(tostring(entry.name or entry.id), slot)
    end
    table.sort(names)
    return names
end

local function ApplyLoadout(loadout, reason)
    if CombatBlocked() then return end
    local run = ProbeBegin("apply", ("%s (%s)"):format(loadout.name, reason or "apply"))
    local _, best, byID = ReadSpellbook()
    local placed, cleared, missing, waiting = 0, 0, {}, {}
    local expected = {}
    local pending = { loadout = loadout.name, slots = {} }
    for slot = 1, MAX_SLOT do
        local entry = loadout.slots[slot]
        local before = run and ActionText(slot)
        local actionType = Safe(GetActionInfo(slot))
        -- The latest-rank option belongs to the slot: a loadout can switch it on, never off.
        local latest = IsLatest(slot) or (entry and entry.latest) or false
        SetLatest(slot, latest)
        if entry then
            local pickup, how = PickupForEntry(entry, best, byID, latest)
            if latest then how = how .. " [latest rank slot]" end
            local ok, cursor, swapped = false, nil, nil
            if pickup then ok, cursor, swapped = PlaceInto(slot, pickup) end
            local result = ok and "PLACED" or (pickup and "NOCURSOR" or "UNRESOLVED")
            if ok then
                placed = placed + 1
            elseif entry.t == "spell" or entry.t == "flyout" then
                -- The old action must not stay in a slot that belongs to another spell; wait for the spell instead.
                if actionType then ClearSlot(slot) end
                pending.slots[slot] = entry
                waiting[#waiting + 1] = entry.name or tostring(entry.id)
                result = result .. " -> cleared, waits until learned"
            else
                missing[#missing + 1] = entry.name or (entry.t .. " " .. tostring(entry.id))
            end
            if run then
                local after = ActionText(slot)
                expected[slot] = after
                ProbeLine("slot %d: %s | want %s | %s | cursor=%s | now=%s | swapped=%s | %s", slot, before, EntryText(entry),
                    how, tostring(cursor), after, tostring(swapped), result)
            end
        elseif actionType then
            ClearSlot(slot)
            cleared = cleared + 1
            if run then
                local after = ActionText(slot)
                expected[slot] = after
                ProbeLine("slot %d: %s | not in loadout -> clear | now=%s | %s", slot, before, after,
                    after == "empty" and "CLEARED" or "STILL SET")
            end
        end
    end
    CharDB.pending = next(pending.slots) and pending or nil
    Print(("loadout \"%s\" applied: %d placed, %d cleared."):format(loadout.name, placed, cleared))
    EquipBoundSet(loadout.equipmentSet)
    if #waiting > 0 then
        table.sort(waiting)
        Print(("not known yet, placed as soon as you learn them (e.g. after switching talents): %s"):format(table.concat(waiting, ", ")))
    end
    if #missing > 0 then
        Print("not available: " .. table.concat(missing, ", "))
    end
    if run then
        ProbeLine("summary: %d placed, %d cleared, %d waiting, %d missing, cursor at end=%s", placed, cleared, #waiting, #missing, CursorText())
        ProbeWatch(run)
        ProbeVerify(run, expected)
        ProbeEnd()
    end
end

-- Places waiting spells that are known now. A slot the player filled in the meantime is left alone and forgotten.
local function FillPending(reason)
    local pending = CharDB.pending
    if not pending or not next(pending.slots) then return end
    if InCombatLockdown() then return end
    local run = ProbeBegin("pending", reason or "?")
    local _, best, byID = ReadSpellbook()
    local filled = {}
    for slot, entry in pairs(pending.slots) do
        local now = ActionText(slot)
        if now ~= "empty" then
            pending.slots[slot] = nil
            ProbeLine("slot %d: %s waited, but the slot holds %s now -> forgotten", slot, tostring(entry.name), now)
        else
            local known = byID[entry.id] or (entry.name and best[entry.name])
            if known then
                local ok, cursor = PlaceInto(slot, PickupForEntry(entry, best, byID, IsLatest(slot) or entry.latest))
                ProbeLine("slot %d: %s known now -> cursor=%s now=%s ok=%s", slot, tostring(entry.name), tostring(cursor),
                    run and ActionText(slot) or "", tostring(ok))
                if ok then
                    pending.slots[slot] = nil
                    filled[#filled + 1] = entry.name or tostring(entry.id)
                end
            end
        end
    end
    if not next(pending.slots) then CharDB.pending = nil end
    if #filled > 0 then
        table.sort(filled)
        Print(("loadout \"%s\": placed %s."):format(tostring(pending.loadout), table.concat(filled, ", ")))
    end
    if run then
        ProbeLine("filled %d, still waiting %d", #filled, PendingCount())
        ProbeWatch(run)
        ProbeEnd()
    end
end

local function SaveLoadout(name, existing)
    if CombatBlocked() then return end
    local run = ProbeBegin("save", ("%s (%s)"):format(name or "?", existing and "overwrite" or "new"))
    local slots, count = CaptureSlots()
    -- Spells of this loadout that still wait to be learned keep their slot (it is empty on the bars right now).
    local pending = CharDB.pending
    if pending and existing and pending.loadout == existing.name then
        for slot, entry in pairs(pending.slots) do
            if not slots[slot] then
                slots[slot] = entry
                count = count + 1
                ProbeLine("slot %d: kept waiting %s", slot, tostring(entry.name))
            end
        end
    end
    if run then
        ProbeLine("captured %d slots", count)
        ProbeEnd()
    end
    local loadout = existing
    if not loadout then
        loadout = { name = name }
        local list = Loadouts()
        list[#list + 1] = loadout
    end
    loadout.slots = slots
    loadout.saved = date("%Y-%m-%d %H:%M")
    Print(("loadout \"%s\" saved (%d slots)."):format(loadout.name, count))
end

local function FindLoadout(name)
    for i, loadout in ipairs(Loadouts()) do
        if loadout.name:lower() == name:lower() then return loadout, i end
    end
end

-- Edit mode: the loadout is put on the bars, the player changes the bars (slot picker, drag and drop),
-- then saves the bars into the loadout or cancels, which restores the bars from before the edit.
-- CharDB.editing = { name = loadout name, backup = slots captured before the edit } survives /reload.
local function EditingLoadout()
    local editing = CharDB.editing
    return editing and FindLoadout(editing.name)
end

local function StopEditing()
    CharDB.editing = nil
end

local function StartEdit(loadout)
    if CombatBlocked() then return end
    local run = ProbeBegin("edit-start backup", loadout.name)
    local backup = CaptureSlots()
    local backupSet = EquippedSetName()
    if CharDB.editing then
        ProbeLine("already editing %s: keeping its backup instead", tostring(CharDB.editing.name))
        backup = CharDB.editing.backup -- switching loadouts keeps the original bars and gear
        backupSet = CharDB.editing.backupSet
    end
    ProbeLine("equipment set before editing: %s", tostring(backupSet))
    if run then ProbeEnd() end
    ApplyLoadout(loadout, "edit start")
    CharDB.editing = { name = loadout.name, backup = backup, backupSet = backupSet }
    Print(("editing \"%s\": change your action bars, then use the minimap button to save or cancel."):format(loadout.name))
end

local function SaveEdit()
    local loadout = EditingLoadout()
    if not loadout or CombatBlocked() then return end
    SaveLoadout(loadout.name, loadout)
    StopEditing()
end

local function CancelEdit()
    local editing = CharDB.editing
    if not editing or CombatBlocked() then return end
    ApplyLoadout({ name = "bars before editing", slots = editing.backup or {}, equipmentSet = editing.backupSet }, "cancel edit")
    StopEditing()
end

local function DeleteLoadout(loadout)
    local list = Loadouts()
    for i, l in ipairs(list) do
        if l == loadout then
            if ProbeBegin("delete", loadout.name) then
                ProbeLine("deleting %s (%d of %d), editing=%s", loadout.name, i, #list, tostring(CharDB.editing and CharDB.editing.name))
                ProbeEnd()
            end
            if EditingLoadout() == loadout then StopEditing() end
            table.remove(list, i)
            Print(("loadout \"%s\" deleted."):format(loadout.name))
            return
        end
    end
end

StaticPopupDialogs["ACTIONSLOTPICKER_NAME"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 40,
    OnShow = function(dialog, data)
        local box = dialog:GetEditBox()
        box:SetText(data and data.default or "")
        box:HighlightText()
        box:SetFocus()
    end,
    OnAccept = function(dialog, data)
        data.accept(strtrim(dialog:GetEditBox():GetText() or ""))
    end,
    EditBoxOnEnterPressed = function(editBox, data)
        data.accept(strtrim(editBox:GetText() or ""))
        editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ACTIONSLOTPICKER_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(dialog, data) data.accept() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

local function AskName(prompt, default, accept)
    StaticPopup_Show("ACTIONSLOTPICKER_NAME", prompt, nil, { default = default, accept = accept })
end

local function Confirm(prompt, accept)
    StaticPopup_Show("ACTIONSLOTPICKER_CONFIRM", prompt, nil, { accept = accept })
end

local function NewLoadoutDialog()
    AskName("Name for the new loadout (saves all action bars):", "", function(name)
        if name == "" then return end
        local existing = FindLoadout(name)
        if existing then
            Confirm(("Loadout \"%s\" exists. Overwrite it with the current bars?"):format(existing.name), function()
                SaveLoadout(existing.name, existing)
            end)
        else
            SaveLoadout(name)
        end
    end)
end

local function RenameDialog(loadout)
    AskName(("Rename loadout \"%s\" to:"):format(loadout.name), loadout.name, function(name)
        if name == "" or name == loadout.name then return end
        local other = FindLoadout(name)
        if other and other ~= loadout then
            Print(("a loadout named \"%s\" already exists."):format(other.name))
            return
        end
        Print(("loadout \"%s\" renamed to \"%s\"."):format(loadout.name, name))
        if EditingLoadout() == loadout then CharDB.editing.name = name end
        loadout.name = name
    end)
end

local function CountSlots(loadout)
    local n = 0
    for _ in pairs(loadout.slots or {}) do n = n + 1 end
    return n
end

------------------------------------------------------------------------
-- Menu
------------------------------------------------------------------------

local function Scroll(desc, count)
    if count > 22 then desc:SetScrollMode(SCROLL_HEIGHT) end
end

local function SpellTooltip(desc, entry)
    desc:SetTooltip(function(tooltip)
        if entry.flyout or not entry.spellID then
            GameTooltip_SetTitle(tooltip, entry.name)
        else
            tooltip:SetSpellByID(entry.spellID)
        end
    end)
end

local function AddSpells(root, slot)
    local tabs = ReadSpellbook()
    local spellsDesc = root:CreateButton("Spells/Abilities")
    if #tabs == 0 then
        spellsDesc:CreateTitle("No spells")
        return
    end
    for _, tab in ipairs(tabs) do
        local tabDesc = spellsDesc:CreateButton(Icon(tab.icon) .. tab.name)
        Scroll(tabDesc, #tab.spells)
        for _, spell in ipairs(tab.spells) do
            if #spell.ranks == 1 then
                local entry = spell.ranks[1]
                local label = Icon(spell.icon) .. spell.name
                if entry.sub then label = label .. " |cff999999(" .. entry.sub .. ")|r" end
                local d = tabDesc:CreateButton(label, function() PlaceInto(slot, PickupRank(entry)) end)
                SpellTooltip(d, entry)
            else
                local spellDesc = tabDesc:CreateButton(Icon(spell.icon) .. spell.name)
                for _, entry in ipairs(spell.ranks) do
                    local d = spellDesc:CreateButton(Icon(entry.icon) .. (entry.sub or spell.name),
                        function() PlaceInto(slot, PickupRank(entry)) end)
                    SpellTooltip(d, entry)
                end
            end
        end
    end
end

local function AddBags(root, slot)
    local types = ReadBags()
    local bagDesc = root:CreateButton("Bag")
    if #types == 0 then
        bagDesc:CreateTitle("Bags are empty")
        return
    end
    for _, group in ipairs(types) do
        local typeDesc = bagDesc:CreateButton(group.name)
        Scroll(typeDesc, #group.items)
        for _, item in ipairs(group.items) do
            local label = Icon(item.icon) .. item.name
            if item.count > 1 then label = label .. " |cff999999x" .. item.count .. "|r" end
            local d = typeDesc:CreateButton(label, function() PlaceInto(slot, PickupItemFn(item.itemID)) end)
            d:SetTooltip(function(tooltip) tooltip:SetBagItem(item.bag, item.slot) end)
        end
    end
end

local function AddMacroList(parent, title, list, slot)
    local desc = parent:CreateButton(title)
    if #list == 0 then
        desc:CreateTitle("No macros")
        return
    end
    Scroll(desc, #list)
    for _, macro in ipairs(list) do
        local d = desc:CreateButton(Icon(macro.icon) .. macro.name, function() PlaceInto(slot, PickupMacroFn(macro.index)) end)
        d:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, macro.name)
            if macro.body and macro.body ~= "" then GameTooltip_AddNormalLine(tooltip, macro.body, true) end
        end)
    end
end

local function AddMacros(root, slot)
    local account, character = ReadMacros()
    local macrosDesc = root:CreateButton("Macros")
    AddMacroList(macrosDesc, "Account-wide", account, slot)
    AddMacroList(macrosDesc, "Character-specific", character, slot)
end

-- "Equipment set" submenu of a loadout: None or one of this character's sets (radio buttons).
local function AddEquipmentSetMenu(parent, loadout)
    local label = "Equipment set: " .. (loadout.equipmentSet or "none")
    local desc = parent:CreateButton(label)
    local function Bind(name)
        loadout.equipmentSet = name
        Print(name and ("loadout \"%s\" equips \"%s\"."):format(loadout.name, name)
            or ("loadout \"%s\" equips no set."):format(loadout.name))
    end
    desc:CreateRadio("None", function() return loadout.equipmentSet == nil end, function() Bind(nil) end)
    local sets = EquipmentSets()
    local found = false
    for _, set in ipairs(sets) do
        if set.name == loadout.equipmentSet then found = true end
        local r = desc:CreateRadio(Icon(set.icon) .. set.name,
            function() return loadout.equipmentSet == set.name end, function() Bind(set.name) end)
        r:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, set.name)
            if set.equipped then GameTooltip_AddNormalLine(tooltip, "Equipped now") end
            if (set.lost or 0) > 0 then GameTooltip_AddNormalLine(tooltip, ("%d item(s) missing"):format(set.lost)) end
        end)
    end
    if loadout.equipmentSet and not found then
        -- Bound on another character of this class; keep it selectable so it is not lost by accident.
        desc:CreateRadio(("|cff999999%s (not on this character)|r"):format(loadout.equipmentSet),
            function() return true end, function() end)
    end
    if #sets == 0 then
        desc:CreateTitle("Create sets in the character window")
    end
end

-- Loadout menu (minimap button): loadouts always cover all action bars together.
local function BuildLoadoutMenu(_, root)
    root:CreateTitle("Action bar loadouts")
    local editing = EditingLoadout()
    if CharDB.editing and not editing then StopEditing() end -- loadout gone (other character deleted it)
    if editing then
        root:CreateTitle(("|cff40ff40Editing: %s|r"):format(editing.name))
        root:CreateButton(("Save changes to \"%s\""):format(editing.name), SaveEdit)
        root:CreateButton("Cancel editing (restore previous bars)", CancelEdit)
        root:CreateDivider()
    end
    local waiting = PendingCount()
    if waiting > 0 then
        local w = root:CreateButton(("|cffffd100%d spell(s) of \"%s\" wait to be learned|r"):format(waiting, tostring(CharDB.pending.loadout)))
        w:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, "Waiting spells")
            GameTooltip_AddNormalLine(tooltip, "They go into their slot as soon as you know them (switch talents, engrave runes). A slot you fill yourself is no longer waited for.", true)
            for _, name in ipairs(PendingNames()) do GameTooltip_AddNormalLine(tooltip, name) end
        end)
        w:CreateButton("Stop waiting for them", function() CharDB.pending = nil end)
        root:CreateDivider()
    end
    root:CreateButton("New loadout from current bars...", NewLoadoutDialog)
    local list = {}
    for _, loadout in ipairs(Loadouts()) do list[#list + 1] = loadout end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    if #list > 0 then root:CreateDivider() end
    for _, loadout in ipairs(list) do
        local label = loadout.name
        if loadout == editing then label = "|cff40ff40" .. label .. " (editing)|r" end
        local l = root:CreateButton(label)
        l:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, loadout.name)
            GameTooltip_AddNormalLine(tooltip, ("%d slots, saved %s"):format(CountSlots(loadout), loadout.saved or "?"))
            GameTooltip_AddNormalLine(tooltip, "Equipment set: " .. (loadout.equipmentSet or "none"))
        end)
        l:CreateButton("Apply", function() ApplyLoadout(loadout) end)
        l:CreateButton("Edit", function() StartEdit(loadout) end)
        AddEquipmentSetMenu(l, loadout)
        l:CreateButton("Overwrite with current bars", function()
            Confirm(("Overwrite loadout \"%s\" with the current bars?"):format(loadout.name), function()
                SaveLoadout(loadout.name, loadout)
            end)
        end)
        l:CreateButton("Rename...", function() RenameDialog(loadout) end)
        l:CreateButton("|cffff6060Delete...|r", function()
            Confirm(("Delete loadout \"%s\"?"):format(loadout.name), function() DeleteLoadout(loadout) end)
        end)
    end
end

local function SlotOf(button)
    local slot = Safe(button.action)
    if (not slot or slot == 0) and button.CalculateAction then slot = Safe(button:CalculateAction()) end
    return slot
end

local function OpenMenu(button)
    if CombatBlocked() then return end
    local slot = SlotOf(button)
    if not slot or slot < 1 then return end
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(("Action slot %d"):format(slot))
        AddSpells(root, slot)
        AddBags(root, slot)
        AddMacros(root, slot)
        root:CreateDivider()
        local check = root:CreateCheckbox("Update spell rank to the latest available",
            function() return IsLatest(slot) end,
            function()
                SetLatest(slot, not IsLatest(slot))
                if IsLatest(slot) then UpgradeRanks(slot) end
            end)
        check:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, "Only this slot")
            GameTooltip_AddNormalLine(tooltip, ("Action slot %d always gets the highest rank you know of its spell, also after learning a new rank. Other slots keep their rank."):format(slot), true)
        end)
        root:CreateButton("Clear this slot", function()
            ClearSlot(slot)
            SetLatest(slot, false)
        end)
    end)
end

------------------------------------------------------------------------
-- Hooking the action buttons
------------------------------------------------------------------------

local header = CreateFrame("Frame", nil, UIParent, "SecureHandlerBaseTemplate")
local hooked = {}
-- Swallow shift + right-click in the secure click handler so the button does not also cast.
local PRE_CLICK = [[ if button == "RightButton" and IsShiftKeyDown() then return false end ]]

local function OnMouseUp(button, mouse)
    if mouse == "RightButton" and IsShiftKeyDown() then OpenMenu(button) end
end

local function HookButtons()
    if InCombatLockdown() then return false end
    local names = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {
        "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
        "MultiBarLeftButton", "MultiBarRightButton", "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
    }
    for _, prefix in ipairs(names) do
        for i = 1, NUM_ACTIONBAR_BUTTONS or 12 do
            local button = _G[prefix .. i]
            if button and not hooked[button] then
                hooked[button] = true
                SecureHandlerWrapScript(button, "OnClick", header, PRE_CLICK)
                button:HookScript("OnMouseUp", OnMouseUp)
            end
        end
    end
    return true
end

------------------------------------------------------------------------
-- Minimap button (own frame, no library): click = loadout menu, drag = move around the minimap
------------------------------------------------------------------------

local minimapButton

local function PlaceMinimapButton()
    local angle = math.rad(DB.minimap.angle or 200)
    local radius = (Minimap:GetWidth() / 2) + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OpenLoadoutMenu(owner)
    if CombatBlocked() then return end
    MenuUtil.CreateContextMenu(owner or UIParent, BuildLoadoutMenu)
end

local function CreateMinimapButton()
    local b = CreateFrame("Button", "ActionSlotPickerMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        OpenLoadoutMenu(self)
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            DB.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
            PlaceMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip_SetTitle(GameTooltip, "Action Slot Picker")
        local editing = EditingLoadout()
        if editing then
            GameTooltip_AddNormalLine(GameTooltip, ("|cff40ff40Editing loadout \"%s\"|r"):format(editing.name))
        end
        GameTooltip_AddNormalLine(GameTooltip, "Click: action bar loadouts (all bars)")
        GameTooltip_AddNormalLine(GameTooltip, "Drag: move this button")
        GameTooltip_AddNormalLine(GameTooltip, "Shift + right-click an action button: pick its spell, item or macro", true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton = b
    PlaceMinimapButton()
    b:SetShown(not DB.minimap.hide)
end

------------------------------------------------------------------------
-- Events and slash command
------------------------------------------------------------------------

local needHook = true
local ProbeSnapshot -- defined with the probe commands below; the login handler needs it
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("SPELLS_CHANGED")
pcall(frame.RegisterEvent, frame, "LEARNED_SPELL_IN_SKILL_LINE")
pcall(frame.RegisterEvent, frame, "LEARNED_SPELL_IN_TAB")

local upgradeTimer, pendingTimer
local function ScheduleUpgrade()
    if not CharDB or not next(CharDB.latest) then return end
    if upgradeTimer then upgradeTimer:Cancel() end
    upgradeTimer = C_Timer.NewTimer(1, function()
        upgradeTimer = nil
        UpgradeRanks(nil, "learned a spell")
    end)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        ActionSlotPickerDB = ActionSlotPickerDB or {}
        DB = ActionSlotPickerDB
        DB.loadouts = DB.loadouts or {}
        DB.minimap = DB.minimap or {}
        DB.probe = DB.probe or {}
        DB.probe.runs = DB.probe.runs or {}
        DB.autoRank = nil -- 0.1.0 had one account-wide switch; it is per slot now
        ActionSlotPickerCharDB = ActionSlotPickerCharDB or {}
        CharDB = ActionSlotPickerCharDB
        CharDB.latest = CharDB.latest or {}
    elseif event == "PLAYER_LOGIN" then
        CreateMinimapButton()
        if HookButtons() then needHook = false end
        if EditingLoadout() then
            Print(("still editing loadout \"%s\" - save or cancel it with the minimap button."):format(CharDB.editing.name))
        end
        if ProbeOn() then
            ProbeSnapshot("login")
            Print("probe is ON (/asp probe off to stop recording).")
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if needHook and HookButtons() then needHook = false end
        if pendingUpgrade then UpgradeRanks(nil, "after combat") end
        FillPending("after combat")
    elseif event == "SPELLS_CHANGED" then
        if CharDB and CharDB.pending then
            if pendingTimer then pendingTimer:Cancel() end
            pendingTimer = C_Timer.NewTimer(0.5, function()
                pendingTimer = nil
                FillPending("spells changed")
            end)
        end
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "LEARNED_SPELL_IN_TAB" then
        ScheduleUpgrade()
    end
end)

-- Probe commands -------------------------------------------------------

-- Current state: saved loadouts, edit mode, latest-rank slots, which button shows which slot, every filled slot.
function ProbeSnapshot(kind) -- assigns the local declared before the event handler
    local run = ProbeBegin(kind, "state")
    if not run then return end
    for class, list in pairs(DB.loadouts) do
        local names = {}
        for _, l in ipairs(list) do
            local n = 0
            for _ in pairs(l.slots or {}) do n = n + 1 end
            names[#names + 1] = ("%s(%d slots, %s, set %s)"):format(tostring(l.name), n, tostring(l.saved), tostring(l.equipmentSet))
        end
        ProbeLine("loadouts %s: %s", class, #names > 0 and table.concat(names, "; ") or "none")
    end
    local editing = CharDB.editing
    ProbeLine("editing: %s (backup %s)", tostring(editing and editing.name),
        editing and editing.backup and "present" or "none")
    local flagged = {}
    for slot in pairs(CharDB.latest) do flagged[#flagged + 1] = slot end
    table.sort(flagged)
    ProbeLine("latest-rank slots: %s", #flagged > 0 and table.concat(flagged, ",") or "none")
    ProbeLine("waiting spells (%s): %s", tostring(CharDB.pending and CharDB.pending.loadout),
        PendingCount() > 0 and table.concat(PendingNames(), ", ") or "none")
    local names = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {}
    for _, prefix in ipairs(names) do
        local map = {}
        for i = 1, NUM_ACTIONBAR_BUTTONS or 12 do
            local button = _G[prefix .. i]
            if button then
                map[#map + 1] = tostring(Safe(button.action)) .. (button:IsVisible() and "" or "h")
            end
        end
        ProbeLine("buttons %s: %s", prefix, #map > 0 and table.concat(map, " ") or "missing")
    end
    for slot = 1, MAX_SLOT do
        local text = ActionText(slot)
        if text ~= "empty" then
            ProbeLine("bar slot %d: %s text=%s", slot, text, tostring(Safe(GetActionText(slot))))
        end
    end
    ProbeEnd()
end

-- Dry run for one loadout: resolve every slot and pick it up, but never place anything.
local function ProbeCheck(name)
    local loadout = name and name ~= "" and FindLoadout(name)
    if not loadout then
        Print(("no loadout \"%s\" for this class."):format(tostring(name)))
        return
    end
    if CombatBlocked() then return end
    local run = ProbeBegin("check", loadout.name)
    if not run then return end
    local _, best, byID = ReadSpellbook()
    local same, differ = 0, 0
    for slot = 1, MAX_SLOT do
        local entry = loadout.slots[slot]
        local now = ActionText(slot)
        if entry then
            local pickup, how = PickupForEntry(entry, best, byID, IsLatest(slot) or entry.latest)
            local cursor = "not picked"
            if pickup then
                ClearCursor()
                pickup()
                cursor = CursorText()
                ClearCursor()
            end
            local match = now == (entry.t .. ":" .. tostring(entry.id)) or now:find("^" .. entry.t .. ":" .. tostring(entry.id) .. "/")
            if match then same = same + 1 else differ = differ + 1 end
            ProbeLine("slot %d: want %s | %s | cursor=%s | bars now %s | %s", slot, EntryText(entry), tostring(how), cursor, now,
                match and "SAME" or "DIFFERENT")
        elseif now ~= "empty" then
            differ = differ + 1
            ProbeLine("slot %d: not in loadout | bars now %s | DIFFERENT", slot, now)
        end
    end
    ProbeLine("summary: %d slots match the bars, %d differ", same, differ)
    ProbeEnd()
    Print(("probe check \"%s\": %d slots match the bars, %d differ. /reload writes the probe to disk."):format(loadout.name, same, differ))
end

local function ProbeCommand(rest)
    local sub, arg = rest:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    if sub == "on" then
        DB.probe.enabled = true
        ProbeSnapshot("probe on")
        Print("probe ON: every loadout step is recorded. Reproduce the problem, then /reload so it is written to disk.")
    elseif sub == "off" then
        DB.probe.enabled = nil
        Print("probe OFF (recorded runs are kept, /asp probe clear deletes them).")
    elseif sub == "clear" then
        DB.probe.runs = {}
        Print("probe runs deleted.")
    elseif sub == "bars" then
        if not ProbeOn() then Print("switch the probe on first: /asp probe on") return end
        ProbeSnapshot("bars")
        Print("probe: current bars recorded.")
    elseif sub == "check" then
        if not ProbeOn() then Print("switch the probe on first: /asp probe on") return end
        ProbeCheck(arg)
    else
        Print(("probe is %s, %d runs recorded."):format(ProbeOn() and "ON" or "OFF", #DB.probe.runs))
        Print("/asp probe on|off - record loadout steps   /asp probe bars - record the current bars")
        Print("/asp probe check <loadout> - dry run, places nothing   /asp probe clear - delete runs")
    end
end

SLASH_ACTIONSLOTPICKER1 = "/asp"
SlashCmdList.ACTIONSLOTPICKER = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "loadouts" then
        OpenLoadoutMenu()
    elseif cmd == "minimap" then
        DB.minimap.hide = not DB.minimap.hide
        minimapButton:SetShown(not DB.minimap.hide)
        Print("minimap button " .. (DB.minimap.hide and "hidden (/asp minimap shows it again)." or "shown."))
    elseif cmd == "rank" then
        local slots = {}
        for slot in pairs(CharDB.latest) do slots[#slots + 1] = slot end
        table.sort(slots)
        Print(#slots == 0 and "no slot follows the latest spell rank."
            or ("slots following the latest spell rank: " .. table.concat(slots, ", ")))
    elseif cmd == "save" and rest ~= "" then
        SaveLoadout(rest, (FindLoadout(rest)))
    elseif cmd == "load" and rest ~= "" then
        local loadout = FindLoadout(rest)
        if loadout then ApplyLoadout(loadout) else Print(("no loadout \"%s\"."):format(rest)) end
    elseif cmd == "probe" then
        ProbeCommand(rest)
    elseif cmd == "list" then
        local list = Loadouts()
        if #list == 0 then Print("no loadouts for this class yet.") end
        for _, loadout in ipairs(list) do
            Print(("%s - %d slots, saved %s"):format(loadout.name, CountSlots(loadout), loadout.saved or "?"))
        end
    else
        Print("Shift + right-click an action button to open the picker. Minimap button or /asp: loadouts.")
        Print("/asp minimap - show or hide the minimap button")
        Print("/asp probe - diagnostics for loadouts (records every step, see /asp probe)")
        Print("/asp rank - list the slots that follow the latest spell rank (switch it in the slot's menu)")
        Print("/asp save <name> | /asp load <name> | /asp list - action bar loadouts")
    end
end
