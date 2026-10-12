-- Comm: syncs sections between players over hidden addon messages.
--
-- Protocol (prefix "FrndProg"):
--   H|<proto>|<reply>|sec=hash,sec=hash,...   "here is what I have"; reply=1 asks for your H back
--   Q|sec,sec,...                              "send me these sections" (always whispered)
--   D|<id>|<i>|<n>|<chunk>                     section data, split into <n> chunks
-- A receiver compares hashes from H with what it has stored and only pulls what changed.
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

local function Pump()
    local msg = queue[1]
    if not msg then
        ticker:Cancel()
        ticker = nil
        return
    end
    local result = C_ChatInfo.SendAddonMessage(PREFIX, msg[1], msg[2], msg[3])
    if THROTTLED and result == THROTTLED then return end   -- retry next tick
    table.remove(queue, 1)
end

local function Send(text, channel, target)
    queue[#queue + 1] = { text, channel, target }
    if not ticker then ticker = C_Timer.NewTicker(SEND_INTERVAL, Pump) end
end

---------------------------------------------------------------------------
-- Who to talk to: guild, current group, and online WoW friends
---------------------------------------------------------------------------
local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local function OnlineFriends()
    local list = {}
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then list[#list + 1] = info.name end
    end
    return list
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
    local text = HelloText(reply)
    if IsInGuild() then Send(text, "GUILD") end
    local group = GroupChannel()
    if group then Send(text, group) end
    for _, name in ipairs(OnlineFriends()) do Send(text, "WHISPER", name) end
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
        Send(("D|%d|%d|%d|%s"):format(msgId, i, n, chunk), "WHISPER", target)
    end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local lastReply = {}
local buffers = {}

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
    if not section then return end
    local data = ns.Deserialize(body)
    if type(data) ~= "table" then return end
    local c = ns.GetChar(sender)
    if section == "log" then NotifyLog(sender, c.sections.log, data) end
    c.sections[section] = data
    c.hashes[section] = hash
    c.lastSeen = GetServerTime()
    ns:Fire("DATA_UPDATED")
end

local handlers = {}

handlers.H = function(sender, rest)
    local proto, reply, list = rest:match("^(%d+)|(%d)|(.*)$")
    if not proto or tonumber(proto) ~= ns.PROTOCOL then return end
    local c = ns.GetChar(sender)
    c.lastSeen = GetServerTime()
    local need = {}
    for section, hash in list:gmatch("(%w+)=([%x%-]+)") do
        if hash == "-" then
            -- They stopped sharing this section: forget our copy.
            c.sections[section], c.hashes[section] = nil, nil
        elseif c.hashes[section] ~= hash then
            need[#need + 1] = section
        end
    end
    if #need > 0 then Send("Q|" .. table.concat(need, ","), "WHISPER", sender) end
    if reply == "1" and GetTime() - (lastReply[sender] or 0) > REPLY_COOLDOWN then
        lastReply[sender] = GetTime()
        Send(HelloText(false), "WHISPER", sender)
    end
    ns:Fire("DATA_UPDATED")
end

handlers.Q = function(sender, rest)
    for section in rest:gmatch("[^,]+") do SendSection(section, sender) end
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
    local group = GroupChannel()
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
        math.floor(GetXPExhaustion() or 0)), group)
end

function ns.SetLiveXPSharing(enabled)
    if enabled then
        ns.SendLiveXP()
    else
        local group = GroupChannel()
        if group then Send("X|off", group) end
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
ns:On("GROUP_ROSTER_UPDATE", function() ns.SendLiveXP() end)

ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or not ns.me then return end
    sender = ns.FullName(sender)
    if sender == ns.me then return end
    local kind, rest = text:match("^(%a)|(.*)$")
    local fn = kind and handlers[kind]
    if fn then fn(sender, rest) end
end)

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

ns:On("GROUP_JOINED", function()
    local group = GroupChannel()
    if group and ns.me then Send(HelloText(true), group) end
end)
