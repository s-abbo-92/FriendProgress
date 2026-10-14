-- UI: character list on the left, tabbed detail view on the right.
local _, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local floor, concat = math.floor, table.concat

local TABS = {
    { "overview", "Overview" },
    { "gear", "Gear" },
    { "bags", "Bags" },
    { "bank", "Bank" },
    { "prof", "Professions" },
    { "quest", "Quests" },
    { "log", "Activity" },
}

local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
    [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [11] = "Finger", [12] = "Finger", [13] = "Trinket", [14] = "Trinket", [15] = "Back",
    [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard",
}

local WIDTH, HEIGHT = 840, 520   -- minimum size; widens if the tab labels need it
local LIST_W = 190
local RIGHT_X = 236   -- left edge of tabs / body / settings

local frame, bodyText, body
local listButtons, tabButtons = {}, {}
local selected, tab = nil, "overview"
local showSettings = false

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------
local function ClassColored(text, class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.colorStr and ("|c" .. c.colorStr .. text .. "|r") or text
end
ns.ClassColored = ClassColored

local function Ago(t)
    if not t or t == 0 then return "never" end
    local d = GetServerTime() - t
    if d < 60 then return "just now" end
    if d < 3600 then return floor(d / 60) .. "m ago" end
    if d < 86400 then return floor(d / 3600) .. "h ago" end
    return floor(d / 86400) .. "d ago"
end

local function Money(copper)
    if not copper then return "?" end
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return floor(copper / 10000) .. "g"
end

local function Gray(s) return "|cff808080" .. s .. "|r" end

-- item is an itemID or an item string ("item:1234:..."). Uncached items show a
-- grey placeholder link (still hoverable); GET_ITEM_INFO_RECEIVED refreshes the
-- view with the real, quality-coloured link once the server answers.
local function ItemText(item)
    local itemString = tonumber(item) and ("item:" .. item) or tostring(item)
    local id = tonumber(itemString:match("item:(%d+)"))
    local _, link = GetItemInfo(item)
    local icon = id and GetItemIcon(id)
    local iconText = icon and ("|T" .. icon .. ":16|t ") or ""
    return iconText .. (link or ("|cff808080|H" .. itemString .. "|h[item " .. tostring(id) .. "]|h|r"))
end

-- Recipe IDs are spell IDs, so names and icons are available instantly.
local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return GetSpellInfo and (GetSpellInfo(id))
end

local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    return GetSpellTexture and GetSpellTexture(id)
end

-- Shows the crafted item (quality-coloured) when known, else a link to the recipe's spell.
local function RecipeText(recipeID, itemID)
    if itemID and itemID > 0 then return ItemText(itemID) end
    local icon = SpellIcon(recipeID)
    local link = C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(recipeID)
    return (icon and ("|T" .. icon .. ":16|t ") or "") .. (link or SpellName(recipeID) or ("recipe " .. recipeID))
end

-- Item list for bags/bank snapshots, best quality first.
local function ItemLines(lines, items)
    local list = {}
    for id, count in pairs(items or {}) do
        local name, _, quality = GetItemInfo(id)
        list[#list + 1] = { id = id, count = count, name = name or "", q = quality or -1 }
    end
    table.sort(list, function(a, b)
        if a.q ~= b.q then return a.q > b.q end
        return a.name < b.name
    end)
    for _, e in ipairs(list) do
        lines[#lines + 1] = ItemText(e.id) .. (e.count > 1 and (" x" .. e.count) or "")
    end
end

local function FilterNote(lines, filter, what)
    if filter == "materials" then
        lines[#lines + 1] = Gray("Sharing crafting materials only")
    elseif filter == "none" then
        lines[#lines + 1] = Gray(what .. " contents not shared")
    end
end

---------------------------------------------------------------------------
-- Tab renderers: each returns a list of lines
---------------------------------------------------------------------------
local render = {}

function render.overview(c, key)
    local s = c.sections.char
    if not s then return { "Waiting for data from " .. key .. "..." } end
    local className = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[s.class] or s.class or ""
    local lines = {
        ClassColored(s.name or key, s.class) .. "  " .. Gray(key),
        ("Level %d %s %s"):format(s.level or 0, s.race or "", className),
    }
    if s.xpMax and s.xpMax > 0 then
        local pct = floor(s.xp / s.xpMax * 100)
        local rested = (s.rested or 0) > 0 and (" (+" .. s.rested .. " rested)") or ""
        lines[#lines + 1] = ("XP: %d / %d  (%d%%)%s"):format(s.xp, s.xpMax, pct, rested)
    end
    if s.zone and s.zone ~= "" then lines[#lines + 1] = "Zone: " .. s.zone end
    if s.guild then lines[#lines + 1] = "Guild: <" .. s.guild .. ">" end
    if s.ilvl then lines[#lines + 1] = "Item level: " .. s.ilvl end
    local bags = c.sections.bags
    if bags and bags.money then lines[#lines + 1] = "Gold: " .. Money(bags.money) end
    local groups = ns.GroupsOf(key)
    if #groups > 0 then lines[#lines + 1] = "Groups: " .. concat(groups, ", ") end
    lines[#lines + 1] = ""
    for _, p in ipairs(c.sections.prof or {}) do
        lines[#lines + 1] = ("%s %d/%d"):format(p.name, p.rank, p.max)
    end
    local quests = c.sections.quest
    if quests then
        local done = 0
        for _, q in ipairs(quests) do if q.done then done = done + 1 end end
        lines[#lines + 1] = ("Quests: %d in log, %d ready to turn in"):format(#quests, done)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = Gray("Last updated " .. Ago(c.lastSeen))
    return lines
end

function render.gear(c)
    local gear = c.sections.gear
    if not gear then return { "No gear data yet." } end
    local lines = {}
    for slot = 1, 19 do
        local item = gear[slot]
        lines[#lines + 1] = Gray(SLOT_NAMES[slot] .. ":") .. "  " .. (item and ItemText(item) or Gray("-"))
    end
    return lines
end

function render.bags(c)
    local bags = c.sections.bags
    if not bags then return { "No bag data shared." } end
    local lines = {}
    if bags.money then lines[#lines + 1] = "Gold: " .. Money(bags.money) end
    if bags.total then
        lines[#lines + 1] = ("Bag space: %d free of %d"):format(bags.free or 0, bags.total)
    end
    FilterNote(lines, bags.filter, "Bag")
    lines[#lines + 1] = ""
    ItemLines(lines, bags.items)
    return lines
end

function render.bank(c, key)
    local bank = c.sections.bank
    if not bank then
        if key == ns.me or c.isMine then
            return { "No bank data yet. Visit a banker on this character to record it." }
        end
        return { "No bank data shared yet. It's recorded when they next visit a banker." }
    end
    local lines = { "Last bank visit: " .. Ago(bank.t) }
    if bank.total then
        lines[#lines + 1] = ("Bank space: %d free of %d"):format(bank.free or 0, bank.total)
    end
    FilterNote(lines, bank.filter, "Bank")
    lines[#lines + 1] = ""
    ItemLines(lines, bank.items)
    return lines
end

local function CountKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function render.prof(c, key)
    local profs = c.sections.prof
    if not profs then return { "No profession data yet." } end
    if #profs == 0 then return { "No professions learned." } end
    local recipes = c.sections.recipes or {}
    local lines = {}
    for _, p in ipairs(profs) do
        local icon = p.icon and ("|T" .. p.icon .. ":16|t ") or ""
        local r = recipes[p.name]
        local count = r and Gray(("  -  %d recipes"):format(CountKeys(r.list))) or ""
        lines[#lines + 1] = ("%s%s  %d / %d%s"):format(icon, p.name, p.rank, p.max, count)
    end

    local names = {}
    for name in pairs(recipes) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        lines[#lines + 1] = ""
        local who = (key == ns.me) and "you open" or "they open"
        lines[#lines + 1] = Gray("Recipes are recorded when " .. who .. " a profession window.")
        return lines
    end
    for _, name in ipairs(names) do
        local r = recipes[name]
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("|cffffd100%s recipes|r  %s"):format(name, Gray("(updated " .. Ago(r.t) .. ")"))
        local list = {}
        for recipeID, itemID in pairs(r.list or {}) do
            list[#list + 1] = { id = recipeID, item = itemID, name = SpellName(recipeID) or "" }
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        for _, e in ipairs(list) do
            lines[#lines + 1] = "    " .. RecipeText(e.id, e.item)
        end
    end
    return lines
end

-- "Who can craft X?" across every character in the current list.
local MAX_RESULTS = 100
local function RenderSearch(query, keys)
    local q = query:lower()
    local found, list = {}, {}
    for _, key in ipairs(keys) do
        local c = ns.db.chars[key]
        local s = c.sections.char or {}
        local who = ClassColored(s.name or Ambiguate(key, "short"), s.class)
        for _, r in pairs(c.sections.recipes or {}) do
            for recipeID, itemID in pairs(r.list or {}) do
                local spell = SpellName(recipeID) or ""
                local item = itemID > 0 and GetItemInfo(itemID) or nil
                if spell:lower():find(q, 1, true) or (item and item:lower():find(q, 1, true)) then
                    local e = found[recipeID]
                    if not e then
                        e = { id = recipeID, item = itemID, name = item or spell, who = {} }
                        found[recipeID] = e
                        list[#list + 1] = e
                    end
                    e.who[#e.who + 1] = who
                end
            end
        end
    end
    if #list == 0 then
        return {
            ("Nobody here knows a recipe matching \"%s\"."):format(query),
            "",
            Gray("Recipes are recorded when each person opens their profession window."),
        }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    local lines = { ("Recipes matching \"%s\" (%d)"):format(query, #list), "" }
    for i = 1, math.min(#list, MAX_RESULTS) do
        local e = list[i]
        lines[#lines + 1] = RecipeText(e.id, e.item) .. "  " .. Gray("-") .. "  " .. concat(e.who, ", ")
    end
    if #list > MAX_RESULTS then
        lines[#lines + 1] = Gray(("...and %d more. Try a longer search."):format(#list - MAX_RESULTS))
    end
    return lines
end

function render.quest(c)
    local quests = c.sections.quest
    if not quests then return { "No quest data yet." } end
    if #quests == 0 then return { "Quest log is empty." } end
    local lines = {}
    for _, q in ipairs(quests) do
        local title = ("[%d] %s"):format(q.level or 0, q.title or ("quest " .. q.id))
        lines[#lines + 1] = q.done and ("|cff40ff40" .. title .. " (complete)|r") or ("|cffffd100" .. title .. "|r")
        for _, o in ipairs(q.obj or {}) do
            local text, finished = o[1], o[2]
            lines[#lines + 1] = "    " .. (finished and Gray(text) or text)
        end
    end
    return lines
end

function render.log(c)
    local log = c.sections.log
    if not log or #log == 0 then return { "No activity yet." } end
    local lines = {}
    for _, e in ipairs(log) do
        lines[#lines + 1] = Gray(date("%d %b %H:%M", e.t)) .. "  " .. (e.m or "")
    end
    return lines
end

---------------------------------------------------------------------------
-- Character list and its right-click menu
---------------------------------------------------------------------------
local function ShowCharacterMenu(owner, key)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local s = ns.db.chars[key] and ns.db.chars[key].sections.char
        root:CreateTitle(s and s.name or Ambiguate(key, "short"))
        if #ns.db.groups > 0 then
            for _, g in ipairs(ns.db.groups) do
                local name = g.name
                root:CreateCheckbox(name,
                    function() return ns.GetGroup(name) and ns.GetGroup(name).members[key] or false end,
                    function()
                        ns.ToggleGroupMember(name, key)
                        ns:Fire("GROUPS_CHANGED")
                    end)
            end
            root:CreateDivider()
        end
        root:CreateButton("New group with this character...", function() ns.PromptNewGroup(key) end)
        if key ~= ns.me then
            root:CreateDivider()
            root:CreateButton("Forget this character", function()
                SlashCmdList.FRIENDPROGRESS("remove " .. key)
            end)
        end
    end)
end

local function ListButton(i)
    local b = listButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, frame.listContent)
    b:SetSize(LIST_W - 4, 34)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * 36)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 1, 1, 0.12)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.name:SetPoint("TOPLEFT", 6, -4)
    b.name:SetPoint("RIGHT", -4, 0)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.sub:SetPoint("BOTTOMLEFT", 6, 4)
    b.sub:SetPoint("RIGHT", -4, 0)
    b.sub:SetJustifyH("LEFT")
    b.sub:SetWordWrap(false)
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ShowCharacterMenu(self, self.key)
            return
        end
        selected = self.key
        showSettings = false
        ns.RefreshUI()
    end)
    listButtons[i] = b
    return b
end

local function BuildGroupDropdown()
    local dd = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    dd:SetWidth(LIST_W)
    dd:SetPoint("TOPLEFT", 12, -30)
    dd:SetupMenu(function(_, root)
        local function Select(key)
            ns.db.settings.activeGroup = key
            ns:Fire("GROUPS_CHANGED")
        end
        local function IsActive(key) return ns.db.settings.activeGroup == key end
        for _, f in ipairs(ns.BUILTIN_FILTERS) do
            root:CreateRadio(f.label, function() return IsActive(f.key) end, function() Select(f.key) end)
        end
        if #ns.db.groups > 0 then
            root:CreateDivider()
            for _, g in ipairs(ns.db.groups) do
                local name = g.name
                root:CreateRadio(name, function() return IsActive(name) end, function() Select(name) end)
            end
        end
        root:CreateDivider()
        root:CreateButton("New group...", function() ns.PromptNewGroup() end)
        local active = ns.db.settings.activeGroup
        if ns.GetGroup(active) then
            root:CreateButton("Rename \"" .. active .. "\"...", function() ns.PromptRenameGroup(active) end)
            root:CreateButton("Delete \"" .. active .. "\"...", function() ns.PromptDeleteGroup(active) end)
        end
    end)
    frame.groupDropdown = dd
end

---------------------------------------------------------------------------
-- Sharing settings panel (replaces the tab body while open)
---------------------------------------------------------------------------
local settingChecks = {}

local function RefreshSettings()
    for _, cb in ipairs(settingChecks) do cb:SetChecked(cb.get() and true or false) end
end

local function BuildSettings()
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", RIGHT_X, -62)   -- below the tab row
    panel:SetPoint("BOTTOMRIGHT", -12, 40)
    panel:Hide()
    frame.settingsPanel = panel

    local share = function() return ns.db.settings.share end
    local x, y = 0, 0   -- current column's left edge and cursor

    local function Column(left)
        x, y = left, 0
    end

    local function Label(text, font, indent, width)
        local fs = panel:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        fs:SetPoint("TOPLEFT", x + (indent or 4), y)
        fs:SetJustifyH("LEFT")
        if width then fs:SetWidth(width) end
        fs:SetText(text)
        y = y - math.max(22, fs:GetStringHeight() + 8)
        return fs
    end

    -- A checkbox at (left, top). get() reads the value, set(checked) stores it,
    -- after(checked) runs once saved (default: resync what friends see).
    local function MakeCheck(left, top, text, font, get, set, after)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", left, top)
        local fs = panel:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        fs:SetText(text)
        cb.get = get
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked())
            RefreshSettings()
            if after then after(self:GetChecked()) else ns.ShareSettingsChanged() end
        end)
        settingChecks[#settingChecks + 1] = cb
        return cb, fs
    end

    local function Check(text, get, set, indent, after)
        local cb = MakeCheck(x + (indent or 4), y, text, "GameFontHighlight", get, set, after)
        y = y - 26
        return cb
    end

    local function Toggle(text, key)
        return Check(text, function() return share()[key] end, function(v) share()[key] = v end)
    end

    -- One row of radio-style checkboxes: "Bags:  [ ] All  [x] Materials  [ ] None".
    -- options = { { value, label }, ... }; get() returns the current value.
    local function RadioRow(text, options, get, set, after)
        local left = x + 8
        if text then
            local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetPoint("TOPLEFT", left, y - 5)
            fs:SetText(text)
            left = x + 56
        end
        for _, o in ipairs(options) do
            local value = o[1]
            local _, label = MakeCheck(left, y, o[2], "GameFontHighlightSmall",
                function() return get() == value end,
                function() set(value) end, after)
            left = left + 26 + label:GetStringWidth() + 12
        end
        y = y - 26
    end

    local MODES = { { "all", "All" }, { "materials", "Materials" }, { "none", "None" } }
    local function ModeRow(text, key)
        RadioRow(text, MODES, function() return share()[key] end, function(v) share()[key] = v end)
    end

    local function OnScreenToggle(text, get, set)
        return Check(text, get, set, nil, function() ns.RefreshOnScreen() end)
    end

    local function TooltipToggle(text, key)
        return Check(text, function() return ns.db.settings.tooltip[key] end,
            function(v) ns.db.settings.tooltip[key] = v end, nil,
            function() ns.InvalidateTooltipIndex() end)
    end

    -- Left column: what friends receive
    Column(0)
    Label("What you share", "GameFontNormalLarge")
    Label("Name, class and level are always shared.", "GameFontDisableSmall", nil, 280)
    Toggle("Current zone", "zone")
    Toggle("Equipped gear", "gear")
    ModeRow("Bags:", "bags")
    ModeRow("Bank:", "bank")
    Toggle("Gold", "gold")
    Toggle("Professions", "prof")
    Check("Known recipes",
        function() return share().recipes end,
        function(v) share().recipes = v end, 24)
    Toggle("Quest log", "quest")
    Toggle("Activity feed", "log")
    Check("Live XP to your party",
        function() return share().liveXP end,
        function(v) share().liveXP = v end, nil,
        function(v) ns.SetLiveXPSharing(v) end)
    Label("Materials = trade goods and reagents. Feed entries for anything you don't share are left out.",
        "GameFontDisableSmall", nil, 280)

    -- Right column: this player's own display
    Column(320)
    Label("On screen", "GameFontNormalLarge")
    OnScreenToggle("Show party XP box",
        function() return ns.db.settings.partyXP.enabled end,
        function(v) ns.db.settings.partyXP.enabled = v end)
    OnScreenToggle("Show sync button",
        function() return ns.db.settings.syncButton.enabled end,
        function(v) ns.db.settings.syncButton.enabled = v end)
    OnScreenToggle("Lock positions",
        function() return ns.db.settings.locked end,
        function(v) ns.db.settings.locked = v end)
    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(120, 22)
    reset:SetPoint("TOPLEFT", x + 8, y - 2)
    reset:SetText("Reset positions")
    reset:SetScript("OnClick", function()
        ns.ResetPartyXPPosition()
        ns.ResetSyncButtonPosition()
    end)
    y = y - 30
    Label("Unlock to drag them anywhere. Party members need FriendProgress for their XP to show.",
        "GameFontDisableSmall", nil, 250)
    y = y - 6
    Label("Auto sync", "GameFontNormalLarge")
    RadioRow(nil, { { 0, "Off" }, { 5, "5 min" }, { 10, "10 min" }, { 30, "30 min" } },
        function() return ns.db.settings.autoSync end,
        function(v) ns.db.settings.autoSync = v end,
        function() end)
    y = y - 6
    Label("Item tooltips", "GameFontNormalLarge")
    TooltipToggle("Show who has / can craft items", "enabled")
    TooltipToggle("Include my other characters", "mine")
    y = y - 6
    Label("Notifications", "GameFontNormalLarge")
    Check("Show friends' activity in chat",
        function() return ns.db.settings.notify end,
        function(v) ns.db.settings.notify = v end, nil,
        function() end)

    panel:SetScript("OnShow", RefreshSettings)
    -- Lock/unlock can also change via slash commands while the panel is open.
    ns.RefreshSettingsPanel = RefreshSettings
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local function Build()
    frame = CreateFrame("Frame", "FriendProgressFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "FriendProgressFrame")   -- Escape closes it

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("FriendProgress")

    BuildGroupDropdown()

    local listScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 12, -60)
    listScroll:SetPoint("BOTTOMLEFT", 12, 40)
    listScroll:SetWidth(LIST_W)
    frame.listContent = CreateFrame("Frame", nil, listScroll)
    frame.listContent:SetSize(LIST_W, 1)
    listScroll:SetScrollChild(frame.listContent)

    frame.emptyList = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.emptyList:SetPoint("TOPLEFT", 16, -66)
    frame.emptyList:SetWidth(LIST_W - 10)
    frame.emptyList:SetJustifyH("LEFT")
    frame.emptyList:SetText("Nobody here yet. Right-click a character in \"Everyone\" to add them to a group.")

    -- Tabs size to their labels, which UI skins with larger fonts can make wider.
    local tabX = RIGHT_X
    for _, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetText(t[2])
        local w = math.max(70, math.ceil(b:GetFontString():GetStringWidth()) + 24)
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", tabX, -30)
        tabX = tabX + w + 3
        b:SetScript("OnClick", function()
            tab = t[1]
            showSettings = false
            ns.RefreshUI()
        end)
        tabButtons[t[1]] = b
    end

    -- Recipe search, shown on the Professions tab only.
    local search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
    search:SetSize(260, 20)
    search:SetPoint("TOPLEFT", RIGHT_X + 8, -60)
    search:SetAutoFocus(false)
    if search.Instructions then search.Instructions:SetText("Who can craft...?") end
    search:HookScript("OnTextChanged", function() ns.RefreshUI() end)
    frame.search = search

    local bodyScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.bodyScroll = bodyScroll
    local frameW = math.max(WIDTH, tabX + 9)
    frame:SetWidth(frameW)
    local bodyW = frameW - RIGHT_X - 32
    body = CreateFrame("Frame", nil, bodyScroll)
    body:SetSize(bodyW, 1)
    bodyScroll:SetScrollChild(body)
    -- Item and spell links in the text: hover for a tooltip; click behaves like
    -- a chat link (shift-click to link in chat, ctrl-click to try on).
    body:SetHyperlinksEnabled(true)
    body:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, 0)
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    body:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    body:SetScript("OnHyperlinkClick", function(_, link, text, button)
        SetItemRef(link, text, button)
    end)
    bodyText = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bodyText:SetPoint("TOPLEFT", 4, -4)
    bodyText:SetWidth(bodyW - 10)
    bodyText:SetJustifyH("LEFT")
    bodyText:SetJustifyV("TOP")
    bodyText:SetSpacing(3)

    local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    sync:SetSize(100, 22)
    sync:SetPoint("BOTTOMRIGHT", -12, 12)
    sync:SetText("Sync now")
    sync:SetScript("OnClick", function() SlashCmdList.FRIENDPROGRESS("sync") end)

    local sharing = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    sharing:SetSize(100, 22)
    sharing:SetPoint("RIGHT", sync, "LEFT", -4, 0)
    sharing:SetText("Sharing...")
    sharing:SetScript("OnClick", function()
        showSettings = not showSettings
        ns.RefreshUI()
    end)

    BuildSettings()

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 16, 18)
    hint:SetText("Friends need FriendProgress too. Right-click a character to add them to a group.")

    frame:SetScript("OnShow", function() ns.RefreshUI() end)
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function SortedKeys()
    local keys = {}
    for k in pairs(ns.db.chars) do
        if ns.PassesFilter(k) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        if a == b then return false end
        local ca, cb = ns.db.chars[a], ns.db.chars[b]
        if a == ns.me then return true end
        if b == ns.me then return false end
        return (ca.lastSeen or 0) > (cb.lastSeen or 0)
    end)
    return keys
end

local function Contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

function ns.RefreshUI()
    if not frame or not frame:IsShown() then return end
    frame.groupDropdown:GenerateMenu()   -- updates the dropdown's label

    local keys = SortedKeys()
    if not selected or not Contains(keys, selected) then selected = keys[1] end

    for i, key in ipairs(keys) do
        local c = ns.db.chars[key]
        local s = c.sections.char or {}
        local b = ListButton(i)
        b.key = key
        local label = ClassColored(s.name or Ambiguate(key, "short"), s.class)
        if c.isMine then label = label .. Gray(key == ns.me and " (you)" or " (alt)") end
        b.name:SetText(label)
        b.sub:SetText(("Lvl %s  %s"):format(s.level or "?", Gray(Ago(c.lastSeen))))
        b.sel:SetShown(key == selected)
        b:Show()
    end
    for i = #keys + 1, #listButtons do listButtons[i]:Hide() end
    frame.listContent:SetHeight(math.max(1, #keys * 36))
    frame.emptyList:SetShown(#keys == 0)

    for key, b in pairs(tabButtons) do b:SetEnabled(showSettings or key ~= tab) end
    frame.settingsPanel:SetShown(showSettings)
    frame.bodyScroll:SetShown(not showSettings)
    local searching = tab == "prof" and not showSettings
    frame.search:SetShown(searching)
    if showSettings then return end

    -- Make room for the search box on the Professions tab.
    frame.bodyScroll:ClearAllPoints()
    frame.bodyScroll:SetPoint("TOPLEFT", RIGHT_X, searching and -86 or -60)
    frame.bodyScroll:SetPoint("BOTTOMRIGHT", -32, 40)

    local query = searching and strtrim(frame.search:GetText() or "") or ""
    local lines
    if query ~= "" then
        lines = RenderSearch(query, keys)
    else
        local c = selected and ns.db.chars[selected]
        lines = c and render[tab](c, selected) or { "No characters to show." }
    end
    bodyText:SetText(concat(lines, "\n"))
    body:SetHeight(bodyText:GetStringHeight() + 8)
end

function ns.ToggleUI()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
end

function ns.ShowRecipeSearch(text)
    if not frame then Build() end
    tab, showSettings = "prof", false
    frame:Show()
    frame.search:SetText(text or "")   -- triggers a refresh
    ns.RefreshUI()
end

function ns.ShowSettings()
    if not frame then Build() end
    showSettings = true
    if frame:IsShown() then ns.RefreshUI() else frame:Show() end
end

-- Coalesce bursts of updates (many chunks arrive at once) into one redraw.
local refreshQueued = false
local function QueueRefresh()
    if refreshQueued or not frame or not frame:IsShown() then return end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        ns.RefreshUI()
    end)
end

ns:Listen("DATA_UPDATED", QueueRefresh)
ns:Listen("GROUPS_CHANGED", QueueRefresh)
ns:On("GET_ITEM_INFO_RECEIVED", QueueRefresh)
