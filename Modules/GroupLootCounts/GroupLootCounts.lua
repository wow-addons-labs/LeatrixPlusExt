-- LeatrixPlusExt 模块：在队伍拾取的按钮上显示已经选择该项的人数
-- 人数统计与拾取历史配对参考 BetterGroupLoot-1.0（作者 Karl-Heinz Schneider，MIT 许可），
-- 只保留按钮上的数字，不替换原生 roll 框。
local _, NS = ...

local DEFAULT = true

-- 只处理 Forever / Camelot 客户端的拾取历史（C_LootHistory 按副本掉落记录）。
-- 按钮上的数字只统计选了该项的玩家；需求包括主天赋和副天赋。
local BUTTONS = {
    { field = "NeedButton", choice = "need" },
    { field = "GreedButton", choice = "greed" },
    { field = "TransmogButton", choice = "transmog" },
    { field = "PassButton", choice = "pass" },
}

local ROLL_STATE = Enum and Enum.EncounterLootDropRollState or {
    NeedMainSpec = 0,
    NeedOffSpec = 1,
    Transmog = 2,
    Greed = 3,
    NoRoll = 4,
    Pass = 5,
}

local EVENTS = {
    "START_LOOT_ROLL",
    "CANCEL_LOOT_ROLL",
    "CANCEL_ALL_LOOT_ROLLS",
    "LOOT_HISTORY_UPDATE_DROP",
    "LOOT_HISTORY_UPDATE_ENCOUNTER",
    "LOOT_HISTORY_CLEAR_HISTORY",
    "PLAYER_ENTERING_WORLD",
}

local enabled = false
local eventFrame = CreateFrame("Frame")
-- [rollID] = { encounterID, lootListKey }：roll 和拾取历史里的掉落配对
local dropByRoll = {}

-- 部分返回值会被标记成秘密值，不能比较
local function Plain(value)
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if not ok or not allowed then
            return nil
        end
    end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then
            return nil
        end
    end
    return value
end

local function GetLootFrames()
    local frames = {}
    for index = 1, NUM_GROUP_LOOT_FRAMES or 4 do
        local frame = _G["GroupLootFrame" .. index]
        if frame then
            frames[#frames + 1] = frame
        end
    end
    return frames
end

-- 拾取历史 ----------------------------------------------------------------------------------------

local function ItemID(link)
    link = Plain(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("item:(%d+)")
    return id and tonumber(id)
end

-- 找出这个 roll 对应的拾取历史掉落。优先物品链接完全一致、仍在进行的掉落；
-- 链接带额外字段时按物品 ID 匹配。已经被其他 roll 占用的掉落跳过，用来区分同名物品。
local function FindDrop(rollID)
    local ok, link = pcall(GetLootRollItemLink, rollID)
    if not ok then
        return nil
    end
    link = Plain(link)
    local id = ItemID(link)
    if not id then
        return nil
    end

    local claimed = {}
    for otherRollID, ref in pairs(dropByRoll) do
        if otherRollID ~= rollID then
            claimed[ref.encounterID .. ":" .. ref.lootListKey] = true
        end
    end

    local history = C_LootHistory
    if type(history) ~= "table" or type(history.GetAllEncounterInfos) ~= "function" then
        return nil
    end

    local okEncounters, encounters = pcall(history.GetAllEncounterInfos)
    if not okEncounters or type(encounters) ~= "table" then
        return nil
    end

    local best, bestScore = nil, 0
    for _, encounter in ipairs(encounters) do
        local encounterID = Plain(encounter.encounterID)
        if encounterID then
            local okDrops, drops = pcall(history.GetSortedDropsForEncounter, encounterID)
            if okDrops and type(drops) == "table" then
                for _, drop in ipairs(drops) do
                    local key = Plain(drop.lootListKey or drop.lootListID)
                    if key and not claimed[encounterID .. ":" .. key] then
                        local score = 0
                        local dropLink = Plain(drop.itemHyperlink)
                        if dropLink == link then
                            score = 2
                        elseif id and ItemID(dropLink) == id then
                            score = 1
                        end
                        if score > 0 and not Plain(drop.winner) and not Plain(drop.allPassed) then
                            score = score + 2
                        end
                        if score > bestScore then
                            best = { encounterID = encounterID, lootListKey = key }
                            bestScore = score
                            if score == 4 then
                                return best
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local function ChoiceOf(state)
    state = Plain(state)
    if state == ROLL_STATE.NeedMainSpec or state == ROLL_STATE.NeedOffSpec then
        return "need"
    elseif state == ROLL_STATE.Greed then
        return "greed"
    elseif state == ROLL_STATE.Transmog then
        return "transmog"
    elseif state == ROLL_STATE.Pass then
        return "pass"
    end
end

-- 返回 { need = 人数, greed = 人数, transmog = 人数, pass = 人数 }；
-- 拾取历史还没有这个掉落时返回 nil，按钮上不显示数字。
local function GetCounts(rollID)
    local history = C_LootHistory
    if type(history) ~= "table" or type(history.GetSortedInfoForDrop) ~= "function" then
        return nil
    end

    local ref = dropByRoll[rollID]
    local drop
    if ref then
        local ok, value = pcall(history.GetSortedInfoForDrop, ref.encounterID, ref.lootListKey)
        if ok then
            drop = value
        end
    end
    if type(drop) ~= "table" then
        ref = FindDrop(rollID)
        dropByRoll[rollID] = ref
        if ref then
            local ok, value = pcall(history.GetSortedInfoForDrop, ref.encounterID, ref.lootListKey)
            if ok then
                drop = value
            end
        end
    end
    if type(drop) ~= "table" then
        return nil
    end

    local counts = { need = 0, greed = 0, transmog = 0, pass = 0 }
    local infos = drop.rollInfos
    if type(infos) ~= "table" then
        return nil
    end
    for _, info in ipairs(infos) do
        local choice = ChoiceOf(info.state)
        if choice then
            counts[choice] = counts[choice] + 1
        end
    end
    return counts
end

-- 按钮数字 ----------------------------------------------------------------------------------------

local function AttachCount(button)
    if button.leatrixPlusExtCount then
        return button.leatrixPlusExtCount
    end
    local text = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    text:SetJustifyH("RIGHT")
    text:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -2)
    text:Hide()
    button.leatrixPlusExtCount = text
    return text
end

local function UpdateFrame(frame)
    local rollID = Plain(frame.rollID)
    local counts = rollID and GetCounts(rollID)
    local container = frame.LootButtonContainer or frame

    for _, info in ipairs(BUTTONS) do
        local button = container[info.field] or frame[info.field]
        if button then
            local text = AttachCount(button)
            if counts then
                text:SetText(tostring(counts[info.choice] or 0))
                text:Show()
            else
                text:SetText("")
                text:Hide()
            end
        end
    end
end

local function HideCounts()
    for _, frame in ipairs(GetLootFrames()) do
        local container = frame.LootButtonContainer or frame
        for _, info in ipairs(BUTTONS) do
            local button = container[info.field] or frame[info.field]
            local text = button and button.leatrixPlusExtCount
            if text then
                text:SetText("")
                text:Hide()
            end
        end
    end
end

local function RefreshAll()
    if not enabled then
        return
    end

    -- 保留仍在显示的 roll 已有的配对，避免同名物品的 roll 结束后人数互换；
    -- 只清掉已经关闭的 roll，释放它占用的掉落。
    local frames = GetLootFrames()
    local active = {}
    for _, frame in ipairs(frames) do
        if frame:IsShown() then
            local rollID = Plain(frame.rollID)
            if rollID then
                active[rollID] = true
            end
        end
    end
    for rollID in pairs(dropByRoll) do
        if not active[rollID] then
            dropByRoll[rollID] = nil
        end
    end

    for _, frame in ipairs(frames) do
        if frame:IsShown() then
            pcall(UpdateFrame, frame)
        end
    end
end

local function OnRollFrameShown()
    RefreshAll()
end

-- 原生 roll 框可能在登录界面之后才创建，所以每次启动/收到 roll 事件都补一次钩子
local function InstallHooks()
    for _, frame in ipairs(GetLootFrames()) do
        if not frame.leatrixPlusExtCountHooked then
            frame.leatrixPlusExtCountHooked = true
            frame:HookScript("OnShow", OnRollFrameShown)
        end
    end
end

local function RegisterEvents()
    for _, event in ipairs(EVENTS) do
        pcall(eventFrame.RegisterEvent, eventFrame, event)
    end
end

local function Start()
    enabled = true
    InstallHooks()
    RegisterEvents()
    RefreshAll()
end

local function Stop()
    enabled = false
    eventFrame:UnregisterAllEvents()
    dropByRoll = {}
    HideCounts()
end

eventFrame:SetScript("OnEvent", function(_, event, rollID)
    if not enabled then
        return
    end

    if event == "START_LOOT_ROLL" then
        -- rollID 可能被重复使用
        dropByRoll[rollID] = nil
        InstallHooks()
        C_Timer.After(0, RefreshAll)
    elseif event == "CANCEL_LOOT_ROLL" then
        dropByRoll[rollID] = nil
    elseif event == "CANCEL_ALL_LOOT_ROLLS" then
        dropByRoll = {}
    elseif event == "LOOT_HISTORY_CLEAR_HISTORY" then
        dropByRoll = {}
        RefreshAll()
    else
        -- 拾取历史更新：谁选了什么都可能变
        RefreshAll()
    end
end)

NS.RegisterModule({
    key = "groupLootCounts",
    section = "拾取与物品",
    label = "队伍拾取显示人数",
    tip = "在队伍拾取的每个选择按钮上显示已经选择该项的人数。"
        .. "\n\n需求会把主天赋和副天赋一起计算。",
    default = DEFAULT,
    onToggle = function(value)
        if value then
            Start()
        else
            Stop()
        end
    end,
})
