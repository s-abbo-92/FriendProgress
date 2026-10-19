-- Collect: snapshots the player's own character into sections and keeps an activity log.
local _, ns = ...

local LOG_MAX = 30
local SCAN_DELAY = 2   -- seconds to batch bursts of events (e.g. BAG_UPDATE spam)

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function Me()
    return ns.GetChar(ns.me)
end

-- kind ("level", "quest", "prof", "gear") lets Share.lua hide entries for unshared sections.
local function AddLog(text, kind)
    if not ns.me then return end
    local c = Me()
    local log = c.sections.log or {}
    table.insert(log, 1, { t = GetServerTime(), m = text, k = kind })
    for i = #log, LOG_MAX + 1, -1 do log[i] = nil end
    c.sections.log = log
    ns.MarkDirty("log")
end
ns.AddLog = AddLog

---------------------------------------------------------------------------
-- Section scanners. Each returns a plain table that gets serialized and sent.
---------------------------------------------------------------------------
local scanners = {}

function scanners.char()
    local _, classFile = UnitClass("player")
    local d = {
        name = UnitName("player"),
        class = classFile,
        race = (UnitRace("player")),
        level = UnitLevel("player"),
        xp = UnitXP("player"),
        xpMax = UnitXPMax("player"),
        rested = GetXPExhaustion() or 0,
        zone = GetZoneText(),
        guild = (GetGuildInfo("player")),
    }
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        d.ilvl = equipped and math.floor(equipped + 0.5)
    end
    return d
end

local GEAR_SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

function scanners.gear()
    local d = {}
    for _, slot in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        -- Send the item string, not the ID, so random suffixes and enchants survive.
        local itemString = link and link:match("|H(item:[^|]+)|h")
        if itemString then
            d[slot] = itemString:gsub(":+$", "")
        end
    end
    return d
end

-- Counts items per itemID across the given container IDs.
local function ScanContainers(bagIDs)
    local items, free, total = {}, 0, 0
    for _, bag in ipairs(bagIDs) do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        total = total + slots
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                items[info.itemID] = (items[info.itemID] or 0) + (info.stackCount or 1)
            else
                free = free + 1
            end
        end
    end
    return items, free, total
end

local BAG_IDS = {}
for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do BAG_IDS[#BAG_IDS + 1] = bag end

-- Forever numbers the character bank as CharacterBankTab_1.._9 (main bank plus
-- bank bags); older clients use BANK_CONTAINER (-1) plus numbered bank bags.
local BANK_IDS = {}
if Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 then
    for i = 1, 9 do
        local id = Enum.BagIndex["CharacterBankTab_" .. i]
        if id then BANK_IDS[#BANK_IDS + 1] = id end
    end
else
    BANK_IDS[1] = BANK_CONTAINER or -1
    local first = (NUM_BAG_SLOTS or 4) + 1
    for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do BANK_IDS[#BANK_IDS + 1] = bag end
end

function scanners.bags()
    local items, free, total = ScanContainers(BAG_IDS)
    return { items = items, free = free, total = total, money = GetMoney() }
end

-- The bank can only be read while it's open; otherwise keep the last snapshot.
local bankOpen = false
function scanners.bank()
    if not bankOpen then return nil end
    local items, free, total = ScanContainers(BANK_IDS)
    if total == 0 then return nil end   -- contents not loaded yet
    return { items = items, free = free, total = total, t = GetServerTime() }
end

local lastProf = nil
function scanners.prof()
    local d = {}
    -- GetProfessions returns a variable number of indices (Forever adds First Aid), some nil.
    local indices = { GetProfessions() }
    for i = 1, select("#", GetProfessions()) do
        local index = indices[i]
        if index then
            local name, icon, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
            if name then
                d[#d + 1] = { name = name, icon = icon, rank = rank or 0, max = maxRank or 0, id = skillLine }
            end
        end
    end
    -- Log new professions and every 25 skill points.
    if lastProf then
        for _, p in ipairs(d) do
            local old = lastProf[p.name]
            if not old then
                AddLog("Learned " .. p.name, "prof")
            elseif math.floor(p.rank / 25) > math.floor(old / 25) then
                AddLog(p.name .. " reached " .. p.rank, "prof")
            end
        end
    end
    lastProf = {}
    for _, p in ipairs(d) do lastProf[p.name] = p.rank end
    return d
end

---------------------------------------------------------------------------
-- Recipes. Like the bank, they can only be read while the player's own
-- profession window is open, so each open records that profession's list:
--   sections.recipes = { [profName] = { id = skillLine, t = time, list = { [recipeID] = outputItemID or 0 } } }
---------------------------------------------------------------------------
local outputCache = {}
local function OutputItem(recipeID)
    if outputCache[recipeID] then return outputCache[recipeID] end
    local id = 0
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if ok and schematic and schematic.outputItemID and schematic.outputItemID > 0 then
        id = schematic.outputItemID
    elseif C_TradeSkillUI.GetRecipeOutputItemData then
        local ok2, data = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if ok2 and type(data) == "table" and data.itemID and data.itemID > 0 then id = data.itemID end
    end
    outputCache[recipeID] = id
    return id
end

-- False when the window shows someone else's (linked/guild) or an NPC's recipes.
local function OwnTradeSkillShown()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetBaseProfessionInfo) then return false end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return false end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return false end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return false end
    return true
end

local function SameList(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function CaptureRecipes()
    if not ns.me or not OwnTradeSkillShown() then return end
    local base = C_TradeSkillUI.GetBaseProfessionInfo()
    local profName = base and base.professionName
    if not profName or profName == "" then return end
    local list, count = {}, 0
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and info.learned then
            list[recipeID] = OutputItem(recipeID)
            count = count + 1
        end
    end
    if count == 0 then return end   -- list not loaded yet; TRADE_SKILL_LIST_UPDATE will follow
    local c = Me()
    local all = c.sections.recipes or {}
    local old = all[profName]
    if old and SameList(old.list or {}, list) then return end   -- unchanged: don't resync
    all[profName] = { id = base.professionID, t = GetServerTime(), list = list }
    c.sections.recipes = all
    ns.MarkDirty("recipes")
end

-- Drops professions the player has since unlearned.
function scanners.recipes()
    local c = Me()
    local all = c.sections.recipes
    if not all then return nil end
    -- Match on name or skill line, in case the two APIs disagree on either.
    local known = {}
    for _, p in ipairs(c.sections.prof or {}) do
        known[p.name] = true
        if p.id then known[p.id] = true end
    end
    if next(known) then
        for name, entry in pairs(all) do
            if not known[name] and not (entry.id and known[entry.id]) then all[name] = nil end
        end
    end
    return all
end

local questTitles = {}   -- questID -> title, so turn-ins can be named after they leave the log
function scanners.quest()
    local d = {}
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
            local q = {
                id = info.questID,
                title = info.title,
                level = info.level,
                done = C_QuestLog.IsComplete(info.questID) or false,
                obj = {},
            }
            for _, o in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
                q.obj[#q.obj + 1] = { o.text or "", o.finished or false }
            end
            questTitles[info.questID] = info.title
            d[#d + 1] = q
        end
    end
    return d
end

---------------------------------------------------------------------------
-- Dirty tracking: events mark sections dirty, a short timer rescans them.
---------------------------------------------------------------------------
local dirty, timer = {}, nil
local skipScan = {}   -- sections whose data was already updated in place (e.g. money), so no rescan

local function Flush()
    timer = nil
    if not ns.me then return end
    local c = Me()
    local changed = false
    -- Copy first: scanners may call AddLog, which marks "log" dirty for the next flush.
    local todo = {}
    for section in pairs(dirty) do todo[#todo + 1] = section end
    wipe(dirty)
    local skip = skipScan
    skipScan = {}
    for _, section in ipairs(todo) do
        if scanners[section] and not skip[section] then
            local ok, data = pcall(scanners[section])
            if ok and data then
                c.sections[section] = data
            elseif not ok then
                ns.Print("scan '" .. section .. "' failed: " .. tostring(data))
            end
        end
        local hash = c.sections[section] and ns.Hash(ns.Serialize(c.sections[section]))
        if hash and hash ~= c.hashes[section] then
            c.hashes[section] = hash
            changed = true
        end
    end
    c.lastSeen = GetServerTime()
    if changed then
        ns:Fire("DATA_UPDATED")
        -- Only announce when the filtered (shared) view changed, e.g. hidden
        -- bag items moving around don't trigger a sync.
        if ns.UpdateSharedHashes() then ns:Fire("SELF_CHANGED") end
    end
end

function ns.MarkDirty(section)
    dirty[section] = true
    if not timer then timer = C_Timer.NewTimer(SCAN_DELAY, Flush) end
end

function ns.CollectAll()
    for _, s in ipairs(ns.SECTIONS) do dirty[s] = true end
    Flush()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function Dirty(section) return function() ns.MarkDirty(section) end end

ns:Listen("LOGIN", function()
    -- Item and quest data can be incomplete right at login; scan a bit later too.
    ns.CollectAll()
    C_Timer.After(10, ns.CollectAll)
end)

ns:On("PLAYER_XP_UPDATE", Dirty("char"))
ns:On("ZONE_CHANGED_NEW_AREA", Dirty("char"))
ns:On("PLAYER_GUILD_UPDATE", Dirty("char"))
ns:On("PLAYER_EQUIPMENT_CHANGED", function(slot)
    ns.MarkDirty("gear")
    ns.MarkDirty("char")   -- item level
    local link = slot and GetInventoryItemLink("player", slot)
    local quality = link and select(3, GetItemInfo(link))
    if quality and quality >= 3 then AddLog("Equipped " .. link, "gear") end
end)
ns:On("BAG_UPDATE_DELAYED", function()
    skipScan.bags = nil   -- contents changed: a full scan is needed after all
    ns.MarkDirty("bags")
    if bankOpen then ns.MarkDirty("bank") end
end)
ns:On("BANKFRAME_OPENED", function()
    bankOpen = true
    ns.MarkDirty("bank")   -- the 2s scan delay gives bank contents time to load
end)
ns:On("BANKFRAME_CLOSED", function() bankOpen = false end)
ns:On("PLAYERBANKSLOTS_CHANGED", function() if bankOpen then ns.MarkDirty("bank") end end)
-- Looting coin shouldn't rescan every bag slot: just update the stored amount.
ns:On("PLAYER_MONEY", function()
    local bags = ns.me and Me().sections.bags
    if bags and not dirty.bags then
        bags.money = GetMoney()
        skipScan.bags = true
    end
    ns.MarkDirty("bags")
end)
ns:On("SKILL_LINES_CHANGED", function()
    ns.MarkDirty("prof")
    ns.MarkDirty("recipes")
end)

-- TRADE_SKILL_LIST_UPDATE can fire in bursts; capture at most twice a second.
local capturePending = false
local function QueueCapture()
    if capturePending then return end
    capturePending = true
    C_Timer.After(0.5, function()
        capturePending = false
        CaptureRecipes()
    end)
end
ns:On("TRADE_SKILL_SHOW", QueueCapture)
ns:On("TRADE_SKILL_LIST_UPDATE", QueueCapture)
ns:On("TRADE_SKILL_DATA_SOURCE_CHANGED", QueueCapture)
ns:On("NEW_RECIPE_LEARNED", function(recipeID)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(recipeID)
    if name then AddLog("Learned recipe: " .. name, "prof") end
    QueueCapture()   -- picks it up if the profession window is open
end)
ns:On("QUEST_LOG_UPDATE", Dirty("quest"))

ns:On("PLAYER_LEVEL_UP", function(level)
    AddLog("Reached level " .. level, "level")
    ns.MarkDirty("char")
end)
ns:On("QUEST_ACCEPTED", function(questID)
    local title = C_QuestLog.GetTitleForQuestID(questID) or ("quest " .. questID)
    questTitles[questID] = title
    AddLog("Accepted: " .. title, "quest")
end)
ns:On("QUEST_TURNED_IN", function(questID)
    local title = questTitles[questID] or C_QuestLog.GetTitleForQuestID(questID) or ("quest " .. questID)
    AddLog("Completed: " .. title, "quest")
    ns.MarkDirty("quest")
end)
