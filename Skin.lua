-- Skin: the addon's flat dark look. Charcoal panels with 1px hairline borders,
-- muted secondary text, and a single accent colour for selection and hover.
-- Everything is built from plain textures and fonts, so no art files are needed.
local _, ns = ...

local S = {}
ns.Skin = S

local function C(hex)
    return { r = tonumber(hex:sub(1, 2), 16) / 255, g = tonumber(hex:sub(3, 4), 16) / 255, b = tonumber(hex:sub(5, 6), 16) / 255 }
end

S.C = {
    bg = C("191b1d"), panel = C("1e2022"), raised = C("272a2d"), line = C("373b40"),
    fg = C("f0f1f3"), muted = C("9a9ea6"), accent = C("33d999"),
}
S.MUTED_HEX, S.ACCENT_HEX = "9a9ea6", "33d999"

local FONT_FLAGS = ""

function S.Solid(parent, layer, c, alpha)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(c.r, c.g, c.b, alpha or 1)
    return t
end

function S.Font(parent, size, c, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, size, flags or FONT_FLAGS)
    c = c or S.C.fg
    fs:SetTextColor(c.r, c.g, c.b, 1)
    return fs
end

-- A 1px outline just inside the frame. Returns an object with :SetColor(c, alpha).
function S.Edge(frame, c, alpha)
    c = c or S.C.line
    local edges = {}
    for i = 1, 4 do edges[i] = frame:CreateTexture(nil, "BORDER") end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT", 0, -1); edges[3]:SetPoint("BOTTOMLEFT", 0, 1); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT", 0, -1); edges[4]:SetPoint("BOTTOMRIGHT", 0, 1); edges[4]:SetWidth(1)
    local edge = {}
    function edge.SetColor(_, color, a)
        for i = 1, 4 do edges[i]:SetColorTexture(color.r, color.g, color.b, a or 1) end
    end
    edge:SetColor(c, alpha)
    return edge
end

-- A flat panel: filled rectangle with a hairline border.
function S.Panel(parent, fill, border)
    local f = CreateFrame("Frame", nil, parent)
    S.Solid(f, "BACKGROUND", fill or S.C.panel):SetAllPoints()
    f.edge = S.Edge(f, border or S.C.line)
    return f
end

-- A flat button. Works with SetText, Enable/Disable and GetFontString like a normal one.
function S.Button(parent, text, w, h, onClick, name)
    local b = CreateFrame("Button", name, parent)
    b:SetSize(w, h)
    b.bg = S.Solid(b, "BACKGROUND", S.C.panel)
    b.bg:SetAllPoints()
    b.edge = S.Edge(b, S.C.line)
    local fs = S.Font(b, 12, S.C.fg)
    fs:SetPoint("CENTER")
    b:SetFontString(fs)
    b:SetText(text or "")
    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self.edge:SetColor(S.C.accent)
            self.bg:SetColorTexture(S.C.raised.r, S.C.raised.g, S.C.raised.b, 1)
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.edge:SetColor(self.selected and S.C.accent or S.C.line)
        self.bg:SetColorTexture(S.C.panel.r, S.C.panel.g, S.C.panel.b, 1)
    end)
    b:SetScript("OnDisable", function(self) self:GetFontString():SetTextColor(S.C.muted.r, S.C.muted.g, S.C.muted.b) end)
    b:SetScript("OnEnable", function(self)
        local c = self.restColor or S.C.fg
        self:GetFontString():SetTextColor(c.r, c.g, c.b)
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- A tab: a button that can be marked selected (accent border and tint).
function S.Tab(parent, text)
    local b = S.Button(parent, text, 70, 24)
    b.tint = S.Solid(b, "BACKGROUND", S.C.accent, 0.16)
    b.tint:SetAllPoints()
    b.tint:Hide()
    function b:SetSelected(on)
        self.selected = on
        self.tint:SetShown(on)
        self.edge:SetColor(on and S.C.accent or S.C.line)
        local c = on and S.C.fg or S.C.muted
        self.restColor = c
        self:GetFontString():SetTextColor(c.r, c.g, c.b)
    end
    b:SetSelected(false)
    return b
end

-- A flat checkbox. Use SetChecked/GetChecked and OnClick as with a CheckButton.
function S.Check(parent, size)
    size = size or 18
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(size, size)
    S.Solid(cb, "BACKGROUND", S.C.bg):SetAllPoints()
    cb.edge = S.Edge(cb, S.C.line)
    local mark = S.Solid(cb, "ARTWORK", S.C.accent)
    mark:SetPoint("TOPLEFT", 4, -4)
    mark:SetPoint("BOTTOMRIGHT", -4, 4)
    cb:SetCheckedTexture(mark)
    local checked = cb:GetCheckedTexture()
    checked:ClearAllPoints()
    checked:SetPoint("TOPLEFT", 4, -4)
    checked:SetPoint("BOTTOMRIGHT", -4, 4)
    cb:SetScript("OnEnter", function(self) self.edge:SetColor(S.C.accent) end)
    cb:SetScript("OnLeave", function(self) self.edge:SetColor(S.C.line) end)
    return cb
end

---------------------------------------------------------------------------
-- A flat popup menu, used instead of the stock dropdown menus.
-- items = list of { text, onClick, radio = true | checkbox = true, checked = bool,
--                   title = true, divider = true }
---------------------------------------------------------------------------
local menu, catcher
local menuRows = {}
local ROW_H, DIVIDER_H, MENU_PAD = 24, 9, 4

function S.HideMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
end

local function NewMenuRow()
    local r = CreateFrame("Button", nil, menu)
    r.hover = S.Solid(r, "BACKGROUND", S.C.accent, 0.14)
    r.hover:SetAllPoints()
    r.hover:Hide()
    r.box = S.Solid(r, "ARTWORK", S.C.line)
    r.box:SetSize(10, 10)
    r.box:SetPoint("LEFT", 10, 0)
    r.dot = S.Solid(r, "OVERLAY", S.C.accent)
    r.dot:SetSize(6, 6)
    r.dot:SetPoint("CENTER", r.box)
    r.text = S.Font(r, 13, S.C.fg)
    r.rule = S.Solid(r, "ARTWORK", S.C.line)
    r.rule:SetPoint("LEFT", 8, 0)
    r.rule:SetPoint("RIGHT", -8, 0)
    r.rule:SetHeight(1)
    r:SetScript("OnEnter", function(self) if self.clickable then self.hover:Show() end end)
    r:SetScript("OnLeave", function(self) self.hover:Hide() end)
    r:SetScript("OnClick", function(self)
        local it = self.item
        S.HideMenu()
        if it and it.onClick then it.onClick() end
    end)
    return r
end

local function BuildMenu()
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(1)
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", S.HideMenu)
    catcher:Hide()

    menu = S.Panel(UIParent, S.C.bg, S.C.line)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(10)
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:Hide()
end

-- Shows the menu under `anchor`, or at the cursor when atCursor is set.
-- Clicking the same anchor again closes it.
function S.ShowMenu(anchor, items, minWidth, atCursor)
    if not menu then BuildMenu() end
    if menu:IsShown() and menu.owner == anchor then
        S.HideMenu()
        return
    end
    menu.owner = anchor

    local hasMarks = false
    for _, it in ipairs(items) do
        if it.radio or it.checkbox then hasMarks = true end
    end
    local textX = hasMarks and 28 or 12

    local y, width = MENU_PAD, minWidth or 120
    for i, it in ipairs(items) do
        local r = menuRows[i] or NewMenuRow()
        menuRows[i] = r
        r.item = it
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -y)
        r:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -y)
        r.hover:Hide()
        r.rule:SetShown(it.divider == true)
        r.box:SetShown(it.radio == true or it.checkbox == true)
        r.dot:SetShown((it.radio or it.checkbox) and it.checked == true or false)
        r.text:SetShown(not it.divider)
        r.clickable = not it.divider and not it.title
        r:EnableMouse(r.clickable)
        if it.divider then
            r:SetHeight(DIVIDER_H)
            y = y + DIVIDER_H
        else
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT", it.title and 12 or textX, 0)
            r.text:SetText(it.text or "")
            local c = it.title and S.C.accent or S.C.fg
            r.text:SetTextColor(c.r, c.g, c.b)
            width = math.max(width, math.ceil(r.text:GetStringWidth()) + textX + 16)
            r:SetHeight(ROW_H)
            y = y + ROW_H
        end
        r:Show()
    end
    for i = #items + 1, #menuRows do menuRows[i]:Hide() end

    menu:SetSize(width + 2, y + MENU_PAD)
    menu:ClearAllPoints()
    if atCursor then
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
    else
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    end
    catcher:Show()
    menu:Show()
end
