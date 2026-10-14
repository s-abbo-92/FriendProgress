-- Deaths: a Hardcore-style death log. When you die, the last thing that hit you
-- is broadcast to everyone you sync with; they get a raid-warning style alert
-- and every death is kept in the Deaths tab.
--
-- Discord relay: addons can't reach the internet, so one player turns on the
-- relay and their addon whispers each death to themselves as a "FPDEATH;" line.
-- With chat logging on, WoW writes it to Logs\WoWChatLog.txt, where the
-- companion script (discord\DeathRelay.ps1) picks it up and posts it.
local _, ns = ...

local MAX_LOG = 300
local LAST_HIT_WINDOW = 15     -- seconds; older hits don't count as the killer
local RELAY_TAG = "FPDEATH"
local RELAY_VERSION = 1

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

-- Fields travel in "|" and ";" separated messages, so strip both.
local function Clean(s, max)
    s = tostring(s or ""):gsub("[|;]", "")
    return s:sub(1, max or 60)
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
-- d = { name, class, level, zone, killer, ability, t }
function ns.DeathText(d, plain)
    local name = Ambiguate(d.name, "short")
    if not plain then
        local color = d.class and RAID_CLASS_COLORS[d.class]
        if color and color.colorStr then name = "|c" .. color.colorStr .. name .. "|r" end
    end
    local className = d.class and LOCALIZED_CLASS_NAMES_MALE[d.class] or ""
    local who = ("%s (level %d %s)"):format(name, d.level or 0, className):gsub(" %)", ")")
    local zone = (d.zone and d.zone ~= "") and (" in " .. d.zone) or ""
    local killer, ability = d.killer or "", d.ability or ""
    if killer ~= "" and ability ~= "" and ability ~= "Melee" then
        return ("%s was killed by %s (%s)%s."):format(who, killer, ability, zone)
    elseif killer ~= "" then
        return ("%s was killed by %s%s."):format(who, killer, zone)
    elseif ENVIRONMENT[ability] then
        return ("%s %s%s."):format(who, ENVIRONMENT[ability], zone)
    elseif ability ~= "" then
        return ("%s was killed by %s%s."):format(who, ability, zone)
    end
    return ("%s died%s."):format(who, zone)
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

local function Relay(d, test)
    if not Settings().relay or not ns.me then return end
    local line = table.concat({
        RELAY_TAG, RELAY_VERSION, test and "test" or "death",
        Clean(d.name), d.level or 0, Clean(d.class), Clean(d.zone), Clean(d.killer), Clean(d.ability), d.t,
    }, ";")
    SendChatMessage(line, "WHISPER", nil, UnitName("player"))
end

-- Keep the relay whispers out of the chat window; WoW still writes them to the chat log.
local function HideRelayLine(_, _, msg)
    return msg:sub(1, #RELAY_TAG + 1) == RELAY_TAG .. ";"
end
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", HideRelayLine)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", HideRelayLine)

local function Record(d)
    if Known(d) then return false end
    table.insert(ns.db.deaths, 1, d)
    for i = #ns.db.deaths, MAX_LOG + 1, -1 do ns.db.deaths[i] = nil end
    ns:Fire("DATA_UPDATED")
    return true
end

---------------------------------------------------------------------------
-- Our own deaths: remember the last hit, report it on PLAYER_DEAD
---------------------------------------------------------------------------
local lastHit
local playerGUID
local loginTime = math.huge

ns:On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local _, sub, _, _, srcName, _, _, destGUID, _, _, _, a12, a13 = CombatLogGetCurrentEventInfo()
    if destGUID ~= playerGUID then return end
    if sub == "SWING_DAMAGE" then
        lastHit = { killer = srcName, ability = "Melee", at = GetTime() }
    elseif sub == "RANGE_DAMAGE" or sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" then
        lastHit = { killer = srcName, ability = a13, at = GetTime() }
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        lastHit = { ability = a12, at = GetTime() }
    end
end)

ns:On("PLAYER_DEAD", function()
    -- Logging in while dead can fire this too; that death was already reported.
    if not ns.me or GetTime() - loginTime < 5 then return end
    local hit = lastHit and GetTime() - lastHit.at <= LAST_HIT_WINDOW and lastHit or {}
    lastHit = nil
    local _, class = UnitClass("player")
    local d = {
        name = ns.me, class = class, level = UnitLevel("player"),
        zone = GetRealZoneText() or "", killer = hit.killer or "", ability = hit.ability or "",
        t = GetServerTime(),
    }
    Record(d)
    Relay(d)
    if ns.db.settings.share.deaths then
        ns.Broadcast(("K|%d|%d|%s|%s|%s|%s"):format(d.t, d.level, Clean(d.class), Clean(d.zone),
            Clean(d.killer), Clean(d.ability)))
    end
end)

ns:Listen("LOGIN", function()
    playerGUID = UnitGUID("player")
    loginTime = GetTime()
    if Settings().relay then LoggingChat(true) end
end)

---------------------------------------------------------------------------
-- Friends' deaths
---------------------------------------------------------------------------
ns.OnMessage("K", function(sender, rest)
    local t, level, class, zone, killer, ability = rest:match("^(%d+)|(%d+)|(%u*)|([^|]*)|([^|]*)|([^|]*)$")
    if not t then return end
    local d = {
        name = sender, class = class ~= "" and class or nil, level = tonumber(level),
        zone = zone, killer = killer, ability = ability, t = tonumber(t),
    }
    if not Record(d) then return end   -- already heard it via another channel
    Alert(d)
    Relay(d)
end)

---------------------------------------------------------------------------
-- Settings hooks
---------------------------------------------------------------------------
function ns.SetDeathRelay(enabled)
    Settings().relay = enabled
    if enabled then
        LoggingChat(true)
        ns.Print("Discord relay on. Chat logging is on; run discord\\DeathRelay.ps1 on this PC.")
    else
        ns.Print("Discord relay off.")
    end
end

-- Shows a made-up death as an alert and sends it to the relay (marked as a test).
function ns.TestDeath()
    local _, class = UnitClass("player")
    local d = {
        name = ns.me, class = class, level = UnitLevel("player"), zone = GetRealZoneText() or "",
        killer = "Hogger", ability = "Melee", t = GetServerTime(),
    }
    local alerts = Settings().alerts
    Settings().alerts = true
    Alert(d)
    Settings().alerts = alerts
    if Settings().relay then
        Relay(d, true)
        ns.Print("Test death sent to the Discord relay.")
    end
end
