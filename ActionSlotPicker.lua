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
local function PlaceInto(slot, pickup)
    ClearCursor()
    pickup()
    if not GetCursorInfo() then return false end
    PlaceAction(slot)
    ClearCursor()
    return true
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
        if PlaceInto(slot, PickupRank(top)) then return top end
    end
end

-- onlySlot: upgrade just that slot (checkbox switched on); otherwise every slot switched on.
local function UpgradeRanks(onlySlot)
    if not next(CharDB.latest) then return end
    if InCombatLockdown() then
        pendingUpgrade = true
        return
    end
    pendingUpgrade = false
    local _, best, byID = ReadSpellbook()
    for slot in pairs(CharDB.latest) do
        if not onlySlot or slot == onlySlot then
            local top = UpgradeSlot(slot, best, byID)
            if top then
                Print(("slot %d: %s set to %s."):format(slot, top.name, top.sub or "the latest rank"))
            end
        end
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

-- Returns a pickup function for a saved slot entry, or nil if it cannot be restored.
local function PickupForEntry(entry, best, byID)
    if entry.t == "spell" then
        local known = byID[entry.id]
        local top = entry.name and best[entry.name]
        if top and (not known or (entry.latest and top.rank > known.rank)) then known = top end
        if known then return PickupRank(known) end
        if IsSpellKnown and IsSpellKnown(entry.id) then
            return function() C_Spell.PickupSpell(entry.id) end
        end
    elseif entry.t == "item" then
        return PickupItemFn(entry.id)
    elseif entry.t == "macro" then
        local index = MacroIndexByName(entry.name)
        if index then return PickupMacroFn(index) end
    elseif entry.t == "flyout" then
        local index = FindFlyoutIndex(entry.id)
        if index then return function() C_SpellBook.PickupSpellBookItem(index, BANK) end end
    elseif entry.t == "equipmentset" and C_EquipmentSet then
        local setID = C_EquipmentSet.GetEquipmentSetID(entry.id)
        if setID then return function() C_EquipmentSet.PickupEquipmentSet(setID) end end
    end
end

local function ApplyLoadout(loadout)
    if CombatBlocked() then return end
    local _, best, byID = ReadSpellbook()
    local placed, cleared, missing = 0, 0, {}
    for slot = 1, MAX_SLOT do
        local entry = loadout.slots[slot]
        local actionType = Safe(GetActionInfo(slot))
        SetLatest(slot, entry and entry.latest)
        if entry then
            local pickup = PickupForEntry(entry, best, byID)
            if pickup and PlaceInto(slot, pickup) then
                placed = placed + 1
            else
                missing[#missing + 1] = entry.name or (entry.t .. " " .. tostring(entry.id))
            end
        elseif actionType then
            ClearSlot(slot)
            cleared = cleared + 1
        end
    end
    Print(("loadout \"%s\" applied: %d placed, %d cleared."):format(loadout.name, placed, cleared))
    if #missing > 0 then
        Print("not available: " .. table.concat(missing, ", "))
    end
end

local function SaveLoadout(name, existing)
    if CombatBlocked() then return end
    local slots, count = CaptureSlots()
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
    local backup = CaptureSlots()
    if CharDB.editing then backup = CharDB.editing.backup end -- switching loadouts keeps the original bars
    ApplyLoadout(loadout)
    CharDB.editing = { name = loadout.name, backup = backup }
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
    ApplyLoadout({ name = "bars before editing", slots = editing.backup or {} })
    StopEditing()
end

local function DeleteLoadout(loadout)
    local list = Loadouts()
    for i, l in ipairs(list) do
        if l == loadout then
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
        end)
        l:CreateButton("Apply", function() ApplyLoadout(loadout) end)
        l:CreateButton("Edit", function() StartEdit(loadout) end)
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
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
pcall(frame.RegisterEvent, frame, "LEARNED_SPELL_IN_SKILL_LINE")
pcall(frame.RegisterEvent, frame, "LEARNED_SPELL_IN_TAB")

local upgradeTimer
local function ScheduleUpgrade()
    if not CharDB or not next(CharDB.latest) then return end
    if upgradeTimer then upgradeTimer:Cancel() end
    upgradeTimer = C_Timer.NewTimer(1, function()
        upgradeTimer = nil
        UpgradeRanks()
    end)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        ActionSlotPickerDB = ActionSlotPickerDB or {}
        DB = ActionSlotPickerDB
        DB.loadouts = DB.loadouts or {}
        DB.minimap = DB.minimap or {}
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
    elseif event == "PLAYER_REGEN_ENABLED" then
        if needHook and HookButtons() then needHook = false end
        if pendingUpgrade then UpgradeRanks() end
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "LEARNED_SPELL_IN_TAB" then
        ScheduleUpgrade()
    end
end)

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
    elseif cmd == "list" then
        local list = Loadouts()
        if #list == 0 then Print("no loadouts for this class yet.") end
        for _, loadout in ipairs(list) do
            Print(("%s - %d slots, saved %s"):format(loadout.name, CountSlots(loadout), loadout.saved or "?"))
        end
    else
        Print("Shift + right-click an action button to open the picker. Minimap button or /asp: loadouts.")
        Print("/asp minimap - show or hide the minimap button")
        Print("/asp rank - list the slots that follow the latest spell rank (switch it in the slot's menu)")
        Print("/asp save <name> | /asp load <name> | /asp list - action bar loadouts")
    end
end
