-- PartyXP: an always-on-screen box with an XP bar for you and each party member.
-- Others' XP comes from their FriendProgress (see ns.SendLiveXP in Comm.lua);
-- the game itself only exposes the player's own XP.
local _, ns = ...

local WIDTH, ROW_H, PAD = 210, 30, 6
local BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local S = ns.Skin

local box
local rows = {}

local function Settings() return ns.db.settings.partyXP end

-- Inside instances some yes/no answers can come back secret and can't be tested; treat as "no".
local function Yes(v)
    if issecretvalue and issecretvalue(v) then return false end
    return v and true or false
end

-- In a raid, party1-4 are the members of your own subgroup.
local function Units()
    local units = { "player" }
    for i = 1, 4 do
        if Yes(UnitExists("party" .. i)) then units[#units + 1] = "party" .. i end
    end
    return units
end

local function ApplyPosition()
    box:ClearAllPoints()
    local pos = Settings().pos
    if pos then
        box:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        box:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -220)
    end
end

local function Build()
    box = CreateFrame("Frame", "FriendProgressPartyXP", UIParent)
    box:SetSize(WIDTH, ROW_H + PAD * 2)
    box:SetFrameStrata("LOW")
    box:SetClampedToScreen(true)
    box:SetMovable(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", box.StartMoving)
    box:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().pos = { point, relPoint, x, y }
    end)

    box.bg = box:CreateTexture(nil, "BACKGROUND")
    box.bg:SetAllPoints()
    box.edge = S.Edge(box, S.C.line)

    box.hint = S.Font(box, 11, S.C.muted)
    box.hint:SetPoint("BOTTOM", box, "TOP", 0, 3)
    box.hint:SetText("Party XP: drag to move, then /fp lock")

    ApplyPosition()
end

local function Row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, box)
    r:SetSize(WIDTH - PAD * 2, ROW_H - 2)
    r:SetPoint("TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)

    r.level = S.Font(r, 11, S.C.muted)
    r.level:SetPoint("TOPRIGHT")
    r.name = S.Font(r, 12, S.C.fg)
    r.name:SetPoint("TOPLEFT")
    r.name:SetPoint("RIGHT", r.level, "LEFT", -4, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    -- Rested XP sits behind the main bar, like Blizzard's XP bar.
    r.rested = CreateFrame("StatusBar", nil, r)
    r.rested:SetPoint("BOTTOMLEFT")
    r.rested:SetPoint("BOTTOMRIGHT")
    r.rested:SetHeight(12)
    r.rested:SetStatusBarTexture(BAR_TEXTURE)
    r.rested:SetStatusBarColor(0.25, 0.5, 0.85, 0.45)
    r.bg = r.rested:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(S.C.bg.r, S.C.bg.g, S.C.bg.b, 0.9)

    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetAllPoints(r.rested)
    r.bar:SetFrameLevel(r.rested:GetFrameLevel() + 1)
    r.bar:SetStatusBarTexture(BAR_TEXTURE)
    r.bar:SetStatusBarColor(S.C.accent.r, S.C.accent.g, S.C.accent.b)

    r.text = S.Font(r.bar, 10, S.C.fg, "OUTLINE")
    r.text:SetPoint("CENTER")

    rows[i] = r
    return r
end

local function SetBars(r, value, max, rested)
    r.bar:SetMinMaxValues(0, max)
    r.bar:SetValue(value)
    r.rested:SetMinMaxValues(0, max)
    r.rested:SetValue(math.min(value + rested, max))
end

local function Fill(r, unit)
    local first, realm = UnitName(unit)
    local key = first and ns.FullName(first, realm ~= "" and realm or nil)
    -- On WoW Forever that's the full two-part name; elsewhere drop the realm.
    local name = key and Ambiguate(key, "short") or first
    local _, class = UnitClass(unit)
    local d
    if unit == "player" or Yes(UnitIsUnit(unit, "player")) then
        d = { level = UnitLevel("player"), xp = UnitXP("player"), xpMax = UnitXPMax("player"),
              rested = GetXPExhaustion() or 0 }
    else
        d = key and ns.liveXP[key]
    end

    r.name:SetText(ns.ClassColored(name or "?", class))
    local level = d and d.level or UnitLevel(unit)
    r.level:SetText("Lvl " .. ((level and level > 0) and level or "??"))

    if d and d.xpMax and d.xpMax > 0 then
        SetBars(r, d.xp, d.xpMax, d.rested or 0)
        r.text:SetFormattedText("%d%%  (%s to go)", math.floor(d.xp / d.xpMax * 100),
            BreakUpLargeNumbers and BreakUpLargeNumbers(d.xpMax - d.xp) or (d.xpMax - d.xp))
    elseif d then
        SetBars(r, 1, 1, 0)
        r.text:SetText("Max level")
    else
        SetBars(r, 0, 1, 0)
        r.text:SetText("|cff9a9ea6no FriendProgress|r")
    end
end

function ns.RefreshPartyXP()
    if not ns.db then return end
    local s = Settings()
    local locked = ns.db.settings.locked
    local units = Units()
    -- Solo, the box hides itself, unless unlocked so it can be positioned.
    if not s.enabled or (#units == 1 and locked) then
        if box then box:Hide() end
        return
    end
    if not box then Build() end

    box:EnableMouse(not locked)   -- locked = click-through
    box.hint:SetShown(not locked)
    if locked then
        box.bg:SetColorTexture(S.C.panel.r, S.C.panel.g, S.C.panel.b, 0.8)
    else
        box.bg:SetColorTexture(S.C.accent.r, S.C.accent.g, S.C.accent.b, 0.25)
    end

    for i, unit in ipairs(units) do
        local r = Row(i)
        Fill(r, unit)
        r:Show()
    end
    for i = #units + 1, #rows do rows[i]:Hide() end
    box:SetHeight(#units * ROW_H + PAD * 2 - 2)
    box:Show()
end

function ns.ResetPartyXPPosition()
    Settings().pos = nil
    if box then ApplyPosition() end
    ns.RefreshPartyXP()
end

local function Refresh() ns.RefreshPartyXP() end
ns:Listen("LOGIN", Refresh)
ns:Listen("LIVE_XP", Refresh)
ns:On("GROUP_ROSTER_UPDATE", Refresh)
ns:On("PLAYER_ENTERING_WORLD", Refresh)
ns:On("PLAYER_XP_UPDATE", Refresh)
ns:On("UPDATE_EXHAUSTION", Refresh)
ns:OnUnit("UNIT_LEVEL", Refresh, "player", "party1", "party2", "party3", "party4")
ns:OnUnit("UNIT_NAME_UPDATE", Refresh, "player", "party1", "party2", "party3", "party4")
