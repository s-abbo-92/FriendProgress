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
local RECENT_HITS = 8          -- damage events kept for picking the killing blow
local RELAY_TAG = "FPDEATH"
local RELAY_VERSION = 2

-- Environmental damage types from the combat log.
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

---------------------------------------------------------------------------
-- Log, alerts and relay
---------------------------------------------------------------------------
local function Known(d)
    for _, e in ipairs(ns.db.deaths) do
        if e.name == d.name and e.t == d.t then return true end
    end
    return false
end

local function Alert(d)
    if not Settings().alerts then return end
    local text = ns.DeathText(d)
    RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo.RAID_WARNING)
    ns.Print(text)
    if Settings().sound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
end

-- The relay reads these from the saved variables file, which WoW only writes on
-- /reload, logout or exit. So after a death we reload when you release spirit.
local RELAY_QUEUE_MAX = 20
local unsaved = false   -- a death was queued since the saved variables were last written

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

-- Release Spirit is a click, so reloading from it is allowed.
hooksecurefunc("RepopMe", function()
    if unsaved and Settings().relay then ReloadUI() end
end)

local function Record(d)
    if Known(d) then return false end
    table.insert(ns.db.deaths, 1, d)
    for i = #ns.db.deaths, MAX_LOG + 1, -1 do ns.db.deaths[i] = nil end
    ns:Fire("DATA_UPDATED")
    return true
end

---------------------------------------------------------------------------
-- Our own deaths: remember recent hits, pick the killing blow on PLAYER_DEAD
---------------------------------------------------------------------------
local recent = {}          -- newest last: { killer, guid, ability, amount, overkill, at }
local lastDeathHits        -- copy of recent at our last death, for /fp deaths debug
local playerGUID
local loginTime = math.huge

-- "FALLING" or "Falling" -> "Falling"
local function EnvName(t)
    t = tostring(t or "")
    return t:sub(1, 1):upper() .. t:sub(2):lower()
end

-- What the combat log is doing, for /fp deaths debug.
local diag = { events = 0, toMe = 0 }

local function OnCombatLog(...)
    diag.events = diag.events + 1
    -- Older clients pass the fields as event arguments instead.
    local _, sub, _, srcGUID, srcName, _, _, destGUID, destName, _, _, a12, a13, a14, a15, a16
    if CombatLogGetCurrentEventInfo then
        _, sub, _, srcGUID, srcName, _, _, destGUID, destName, _, _, a12, a13, a14, a15, a16 =
            CombatLogGetCurrentEventInfo()
    else
        _, sub, _, srcGUID, srcName, _, _, destGUID, destName, _, _, a12, a13, a14, a15, a16 = ...
    end
    diag.last = ("%s: %s -> %s"):format(tostring(sub), tostring(srcName), tostring(destName))
    if destGUID ~= (playerGUID or UnitGUID("player")) then return end
    diag.toMe = diag.toMe + 1
    local hit
    if sub == "SWING_DAMAGE" then
        hit = { killer = srcName, guid = srcGUID, ability = "Melee", amount = a12, overkill = a13 }
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        hit = { ability = EnvName(a12), amount = a13, overkill = a14 }
    elseif sub:find("_DAMAGE$") or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
        -- SPELL_, SPELL_PERIODIC_, RANGE_ ... all share the spell prefix: id, name, school.
        hit = { killer = srcName, guid = srcGUID, ability = a13, amount = a15, overkill = a16 }
    elseif sub == "SPELL_INSTAKILL" then
        hit = { killer = srcName, guid = srcGUID, ability = a13 }
    end
    if not hit then return end
    hit.at = GetTime()
    recent[#recent + 1] = hit
    if #recent > RECENT_HITS then table.remove(recent, 1) end
end

-- A failing handler would otherwise stay silent; keep the error for the debug command.
ns:On("COMBAT_LOG_EVENT_UNFILTERED", function(...)
    local ok, err = pcall(OnCombatLog, ...)
    if not ok then diag.err = err end
end)

---------------------------------------------------------------------------
-- Fallback for clients that don't give addons the combat log (WoW Forever):
--   UNIT_COMBAT gives each hit's damage and school, but not who did it;
--   the killer is the hostile unit that was targeting us;
--   the ability is the killer's spell cast just before the hit, else melee for physical hits;
--   falling, drowning and fatigue come from watching IsFalling() and the breath/fatigue bars.
---------------------------------------------------------------------------
local SCHOOL_PHYSICAL = 1
local CAST_BEFORE_HIT = 3     -- seconds a spell cast can precede its damage (travel time)
local ENV_WINDOW = 2          -- seconds before death a fall/drown still counts

local lastWound      -- { amount, school, at }
local lastAttacker   -- { name, level, guid, at }
local lastCast = {}  -- [ unit GUID ] = { name, at }
local lastFall, lastEnv = 0, nil   -- lastEnv = { ability, at }

local ATTACKER_UNITS = { "target", "mouseover", "focus", "pettarget" }
for i = 1, 40 do ATTACKER_UNITS[#ATTACKER_UNITS + 1] = "nameplate" .. i end

local function FindAttacker()
    for _, unit in ipairs(ATTACKER_UNITS) do
        if UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit)
            and UnitIsUnit(unit .. "target", "player") then
            return { name = UnitName(unit), level = UnitLevel(unit), guid = UnitGUID(unit), at = GetTime() }
        end
    end
end

ns:On("UNIT_COMBAT", function(unit, action, _, amount, school)
    if unit ~= "player" or action ~= "WOUND" then return end
    lastWound = { amount = tonumber(amount), school = tonumber(school), at = GetTime() }
    lastAttacker = FindAttacker() or lastAttacker
end)

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return (GetSpellInfo(id))
end

-- Fires once per unit token showing the caster (target, nameplate3, ...); same result each time.
ns:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit == "player" or not UnitCanAttack("player", unit) then return end
    local guid, name = UnitGUID(unit), spellID and SpellName(spellID)
    if guid and name then
        lastCast[guid] = { name = name, at = GetTime() }
        diag.casts = (diag.casts or 0) + 1
    end
end)

-- Leaving combat: forget old casts so the table doesn't grow all session.
ns:On("PLAYER_REGEN_ENABLED", function() lastCast = {} end)

-- Cheap enough at 5x a second: one IsFalling call and up to three mirror timer lookups.
C_Timer.NewTicker(0.2, function()
    if IsFalling() then lastFall = GetTime() end
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

-- The killer's level, if it's on a unit we can see.
local function UnitLevelByGUID(guid)
    if not guid then return nil end
    local units = { "target", "mouseover", "targettarget", "pettarget" }
    for i = 1, 4 do units[#units + 1] = "party" .. i .. "target" end
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    for _, unit in ipairs(units) do
        if UnitGUID(unit) == guid then return UnitLevel(unit) end
    end
end

-- The hit that overkilled us, otherwise the most recent one in the window.
local function KillingBlow()
    local now, newest = GetTime(), nil
    for i = #recent, 1, -1 do
        local h = recent[i]
        if now - h.at > LAST_HIT_WINDOW then break end
        if (tonumber(h.overkill) or 0) > 0 then return h end
        newest = newest or h
    end
    return newest
end

-- attacker: the fallback killer, found the moment we died (mobs drop their target right after).
local function ReportOwnDeath(attacker)
    local hit = KillingBlow()
    lastDeathHits = recent
    recent = {}
    hit = hit or FallbackHit(attacker)
    local _, class = UnitClass("player")
    local d = {
        name = ns.me, class = class, level = UnitLevel("player"),
        zone = GetRealZoneText() or "", subzone = GetSubZoneText() or "",
        killer = hit.killer or "", klevel = hit.level or UnitLevelByGUID(hit.guid),
        ability = hit.ability or "", damage = tonumber(hit.amount),
        t = GetServerTime(),
    }
    Record(d)
    Relay(d)
    if ns.db.settings.share.deaths then
        ns.Broadcast(table.concat({
            "K", d.t, d.level, Clean(d.class), Clean(d.zone), Clean(d.killer), Clean(d.ability),
            d.damage or "", d.klevel or "", Clean(d.subzone),
        }, "|"))
    end
end

ns:On("PLAYER_DEAD", function()
    -- Logging in while dead can fire this too; that death was already reported.
    if not ns.me or GetTime() - loginTime < 5 then return end
    local attacker = FindAttacker() or Fresh(lastAttacker)
    -- The killing blow can reach the combat log just after this event.
    C_Timer.After(0.5, function() ReportOwnDeath(attacker) end)
end)

ns:Listen("LOGIN", function()
    playerGUID = UnitGUID("player")
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
    local d = {
        name = sender, class = (class and class:match("^%u+$")) or nil, level = level,
        zone = zone or "", subzone = subzone or "", killer = killer or "", klevel = tonumber(klevel),
        ability = ability or "", damage = tonumber(damage), t = t,
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
    Alert(d)
    Settings().alerts = alerts
    if Settings().relay then
        Relay(d, true)
        ReloadUI()
    end
end

-- What the combat log showed before our last death (or since, if we haven't died).
function ns.DeathDebug()
    local now = GetTime()
    ns.Print(("Combat log: %d events this session, %d hit you."):format(diag.events, diag.toMe))
    if diag.last then ns.Print("  last event: " .. diag.last) end
    if diag.err then ns.Print("  error: " .. tostring(diag.err)) end
    ns.Print("  your GUID: " .. tostring(playerGUID or UnitGUID("player")))
    ns.Print(("Fallback: last hit %s, attacker %s, enemy spell casts seen: %d."):format(
        lastWound and ("%s dmg (school %s) %ds ago"):format(tostring(lastWound.amount),
            tostring(lastWound.school), now - lastWound.at) or "none",
        lastAttacker and ("%s (level %s)"):format(tostring(lastAttacker.name), tostring(lastAttacker.level))
            or "none", diag.casts or 0))

    local hits = lastDeathHits or recent
    ns.Print(lastDeathHits and "Damage taken before your last death:" or "Damage taken recently (no death yet):")
    if #hits == 0 then
        ns.Print("  none captured from the combat log.")
        return
    end
    for _, h in ipairs(hits) do
        ns.Print(("  %.1fs ago: %s / %s / %s dmg / %s overkill"):format(now - h.at,
            tostring(h.killer), tostring(h.ability), tostring(h.amount), tostring(h.overkill)))
    end
end
