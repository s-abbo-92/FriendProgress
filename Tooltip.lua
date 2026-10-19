-- Tooltip: adds "who has this / who can craft this" lines to every item tooltip,
-- from the bags, bank and recipes data already synced.
local _, ns = ...

local MAX_HOLDERS = 8
local MAX_CRAFTERS = 6

-- index.have[itemID][key] = { bags = n, bank = n }; index.craft[itemID][key] = true
-- Rebuilt lazily after any data change, so hovering never walks every recipe list.
local index

local function Settings() return ns.db.settings.tooltip end

local function Build()
    index = { have = {}, craft = {} }
    local includeMine = Settings().mine
    for key, c in pairs(ns.db.chars) do
        if key ~= ns.me and (includeMine or not c.isMine) then
            local function Add(items, where)
                for id, count in pairs(items or {}) do
                    local byChar = index.have[id] or {}
                    index.have[id] = byChar
                    local h = byChar[key] or {}
                    byChar[key] = h
                    h[where] = count
                end
            end
            Add(c.sections.bags and c.sections.bags.items, "bags")
            Add(c.sections.bank and c.sections.bank.items, "bank")
            for _, r in pairs(c.sections.recipes or {}) do
                for _, itemID in pairs(r.list or {}) do
                    if itemID > 0 then
                        index.craft[itemID] = index.craft[itemID] or {}
                        index.craft[itemID][key] = true
                    end
                end
            end
        end
    end
end

local function Invalidate() index = nil end
ns.InvalidateTooltipIndex = Invalidate

-- DATA_UPDATED(key, section): only changes to others' bags, bank or recipes matter here.
-- No arguments (e.g. a character was forgotten) or an unknown section rebuilds, to be safe.
local IRRELEVANT = { own = true, hello = true, deaths = true, char = true, gear = true, prof = true, quest = true, log = true }
ns:Listen("DATA_UPDATED", function(key, section)
    if key == ns.me or (section and IRRELEVANT[section]) then return end
    Invalidate()
end)

local function DisplayName(key)
    local c = ns.db.chars[key]
    local s = c and c.sections.char or {}
    return ns.ClassColored(s.name or Ambiguate(key, "short"), s.class)
end

local function SortedKeys(set, value)
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local va, vb = value(a), value(b)
        if va ~= vb then return va > vb end
        return a < b
    end)
    return keys
end

local function AddLines(tooltip, itemID)
    if not index then Build() end
    local holders = index.have[itemID]
    local crafters = index.craft[itemID]
    if not holders and not crafters then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("FriendProgress", 0.2, 1, 0.6)

    if holders then
        local function Total(key) return (holders[key].bags or 0) + (holders[key].bank or 0) end
        local keys = SortedKeys(holders, Total)
        local total = 0
        for i, key in ipairs(keys) do
            local h = holders[key]
            total = total + Total(key)
            if i <= MAX_HOLDERS then
                local where
                if h.bags and h.bank then
                    where = ("%d  |cff999999(bags %d, bank %d)|r"):format(Total(key), h.bags, h.bank)
                elseif h.bank then
                    where = h.bank .. "  |cff999999(bank)|r"
                else
                    where = tostring(h.bags)
                end
                tooltip:AddDoubleLine(DisplayName(key), where, 1, 1, 1, 1, 1, 1)
            end
        end
        if #keys > MAX_HOLDERS then
            tooltip:AddLine(("...and %d more"):format(#keys - MAX_HOLDERS), 0.6, 0.6, 0.6)
        end
        if #keys > 1 then tooltip:AddDoubleLine("Total", tostring(total), 1, 0.82, 0, 1, 0.82, 0) end
    end

    if crafters then
        local keys = SortedKeys(crafters, function() return 0 end)
        local names = {}
        for i = 1, math.min(#keys, MAX_CRAFTERS) do names[i] = DisplayName(keys[i]) end
        local text = "Can craft: " .. table.concat(names, ", ")
        if #keys > MAX_CRAFTERS then text = text .. (" +%d more"):format(#keys - MAX_CRAFTERS) end
        tooltip:AddLine(text, 1, 0.82, 0, true)
    end
end

local function OnItem(tooltip, data)
    if not ns.db or not Settings().enabled then return end
    -- Only the main and pinned item tooltips, not comparison or embedded ones.
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if tooltip:IsForbidden() then return end
    local id = data and data.id
    if not id or (issecretvalue and issecretvalue(id)) then return end
    AddLines(tooltip, id)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItem)
end
