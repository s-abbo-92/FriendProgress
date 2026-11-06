-- Validate: rebuilds data received from other players into the shapes the rest of
-- the addon expects. Anything unexpected is dropped or defaulted, strings are
-- length-capped and stripped of control characters, and "|" is doubled so peers
-- can't inject colour codes or links (except in activity-feed lines, which carry
-- item links on purpose).
local _, ns = ...

local type, pairs, ipairs = type, pairs, ipairs

local LIMITS = { items = 600, gear = 19, profs = 12, recipes = 1500, reagents = 12, quests = 50, objectives = 10, log = 30 }

local function Num(v, default)
    if type(v) == "number" and v == v and v > -1e15 and v < 1e15 then return v end
    return default
end

local function Str(v, max, keepPipes)
    if type(v) ~= "string" then return nil end
    v = v:sub(1, max):gsub("%c", "")
    if not keepPipes then v = v:gsub("|", "||") end
    return v
end
ns.CleanText = function(v, max) return Str(v, max or 60) or "" end

-- Copies a { number = number } map, keeping at most max valid entries.
local function NumMap(t, max)
    local out, n = {}, 0
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if type(k) == "number" and type(v) == "number" and v == v then
            n = n + 1
            if n > max then break end
            out[k] = v
        end
    end
    return out
end

local function Container(d)
    local out = {
        items = NumMap(d.items, LIMITS.items),
        free = Num(d.free), total = Num(d.total), money = Num(d.money), t = Num(d.t),
    }
    local f = d.filter
    out.filter = (f == "all" or f == "materials" or f == "none") and f or nil
    return out
end

local clean = {}

function clean.char(d)
    local class = Str(d.class, 20)
    return {
        name = Str(d.name, 48), race = Str(d.race, 30), guild = Str(d.guild, 80), zone = Str(d.zone, 80),
        class = class and class:match("^%u+$") or nil,
        level = Num(d.level, 0), xp = Num(d.xp, 0), xpMax = Num(d.xpMax), rested = Num(d.rested, 0),
        xph = Num(d.xph),
        ilvl = Num(d.ilvl),
    }
end

function clean.gear(d)
    local out = {}
    for slot = 1, LIMITS.gear do
        local item = Str(d[slot], 200, true)
        if item and item:match("^item:[%d:%-]*$") then out[slot] = item end
    end
    return out
end

clean.bags = Container
clean.bank = Container

function clean.prof(d)
    local out = {}
    for i = 1, LIMITS.profs do
        local p = d[i]
        if type(p) ~= "table" then break end
        local name = Str(p.name, 40)
        if name then
            out[#out + 1] = {
                name = name, rank = Num(p.rank, 0), max = Num(p.max, 0), id = Num(p.id), icon = Num(p.icon),
            }
        end
    end
    return out
end

-- { [recipeID] = { [itemID] = count } }
local function Mats(t)
    local out, n = {}, 0
    if type(t) ~= "table" then return out end
    for recipeID, reagents in pairs(t) do
        if type(recipeID) == "number" and type(reagents) == "table" then
            n = n + 1
            if n > LIMITS.recipes then break end
            out[recipeID] = NumMap(reagents, LIMITS.reagents)
        end
    end
    return out
end

function clean.recipes(d)
    local out, profs = {}, 0
    for name, entry in pairs(d) do
        if type(name) == "string" and type(entry) == "table" then
            profs = profs + 1
            if profs > LIMITS.profs then break end
            out[Str(name, 40)] = {
                id = Num(entry.id), t = Num(entry.t, 0),
                list = NumMap(entry.list, LIMITS.recipes), mats = Mats(entry.mats),
            }
        end
    end
    return out
end

function clean.quest(d)
    local out = {}
    for i = 1, LIMITS.quests do
        local q = d[i]
        if type(q) ~= "table" then break end
        local id = Num(q.id)
        if id then
            local obj = {}
            for j = 1, LIMITS.objectives do
                local o = type(q.obj) == "table" and q.obj[j]
                if type(o) ~= "table" then break end
                obj[j] = { Str(o[1], 200) or "", o[2] == true }
            end
            out[#out + 1] = {
                id = id, title = Str(q.title, 120), level = Num(q.level, 0), done = q.done == true, obj = obj,
            }
        end
    end
    return out
end

function clean.log(d)
    local out = {}
    for i = 1, LIMITS.log do
        local e = d[i]
        if type(e) ~= "table" then break end
        local m = Str(e.m, 300, true)
        if m and Num(e.t) then out[#out + 1] = { t = e.t, m = m, k = Str(e.k, 10) } end
    end
    return out
end

local KNOWN = {}
for _, s in ipairs(ns.SECTIONS) do KNOWN[s] = true end
function ns.IsSection(name) return KNOWN[name] == true end

-- Returns a cleaned copy of a received section, or nil if it isn't usable.
function ns.SanitizeSection(section, data)
    local fn = clean[section]
    if not fn or type(data) ~= "table" then return nil end
    local ok, out = pcall(fn, data)
    return ok and out or nil
end
