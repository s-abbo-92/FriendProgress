-- Deaths: a Hardcore-style death log. When you die, the hit that killed you
-- is broadcast to everyone you sync with; they get a raid-warning style alert
-- and every death is kept in the Deaths tab.
--
-- Discord relay: addons can't reach the internet, so each player who wants
-- their deaths posted installs the relay (discord\Install.cmd) and turns on
-- /fp discord. Their addon then queues each of their own deaths as a "FPDEATH;"
-- line in FriendProgressDB.relayQueue; once WoW writes the saved variables file,
-- the relay (discord\DeathRelay.ps1) posts the new lines.
local _, ns = ...

local MAX_LOG = 300
local LAST_HIT_WINDOW = 15     -- seconds; older hits don't count as the killer
local RELAY_TAG = "FPDEATH"
local RELAY_VERSION = 2

-- How environmental deaths are worded (see FallbackHit for how we detect them).
local ENVIRONMENT = {
    Falling = "fell to their death",
    Drowning = "drowned",
    Fatigue = "died of fatigue",
    Fire = "burned to death",
    Lava = "died in lava",
    Slime = "died in slime",
}

local function Settings() return ns.db.settings.deaths end

-- Fields travel in "|" and ";" separated messages and the relay reads them out of
-- quoted Lua strings in the saved variables, so strip separators, quotes and backslashes.
local function Clean(s, max)
    s = tostring(s or ""):gsub("[|;\"\\]", "")
    return s:sub(1, max or 60)
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
-- d = { name, class, level, zone, subzone, killer, klevel, ability, damage, t }
-- klevel -1 means a skull-level mob.
function ns.DeathText(d, plain)
    local name = Ambiguate(d.name, "short")
    if not plain then
        local color = d.class and RAID_CLASS_COLORS[d.class]
        if color and color.colorStr then name = "|c" .. color.colorStr .. name .. "|r" end
    end
    local className = d.class and LOCALIZED_CLASS_NAMES_MALE[d.class] or ""
    local who = ("%s (level %d %s)"):format(name, d.level or 0, className):gsub(" %)", ")")

    local where = ""
    if d.zone and d.zone ~= "" then
        local sub = d.subzone
        where = (sub and sub ~= "" and sub ~= d.zone) and (" in " .. sub .. ", " .. d.zone) or (" in " .. d.zone)
    end

    local killer, ability = d.killer or "", d.ability or ""
    if killer ~= "" and d.klevel then
        killer = killer .. (d.klevel < 0 and " (level ??)" or (" (level " .. d.klevel .. ")"))
    end
    local dmg = d.damage and d.damage > 0 and d.damage or nil

    if killer ~= "" and ability ~= "" and ability ~= "Melee" then
        return ("%s was killed by %s with %s%s%s."):format(who, killer, ability,
            dmg and (" for " .. dmg .. " damage") or "", where)
    elseif killer ~= "" and ability == "Melee" then
        return ("%s was killed by %s%s%s."):format(who, killer,
            dmg and (" with a melee hit for " .. dmg .. " damage") or "", where)
    elseif killer ~= "" then
        return ("%s was killed by %s%s%s."):format(who, killer,
            dmg and (" (last hit " .. dmg .. " damage)") or "", where)
    elseif ENVIRONMENT[ability] then
        return ("%s %s%s%s."):format(who, ENVIRONMENT[ability], dmg and (" (" .. dmg .. " damage)") or "", where)
    elseif ability ~= "" then
        return ("%s was killed by %s%s%s."):format(who, ability, dmg and (" for " .. dmg .. " damage") or "", where)
    end
    return ("%s died%s%s."):format(who, dmg and (" (last hit " .. dmg .. " damage)") or "", where)
end

-- A joke for the death, from DeathQuips.lua (generated from the relay's DeathQuips.json;
-- this follows the same rules as Get-Quip in discord\DeathRelay.ps1).
local ENV_CATEGORY = { Falling = "falling", Drowning = "drowning", Fatigue = "fatigue",
    Fire = "fire", Lava = "fire", Slime = "fire" }

function ns.DeathQuip(d, test)
    local quips = ns.DeathQuips
    if not quips then return nil end
    local level, klevel, killer = d.level or 0, d.klevel, d.killer or ""
    local count = 0
    for _, e in ipairs(ns.db.deaths) do
        if e.name == d.name then count = count + 1 end
    end

    -- Most specific first; the first category with usable lines wins.
    local cats = {}
    if test then cats[#cats + 1] = "test" end
    if ENV_CATEGORY[d.ability or ""] then cats[#cats + 1] = ENV_CATEGORY[d.ability] end
    if killer ~= "" then
        local lower = killer:lower()
        for _, k in ipairs(quips.killers) do
            local matched = false
            for _, pattern in ipairs(k[2]) do
                if lower:find(pattern) then matched = true break end
            end
            if matched then cats[#cats + 1] = k[1] break end
        end
    end
    if klevel and klevel < 0 then cats[#cats + 1] = "skull" end
    if klevel and klevel > 0 and level - klevel >= 4 then cats[#cats + 1] = "outlevelled" end
    if count >= 3 then cats[#cats + 1] = "veteran" end
    if level <= 5 then cats[#cats + 1] = "lowlevel" end
    if level >= 60 then cats[#cats + 1] = "maxlevel" end
    cats[#cats + 1] = "generic"

    local values = {
        name = Ambiguate(d.name, "short"), level = level, count = count,
        killer = killer ~= "" and killer or nil, klevel = klevel,
        zone = (d.zone or "") ~= "" and d.zone or nil, ability = (d.ability or "") ~= "" and d.ability or nil,
    }
    for _, cat in ipairs(cats) do
        -- Skip lines whose placeholders we can't fill (e.g. {killer} after a fall).
        local usable = {}
        for _, line in ipairs(quips.lines[cat] or {}) do
            local ok = true
            for key in line:gmatch("{(%w+)}") do
                if values[key] == nil then ok = false break end
            end
            if ok then usable[#usable + 1] = line end
        end
        if #usable > 0 then
            return (usable[math.random(#usable)]:gsub("{(%w+)}", values))
        end
    end
end

---------------------------------------------------------------------------
-- Log, alerts and relay
---------------------------------------------------------------------------
local function Known(d)
    for _, e in ipairs(ns.db.deaths) do
        if e.name == d.name and e.t == d.t then return true end
    end
    return false
end

local QUIP_COLOR = { r = 0.8, g = 0.8, b = 0.8 }

local function Alert(d, test)
    if not Settings().alerts then return end
    local text = ns.DeathText(d)
    RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo.RAID_WARNING)
    ns.Print(text)
    local quip = Settings().jokes and ns.DeathQuip(d, test)
    if quip then
        RaidNotice_AddMessage(RaidWarningFrame, quip, QUIP_COLOR)
        ns.Print("|cffcccccc" .. quip .. "|r")
    end
    if Settings().sound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
end

-- The relay reads these from the saved variables file, which WoW only writes on
-- /reload, logout or exit. So after a death we reload when you release spirit.
local RELAY_QUEUE_MAX = 20
local unsaved = false   -- a death was queued since the saved variables were last written
local reportPending = false   -- we died and the report (0.5s later) hasn't been built yet

local function Relay(d, test)
    if not Settings().relay or not ns.me then return end
    local line = table.concat({
        RELAY_TAG, RELAY_VERSION, test and "test" or "death",
        Clean(d.name), d.level or 0, Clean(d.class), Clean(d.zone), Clean(d.killer), Clean(d.ability), d.t,
        d.damage or "", d.klevel or "", Clean(d.subzone),
    }, ";")
    local queue = ns.db.relayQueue
    queue[#queue + 1] = line
    while #queue > RELAY_QUEUE_MAX do table.remove(queue, 1) end
    unsaved = true
end

-- A reload empties the outgoing message queue, so wait until the death has been
-- reported and sent to friends first (at most ~10s). When nothing is waiting this
-- reloads at once, inside the click that triggered it.
local function ReloadWhenSent()
    local tries = 0
    local function Check()
        tries = tries + 1
        if (reportPending or not ns.SendQueueEmpty()) and tries <= 50 then
            C_Timer.After(0.2, Check)
            return
        end
        ReloadUI()
    end
    Check()
end

-- Release Spirit is a click, so reloading from it is allowed.
hooksecurefunc("RepopMe", function()
    if (unsaved or reportPending) and Settings().relay then ReloadWhenSent() end
end)

local function Record(d)
    if Known(d) then return false end
    table.insert(ns.db.deaths, 1, d)
    for i = #ns.db.deaths, MAX_LOG + 1, -1 do ns.db.deaths[i] = nil end
    ns:Fire("DATA_UPDATED", d.name, "deaths")
    return true
end

---------------------------------------------------------------------------
-- Our own deaths. WoW Forever doesn't let addons register for the combat log
-- (COMBAT_LOG_EVENT_UNFILTERED is protected), so the killing blow is pieced together:
--   UNIT_COMBAT gives each hit's damage and school, but not who did it;
--   the killer is the hostile unit that was targeting us;
--   the ability is the killer's spell cast just before the hit, else melee for physical hits;
--   falling, drowning and fatigue come from watching IsFalling() and the breath/fatigue bars.
---------------------------------------------------------------------------
local SCHOOL_PHYSICAL = 1
local CAST_BEFORE_HIT = 3     -- seconds a spell cast can precede its damage (travel time)
local ENV_WINDOW = 2          -- seconds before death a fall/drown still counts

local loginTime = math.huge
local castsSeen = 0           -- for /fp deaths debug

local lastWound      -- { amount, school, at }
local lastAttacker   -- { name, level, guid, at }
local lastCast = {}  -- [ unit GUID ] = { name, at }
local lastFall, lastEnv = 0, nil   -- lastEnv = { ability, at }

-- WoW Forever can hand combat values (UNIT_COMBAT damage, sometimes unit info) over as
-- "secret" values, which error when concatenated, compared, used in maths or as table
-- keys (and tonumber passes them through). Treat them as unknown so a death is still
-- reported, just without that detail.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- For yes/no answers (UnitExists, UnitCanAttack, ...): a secret answer can't be tested,
-- so it counts as "no" and the attacker simply stays unknown.
local function Yes(v)
    if issecretvalue and issecretvalue(v) then return false end
    return v and true or false
end

local ATTACKER_UNITS = { "target", "mouseover", "focus", "pettarget" }
for i = 1, 40 do ATTACKER_UNITS[#ATTACKER_UNITS + 1] = "nameplate" .. i end

local function FindAttacker()
    for _, unit in ipairs(ATTACKER_UNITS) do
        if Yes(UnitExists(unit)) and Yes(UnitCanAttack("player", unit)) and not Yes(UnitIsDead(unit))
            and Yes(UnitIsUnit(unit .. "target", "player")) then
            return { name = Plain(UnitName(unit)), level = Plain(UnitLevel(unit)), guid = Plain(UnitGUID(unit)),
                at = GetTime() }
        end
    end
end

ns:OnUnit("UNIT_COMBAT", function(unit, action, _, amount, school)
    action = Plain(action)
    if unit ~= "player" or action ~= "WOUND" then return end
    lastWound = { amount = tonumber(Plain(amount)), school = tonumber(Plain(school)), at = GetTime() }
    lastAttacker = FindAttacker() or lastAttacker
end, "player")

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return (GetSpellInfo(id))
end

-- Fires once per unit token showing the caster (target, nameplate3, ...); same result each time.
-- Only the units an attacker could be found on, not every party and raid member.
ns:OnUnit("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit == "player" or not Yes(UnitCanAttack("player", unit)) then return end
    spellID = Plain(spellID)
    local guid, name = Plain(UnitGUID(unit)), spellID and Plain(SpellName(spellID))
    if guid and name then
        lastCast[guid] = { name = name, at = GetTime() }
        castsSeen = castsSeen + 1
    end
end, unpack(ATTACKER_UNITS))

-- Leaving combat: forget old casts so the table doesn't grow all session.
ns:On("PLAYER_REGEN_ENABLED", function() lastCast = {} end)

-- Cheap enough at 5x a second: one IsFalling call and up to three mirror timer lookups.
C_Timer.NewTicker(0.2, function()
    if Yes(IsFalling()) then lastFall = GetTime() end
    for i = 1, MIRRORTIMER_NUMTIMERS or 3 do
        local timer = GetMirrorTimerInfo(i)
        if (timer == "BREATH" or timer == "EXHAUSTION") and GetMirrorTimerProgress(timer) <= 0 then
            lastEnv = { ability = timer == "BREATH" and "Drowning" or "Fatigue", at = GetTime() }
        end
    end
end)

local function Fresh(t, window)
    return t and GetTime() - t.at <= (window or LAST_HIT_WINDOW) and t or nil
end

-- Best guess at the killing blow without the combat log.
local function FallbackHit(attacker)
    local wound = Fresh(lastWound)
    local hit = { amount = wound and wound.amount }
    local env = Fresh(lastEnv, ENV_WINDOW)
    if env then
        hit.ability = env.ability
    elseif (wound and wound.at - lastFall >= 0 and wound.at - lastFall <= 0.5)
        or (not attacker and GetTime() - lastFall <= ENV_WINDOW) then
        -- Fall damage lands the moment we stop falling (the ticker samples every 0.2s).
        hit.ability = "Falling"
    elseif attacker then
        hit.killer, hit.level = attacker.name, attacker.level
        local cast = lastCast[attacker.guid]
        if cast and wound and wound.at - cast.at <= CAST_BEFORE_HIT and wound.at - cast.at >= -0.5 then
            hit.ability = cast.name
        elseif wound and wound.school == SCHOOL_PHYSICAL then
            hit.ability = "Melee"
        end
    end
    return hit
end

-- attacker: the killer, found the moment we died (mobs drop their target right after).
local function ReportOwnDeath(attacker)
    local hit = FallbackHit(attacker)
    local _, class = UnitClass("player")
    local d = {
        name = ns.me, class = class, level = UnitLevel("player"),
        zone = GetRealZoneText() or "", subzone = GetSubZoneText() or "",
        killer = hit.killer or "", klevel = hit.level,
        ability = hit.ability or "", damage = tonumber(hit.amount),
        t = GetServerTime(),
    }
    Record(d)
    Relay(d)
    if ns.db.settings.share.deaths then
        ns.Broadcast(table.concat({
            "K", d.t, d.level, Clean(d.class), Clean(d.zone), Clean(d.killer), Clean(d.ability),
            d.damage or "", d.klevel or "", Clean(d.subzone),
        }, "|"), true)
    end
    reportPending = false
end

ns:On("PLAYER_DEAD", function()
    -- Logging in while dead can fire this too; that death was already reported.
    if not ns.me or GetTime() - loginTime < 5 then return end
    local attacker = FindAttacker() or Fresh(lastAttacker)
    reportPending = true
    -- Give the killing hit's UNIT_COMBAT and the falling/breath ticker a moment to catch up.
    C_Timer.After(0.5, function() ReportOwnDeath(attacker) end)
end)

ns:Listen("LOGIN", function()
    loginTime = GetTime()
end)

---------------------------------------------------------------------------
-- Friends' deaths
-- K|t|level|class|zone|killer|ability|damage|killerLevel|subzone
-- (the last three were added later and may be missing)
---------------------------------------------------------------------------
ns.OnMessage("K", function(sender, rest)
    local t, level, class, zone, killer, ability, damage, klevel, subzone = strsplit("|", rest)
    t, level = tonumber(t), tonumber(level)
    if not t or not level then return end
    local Text = ns.CleanText
    local d = {
        name = sender, class = (class and class:match("^%u+$")) or nil, level = level,
        zone = Text(zone), subzone = Text(subzone), killer = Text(killer), klevel = tonumber(klevel),
        ability = Text(ability), damage = tonumber(damage), t = t,
    }
    if not Record(d) then return end   -- already heard it via another channel
    Alert(d)
end)

---------------------------------------------------------------------------
-- Settings hooks and slash command helpers
---------------------------------------------------------------------------
function ns.SetDeathRelay(enabled)
    Settings().relay = enabled
    if enabled then
        ns.Print("Your deaths will be posted to Discord (needs discord\\Install.cmd run on this PC). "
            .. "Releasing spirit reloads your UI to send them. Test with /fp deaths test.")
    else
        ns.Print("Your deaths won't be posted to Discord.")
    end
end

-- Shows a made-up death as an alert and sends it to the relay (marked as a test).
-- Runs from a slash command, so reloading here is allowed.
function ns.TestDeath()
    local _, class = UnitClass("player")
    local d = {
        name = ns.me, class = class, level = UnitLevel("player"),
        zone = GetRealZoneText() or "", subzone = GetSubZoneText() or "",
        killer = "Hogger", klevel = 11, ability = "Melee", damage = 87, t = GetServerTime(),
    }
    local alerts = Settings().alerts
    Settings().alerts = true
    Alert(d, true)
    Settings().alerts = alerts
    if Settings().relay then
        Relay(d, true)
        ReloadWhenSent()
    end
end

-- What death detection has seen, for when a death comes out wrong.
function ns.DeathDebug()
    local now = GetTime()
    ns.Print("Death detection (what a death right now would be based on):")
    ns.Print("  last hit taken: " .. (lastWound and ("%s dmg (school %s) %ds ago"):format(
        tostring(lastWound.amount), tostring(lastWound.school), now - lastWound.at) or "none"))
    ns.Print("  last attacker: " .. (lastAttacker and ("%s (level %s) %ds ago"):format(
        tostring(lastAttacker.name), tostring(lastAttacker.level), now - lastAttacker.at) or "none"))
    ns.Print(("  enemy spell casts seen: %d; last fall %s; last drown/fatigue %s"):format(castsSeen,
        lastFall > 0 and ("%ds ago"):format(now - lastFall) or "never",
        lastEnv and ("%s %ds ago"):format(lastEnv.ability, now - lastEnv.at) or "never"))
end
