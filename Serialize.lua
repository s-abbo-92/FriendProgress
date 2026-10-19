-- Compact, deterministic table serializer (no loadstring, so received data can't run code).
--   number  -> n<digits>;      string -> s<bytelen>:<bytes>
--   true    -> T               false  -> F
--   table   -> { key value key value ... }
-- Keys are sorted so the same data always produces the same string (and hash).
local _, ns = ...

local tostring, tonumber, type, pairs, sort, concat = tostring, tonumber, type, pairs, table.sort, table.concat
local sub, find = string.sub, string.find

local function KeyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
end

local function Write(v, out)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = "n" .. tostring(v) .. ";"
    elseif t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do
            local kt = type(k)
            if kt == "number" or kt == "string" then keys[#keys + 1] = k end
        end
        sort(keys, KeyLess)
        out[#out + 1] = "{"
        for i = 1, #keys do
            Write(keys[i], out)
            Write(v[keys[i]], out)
        end
        out[#out + 1] = "}"
    end
    -- functions/userdata/nil values are skipped
end

function ns.Serialize(v)
    local out = {}
    Write(v, out)
    return concat(out)
end

-- Input comes from other players, so every token is checked: a bad length must
-- never move the read position backwards (that would loop forever).
local MAX_DEPTH = 8

local Read
Read = function(s, pos, depth)
    local c = sub(s, pos, pos)
    if c == "n" then
        local e = find(s, ";", pos, true)
        if not e then error("unterminated number") end
        local n = tonumber(sub(s, pos + 1, e - 1))
        if not n then error("bad number at " .. pos) end
        return n, e + 1
    elseif c == "s" then
        local colon = find(s, ":", pos, true)
        if not colon then error("unterminated string header") end
        local len = tonumber(sub(s, pos + 1, colon - 1))
        if not len or len < 0 or len % 1 ~= 0 or colon + len > #s then error("bad string length at " .. pos) end
        return sub(s, colon + 1, colon + len), colon + len + 1
    elseif c == "T" then
        return true, pos + 1
    elseif c == "F" then
        return false, pos + 1
    elseif c == "{" then
        if depth >= MAX_DEPTH then error("nested too deep") end
        local t = {}
        pos = pos + 1
        while sub(s, pos, pos) ~= "}" do
            if pos > #s then error("unterminated table") end
            local k, v
            k, pos = Read(s, pos, depth + 1)
            v, pos = Read(s, pos, depth + 1)
            if type(k) == "number" or type(k) == "string" then t[k] = v end
        end
        return t, pos + 1
    end
    error("bad token at " .. pos)
end

-- Returns the value, or nil if the string is malformed.
function ns.Deserialize(s)
    local ok, v = pcall(Read, s, 1, 0)
    if ok then return v end
end

-- 32-bit polynomial hash, rendered as hex. Only used to detect changes.
function ns.Hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end
