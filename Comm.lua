-- Comm: syncs sections between players over hidden addon messages.
--
-- Protocol (prefix "FrndProg"):
--   H|<proto>|<reply>|sec=hash,sec=hash,...   "here is what I have"; reply=1 asks for your H back
--   Q|sec,sec,...                              "send me these sections" (always whispered)
--   D|<id>|<i>|<n>|<chunk>                     section data, split into <n> chunks
--   X|...                                      live XP to the group (below)
--   K|...                                      a death (Deaths.lua)
-- A receiver compares hashes from H with what it has stored and only pulls what changed.
--
-- Messages go over guild, party and character-friend whispers (C_ChatInfo), and to
-- Battle.net friends playing the same game over Battle.net game data (BNSendGameData),
-- which also reaches friends on other realms.
local _, ns = ...

local PREFIX = "FrndProg"
local CHUNK = 220            -- addon messages are capped at 255 bytes including our header
local SEND_INTERVAL = 0.2    -- seconds between queued messages
local HELLO_COOLDOWN = 30    -- min seconds between unforced broadcasts
local REPLY_COOLDOWN = 30    -- min seconds between replies to the same player
local MAX_CHUNKS = 200

---------------------------------------------------------------------------
-- Outgoing queue (keeps us under the server's addon message throttle)
---------------------------------------------------------------------------
local queue = {}
local ticker

local THROTTLED = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.AddonMessageThrottle

local PRIORITY_BURST = 5   -- priority messages (deaths, live XP) sent per tick instead of one

-- What we sent to guild/group recently, to spot our own messages echoing back (see
-- CHAT_MSG_ADDON). Live XP is left out: "X|off" from someone else would look the same.
local ECHO_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }
local ECHO_WINDOW = 30
local sentShared = {}   -- [ text ] = GetTime() when sent

local function Pump()
    local sent = 0
    while queue[1] do
        local msg = queue[1]
        if msg[2] == "BNET" then
            -- pcall: the friend may have logged off since this was queued.
            pcall(BNSendGameData, msg[3], PREFIX, "N|" .. ns.me .. "|" .. msg[1])
        else
            local result = C_ChatInfo.SendAddonMessage(PREFIX, msg[1], msg[2], msg[3])
            if THROTTLED and result == THROTTLED then return end   -- retry next tick
            if ECHO_CHANNELS[msg[2]] and not msg[1]:find("^X|") then sentShared[msg[1]] = GetTime() end
        end
        table.remove(queue, 1)
        sent = sent + 1
        if not msg[4] or sent >= PRIORITY_BURST then return end
    end
    ticker:Cancel()
    ticker = nil
    local now = GetTime()
    for text, t in pairs(sentShared) do
        if now - t > ECHO_WINDOW then sentShared[text] = nil end
    end
end

-- priority messages jump ahead of bulk section data (but stay in order among themselves).
local function Send(text, channel, target, priority)
    local entry = { text, channel, target, priority }
    if priority then
        local at = #queue + 1
        for i, m in ipairs(queue) do
            if not m[4] then at = i break end
        end
        table.insert(queue, at, entry)
    else
        queue[#queue + 1] = entry
    end
    if not ticker then ticker = C_Timer.NewTicker(SEND_INTERVAL, Pump) end
end

function ns.SendQueueEmpty() return #queue == 0 end

---------------------------------------------------------------------------
-- Who to talk to: guild, current group, and online WoW friends
---------------------------------------------------------------------------
local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

-- Syncing into a raid or battleground would hand your data to strangers and bury
-- everyone in traffic, so group traffic only goes to groups of party size.
local MAX_SYNC_GROUP = 5

local function SyncGroupChannel()
    if GetNumGroupMembers() > MAX_SYNC_GROUP then return nil end
    return GroupChannel()
end

local function OnlineFriends()
    local list = {}
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then list[#list + 1] = info.name end
    end
    return list
end

-- Battle.net friends online in this same game (WoW Forever), on any realm.
--
-- WoW Forever is realmless and characters have two-part names, so the Battle.net game
-- account info for a friend (e.g. characterName "Smitty Jensen", realmName
-- "CAMWOWEU5Realm5PvE") isn't needed to know who they are. Every Battle.net message
-- says who sent it, and the receiver puts that through ns.FullName like any sender:
-- "N|<sender's ns.me>|<message>". Older versions ignore these (there's no "N" handler),
-- which is fine: their Battle.net sync didn't work.
local BNET_OK = BNSendGameData and BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendGameAccountInfo
local bnRoute = {}   -- [ "Name-Realm" ] = gameAccountID they last messaged us from

-- A character key as another client's ns.me: names can have spaces on WoW Forever,
-- so only rule out what our message format and saved data can't hold.
local function ValidCharacter(name)
    return name ~= nil and #name <= 80 and name:match("^[^|%c%s][^|%c]*[^|%c%s]$") ~= nil
end

local function BNetEnabled()
    return BNET_OK and ns.db and ns.db.settings.share.bnet
end

-- Game accounts of Battle.net friends online in this game, not counting ourselves.
local function BNetFriends()
    local list = {}   -- { gameAccountID, ... }
    if not BNetEnabled() then return list end
    local me = UnitGUID("player")
    for i = 1, BNGetNumFriends() do
        for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) do
            local info = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if info and info.isOnline and info.gameAccountID
                and info.clientProgram == (BNET_CLIENT_WOW or "WoW")
                and (not info.wowProjectID or info.wowProjectID == WOW_PROJECT_ID)
                and not (info.playerGuid and info.playerGuid == me) then
                list[#list + 1] = info.gameAccountID
            end
        end
    end
    return list
end

-- Whisper one player, over Battle.net if that's how they reached us (works cross-realm).
-- A player we only know over Battle.net is never whispered: the whisper would fail
-- with "No player named ... is currently playing" if they're on another realm.
local function SendTo(name, text, priority)
    if bnRoute[name] then
        Send(text, "BNET", bnRoute[name], priority)
    else
        Send(text, "WHISPER", name, priority)
    end
end

-- For /fp bnet: what Battle.net reports, to check the above against.
function ns.BNetDebug()
    if not BNET_OK then ns.Print("Battle.net game data isn't available in this client.") return end
    ns.Print(("Battle.net sync is %s. This game: project %s, you: %s %s"):format(
        BNetEnabled() and "on" or "off (Sharing...)", tostring(WOW_PROJECT_ID), tostring(ns.me),
        tostring(UnitGUID("player"))))
    local shown = 0
    for i = 1, BNGetNumFriends() do
        for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) do
            local info = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if info and info.isOnline and info.clientProgram == (BNET_CLIENT_WOW or "WoW") then
                shown = shown + 1
                ns.Print(("  #%s: %s / %s / %s, project %s, %s"):format(tostring(info.gameAccountID),
                    tostring(info.characterName), tostring(info.realmName), tostring(info.realmDisplayName),
                    tostring(info.wowProjectID), tostring(info.playerGuid)))
            end
        end
    end
    if shown == 0 then ns.Print("  No Battle.net friends online in WoW.") end
    for name, id in pairs(bnRoute) do ns.Print(("  heard from %s via #%s"):format(name, tostring(id))) end
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function HelloText(reply)
    local c = ns.GetChar(ns.me)
    local hashes = c.sharedHashes or {}
    local parts = {}
    for _, s in ipairs(ns.SECTIONS) do
        if hashes[s] then parts[#parts + 1] = s .. "=" .. hashes[s] end
    end
    return ("H|%d|%d|%s"):format(ns.PROTOCOL, reply and 1 or 0, table.concat(parts, ","))
end

local lastHello = 0
-- reply: ask receivers to answer with their own hello. force: ignore the cooldown.
function ns.SayHello(reply, force)
    if not ns.me then return end
    local now = GetTime()
    if not force and now - lastHello < HELLO_COOLDOWN then
        -- Try again when the cooldown ends so the latest change still goes out.
        if not ns._helloPending then
            ns._helloPending = true
            C_Timer.After(HELLO_COOLDOWN - (now - lastHello), function()
                ns._helloPending = false
                ns.SayHello(reply)
            end)
        end
        return
    end
    lastHello = now
    ns.Broadcast(HelloText(reply))
end

-- Send to everyone we can reach. Friends who are also in our guild or group get
-- it more than once, so receivers of one-off messages must dedupe.
function ns.Broadcast(text, priority)
    if IsInGuild() then Send(text, "GUILD", nil, priority) end
    local group = SyncGroupChannel()
    if group then Send(text, group, nil, priority) end
    for _, name in ipairs(OnlineFriends()) do Send(text, "WHISPER", name, priority) end
    -- Battle.net friends who are also character friends get it twice; receivers dedupe.
    for _, id in ipairs(BNetFriends()) do Send(text, "BNET", id, priority) end
end

-- Manual sync (window button, on-screen button, /fp sync). Returns false while cooling down.
local SYNC_COOLDOWN = 10
local lastManualSync = -SYNC_COOLDOWN
function ns.SyncNow()
    if GetTime() - lastManualSync < SYNC_COOLDOWN then return false end
    lastManualSync = GetTime()
    ns.CollectAll()
    ns.SayHello(true, true)
    ns:Fire("SYNC_STARTED", SYNC_COOLDOWN)
    return true
end

-- Auto sync: a periodic hello catches anything missed (dropped messages, people
-- who were out of reach). reply=false because everyone runs their own timer, so
-- asking for replies would only double the traffic.
local lastAutoSync = GetTime()
C_Timer.NewTicker(60, function()
    local minutes = ns.db and ns.db.settings.autoSync or 0
    if minutes <= 0 or not ns.me then return end
    if InCombatLockdown() then return end   -- try again next minute
    if GetTime() - lastAutoSync < minutes * 60 then return end
    lastAutoSync = GetTime()
    ns.SayHello(false)
end)

local msgId = 0
local function SendSection(section, target)
    local data = ns.SharedSection(section)
    if not data then return end
    local hash = (ns.GetChar(ns.me).sharedHashes or {})[section] or ""
    local payload = section .. "|" .. hash .. "|" .. ns.Serialize(data)
    msgId = (msgId % 999) + 1
    local n = math.ceil(#payload / CHUNK)
    for i = 1, n do
        local chunk = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
        SendTo(target, ("D|%d|%d|%d|%s"):format(msgId, i, n, chunk))
    end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local lastReply = {}
local buffers = {}

-- The same hello often arrives twice (guild + friends list + group), and each copy
-- would otherwise start its own transfer. Remember what we asked for and what we
-- sent, per player and section, and skip an identical repeat for a while.
local DEDUPE_WINDOW = 30
local requested = {}   -- [ sender .. ":" .. section ] = { hash, time }  (we asked them)
local served = {}      -- [ sender .. ":" .. section ] = { hash, time }  (they asked us)

local function Recent(map, key, hash)
    local e = map[key]
    return e and e[1] == hash and GetTime() - e[2] < DEDUPE_WINDOW
end

local function NotifyLog(sender, old, new)
    if not ns.db.settings.notify or not old or not new then return end
    local since = old[1] and old[1].t or 0
    local short = Ambiguate(sender, "short")
    for i = #new, 1, -1 do
        local e = new[i]
        if e.t and e.t > since and e.m then ns.Print(short .. ": " .. e.m) end
    end
end

local function OnSection(sender, payload)
    local section, hash, body = payload:match("^(%w+)|(%x*)|(.*)$")
    if not section or not ns.IsSection(section) then return end
    local data = ns.SanitizeSection(section, ns.Deserialize(body))
    if not data then return end
    local c = ns.GetChar(sender)
    if section == "log" then NotifyLog(sender, c.sections.log, data) end
    c.sections[section] = data
    c.hashes[section] = hash
    requested[sender .. ":" .. section] = nil
    c.lastSeen = GetServerTime()
    ns:Fire("DATA_UPDATED", sender, section)
end

local handlers = {}

-- Other modules add message kinds: fn(sender, rest) handles "<kind>|<rest>".
function ns.OnMessage(kind, fn) handlers[kind] = fn end

handlers.H = function(sender, rest)
    local proto, reply, list = rest:match("^(%d+)|(%d)|(.*)$")
    if not proto or tonumber(proto) ~= ns.PROTOCOL then return end
    local c = ns.GetChar(sender)
    c.lastSeen = GetServerTime()
    local need, dropped = {}, nil
    for section, hash in list:gmatch("(%w+)=([%x%-]+)") do
        if not ns.IsSection(section) then
            -- ignore names we don't know
        elseif hash == "-" then
            -- They stopped sharing this section: forget our copy.
            c.sections[section], c.hashes[section] = nil, nil
            dropped = section
        elseif c.hashes[section] ~= hash and not Recent(requested, sender .. ":" .. section, hash) then
            requested[sender .. ":" .. section] = { hash, GetTime() }
            need[#need + 1] = section
        end
    end
    if #need > 0 then SendTo(sender, "Q|" .. table.concat(need, ",")) end
    if reply == "1" and GetTime() - (lastReply[sender] or 0) > REPLY_COOLDOWN then
        lastReply[sender] = GetTime()
        SendTo(sender, HelloText(false))
    end
    ns:Fire("DATA_UPDATED", sender, dropped or "hello")
end

handlers.Q = function(sender, rest)
    for section in rest:gmatch("[^,]+") do
        if ns.IsSection(section) then
            local hash = (ns.GetChar(ns.me).sharedHashes or {})[section] or ""
            local key = sender .. ":" .. section
            if not Recent(served, key, hash) then
                served[key] = { hash, GetTime() }
                SendSection(section, sender)
            end
        end
    end
end

handlers.D = function(sender, rest)
    local id, i, n, chunk = rest:match("^(%d+)|(%d+)|(%d+)|(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not id or n > MAX_CHUNKS or i < 1 or i > n then return end
    local key = sender .. ":" .. id
    local buf = buffers[key]
    if not buf or buf.n ~= n then
        buf = { n = n, parts = {}, got = 0 }
        buffers[key] = buf
    end
    if not buf.parts[i] then
        buf.parts[i] = chunk
        buf.got = buf.got + 1
    end
    if buf.got == n then
        buffers[key] = nil
        OnSection(sender, table.concat(buf.parts))
    end
end

---------------------------------------------------------------------------
-- Live XP for the party box: tiny "X|level|xp|xpMax|rested" messages to the
-- group, separate from the section sync so it can update every few seconds.
---------------------------------------------------------------------------
local LIVE_XP_INTERVAL = 2
ns.liveXP = {}   -- [ "Name-Realm" ] = { level, xp, xpMax, rested }

local lastXPSend, xpPending = 0, false
function ns.SendLiveXP()
    if not ns.me or not ns.db.settings.share.liveXP then return end
    local group = SyncGroupChannel()
    if not group then return end
    local wait = LIVE_XP_INTERVAL - (GetTime() - lastXPSend)
    if wait > 0 then
        if not xpPending then
            xpPending = true
            C_Timer.After(wait, function()
                xpPending = false
                ns.SendLiveXP()
            end)
        end
        return
    end
    lastXPSend = GetTime()
    Send(("X|%d|%d|%d|%d"):format(UnitLevel("player"), UnitXP("player"), UnitXPMax("player"),
        math.floor(GetXPExhaustion() or 0)), group, nil, true)
end

function ns.SetLiveXPSharing(enabled)
    if enabled then
        ns.SendLiveXP()
    else
        local group = SyncGroupChannel()
        if group then Send("X|off", group, nil, true) end
    end
end

handlers.X = function(sender, rest)
    if rest == "off" then
        ns.liveXP[sender] = nil
    else
        local level, xp, xpMax, rested = rest:match("^(%d+)|(%d+)|(%d+)|(%d+)$")
        if not level then return end
        ns.liveXP[sender] = {
            level = tonumber(level), xp = tonumber(xp), xpMax = tonumber(xpMax), rested = tonumber(rested),
        }
    end
    ns:Fire("LIVE_XP")
end

ns:On("PLAYER_XP_UPDATE", function() ns.SendLiveXP() end)
ns:On("PLAYER_LEVEL_UP", function() ns.SendLiveXP() end)
-- Everyone resends on roster changes so people who just joined get current values.
ns:On("GROUP_ROSTER_UPDATE", function()
    -- Forget XP from people who left the group.
    for key in pairs(ns.liveXP) do
        local short = Ambiguate(key, "none")
        if not (UnitInParty(short) or UnitInRaid(short)) then ns.liveXP[key] = nil end
    end
    ns.SendLiveXP()
end)

---------------------------------------------------------------------------
-- Who we answer. Group and guild channels can't be spoofed, so anything that
-- arrives on them is from a group or guild mate. Whispers can come from anyone,
-- so those must be from a friend, someone in our group, or a guild member.
---------------------------------------------------------------------------
local guildMembers = {}   -- [ short name ] = true, from the guild roster
local guildStale = true   -- the roster changes often; only reread it when a whisper needs checking

local function RefreshGuildMembers()
    guildStale = false
    wipe(guildMembers)
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local name = GetGuildRosterInfo(i)
        if name then guildMembers[ns.FullName(name)] = true end
    end
end
ns:On("GUILD_ROSTER_UPDATE", function() guildStale = true end)
ns:Listen("LOGIN", function()
    if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
end)

local SHARED_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }

local function IsTrusted(sender, channel)
    if SHARED_CHANNELS[channel] then return true end
    if channel ~= "WHISPER" then return false end
    -- sender has been through ns.FullName; compare everything in that same form.
    local short = Ambiguate(sender, "none")
    if UnitInParty(short) or UnitInRaid(short) then return true end
    if guildStale then RefreshGuildMembers() end
    if guildMembers[sender] then return true end
    for _, name in ipairs(OnlineFriends()) do
        if ns.FullName(name) == sender then return true end
    end
    return false
end

local function Dispatch(sender, text)
    local kind, rest = text:match("^(%a)|(.*)$")
    local fn = kind and handlers[kind]
    if fn then fn(sender, rest) end
end

-- Guild and group messages come back to the sender too. Normally that's under ns.me, but
-- if the server names us differently (it did on WoW Forever before ns.me was built from
-- Battle.net), recognise our own message by its text, remember that name as ours and
-- drop the ghost character older versions created for it.
local selfNames = {}

local function IsOwnEcho(sender, text, channel)
    if selfNames[sender] then return true end
    local t = ECHO_CHANNELS[channel] and sentShared[text]
    if not t or GetTime() - t > ECHO_WINDOW then return false end
    selfNames[sender] = true
    local ghost = ns.db.chars[sender]
    if ghost and not ghost.isMine then
        ns.db.chars[sender] = nil
        ns:Fire("DATA_UPDATED")   -- no name: listeners mustn't look the removed character up
    end
    return true
end

ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or not ns.me then return end
    sender = ns.FullName(sender)
    if sender == ns.me or IsOwnEcho(sender, text, channel) or not IsTrusted(sender, channel) then return end
    Dispatch(sender, text)
end)

-- Only Battle.net friends can send us game data, so these are trusted. The sender
-- names themselves ("N|Name-Realm|..."); remember the game account so our replies to
-- that character go back over Battle.net too.
if BNET_OK then
    ns:On("BN_CHAT_MSG_ADDON", function(prefix, text, _, gameAccountID)
        if prefix ~= PREFIX or not ns.me or not gameAccountID or not BNetEnabled() then return end
        local sender, inner = text:match("^N|([^|]+)|(.*)$")
        if not ValidCharacter(sender) then return end
        -- 0.3.5-0.3.7 name themselves "Slim-Steaky" or "Slim Steaky-<realm>".
        sender = ns.FullName(sender)
        if sender == ns.me then return end
        bnRoute[sender] = gameAccountID
        Dispatch(sender, inner)
    end)
end

---------------------------------------------------------------------------
-- Triggers
---------------------------------------------------------------------------
ns:Listen("LOGIN", function()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_FriendList.ShowFriends()
    -- Give the guild/friend lists a moment to load, then announce ourselves.
    C_Timer.After(5, function() ns.SayHello(true, true) end)
end)

ns:Listen("SELF_CHANGED", function() ns.SayHello(false) end)

-- The first update after login just records who's online; the login hello covers them.
local onlineFriends
ns:On("FRIENDLIST_UPDATE", function()
    local now = {}
    for _, name in ipairs(OnlineFriends()) do
        now[name] = true
        if onlineFriends and not onlineFriends[name] and ns.me then
            Send(HelloText(true), "WHISPER", name)
        end
    end
    onlineFriends = now
end)

-- Same for Battle.net friends logging in (or switching character) in this game.
-- BN_FRIEND_INFO_CHANGED fires a lot, but reading the list is cheap.
local onlineBNet
if BNET_OK then
    ns:On("BN_FRIEND_INFO_CHANGED", function()
        local now = {}
        for _, id in ipairs(BNetFriends()) do
            now[id] = true
            if onlineBNet and not onlineBNet[id] and ns.me then
                Send(HelloText(true), "BNET", id)
            end
        end
        onlineBNet = now
    end)
end

ns:On("GROUP_JOINED", function()
    local group = SyncGroupChannel()
    if group and ns.me then Send(HelloText(true), group) end
end)
