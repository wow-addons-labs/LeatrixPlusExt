-- LeatrixPlusExt 模块：自动设置任务焦点（击杀任务怪 / 选中任务怪）
-- 击杀由 PARTY_KILL 事件识别（玩家/队伍击杀的 NPC），选中目标由 PLAYER_TARGET_CHANGED
-- 识别；NPC → 任务的目标数据取自 QuestieDB（LibQuestieDB）。命中后优先调用 Questie 的
-- 焦点接口（TrackerUtils:FocusQuest，等同追踪器右键「设为焦点」），并同步原生
-- C_SuperTrack.SetSuperTrackedQuestID；Questie 不在或数据不足时只切原生超级追踪。
-- 不依赖客户端任务追踪器是否显示该任务。
-- 战斗处理：战斗中也直接切换；如果客户端在战斗中拒绝接口调用（或静默忽略），
-- 先记下这次触发，脱战（PLAYER_REGEN_ENABLED）后再重试一次。Questie 设焦点前要刷新
-- 任务日志/地图数据，战斗里可能判定失败，这时先切原生超级追踪，脱战后自动补一次
-- Questie 焦点同步（它的追踪器本来也只在脱战后重排）。
local addonName, NS = ...

local DB = NS.DB
local Utils = NS.Utils

local DEFAULT = false

-- 选项（可多选）；战斗中也直接切换，不设单独开关
local OPTION_DEFAULTS = {
    kill = true,   -- 击杀任务怪后
    target = false, -- 选中任务怪后
}

local state = {
    events = nil,
    dirty = true,
    npcToQuests = nil,
    switches = 0,
    pendingNPC = nil,     -- 客户端在战斗中拒绝切换时暂存的任务怪，脱战后重试
    pendingTrigger = nil, -- kill / target，脱战时再确认对应开关仍然开着
    pendingQuestie = nil, -- 战斗中 Questie 焦点没同步成功时记下任务 ID，脱战后补一次
    questieError = nil,   -- 最近一次 Questie 焦点接口报错，供 /lpext diag questfocus 诊断
    last = nil,           -- 最近一次触发的判定过程，供 /lpext diag questfocus 诊断
}

local function IsEnabled()
    local value = DB.questFocusOnKill
    if value == nil then return DEFAULT end
    return value and true or false
end

local function GetOptions()
    local options = DB.questFocusOptions
    if type(options) ~= "table" then
        options = {}
        DB.questFocusOptions = options
    end
    return options
end

local function GetOption(key)
    local value = GetOptions()[key]
    if value == nil then return OPTION_DEFAULTS[key] end
    return value and true or false
end

local function SetOption(key, value)
    GetOptions()[key] = value and true or false
end

-- 机密值（聊天锁定等）读不了就当作没有；接口本身报错时按可读处理
local function Accessible(value)
    if type(canaccessvalue) ~= "function" then return true end
    local ok, result = pcall(canaccessvalue, value)
    if not ok then return true end
    return result and true or false
end

-- 错误对象转文本：机密值不能直接 tostring，读了会再报错
local function MessageText(value)
    local ok, text = pcall(tostring, value)
    if ok and type(text) == "string" then return text end
    return "未知错误"
end

-- 整张表被标记为机密时（战斗/副本里的任务数据）不要读它的字段
local function ReadableTable(value)
    if type(value) ~= "table" then return false end
    if type(issecrettable) == "function" then
        local ok, secret = pcall(issecrettable, value)
        if ok and secret then return false end
    end
    return true
end

-- 从单位 GUID 取 NPC ID：优先客户端接口，退回 GUID 第 6 段
-- （Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID）
local function CreatureIDFromGUID(guid)
    if not Accessible(guid) then return nil end
    if type(guid) ~= "string" or guid == "" then return nil end
    if C_CreatureInfo and type(C_CreatureInfo.GetCreatureID) == "function" then
        local ok, npcID = pcall(C_CreatureInfo.GetCreatureID, guid)
        if ok and type(npcID) == "number" and npcID > 0 then
            return npcID
        end
    end
    local parts = { strsplit("-", guid) }
    return tonumber(parts[6])
end

-- ---------------------------------------------------------------------------
-- 任务 → 目标 NPC：与 Quest2RareScanner 使用同一套 QuestieDB 结构
-- objectives = { creature, object, item, reputation, killCredits, spell }
--   [1] 击杀目标      [3] 物品（取物品的 npcDrops）      [5] killCredits
-- extraObjectives 里 type == "monster" 的引用也算
-- ---------------------------------------------------------------------------
local function QuestDB()
    local db = _G.LibQuestieDB
    if type(db) ~= "table" then return nil end
    if not (db.Quest and type(db.Quest.Get) == "function") then return nil end
    return db
end

-- 给予任务 / 交任务的 NPC 不算击杀目标（目标数据里偶尔会混进来）
local function ExcludedNPCs(db, questID)
    local set = {}
    for _, field in ipairs({ "startedBy", "finishedBy" }) do
        local ok, data = pcall(db.Quest.Get, questID, field)
        if ok and type(data) == "table" and type(data[1]) == "table" then
            for _, npcID in ipairs(data[1]) do
                npcID = tonumber(npcID)
                if npcID and npcID > 0 then set[npcID] = true end
            end
        end
    end
    return set
end

local function QuestTargetNPCs(db, questID)
    local ids = {}
    local excluded = ExcludedNPCs(db, questID)
    local function add(npcID)
        npcID = tonumber(npcID)
        if npcID and npcID > 0 and not excluded[npcID] then ids[npcID] = true end
    end

    if type(db.Quest.Exists) == "function" then
        local okExists, exists = pcall(db.Quest.Exists, questID)
        if okExists and not exists then return ids end
    end

    local okObjectives, objectives = pcall(db.Quest.Get, questID, "objectives")
    if not okObjectives or type(objectives) ~= "table" then return ids end

    -- 单条数据异常不应该让整张缓存建不出来
    local function list(index)
        local value = objectives[index]
        if type(value) == "table" then return value end
        return {}
    end

    for _, obj in ipairs(list(1)) do
        if type(obj) == "table" then add(obj[1]) end
    end

    for _, obj in ipairs(list(3)) do
        if type(obj) == "table" then
            local itemID = tonumber(obj[1])
            local itemKnown = true
            if itemID and db.Item and type(db.Item.Exists) == "function" then
                local okExists, exists = pcall(db.Item.Exists, itemID)
                itemKnown = not okExists or exists
            end
            if itemID and itemKnown and db.Item and type(db.Item.Get) == "function" then
                local okDrops, drops = pcall(db.Item.Get, itemID, "npcDrops")
                if okDrops and type(drops) == "table" then
                    for _, npcID in ipairs(drops) do add(npcID) end
                end
            end
        end
    end

    for _, obj in ipairs(list(5)) do
        if type(obj) == "table" then
            if type(obj[1]) == "table" then
                for _, npcID in ipairs(obj[1]) do add(npcID) end
            end
            add(obj[2])
        end
    end

    local okExtra, extraObjectives = pcall(db.Quest.Get, questID, "extraObjectives")
    if okExtra and type(extraObjectives) == "table" then
        for _, extra in ipairs(extraObjectives) do
            local references = type(extra) == "table" and extra[5]
            if type(references) == "table" then
                for _, ref in ipairs(references) do
                    if type(ref) == "table" and ref[1] == "monster" then
                        add(ref[2])
                    end
                end
            end
        end
    end

    return ids
end

-- 当前任务日志里已接的任务（是否已完成在设焦点时再判断）
-- 第二个返回值表示有条目读不了（战斗里任务数据可能被标记为机密），调用方稍后再重建
local function QuestLogQuestIDs()
    local ids = {}
    if not (C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
        and type(C_QuestLog.GetInfo) == "function") then
        return ids
    end
    local okNum, num = pcall(C_QuestLog.GetNumQuestLogEntries)
    if not okNum or type(num) ~= "number" then return ids end
    for index = 1, num do
        local okInfo, info = pcall(C_QuestLog.GetInfo, index)
        if okInfo and ReadableTable(info) then
            local isHeader = info.isHeader
            local questID = info.questID
            if Accessible(isHeader) and Accessible(questID)
                and not isHeader and type(questID) == "number" and questID > 0 then
                ids[#ids + 1] = questID
            end
        elseif okInfo then
            return ids, true
        end
    end
    return ids
end

local function QuestTitle(questID)
    if C_QuestLog and type(C_QuestLog.GetTitleForQuestID) == "function" then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and Accessible(title) and type(title) == "string" and title ~= "" then
            return title
        end
    end
    return nil
end

local function QuestIsComplete(questID)
    if C_QuestLog and type(C_QuestLog.IsComplete) == "function" then
        local ok, complete = pcall(C_QuestLog.IsComplete, questID)
        if ok and Accessible(complete) then return complete and true or false end
    end
    return false
end

local function ContainsQuest(quests, questID)
    for _, id in ipairs(quests) do
        if id == questID then return true end
    end
    return false
end

-- 诊断用：把候选任务及完成情况拼成一行
local function QuestSummary(quests)
    local parts = {}
    for _, questID in ipairs(quests) do
        local title = QuestTitle(questID)
        parts[#parts + 1] = tostring(questID)
            .. (title and ("「" .. title .. "」") or "")
            .. (QuestIsComplete(questID) and "（已完成）" or "")
    end
    return table.concat(parts, "、")
end

local function RebuildCache()
    local db = QuestDB()
    local map = {}
    state.npcToQuests = map
    -- 登录过程中任务日志接口可能还不可用：保持 dirty，下次再试
    if not (C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
        and type(C_QuestLog.GetInfo) == "function") then
        state.dirty = true
        return
    end
    state.dirty = false
    if not db then return end
    local ids, unreadable = QuestLogQuestIDs()
    for _, questID in ipairs(ids) do
        local npcs = QuestTargetNPCs(db, questID)
        for npcID in pairs(npcs) do
            local list = map[npcID]
            if not list then
                list = {}
                map[npcID] = list
            end
            list[#list + 1] = questID
        end
    end
    if unreadable then
        -- 战斗里数据读不全：下次触发时再重建，别把残缺缓存放着一直用
        state.dirty = true
    end
end

local function EnsureCache()
    if state.dirty or not state.npcToQuests then RebuildCache() end
    return state.npcToQuests
end

-- ---------------------------------------------------------------------------
-- 超级追踪（任务焦点）：和任务日志右键「设为焦点」是同一个接口
-- ---------------------------------------------------------------------------
local function SuperTrackSupported()
    return C_SuperTrack
        and type(C_SuperTrack.GetSuperTrackedQuestID) == "function"
        and type(C_SuperTrack.SetSuperTrackedQuestID) == "function"
end

local function CurrentFocus()
    if not SuperTrackSupported() then return nil end
    local ok, questID = pcall(C_SuperTrack.GetSuperTrackedQuestID)
    -- 战斗/副本里部分数据会变成机密值，比较之前先确认能读
    if not ok or not Accessible(questID) then return nil end
    if type(questID) == "number" and questID > 0 then
        return questID
    end
    return nil
end

-- Questie 自己记录的焦点（TrackerFocus）。它默认不跟随客户端超级追踪，
-- 所以这个值和 CurrentFocus() 不一致时，Questie 追踪器会一直显示旧的焦点。
local function QuestieTrackerFocus()
    local questie = _G.Questie
    if type(questie) ~= "table" then return nil end
    local ok, questID = pcall(function()
        return questie.db and questie.db.char and questie.db.char.TrackerFocus
    end)
    if ok and type(questID) == "number" and questID > 0 then
        return questID
    end
    return nil
end

local function SetFocus(questID)
    if not SuperTrackSupported() or type(questID) ~= "number" then return false end
    local ok = pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
    return ok
end

-- Questie 有自己的焦点状态（追踪器右键「设为焦点」）：TrackerFocus + 地图图标淡出 + 原生超级追踪。
-- Questie 会隐藏暴雪追踪器，且它的追踪器默认不跟随原生超级追踪，所以只调 C_SuperTrack
-- 时 Questie 界面看起来毫无变化。这里优先走 Questie 的焦点接口，和它的右键菜单效果一致；
-- Questie 不在、数据不足或调用失败时再退回原生超级追踪。
local function QuestieFocus(questID)
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then
        return false
    end

    local okUtils, TrackerUtils = pcall(loader.ImportModule, loader, "TrackerUtils")
    if not okUtils or type(TrackerUtils) ~= "table"
        or type(TrackerUtils.FocusQuest) ~= "function" then
        return false
    end

    local okFocus, focused = pcall(TrackerUtils.FocusQuest, TrackerUtils, questID)
    if not okFocus then
        state.questieError = MessageText(focused)
        return false
    end
    if not focused then
        -- Questie 自己有资格判断（canFocusQuest），战斗中任务日志/地图数据刷新不出来时也会走到这里
        state.questieError = "Questie 判定该任务不能设为焦点（数据未就绪或已不在任务日志）"
        return false
    end
    state.questieError = nil

    -- 和 Questie 自己的焦点按钮一致：让地图上其他任务的图标淡出，并刷新追踪器
    -- （ToggleQuestNotes 是点号函数，不需要传 self）
    local okQuest, QuestieQuest = pcall(loader.ImportModule, loader, "QuestieQuest")
    local okTracker, QuestieTracker = pcall(loader.ImportModule, loader, "QuestieTracker")
    local okQueue, Queue = pcall(loader.ImportModule, loader, "QuestieCombatQueue")
    local hasQueue = okQueue and type(Queue) == "table"
        and type(Queue.Queue) == "function"

    local function FadeMapIcons()
        if okQuest and type(QuestieQuest) == "table"
            and type(QuestieQuest.ToggleQuestNotes) == "function" then
            pcall(QuestieQuest.ToggleQuestNotes, false)
        end
    end

    local function UpdateTracker()
        if okTracker and type(QuestieTracker) == "table"
            and type(QuestieTracker.Update) == "function" then
            pcall(QuestieTracker.Update, QuestieTracker)
        end
    end

    -- 战斗里 Questie 的追踪器本来就不会重排，地图图标淡出也一起留到脱战后做，
    -- 避免战斗中反复淡入淡出，也少碰一次可能受限的任务/地图数据。
    if InCombatLockdown() and hasQueue then
        local okQueued, accepted = pcall(Queue.Queue, Queue, function()
            FadeMapIcons()
            UpdateTracker()
        end)
        if okQueued and accepted then return true end
    end

    FadeMapIcons()
    -- 和 Questie 一样把重排交给它的战斗队列，避免在事件里同步做整套布局
    if hasQueue then
        local okQueued, accepted = pcall(Queue.Queue, Queue, UpdateTracker)
        if okQueued and accepted then return true end
    end
    UpdateTracker()
    return true
end

local function QuestieAvailable()
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then
        return false
    end
    local ok, TrackerUtils = pcall(loader.ImportModule, loader, "TrackerUtils")
    return ok and type(TrackerUtils) == "table"
        and type(TrackerUtils.FocusQuest) == "function"
end

-- 同一只怪对应多个任务时：当前焦点仍是未完成任务就保留，否则取日志里第一个未完成的
local function PickQuest(quests, current)
    if not quests or #quests == 0 then return nil end
    if current then
        for _, questID in ipairs(quests) do
            if questID == current and not QuestIsComplete(questID) then
                return nil
            end
        end
    end
    for _, questID in ipairs(quests) do
        if not QuestIsComplete(questID) then
            return questID
        end
    end
    return nil
end

-- 返回一句结果说明，方便 /lpext diag questfocus 判断卡在哪一步
local function ApplyFocusNow(npcID, trigger)
    if not IsEnabled() then return "模块未开启" end
    if not npcID then return "没有 NPC ID" end
    if not SuperTrackSupported() then return "客户端没有 C_SuperTrack 接口" end
    local map = EnsureCache()
    local quests = map[npcID]
    if not quests then return "任务日志里没有这只怪对应的任务" end

    local current = CurrentFocus()
    local target = PickQuest(quests, current)
    if not target then
        if current and ContainsQuest(quests, current) then
            return "当前焦点已经是候选任务之一，保持不变（正常：焦点本来就在这个任务上）"
        end
        return "候选任务都已完成，不切换"
    end

    local before = current

    -- 优先走 Questie 焦点，让它的追踪器/地图也同步切换（战斗中同样直接切）。
    -- Questie 设焦点前要刷新任务日志/地图数据（canFocusQuest），战斗里可能拿不到，
    -- 这时先切原生焦点，并记下来脱战后补一次 Questie 同步。
    if QuestieFocus(target) then
        state.pendingQuestie = nil
        state.switches = state.switches + 1
        local after = CurrentFocus()
        if after ~= target then
            -- Questie 只改了自己的状态时，补一次原生超级追踪
            SetFocus(target)
            after = CurrentFocus()
        end
        if after ~= target then
            if InCombatLockdown() then
                state.pendingNPC = npcID
                state.pendingTrigger = trigger
                return "Questie 焦点已设为 " .. tostring(target)
                    .. "，但客户端超级追踪仍是 " .. tostring(after or "无") .. "，已暂存，脱战后重试"
            end
            return "Questie 焦点已设为 " .. tostring(target)
                .. "，但客户端超级追踪仍是 " .. tostring(after or "无")
        end
        return "已切换焦点到 " .. tostring(target) .. "（Questie 追踪器已同步）"
            .. (before and ("（原焦点 " .. tostring(before) .. "）") or "")
    elseif InCombatLockdown() and QuestieAvailable() then
        state.pendingQuestie = target
    end

    if not SetFocus(target) then
        if InCombatLockdown() then
            state.pendingNPC = npcID
            state.pendingTrigger = trigger
            return "战斗中接口拒绝切换，已暂存，脱战后重试"
        end
        return "调用 SetSuperTrackedQuestID 失败"
    end

    -- 接口不报错也可能被客户端静默忽略：读回来确认
    local after = CurrentFocus()
    if after ~= target then
        if InCombatLockdown() then
            state.pendingNPC = npcID
            state.pendingTrigger = trigger
            return "战斗中焦点没有变化（仍是 " .. tostring(after or "无") .. "），已暂存，脱战后重试"
        end
        return "接口调用成功，但焦点仍是 " .. tostring(after or "无")
    end
    state.switches = state.switches + 1
    local questieNote = ""
    if QuestieAvailable() then
        questieNote = InCombatLockdown() and "（Questie 追踪器脱战后补同步）"
            or "（Questie 未同步：它的焦点接口不接受这个任务）"
    end
    return "已切换焦点到 " .. tostring(target) .. questieNote
        .. (before and ("（原焦点 " .. tostring(before) .. "）") or "")
end

-- 战斗中客户端/Questie 返回的可能是机密值，任何一步报错都不要打断事件处理
local function SafeApply(npcID, trigger)
    local ok, result = pcall(ApplyFocusNow, npcID, trigger)
    if ok then return result end
    return "内部错误：" .. MessageText(result)
end

local function OnKill(npcID)
    local record = {
        trigger = "kill",
        enabled = IsEnabled(),
        option = GetOption("kill"),
        inCombat = InCombatLockdown() and true or false,
        npcID = npcID,
    }
    -- 没开启/没勾选的事件不覆盖上一次真正处理过的记录，否则诊断会看到一堆
    -- 「未勾选」的脏数据，掩盖刚发生的那次击杀结果
    if not record.enabled then
        record.outcome = "模块未开启"
        state.lastIgnored = record
        return
    end
    if not record.option then
        record.outcome = "「击杀任务怪后设置焦点」未勾选"
        state.lastIgnored = record
        return
    end
    state.last = record
    state.lastIgnored = nil

    if not npcID then record.outcome = "无法从击杀 GUID 解析 NPC ID" return end

    local map = EnsureCache()
    local quests = map[npcID]
    if not quests then
        record.outcome = "任务日志里没有这只怪对应的任务"
    else
        record.mapping = QuestSummary(quests)
        record.outcome = SafeApply(npcID, "kill")
    end
end

-- 选中目标：只看能攻击的活着的 NPC（尸体、玩家、友方 NPC 不处理）
local function OnTargetChanged()
    -- 取消选中时保留上一次目标的判定记录，方便事后查看
    if not UnitExists("target") then return end

    local record = {
        trigger = "target",
        enabled = IsEnabled(),
        option = GetOption("target"),
        inCombat = InCombatLockdown() and true or false,
    }
    if not record.enabled then
        record.outcome = "模块未开启"
        state.lastIgnored = record
        return
    end
    if not record.option then
        record.outcome = "「选中任务怪后设置焦点」未勾选"
        state.lastIgnored = record
        return
    end
    state.last = record
    state.lastIgnored = nil

    local guid = UnitGUID("target")
    record.guid = type(guid) == "string" and guid or nil
    local name = UnitName("target")
    record.name = type(name) == "string" and name or nil
    record.isPlayer = UnitIsPlayer("target") and true or false
    record.isDead = UnitIsDead("target") and true or false
    record.canAttack = UnitCanAttack("player", "target") and true or false

    if record.isPlayer then record.outcome = "目标是玩家" return end
    if record.isDead then record.outcome = "目标是尸体" return end
    if not record.canAttack then record.outcome = "目标不可攻击（友方/中立 NPC）" return end

    local npcID = CreatureIDFromGUID(guid)
    record.npcID = npcID
    if not npcID then record.outcome = "无法从 GUID 解析 NPC ID" return end

    local map = EnsureCache()
    local quests = map[npcID]
    if not quests then
        record.outcome = "任务日志里没有这只怪对应的任务"
    else
        record.mapping = QuestSummary(quests)
        record.outcome = SafeApply(npcID, "target")
    end
end

-- ---------------------------------------------------------------------------
-- 事件
-- ---------------------------------------------------------------------------
local function MarkDirty()
    state.dirty = true
end

-- 脱战：应用战斗中暂存的切换
local function OnCombatEnd()
    local npcID = state.pendingNPC
    local trigger = state.pendingTrigger
    local questieQuest = state.pendingQuestie
    state.pendingNPC = nil
    state.pendingTrigger = nil
    state.pendingQuestie = nil

    if npcID then
        -- 战斗期间对应触发方式被关掉的话，不再应用
        if trigger and not GetOption(trigger) then return end
        SafeApply(npcID, trigger)
        return
    end

    -- 原生焦点当时已经切好了，只是 Questie 的焦点状态没同步：脱战后补一次。
    -- 战斗期间玩家手动改过焦点的话尊重手动选择，不再补同步。
    if questieQuest and IsEnabled() and QuestieAvailable() then
        local current = CurrentFocus()
        if current == nil or current == questieQuest then
            QuestieFocus(questieQuest)
        end
    end
end

local function EnsureEvents()
    if state.events then return state.events end
    local frame = CreateFrame("Frame")
    state.events = frame
    frame:RegisterEvent("PARTY_KILL")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("QUEST_ACCEPTED")
    frame:RegisterEvent("QUEST_REMOVED")
    frame:RegisterEvent("QUEST_TURNED_IN")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PARTY_KILL" then
            local _, targetGUID = ...
            OnKill(CreatureIDFromGUID(targetGUID))
        elseif event == "PLAYER_TARGET_CHANGED" then
            OnTargetChanged()
        elseif event == "PLAYER_REGEN_ENABLED" then
            OnCombatEnd()
        elseif event == "ADDON_LOADED" then
            local name = ...
            -- QuestieDB 可能比我们晚加载，加载好后再建缓存
            if name == "QuestieDB" or name == "Questie" then
                MarkDirty()
            end
        else
            MarkDirty()
        end
    end)
    return frame
end

-- ---------------------------------------------------------------------------
-- 二级设置页：触发方式
-- ---------------------------------------------------------------------------
local panelCheckboxes = {}

local function UpdatePanelCheckboxes()
    for key, checkbox in pairs(panelCheckboxes) do
        checkbox:SetChecked(GetOption(key))
    end
end

local function BuildQuestFocusPanel(parent, configPanel)
    local AssignTooltip = Utils.AssignTooltip

    local function AddTrigger(key, y, labelText, tip)
        local checkbox = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", 0, y)

        local label = checkbox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", 20, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetText(labelText)
        checkbox.f = label

        -- 和主面板的选项行一致：点文字也能切换，不用非点中小方块
        if label:GetStringWidth() > 152 then
            checkbox:SetHitRectInsets(0, -142, 0, 0)
        else
            checkbox:SetHitRectInsets(0, -label:GetStringWidth() + 4, 0, 0)
        end

        checkbox:SetChecked(GetOption(key))
        AssignTooltip(checkbox, tip, configPanel)
        checkbox:SetScript("OnClick", function(self)
            SetOption(key, self:GetChecked() and true or false)
        end)

        panelCheckboxes[key] = checkbox
        return checkbox
    end

    AddTrigger("kill", 0, "击杀任务怪后设置焦点",
        "击杀任务怪（含任务物品的掉落怪）后，把这个任务设为焦点。")
    AddTrigger("target", -24, "选中任务怪后设置焦点",
        "选中可攻击的任务怪时，提前把这个任务设为焦点，适合跑图找怪的阶段。")
end

-- 诊断用：当场展开当前目标（只读判断，不切换焦点）
local function DescribeCurrentTarget()
    local lines = {}
    if not UnitExists("target") then
        lines[1] = "当前目标=无（选中任务怪后再查看）"
        return lines
    end

    local guid = UnitGUID("target")
    local name = UnitName("target")
    local npcID = CreatureIDFromGUID(guid)
    lines[#lines + 1] = "当前目标=" .. tostring(name or "?")
        .. (npcID and ("  NPC ID=" .. tostring(npcID)) or "（无法解析 NPC ID）")
    lines[#lines + 1] = "  玩家=" .. (UnitIsPlayer("target") and "是" or "否")
        .. " 尸体=" .. (UnitIsDead("target") and "是" or "否")
        .. " 可攻击=" .. (UnitCanAttack("player", "target") and "是" or "否")

    if npcID then
        local map = EnsureCache()
        local quests = map[npcID]
        if quests then
            lines[#lines + 1] = "  对应任务=" .. QuestSummary(quests)
        else
            lines[#lines + 1] = "  对应任务=没有（任务日志里没有这只怪的目标）"
        end
    end
    return lines
end

function NS.DiagnoseQuestFocus()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add("自动设置任务焦点=" .. (IsEnabled() and "开" or "关"))
    add("触发方式：击杀后=" .. (GetOption("kill") and "开" or "关")
        .. " 选中目标后=" .. (GetOption("target") and "开" or "关"))
    add("战斗中切换=直接切换（客户端拒绝时脱战重试）"
        .. " 当前在战斗中=" .. (InCombatLockdown() and "是" or "否"))
    add("待脱战重试的任务怪="
        .. (state.pendingNPC and ("NPC " .. tostring(state.pendingNPC)
            .. "（" .. tostring(state.pendingTrigger or "?") .. "）") or "无"))
    add("待脱战补同步的 Questie 焦点="
        .. (state.pendingQuestie and tostring(state.pendingQuestie) or "无"))
    add("超级追踪接口 C_SuperTrack=" .. (SuperTrackSupported() and "可用" or "不可用"))

    local current = CurrentFocus()
    if current then
        local title = QuestTitle(current)
        add("当前焦点=" .. current .. (title and ("（" .. title .. "）") or ""))
    else
        add("当前焦点=无")
    end
    if QuestieAvailable() then
        local questieFocus = QuestieTrackerFocus()
        add("Questie 自己的焦点=" .. (questieFocus and tostring(questieFocus) or "无"))
        if questieFocus and current and questieFocus ~= current then
            add("  注意：两者不一致。Questie 追踪器默认不跟随客户端超级追踪，"
                .. "界面上看到的是 Questie 自己的焦点")
        end
    end

    for _, line in ipairs(DescribeCurrentTarget()) do add(line) end

    add("QuestieDB=" .. (QuestDB() and "已加载" or "未加载（没有它无法判断任务怪）"))
    add("Questie 焦点接口=" .. (QuestieAvailable()
        and "可用（切换时会同步 Questie 追踪器/地图焦点）"
        or "不可用（只切原生超级追踪）"))
    if state.questieError then
        add("Questie 焦点接口最近报错=" .. tostring(state.questieError))
    end

    local last = state.last
    if last then
        add("")
        add("上次触发=" .. (last.trigger == "kill" and "击杀任务怪" or "选中任务怪")
            .. "（模块=" .. (last.enabled and "开" or "关")
            .. " 该触发选项=" .. (last.option and "开" or "关")
            .. " 当时在战斗中=" .. (last.inCombat and "是" or "否") .. "）")
        if last.trigger == "target" then
            add("  目标=" .. tostring(last.name or "?")
                .. (last.guid and ("  GUID " .. tostring(last.guid)) or ""))
            add("  判定：玩家=" .. (last.isPlayer and "是" or "否")
                .. " 尸体=" .. (last.isDead and "是" or "否")
                .. " 可攻击=" .. (last.canAttack and "是" or "否")
                .. " 解析 NPC ID=" .. tostring(last.npcID or "无"))
        else
            add("  NPC ID=" .. tostring(last.npcID or "无"))
        end
        if last.mapping then add("  这只怪对应的任务=" .. tostring(last.mapping)) end
        add("  结果=" .. tostring(last.outcome or "无"))
    else
        add("上次触发=还没有触发过（开启后击杀或选中任务怪试试）")
    end
    if state.lastIgnored then
        local ignored = state.lastIgnored
        add("之后还有一次被忽略的触发=" .. (ignored.trigger == "kill" and "击杀" or "选中目标")
            .. "（" .. tostring(ignored.outcome or "无") .. "；不影响上面的结果）")
    end

    add("本次登录已切换焦点=" .. tostring(state.switches) .. " 次")

    local map = EnsureCache()
    local questCount = #QuestLogQuestIDs()
    local npcCount = 0
    for _ in pairs(map) do npcCount = npcCount + 1 end
    add("任务日志任务=" .. tostring(questCount)
        .. " 可识别的任务怪 NPC=" .. tostring(npcCount))

    local db = QuestDB()
    if not db then
        add("提示：安装 Questie + QuestieDB 后才能把击杀怪对应到任务。")
    elseif npcCount == 0 and questCount > 0 then
        add("提示：日志里的任务在 QuestieDB 中没有击杀/掉落目标（可能是对话、物品使用或采集任务）。")
    end
    return lines
end

NS.RegisterModule({
    key = "questFocusOnKill",
    section = "任务",
    label = "自动设置任务焦点",
    tip = "把已接任务的焦点自动切到当前正在打的任务，效果同任务日志右键「设为焦点」；"
        .. "装了 Questie 时会同步它的追踪焦点。\n"
        .. "点右侧齿轮选择触发方式（击杀/选中任务怪，可多选）；需要安装 Questie。",
    default = DEFAULT,
    panelTitle = "自动设置任务焦点",
    panelDesc = "",
    buildPanel = BuildQuestFocusPanel,
    reset = function()
        SetOption("kill", OPTION_DEFAULTS.kill)
        SetOption("target", OPTION_DEFAULTS.target)
        UpdatePanelCheckboxes()
    end,
    onToggle = function(enabled)
        EnsureEvents()
        if enabled then
            state.dirty = true
        else
            state.pendingNPC = nil
            state.pendingTrigger = nil
            state.pendingQuestie = nil
        end
    end,
})

EnsureEvents()
