-- UI: character list on the left, tabbed detail view on the right.
local _, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local floor, concat = math.floor, table.concat
local S = ns.Skin
local TITLE_H, TOP_Y, FOOT_H = 32, 44, 40   -- title bar; tab row; footer (heights / offsets)
local BODY_SIZE = 13

local TABS = {
    { "overview", "Overview" },
    { "gear", "Gear" },
    { "bags", "Bags" },
    { "bank", "Bank" },
    { "prof", "Professions" },
    { "quest", "Quests" },
    { "log", "Activity" },
    { "deaths", "Deaths" },
}

local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
    [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [11] = "Finger", [12] = "Finger", [13] = "Trinket", [14] = "Trinket", [15] = "Back",
    [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard",
}

local WIDTH, HEIGHT = 840, 584   -- minimum size; widens if the tab labels need it
local LIST_W = 190
local RIGHT_X = 236   -- left edge of tabs / body / settings

local frame, bodyText, body
local listButtons, tabButtons = {}, {}
local selected, tab = nil, "overview"
local legacyBody = false   -- true if the virtual list couldn't be built; the plain scroll frame is used instead
local expandedRecipes = {}   -- [ recipeID ] = true while its materials are unfolded on the Professions tab
local menuStale = true   -- the group dropdown only needs regenerating when groups or the selection change
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

local function Gray(s) return "|cff" .. S.MUTED_HEX .. s .. "|r" end

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

local function Duration(seconds)
    local minutes = floor(seconds / 60)
    if minutes < 60 then return minutes .. "m" end
    return ("%dh %dm"):format(floor(minutes / 60), minutes % 60)
end

-- Friends send their rate. Hide it once they've gone quiet: it only updates as they earn XP.
local RATE_STALE = 1800
local function XPRateLines(lines, c, s, key)
    local rate = s.xph
    if key == ns.me then
        rate = ns.XPRate()
    elseif GetServerTime() - (c.lastSeen or 0) > RATE_STALE then
        rate = nil
    end
    if not rate or rate <= 0 then return end
    lines[#lines + 1] = ("XP per hour: about %d"):format(floor(rate))
    -- Friends' XP is shared in 5% steps (rounded down); assume the middle of the step.
    local xp = (s.xp or 0) + (key ~= ns.me and s.xpMax / 40 or 0)
    local seconds = math.max(s.xpMax - xp, 0) / rate * 3600
    if seconds < 100 * 3600 then
        lines[#lines + 1] = "Next level: about " .. Duration(seconds) .. Gray("  at this rate")
    end
end

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
        XPRateLines(lines, c, s, key)
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

-- How many of an item they hold across bags and bank, or nil if they don't share their bags.
local function MaterialCount(c, id)
    local bags, bank = c.sections.bags, c.sections.bank
    if not bags or bags.filter == "none" then return nil end
    return ((bags.items or {})[id] or 0) + (bank and bank.items and bank.items[id] or 0)
end

local function MaterialLines(lines, c, mats)
    local list = {}
    for id, need in pairs(mats or {}) do list[#list + 1] = { id = id, need = need } end
    table.sort(list, function(a, b) return a.id < b.id end)
    for _, m in ipairs(list) do
        local have = MaterialCount(c, m.id)
        local text = Gray(("need %d"):format(m.need))
        if have then
            local colour = have >= m.need and "33d999" or "ff6666"
            text = ("|cff%shave %d|r  %s"):format(colour, have, text)
        end
        lines[#lines + 1] = "        " .. ItemText(m.id) .. "  " .. text
    end
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
        lines[#lines + 1] = ("|cff33d999%s recipes|r  %s"):format(name, Gray("(updated " .. Ago(r.t) .. ")"))
        local list = {}
        for recipeID, itemID in pairs(r.list or {}) do
            list[#list + 1] = { id = recipeID, item = itemID, name = SpellName(recipeID) or "" }
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        for _, e in ipairs(list) do
            -- Materials unfold on click: listing them all would add hundreds of item lines.
            local mats = r.mats and r.mats[e.id]
            local toggle = ""
            if mats and next(mats) then
                toggle = ("|Hfp:mats:%d|h|cff33d999[%s]|r|h "):format(e.id, expandedRecipes[e.id] and "-" or "+")
            end
            lines[#lines + 1] = "    " .. toggle .. RecipeText(e.id, e.item)
            if toggle ~= "" and expandedRecipes[e.id] then MaterialLines(lines, c, mats) end
        end
    end
    return lines
end

-- "Who can craft X?" across every character in the current list.
local MAX_RESULTS = 100
local lowerSpell, lowerItem = {}, {}   -- lowercased names, so a keystroke doesn't redo them for every recipe
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
                local spellLower = lowerSpell[recipeID]
                if not spellLower then
                    spellLower = spell:lower()
                    if spell ~= "" then lowerSpell[recipeID] = spellLower end
                end
                local itemLower = item and (lowerItem[itemID] or item:lower())
                if itemLower then lowerItem[itemID] = itemLower end
                if spellLower:find(q, 1, true) or (itemLower and itemLower:find(q, 1, true)) then
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
        lines[#lines + 1] = q.done and ("|cff40ff40" .. title .. " (complete)|r") or ("|cff33d999" .. title .. "|r")
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

-- Everyone's deaths, not just the selected character's (filtered by the group dropdown).
function render.deaths()
    local lines = {}
    for _, d in ipairs(ns.db.deaths) do
        if ns.PassesFilter(d.name) then
            lines[#lines + 1] = Gray(date("%d %b %H:%M", d.t)) .. "  " .. ns.DeathText(d)
        end
    end
    if #lines == 0 then return { "No deaths yet. Long may it last." } end
    return lines
end

---------------------------------------------------------------------------
-- Links in the text: item and spell links behave like chat links; our own "fp:mats:<id>"
-- links fold and unfold a recipe's materials.
---------------------------------------------------------------------------
local function LinkEnter(self, link)
    if link:sub(1, 3) == "fp:" then return end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, 0)
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

local function LinkClick(_, link, text, button)
    local recipeID = tonumber(link:match("^fp:mats:(%d+)$"))
    if recipeID then
        expandedRecipes[recipeID] = not expandedRecipes[recipeID] or nil
        ns.RefreshUI()
        return
    end
    SetItemRef(link, text, button)
end

---------------------------------------------------------------------------
-- Character list and its right-click menu
---------------------------------------------------------------------------
local function ShowCharacterMenu(owner, key)
    local c = ns.db.chars[key] and ns.db.chars[key].sections.char
    local items = { { text = c and c.name or Ambiguate(key, "short"), title = true } }
    for _, g in ipairs(ns.db.groups) do
        local name = g.name
        items[#items + 1] = { text = name, checkbox = true, checked = g.members[key] == true,
            onClick = function()
                ns.ToggleGroupMember(name, key)
                ns:Fire("GROUPS_CHANGED")
            end }
    end
    if #ns.db.groups > 0 then items[#items + 1] = { divider = true } end
    items[#items + 1] = { text = "New group with this character...", onClick = function() ns.PromptNewGroup(key) end }
    if key ~= ns.me then
        items[#items + 1] = { divider = true }
        items[#items + 1] = { text = "Forget this character", onClick = function()
            SlashCmdList.FRIENDPROGRESS("remove " .. key)
        end }
    end
    S.ShowMenu(owner, items, 180, true)
end

local function ListButton(i)
    local b = listButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, frame.listContent)
    b:SetSize(LIST_W - 4, 34)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * 36)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.hover = S.Solid(b, "BACKGROUND", S.C.accent, 0.08)
    b.hover:SetAllPoints()
    b.hover:Hide()
    b.sel = S.Solid(b, "BACKGROUND", S.C.accent, 0.16)
    b.sel:SetAllPoints()
    b.mark = S.Solid(b, "ARTWORK", S.C.accent, 1)
    b.mark:SetPoint("TOPLEFT")
    b.mark:SetPoint("BOTTOMLEFT")
    b.mark:SetWidth(3)
    b:SetScript("OnEnter", function(self) self.hover:Show() end)
    b:SetScript("OnLeave", function(self) self.hover:Hide() end)
    b.name = S.Font(b, 13, S.C.fg)
    b.name:SetPoint("TOPLEFT", 12, -5)
    b.name:SetPoint("RIGHT", -4, 0)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.sub = S.Font(b, 11, S.C.muted)
    b.sub:SetPoint("BOTTOMLEFT", 12, 5)
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

local function GroupMenuItems()
    local active = ns.db.settings.activeGroup
    local function Select(key)
        return function()
            ns.db.settings.activeGroup = key
            ns:Fire("GROUPS_CHANGED")
        end
    end
    local items = {}
    for _, f in ipairs(ns.BUILTIN_FILTERS) do
        items[#items + 1] = { text = f.label, radio = true, checked = active == f.key, onClick = Select(f.key) }
    end
    if #ns.db.groups > 0 then
        items[#items + 1] = { divider = true }
        for _, g in ipairs(ns.db.groups) do
            items[#items + 1] = { text = g.name, radio = true, checked = active == g.name, onClick = Select(g.name) }
        end
    end
    items[#items + 1] = { divider = true }
    items[#items + 1] = { text = "New group...", onClick = function() ns.PromptNewGroup() end }
    if ns.GetGroup(active) then
        items[#items + 1] = { text = "Rename \"" .. active .. "\"...", onClick = function() ns.PromptRenameGroup(active) end }
        items[#items + 1] = { text = "Delete \"" .. active .. "\"...", onClick = function() ns.PromptDeleteGroup(active) end }
    end
    return items
end

local function BuildGroupDropdown()
    local dd = S.Button(frame, "", LIST_W, 26, function(self) S.ShowMenu(self, GroupMenuItems(), LIST_W) end)
    dd:SetPoint("TOPLEFT", 12, -TOP_Y)
    local label = dd:GetFontString()
    label:ClearAllPoints()
    label:SetPoint("LEFT", 10, 0)
    label:SetPoint("RIGHT", -24, 0)
    label:SetJustifyH("LEFT")
    local arrow = S.Font(dd, 12, S.C.muted)
    arrow:SetPoint("RIGHT", -10, 1)
    arrow:SetText("v")
    -- RefreshUI calls this to update the label.
    function dd:GenerateMenu() self:SetText(ns.ActiveFilterLabel()) end
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
    panel:SetPoint("TOPLEFT", RIGHT_X + 8, -(TOP_Y + 40))   -- below the tab row
    panel:SetPoint("BOTTOMRIGHT", -16, FOOT_H + 10)
    panel:Hide()
    frame.settingsPanel = panel

    local share = function() return ns.db.settings.share end
    local x, y = 0, 0   -- current column's left edge and cursor

    local function Column(left)
        x, y = left, 0
    end

    local function Label(text, font, indent, width)
        -- "GameFontNormalLarge" marks a section heading, "GameFontDisableSmall" a note.
        local fs
        if font == "GameFontNormalLarge" then
            fs = S.Font(panel, 15, S.C.accent)
        elseif font == "GameFontDisableSmall" then
            fs = S.Font(panel, 11, S.C.muted)
        else
            fs = S.Font(panel, BODY_SIZE, S.C.fg)
        end
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
        local cb = S.Check(panel, 18)
        cb:SetPoint("TOPLEFT", left, top - 2)
        local fs = S.Font(panel, font == "GameFontHighlightSmall" and 12 or BODY_SIZE, S.C.fg)
        fs:SetPoint("LEFT", cb, "RIGHT", 8, 0)
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
            local fs = S.Font(panel, BODY_SIZE, S.C.fg)
            fs:SetPoint("TOPLEFT", left, y - 5)
            fs:SetText(text)
            left = x + 56
        end
        for _, o in ipairs(options) do
            local value = o[1]
            local _, label = MakeCheck(left, y, o[2], "GameFontHighlightSmall",
                function() return get() == value end,
                function() set(value) end, after)
            left = left + 30 + label:GetStringWidth() + 12
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
    Check("Announce my deaths",
        function() return share().deaths end,
        function(v) share().deaths = v end, nil,
        function() end)
    Check("Live XP to your party",
        function() return share().liveXP end,
        function(v) share().liveXP = v end, nil,
        function(v) ns.SetLiveXPSharing(v) end)
    Check("Battle.net friends (any realm)",
        function() return share().bnet end,
        function(v) share().bnet = v end, nil,
        function(v) if v then ns.SayHello(true, true) end end)
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
    local reset = S.Button(panel, "Reset positions", 120, 22, function()
        ns.ResetPartyXPPosition()
        ns.ResetSyncButtonPosition()
    end)
    reset:SetPoint("TOPLEFT", x + 8, y - 2)
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
    Check("Death alerts on screen",
        function() return ns.db.settings.deaths.alerts end,
        function(v) ns.db.settings.deaths.alerts = v end, nil,
        function() end)
    Check("Jokes in death alerts",
        function() return ns.db.settings.deaths.jokes end,
        function(v) ns.db.settings.deaths.jokes = v end, 24,
        function() end)
    Check("Post my deaths to Discord",
        function() return ns.db.settings.deaths.relay end,
        function(v) ns.db.settings.deaths.relay = v end, nil,
        function(v) ns.SetDeathRelay(v) end)

    panel:SetScript("OnShow", RefreshSettings)
    -- Lock/unlock can also change via slash commands while the panel is open.
    ns.RefreshSettingsPanel = RefreshSettings
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local function Build()
    frame = CreateFrame("Frame", "FriendProgressFrame", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    S.Solid(frame, "BACKGROUND", S.C.bg):SetAllPoints()
    S.Edge(frame, S.C.line)
    frame:SetPoint("CENTER")
    local pos = ns.db.settings.windowPos
    if pos then
        frame:ClearAllPoints()
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.settings.windowPos = { point, relPoint, x, y }
    end)
    frame:SetScript("OnHide", S.HideMenu)
    frame:Hide()
    tinsert(UISpecialFrames, "FriendProgressFrame")   -- Escape closes it

    -- Title bar, sidebar and footer panels
    local bar = S.Solid(frame, "BACKGROUND", S.C.panel)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_H)
    local barRule = S.Solid(frame, "BORDER", S.C.line)
    barRule:SetPoint("TOPLEFT", 1, -(TITLE_H + 1))
    barRule:SetPoint("TOPRIGHT", -1, -(TITLE_H + 1))
    barRule:SetHeight(1)

    local side = S.Solid(frame, "BACKGROUND", S.C.panel)
    side:SetPoint("TOPLEFT", 1, -(TITLE_H + 2))
    side:SetPoint("BOTTOMLEFT", 1, FOOT_H)
    side:SetWidth(RIGHT_X - 14)
    local sideRule = S.Solid(frame, "BORDER", S.C.line)
    sideRule:SetPoint("TOPLEFT", side, "TOPRIGHT")
    sideRule:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT")
    sideRule:SetWidth(1)

    local foot = S.Solid(frame, "BACKGROUND", S.C.panel)
    foot:SetPoint("BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", -1, 1)
    foot:SetHeight(FOOT_H - 1)
    local footRule = S.Solid(frame, "BORDER", S.C.line)
    footRule:SetPoint("BOTTOMLEFT", 1, FOOT_H)
    footRule:SetPoint("BOTTOMRIGHT", -1, FOOT_H)
    footRule:SetHeight(1)

    local title = S.Font(frame, 14, S.C.fg)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("FriendProgress")
    local version = S.Font(frame, 11, S.C.muted)
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    version:SetText("v" .. ns.VERSION)
    local close = S.Button(frame, "X", 26, 22, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -5)

    -- Content panel behind the tab body
    local content = S.Panel(frame, S.C.panel, S.C.line)
    content:SetFrameLevel(frame:GetFrameLevel() + 1)
    content:SetPoint("TOPLEFT", RIGHT_X - 6, -(TOP_Y + 28))
    content:SetPoint("BOTTOMRIGHT", -10, FOOT_H + 6)

    BuildGroupDropdown()

    local listScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 12, -(TOP_Y + 32))
    listScroll:SetPoint("BOTTOMLEFT", 12, FOOT_H + 6)
    listScroll:SetWidth(LIST_W)
    frame.listContent = CreateFrame("Frame", nil, listScroll)
    frame.listContent:SetSize(LIST_W, 1)
    listScroll:SetScrollChild(frame.listContent)

    frame.emptyList = S.Font(frame, 12, S.C.muted)
    frame.emptyList:SetPoint("TOPLEFT", 16, -(TOP_Y + 40))
    frame.emptyList:SetWidth(LIST_W - 10)
    frame.emptyList:SetJustifyH("LEFT")
    frame.emptyList:SetText("Nobody here yet. Right-click a character in \"Everyone\" to add them to a group.")

    -- Tabs size to their labels, which UI skins with larger fonts can make wider.
    local tabX = RIGHT_X
    for _, t in ipairs(TABS) do
        local b = S.Tab(frame, t[2])
        local w = math.max(70, math.ceil(b:GetFontString():GetStringWidth()) + 24)
        b:SetSize(w, 24)
        b:SetPoint("TOPLEFT", tabX, -TOP_Y)
        tabX = tabX + w + 4
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
    search:SetPoint("TOPLEFT", RIGHT_X + 8, -(TOP_Y + 34))
    search:SetAutoFocus(false)
    if search.Instructions then search.Instructions:SetText("Who can craft...?") end
    -- Wait for a pause in typing; each redraw scans every friend's recipes.
    local searchToken = 0
    search:HookScript("OnTextChanged", function()
        searchToken = searchToken + 1
        local token = searchToken
        C_Timer.After(0.2, function()
            if token == searchToken then ns.RefreshUI() end
        end)
    end)
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
    body:SetScript("OnHyperlinkEnter", LinkEnter)
    body:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    body:SetScript("OnHyperlinkClick", LinkClick)
    bodyText = S.Font(body, BODY_SIZE, S.C.fg)
    bodyText:SetPoint("TOPLEFT", 4, -4)
    bodyText:SetWidth(bodyW - 10)
    bodyText:SetJustifyH("LEFT")
    bodyText:SetJustifyV("TOP")
    bodyText:SetSpacing(3)

    -- Virtual list: only the visible lines exist as frames, so long recipe and bag
    -- lists stay cheap to redraw. Falls back to the plain scroll frame above on error.
    legacyBody = not pcall(function()
        local box = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
        local bar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
        bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)

        -- An invisible FontString of the same width measures how tall each line wraps.
        local measure = S.Font(frame, BODY_SIZE, S.C.fg)
        measure:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        measure:SetWidth(bodyW - 8)
        measure:SetSpacing(3)
        measure:SetAlpha(0)

        local view = CreateScrollBoxListLinearView()
        view:SetElementExtentCalculator(function(_, text)
            measure:SetText(text)
            return math.max(14, measure:GetStringHeight() + 3)
        end)
        view:SetElementInitializer("Frame", function(row, text)
            if not row.text then
                row.text = S.Font(row, BODY_SIZE, S.C.fg)
                row.text:SetPoint("TOPLEFT", 4, 0)
                row.text:SetPoint("TOPRIGHT", -4, 0)
                row.text:SetJustifyH("LEFT")
                row.text:SetJustifyV("TOP")
                row.text:SetSpacing(3)
                row:SetHyperlinksEnabled(true)
                row:SetScript("OnHyperlinkEnter", LinkEnter)
                row:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
                row:SetScript("OnHyperlinkClick", LinkClick)
            end
            row.text:SetText(text)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
        frame.listBox, frame.listBar = box, bar
    end)

    -- The content panel is a frame too; make sure the text frames draw above it.
    local above = content:GetFrameLevel() + 5
    frame.bodyScroll:SetFrameLevel(above)
    if frame.listBox then
        frame.listBox:SetFrameLevel(above)
        frame.listBar:SetFrameLevel(above + 1)
    end

    local sync = S.Button(frame, "Sync now", 100, 24, function() SlashCmdList.FRIENDPROGRESS("sync") end)
    sync:SetPoint("BOTTOMRIGHT", -12, 8)

    local sharing = S.Tab(frame, "Sharing...")
    sharing:SetSize(100, 24)
    sharing:SetPoint("RIGHT", sync, "LEFT", -6, 0)
    sharing:SetScript("OnClick", function()
        showSettings = not showSettings
        ns.RefreshUI()
    end)
    frame.sharingButton = sharing

    BuildSettings()

    local hint = S.Font(frame, 11, S.C.muted)
    hint:SetPoint("BOTTOMLEFT", 16, 14)
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
    if menuStale then
        menuStale = false
        frame.groupDropdown:GenerateMenu()   -- updates the dropdown's label
    end

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
        b.mark:SetShown(key == selected)
        b:Show()
    end
    for i = #keys + 1, #listButtons do listButtons[i]:Hide() end
    frame.listContent:SetHeight(math.max(1, #keys * 36))
    frame.emptyList:SetShown(#keys == 0)

    for key, b in pairs(tabButtons) do b:SetSelected(not showSettings and key == tab) end
    frame.sharingButton:SetSelected(showSettings)
    frame.settingsPanel:SetShown(showSettings)
    local useList = frame.listBox and not legacyBody
    frame.bodyScroll:SetShown(not showSettings and not useList)
    if frame.listBox then
        frame.listBox:SetShown(not showSettings and useList)
        frame.listBar:SetShown(not showSettings and useList)
    end
    local searching = tab == "prof" and not showSettings
    frame.search:SetShown(searching)
    if showSettings then return end

    -- Make room for the search box on the Professions tab.
    frame.bodyScroll:ClearAllPoints()
    frame.bodyScroll:SetPoint("TOPLEFT", RIGHT_X, searching and -(TOP_Y + 58) or -(TOP_Y + 32))
    frame.bodyScroll:SetPoint("BOTTOMRIGHT", -32, FOOT_H + 12)
    if frame.listBox then
        frame.listBox:ClearAllPoints()
        frame.listBox:SetPoint("TOPLEFT", RIGHT_X, searching and -(TOP_Y + 58) or -(TOP_Y + 32))
        frame.listBox:SetPoint("BOTTOMRIGHT", -32, FOOT_H + 12)
    end

    local query = searching and strtrim(frame.search:GetText() or "") or ""
    local lines
    if query ~= "" then
        lines = RenderSearch(query, keys)
    else
        local c = selected and ns.db.chars[selected]
        lines = c and render[tab](c, selected) or { "No characters to show." }
    end
    if useList then
        local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
        frame.listBox:SetDataProvider(CreateDataProvider(lines), retain)
    else
        bodyText:SetText(concat(lines, "\n"))
        body:SetHeight(bodyText:GetStringHeight() + 8)
    end
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

function ns.ShowTab(name)
    if not frame then Build() end
    tab, showSettings = name, false
    if frame:IsShown() then ns.RefreshUI() else frame:Show() end
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
ns:Listen("GROUPS_CHANGED", function()
    menuStale = true
    QueueRefresh()
end)
ns:On("GET_ITEM_INFO_RECEIVED", QueueRefresh)
