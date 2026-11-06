-- FriendProgress: core namespace, event dispatch, saved data and slash commands.
local ADDON, ns = ...

ns.VERSION = "0.3.10"
ns.PROTOCOL = 1

-- Each section is collected, hashed and synced independently, so a change to
-- one (e.g. XP) never resends the others (e.g. bags).
ns.SECTIONS = { "char", "gear", "bags", "bank", "prof", "recipes", "quest", "log" }

local DEFAULTS = {
    chars = {},        -- [ "Name-Realm" ] = { sections = {}, hashes = {}, lastSeen = n, isMine = bool }
    deaths = {},       -- newest first: { name, class, level, zone, killer, ability, t }
    relayQueue = {},   -- our own deaths as "FPDEATH;..." lines for the Discord relay
    settings = {
        notify = true,
        -- What this player sends to others. Their own view always has everything.
        share = {
            zone = true,
            gear = true,
            bags = "all",   -- "all" | "materials" | "none"
            bank = "all",   -- same choices as bags
            gold = true,
            prof = true,
            recipes = true,
            quest = true,
            log = true,
            liveXP = true,  -- broadcast XP to the current party for the party XP box
            deaths = true,  -- announce our deaths
            bnet = true,    -- also sync with Battle.net friends playing this game, on any realm
        },
        deaths = {
            alerts = true,  -- raid-warning style alert when a friend dies
            sound = true,
            jokes = true,   -- a joke line under each alert (DeathQuips.lua)
            relay = false,  -- queue our deaths for the Discord relay; reload on release spirit
        },
        autoSync = 10,      -- minutes between background syncs; 0 = off
        locked = true,      -- on-screen frames (party XP box, sync button) can't be dragged
        partyXP = {
            enabled = true,
            pos = nil,      -- { point, relativePoint, x, y } once moved
        },
        syncButton = {
            enabled = false,
            pos = nil,
        },
        tooltip = {
            enabled = true, -- add "who has / can craft" lines to item tooltips
            mine = true,    -- include this account's other characters
        },
    },
}

local function Print(msg)
    print("|cff33ff99FriendProgress|r: " .. tostring(msg))
end
ns.Print = Print

-- Event dispatch: modules call ns:On("EVENT", fn); several handlers per event are fine.
local frame = CreateFrame("Frame")
local handlers = {}
function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end
frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do fn(...) end
end)

-- Like ns:On, but only for the given units (e.g. "player", "party1"), so the game
-- doesn't call us for every nameplate. One frame per two units keeps it safe on
-- clients that only accept two units per registration.
function ns:OnUnit(event, fn, ...)
    local units = { ... }
    for i = 1, #units, 2 do
        local f = CreateFrame("Frame")
        f:RegisterUnitEvent(event, units[i], units[i + 1])
        f:SetScript("OnEvent", function(_, _, ...) fn(...) end)
    end
end

-- Tiny callback bus for internal messages (e.g. "DATA_UPDATED").
local callbacks = {}
function ns:Listen(msg, fn)
    callbacks[msg] = callbacks[msg] or {}
    table.insert(callbacks[msg], fn)
end
function ns:Fire(msg, ...)
    for _, fn in ipairs(callbacks[msg] or {}) do fn(...) end
end

-- WoW Forever has no realms and two-part names ("Slim Steaky"), which are unique on
-- their own. Its UnitName returns them as two values, "Slim", "Steaky", where other
-- clients return a realm (never, for the player), so that tells us which game this is.
local function TwoPartNames()
    local _, second = UnitName("player")
    return second ~= nil and second ~= ""
end

-- The key a character is stored and addressed under. Elsewhere that's "Name-Realm".
-- On WoW Forever it's the bare two-part name: addon messages arrive labelled
-- "Slim Steaky" (party) or with a realm attached, and adding a realm ourselves names
-- someone who doesn't exist ("No player named 'Slim Steaky-<our realm>'").
-- name/realm may also be UnitName's two values; on WoW Forever the second is the surname.
function ns.FullName(name, realm)
    if not name then return nil end
    if TwoPartNames() then
        local bare = name:match("^(.-)%-[^%-]*$") or name
        if bare:find(" ", 1, true) then return bare end
        if realm and realm ~= "" and not name:find("-", 1, true) then return name .. " " .. realm end
        -- "Slim-Steaky": how versions before 0.3.8 stored a two-part name.
        local first, last = name:match("^([^%s%-]+)%-([^%s%-]+)$")
        if first then return first .. " " .. last end
        return name
    end
    if name:find("-", 1, true) then return name end
    realm = realm or GetNormalizedRealmName()
    return realm and (name .. "-" .. realm) or name
end

function ns.GetChar(fullName)
    local chars = ns.db.chars
    local c = chars[fullName]
    if not c then
        c = { sections = {}, hashes = {}, lastSeen = 0 }
        chars[fullName] = c
    end
    return c
end

local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(dst[k]) == "table" then
            ApplyDefaults(dst[k], v)
        end
    end
end

ns:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    FriendProgressDB = FriendProgressDB or {}
    ApplyDefaults(FriendProgressDB, DEFAULTS)
    ns.db = FriendProgressDB
    -- 0.1.0 kept the lock on the party XP box; it now covers all on-screen frames.
    local s = ns.db.settings
    if s.partyXP.locked ~= nil then
        s.locked = s.partyXP.locked
        s.partyXP.locked = nil
    end
end)

-- Redraw everything that lives on screen outside the main window.
function ns.RefreshOnScreen()
    ns.RefreshPartyXP()
    ns.RefreshSyncButton()
    if ns.RefreshSettingsPanel then ns.RefreshSettingsPanel() end
end

-- Saved data from versions before 0.3.8 has WoW Forever characters under older keys:
-- "Slim-Steaky" (0.3.5 and earlier) or "Slim Steaky-<realm>" (0.3.6, 0.3.7, or a party
-- member with our own realm wrongly added). Move everything to the current key. When two
-- records land on one key, ours wins (a ghost of ourselves loses), then the newest.
local function MigrateKeys()
    local chars = ns.db.chars
    local moves = {}
    for key in pairs(chars) do
        local new = ns.FullName(key)
        if new ~= key then moves[#moves + 1] = { key, new } end
    end
    for _, m in ipairs(moves) do
        local old, new = chars[m[1]], m[2]
        local cur = chars[new]
        local keepOld = not cur
            or (old.isMine and not cur.isMine)
            or (old.isMine == cur.isMine and (old.lastSeen or 0) > (cur.lastSeen or 0))
        if keepOld then
            old.isMine = old.isMine or (cur and cur.isMine) or nil
            chars[new] = old
        end
        chars[m[1]] = nil
    end
    for _, g in ipairs(ns.db.groups or {}) do
        local members = {}
        for key in pairs(g.members) do members[ns.FullName(key)] = true end
        g.members = members
    end
    for _, d in ipairs(ns.db.deaths) do
        if d.name then d.name = ns.FullName(d.name) end
    end
end

ns:On("PLAYER_LOGIN", function()
    MigrateKeys()
    ns.me = ns.FullName(UnitName("player"))
    ns.GetChar(ns.me).isMine = true
    ns:Fire("LOGIN")
end)

SLASH_FRIENDPROGRESS1 = "/fp"
SLASH_FRIENDPROGRESS2 = "/friendprogress"
SlashCmdList.FRIENDPROGRESS = function(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        ns.ToggleUI()
    elseif cmd == "sync" then
        if ns.SyncNow() then
            Print("Sync requested.")
        else
            Print("Synced a moment ago; try again in a few seconds.")
        end
    elseif cmd == "craft" then
        ns.ShowRecipeSearch(rest)
    elseif cmd == "share" or cmd == "settings" then
        ns.ShowSettings()
    elseif cmd == "xp" then
        local s = ns.db.settings.partyXP
        s.enabled = not s.enabled
        ns.RefreshOnScreen()
        Print("Party XP box " .. (s.enabled and "shown" or "hidden") .. ".")
    elseif cmd == "button" then
        local s = ns.db.settings.syncButton
        s.enabled = not s.enabled
        ns.RefreshOnScreen()
        Print("Sync button " .. (s.enabled and "shown" or "hidden") .. ".")
    elseif cmd == "unlock" or cmd == "lock" then
        ns.db.settings.locked = (cmd == "lock")
        ns.RefreshOnScreen()
        Print(ns.db.settings.locked and "On-screen frames locked."
            or "On-screen frames unlocked: drag them, then /fp lock.")
    elseif cmd == "autosync" then
        local minutes = tonumber(rest)
        if minutes and minutes >= 0 then
            ns.db.settings.autoSync = minutes
            if ns.RefreshSettingsPanel then ns.RefreshSettingsPanel() end
        end
        local m = ns.db.settings.autoSync
        Print("Auto sync " .. (m > 0 and ("every " .. m .. " min.") or "off."))
    elseif cmd == "notify" then
        ns.db.settings.notify = not ns.db.settings.notify
        Print("Chat notifications " .. (ns.db.settings.notify and "on" or "off") .. ".")
    elseif cmd == "deaths" then
        if rest == "test" then
            ns.TestDeath()
        elseif rest == "debug" then
            ns.DeathDebug()
        elseif rest == "alerts" then
            local s = ns.db.settings.deaths
            s.alerts = not s.alerts
            if ns.RefreshSettingsPanel then ns.RefreshSettingsPanel() end
            Print("Death alerts " .. (s.alerts and "on" or "off") .. ".")
        elseif rest == "jokes" then
            local s = ns.db.settings.deaths
            s.jokes = not s.jokes
            if ns.RefreshSettingsPanel then ns.RefreshSettingsPanel() end
            Print("Jokes in death alerts " .. (s.jokes and "on" or "off") .. ".")
        else
            ns.ShowTab("deaths")
        end
    elseif cmd == "bnet" then
        ns.BNetDebug()
    elseif cmd == "discord" then
        ns.SetDeathRelay(not ns.db.settings.deaths.relay)
        if ns.RefreshSettingsPanel then ns.RefreshSettingsPanel() end
    elseif cmd == "remove" and rest ~= "" then
        local key = ns.FullName(rest)   -- "Slim Steaky", or Name-Realm elsewhere
        if ns.db.chars[key] then
            ns.db.chars[key] = nil
            ns:Fire("DATA_UPDATED")
            Print("Removed " .. key .. ".")
        else
            Print("No saved data for " .. key .. ".")
        end
    else
        Print("/fp - open window")
        Print("/fp sync - rescan yourself and ask friends for updates")
        Print("/fp craft <name> - who can craft something")
        Print("/fp share - choose what you share with friends")
        Print("/fp xp - show/hide the party XP box")
        Print("/fp button - show/hide the on-screen sync button")
        Print("/fp unlock, /fp lock - move the on-screen frames")
        Print("/fp autosync <minutes> - background sync interval, 0 = off")
        Print("/fp notify - toggle chat notifications for friend activity")
        Print("/fp deaths - death log; /fp deaths alerts, /fp deaths jokes - toggle alerts or jokes; /fp deaths test - preview")
        Print("/fp deaths debug - what death detection has seen (last hit, attacker, falls)")
        Print("/fp bnet - what Battle.net sync can see (friends online in this game)")
        Print("/fp discord - post your deaths to Discord (needs the relay installed)")
        Print("/fp remove Name-Realm - forget a character")
    end
end

function FriendProgress_OnAddonCompartmentClick()
    ns.ToggleUI()
end
