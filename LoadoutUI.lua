-- Action Slot Picker: loadout window (/asp or a click on the minimap button).
-- Left: the class's loadouts. Right: buttons for the selected loadout and its slots, bar by bar.
-- Click a slot to pick its spell, item or macro (same menu as on the bars) or set its rank option.
-- Drop a spell, item or macro from the cursor onto a slot to put it there. Slot changes only touch the saved loadout.

local _, NS = ...

local WIDTH, HEIGHT = 760, 500
local LIST_WIDTH = 180
local ICON, GAP = 30, 3
local ROW_LABEL = 64
local EMPTY_ICON = "Interface\\Buttons\\UI-EmptySlot-Disabled"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Rows in the order of the Blizzard bars. extra rows show only with "All slots" or when they hold something.
local ROWS = {
    { label = "Bar 1", first = 1 },
    { label = "Bar 2", first = 61 },
    { label = "Bar 3", first = 49 },
    { label = "Bar 4", first = 25 },
    { label = "Bar 5", first = 37 },
    { label = "Bar 6", first = 145 },
    { label = "Bar 7", first = 157 },
    { label = "Bar 8", first = 169 },
    { label = "Page 2", first = 13, extra = true },
    { label = "Stance 1", first = 73, extra = true },
    { label = "Stance 2", first = 85, extra = true },
    { label = "Stance 3", first = 97, extra = true },
    { label = "Stance 4", first = 109, extra = true },
    { label = "Slots 121", first = 121, extra = true },
    { label = "Totems", first = 133, extra = true },
}

local frame, listChild, gridChild
local listButtons, rowFrames = {}, {}
local selected -- the loadout table (kept across renames)
local showAll = false

local function Refresh() end -- assigned below

local function SortedLoadouts()
    local list = {}
    for _, loadout in ipairs(NS.Loadouts()) do list[#list + 1] = loadout end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function Selected()
    for _, loadout in ipairs(NS.Loadouts()) do
        if loadout == selected then return loadout end
    end
    selected = NS.EditingLoadout() or SortedLoadouts()[1]
    return selected
end

local function PendingEntry(loadout, slot)
    local pending = NS.CharDB().pending
    return pending and pending.loadout == loadout.name and pending.slots[slot] or nil
end

------------------------------------------------------------------------
-- Slot icons
------------------------------------------------------------------------

-- Spellbook read once per refresh: icon and "known" of each saved entry.
local book

local function MacroIcon(name)
    local index = NS.MacroIndexByName(name)
    if not index then return nil end
    local _, icon = GetMacroInfo(index)
    return icon
end

local function FlyoutIcon(id)
    for _, tab in ipairs(book.tabs) do
        for _, spell in ipairs(tab.spells) do
            for _, entry in ipairs(spell.ranks) do
                if entry.flyout == id then return entry.icon, true end
            end
        end
    end
end

-- Returns icon, known (false = this character cannot place it right now).
local function EntryIcon(entry)
    if entry.t == "spell" then
        local known = book.byID[entry.id] or (entry.name and book.best[entry.name])
        local icon = (known and known.icon) or (C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(entry.id))
        return icon or UNKNOWN_ICON, known ~= nil
    elseif entry.t == "item" then
        local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(entry.id)
        local count = C_Item.GetItemCount and C_Item.GetItemCount(entry.id) or 1
        return icon or UNKNOWN_ICON, count > 0
    elseif entry.t == "macro" then
        local icon = MacroIcon(entry.name)
        return icon or UNKNOWN_ICON, icon ~= nil
    elseif entry.t == "flyout" then
        local icon, known = FlyoutIcon(entry.id)
        return icon or UNKNOWN_ICON, known == true
    elseif entry.t == "equipmentset" and C_EquipmentSet then
        local setID = C_EquipmentSet.GetEquipmentSetID(entry.id)
        local icon = setID and select(2, C_EquipmentSet.GetEquipmentSetInfo(setID))
        return icon or UNKNOWN_ICON, setID ~= nil
    end
    return UNKNOWN_ICON, false
end

local RANK_MARK = { [0] = "L", [1] = "L-1", [2] = "L-2" }

------------------------------------------------------------------------
-- Slot buttons
------------------------------------------------------------------------

-- What the cursor holds, as a loadout action (nil if it cannot go into a loadout).
local function CursorAction()
    local kind, a, b, c = GetCursorInfo()
    kind, a, b, c = NS.Safe(kind), NS.Safe(a), NS.Safe(b), NS.Safe(c)
    if kind == "spell" then
        local spellID = c or a
        local _, _, byID = NS.ReadSpellbook()
        local known = spellID and byID[spellID]
        local name = (known and known.name) or (spellID and C_Spell.GetSpellName(spellID))
        if spellID and name then
            return { t = "spell", id = spellID, name = name, rank = known and known.rank or nil }
        end
    elseif kind == "item" and a then
        return { t = "item", id = a, name = NS.ItemName(a, b) }
    elseif kind == "macro" and a then
        local name = GetMacroInfo(a)
        if name then return { t = "macro", id = a, name = name } end
    elseif kind == "flyout" and a then
        return { t = "flyout", id = a, name = (GetFlyoutInfo and GetFlyoutInfo(a)) or ("Flyout " .. a) }
    end
end

local function DropOnSlot(button)
    local loadout = Selected()
    if not loadout or not GetCursorInfo() then return false end
    local action = CursorAction()
    ClearCursor()
    if not action then
        NS.Print("only spells, items and macros can go into a loadout.")
        return true
    end
    NS.LoadoutTarget(loadout, button.slot).pick(action)
    return true
end

local function SlotOnClick(button)
    if DropOnSlot(button) then return end
    local loadout = Selected()
    if not loadout then return end
    MenuUtil.CreateContextMenu(button, function(_, root)
        NS.BuildSlotMenu(root, NS.LoadoutTarget(loadout, button.slot),
            ("Slot %d of \"%s\""):format(button.slot, loadout.name))
    end)
end

local function SlotOnEnter(button)
    local loadout = Selected()
    if not loadout then return end
    local entry = loadout.slots and loadout.slots[button.slot]
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip_SetTitle(GameTooltip, entry and tostring(entry.name or entry.id) or "Empty")
    local line = ("Slot %d"):format(button.slot)
    if entry then
        line = line .. " - " .. entry.t
        if entry.t == "spell" and entry.rank and entry.rank > 0 then line = line .. (", saved rank %d"):format(entry.rank) end
    end
    GameTooltip_AddNormalLine(GameTooltip, line)
    if entry and entry.t == "spell" then
        GameTooltip_AddNormalLine(GameTooltip, "Spell rank: " .. NS.RankOptionText(NS.LatestOffset(entry.latest)))
    end
    if PendingEntry(loadout, button.slot) then
        GameTooltip_AddColoredLine(GameTooltip, "Waits to be learned", NORMAL_FONT_COLOR)
    elseif entry and button.unknown then
        GameTooltip_AddColoredLine(GameTooltip, "Not available on this character right now", RED_FONT_COLOR)
    end
    GameTooltip_AddInstructionLine(GameTooltip, "Click: pick, rank, clear. Drop a spell, item or macro here.")
    GameTooltip:Show()
end

local function CreateSlotButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ICON, ICON)
    b:RegisterForClicks("AnyUp")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.mark = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.mark:SetPoint("BOTTOMRIGHT", -1, 1)
    b.number = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    b.number:SetPoint("TOPLEFT", 2, -2)
    b:SetScript("OnClick", SlotOnClick)
    b:SetScript("OnReceiveDrag", DropOnSlot)
    b:SetScript("OnEnter", SlotOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function UpdateSlot(b, loadout)
    local entry = loadout.slots and loadout.slots[b.slot]
    b.unknown = nil
    if not entry then
        b.icon:SetTexture(EMPTY_ICON)
        b.icon:SetTexCoord(0, 1, 0, 1)
        b.icon:SetDesaturated(false)
        b.icon:SetVertexColor(1, 1, 1)
        b.mark:SetText("")
        b.number:SetText(b.index)
        return
    end
    local icon, known = EntryIcon(entry)
    local waiting = PendingEntry(loadout, b.slot) and true or false
    b.unknown = not known
    b.icon:SetTexture(icon)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.icon:SetDesaturated(waiting or not known)
    if waiting then
        b.icon:SetVertexColor(1, 0.82, 0)
    elseif not known then
        b.icon:SetVertexColor(1, 0.4, 0.4)
    else
        b.icon:SetVertexColor(1, 1, 1)
    end
    local offset = entry.t == "spell" and NS.LatestOffset(entry.latest)
    b.mark:SetText(offset and RANK_MARK[offset] or "")
    b.number:SetText("")
end

------------------------------------------------------------------------
-- Loadout list
------------------------------------------------------------------------

local function ListButton(i)
    local b = listButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, listChild)
    b:SetSize(LIST_WIDTH - 8, 20)
    b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 21)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.selected = b:CreateTexture(nil, "BACKGROUND")
    b.selected:SetAllPoints()
    b.selected:SetColorTexture(0.2, 0.5, 1, 0.3)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetJustifyH("LEFT")
    b:SetScript("OnClick", function(self)
        selected = self.loadout
        Refresh()
    end)
    b:SetScript("OnDoubleClick", function(self)
        if self.loadout then NS.ApplyLoadout(self.loadout) end
    end)
    listButtons[i] = b
    return b
end

local function RefreshList(selected)
    local list = SortedLoadouts()
    local editing = NS.EditingLoadout()
    local active = NS.ActiveLoadout()
    for i, loadout in ipairs(list) do
        local b = ListButton(i)
        b.loadout = loadout
        local label = loadout.name
        if loadout == editing then
            label = "|cff40ff40" .. label .. " (editing)|r"
        elseif loadout == active then
            label = label .. " |cff66bbff(active)|r"
        end
        b.text:SetText(label)
        b.selected:SetShown(loadout == selected)
        b:Show()
    end
    for i = #list + 1, #listButtons do listButtons[i]:Hide() end
    listChild:SetHeight(math.max(1, #list * 21 + 8))
    frame.emptyList:SetShown(#list == 0)
end

------------------------------------------------------------------------
-- Slot grid
------------------------------------------------------------------------

local function RowFrame(i)
    local row = rowFrames[i]
    if row then return row end
    row = CreateFrame("Frame", nil, gridChild)
    row:SetSize(ROW_LABEL + 12 * (ICON + GAP), ICON)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetWidth(ROW_LABEL - 4)
    row.label:SetJustifyH("LEFT")
    row.buttons = {}
    for n = 1, 12 do
        local b = CreateSlotButton(row)
        b:SetPoint("LEFT", ROW_LABEL + (n - 1) * (ICON + GAP), 0)
        b.index = n
        row.buttons[n] = b
    end
    rowFrames[i] = row
    return row
end

local function RowUsed(loadout, first)
    for slot = first, first + 11 do
        if loadout.slots and loadout.slots[slot] then return true end
    end
    return false
end

local function RefreshGrid(loadout)
    local shown = 0
    for i, def in ipairs(ROWS) do
        local row = RowFrame(i)
        if def.extra and not showAll and not RowUsed(loadout, def.first) then
            row:Hide()
        else
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -shown * (ICON + GAP))
            row.label:SetText(def.label)
            for n, b in ipairs(row.buttons) do
                b.slot = def.first + n - 1
                UpdateSlot(b, loadout)
            end
            row:Show()
            shown = shown + 1
        end
    end
    gridChild:SetHeight(math.max(1, shown * (ICON + GAP)))
end

------------------------------------------------------------------------
-- Details of the selected loadout
------------------------------------------------------------------------

local function CountUnknown(loadout)
    local n = 0
    for _, entry in pairs(loadout.slots or {}) do
        local _, known = EntryIcon(entry)
        if not known then n = n + 1 end
    end
    return n
end

local function RefreshDetails(loadout)
    local d = frame.details
    local editing = NS.EditingLoadout()
    d:SetShown(loadout ~= nil)
    frame.noSelection:SetShown(loadout == nil)
    if not loadout then return end
    d.name:SetText(loadout.name)
    local info = ("%d slots - saved %s"):format(NS.CountSlots(loadout), loadout.saved or "?")
    local unknown = CountUnknown(loadout)
    if unknown > 0 then info = info .. (" - |cffff6060%d not available|r"):format(unknown) end
    d.info:SetText(info)
    d.setButton:SetText("Equipment set: " .. (loadout.equipmentSet or "none"))
    d.specButton:SetText("Spec: " .. NS.SpecText(NS.SpecOf(loadout)))

    local isEditing = editing == loadout
    d.edit:SetShown(not isEditing)
    d.saveEdit:SetShown(isEditing)
    d.cancelEdit:SetShown(isEditing)

    local notes = {}
    if isEditing then
        notes[#notes + 1] = "|cff40ff40On the bars for editing: change the bars, then Save edit or Cancel edit.|r"
    elseif editing then
        notes[#notes + 1] = ("|cff40ff40Editing \"%s\" on the bars.|r"):format(editing.name)
    elseif NS.ActiveLoadout() == loadout then
        notes[#notes + 1] = "|cff66bbffActive: changes to your bars or gear ask to be saved here.|r"
    end
    local pending = NS.CharDB().pending
    if pending and pending.loadout == loadout.name then
        notes[#notes + 1] = ("|cffffd100%d spell(s) wait to be learned (yellow).|r"):format(NS.PendingCount())
    end
    d.note:SetText(table.concat(notes, "  "))
    d.stopWaiting:SetShown(pending ~= nil and pending.loadout == loadout.name)
end

function Refresh()
    if not frame or not frame:IsShown() then return end
    if NS.lastSaved then
        selected = NS.lastSaved
        NS.lastSaved = nil
    end
    local tabs, best, byID = NS.ReadSpellbook()
    book = { tabs = tabs, best = best, byID = byID }
    local loadout = Selected()
    RefreshList(loadout)
    RefreshDetails(loadout)
    if loadout then RefreshGrid(loadout) end
    gridChild:GetParent():SetShown(loadout ~= nil)
    frame.showAll:SetShown(loadout ~= nil)
    book = nil
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------

local function Button(parent, text, width, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    if tooltip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip_SetTitle(GameTooltip, text)
            GameTooltip_AddNormalLine(GameTooltip, tooltip, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

local function WithSelected(fn)
    return function()
        local loadout = Selected()
        if loadout then fn(loadout) end
    end
end

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    NS.DB().window = { point = point, relPoint = relPoint, x = x, y = y }
end

local function CreateWindow()
    frame = CreateFrame("Frame", "ActionSlotPickerLoadoutFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    local pos = NS.DB().window
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER")
    end
    if frame.TitleText then frame.TitleText:SetText("Action Bar Loadouts") end
    tinsert(UISpecialFrames, frame:GetName())
    frame:Hide()

    -- Left: loadout list
    local listScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 12, -32)
    listScroll:SetSize(LIST_WIDTH, HEIGHT - 132)
    listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(LIST_WIDTH, 1)
    listScroll:SetScrollChild(listChild)
    frame.emptyList = listChild:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.emptyList:SetPoint("TOPLEFT", 6, -8)
    frame.emptyList:SetWidth(LIST_WIDTH - 12)
    frame.emptyList:SetJustifyH("LEFT")
    frame.emptyList:SetText("No loadouts for this class yet.")

    local new = Button(frame, "New from bars", LIST_WIDTH, function() NS.NewLoadoutDialog() end,
        "Saves all your action bars as a new loadout.")
    new:SetPoint("BOTTOMLEFT", 12, 12)

    -- Ask to save changes of the active loadout (account-wide settings)
    local function AskBox(key, text, tip, anchor)
        local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        box:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", -2, 2)
        box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
        box.label:SetText(text)
        box:SetChecked(NS.DB()[key] ~= false)
        box:SetScript("OnClick", function(self)
            if self:GetChecked() then
                NS.DB()[key] = nil
                if key == "askBars" then NS.CheckBars() else NS.CheckGear() end
            else
                NS.DB()[key] = false
            end
        end)
        box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip_SetTitle(GameTooltip, text)
            GameTooltip_AddNormalLine(GameTooltip, tip, true)
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return box
    end
    frame.askGear = AskBox("askGear", "Ask to save gear changes",
        "Gear changed while the active loadout has an equipment set: ask to save it into that set.", new)
    frame.askBars = AskBox("askBars", "Ask to save bar changes",
        "Action bars changed after applying or saving a loadout: ask to save them into it.", frame.askGear)

    -- Right: selected loadout
    local left = 12 + LIST_WIDTH + 30
    local d = CreateFrame("Frame", nil, frame)
    d:SetPoint("TOPLEFT", left, -30)
    d:SetPoint("BOTTOMRIGHT", -12, 12)
    frame.details = d

    frame.noSelection = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.noSelection:SetPoint("CENTER", d, "CENTER")
    frame.noSelection:SetText("Save your bars with \"New from bars\".")

    d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    -- Drag this onto an action bar: a macro that applies the loadout
    d.macro = CreateFrame("Button", nil, d)
    d.macro:SetSize(36, 36)
    d.macro:SetPoint("TOPLEFT", 0, -2)
    d.macro.icon = d.macro:CreateTexture(nil, "ARTWORK")
    d.macro.icon:SetAllPoints()
    d.macro.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    d.macro:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    d.macro:RegisterForDrag("LeftButton")
    local function PickupMacroOfSelected()
        local loadout = Selected()
        if loadout then
            GameTooltip:Hide()
            NS.PickupLoadoutMacro(loadout)
        end
    end
    d.macro:SetScript("OnDragStart", PickupMacroOfSelected)
    d.macro:SetScript("OnClick", PickupMacroOfSelected)
    d.macro:SetScript("OnEnter", function(self)
        local loadout = Selected()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip_SetTitle(GameTooltip, "Loadout macro")
        GameTooltip_AddNormalLine(GameTooltip, "Drag onto an action bar: clicking it applies this loadout.", true)
        if loadout then GameTooltip_AddNormalLine(GameTooltip, "/asp load " .. loadout.name) end
        GameTooltip_AddInstructionLine(GameTooltip, "Created as a character macro the first time.")
        GameTooltip:Show()
    end)
    d.macro:SetScript("OnLeave", function() GameTooltip:Hide() end)

    d.name:SetPoint("TOPLEFT", 44, -4)
    d.name:SetPoint("RIGHT", -4, 0)
    d.name:SetJustifyH("LEFT")
    d.info = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.info:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -4)

    local apply = Button(d, "Apply", 80, WithSelected(function(l) NS.ApplyLoadout(l) end),
        "Puts this loadout on all bars and equips its set.")
    apply:SetPoint("TOPLEFT", d.info, "BOTTOMLEFT", 0, -8)
    d.edit = Button(d, "Edit on bars", 100, WithSelected(NS.StartEdit),
        "Puts it on the bars to change them there. Save edit keeps the bars, Cancel edit restores the old bars.")
    d.edit:SetPoint("LEFT", apply, "RIGHT", 4, 0)
    d.saveEdit = Button(d, "Save edit", 80, function() NS.SaveEdit() end)
    d.saveEdit:SetPoint("LEFT", apply, "RIGHT", 4, 0)
    d.cancelEdit = Button(d, "Cancel edit", 90, function() NS.CancelEdit() end)
    d.cancelEdit:SetPoint("LEFT", d.saveEdit, "RIGHT", 4, 0)
    local overwrite = Button(d, "Overwrite from bars", 140, WithSelected(function(l)
        NS.Confirm(("Overwrite loadout \"%s\" with the current bars?"):format(l.name), function()
            NS.SaveLoadout(l.name, l)
        end)
    end), "Replaces all slots of this loadout with your bars now.")
    overwrite:SetPoint("LEFT", apply, "RIGHT", 4 + 90 + 4 + 80 + 4, 0)

    local rename = Button(d, "Rename", 80, WithSelected(NS.RenameDialog))
    rename:SetPoint("TOPLEFT", apply, "BOTTOMLEFT", 0, -4)
    local copy = Button(d, "Copy", 80, WithSelected(NS.CopyDialog))
    copy:SetPoint("LEFT", rename, "RIGHT", 4, 0)
    local delete = Button(d, "Delete", 80, WithSelected(function(l)
        NS.Confirm(("Delete loadout \"%s\"?"):format(l.name), function() NS.DeleteLoadout(l) end)
    end))
    delete:SetPoint("LEFT", copy, "RIGHT", 4, 0)
    d.setButton = Button(d, "Equipment set: none", 210, nil,
        "Equipped together with this loadout. Bound by name, so each character of the class can have its own set.")
    d.setButton:SetPoint("LEFT", delete, "RIGHT", 4, 0)
    d.specButton = Button(d, "Spec: none", 110, nil,
        "Talent spec of this character that uses this loadout: switching to it applies the loadout.")
    d.specButton:SetPoint("LEFT", overwrite, "RIGHT", 4, 0)
    d.specButton:SetScript("OnClick", function(self)
        local loadout = Selected()
        if not loadout then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Talent spec")
            NS.AddSpecRadios(root, loadout)
        end)
    end)
    d.setButton:SetScript("OnClick", function(self)
        local loadout = Selected()
        if not loadout then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Equipment set")
            NS.AddEquipmentSetRadios(root, loadout)
        end)
    end)

    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.note:SetPoint("TOPLEFT", rename, "BOTTOMLEFT", 0, -8)
    d.note:SetPoint("RIGHT", -110, 0)
    d.note:SetJustifyH("LEFT")
    d.stopWaiting = Button(d, "Stop waiting", 100, function() NS.StopWaiting() end,
        "Forget the spells that wait to be learned; their slots stay empty.")
    d.stopWaiting:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, -100)

    -- Slot grid
    local gridScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    gridScroll:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -128)
    gridScroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -24, 28)
    gridChild = CreateFrame("Frame", nil, gridScroll)
    gridChild:SetSize(ROW_LABEL + 12 * (ICON + GAP), 1)
    gridScroll:SetScrollChild(gridChild)

    local all = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    all:SetSize(24, 24)
    all:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, 0)
    all.label = all:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    all.label:SetPoint("LEFT", all, "RIGHT", 2, 0)
    all.label:SetText("All slots (page 2, stances, totems)")
    all:SetScript("OnClick", function(self)
        showAll = self:GetChecked() and true or false
        Refresh()
    end)
    frame.showAll = all

    local legend = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", 0, 6)
    legend:SetText("L = latest rank, L-1 / L-2 = below it")

    frame:SetScript("OnShow", Refresh)
    frame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("SPELLS_CHANGED")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("UPDATE_MACROS")
    frame:SetScript("OnEvent", function() Refresh() end)
end

-- show: true = always show, nil = toggle.
function NS.ToggleUI(show)
    if not frame then CreateWindow() end
    if not frame:IsShown() then
        frame:Show() -- OnShow refreshes
    elseif show then
        Refresh()
    else
        frame:Hide()
    end
end

function NS.RefreshUI()
    Refresh()
end
