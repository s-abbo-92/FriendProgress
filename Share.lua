-- Share: applies the player's sharing settings to what gets sent to friends.
-- The full snapshot stays local; only the filtered copy is hashed and sent.
local _, ns = ...

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local MATERIAL_CLASSES = {
    [Enum.ItemClass and Enum.ItemClass.Tradegoods or 7] = true,
    [Enum.ItemClass and Enum.ItemClass.Reagent or 5] = true,
}

function ns.IsCraftingMaterial(itemID)
    local classID = select(6, GetItemInfoInstant(itemID))
    return classID and MATERIAL_CLASSES[classID] or false
end

-- Each filter returns the data to send, or nil to withhold the section.
local filters = {}

-- Friends see XP in steps of 5% of the level, not every kill, so earning XP doesn't
-- change what we share (and trigger a sync). The party XP box has live values.
local function Step(value, max)
    if not value or not max or max <= 0 then return value end
    local step = max / 20
    return math.floor(value / step) * step
end

function filters.char(d, share)
    local copy = CopyTable(d)
    copy.xp = Step(d.xp, d.xpMax)
    copy.rested = Step(d.rested, d.xpMax)
    if not share.zone then copy.zone = nil end
    return copy
end

-- Gold is shared to two significant digits (123g 45s -> 120g), for the same reason:
-- every coin looted would otherwise count as a change worth syncing.
local function RoundMoney(copper)
    if not copper or copper < 100 then return copper end
    local step = 10 ^ (math.floor(math.log10(copper)) - 1)
    return math.floor(copper / step) * step
end

function filters.gear(d, share) return share.gear and d or nil end
function filters.prof(d, share) return share.prof and d or nil end
function filters.recipes(d, share) return share.recipes and d or nil end
function filters.quest(d, share) return share.quest and d or nil end

-- Copies a bags/bank snapshot with only the contents that mode allows.
local function FilterContainer(d, mode)
    local out = { filter = mode }
    if mode == "all" then
        out.items, out.free, out.total = d.items, d.free, d.total
    elseif mode == "materials" then
        out.items = {}
        for id, count in pairs(d.items or {}) do
            if ns.IsCraftingMaterial(id) then out.items[id] = count end
        end
    end
    return out
end

function filters.bags(d, share)
    if share.bags == "none" and not share.gold then return nil end
    local out = FilterContainer(d, share.bags)
    out.money = share.gold and RoundMoney(d.money) or nil
    return out
end

function filters.bank(d, share)
    if share.bank == "none" then return nil end
    local out = FilterContainer(d, share.bank)
    out.t = d.t
    return out
end

-- Log entries are tagged by kind; drop the ones whose section is hidden.
local LOG_KIND_SETTING = { quest = "quest", gear = "gear", prof = "prof" }
function filters.log(d, share)
    if not share.log then return nil end
    local out = {}
    for _, e in ipairs(d) do
        local setting = e.k and LOG_KIND_SETTING[e.k]
        if not setting or share[setting] then out[#out + 1] = e end
    end
    return out
end

function ns.SharedSection(section)
    local data = ns.GetChar(ns.me).sections[section]
    local filter = filters[section]
    if data == nil or not filter then return nil end
    return filter(data, ns.db.settings.share)
end

-- Recomputes the hashes friends see. "-" means "withheld: delete your copy".
-- Returns true if anything a friend would see has changed.
-- sections: optional list of the sections that were rescanned; the rest can't have changed.
function ns.UpdateSharedHashes(sections)
    local c = ns.GetChar(ns.me)
    c.sharedHashes = c.sharedHashes or {}
    local changed = false
    for _, section in ipairs(sections or ns.SECTIONS) do
        local hash
        if c.sections[section] ~= nil then
            local data = ns.SharedSection(section)
            hash = data and ns.Hash(ns.Serialize(data)) or "-"
        end
        if hash ~= c.sharedHashes[section] then
            c.sharedHashes[section] = hash
            changed = true
        end
    end
    return changed
end

-- Runs after Collect's login scan (Share.lua loads later), so hashes exist before the first hello.
ns:Listen("LOGIN", function() ns.UpdateSharedHashes() end)

function ns.ShareSettingsChanged()
    if ns.UpdateSharedHashes() then ns.SayHello(false) end
end
