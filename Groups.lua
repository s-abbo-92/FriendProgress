-- Groups: user-made friend groups, used to filter the character list.
-- Stored as db.groups = { { name = "Raid team", members = { ["Name-Realm"] = true } }, ... }
local ADDON, ns = ...

-- Built-in filters, shown above the custom groups. Keys start with "*" so they
-- can't clash with a group name.
ns.BUILTIN_FILTERS = {
    { key = "*all", label = "Everyone" },
    { key = "*mine", label = "My characters" },
    { key = "*others", label = "Friends" },
}

ns:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    ns.db.groups = ns.db.groups or {}
    ns.db.settings.activeGroup = ns.db.settings.activeGroup or "*all"
end)

function ns.GetGroup(name)
    for i, g in ipairs(ns.db.groups) do
        if g.name == name then return g, i end
    end
end

function ns.CreateGroup(name)
    name = name and strtrim(name) or ""
    if name == "" or name:sub(1, 1) == "*" or ns.GetGroup(name) then return nil end
    local g = { name = name, members = {} }
    table.insert(ns.db.groups, g)
    table.sort(ns.db.groups, function(a, b) return a.name:lower() < b.name:lower() end)
    return g
end

function ns.RenameGroup(old, new)
    new = new and strtrim(new) or ""
    local g = ns.GetGroup(old)
    if not g or new == "" or new:sub(1, 1) == "*" or ns.GetGroup(new) then return false end
    g.name = new
    if ns.db.settings.activeGroup == old then ns.db.settings.activeGroup = new end
    return true
end

function ns.DeleteGroup(name)
    local _, i = ns.GetGroup(name)
    if not i then return end
    table.remove(ns.db.groups, i)
    if ns.db.settings.activeGroup == name then ns.db.settings.activeGroup = "*all" end
end

function ns.ToggleGroupMember(name, key)
    local g = ns.GetGroup(name)
    if not g then return end
    g.members[key] = not g.members[key] or nil
end

-- Names of the custom groups a character belongs to.
function ns.GroupsOf(key)
    local names = {}
    for _, g in ipairs(ns.db.groups) do
        if g.members[key] then names[#names + 1] = g.name end
    end
    return names
end

function ns.ActiveFilterLabel()
    local active = ns.db.settings.activeGroup
    for _, f in ipairs(ns.BUILTIN_FILTERS) do
        if f.key == active then return f.label end
    end
    return active
end

-- Whether a character passes the currently selected filter.
function ns.PassesFilter(key)
    local active = ns.db.settings.activeGroup
    local c = ns.db.chars[key]
    if active == "*all" then return true end
    if active == "*mine" then return c and c.isMine or false end
    if active == "*others" then return not (c and c.isMine) end
    local g = ns.GetGroup(active)
    if not g then return true end   -- group was deleted elsewhere
    return g.members[key] or false
end

---------------------------------------------------------------------------
-- Dialogs. data = character key to add to a new group (optional).
---------------------------------------------------------------------------
local function EditBox(dialog)
    return dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
end

local function NameOK(dialog)
    local button = dialog.GetButton1 and dialog:GetButton1() or dialog.button1
    local text = strtrim(EditBox(dialog):GetText() or "")
    button:SetEnabled(text ~= "" and text:sub(1, 1) ~= "*" and not ns.GetGroup(text))
end

StaticPopupDialogs.FRIENDPROGRESS_NEW_GROUP = {
    text = "Name for the new friend group:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 32,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self) NameOK(self) end,
    EditBoxOnTextChanged = function(self) NameOK(self:GetParent()) end,
    OnAccept = function(self, key)
        local g = ns.CreateGroup(EditBox(self):GetText())
        if not g then return end
        if key then g.members[key] = true end
        ns.db.settings.activeGroup = g.name
        ns:Fire("GROUPS_CHANGED")
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        local button = dialog.GetButton1 and dialog:GetButton1() or dialog.button1
        if button:IsEnabled() then button:Click() end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

StaticPopupDialogs.FRIENDPROGRESS_RENAME_GROUP = {
    text = "Rename \"%s\" to:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 32,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self) NameOK(self) end,
    EditBoxOnTextChanged = function(self) NameOK(self:GetParent()) end,
    OnAccept = function(self, old)
        if ns.RenameGroup(old, EditBox(self):GetText()) then ns:Fire("GROUPS_CHANGED") end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        local button = dialog.GetButton1 and dialog:GetButton1() or dialog.button1
        if button:IsEnabled() then button:Click() end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

StaticPopupDialogs.FRIENDPROGRESS_DELETE_GROUP = {
    text = "Delete the friend group \"%s\"? Characters in it aren't affected.",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, name)
        ns.DeleteGroup(name)
        ns:Fire("GROUPS_CHANGED")
    end,
}

function ns.PromptNewGroup(key)
    StaticPopup_Show("FRIENDPROGRESS_NEW_GROUP", nil, nil, key)
end
function ns.PromptRenameGroup(name)
    StaticPopup_Show("FRIENDPROGRESS_RENAME_GROUP", name, nil, name)
end
function ns.PromptDeleteGroup(name)
    StaticPopup_Show("FRIENDPROGRESS_DELETE_GROUP", name, nil, name)
end
