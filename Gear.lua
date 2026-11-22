-- Action Slot Picker: gear helpers
--   Equipment sets to and from the bank (only while the bank is open).
--   Naked mode: armor and weapons into the bags, the same items back on later.
--   Gear sets window: every set with its pieces and where each one is (worn, bags, bank, missing).
--   Item comparison (Shift): next to the equipped item, the piece the other talent spec's set uses in that slot.
-- Menu entries sit in the minimap button's quick menu; the "Gear sets" button at the bank opens the window.
-- Items are moved the way a player does it: pick up, drop into a free slot. Out of combat only.

local ADDON, NS = ...
local Print, Safe, Icon = NS.Print, NS.Safe, NS.Icon

local BAGS = { 0, 1, 2, 3, 4 }
local bankOpen = false

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

local function Move(item, target)
    ClearCursor()
    C_Container.PickupContainerItem(item.bag, item.slot)
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

local function Report(set, moved, noRoom, locked, done, nothing, full)
    if moved == 0 and noRoom == 0 and locked == 0 then
        Print(("%s: %s"):format(set.name, nothing))
        return
    end
    local text = ("%s: %d %s"):format(set.name, moved, done)
    if noRoom > 0 then text = text .. (", %d left (%s)"):format(noRoom, full) end
    if locked > 0 then text = text .. (", %d locked - try again"):format(locked) end
    Print(text .. ".")
end

-- Bags -> bank: every piece of the set that lies in the bags. Worn pieces stay on.
local function StoreSet(set)
    if not BankReady() then return end
    local need = Needed(set)
    Collect(need, BankBags()) -- pieces already in the bank do not pull a spare copy after them
    local items = Collect(need, BAGS)
    local moved, noRoom, locked = MoveAll(items, FreeSlots(BankBags()))
    Report(set, moved, noRoom, locked, "stored in the bank", "nothing in your bags.", "bank full")
end

-- Bank -> bags: every piece of the set that is neither worn nor in the bags already.
local function PickupSet(set)
    if not BankReady() then return end
    local need = Needed(set)
    Collect(need, BAGS) -- pieces already in the bags are not fetched a second time
    local items = Collect(need, BankBags())
    local moved, noRoom, locked = MoveAll(items, FreeSlots(BAGS, true))
    Report(set, moved, noRoom, locked, "picked up from the bank", "nothing in the bank.", "bags full")
end

local function FindSet(name)
    for _, set in ipairs(NS.EquipmentSets()) do
        if set.name:lower() == name:lower() then return set end
    end
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
        GameTooltip_AddNormalLine(tooltip, "Set pieces in your bags go into the bank. Worn pieces stay on.", true)
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
        bankButton = CreateFrame("Button", "ActionSlotPickerBankButton", UIParent, "UIPanelButtonTemplate")
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
            GameTooltip_SetTitle(GameTooltip, "Action Slot Picker")
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
events:SetScript("OnEvent", function(_, event)
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
-- Slash: /asp naked | /asp store <set> | /asp pickup <set>
------------------------------------------------------------------------

local function GearCommand(cmd, rest)
    if cmd == "sets" or cmd == "gear" then
        NS.ToggleGear(true)
    elseif cmd == "naked" then
        ToggleNaked()
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

-- pieces = { { slot, id, where, link } } in slot order, counts = { worn, bags, bank, missing }.
-- "bank" comes from the bank memory, so it also shows away from the bank.
local function SetPieces(set)
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
                piece.where, piece.link = "worn", Safe(GetInventoryItemLink("player", invSlot))
            elseif other and Safe(ids[other]) ~= id and Safe(GetInventoryItemID("player", other)) == id then
                piece.where, piece.link = "worn", Safe(GetInventoryItemLink("player", other)) -- in the twin slot
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
    row.store = RowButton(row, "Store", 60, StoreSet, "Set pieces in your bags go into the bank. Worn pieces stay on.")
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
        row.store:SetEnabled(bankOpen and counts.bags > 0)
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
    gearFrame:SetHeight(34 + math.max(1, #sets) * ROW_HEIGHT + 54)
end

local function CreateGearWindow()
    gearFrame = CreateFrame("Frame", "ActionSlotPickerGearFrame", UIParent, "BasicFrameTemplateWithInset")
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
-- Item comparison: the other talent spec's piece next to the equipped one
------------------------------------------------------------------------
-- The game shows its comparison (Shift, or "always compare") through TooltipComparisonManager. A hook after it
-- adds up to two tooltips of our own with the piece the other spec's equipment set has in the same slot. The other
-- spec's set is the one bound to the loadout that is bound to the other spec.

local INV_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 }, INVTYPE_TABARD = { 19 },
}

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
local function LinkFor(id, inBags)
    for invSlot = 1, 19 do
        if Safe(GetInventoryItemID("player", invSlot)) == id then
            return Safe(GetInventoryItemLink("player", invSlot)) or ("item:" .. id)
        end
    end
    if inBags[id] and inBags[id][1] then return inBags[id][1] end
    local db = NS.CharDB()
    local banked = db and db.bank and db.bank.items[id]
    return banked and banked.link or ("item:" .. id)
end

-- The other spec pieces for the slot(s) the hovered item goes into: { { id, slot, link, set } }, at most two.
-- Left out: the hovered item itself and what is worn in those slots (the game comparison shows that already).
local function OtherSpecItems(hoverID)
    local list = {}
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(hoverID)
    local slots = equipLoc and INV_SLOTS[equipLoc]
    local set = slots and OtherSpecSet()
    if not set then return list end
    local ids = C_EquipmentSet.GetItemIDs(set.setID) or {}
    local worn, seen, inBags = {}, {}, nil
    for _, invSlot in ipairs(slots) do
        local id = Safe(GetInventoryItemID("player", invSlot))
        if id then worn[id] = true end
    end
    for _, invSlot in ipairs(slots) do
        local id = Safe(ids[invSlot])
        if type(id) == "number" and id > 0 and id ~= hoverID and not worn[id] and not seen[id] then
            seen[id] = true
            inBags = inBags or BagGear()
            list[#list + 1] = { id = id, slot = invSlot, link = LinkFor(id, inBags), set = set.name }
        end
    end
    return list
end

local compareTips = {}
local compareOwner

local function HideCompare()
    compareOwner = nil
    for _, tip in ipairs(compareTips) do
        tip.aspLink = nil
        tip:Hide()
    end
end

local function ComparisonWanted(tooltip)
    for _, shopping in ipairs(tooltip.shoppingTooltips or {}) do
        if shopping:IsShown() then return true end
    end
    return (IsModifiedClick and IsModifiedClick("COMPAREITEMS")) or (GetCVarBool and GetCVarBool("alwaysCompareItems")) or false
end

local function CompareTip(i)
    local tip = compareTips[i]
    if tip then return tip end
    tip = CreateFrame("GameTooltip", "ActionSlotPickerCompareTooltip" .. i, UIParent, "ShoppingTooltipTemplate")
    tip:SetFrameStrata("TOOLTIP")
    tip:SetClampedToScreen(true)
    local waited = 0
    tip:SetScript("OnUpdate", function(_, elapsed) -- gone as soon as the game comparison is
        waited = waited + (elapsed or 0)
        if waited < 0.1 then return end
        waited = 0
        if not compareOwner or not compareOwner:IsShown() or not ComparisonWanted(compareOwner) then HideCompare() end
    end)
    compareTips[i] = tip
    return tip
end

local function FillCompareTip(tip, owner, item)
    local header = "Other spec: " .. item.set
    tip:SetOwner(owner, "ANCHOR_NONE")
    tip:ClearAllPoints()
    local data = tip.CompareHeader and tip.ProcessInfo and C_TooltipInfo and C_TooltipInfo.GetHyperlink
        and C_TooltipInfo.GetHyperlink(item.link)
    if data then
        -- the way the game fills its own comparison tooltips: header label, then the item appended
        tip:ClearLines()
        tip.CompareHeader:Show()
        tip.CompareHeader.Label:SetText(header)
        tip.CompareHeader:SetWidth(tip.CompareHeader.Label:GetWidth() + 30)
        tip:ProcessInfo({ tooltipData = data, append = true })
    else
        tip:SetHyperlink(item.link)
        tip:AddLine(header, 0.4, 0.73, 1)
    end
    tip.aspLink, tip.aspHeader = item.link, header
    tip:Show()
end

-- Next to the outermost tooltip of the group (item tooltip + the game comparison tooltips), away from the item
-- tooltip; on the other side when there is no room.
local function PlaceCompareTips(tooltip, shown)
    local left, right, leftFrame, rightFrame
    local group = { tooltip }
    for _, shopping in ipairs(tooltip.shoppingTooltips or {}) do
        if shopping:IsShown() then group[#group + 1] = shopping end
    end
    for _, f in ipairs(group) do
        local l, r = Safe(f:GetLeft()), Safe(f:GetRight())
        if l and r then
            if not left or l < left then left, leftFrame = l, f end
            if not right or r > right then right, rightFrame = r, f end
        end
    end
    if not left then return false end -- positions unknown (secret in combat)
    local width = 0
    for _, tip in ipairs(shown) do width = width + (Safe(tip:GetWidth()) or 0) end
    local roomRight = (GetScreenWidth() or 0) - right
    local side
    if leftFrame ~= tooltip and rightFrame == tooltip then
        side = "left"
    elseif rightFrame ~= tooltip and leftFrame == tooltip then
        side = "right"
    else
        side = roomRight >= left and "right" or "left"
    end
    if side == "left" and left < width and roomRight >= width then
        side = "right"
    elseif side == "right" and roomRight < width and left >= width then
        side = "left"
    end
    local anchor = side == "left" and leftFrame or rightFrame
    for _, tip in ipairs(shown) do
        tip:ClearAllPoints()
        if side == "left" then
            tip:SetPoint("TOPRIGHT", anchor, "TOPLEFT")
        else
            tip:SetPoint("TOPLEFT", anchor, "TOPRIGHT")
        end
        anchor = tip
    end
    tooltip.aspCompareSide = side
    return true
end

local function OnCompareItem(_, comparisonItem, tooltip)
    if not comparisonItem or not tooltip or not tooltip.GetPrimaryTooltipData then
        HideCompare()
        return
    end
    local data = tooltip:GetPrimaryTooltipData()
    local id = data and Safe(data.id)
    local items = type(id) == "number" and OtherSpecItems(id) or {}
    if #items == 0 then
        HideCompare()
        return
    end
    compareOwner = tooltip
    local shown = {}
    for i, item in ipairs(items) do
        local tip = CompareTip(i)
        if tip.aspLink ~= item.link or not tip:IsShown() then FillCompareTip(tip, tooltip, item) end
        shown[i] = tip
    end
    for i = #items + 1, #compareTips do
        compareTips[i].aspLink = nil
        compareTips[i]:Hide()
    end
    if not PlaceCompareTips(tooltip, shown) then HideCompare() end
end

if TooltipComparisonManager and TooltipComparisonManager.CompareItem and hooksecurefunc then
    hooksecurefunc(TooltipComparisonManager, "CompareItem", OnCompareItem)
    hooksecurefunc(TooltipComparisonManager, "Clear", function(_, tooltip)
        if not tooltip or tooltip == compareOwner then HideCompare() end
    end)
end

NS.SetPieces = SetPieces
NS.SetSummary = SetSummary
NS.OtherSpecItems = OtherSpecItems
NS.OnCompareItem = OnCompareItem
