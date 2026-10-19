-- SyncButton: optional on-screen "Sync" button, movable while frames are unlocked.
local _, ns = ...

local button

local function Settings() return ns.db.settings.syncButton end

local function ApplyPosition()
    button:ClearAllPoints()
    local pos = Settings().pos
    if pos then
        button:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -190)
    end
end

local function Build()
    button = ns.Skin.Button(UIParent, "Sync", 80, 22, function() ns.SyncNow() end, "FriendProgressSyncButton")
    button:SetFrameStrata("LOW")
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if not ns.db.settings.locked then self:StartMoving() end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().pos = { point, relPoint, x, y }
    end)
    local base = button:GetScript("OnEnter")   -- the skin's hover highlight
    button:SetScript("OnEnter", function(self)
        base(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("FriendProgress")
        GameTooltip:AddLine("Rescan yourself and ask friends for updates.", 1, 1, 1, true)
        if not ns.db.settings.locked then
            GameTooltip:AddLine("Unlocked: drag to move, /fp lock when done.", 0.5, 0.8, 1, true)
        end
        GameTooltip:Show()
    end)
    local baseLeave = button:GetScript("OnLeave")
    button:SetScript("OnLeave", function(self)
        baseLeave(self)
        GameTooltip:Hide()
    end)

    button.hint = ns.Skin.Font(button, 11, ns.Skin.C.muted)
    button.hint:SetPoint("BOTTOM", button, "TOP", 0, 3)
    button.hint:SetText("Drag to move")

    ApplyPosition()
end

function ns.RefreshSyncButton()
    if not ns.db then return end
    if not Settings().enabled then
        if button then button:Hide() end
        return
    end
    if not button then Build() end
    button.hint:SetShown(not ns.db.settings.locked)
    button:Show()
end

function ns.ResetSyncButtonPosition()
    Settings().pos = nil
    if button then ApplyPosition() end
end

-- Grey the button out during the sync cooldown, whichever button started it.
ns:Listen("SYNC_STARTED", function(cooldown)
    if not button then return end
    button:Disable()
    button:SetText("Syncing...")
    C_Timer.After(cooldown, function()
        button:Enable()
        button:SetText("Sync")
    end)
end)

ns:Listen("LOGIN", function() ns.RefreshSyncButton() end)
