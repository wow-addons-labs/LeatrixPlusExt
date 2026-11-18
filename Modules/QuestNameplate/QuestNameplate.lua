-- LeatrixPlusExt 模块：在 Questie 的姓名板任务图标后面显示目标进度
local addonName, NS = ...

local DEFAULT = false

local ICON_SIZE = 16
local TEXT_GAP = 2
local BASE_FONT_SIZE = 10
local TEXT_RED, TEXT_GREEN, TEXT_BLUE = 1, 0.82, 0

-- Questie 的 GetValidIcon 只认识这些图标类型；用它来保证文字和图标对应同一个目标
local VALID_ICON_KEYS = {
    "ICON_TYPE_LOOT",
    "ICON_TYPE_OBJECT",
    "ICON_TYPE_SLAY",
    "ICON_TYPE_EVENT",
    "ICON_TYPE_TALK",
    "ICON_TYPE_INTERACT",
    "ICON_TYPE_MOUNT_UP",
    "ICON_TYPE_PET_BATTLE",
    "ICON_TYPE_AVAILABLE",
    "ICON_TYPE_AVAILABLE_GRAY",
    "ICON_TYPE_REPEATABLE",
    "ICON_TYPE_COMPLETE",
}

local QuestieNameplate
local QuestieTooltips
local QuestieDB
local QuestLogCache

local validIconTypes = {}
local hasValidIconTypes = false

local enabled = false
local ready = false
local onReadyRegistered = false
local hooksInstalled = false
local questUpdatesRegistered = false

-- [guid] = 姓名板 token；即使当前没有文字也要记录，接任务后才能立刻补上
local plateTokens = {}
-- [guid] = { frame = FontString 所在的 Frame }
local frames = {}
local unusedFrames = {}
-- [itemId:npcId] = 掉落概率文字
local dropRateCache = {}

local function GetProfile()
    local questie = _G.Questie
    local db = questie and questie.db
    return db and db.profile
end

local function IconsVisible()
    local profile = GetProfile()
    if not profile or not profile.nameplateEnabled then
        return false
    end
    local questie = _G.Questie
    if questie.IsForever and IsInInstance() then
        return false
    end
    return true
end

local function GetIconScale()
    local profile = GetProfile()
    local scale = profile and profile.nameplateScale
    if type(scale) ~= "number" or scale <= 0 then
        scale = 1.1
    end
    return scale
end

local function GetIconAnchor()
    local profile = GetProfile() or {}
    local x = tonumber(profile.nameplateX) or -4
    local y = tonumber(profile.nameplateY) or 16
    return x, y
end

local function GetNpcId(guid)
    if type(guid) ~= "string" then
        return nil
    end
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then
        return nil
    end
    -- Questie 的掉落数据按数字 NPC ID 索引，字符串查不到。
    return tonumber(npcId)
end

local function BuildValidIconTypes()
    validIconTypes = {}
    hasValidIconTypes = false
    local questie = _G.Questie
    if not questie then
        return
    end
    for _, key in ipairs(VALID_ICON_KEYS) do
        local value = questie[key]
        if value ~= nil then
            validIconTypes[value] = true
            hasValidIconTypes = true
        end
    end
end

local function IsValidIconType(iconType)
    if iconType == nil then
        return false
    end
    if not hasValidIconTypes then
        return true
    end
    return validIconTypes[iconType] == true
end

local function ImportQuestieModule(name)
    if not QuestieLoader then
        return nil
    end
    local ok, module = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
    if ok then
        return module
    end
    return nil
end

local function GetItemId(objective)
    if objective.Type ~= "item" then
        return nil
    end

    local itemId = objective.Id
    if type(itemId) ~= "number" then
        itemId = tonumber(itemId)
    end
    return itemId
end

local function GetItemName(objective, itemId)
    itemId = itemId or GetItemId(objective)
    if not itemId then
        return nil
    end

    local name
    if QuestieDB and QuestieDB.QueryItemSingle then
        local ok, result = pcall(QuestieDB.QueryItemSingle, itemId, "name")
        if ok then
            name = result
        end
    end
    if type(name) ~= "string" or name == "" then
        name = GetItemInfo(itemId)
    end
    if type(name) ~= "string" or name == "" then
        name = objective.Description
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

-- 与 Questie 任务提示里的掉落概率保持同样的精度
local function FormatDropRate(rate)
    if rate >= 10 then
        return string.format("%.0f", rate)
    elseif rate >= 2 then
        return string.format("%.1f", rate)
    elseif rate >= 0.01 then
        return string.format("%.2f", rate)
    end
    return string.format("%.3f", rate)
end

local function GetDropRateText(itemId, npcId)
    if not itemId or not npcId then
        return nil
    end

    local key = itemId .. ":" .. npcId
    local cached = dropRateCache[key]
    if cached then
        return cached
    end

    local text
    if QuestieDB and type(QuestieDB.GetItemDroprate) == "function" then
        local ok, data = pcall(QuestieDB.GetItemDroprate, itemId, npcId)
        if ok and type(data) == "table" then
            local rate = tonumber(data[1])
            if rate and rate > 0 then
                text = "[" .. FormatDropRate(rate) .. "%]"
            end
        end
    end

    -- 只缓存查到的结果：数据还没准备好时下次还能再查。
    if text then
        dropRateCache[key] = text
    end
    return text
end

-- 目标进度优先用目标对象上的数字；对象还没刷新时，改从任务记录里取最新数字
local function GetCounts(objective)
    local collected = tonumber(objective.Collected)
    local needed = tonumber(objective.Needed)
    if collected and needed and needed > 0 then
        return collected, needed
    end

    if QuestLogCache and QuestLogCache.TryGetQuest and objective.questId then
        local ok, quest = pcall(QuestLogCache.TryGetQuest, objective.questId)
        local objectives = ok and quest and quest.objectives
        local data = objectives and objectives[objective.Index]
        if data then
            collected = tonumber(data.numFulfilled)
            needed = tonumber(data.numRequired)
            if collected and needed and needed > 0 then
                return collected, needed
            end
        end
    end
end

local function FormatObjective(objective, npcId)
    local collected, needed = GetCounts(objective)
    if not collected or not needed then
        return nil
    end

    local text = collected .. "/" .. needed
    local itemId = GetItemId(objective)
    local itemName = GetItemName(objective, itemId)
    if itemName then
        text = text .. " " .. itemName
        local dropRate = GetDropRateText(itemId, npcId)
        if dropRate then
            text = text .. " " .. dropRate
        end
    end
    return text
end

-- 按 Questie 的规则挑出姓名板图标对应的那个未完成任务目标
local function FindObjective(guid)
    local npcId = GetNpcId(guid)
    if not npcId or not QuestieTooltips then
        return nil
    end

    local tooltips = QuestieTooltips.lookupByKey["m_" .. npcId]
    if type(tooltips) ~= "table" then
        return nil
    end

    for _, tooltip in pairs(tooltips) do
        local objective = tooltip and tooltip.objective
        if objective and objective.Update then
            pcall(objective.Update, objective)
            if not objective.Completed
                and IsValidIconType(objective.Icon) then
                return objective, npcId
            end
        end
    end
end

local function GetIconTexture(guid)
    local questie = _G.Questie
    local api = questie and questie.API
    if not (api and api.GetQuestObjectiveIconForUnit and api.isReady) then
        return nil
    end
    local ok, texture = pcall(api.GetQuestObjectiveIconForUnit, guid)
    if ok then
        return texture
    end
end

local function HasIcon(guid)
    local questie = _G.Questie
    local api = questie and questie.API
    if not (api and api.GetQuestObjectiveIconForUnit and api.isReady) then
        -- 没有公开接口或接口还没就绪时，以 FindObjective 的结果为准
        return true
    end
    return GetIconTexture(guid) ~= nil
end

-- Questie 的图标框：姓名板的子框，带 Icon 贴图，贴图与当前目标图标一致
local function FindIconFrame(nameplate, texture)
    if not texture then
        return nil
    end
    local ok, children = pcall(function()
        return { nameplate:GetChildren() }
    end)
    if not ok then
        return nil
    end
    for _, child in ipairs(children) do
        local icon = child.Icon
        if icon and icon.GetTexture then
            local okTexture, childTexture = pcall(icon.GetTexture, icon)
            if okTexture and childTexture == texture then
                return child
            end
        end
    end
end

local function AcquireFrame()
    local frame = table.remove(unusedFrames)
    if frame then
        return frame
    end

    frame = CreateFrame("Frame")
    frame:SetSize(200, ICON_SIZE)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(11)
    frame:EnableMouse(false)
    frame:Hide()

    frame.Text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.Text:SetJustifyH("LEFT")
    frame.Text:SetJustifyV("MIDDLE")
    frame.Text:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    return frame
end

local function ReleaseFrame(guid)
    local entry = frames[guid]
    if not entry then
        return
    end
    frames[guid] = nil

    local frame = entry.frame
    if frame then
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
        table.insert(unusedFrames, frame)
    end
end

local function HideAllFrames()
    for guid in pairs(frames) do
        ReleaseFrame(guid)
    end
end

local function UpdatePlate(guid, token)
    local nameplate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(token)
    if not enabled or not ready or not nameplate or not IconsVisible() then
        ReleaseFrame(guid)
        return
    end

    local objective, npcId = FindObjective(guid)
    local text
    if objective then
        local ok, value = pcall(FormatObjective, objective, npcId)
        if ok then
            text = value
        end
    end
    if not text or not HasIcon(guid) then
        ReleaseFrame(guid)
        return
    end

    local entry = frames[guid]
    local frame
    if entry then
        frame = entry.frame
    else
        frame = AcquireFrame()
        frames[guid] = { frame = frame }
    end

    -- 图标框存在时直接挂在它上面：和图标同一个绘制环境，位置、缩放、层级完全一致
    local scale = GetIconScale()
    local iconWidth = ICON_SIZE * scale
    local iconFrame = FindIconFrame(nameplate, GetIconTexture(guid))

    if iconFrame then
        local width = iconFrame:GetWidth()
        if type(width) == "number" and width > 0 then
            iconWidth = width
            scale = width / ICON_SIZE
        end
    end

    local font = SystemFont_NamePlate and SystemFont_NamePlate:GetFont() or frame.Text:GetFont()
    if font then
        local size = math.max(8, math.floor(BASE_FONT_SIZE * scale + 0.5))
        if not frame.Text:SetFont(font, size, "OUTLINE") then
            frame.Text:SetFontObject("GameFontNormalSmall")
        end
    end

    frame:ClearAllPoints()
    frame:SetHeight(iconWidth)
    if iconFrame then
        if frame:GetParent() ~= iconFrame then
            frame:SetParent(iconFrame)
        end
        local plateLevel = nameplate:GetFrameLevel()
        if type(plateLevel) ~= "number" then
            plateLevel = 1
        end
        local iconLevel = iconFrame:GetFrameLevel()
        if type(iconLevel) ~= "number" then
            iconLevel = plateLevel
        end
        frame:SetFrameStrata(iconFrame:GetFrameStrata())
        frame:SetFrameLevel(math.min(math.max(iconLevel + 1, plateLevel + 30), 9000))
        frame:SetPoint("LEFT", iconFrame, "RIGHT", TEXT_GAP, 0)
    else
        -- 找不到图标框时按 Questie 的设置推算位置
        local iconX, iconY = GetIconAnchor()
        if frame:GetParent() ~= nameplate then
            frame:SetParent(nameplate)
        end
        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel(11)
        frame:SetPoint("LEFT", nameplate, "LEFT", iconX + iconWidth + TEXT_GAP, iconY)
    end

    frame.Text:ClearAllPoints()
    frame.Text:SetPoint("LEFT", frame, "LEFT", 0, 0)
    frame.Text:SetText(text)
    frame:Show()
end

local function RefreshAll()
    if not enabled or not ready then
        return
    end
    if not IconsVisible() then
        HideAllFrames()
        return
    end
    for guid, token in pairs(plateTokens) do
        UpdatePlate(guid, token)
    end
end

local function OnQuestUpdate()
    if enabled then
        RefreshAll()
    end
end

local function OnNamePlateAdded(token)
    if not enabled or not ready or not IconsVisible() then
        return
    end

    local guid = UnitGUID(token)
    if not guid or not UnitName(token) or not GetNpcId(guid) then
        return
    end

    -- 同一个 token 换了 GUID 时，清掉旧记录
    for otherGuid, otherToken in pairs(plateTokens) do
        if otherToken == token and otherGuid ~= guid then
            ReleaseFrame(otherGuid)
            plateTokens[otherGuid] = nil
        end
    end

    plateTokens[guid] = token
    UpdatePlate(guid, token)
end

local function OnNamePlateRemoved(token)
    for guid, activeToken in pairs(plateTokens) do
        if activeToken == token then
            ReleaseFrame(guid)
            plateTokens[guid] = nil
        end
    end
end

local function SeedVisiblePlates()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then
        return
    end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local token = plate.namePlateUnitToken
        if not token and plate.GetUnit then
            local ok, unit = pcall(plate.GetUnit, plate)
            if ok then
                token = unit
            end
        end
        if token then
            OnNamePlateAdded(token)
        end
    end
end

local function ClearAll()
    HideAllFrames()
    plateTokens = {}
end

local function InstallHooks()
    if hooksInstalled or not QuestieNameplate then
        return
    end
    hooksInstalled = true

    -- Questie 创建图标后再定位文字，保证文字和图标框的位置、层级一致
    pcall(hooksecurefunc, QuestieNameplate, "NameplateCreated", function(token)
        if enabled and ready then
            OnNamePlateAdded(token)
        end
    end)

    -- Questie 刷新姓名板图标、改变图标位置或关闭图标时，文字一起跟着变
    pcall(hooksecurefunc, QuestieNameplate, "UpdateNameplate", RefreshAll)
    pcall(hooksecurefunc, QuestieNameplate, "RedrawIcons", RefreshAll)
    pcall(hooksecurefunc, QuestieNameplate, "HideCurrentFrames", ClearAll)
end

local function OnQuestieReady()
    if ready then
        return
    end

    local questie = _G.Questie
    if not (questie and questie.db and questie.db.profile) then
        return
    end

    QuestieNameplate = ImportQuestieModule("QuestieNameplate")
    QuestieTooltips = ImportQuestieModule("QuestieTooltips")
    QuestieDB = ImportQuestieModule("QuestieDB")
    QuestLogCache = ImportQuestieModule("QuestLogCache")

    if not QuestieTooltips or not QuestieTooltips.lookupByKey then
        return
    end

    BuildValidIconTypes()
    InstallHooks()
    ready = true

    if questie.API and questie.API.RegisterForQuestUpdates and not questUpdatesRegistered then
        local ok = pcall(questie.API.RegisterForQuestUpdates, OnQuestUpdate)
        if ok then
            questUpdatesRegistered = true
        end
    end

    if enabled then
        HideAllFrames()
        SeedVisiblePlates()
    end
end

local function InitializeQuestie()
    if ready then
        return
    end

    -- 不依赖 Questie 的公开接口：模块数据在 Questie 初始化完成后就能直接用
    OnQuestieReady()
    if ready or onReadyRegistered then
        return
    end

    local questie = _G.Questie
    if not (questie and questie.API and questie.API.RegisterOnReady) then
        return
    end
    local ok = pcall(questie.API.RegisterOnReady, OnQuestieReady)
    if ok then
        onReadyRegistered = true
    end
end

local eventFrame = CreateFrame("Frame")
local EVENTS = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED",
}

local function RegisterEvents()
    for _, event in ipairs(EVENTS) do
        pcall(eventFrame.RegisterEvent, eventFrame, event)
    end
end

local function UnregisterEvents()
    for _, event in ipairs(EVENTS) do
        pcall(eventFrame.UnregisterEvent, eventFrame, event)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if not enabled then
        return
    end

    if event == "NAME_PLATE_UNIT_ADDED" then
        OnNamePlateAdded(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNamePlateRemoved(arg1)
    elseif event == "ADDON_LOADED" then
        if arg1 == "Questie" then
            InitializeQuestie()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not ready then
            InitializeQuestie()
        end
        ClearAll()
        C_Timer.After(0, function()
            if enabled and ready then
                SeedVisiblePlates()
            end
        end)
        -- Questie 的任务记录可能比姓名板晚一点准备好，稍后再补一次
        for _, delay in ipairs({ 1, 3 }) do
            C_Timer.After(delay, function()
                if enabled and ready then
                    SeedVisiblePlates()
                    RefreshAll()
                end
            end)
        end
    end
end)

local function Enable()
    enabled = true
    RegisterEvents()
    local wasReady = ready
    InitializeQuestie()
    if wasReady then
        ClearAll()
        SeedVisiblePlates()
    end
end

local function Disable()
    enabled = false
    UnregisterEvents()
    ClearAll()
end

NS.RegisterModule({
    key = "nameplateQuestProgress",
    section = "任务",
    label = "姓名板任务进度",
    tip = "在 Questie 的姓名板任务图标后面显示目标进度："
        .. "击杀目标显示 6/10，掉落目标显示 6/10、物品名称和掉落概率。"
        .. "\n\n需要安装 Questie，并在 Questie 设置里开启姓名板任务目标图标。",
    default = DEFAULT,
    onToggle = function(value)
        if value then
            Enable()
        else
            Disable()
        end
    end,
})
