-- Loadout Manager: gear helpers
--   Equipment sets to and from the bank (only while the bank is open), worn pieces included.
--   Set swap at the bank: a loadout or spec switch fetches the new set, equips it and stores the old one.
--   Naked mode: armor and weapons into the bags, the same items back on later.
--   Gear sets window: every set with its pieces and where each one is (worn, bags, bank, missing).
--   Comparison window (Shift + Alt + left click on an item): its stats against the piece of every gear set,
--   with totals (Attack Power, spell power, crit) by each set's talent spec.
--   Set contents in the saved variables (LoadoutManagerCharDB.sets), for tools outside the game.
-- Menu entries sit in the minimap button's quick menu; the "Gear sets" button at the bank opens the window.
-- Items are moved the way a player does it: pick up, drop into a free slot. Out of combat only.

local ADDON, NS = ...
local Print, Safe, Icon = NS.Print, NS.Safe, NS.Icon

local BAGS = { 0, 1, 2, 3, 4 }
local bankOpen = false
local SetPieces -- defined with the set pieces below; storing a set needs it

------------------------------------------------------------------------
-- Bags and bank
------------------------------------------------------------------------

-- Bank tabs of this character (bag ids). The bank on this client is made of purchased tabs.
local function BankBags()
    local bags = {}
    if C_Bank and C_Bank.FetchPurchasedBankTabIDs and Enum.BankType then
        for _, id in ipairs(C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character) or {}) do
            bags[#bags + 1] = id
        end
    end
    return bags
end

local function ItemAt(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    local id = info and Safe(info.itemID)
    if not id then return nil end
    return { bag = bag, slot = slot, id = id, locked = Safe(info.isLocked) and true or false, link = Safe(info.hyperlink) }
end

-- Free slots of the given bags, in order. generalOnly: skip bags that take only certain items (quiver, soul bag).
local function FreeSlots(bags, generalOnly)
    local free = {}
    for _, bag in ipairs(bags) do
        local usable = true
        if generalOnly and bag ~= 0 and C_Container.GetContainerNumFreeSlots then
            local _, family = C_Container.GetContainerNumFreeSlots(bag)
            usable = (Safe(family) or 0) == 0
        end
        if usable then
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                if not C_Container.GetContainerItemInfo(bag, slot) then free[#free + 1] = { bag = bag, slot = slot } end
            end
        end
    end
    return free
end

-- item.inv: a worn piece (inventory slot), else a bag item (bag, slot).
local function Move(item, target)
    ClearCursor()
    if item.inv then
        PickupInventoryItem(item.inv)
    else
        C_Container.PickupContainerItem(item.bag, item.slot)
    end
    C_Container.PickupContainerItem(target.bag, target.slot)
    ClearCursor() -- a drop that did not work puts the item back
end

------------------------------------------------------------------------
-- Equipment sets and the bank
------------------------------------------------------------------------

-- How many pieces of each item the set still needs from elsewhere: its items minus what is worn in their slot.
local function Needed(set)
    local need, total = {}, 0
    for invSlot, id in pairs(C_EquipmentSet.GetItemIDs(set.setID) or {}) do
        id = Safe(id)
        if type(id) == "number" and id > 0 then
            total = total + 1
            if Safe(GetInventoryItemID("player", invSlot)) ~= id then need[id] = (need[id] or 0) + 1 end
        end
    end
    return need, total
end

-- Items in these bags that the set needs, at most as many of each as it needs.
local function Collect(need, bags)
    local found = {}
    for _, bag in ipairs(bags) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = ItemAt(bag, slot)
            if item and (need[item.id] or 0) > 0 then
                need[item.id] = need[item.id] - 1
                found[#found + 1] = item
            end
        end
    end
    return found
end

local function BankReady()
    if NS.CombatBlocked() then return false end
    if not bankOpen then
        Print("open the bank first.")
        return false
    end
    return true
end

-- Moves the found items into the free slots; returns moved, without room, locked.
local function MoveAll(items, free)
    local moved, noRoom, locked = 0, 0, 0
    for _, item in ipairs(items) do
        if item.locked then
            locked = locked + 1
        elseif #free == 0 then
            noRoom = noRoom + 1
        else
            Move(item, table.remove(free, 1))
            moved = moved + 1
        end
    end
    return moved, noRoom, locked
end

local function Report(set, moved, noRoom, locked, done, nothing, full, note)
    note = note or ""
    if moved == 0 and noRoom == 0 and locked == 0 then
        Print(("%s: %s%s."):format(set.name, nothing, note))
        return
    end
    local text = ("%s: %d %s"):format(set.name, moved, done)
    if noRoom > 0 then text = text .. (", %d left (%s)"):format(noRoom, full) end
    if locked > 0 then text = text .. (", %d locked - try again"):format(locked) end
    Print(text .. note .. ".")
end

-- Items of other sets that are with the character (more than half of the set worn or in the bags):
-- itemID -> name of that set. A worn piece another such set uses stays on when a set is stored.
local function NeededElsewhere(set)
    local used = {}
    for _, other in ipairs(NS.EquipmentSets()) do
        if other.setID ~= set.setID then
            local pieces, counts = SetPieces(other)
            if #pieces > 0 and (counts.worn + counts.bags) * 2 > #pieces then
                for _, piece in ipairs(pieces) do used[piece.id] = used[piece.id] or other.name end
            end
        end
    end
    return used
end

-- The worn pieces of a set that go to the bank with it: list for MoveAll, and how many stay on for which set.
local function WornToStore(set)
    local elsewhere = NeededElsewhere(set)
    local items, kept, keptFor = {}, 0, nil
    for _, piece in ipairs((SetPieces(set))) do
        if piece.where == "worn" and piece.inv then
            if elsewhere[piece.id] then
                kept, keptFor = kept + 1, elsewhere[piece.id]
            else
                items[#items + 1] = {
                    inv = piece.inv, id = piece.id,
                    locked = (IsInventoryItemLocked and IsInventoryItemLocked(piece.inv)) and true or false,
                }
            end
        end
    end
    return items, kept, keptFor
end

-- Bags and body -> bank: every piece of the set that lies in the bags or is worn. A worn piece stays on when
-- another set you carry uses it too.
local function StoreSet(set)
    if not BankReady() then return end
    local need = Needed(set)
    Collect(need, BankBags()) -- pieces already in the bank do not pull a spare copy after them
    local items = Collect(need, BAGS)
    local worn, kept, keptFor = WornToStore(set)
    for _, item in ipairs(worn) do items[#items + 1] = item end
    -- Taking gear off is not a change to save into the set: the prompt takes the new state as its baseline.
    if #worn > 0 and NS.BeginSwitchQuiet then NS.BeginSwitchQuiet() end
    local moved, noRoom, locked = MoveAll(items, FreeSlots(BankBags()))
    local note = kept > 0 and (", %d %s on (also in %s)"):format(kept, kept == 1 and "stays" or "stay", keptFor) or ""
    Report(set, moved, noRoom, locked, "stored in the bank", "nothing to store", "bank full", note)
    return moved, noRoom, locked
end

-- Bank -> bags: every piece of the set that is neither worn nor in the bags already.
local function PickupSet(set)
    if not BankReady() then return end
    local need = Needed(set)
    Collect(need, BAGS) -- pieces already in the bags are not fetched a second time
    local items = Collect(need, BankBags())
    local moved, noRoom, locked = MoveAll(items, FreeSlots(BAGS, true))
    Report(set, moved, noRoom, locked, "picked up from the bank", "nothing in the bank", "bags full")
    return moved, noRoom, locked
end

local function FindSet(name)
    for _, set in ipairs(NS.EquipmentSets()) do
        if set.name:lower() == name:lower() then return set end
    end
end

------------------------------------------------------------------------
-- Set swap through the bank on a loadout or spec switch
------------------------------------------------------------------------
-- With the bank open, the main file hands the equip step over to SwapThroughBank:
--   1. the new set's pieces come out of the bank into the bags
--   2. the set is equipped (the old pieces drop into the bags)
--   3. the old set goes into the bank
-- The server moves items one at a time, so each step waits until the step before has arrived (or gives up after
-- a few seconds and goes on).
-- No room in the bags for a piece: it is swapped 1 by 1, straight from its bank slot onto the body, and the piece
-- worn there drops into that bank slot. That needs no free slot anywhere. A full bank is no problem either: the
-- new set leaves its slots before the old one arrives. What still did not move gets a second round after step 3.
-- Account option DB.bankSwap = false switches it off.

local SWAP_POLL, SWAP_TRIES = 0.3, 20 -- wait up to 6 s for a step
local swap -- the running swap; a newer one replaces it

local function SwapEnabled()
    local db = NS.DB()
    return db ~= nil and db.bankSwap ~= false
end

-- Pieces of the set that lie in the bank (not worn, no copy in the bags) / in the bags (not worn).
local function InBank(set)
    local need = Needed(set)
    Collect(need, BAGS)
    return #Collect(need, BankBags())
end

local function InBags(set)
    return #Collect(Needed(set), BAGS)
end

local function SwapQuiet()
    if NS.BeginSwitchQuiet then NS.BeginSwitchQuiet() end -- no "save gear?" prompt for what the swap moves
end

-- 1 by 1: every piece of the set that still lies in the bank goes straight into its slot on the body; the piece
-- worn there lands in the bank slot. The game's own equipment manager equips a bank item the same way (pick up the
-- bank item, drop it on the inventory slot). Pieces on their way to the bags are locked and left alone.
local function SwapDirect(set)
    local ids = C_EquipmentSet.GetItemIDs(set.setID) or {}
    local need = Needed(set)
    Collect(need, BAGS) -- a copy in the bags is equipped by the set itself
    local banked = Collect(need, BankBags())
    local swapped = 0
    for invSlot = 1, 19 do
        local id = Safe(ids[invSlot])
        if type(id) == "number" and id > 0 and Safe(GetInventoryItemID("player", invSlot)) ~= id then
            for i, item in ipairs(banked) do
                if item.id == id and not item.locked and not (IsInventoryItemLocked and IsInventoryItemLocked(invSlot)) then
                    table.remove(banked, i)
                    ClearCursor()
                    C_Container.PickupContainerItem(item.bag, item.slot)
                    local fits = not (C_PaperDollInfo and C_PaperDollInfo.CursorCanGoInSlot)
                        or C_PaperDollInfo.CursorCanGoInSlot(invSlot)
                    if fits then
                        PickupInventoryItem(invSlot)
                        swapped = swapped + 1
                    end
                    ClearCursor()
                    break
                end
            end
        end
    end
    return swapped
end

local function SwapThroughBank(set, oldSetName, equip)
    if not bankOpen or not SwapEnabled() or InCombatLockdown() then return false end
    local token = { round = 1 }
    swap = token
    local Fetch, Equip, Store

    local function CanBank()
        return bankOpen and not InCombatLockdown()
    end

    local function Wait(arrived, nextStep)
        local tries = 0
        local function Poll()
            if swap ~= token then return end
            tries = tries + 1
            if arrived() or tries >= SWAP_TRIES then nextStep() else C_Timer.After(SWAP_POLL, Poll) end
        end
        C_Timer.After(SWAP_POLL, Poll)
    end

    local function Finish()
        if swap == token then swap = nil end
        SwapQuiet()
    end

    function Store()
        if swap ~= token then return end
        SwapQuiet()
        local old = oldSetName and oldSetName:lower() ~= set.name:lower() and FindSet(oldSetName) or nil
        if old and CanBank() and (InBags(old) > 0 or #WornToStore(old) > 0) then StoreSet(old) end
        if CanBank() and token.round < 2 and InBank(set) > 0 then
            token.round = 2 -- pieces that did not fit into the bags: once more, now that the old set is gone
            Wait(function() return old == nil or InBags(old) == 0 end, Fetch)
        else
            Finish()
        end
    end

    function Equip()
        if swap ~= token then return end
        SwapQuiet()
        equip()
        Wait(function() return InBags(set) == 0 end, Store)
    end

    function Fetch()
        if swap ~= token then return end
        SwapQuiet()
        if CanBank() and InBank(set) > 0 then
            local _, noRoom, locked = PickupSet(set)
            local left = (noRoom or 0) + (locked or 0)
            if (noRoom or 0) > 0 then
                local direct = SwapDirect(set)
                if direct > 0 then
                    left = math.max(0, left - direct)
                    Print(("%s: %d swapped 1 by 1 with the bank (bags full)."):format(set.name, direct))
                end
            end
            Wait(function() return not bankOpen or InBank(set) <= left end, Equip)
        else
            Equip()
        end
    end

    Fetch()
    return true
end

------------------------------------------------------------------------
-- Naked mode
------------------------------------------------------------------------

-- Head, shoulder, chest, waist, legs, feet, wrist, hands, main hand, off hand, ranged: what loses durability.
local NAKED_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

local function ItemGUID(location)
    if not (C_Item and C_Item.GetItemGUID and location) then return nil end
    if C_Item.DoesItemExist and not C_Item.DoesItemExist(location) then return nil end
    return Safe(C_Item.GetItemGUID(location))
end

local function WornGUID(invSlot)
    return ItemLocation and ItemGUID(ItemLocation:CreateFromEquipmentSlot(invSlot)) or nil
end

local function BagGUID(bag, slot)
    return ItemLocation and ItemGUID(ItemLocation:CreateFromBagAndSlot(bag, slot)) or nil
end

local function IsNaked()
    local db = NS.CharDB()
    return db ~= nil and db.naked ~= nil
end

local function QuietGear()
    NS.equipQuietUntil = GetTime() + 4 -- the save prompt for gear waits until the swap is through
end

-- CharDB.naked = { [invSlot] = { id, guid, link } } of what was taken off.
local function Strip()
    if NS.CombatBlocked() then return end
    local free = FreeSlots(BAGS, true)
    local taken, count, left = {}, 0, 0
    QuietGear()
    for _, invSlot in ipairs(NAKED_SLOTS) do
        local id = Safe(GetInventoryItemID("player", invSlot))
        if id then
            if #free == 0 or (IsInventoryItemLocked and IsInventoryItemLocked(invSlot)) then
                left = left + 1
            else
                local target = table.remove(free, 1)
                taken[invSlot] = { id = id, guid = WornGUID(invSlot), link = Safe(GetInventoryItemLink("player", invSlot)) }
                ClearCursor()
                PickupInventoryItem(invSlot)
                C_Container.PickupContainerItem(target.bag, target.slot)
                ClearCursor()
                count = count + 1
            end
        end
    end
    if count == 0 then
        Print(left > 0 and "naked: bags full, nothing taken off." or "naked: nothing to take off.")
        return
    end
    NS.CharDB().naked = taken
    Print(("naked: %d items in your bags%s. Again to dress."):format(count,
        left > 0 and (", %d still on (bags full)"):format(left) or ""))
end

-- The bag slot holding a taken-off item: the very same item if the client tells items apart, else the same kind.
local function FindTaken(item, used)
    local byID
    for _, bag in ipairs(BAGS) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local key = bag * 1000 + slot
            local found = not used[key] and ItemAt(bag, slot)
            if found and found.id == item.id and not found.locked then
                if item.guid and BagGUID(bag, slot) == item.guid then return found, key end
                byID = byID or found
            end
        end
    end
    if byID then return byID, byID.bag * 1000 + byID.slot end
end

local function Dress()
    if NS.CombatBlocked() then return end
    local db = NS.CharDB()
    local taken = db.naked
    if not taken then return end
    QuietGear()
    local count, missing, used = 0, {}, {}
    for _, invSlot in ipairs(NAKED_SLOTS) do
        local item = taken[invSlot]
        if item and Safe(GetInventoryItemID("player", invSlot)) ~= item.id then
            local found, key = FindTaken(item, used)
            if found then
                used[key] = true
                ClearCursor()
                C_Container.PickupContainerItem(found.bag, found.slot)
                PickupInventoryItem(invSlot)
                ClearCursor()
                count = count + 1
            else
                missing[#missing + 1] = item.link or ("item " .. item.id)
            end
        end
    end
    db.naked = nil
    Print(("dressed: %d items back on."):format(count))
    if #missing > 0 then Print("not in your bags: " .. table.concat(missing, ", ")) end
end

local function ToggleNaked()
    if IsNaked() then Dress() else Strip() end
end

------------------------------------------------------------------------
-- Menu entries (minimap quick menu and bank button)
------------------------------------------------------------------------

local function AddSetList(root, label, action)
    local sets = NS.EquipmentSets()
    local desc = root:CreateButton(bankOpen and label or ("|cff999999%s (bank closed)|r"):format(label))
    for _, set in ipairs(sets) do
        desc:CreateButton(Icon(set.icon) .. set.name, function() action(set) end)
    end
    if #sets == 0 then desc:CreateTitle("Create sets in the character window") end
    return desc
end

local function AddGearMenu(root)
    root:CreateTitle("Gear")
    root:CreateButton("Gear sets window", function() NS.ToggleGear(true) end)
    local store = AddSetList(root, "Store set in bank", StoreSet)
    store:SetTooltip(function(tooltip)
        GameTooltip_SetTitle(tooltip, "Store set in bank")
        GameTooltip_AddNormalLine(tooltip, "Set pieces in your bags and on you go into the bank. A worn piece stays on if another set you carry uses it.", true)
    end)
    local pickup = AddSetList(root, "Pick up set from bank", PickupSet)
    pickup:SetTooltip(function(tooltip)
        GameTooltip_SetTitle(tooltip, "Pick up set from bank")
        GameTooltip_AddNormalLine(tooltip, "Set pieces in the bank come into your bags.", true)
    end)
    local naked = root:CreateCheckbox("Naked mode", IsNaked, ToggleNaked)
    naked:SetTooltip(function(tooltip)
        GameTooltip_SetTitle(tooltip, "Naked mode")
        GameTooltip_AddNormalLine(tooltip, "Armor and weapons go into your bags (no durability loss). Click again to put them back on.", true)
    end)
end

------------------------------------------------------------------------
-- "Gear sets" button at the bank window
------------------------------------------------------------------------

local bankButton

-- The bank window on screen: Baganator's (one frame per view and skin) or Blizzard's.
local function BankWindow()
    for _, view in ipairs({ "Category", "Single" }) do
        for _, skin in ipairs({ "blizzard", "dark", "elvui", "gw2_ui", "ndui" }) do
            local f = _G["Baganator_" .. view .. "ViewBankViewFrame" .. skin]
            if f and f:IsVisible() then return f end
        end
    end
    if BankFrame and BankFrame:IsVisible() then return BankFrame end
end

local function PlaceBankButton()
    if not bankButton or not bankOpen then return end
    local window = BankWindow()
    bankButton:ClearAllPoints()
    if window then
        bankButton:SetPoint("BOTTOMLEFT", window, "TOPLEFT", 8, 2)
    else
        bankButton:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    bankButton:Show()
end

local function ShowBankButton()
    if not bankButton then
        bankButton = CreateFrame("Button", "LoadoutManagerBankButton", UIParent, "UIPanelButtonTemplate")
        bankButton:SetSize(96, 22)
        bankButton:SetFrameStrata("HIGH")
        bankButton:SetText("Gear sets")
        bankButton:RegisterForClicks("AnyUp")
        bankButton:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" then
                if NS.CombatBlocked() then return end
                MenuUtil.CreateContextMenu(self, function(_, root) AddGearMenu(root) end)
            else
                NS.ToggleGear()
            end
        end)
        bankButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip_SetTitle(GameTooltip, "Loadout Manager")
            GameTooltip_AddNormalLine(GameTooltip, "Click: gear sets window (store, pick up)")
            GameTooltip_AddNormalLine(GameTooltip, "Right-click: quick menu")
            GameTooltip:Show()
        end)
        bankButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    PlaceBankButton()
    C_Timer.After(0.3, PlaceBankButton) -- the bank window may come up a moment after the event
end

local ScanBank -- defined with the bank memory below

local events = CreateFrame("Frame")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:RegisterEvent("EQUIPMENT_SETS_CHANGED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_DOWN")
pcall(events.RegisterEvent, events, "GET_ITEM_INFO_RECEIVED")
for _, event in ipairs({ "TRAIT_CONFIG_UPDATED", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_LEVEL_UP" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if NS.off then return end -- the old addon is still running (see the main file)
    if event == "GLOBAL_MOUSE_DOWN" then
        if NS.OnGlobalClick then NS.OnGlobalClick(arg1) end -- Shift + Alt + left click: comparison window
        return
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if NS.RefreshCompare then NS.RefreshCompare() end -- item data the window waited for
        return
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "PLAYER_LEVEL_UP" then
        NS.StatsDirty() -- what the stats give has changed
        if NS.RefreshCompare then NS.RefreshCompare() end
        return
    end
    if event == "PLAYER_LOGOUT" then
        if NS.SaveSets then NS.SaveSets() end -- last state before the saved variables are written
        return
    end
    if NS.SaveSetsSoon then NS.SaveSetsSoon() end
    if event == "BANKFRAME_OPENED" then
        bankOpen = true
        ShowBankButton()
        ScanBank()
        C_Timer.After(0.5, ScanBank) -- the tabs may fill a moment after the event
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        if bankButton then bankButton:Hide() end
    elseif event == "BAG_UPDATE_DELAYED" and bankOpen then
        ScanBank()
    end
    if NS.RefreshGear then NS.RefreshGear() end
end)

------------------------------------------------------------------------
-- Slash: /lm naked | /lm store <set> | /lm pickup <set>
------------------------------------------------------------------------

local function GearCommand(cmd, rest)
    if cmd == "sets" or cmd == "gear" then
        NS.ToggleGear(true)
    elseif cmd == "naked" then
        ToggleNaked()
    elseif cmd == "compare" then
        if not NS.OpenCompare(rest) then
            Print("compare: Shift + Alt + left click an item you can wear, or /lm compare [item link].")
        end
    elseif cmd == "bankswap" then
        NS.DB().bankSwap = not SwapEnabled()
        Print("set swap at the bank on a loadout or spec switch: " .. (SwapEnabled() and "on." or "off."))
        if NS.RefreshGear then NS.RefreshGear() end
    elseif (cmd == "store" or cmd == "pickup") and rest ~= "" then
        local set = FindSet(rest)
        if not set then
            Print(("no equipment set \"%s\"."):format(rest))
        elseif cmd == "store" then
            StoreSet(set)
        else
            PickupSet(set)
        end
    else
        return false
    end
    return true
end

NS.AddGearMenu = AddGearMenu
NS.GearCommand = GearCommand
NS.StoreSet = StoreSet
NS.PickupSet = PickupSet
NS.ToggleNaked = ToggleNaked
NS.IsNaked = IsNaked

------------------------------------------------------------------------
-- Bank memory: the gear the bank held when it was last open (per character)
------------------------------------------------------------------------

local function IsGear(id)
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(id)
    return type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

-- CharDB.bank = { seen = "2026-11-22 14:10", items = { [itemID] = { n = pieces, link = hyperlink } } }
function ScanBank() -- assigns the local declared before the event handler
    local db = NS.CharDB()
    if not bankOpen or not db then return end
    local items = {}
    for _, bag in ipairs(BankBags()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = ItemAt(bag, slot)
            if item and IsGear(item.id) then
                local entry = items[item.id] or { n = 0 }
                entry.n = entry.n + 1
                entry.link = entry.link or item.link
                items[item.id] = entry
            end
        end
    end
    db.bank = { seen = date("%Y-%m-%d %H:%M"), items = items }
end

-- Items in the bags: itemID -> list of hyperlinks.
local function BagGear()
    local found = {}
    for _, bag in ipairs(BAGS) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = ItemAt(bag, slot)
            if item then
                found[item.id] = found[item.id] or {}
                table.insert(found[item.id], item.link or ("item:" .. item.id))
            end
        end
    end
    return found
end

------------------------------------------------------------------------
-- Where the pieces of a set are
------------------------------------------------------------------------

local SLOT_ORDER = { 1, 2, 3, 15, 5, 4, 19, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
local PAIRED = { [11] = 12, [12] = 11, [13] = 14, [14] = 13, [16] = 17, [17] = 16 }
local WHERE = {
    worn    = { text = "Worn",    r = 0.25, g = 1.00, b = 0.25, hex = "40ff40" },
    bags    = { text = "Bags",    r = 1.00, g = 1.00, b = 1.00, hex = "ffffff" },
    bank    = { text = "Bank",    r = 0.40, g = 0.73, b = 1.00, hex = "66bbff" },
    missing = { text = "Missing", r = 1.00, g = 0.25, b = 0.25, hex = "ff4040" },
}

-- pieces = { { slot, id, where, link, inv } } in slot order, counts = { worn, bags, bank, missing }.
-- inv = the inventory slot a worn piece is in. "bank" comes from the bank memory, so it also shows away from the bank.
function SetPieces(set) -- assigns the local declared at the top
    local db = NS.CharDB()
    local ids = C_EquipmentSet.GetItemIDs(set.setID) or {}
    local inBags = BagGear()
    local bank = db and db.bank and db.bank.items or {}
    local bankLeft = {}
    local pieces, counts = {}, { worn = 0, bags = 0, bank = 0, missing = 0 }
    for _, invSlot in ipairs(SLOT_ORDER) do
        local id = Safe(ids[invSlot])
        if type(id) == "number" and id > 0 then
            local piece = { slot = invSlot, id = id }
            local other = PAIRED[invSlot]
            if Safe(GetInventoryItemID("player", invSlot)) == id then
                piece.where, piece.inv, piece.link = "worn", invSlot, Safe(GetInventoryItemLink("player", invSlot))
            elseif other and Safe(ids[other]) ~= id and Safe(GetInventoryItemID("player", other)) == id then
                piece.where, piece.inv, piece.link = "worn", other, Safe(GetInventoryItemLink("player", other)) -- in the twin slot
            elseif inBags[id] and #inBags[id] > 0 then
                piece.where, piece.link = "bags", table.remove(inBags[id], 1)
            else
                local left = bankLeft[id] or (bank[id] and bank[id].n) or 0
                if left > 0 then
                    piece.where, piece.link = "bank", bank[id].link
                    bankLeft[id] = left - 1
                else
                    piece.where = "missing"
                    bankLeft[id] = 0
                end
            end
            piece.link = piece.link or ("item:" .. id)
            counts[piece.where] = counts[piece.where] + 1
            pieces[#pieces + 1] = piece
        end
    end
    return pieces, counts
end

-- One line for a set: "Worn", "In the bank (14)" or the counts per place.
local function SetSummary(counts)
    local total = counts.worn + counts.bags + counts.bank + counts.missing
    if total == 0 then return "|cff999999empty set|r" end
    if counts.worn == total then return "|cff40ff40Worn|r" end
    if counts.bank == total then return ("|cff66bbffIn the bank (%d)|r"):format(total) end
    if counts.bags == total then return ("In your bags (%d)"):format(total) end
    local parts = {}
    for _, key in ipairs({ "bank", "bags", "worn", "missing" }) do
        if counts[key] > 0 then
            parts[#parts + 1] = ("|cff%s%s %d|r"):format(WHERE[key].hex, WHERE[key].text, counts[key])
        end
    end
    return table.concat(parts, "  ")
end

------------------------------------------------------------------------
-- Gear sets window
------------------------------------------------------------------------

local GEAR_WIDTH, ROW_HEIGHT, PIECE = 540, 62, 24
local gearFrame
local gearRows = {}

local function PieceOnEnter(b)
    local piece = b.piece
    if not piece then return end
    local where = WHERE[piece.where]
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(piece.link)
    GameTooltip:AddLine(piece.where == "missing" and "Not found: not worn, not in bags or bank" or ("Now: " .. where.text),
        where.r, where.g, where.b)
    GameTooltip:Show()
end

local function PieceButton(row, i)
    local b = row.pieces[i]
    if b then return b end
    b = CreateFrame("Button", nil, row)
    b:SetSize(PIECE, PIECE)
    b:SetPoint("TOPLEFT", (i - 1) * (PIECE + 3), -26)
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b:SetScript("OnEnter", PieceOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.UpdateTooltip = PieceOnEnter -- keeps the tooltip fresh, so holding Shift brings up the comparison
    row.pieces[i] = b
    return b
end

local function RowButton(row, text, width, onClick, tip)
    local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetText(text)
    b:SetScript("OnClick", function() onClick(row.set) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip_SetTitle(GameTooltip, text)
        GameTooltip_AddNormalLine(GameTooltip, tip, true)
        if not bankOpen then GameTooltip_AddNormalLine(GameTooltip, "|cffff4040Open the bank first.|r") end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function GearRow(i)
    local row = gearRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, gearFrame)
    row:SetSize(GEAR_WIDTH - 28, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 14, -34 - (i - 1) * ROW_HEIGHT)
    row.pieces = {}
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("TOPLEFT", 0, -2)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.pickup = RowButton(row, "Pick up", 70, PickupSet, "Set pieces in the bank come into your bags.")
    row.pickup:SetPoint("TOPRIGHT", 0, -2)
    row.store = RowButton(row, "Store", 60, StoreSet, "Set pieces in your bags and on you go into the bank. A worn piece stays on if another set you carry uses it.")
    row.store:SetPoint("RIGHT", row.pickup, "LEFT", -4, 0)
    gearRows[i] = row
    return row
end

local function RefreshGear()
    local sets = NS.EquipmentSets()
    for i, set in ipairs(sets) do
        local row = GearRow(i)
        local pieces, counts = SetPieces(set)
        row.set, row.counts = set, counts
        row.icon:SetTexture(set.icon)
        row.name:SetText(set.name)
        row.status:SetText(SetSummary(counts))
        row.store:SetEnabled(bankOpen and (counts.bags > 0 or #WornToStore(set) > 0))
        row.pickup:SetEnabled(bankOpen and counts.bank > 0)
        for p, piece in ipairs(pieces) do
            local b = PieceButton(row, p)
            local where = WHERE[piece.where]
            b.piece = piece
            b.icon:SetTexture(C_Item.GetItemIconByID(piece.id) or 134400)
            b.icon:SetDesaturated(piece.where == "missing")
            b.border:SetColorTexture(where.r, where.g, where.b, piece.where == "bags" and 0.35 or 0.9)
            b:Show()
        end
        for p = #pieces + 1, #row.pieces do row.pieces[p]:Hide() end
        row:Show()
    end
    for i = #sets + 1, #gearRows do gearRows[i]:Hide() end
    gearFrame.empty:SetShown(#sets == 0)
    local db = NS.CharDB()
    gearFrame.seen:SetText(db and db.bank and ("Bank seen: " .. db.bank.seen .. (bankOpen and " (open)" or ""))
        or "|cffff4040Bank not seen yet - open it once.|r")
    gearFrame.naked:SetChecked(IsNaked())
    gearFrame.auto:SetChecked(SwapEnabled())
    gearFrame:SetHeight(34 + math.max(1, #sets) * ROW_HEIGHT + 54)
end

local function CreateGearWindow()
    gearFrame = CreateFrame("Frame", "LoadoutManagerGearFrame", UIParent, "BasicFrameTemplateWithInset")
    gearFrame:SetSize(GEAR_WIDTH, 200)
    gearFrame:SetFrameStrata("DIALOG")
    gearFrame:SetToplevel(true)
    gearFrame:SetClampedToScreen(true)
    gearFrame:SetMovable(true)
    gearFrame:EnableMouse(true)
    gearFrame:RegisterForDrag("LeftButton")
    gearFrame:SetScript("OnDragStart", gearFrame.StartMoving)
    gearFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        NS.DB().gearWindow = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    local pos = NS.DB().gearWindow
    if pos and pos.point then
        gearFrame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        gearFrame:SetPoint("CENTER", 0, 80)
    end
    if gearFrame.TitleText then gearFrame.TitleText:SetText("Gear Sets") end
    tinsert(UISpecialFrames, gearFrame:GetName())

    gearFrame.empty = gearFrame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    gearFrame.empty:SetPoint("TOPLEFT", 16, -44)
    gearFrame.empty:SetText("No equipment sets. Create them in the character window.")

    gearFrame.legend = gearFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gearFrame.legend:SetPoint("BOTTOMLEFT", 16, 30)
    gearFrame.legend:SetText("Frame color: |cff40ff40worn|r  |cffbbbbbbbags|r  |cff66bbffbank|r  |cffff4040missing|r")
    gearFrame.seen = gearFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    gearFrame.seen:SetPoint("BOTTOMLEFT", 16, 14)

    local naked = CreateFrame("CheckButton", nil, gearFrame, "UICheckButtonTemplate")
    naked:SetSize(24, 24)
    naked:SetPoint("BOTTOMRIGHT", -110, 12)
    naked.label = naked:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    naked.label:SetPoint("LEFT", naked, "RIGHT", 2, 0)
    naked.label:SetText("Naked mode")
    naked:SetScript("OnClick", function(self)
        ToggleNaked()
        self:SetChecked(IsNaked())
    end)
    naked:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip_SetTitle(GameTooltip, "Naked mode")
        GameTooltip_AddNormalLine(GameTooltip, "Armor and weapons go into your bags (no durability loss). Click again to put them back on.", true)
        GameTooltip:Show()
    end)
    naked:SetScript("OnLeave", function() GameTooltip:Hide() end)
    gearFrame.naked = naked

    local auto = CreateFrame("CheckButton", nil, gearFrame, "UICheckButtonTemplate")
    auto:SetSize(24, 24)
    auto:SetPoint("BOTTOMLEFT", naked, "TOPLEFT", 0, -2)
    auto.label = auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    auto.label:SetPoint("LEFT", auto, "RIGHT", 2, 0)
    auto.label:SetText("Swap at bank")
    auto:SetScript("OnClick", function(self)
        NS.DB().bankSwap = self:GetChecked() and true or false
    end)
    auto:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip_SetTitle(GameTooltip, "Swap sets at the bank")
        GameTooltip_AddNormalLine(GameTooltip, "With the bank open, switching the loadout or the talent spec fetches the new set from the bank, equips it and stores the old set.", true)
        GameTooltip:Show()
    end)
    auto:SetScript("OnLeave", function() GameTooltip:Hide() end)
    gearFrame.auto = auto
    gearFrame:Hide()
end

-- show: true = open, nil = toggle
function NS.ToggleGear(show)
    if not gearFrame then CreateGearWindow() end
    if show or not gearFrame:IsShown() then
        RefreshGear()
        gearFrame:Show()
    else
        gearFrame:Hide()
    end
end

function NS.RefreshGear()
    if gearFrame and gearFrame:IsShown() then RefreshGear() end
end

------------------------------------------------------------------------
-- What an item's stats give this character under a talent spec
------------------------------------------------------------------------
--   Attack Power, spell power and crit of an item are more than its own lines: Strength gives Attack Power, Agility
--   and Intellect give crit, and talents add to that ("Attack Power equal to 100% of your Intellect").
-- Nothing here is listed per class. Two sources:
--   1. The game's own formulas for your class and level (GetAttackPowerForStat, GetCritChanceFromStat, ...).
--   2. The description text of the talents learned in a spec ("Increases your Intellect by 10%",
--      "... by 100% of your Intellect"). Sentences with a condition (procs, forms, timed effects) are left out.
-- The talents of the spec you are not in are read from that spec's own talent set, the way the talent window
-- shows its second tab. What was read while a spec was active is kept in the saved variables as a fallback.
-- Buffs are not counted: they are the same whichever set you wear.
-- In a block of its own: only the NS functions at its end are used outside.

do
local STR, AGI, STA, INT, SPI = 1, 2, 3, 4, 5

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return Safe(a), Safe(b)
end

local function Num(v)
    v = Safe(v)
    return type(v) == "number" and v or nil
end

-- Talent text -> effects
--   { kind = "statPct", stat = 1..5, pct = n }               "Increases your Intellect by 10%"
--   { kind = "convert", stat = 1..5, to = target, pct = n }  "Attack Power equal to 100% of your Intellect"
--   { kind = "resPct", res = "ap" | "rap", pct = n }         "Increases your Attack Power by 10%"

local STAT_WORDS = { { "strength", STR }, { "agility", AGI }, { "stamina", STA }, { "intellect", INT }, { "spirit", SPI } }

-- Words that make a sentence situational.
local CONDITIONS = {
    "while ", "when ", "whenever", "each time", "every time", "chance", "for %d+ sec", "for %d+ min", "after ",
    "if ", "during ", "afflicting", "party", "raid", "against ", "your next", "stacks", "consumed", "nearby",
    "allies", "target", "killing", "upon ",
}

local function Clean(text)
    text = tostring(text or "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " "):gsub("\n", " ")
    text = text:gsub("&nbsp;", " "):gsub("\194\160", " ")
    text = text:lower():gsub("%s+", " ")
    text = text:gsub("of your total ", "of your ")
    return text
end

local function Sentences(text)
    local out = {}
    for part in (text .. " "):gmatch("(.-)[%.;]%s") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function IsConditional(sentence)
    for _, word in ipairs(CONDITIONS) do
        if sentence:find(word) then return true end
    end
    return false
end

local function StatsIn(fragment)
    if fragment:find("all stats") or fragment:find("total stats") or fragment:find("all attributes")
        or fragment:find("^stats") or fragment:find(" stats$") then
        return { STR, AGI, STA, INT, SPI }
    end
    local found = {}
    for _, word in ipairs(STAT_WORDS) do
        if fragment:find(word[1]) then found[#found + 1] = word[2] end
    end
    return found
end

-- Which outcome a "... by X% of your <stat>" clause feeds, from the words before "by".
local function Targets(head)
    local t = {}
    if head:find("ranged attack power") then
        t[#t + 1] = "rap"
    elseif head:find("melee attack power") then
        t[#t + 1] = "ap"
    elseif head:find("attack power") then
        t[#t + 1] = "ap"
        t[#t + 1] = "rap"
    end
    if head:find("spell damage and healing") or head:find("spell power") or head:find("damage and healing done by")
        or head:find("spell damage and spell healing") then
        t[#t + 1] = "spdmg"
        t[#t + 1] = "heal"
    else
        if head:find("spell damage") or head:find("damage done by spells") then t[#t + 1] = "spdmg" end
        if head:find("healing") then t[#t + 1] = "heal" end
    end
    return t
end

local function ParseSentence(s, effects)
    for head, pct, statText in s:gmatch("([^,]-) by [%a ]-(%d+%.?%d*)%% of your (%a+)") do
        for _, stat in ipairs(StatsIn(statText)) do
            for _, to in ipairs(Targets(head)) do
                effects[#effects + 1] = { kind = "convert", stat = stat, to = to, pct = tonumber(pct) }
            end
        end
    end
    for head, pct, statText in s:gmatch("([^,]-) equal to (%d+%.?%d*)%% of your (%a+)") do
        for _, stat in ipairs(StatsIn(statText)) do
            for _, to in ipairs(Targets(head)) do
                effects[#effects + 1] = { kind = "convert", stat = stat, to = to, pct = tonumber(pct) }
            end
        end
    end
    for pct, statText, tail in s:gmatch("(%d+%.?%d*)%% of your (%a+) as ([%a ]+)") do
        for _, stat in ipairs(StatsIn(statText)) do
            for _, to in ipairs(Targets(tail)) do
                effects[#effects + 1] = { kind = "convert", stat = stat, to = to, pct = tonumber(pct) }
            end
        end
    end
    -- Percent increases. A clause followed by " of your" was a conversion and is skipped.
    local function PercentClause(what, pct, after)
        if after:find("^ of ") then return end
        pct = tonumber(pct)
        local stats = StatsIn(what)
        if #stats > 0 then
            for _, stat in ipairs(stats) do effects[#effects + 1] = { kind = "statPct", stat = stat, pct = pct } end
        elseif what:find("ranged attack power") then
            effects[#effects + 1] = { kind = "resPct", res = "rap", pct = pct }
        elseif what:find("melee attack power") then
            effects[#effects + 1] = { kind = "resPct", res = "ap", pct = pct }
        elseif what:find("attack power") then
            effects[#effects + 1] = { kind = "resPct", res = "ap", pct = pct }
            effects[#effects + 1] = { kind = "resPct", res = "rap", pct = pct }
        end
    end
    for what, pct, after in s:gmatch("increases? your ([%a ,]-) by (%d+%.?%d*)%%(.?.?.?.?)") do
        PercentClause(what:gsub("^total ", ""), pct, after)
    end
    for what, pct, after in s:gmatch("increases? (total [%a ,]-) by (%d+%.?%d*)%%(.?.?.?.?)") do
        PercentClause(what:gsub("^total ", ""), pct, after)
    end
    for what, pct, after in s:gmatch("your ([%a ,]-) is increased by (%d+%.?%d*)%%(.?.?.?.?)") do
        PercentClause(what, pct, after)
    end
    for what, pct, after in s:gmatch("your ([%a ,]-) are increased by (%d+%.?%d*)%%(.?.?.?.?)") do
        PercentClause(what, pct, after)
    end
end

local function ParseEffects(text)
    local effects, seen, out = {}, {}, {}
    for _, sentence in ipairs(Sentences(Clean(text))) do
        if not IsConditional(sentence) then ParseSentence(sentence, effects) end
    end
    for _, e in ipairs(effects) do -- the patterns overlap: one effect once
        local key = table.concat({ e.kind, tostring(e.stat), tostring(e.to), tostring(e.res), tostring(e.pct) }, ":")
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = e
        end
    end
    return out
end

-- Talents of a spec

local function LinesText(data)
    if type(Safe(data)) ~= "table" or type(Safe(data.lines)) ~= "table" then return nil end
    local parts = {}
    for i, line in ipairs(data.lines) do
        if line.leftText == nil and line.args and TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local text = Safe(line.leftText)
        if i > 1 and type(text) == "string" and text ~= "" then parts[#parts + 1] = text end -- line 1 is the name
    end
    return table.concat(parts, ". ")
end

-- The talent set of a spec group. Second value: true when it is the set in use right now.
local function ConfigOf(group)
    local active = group == NS.ActiveSpecGroup()
    local spec = C_SpecializationInfo
    local id = spec and Num(Call(spec.GetCombatConfigIDForSpecGroup, group))
    if (not id or id <= 0) and active and C_ClassTalents then id = Num(Call(C_ClassTalents.GetActiveConfigID)) end
    if id and id > 0 then return id, active end
    return nil, active
end

-- { talents = { { name, effects } }, learned = number of talents with points } or nil when nothing can be read.
local function ReadTalents(configID)
    if not (C_Traits and configID) then return nil end
    local info = Call(C_Traits.GetConfigInfo, configID)
    if type(info) ~= "table" or type(info.treeIDs) ~= "table" then return nil end
    local out = { talents = {}, learned = 0 }
    for _, treeID in ipairs(info.treeIDs) do
        for _, nodeID in ipairs(Call(C_Traits.GetTreeNodes, treeID) or {}) do
            local node = Call(C_Traits.GetNodeInfo, configID, nodeID)
            if type(node) == "table" then
                local rank = Num(node.ranksPurchased) or 0
                if rank == 0 and (Num(node.activeRank) or 0) > 0 and (Num(node.ranksIncreased) or 0) == 0 then
                    rank = Num(node.activeRank)
                end
                local entryID = (type(node.activeEntry) == "table" and Num(node.activeEntry.entryID))
                    or (type(node.entryIDs) == "table" and Num(node.entryIDs[1]))
                if rank > 0 and entryID then
                    out.learned = out.learned + 1
                    local entry = Call(C_Traits.GetEntryInfo, configID, entryID)
                    local def = type(entry) == "table" and Num(entry.definitionID) and Call(C_Traits.GetDefinitionInfo, entry.definitionID)
                    local spellID = type(def) == "table" and (Num(def.overriddenSpellID) or Num(def.spellID)) or nil
                    local text = C_TooltipInfo and LinesText(Call(C_TooltipInfo.GetTraitEntry, entryID, rank))
                    if (not text or text == "") and spellID and C_Spell then text = Call(C_Spell.GetSpellDescription, spellID) end
                    local effects = type(text) == "string" and ParseEffects(text) or {}
                    if #effects > 0 then
                        local name = (type(def) == "table" and Safe(def.overrideName))
                            or (spellID and C_Spell and Call(C_Spell.GetSpellName, spellID)) or "?"
                        out.talents[#out.talents + 1] = { name = name, effects = effects }
                    end
                end
            end
        end
    end
    return out
end

-- The talents that count for a spec group: read now, or what was kept when that spec was last active.
local function TalentsOf(group)
    local db = NS.CharDB()
    local configID, active = ConfigOf(group)
    local read = ReadTalents(configID)
    local kept = db and db.statTalents and db.statTalents[group]
    if read and (active or read.learned > 0) then
        if active and db then
            db.statTalents = db.statTalents or {}
            db.statTalents[group] = read.talents
        end
        return read.talents
    end
    return kept or (read and read.talents) or {}
end

-- Model: what one point of each stat gives under a spec

local models, dirty = {}, true

local function Slope(fn, stat, value)
    local a, b = Num(Call(fn, stat, value)), Num(Call(fn, stat, value + 100))
    if not a or not b then return 0 end
    return (b - a) / 100
end

local function Build(group)
    local m = { group = group, per = {}, names = {}, mult = { ap = 1, rap = 1 } }
    local statMult, conv = { 1, 1, 1, 1, 1 }, { {}, {}, {}, {}, {} }
    for _, talent in ipairs(TalentsOf(group)) do
        m.names[#m.names + 1] = talent.name
        for _, e in ipairs(talent.effects) do
            if e.kind == "statPct" then
                statMult[e.stat] = statMult[e.stat] * (1 + e.pct / 100)
            elseif e.kind == "resPct" then
                m.mult[e.res] = (m.mult[e.res] or 1) * (1 + e.pct / 100)
            elseif e.kind == "convert" then
                conv[e.stat][e.to] = (conv[e.stat][e.to] or 0) + e.pct / 100
            end
        end
    end
    for stat = 1, 5 do
        local _, value = Call(UnitStat, "player", stat)
        value = Num(value) or 100 -- secret in combat: the formulas are straight lines, any point does
        local ap, rap = 0, 0
        -- The game's own formulas give Attack Power for Strength and Agility only. A value for another stat is a
        -- talent of the spec in use, and that comes from the talent text of the spec asked for instead.
        if stat == STR or stat == AGI then
            ap, rap = Slope(GetAttackPowerForStat, stat, value), Slope(GetRangedAttackPowerForStat, stat, value)
        end
        local c, mult = conv[stat], statMult[stat]
        m.per[stat] = {
            ap = (ap + (c.ap or 0)) * mult * m.mult.ap,
            rap = (rap + (c.rap or 0)) * mult * m.mult.rap,
            crit = Slope(GetCritChanceFromStat, stat, value) * 100 * mult,
            spellcrit = Slope(GetSpellCritChanceFromStat, stat, value) * 100 * mult,
            spdmg = (c.spdmg or 0) * mult,
            heal = (c.heal or 0) * mult,
        }
    end
    return m
end

-- The model of a talent spec group (default: the one in use). Rebuilt out of combat after talents changed.
local function StatModel(group)
    group = group or NS.ActiveSpecGroup()
    if dirty and not (InCombatLockdown and InCombatLockdown()) then
        models, dirty = {}, false
    end
    if not models[group] then
        local ok, m = pcall(Build, group)
        models[group] = ok and m or { group = group, per = {}, names = {}, mult = { ap = 1, rap = 1 } }
    end
    return models[group]
end

-- An item's outcomes

local STAT_KEYS = {
    "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_INTELLECT_SHORT",
    "ITEM_MOD_SPIRIT_SHORT",
}
-- Item lines that are an outcome themselves.
local DIRECT = {
    ITEM_MOD_ATTACK_POWER_SHORT = { "ap", "rap" }, ITEM_MOD_MELEE_ATTACK_POWER_SHORT = { "ap" },
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = { "rap" }, ITEM_MOD_SPELL_POWER_SHORT = { "spdmg", "heal" },
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = { "spdmg" }, ITEM_MOD_SPELL_HEALING_DONE_SHORT = { "heal" },
}

-- Hit and crit come from the game as ratings (10 for 1% hit, 14 for 1% crit on this client); shown as percent.
local RATING_INDEX = {
    hit = { melee = CR_HIT_MELEE or 6, ranged = CR_HIT_RANGED or 7, spell = CR_HIT_SPELL or 8 },
    crit = { melee = CR_CRIT_MELEE or 9, ranged = CR_CRIT_RANGED or 10, spell = CR_CRIT_SPELL or 11 },
}
local RATING_PER_PERCENT = { hit = 10, crit = 14 }

-- "hit" or "crit" and "melee", "ranged", "spell" or "all" for a stat key, nil for any other key.
local function ChanceOf(key)
    if key:find("TAKEN") or key:find("DAMAGE") or key:find("RESIL") then return nil end
    local what = (key:find("CRIT") and "crit") or (key:find("HIT") and "hit")
    if not what then return nil end
    local kind = (key:find("SPELL") and "spell") or (key:find("MELEE") and "melee") or (key:find("RANGED") and "ranged") or "all"
    return what, kind
end

local function ChancePercent(key, what, kind, value)
    if not key:find("RATING") then return value end -- already a percent
    local pct = Num(Call(GetCombatRatingBonusForCombatRatingValue, RATING_INDEX[what][kind == "all" and "melee" or kind], value))
    if pct and pct > 0 then return pct end
    return value / RATING_PER_PERCENT[what]
end

-- True for an item line that goes into an outcome row instead of a row of its own.
local function IsOutcomeKey(key)
    if DIRECT[key] then return true end
    return ChanceOf(key) == "crit"
end

-- raw = the table C_Item.GetItemStats gives. Result: { ap, rap, spdmg, heal, crit, spellcrit } under the model.
local function Outcomes(model, raw)
    local o = { ap = 0, rap = 0, spdmg = 0, heal = 0, crit = 0, spellcrit = 0 }
    for key, value in pairs(raw) do
        value = Num(value)
        if type(key) == "string" and value and value ~= 0 then
            if DIRECT[key] then
                for _, to in ipairs(DIRECT[key]) do o[to] = o[to] + value * (model.mult[to] or 1) end
            else
                local what, kind = ChanceOf(key)
                if what == "crit" then
                    local pct = ChancePercent(key, what, kind, value)
                    if kind ~= "spell" then o.crit = o.crit + pct end
                    if kind == "spell" or kind == "all" then o.spellcrit = o.spellcrit + pct end
                end
            end
        end
    end
    for stat, key in ipairs(STAT_KEYS) do
        local amount, per = Num(raw[key]), model.per[stat]
        if amount and amount ~= 0 and per then
            for to, each in pairs(per) do o[to] = o[to] + each * amount end
        end
    end
    return o
end

NS.ParseEffects = ParseEffects
NS.StatModel = StatModel
NS.StatOutcomes = Outcomes
NS.IsOutcomeKey = IsOutcomeKey
NS.ChanceOf = ChanceOf
NS.ChancePercent = ChancePercent
NS.StatsDirty = function() dirty = true end
end

------------------------------------------------------------------------
-- Comparison window: an item against the piece each gear set uses in its slot
------------------------------------------------------------------------
-- Shift + Alt + left click on an item (anywhere its tooltip is up: bags, character window, loot, chat links, the
-- gear sets window) opens a window with one column per gear set: the piece that set holds in the item's slot, its
-- stats and the difference to the clicked item. The game's own comparison tooltips are left alone.

local INV_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 }, INVTYPE_TABARD = { 19 },
}
local SLOT_NAMES = {
    [11] = "Ring 1", [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2", [16] = "Main hand", [17] = "Off hand",
}
local MAX_COLUMNS = 6

-- The equipment set of the other talent spec (via its loadout), or nil.
local function OtherSpecSet()
    local db = NS.CharDB()
    if not db or not db.specLoadouts then return nil end
    local active = NS.ActiveSpecGroup()
    for group = 1, 4 do
        local name = group ~= active and db.specLoadouts[group]
        local loadout = name and NS.FindLoadout(name)
        local set = loadout and loadout.equipmentSet and NS.FindEquipmentSet(loadout.equipmentSet)
        if set then return set end
    end
end

-- Best link for an item of the character: the worn or carried one (with its enchant), else the bank one, else plain.
-- Second value: where it is ("worn", "bags", "bank") or nil.
local function LinkFor(id, inBags)
    for invSlot = 1, 19 do
        if Safe(GetInventoryItemID("player", invSlot)) == id then
            return Safe(GetInventoryItemLink("player", invSlot)) or ("item:" .. id), "worn"
        end
    end
    if inBags[id] and inBags[id][1] then return inBags[id][1], "bags" end
    local db = NS.CharDB()
    local banked = db and db.bank and db.bank.items[id]
    if banked then return banked.link or ("item:" .. id), "bank" end
    return "item:" .. id, nil
end

-- "DPS - Spec 1": the loadouts that equip this set, with the talent spec they are bound to.
local function LoadoutsOf(setName)
    local db = NS.CharDB()
    local parts = {}
    for _, loadout in ipairs(NS.Loadouts()) do
        if loadout.equipmentSet == setName then
            local text = loadout.name
            for group = 1, 4 do
                if db and db.specLoadouts and db.specLoadouts[group] == loadout.name then
                    text = text .. " - Spec " .. group
                end
            end
            parts[#parts + 1] = text
        end
    end
    return table.concat(parts, ", ")
end

-- The talent spec group whose loadout equips this set, nil when no spec is bound to it.
local function SpecGroupOf(setName)
    local db = NS.CharDB()
    for group = 1, 4 do
        local name = db and db.specLoadouts and db.specLoadouts[group]
        local loadout = name and NS.FindLoadout(name)
        if loadout and loadout.equipmentSet == setName then return group end
    end
end

local function ItemID(link)
    if type(link) == "number" then return link end
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- One column per gear set and slot for the item: { set, loadouts, group, slotName, id, link, where }, the other talent
-- spec's set first. id = nil: that set has nothing in the slot. Second value: names of the sets that already hold
-- this very item. nil when the item cannot be worn.
local function CompareColumns(link)
    local id = ItemID(link)
    if not id then return nil end
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(id)
    local slots = equipLoc and INV_SLOTS[equipLoc]
    if not slots then return nil end
    local sets = NS.EquipmentSets() -- by name
    local first = OtherSpecSet()
    if first then
        table.sort(sets, function(a, b)
            local aFirst, bFirst = a.setID == first.setID, b.setID == first.setID
            if aFirst ~= bFirst then return aFirst end
            return a.name < b.name
        end)
    end
    local columns, uses, inBags = {}, {}, BagGear()
    for _, set in ipairs(sets) do
        local ids = C_EquipmentSet.GetItemIDs(set.setID) or {}
        local seen, usesThis = {}, false
        for _, invSlot in ipairs(slots) do
            local piece = Safe(ids[invSlot])
            if type(piece) ~= "number" or piece <= 0 then piece = nil end
            if piece == id then
                usesThis = true
            elseif not seen[piece or 0] and #columns < MAX_COLUMNS then
                seen[piece or 0] = true
                local column = { set = set.name, loadouts = LoadoutsOf(set.name), group = SpecGroupOf(set.name), id = piece }
                if #slots > 1 then column.slotName = SLOT_NAMES[invSlot] end
                if piece then column.link, column.where = LinkFor(piece, inBags) end
                columns[#columns + 1] = column
            end
        end
        if usesThis then uses[#uses + 1] = set.name end
    end
    return columns, uses
end

-- Item stats --------------------------------------------------------------

local function StatLabel(key)
    local text = _G[key]
    if type(text) == "string" and text ~= "" then return text end
    text = key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_NAME$", ""):gsub("_", " "):lower()
    return (text:gsub("^%l", string.upper))
end

-- stats[key] = { v = number, pct = true for percent values }: the item's own lines, without those that go into a
-- total (Attack Power, spell power, crit). Second value: the game's own table. nil while the game has no data
-- for the item yet.
local function StatsOf(link, id)
    local fn = C_Item and C_Item.GetItemStats
    if not fn or not link then return nil end
    local raw = fn(link)
    if type(raw) ~= "table" and id then raw = fn("item:" .. id) end
    if type(raw) ~= "table" then
        if id and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        return nil
    end
    local stats = {}
    for key, value in pairs(raw) do
        value = Safe(value)
        if type(key) == "string" and type(value) == "number" and value ~= 0 and not NS.IsOutcomeKey(key) then
            local what, kind = NS.ChanceOf(key) -- hit: a rating from the game, shown as percent
            if what then
                stats[key] = { v = NS.ChancePercent(key, what, kind, value), pct = true }
            else
                stats[key] = { v = value }
            end
        end
    end
    return stats, raw
end

local STAT_ORDER = {
    "RESISTANCE0_NAME", "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT",
    "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT",
}
-- Totals: an item's own lines plus what its stats give under a talent spec, e.g. Attack Power from
-- Strength, and from Intellect with the talent for it. A pair with the same numbers everywhere is one row.
local TOTAL_ROWS = {
    { key = "ap", label = "Attack Power" },
    { key = "rap", label = "Ranged Attack Power", ranged = true },
    { key = "spdmg", label = "Spell Damage", same = "heal", sameKey = "sp", sameLabel = "Spell Power" },
    { key = "heal", label = "Healing" },
    { key = "crit", label = "Melee Crit", pct = true, same = "spellcrit", sameKey = "crit", sameLabel = "Crit" },
    { key = "spellcrit", label = "Spell Crit", pct = true },
}
local RANGED_CLASS = { HUNTER = true, WARRIOR = true, ROGUE = true }
local EPS = 0.005

local function FmtStat(v, pct)
    local text = ("%.2f"):format(v):gsub("0+$", ""):gsub("%.$", "")
    return pct and (text .. "%") or text
end

-- The rows of the window. row = { key, label, pct, item = value or nil, cols = { [i] = { v = value or nil,
-- d = item - piece } } }; a column without data yet has loading = true and no cells.
-- Total rows (total = true) are worked out per column with the talent spec of that column's set; "item" is the
-- value under the spec in use, and a cell has own = the item's value under its spec where that differs.
local function CompareRows(link, columns)
    local id = ItemID(link)
    local own, ownRaw = StatsOf(link, id)
    own, ownRaw = own or {}, ownRaw or {}
    local perColumn, perRaw = {}, {}
    for i, column in ipairs(columns) do
        if column.id then
            perColumn[i], perRaw[i] = StatsOf(column.link, column.id)
            column.loading = perColumn[i] == nil
        else
            perColumn[i], perRaw[i] = {}, {}
        end
    end

    -- The item's own lines. Two keys with the same name (the game lists some resistances twice) are one row.
    local info = {} -- lower-case label -> { key, label, pct }
    local function ByLabel(stats)
        local out = {}
        for key, stat in pairs(stats) do
            local label = StatLabel(key)
            local name = label:lower()
            local row = info[name]
            if not row then
                row = { key = key, label = label }
                info[name] = row
            end
            if key < row.key then row.key = key end
            if label < row.label then row.label = label end
            if stat.pct then row.pct = true end
            if not out[name] or math.abs(stat.v) > math.abs(out[name]) then out[name] = stat.v end
        end
        return out
    end
    local mine, theirs = ByLabel(own), {}
    for i in ipairs(columns) do theirs[i] = perColumn[i] and ByLabel(perColumn[i]) end

    local rows, placed = {}, {}
    local function Add(name)
        local known = info[name]
        if not known or placed[name] then return end
        placed[name] = true
        local row = { key = known.key, label = known.label, pct = known.pct, item = mine[name], cols = {} }
        for i in ipairs(columns) do
            if theirs[i] then row.cols[i] = { v = theirs[i][name], d = (mine[name] or 0) - (theirs[i][name] or 0) } end
        end
        rows[#rows + 1] = row
    end
    for _, key in ipairs(STAT_ORDER) do Add(StatLabel(key):lower()) end

    -- Totals, each column with the talents of its set's spec.
    local active = NS.StatModel()
    local mineActive, mineIn, theirsIn, talents = NS.StatOutcomes(active, ownRaw), {}, {}, {}
    talents[active.group] = active.names
    for i, column in ipairs(columns) do
        if perRaw[i] then
            local model = NS.StatModel(column.group)
            talents[model.group] = model.names
            mineIn[i], theirsIn[i] = NS.StatOutcomes(model, ownRaw), NS.StatOutcomes(model, perRaw[i])
        end
    end
    local function Same(a, b)
        if math.abs(mineActive[a] - mineActive[b]) >= EPS then return false end
        for i in ipairs(columns) do
            if mineIn[i] and (math.abs(mineIn[i][a] - mineIn[i][b]) >= EPS or math.abs(theirsIn[i][a] - theirsIn[i][b]) >= EPS) then
                return false
            end
        end
        return true
    end
    local _, class = UnitClass("player")
    local skip = {}
    for _, total in ipairs(TOTAL_ROWS) do
        local key, label, rowKey = total.key, total.label, total.key
        if total.same and Same(key, total.same) then
            skip[total.same] = true
            label, rowKey = total.sameLabel, total.sameKey
        end
        local show = not skip[key] and math.abs(mineActive[key]) >= EPS
        if total.ranged and (not RANGED_CLASS[class] or Same("ap", "rap")) then skip[key] = true end
        local row = { key = rowKey, label = label, pct = total.pct, total = true, cols = {} }
        row.item = math.abs(mineActive[key]) >= EPS and mineActive[key] or nil
        for i in ipairs(columns) do
            if mineIn[i] then
                local a, b = mineIn[i][key], theirsIn[i][key]
                row.cols[i] = { v = math.abs(b) >= EPS and b or nil, d = a - b }
                if math.abs(a - mineActive[key]) >= EPS then row.cols[i].own = a end
                if math.abs(a) >= EPS or math.abs(b) >= EPS then show = true end
            end
        end
        if show and not skip[key] then rows[#rows + 1] = row end
    end

    local rest = {}
    for name in pairs(info) do
        if not placed[name] then rest[#rest + 1] = name end
    end
    table.sort(rest, function(a, b) return info[a].label < info[b].label end)
    for _, name in ipairs(rest) do Add(name) end
    return rows, talents
end

-- Window --------------------------------------------------------------------

local LABEL_W, ITEM_W, COL_W, ROW_H, HEAD_H = 150, 64, 190, 16, 74
local TOTAL_HEX = "7fd4ff" -- rows that are totals
local compareFrame, compareLink
local cells, heads = {}, {}

local function Cell(i)
    local fs = cells[i]
    if not fs then
        fs = compareFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        cells[i] = fs
    end
    fs:Show()
    return fs
end

local function Head(i)
    local h = heads[i]
    if h then return h end
    h = CreateFrame("Button", nil, compareFrame)
    h:SetSize(COL_W - 8, HEAD_H - 20)
    h.set = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h.set:SetPoint("TOPLEFT")
    h.set:SetWidth(COL_W - 8)
    h.set:SetJustifyH("LEFT")
    h.set:SetWordWrap(false)
    h.loadouts = h:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    h.loadouts:SetPoint("TOPLEFT", h.set, "BOTTOMLEFT", 0, -1)
    h.loadouts:SetWidth(COL_W - 8)
    h.loadouts:SetJustifyH("LEFT")
    h.loadouts:SetWordWrap(false)
    h.piece = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.piece:SetPoint("TOPLEFT", h.loadouts, "BOTTOMLEFT", 0, -2)
    h.piece:SetWidth(COL_W - 8)
    h.piece:SetJustifyH("LEFT")
    h.piece:SetWordWrap(false)
    h.where = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.where:SetPoint("TOPLEFT", h.piece, "BOTTOMLEFT", 0, -1)
    h:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    heads[i] = h
    return h
end

local function DiffText(d, pct)
    if math.abs(d) < 0.005 then return "|cff808080=|r" end
    return ("|cff%s%s%s|r"):format(d > 0 and "40ff40" or "ff4040", d > 0 and "+" or "-", FmtStat(math.abs(d), pct))
end

local function RefreshCompare()
    local columns, uses = CompareColumns(compareLink)
    columns, uses = columns or {}, uses or {}
    local rows, talents = CompareRows(compareLink, columns)
    compareFrame.columns, compareFrame.rows, compareFrame.uses, compareFrame.talents = columns, rows, uses, talents -- for the tests
    local id = ItemID(compareLink)
    compareFrame.icon:SetTexture(id and C_Item.GetItemIconByID(id) or 134400)
    compareFrame.item:SetText(compareLink)

    local used = 0
    local function Text(x, y, width, justify, text)
        used = used + 1
        local fs = Cell(used)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetWidth(width)
        fs:SetJustifyH(justify)
        fs:SetText(text)
        return fs
    end
    local left, top = 16, -62
    local colX = left + LABEL_W + ITEM_W + 14
    Text(left + LABEL_W, top - HEAD_H + 16, ITEM_W, "RIGHT", "|cffffd100This item|r")
    for i, column in ipairs(columns) do
        local h = Head(i)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", colX + (i - 1) * COL_W, top)
        h.link = column.link
        h.set:SetText(column.set .. (column.slotName and (" |cff999999" .. column.slotName .. "|r") or ""))
        h.loadouts:SetText(column.loadouts ~= "" and column.loadouts or "no loadout")
        h.piece:SetText(column.id and column.link or "|cff808080(empty slot)|r")
        local where = column.where and WHERE[column.where]
        h.where:SetText(column.loading and "|cff808080loading...|r"
            or (where and ("|cff%s%s|r"):format(where.hex, where.text:lower())) or (column.id and "|cffff4040not found|r") or "")
        h:Show()
    end
    for i = #columns + 1, #heads do heads[i]:Hide() end

    local y = top - HEAD_H
    local anyTotal = false
    for _, row in ipairs(rows) do
        anyTotal = anyTotal or row.total
        Text(left, y, LABEL_W, "LEFT", row.total and ("|cff" .. TOTAL_HEX .. row.label .. "|r") or row.label)
        Text(left + LABEL_W, y, ITEM_W, "RIGHT", row.item and FmtStat(row.item, row.pct) or "|cff808080-|r")
        for i in ipairs(columns) do
            local cell = row.cols[i]
            if cell then
                local x = colX + (i - 1) * COL_W
                Text(x, y, 56, "RIGHT", cell.v and FmtStat(cell.v, row.pct) or "|cff808080-|r")
                local diff = DiffText(cell.d, row.pct)
                -- this set's talents make something else of the item than the spec in use does
                if cell.own then diff = diff .. " |cff808080(this: " .. FmtStat(cell.own, row.pct) .. ")|r" end
                Text(x + 62, y, COL_W - 70, "LEFT", diff)
            end
        end
        y = y - ROW_H
    end
    if #rows == 0 then
        Text(left, y, 400, "LEFT", "|cff808080No stats to compare.|r")
        y = y - ROW_H
    end
    y = y - 6
    if #columns == 0 then
        Text(left, y, 460, "LEFT", #uses > 0 and "No other gear set has a piece for this slot." or "No gear set has a piece for this slot.")
        y = y - ROW_H
    end
    if #uses > 0 then
        Text(left, y, 460, "LEFT", "|cff66bbffAlready in: " .. table.concat(uses, ", ") .. "|r")
        y = y - ROW_H
    end
    Text(left, y, 520, "LEFT", "|cff808080Green: this item is better than that set's piece. Hover a piece for its tooltip.|r")
    y = y - ROW_H
    if anyTotal then
        Text(left, y, 520, "LEFT", "|cff" .. TOTAL_HEX .. "Blue|r|cff808080: own lines + what the stats give, by each set's talent spec.|r")
        y = y - ROW_H
        local groups = {}
        for group, names in pairs(talents) do
            if #names > 0 then groups[#groups + 1] = group end
        end
        table.sort(groups)
        for _, group in ipairs(groups) do
            local names = talents[group]
            local shown = table.concat(names, ", ", 1, math.min(#names, 4)) .. (#names > 4 and ", ..." or "")
            Text(left, y, 520, "LEFT", ("|cff808080Spec %d talents counted: %s|r"):format(group, shown))
            y = y - ROW_H
        end
    end
    for i = used + 1, #cells do cells[i]:Hide() end
    compareFrame:SetSize(math.max(540, colX + #columns * COL_W + 8), -y + 14)
end

local function CreateCompareWindow()
    compareFrame = CreateFrame("Frame", "LoadoutManagerCompareFrame", UIParent, "BasicFrameTemplateWithInset")
    compareFrame:SetSize(540, 300)
    compareFrame:SetFrameStrata("DIALOG")
    compareFrame:SetToplevel(true)
    compareFrame:SetClampedToScreen(true)
    compareFrame:SetMovable(true)
    compareFrame:EnableMouse(true)
    compareFrame:RegisterForDrag("LeftButton")
    compareFrame:SetScript("OnDragStart", compareFrame.StartMoving)
    compareFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        NS.DB().compareWindow = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    local pos = NS.DB().compareWindow
    if pos and pos.point then
        compareFrame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        compareFrame:SetPoint("CENTER", 0, 120)
    end
    if compareFrame.TitleText then compareFrame.TitleText:SetText("Gear Set Comparison") end
    tinsert(UISpecialFrames, compareFrame:GetName())
    compareFrame.icon = compareFrame:CreateTexture(nil, "ARTWORK")
    compareFrame.icon:SetSize(24, 24)
    compareFrame.icon:SetPoint("TOPLEFT", 16, -30)
    compareFrame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    compareFrame.item = compareFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    compareFrame.item:SetPoint("LEFT", compareFrame.icon, "RIGHT", 8, 0)
    compareFrame:Hide()
end

-- Opens the window for an item link. False when the item cannot be worn.
local function OpenCompare(link)
    link = Safe(link)
    if type(link) ~= "string" or not CompareColumns(link) then return false end
    if not compareFrame then CreateCompareWindow() end
    compareLink = link
    NS.StatsDirty() -- talents are read again at every opening
    RefreshCompare()
    compareFrame:Show()
    return true
end

function NS.RefreshCompare()
    if compareFrame and compareFrame:IsShown() and compareLink then RefreshCompare() end
end

-- The item the game tooltip shows right now, as a link.
local function HoveredItemLink()
    local tip = GameTooltip
    if not tip or not tip:IsShown() then return nil end
    local data = tip.GetPrimaryTooltipData and tip:GetPrimaryTooltipData()
    if type(data) == "table" then
        local itemType = Enum.TooltipDataType and Enum.TooltipDataType.Item
        if itemType ~= nil and Safe(data.type) ~= itemType then return nil end
        local link = Safe(data.hyperlink)
        if type(link) == "string" and link:find("item:", 1, true) then return link end
        local guid = Safe(data.guid)
        link = guid and C_Item.GetItemLinkByGUID and Safe(C_Item.GetItemLinkByGUID(guid))
        if type(link) == "string" and link ~= "" then return link end
        local id = Safe(data.id)
        if type(id) == "number" then return "item:" .. id end
    end
    return nil
end

-- Shift + Alt + left click, wherever the mouse is: compare the item under it.
local function OnGlobalClick(button)
    if NS.off or button ~= "LeftButton" then return end
    if not (IsShiftKeyDown() and IsAltKeyDown and IsAltKeyDown()) then return end
    local link = HoveredItemLink()
    if link then OpenCompare(link) end
end

NS.CompareColumns = CompareColumns
NS.CompareRows = CompareRows
NS.OpenCompare = OpenCompare
NS.OnGlobalClick = OnGlobalClick

------------------------------------------------------------------------
-- Set contents in the saved variables
------------------------------------------------------------------------
-- LoadoutManagerCharDB.sets = { [set name] = { icon = fileID, items = { [inventory slot] = piece } } }
--   piece = { id = itemID, name = "Item Name", link = hyperlink, where = "worn" | "bags" | "bank" | "missing" }
-- LoadoutManagerCharDB.setsSaved = "2026-11-25 14:10"
-- Written whenever sets, gear, bags or the bank change, and at logout. The client writes the file itself at
-- /reload and logout, so a tool outside the game sees the state of that moment.

local function SaveSets()
    local db = NS.CharDB()
    if not db then return end
    local before = db.sets or {}
    local sets = {}
    for _, set in ipairs(NS.EquipmentSets()) do
        local old = before[set.name] and before[set.name].items or {}
        local items = {}
        for _, piece in ipairs(SetPieces(set)) do
            local link = piece.link
            local was = old[piece.slot]
            -- A bare "item:123" means the piece is not in reach right now: keep the full link seen earlier.
            if link:find("^item:%d+$") and was and was.id == piece.id and was.link then link = was.link end
            items[piece.slot] = {
                id = piece.id,
                name = link:match("%[(.-)%]") or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(piece.id)) or nil,
                link = link,
                where = piece.where,
            }
        end
        sets[set.name] = { icon = set.icon, items = items }
    end
    db.sets = sets
    db.setsSaved = date("%Y-%m-%d %H:%M")
end

-- Several events in a row (a gear swap, looting) give one save.
local saveTimer
local function SaveSetsSoon()
    if saveTimer then return end
    saveTimer = C_Timer.NewTimer(2, function()
        saveTimer = nil
        SaveSets()
    end)
end

NS.SwapThroughBank = SwapThroughBank
NS.SaveSets = SaveSets
NS.SaveSetsSoon = SaveSetsSoon
NS.SetPieces = SetPieces
NS.SetSummary = SetSummary
