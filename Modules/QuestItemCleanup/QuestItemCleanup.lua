-- LeatrixPlusExt 模块：在背包里标记已经不再需要的任务物品
-- 只标记「所有可能用到它的本阵营任务都已交完」的物品，任何一步不确定都不标记。
local addonName, NS = ...

local DB = NS.DB

local DEFAULT = true

local QUEST_ITEM_CLASS = 12
local BIND_QUEST = 4

local INDEX_BATCH = 250      -- 每帧处理的任务数
local INDEX_DELAY = 5        -- 登录后等 Questie 完成自己的工作再建索引
local MAX_CONTAINER_FRAME_SCAN = 100

local enabled = false
local loggedIn = false
local indexStarted = false
local indexReady = false
local indexQueued = false

local band = bit and bit.band

-- 从任务库反查出来的物品 → 任务关系
local itemQuests = {}     -- [itemID] = { [questID] = true }
local itemStarters = {}   -- [itemID] = questID

local verdict = {}        -- [itemID] = true/false，任务状态变化时整体清空
local activeTexts         -- 当前任务日志里的目标文字
local lastSignature

local tracked = setmetatable({}, { __mode = "k" })
local lastHover     -- 最近一次鼠标提示成功标记的格子，供诊断查看

local RefreshAll

-- ---------------------------------------------------------------------------
-- 安全访问：这个客户端会返回机密数值，不能比较、不能运算
-- ---------------------------------------------------------------------------
local function Legible(value)
    if value == nil then return nil end
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

local function Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return Legible(a), Legible(b), Legible(c)
end

local function HasBit(value, flag)
    if type(value) ~= "number" then return false end
    if band then return band(value, flag) ~= 0 end
    return math.floor(value / flag) % 2 == 1
end

local function GetDB()
    local db = _G.LibQuestieDB
    if db and db.Item and db.Quest and db.Item.Get and db.Quest.Get then
        return db
    end
end

-- ---------------------------------------------------------------------------
-- 物品信息
-- ---------------------------------------------------------------------------
local function ItemDetails(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(getInfo) ~= "function" then return nil end
    local ok, name, link, quality, itemLevel, reqLevel, class, subclass,
        maxStack, equipLoc, texture, sellPrice, classID, subclassID, bindType =
        pcall(getInfo, itemID)
    if not ok then return nil end
    return Legible(name), Legible(classID), Legible(bindType)
end

local function ItemName(itemID, db)
    -- 客户端名称和任务目标文字使用同一语言，优先用它
    local infoName = ItemDetails(itemID)
    if type(infoName) == "string" and infoName ~= "" then return infoName end
    local name = Safe(db.Item.Get, itemID, "name")
    if type(name) == "string" and name ~= "" then return name end
end

local function ContainerItemID(bag, slot)
    if type(bag) ~= "number" or type(slot) ~= "number" or bag < 0 or slot <= 0 then
        return nil
    end
    if C_Container and C_Container.GetContainerItemInfo then
        local info = Safe(C_Container.GetContainerItemInfo, bag, slot)
        if type(info) == "table" then return Legible(info.itemID) end
        return nil
    end
    if type(GetContainerItemInfo) == "function" then
        local ok, _, _, _, _, _, _, link, _, _, itemID =
            pcall(GetContainerItemInfo, bag, slot)
        if not ok then return nil end
        itemID = Legible(itemID)
        if type(itemID) == "number" then return itemID end
        link = Legible(link)
        if type(link) == "string" then
            return tonumber(link:match("item:(%d+)"))
        end
    end
end

-- 返回 isQuestItem, 开启的任务 ID, 是否正在进行
local function GetBagQuestInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemQuestInfo then
        local info = Safe(C_Container.GetContainerItemQuestInfo, bag, slot)
        if type(info) == "table" then
            return Legible(info.isQuestItem), Legible(info.questID), Legible(info.isActive)
        end
        return nil
    end
    if type(GetContainerItemQuestInfo) == "function" then
        return Safe(GetContainerItemQuestInfo, bag, slot)
    end
end

-- ---------------------------------------------------------------------------
-- 任务日志
-- ---------------------------------------------------------------------------
local function Clean(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return text:lower()
end

-- 一次扫描同时得到任务日志指纹和所有目标文字
local function ReadQuestLog()
    local parts, texts = {}, {}
    local questLog = C_QuestLog
    if type(questLog) ~= "table" then return "", texts end
    local count = Safe(questLog.GetNumQuestLogEntries) or 0
    for i = 1, count do
        local info = Safe(questLog.GetInfo, i)
        if type(info) == "table" then
            local questID = Legible(info.questID)
            local isHeader = Legible(info.isHeader)
            if not isHeader and type(questID) == "number" and questID > 0 then
                parts[#parts + 1] = questID
                local objectives = Safe(questLog.GetQuestObjectives, questID)
                if type(objectives) == "table" then
                    for _, objective in ipairs(objectives) do
                        local text = type(objective) == "table" and Legible(objective.text)
                        if type(text) == "string" then
                            parts[#parts + 1] = text
                            texts[#texts + 1] = Clean(text)
                        end
                    end
                end
            end
        end
    end
    return table.concat(parts, "|"), texts
end

-- ---------------------------------------------------------------------------
-- 判定：物品是否已经明确不再需要
-- ---------------------------------------------------------------------------
local factionMask
local factionMaskChecked = false

local classBit
local classBitChecked = false

-- 职业是永久限制：职业不符的任务永远接不到，不算「以后还会用」
local function GetClassBit()
    if classBitChecked then return classBit end
    classBitChecked = true
    local _, _, classID = Safe(UnitClass, "player")
    if type(classID) == "number" and classID >= 1 then
        classBit = 2 ^ (classID - 1)
    end
    return classBit
end

local function GetFactionMask(db)
    if factionMaskChecked then return factionMask end
    factionMaskChecked = true
    local masks = db and db.Enum and db.Enum.factionRaceMasks
    if type(masks) ~= "table" then return nil end
    local faction = Safe(UnitFactionGroup, "player")
    if faction == "Alliance" or faction == "Horde" then
        local mask = masks[faction]
        if type(mask) == "number" then factionMask = mask end
    end
    return factionMask
end

-- 本阵营接不到的任务不算「还要用到它」；已经在日志里的任务优先保留
local function QuestRelevant(questID, db, mask)
    if Safe(C_QuestLog and C_QuestLog.IsOnQuest, questID) == true then return true end
    if mask and type(mask) == "number" then
        local races = Safe(db.Quest.Get, questID, "requiredRaces")
        if type(races) == "number" and races > 0 and not HasBit(races, mask) then
            return false
        end
    end
    local bit = GetClassBit()
    if bit then
        local classes = Safe(db.Quest.Get, questID, "requiredClasses")
        if type(classes) == "number" and classes > 0 and not HasBit(classes, bit) then
            return false
        end
    end
    return true
end

-- 任务是否还需要这个物品
local function QuestStillNeeded(questID, db)
    local special = Safe(db.Quest.Get, questID, "specialFlags")
    if HasBit(special, 1) then return true end   -- 可重复任务

    local flags = Safe(db.Quest.Get, questID, "questFlags")
    if HasBit(flags, 4096) or HasBit(flags, 32768) or HasBit(flags, 65536) then
        return true                               -- 日常 / 周常 / 月常
    end

    if Safe(C_QuestLog and C_QuestLog.IsOnQuest, questID) == true then return true end
    if Safe(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, questID) == true then
        return false
    end
    return true                                   -- 没完成、也不在日志里：以后可能还会接
end

local function AddRelated(set, questID)
    if type(questID) == "number" and questID > 0 then
        set[questID] = true
    end
end

-- 收集所有可能用到这个物品的任务
local function CollectRelated(itemID, db, set)
    local list = Safe(db.Item.Get, itemID, "relatedQuests")
    if type(list) == "table" then
        for _, questID in ipairs(list) do AddRelated(set, questID) end
    end
    AddRelated(set, Safe(db.Item.Get, itemID, "startQuest"))
    AddRelated(set, itemStarters[itemID])
    local indexed = itemQuests[itemID]
    if indexed then
        for questID in pairs(indexed) do AddRelated(set, questID) end
    end
end

local function ItemIsNoLongerNeeded(itemID, db, mask)
    local related = {}
    CollectRelated(itemID, db, related)

    local hasRelevant = false
    for questID in pairs(related) do
        if QuestRelevant(questID, db, mask) then
            hasRelevant = true
            if QuestStillNeeded(questID, db) then
                return false
            end
        end
    end
    return hasRelevant
end

-- 进行中的任务目标里出现物品名时，宁可不标
local function NeededByActiveText(itemID, db)
    local name = ItemName(itemID, db)
    if type(name) ~= "string" or name == "" then return true end
    local needle = Clean(name)
    if needle == "" then return true end
    if type(activeTexts) ~= "table" then return true end
    for _, text in ipairs(activeTexts) do
        if text:find(needle, 1, true) then return true end
    end
    return false
end

local function IsQuestRelatedItem(itemID, db)
    local _, classID, bindType = ItemDetails(itemID)
    if bindType == BIND_QUEST then return true end
    if classID == QUEST_ITEM_CLASS then return true end

    -- 物品信息还没准备好时，退回任务库里的物品分类
    if classID == nil then
        local dbClass = Safe(db.Item.Get, itemID, "class")
        if dbClass == QUEST_ITEM_CLASS then return true end
    end

    local startQuest = Safe(db.Item.Get, itemID, "startQuest")
    if type(startQuest) == "number" and startQuest > 0 then
        return true
    end
    return itemStarters[itemID] ~= nil
end

local function VerdictForItem(itemID, db)
    if not IsQuestRelatedItem(itemID, db) then return false end
    if not ItemIsNoLongerNeeded(itemID, db, GetFactionMask(db)) then return false end
    if NeededByActiveText(itemID, db) then return false end
    return true
end

local function GetVerdict(itemID)
    if type(itemID) ~= "number" then return false end
    local db = GetDB()
    if not db or not indexReady then return false end
    local cached = verdict[itemID]
    if cached ~= nil then return cached end
    local result = VerdictForItem(itemID, db)
    verdict[itemID] = result
    return result
end

local function ShouldMark(bag, slot)
    if not enabled or not indexReady then return false end
    local itemID = ContainerItemID(bag, slot)
    if not itemID then return false end
    if not GetVerdict(itemID) then return false end
    local _, _, isActive = GetBagQuestInfo(bag, slot)
    if isActive then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- 反查索引：登录后分批构建，建好之前不标记
-- ---------------------------------------------------------------------------
local function AddQuestItem(itemID, questID)
    if type(itemID) ~= "number" or itemID <= 0 then return end
    if type(questID) ~= "number" or questID <= 0 then return end
    local set = itemQuests[itemID]
    if not set then
        set = {}
        itemQuests[itemID] = set
    end
    set[questID] = true
end

local function BuildIndex()
    if indexStarted or indexReady then return end
    local db = GetDB()
    if not db then return end
    local ids = Safe(db.Quest.GetAllIds)
    if type(ids) ~= "table" or #ids == 0 then return end

    indexStarted = true
    local pos = 1
    local ticker
    local okCreate, created = pcall(C_Timer.NewTicker, 0.01, function()
        local last = math.min(pos + INDEX_BATCH - 1, #ids)
        for i = pos, last do
            local questID = ids[i]
            if type(questID) == "number" then
                local objectives = Safe(db.Quest.Get, questID, "objectives")
                local itemObjectives = type(objectives) == "table" and objectives[3]
                if type(itemObjectives) == "table" then
                    for _, entry in ipairs(itemObjectives) do
                        local itemID = type(entry) == "table" and entry[1] or entry
                        AddQuestItem(itemID, questID)
                    end
                end

                local startedBy = Safe(db.Quest.Get, questID, "startedBy")
                local starterItems = type(startedBy) == "table" and startedBy[3]
                if type(starterItems) == "table" then
                    for _, itemID in ipairs(starterItems) do
                        if type(itemID) == "number" and itemID > 0 then
                            itemStarters[itemID] = questID
                            AddQuestItem(itemID, questID)
                        end
                    end
                end

                AddQuestItem(Safe(db.Quest.Get, questID, "sourceItemId"), questID)

                local required = Safe(db.Quest.Get, questID, "requiredSourceItems")
                if type(required) == "table" then
                    for _, itemID in ipairs(required) do
                        AddQuestItem(itemID, questID)
                    end
                end
            end
        end
        pos = last + 1
        if pos > #ids then
            pcall(ticker.Cancel, ticker)
            indexReady = true
            verdict = {}
            if enabled then RefreshAll() end
        end
    end)
    if not okCreate or not created then
        indexStarted = false
        return
    end
    ticker = created
end

local function QueueIndex(delay)
    if indexReady or indexStarted or indexQueued then return end
    indexQueued = true
    C_Timer.After(delay or 0, function()
        indexQueued = false
        if enabled then BuildIndex() end
    end)
end

-- ---------------------------------------------------------------------------
-- 背包标记
-- ---------------------------------------------------------------------------
local function GetOverlay(button)
    local overlay = button.lpextQuestItemOverlay
    if overlay then return overlay end

    overlay = CreateFrame("Frame", nil, button)
    overlay:SetAllPoints(button)
    overlay:EnableMouse(false)

    local function Line(topPoint, bottomPoint, isHorizontal)
        local texture = overlay:CreateTexture(nil, "OVERLAY")
        texture:SetColorTexture(1, 0.12, 0.12, 0.95)
        texture:SetPoint(topPoint, overlay, topPoint, 0, 0)
        texture:SetPoint(bottomPoint, overlay, bottomPoint, 0, 0)
        if isHorizontal then
            texture:SetHeight(2)
        else
            texture:SetWidth(2)
        end
        return texture
    end

    Line("TOPLEFT", "TOPRIGHT", true)
    Line("BOTTOMLEFT", "BOTTOMRIGHT", true)
    Line("TOPLEFT", "BOTTOMLEFT", false)
    Line("TOPRIGHT", "BOTTOMRIGHT", false)

    local cross = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
    cross:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    cross:SetSize(16, 16)
    cross:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 3, 3)

    overlay:Hide()
    button.lpextQuestItemOverlay = overlay
    return overlay
end

local function HideOverlay(button)
    if button and button.lpextQuestItemOverlay then
        button.lpextQuestItemOverlay:Hide()
    end
end

-- 有些背包界面会在创建格子之后再抬高格子层级，覆盖层要跟着抬，否则会被图标盖住
local function RaiseOverlay(overlay, button)
    local ok, level = pcall(button.GetFrameLevel, button)
    if ok and type(level) == "number" then
        local okLevel, newLevel = pcall(function() return level + 8 end)
        if okLevel and type(newLevel) == "number" then
            pcall(overlay.SetFrameLevel, overlay, newLevel)
        end
    end
    if button.GetFrameStrata then
        local okStrata, strata = pcall(button.GetFrameStrata, button)
        if okStrata and type(strata) == "string" then
            pcall(overlay.SetFrameStrata, overlay, strata)
        end
    end
end

-- 扫描统计，供 /lpext diag questitemcleanup 查看
local scan = {
    refreshes = 0, frames = 0, visited = 0, marked = 0, hidden = 0,
    noBag = 0, noSlot = 0, watchTicks = 0, watchRefreshes = 0, lastError = "",
}

-- 整合背包挂钩状态单独记，不会被每次刷新的统计清零
local hookStats = {
    installed = {}, errors = {}, calls = 0, marked = 0,
    lastBag = nil, lastSlot = nil, lastError = "",
}

local function MarkButton(button, bag, slot)
    if type(button) ~= "table" then return end
    if type(bag) ~= "number" or type(slot) ~= "number" or slot <= 0 then
        HideOverlay(button)
        return
    end
    tracked[button] = { bag, slot }
    if enabled and ShouldMark(bag, slot) then
        scan.marked = scan.marked + 1
        local overlay = GetOverlay(button)
        RaiseOverlay(overlay, button)
        overlay:Show()
    else
        HideOverlay(button)
    end
end

-- 收集一个背包窗口里的物品按钮，兼容新旧两种背包界面
local function CollectButtons(frame)
    local list, seen = {}, {}
    local function Add(button)
        if type(button) == "table" and not seen[button] then
            seen[button] = true
            list[#list + 1] = button
        end
    end

    if type(frame.Items) == "table" then
        for _, button in pairs(frame.Items) do Add(button) end
    end

    if type(frame.GetName) == "function" then
        local name = Safe(frame.GetName, frame)
        if type(name) == "string" then
            for i = 1, 100 do
                Add(_G[name .. "Item" .. i])
            end
        end
    end

    if type(frame.EnumerateValidItems) == "function" then
        local ok, iterator, state, control = pcall(frame.EnumerateValidItems, frame)
        if ok and type(iterator) == "function" then
            for first, second in iterator, state, control do
                Add(first)
                Add(second)
            end
        end
    end

    return list
end

local function IsShownSafe(frame)
    if type(frame) ~= "table" then return false end
    if not frame.IsShown then return true end
    -- 比较也放进 pcall：某些客户端会把返回值标成不可读
    local ok, shown = pcall(function() return frame:IsShown() == true end)
    if not ok or shown ~= true then return false end
    -- IsShown 只看窗口自己；被整合背包藏到隐藏父窗口下的暴雪背包仍然算“显示”，
    -- 会抢在真正的整合背包窗口前面被扫描。IsVisible 会一并检查父窗口。
    if type(frame.IsVisible) == "function" then
        local okVisible, visible = pcall(function() return frame:IsVisible() end)
        if okVisible and type(visible) == "boolean" then
            return visible
        end
    end
    return true
end

-- 从鼠标提示里认识的背包窗口：这样即使是不认识的背包界面，
-- 只要鼠标在某个格子上停过一次，也能找到同一个窗口里的其他格子。
local extraRoots = {}

local function LearnBagRoot(button)
    local root, depth = button, 0
    while depth < 10 do
        local ok, parent = pcall(root.GetParent, root)
        if not ok or type(parent) ~= "table" or parent == _G.UIParent then break end
        root = parent
        depth = depth + 1
    end
    if root ~= button and root ~= _G.UIParent and not extraRoots[root] then
        extraRoots[root] = true
        return true
    end
    return false
end

-- 背包号和格子号一律从格子按钮自己读；窗口 ID 和 Items 的键只做兜底。
-- 格子按钮会被背包界面重复利用，所以每次都要重新解析，不能缓存旧位置。
local function ResolveButton(button, bagHint, slotHint)
    if type(button) ~= "table" then return nil, nil end

    local slot = Safe(button.GetID, button)
    if type(slot) ~= "number" or slot <= 0 then
        -- 有的界面按钮编号不在 GetID 上，改从名字后缀取
        local name = type(button.GetName) == "function" and Safe(button.GetName, button)
        if type(name) == "string" then
            slot = tonumber(name:match("(%d+)$"))
        end
    end
    if (type(slot) ~= "number" or slot <= 0) and type(slotHint) == "number" and slotHint > 0 then
        slot = slotHint
    end

    local bag = Safe(button.GetBagID, button)
    if type(bag) ~= "number" then bag = Safe(button.GetBag, button) end
    if type(bag) ~= "number" and type(button.GetParent) == "function" then
        local ok, parent = pcall(button.GetParent, button)
        if ok and type(parent) == "table" and parent.GetID then
            bag = Safe(parent.GetID, parent)
        end
    end
    if type(bag) ~= "number" then bag = bagHint end
    return bag, slot
end

local function VisitButton(button, seen, bagHint, slotHint)
    if type(button) ~= "table" or seen[button] then return end
    seen[button] = true
    scan.visited = scan.visited + 1
    if not IsShownSafe(button) then scan.hidden = scan.hidden + 1 end

    local bag, slot = ResolveButton(button, bagHint, slotHint)
    if type(bag) ~= "number" then scan.noBag = scan.noBag + 1 end
    if type(slot) ~= "number" then scan.noSlot = scan.noSlot + 1 end
    -- 背包/格子取不到时宁可不动，避免用错格子把已经标好的图标藏掉
    if type(bag) ~= "number" or type(slot) ~= "number" then return end
    MarkButton(button, bag, slot)
end

-- 有些背包界面把格子放在滚动框里，按名字或 Items 表都拿不到，只能顺着子对象找
local function WalkBagButtons(root, depth, seen, budget, bagHint)
    if depth > 8 or budget.n > 3000 or type(root) ~= "table" then return end
    budget.n = budget.n + 1
    local ok, children = pcall(root.GetChildren, root)
    if not ok or type(children) ~= "table" then return end
    for _, child in ipairs(children) do
        if type(child) == "table" and IsShownSafe(child) then
            -- 背包格子自己下面都是冷却、边框之类的装饰，不用再往下找
            if type(child.GetBag) == "function" or type(child.GetBagID) == "function" then
                VisitButton(child, seen, bagHint)
            else
                WalkBagButtons(child, depth + 1, seen, budget, bagHint)
            end
        end
    end
end

local function IsBagButton(button)
    if type(button) ~= "table" then return false end
    if type(button.GetBagID) == "function" or type(button.GetBag) == "function" then
        return true
    end
    return false
end

local function HasBagButtons(frame, depth, includeHidden)
    if depth < 0 or type(frame) ~= "table" then return false end
    local ok, children = pcall(frame.GetChildren, frame)
    if not ok or type(children) ~= "table" then return false end
    for _, child in ipairs(children) do
        if type(child) == "table" and (includeHidden or IsShownSafe(child)) then
            if IsBagButton(child) then return true end
            if depth > 0 and HasBagButtons(child, depth - 1, includeHidden) then return true end
        end
    end
    return false
end

-- 背包插件/整合背包的窗口不一定叫 ContainerFrame，也不一定有 Items 表。
-- 只自动认领确实带有背包格子的顶层窗口，避免把动作条、商人等界面当成背包。
local IGNORED_ROOT_WORDS = { "bank", "merchant", "mail", "auction", "guild", "trade" }

local function BagRootAllowed(name)
    if type(name) ~= "string" then return true end
    local lower = name:lower()
    if lower:find("^containerframe", 1) then return false end
    for _, word in ipairs(IGNORED_ROOT_WORDS) do
        if lower:find(word, 1, true) then return false end
    end
    return true
end

local lastDiscover = 0
local function DiscoverBagRoots(force)
    if type(UIParent) ~= "table" or type(UIParent.GetChildren) ~= "function" then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local now = type(GetTime) == "function" and GetTime() or 0
    if not force and now > 0 and now - lastDiscover < 3 then return end
    lastDiscover = now

    local ok, children = pcall(UIParent.GetChildren, UIParent)
    if not ok or type(children) ~= "table" then return end
    for _, child in ipairs(children) do
        if type(child) == "table" and not extraRoots[child] then
            local shown = IsShownSafe(child)
            local name = Safe(child.GetName, child)
            local lower = type(name) == "string" and name:lower() or ""
            -- 名字里带 bag 的窗口可以找深一点，其他窗口只看两层
            local looksLikeBag = lower ~= ""
                and (lower:find("bag", 1, true) or lower:find("inventory", 1, true))
            if BagRootAllowed(name) and (shown or looksLikeBag) then
                -- 整合背包窗口在登录时先创建再隐藏，趁隐藏时先记住它，
                -- 之后它一显示就能立刻扫描，不必等名字/层级再次匹配。
                if HasBagButtons(child, looksLikeBag and 6 or 2, not shown) then
                    extraRoots[child] = true
                end
            end
        end
    end
end

local function RefreshFrame(frame)
    if not IsShownSafe(frame) then return end
    scan.frames = scan.frames + 1
    local name = Safe(frame.GetName, frame)
    local bag = Safe(frame.GetID, frame)
    if type(bag) ~= "number" and type(name) == "string" then
        local index = tonumber(name:match("^ContainerFrame(%d+)$"))
        if index then bag = index - 1 end
    end
    if type(bag) ~= "number" then bag = nil end

    local seen = {}

    -- 窗口自己的 ID 不一定是背包号（合并背包窗口尤其如此），只把它当兜底；
    -- 背包号和格子号一律优先从格子按钮自己读，和鼠标提示里用的是同一套判定。
    local items = frame.Items
    if type(items) == "table" and next(items) ~= nil then
        for key, button in pairs(items) do
            VisitButton(button, seen, bag, type(key) == "number" and key or nil)
        end
        return
    end

    -- 旧式窗口：格子按名字编号
    if type(name) == "string" then
        local found = false
        for i = 1, 100 do
            local button = _G[name .. "Item" .. i]
            if type(button) == "table" then
                found = true
                VisitButton(button, seen, bag, i)
            end
        end
        if found then return end
    end

    -- 不认识的背包界面：再逐个按钮解析
    for _, button in ipairs(CollectButtons(frame)) do
        VisitButton(button, seen, bag)
    end
    WalkBagButtons(frame, 0, seen, { n = 0 }, bag)
end

local function RefreshBlizzardBags()
    for i = 1, MAX_CONTAINER_FRAME_SCAN do
        local frame = _G["ContainerFrame" .. i]
        if frame and IsShownSafe(frame) then
            RefreshFrame(frame)
        end
    end
    local combined = _G.ContainerFrameCombinedBags
    if combined and IsShownSafe(combined) then
        RefreshFrame(combined)
    end
end

-- 注意：不能写成 ipairs({ _G.BagBrother, _G.Bagnon, _G.Bagnonium })。
-- 只装 Bagnonium 时前面两项是 nil，ipairs 会在第一项就停下，
-- 导致 Bagnonium 永远轮不到。这里按名字逐个取。
local BAG_ADDON_NAMES = { "BagBrother", "Bagnon", "Bagnonium" }

local function EachBagAddon(fn)
    for _, name in ipairs(BAG_ADDON_NAMES) do
        local addon = _G[name]
        if type(addon) == "table" then
            fn(addon, name)
        end
    end
end

-- Frames:Get 有时返回窗口对象，有时还是注册表里的占位表；
-- 真正的窗口一定能 GetChildren。
local function FrameFromValue(value)
    if type(value) ~= "table" then return nil end
    if type(value.GetChildren) == "function" then return value end
    local inner = rawget(value, 0)
    if type(inner) == "table" and type(inner.GetChildren) == "function" then
        return inner
    end
    inner = rawget(value, "frame")
    if type(inner) == "table" and type(inner.GetChildren) == "function" then
        return inner
    end
    return nil
end

-- Bagnon / BagBrother / Bagnonium 自己的背包窗口
local function BagnonRoots()
    local roots, added = {}, {}
    local function AddValue(value)
        local frame = FrameFromValue(value)
        if frame and not added[frame] then
            added[frame] = true
            roots[#roots + 1] = frame
        end
    end

    EachBagAddon(function(addon)
        local frames = addon.Frames
        if type(frames) ~= "table" then return end
        for _, key in ipairs({ "inventory", "bank" }) do
            local value
            if type(frames.Get) == "function" then
                local ok, got = pcall(frames.Get, frames, key)
                if ok then value = got end
            end
            if value == nil then
                local ok, got = pcall(function() return frames[key] end)
                if ok then value = got end
            end
            AddValue(value)
        end
        -- 注册表兜底：窗口创建后 Get 可能仍返回占位表，直接遍历注册表
        local registry = frames.Registry
        if type(registry) == "table" then
            for _, entry in ipairs(registry) do
                if type(entry) == "table" and (entry.id == "inventory" or entry.id == "bank") then
                    AddValue(entry)
                end
            end
        end
    end)
    return roots
end

local function RefreshExtraRoots()
    for root in pairs(extraRoots) do
        if IsShownSafe(root) then RefreshFrame(root) end
    end
    for _, root in ipairs(BagnonRoots()) do
        if IsShownSafe(root) then RefreshFrame(root) end
    end
end

function RefreshAll()
    if not enabled or not indexReady then
        for button in pairs(tracked) do
            HideOverlay(button)
        end
        return
    end
    scan.refreshes = scan.refreshes + 1
    scan.frames, scan.visited, scan.marked = 0, 0, 0
    scan.hidden, scan.noBag, scan.noSlot = 0, 0, 0
    scan.lastError = ""
    local ok, err = pcall(function()
        DiscoverBagRoots()
        -- 格子按钮会被背包界面重复利用，旧位置不能直接拿来重标，必须按按钮重新解析
        for button in pairs(tracked) do
            local bag, slot = ResolveButton(button)
            if type(bag) == "number" and type(slot) == "number" then
                MarkButton(button, bag, slot)
            else
                HideOverlay(button)
            end
        end
        RefreshBlizzardBags()
        RefreshExtraRoots()
    end)
    if not ok then scan.lastError = tostring(err) end
end

-- 背包开着的时候定时补一次，覆盖没有可靠打开事件的背包界面
local watcher
local function AnyBagWindowShown()
    for i = 1, MAX_CONTAINER_FRAME_SCAN do
        local frame = _G["ContainerFrame" .. i]
        if frame and IsShownSafe(frame) then return true end
    end
    local combined = _G.ContainerFrameCombinedBags
    if combined and IsShownSafe(combined) then return true end
    for root in pairs(extraRoots) do
        if IsShownSafe(root) then return true end
    end
    for _, root in ipairs(BagnonRoots()) do
        if IsShownSafe(root) then return true end
    end
    return false
end

local function StartWatcher()
    if watcher or not C_Timer or not C_Timer.NewTicker then return end
    local ok, created = pcall(C_Timer.NewTicker, 0.7, function()
        scan.watchTicks = scan.watchTicks + 1
        if not enabled or not indexReady then return end
        if scan.watchTicks % 8 == 0 then
            pcall(DiscoverBagRoots, true)
        end
        if AnyBagWindowShown() then
            scan.watchRefreshes = scan.watchRefreshes + 1
            RefreshAll()
        elseif scan.watchTicks % 8 == 0 then
            -- 窗口没认出来时也刷新已记录的格子，避免一直停在旧状态
            scan.watchRefreshes = scan.watchRefreshes + 1
            RefreshAll()
        end
    end)
    if ok then watcher = created end
end

local function StopWatcher()
    if watcher then
        pcall(watcher.Cancel, watcher)
        watcher = nil
    end
end

-- ---------------------------------------------------------------------------
-- 刷新的触发
-- ---------------------------------------------------------------------------
local refreshQueued = false
local function QueueRefresh(delay)
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(delay or 0.2, function()
        refreshQueued = false
        if enabled then RefreshAll() end
    end)
end

local function HookBlizzardFrames()
    local function hook(frame)
        if type(frame) == "table" and not frame.lpextQuestItemHooked then
            frame.lpextQuestItemHooked = true
            pcall(frame.HookScript, frame, "OnShow", function()
                QueueRefresh(0.05)
            end)
            if type(frame.UpdateItems) == "function" then
                pcall(hooksecurefunc, frame, "UpdateItems", function()
                    QueueRefresh(0.1)
                end)
            end
        end
    end
    hook(_G.ContainerFrameCombinedBags)
    for i = 1, MAX_CONTAINER_FRAME_SCAN do
        hook(_G["ContainerFrame" .. i])
    end
    if type(ContainerFrame_Update) == "function" then
        pcall(hooksecurefunc, "ContainerFrame_Update", function()
            QueueRefresh(0.1)
        end)
    end
    for _, name in ipairs({ "ToggleBag", "OpenAllBags", "ToggleAllBags",
                            "ContainerFrameItemButton_Update" }) do
        if type(_G[name]) == "function" then
            pcall(hooksecurefunc, name, function()
                QueueRefresh(0.1)
            end)
        end
    end
end

-- 和背包插件自己用的扩展点一致：基类 Item 的 UpdateSecondary 会在每次
-- 格子刷新后调用（没有这个方法的旧版本退回 UpdatePrimary / Update）。
local function OnBagButtonUpdated(self)
    hookStats.calls = hookStats.calls + 1
    local ok, err = pcall(function()
        if type(self) ~= "table" then return end
        local bag = Safe(self.GetBag, self)
        if type(bag) ~= "number" then bag = Safe(self.GetBagID, self) end
        local slot = Safe(self.GetID, self)
        hookStats.lastBag, hookStats.lastSlot = bag, slot
        -- 存储里其他角色的离线视图不标
        if type(self.IsCached) == "function" then
            local okCached, cached = pcall(self.IsCached, self)
            if okCached and cached == true then
                HideOverlay(self)
                return
            end
        end
        MarkButton(self, bag, slot)
    end)
    if not ok then
        hookStats.lastError = tostring(err)
    end
end

local function HookBagnonClass(class, label)
    if type(class) ~= "table" then return end
    local method = type(class.UpdateSecondary) == "function" and "UpdateSecondary"
        or type(class.UpdatePrimary) == "function" and "UpdatePrimary"
        or type(class.Update) == "function" and "Update"
    if not method then return end
    local flag = "lpextQuestItemHooked" .. method
    if class[flag] then return end
    local ok, err = pcall(hooksecurefunc, class, method, OnBagButtonUpdated)
    if ok then
        class[flag] = true
        hookStats.installed[#hookStats.installed + 1] = label .. "." .. method
    else
        hookStats.errors[#hookStats.errors + 1] = label .. "." .. method .. "：" .. tostring(err)
    end
end

local function HookBagnon()
    EachBagAddon(function(addon, name)
        HookBagnonClass(addon.Item, name .. ".Item")
        -- 只有在没有 Item 基类时才退到 ContainerItem，避免同一次刷新挂两次
        if type(addon.Item) ~= "table" then
            HookBagnonClass(addon.ContainerItem, name .. ".ContainerItem")
            HookBagnonClass(addon.ItemButton, name .. ".ItemButton")
        end
    end)
end

-- 和 Bagnon_ItemLevel 一样，插件先加载的话就在这里先挂上；
-- 如果它比我们晚加载，ADDON_LOADED 和登录时还会再补一次。
HookBagnon()

-- ---------------------------------------------------------------------------
-- 任务日志变化
-- ---------------------------------------------------------------------------
local questQueued = false
local function QuestLogChanged(force)
    if questQueued then return end
    questQueued = true
    C_Timer.After(0.3, function()
        questQueued = false
        local signature, texts = ReadQuestLog()
        if force or signature ~= lastSignature then
            lastSignature = signature
            activeTexts = texts
            verdict = {}
            if enabled then RefreshAll() end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- 鼠标提示
-- ---------------------------------------------------------------------------
local function TooltipOwnerBagSlot(tooltip)
    local ok, owner = pcall(function() return tooltip:GetOwner() end)
    if not ok or type(owner) ~= "table" then return nil end
    local slot = Safe(owner.GetID, owner)
    if type(slot) ~= "number" or slot <= 0 then return nil end
    local bag = Safe(owner.GetBagID, owner)
    if type(bag) ~= "number" and type(owner.GetBag) == "function" then
        bag = Safe(owner.GetBag, owner)
    end
    if type(bag) ~= "number" and type(owner.GetParent) == "function" then
        local okParent, parent = pcall(owner.GetParent, owner)
        if okParent and type(parent) == "table" and parent.GetID then
            bag = Safe(parent.GetID, parent)
        end
    end
    if type(bag) ~= "number" then return nil end
    return bag, slot, owner
end

local function AddTooltipLine(tooltip, data)
    if not enabled or not indexReady or type(tooltip) ~= "table" then return end
    if type(tooltip.AddLine) ~= "function" then return end

    local itemID = type(data) == "table" and Legible(data.id) or nil
    if type(itemID) ~= "number" then
        local _, link = Safe(tooltip.GetItem, tooltip)
        if type(link) == "string" then
            itemID = tonumber(link:match("item:(%d+)"))
        end
    end
    if type(itemID) ~= "number" then return end

    local bag, slot, owner = TooltipOwnerBagSlot(tooltip)
    if not bag or not slot then return end
    if ContainerItemID(bag, slot) ~= itemID then return end
    if not ShouldMark(bag, slot) then return end

    -- 无论用的是哪种背包界面，鼠标移上去时都把图标标记补上
    MarkButton(owner, bag, slot)
    lastHover = { bag = bag, slot = slot, item = itemID, button = owner }
    -- 顺便记住这个背包窗口，之后打开同一个窗口就能自动标记所有格子
    if owner and LearnBagRoot(owner) then
        QueueRefresh(0.1)
    end
    tooltip:AddLine("相关任务均已完成，可出售或删除", 1, 0.35, 0.3, true)
    tooltip:Show()
end

local tooltipRegistered = false
if type(TooltipDataProcessor) == "table"
    and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    tooltipRegistered = pcall(
        TooltipDataProcessor.AddTooltipPostCall,
        Enum.TooltipDataType.Item,
        function(tooltip, data) AddTooltipLine(tooltip, data) end
    )
end
if not tooltipRegistered then
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
        local tip = _G[name]
        if type(tip) == "table" and type(tip.HookScript) == "function" then
            pcall(tip.HookScript, tip, "OnTooltipSetItem", function(self)
                AddTooltipLine(self, nil)
            end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 开关 / 事件
-- ---------------------------------------------------------------------------
local function IsEnabled()
    local value = DB.questItemCleanup
    if value == nil then return DEFAULT end
    return value == true
end

local function Apply(on)
    enabled = on and true or false
    verdict = {}
    if not loggedIn then return end
    local function Attempt(fn)
        local ok, err = pcall(fn)
        if not ok then scan.lastError = tostring(err) end
    end
    Attempt(HookBagnon)
    if enabled then
        Attempt(HookBlizzardFrames)
        Attempt(function() QueueIndex(indexReady and 0 or INDEX_DELAY) end)
        Attempt(RefreshAll)
        Attempt(StartWatcher)
    else
        Attempt(StopWatcher)
        Attempt(RefreshAll)
    end
end

local eventFrame = CreateFrame("Frame")
local EVENTS = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "ADDON_LOADED",
    "BAG_UPDATE_DELAYED",
    "QUEST_LOG_UPDATE",
    "QUEST_TURNED_IN",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "GET_ITEM_INFO_RECEIVED",
}
for _, event in ipairs(EVENTS) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        loggedIn = true
        QuestLogChanged(true)
        Apply(IsEnabled())
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 冗余保障：即使登录那一步有东西没挂上，进世界时再补一次
        loggedIn = true
        if enabled then
            pcall(HookBlizzardFrames)
            pcall(StartWatcher)
            pcall(RefreshAll)
        end
    elseif event == "ADDON_LOADED" then
        if arg1 == "BagBrother" or arg1 == "Bagnon" or arg1 == "Bagnonium" then
            HookBagnon()
        elseif arg1 == "QuestieDB" and loggedIn and enabled then
            QueueIndex(0)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if enabled and indexReady then RefreshAll() end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        verdict = {}
        if enabled and indexReady then QueueRefresh(0.5) end
    else
        QuestLogChanged(false)
    end
end)

-- 说明单个物品的判定结果，用于诊断
local function DescribeVerdict(itemID, db)
    if not IsQuestRelatedItem(itemID, db) then
        return "不是任务物品"
    end
    local related = {}
    CollectRelated(itemID, db, related)
    local mask = GetFactionMask(db)
    local relevant, blocking = 0, {}
    for questID in pairs(related) do
        if QuestRelevant(questID, db, mask) then
            relevant = relevant + 1
            if QuestStillNeeded(questID, db) then
                blocking[#blocking + 1] = questID
            end
        end
    end
    table.sort(blocking)
    if relevant == 0 then
        return "找不到本阵营/本职业能接的相关任务，不标"
    end
    if #blocking > 0 then
        local shown = {}
        for i = 1, math.min(#blocking, 6) do
            shown[i] = tostring(blocking[i])
        end
        return "还有未完成的相关任务 " .. table.concat(shown, ",")
            .. (#blocking > 6 and " 等" or "")
    end
    if NeededByActiveText(itemID, db) then
        return "当前任务目标文字里出现了这个物品名，不标"
    end
    return "可标记"
end

-- /lpext diag questitemcleanup：标记状态诊断（先打开背包再看）
function NS.DiagnoseQuestItemCleanup()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add("标记多余的任务物品=" .. (enabled and "开" or "关"))
    add("QuestieDB=" .. (GetDB() and "已加载" or "未加载"))
    add("任务索引=" .. (indexReady and "就绪" or (indexStarted and "构建中" or "未开始")))

    local marked, total = 0, 0
    for button in pairs(tracked) do
        total = total + 1
        local overlay = button.lpextQuestItemOverlay
        if overlay and IsShownSafe(overlay) then
            marked = marked + 1
        end
    end
    add("已记录格子=" .. total .. "，当前显示标记=" .. marked)
    add("自动刷新次数=" .. scan.refreshes .. "，上次扫描：窗口=" .. scan.frames
        .. "，格子=" .. scan.visited .. "，不可见=" .. scan.hidden
        .. "，没取到背包=" .. scan.noBag .. "，没取到槽位=" .. scan.noSlot
        .. "，显示标记=" .. scan.marked)
    add("定时刷新=" .. (watcher and "已启动" or "未启动")
        .. "，计时次数=" .. scan.watchTicks .. "，其中扫描=" .. scan.watchRefreshes)
    if scan.lastError ~= "" then
        add("上次刷新出错：" .. scan.lastError)
    end

    local frames, buttons = 0, 0
    local function count(frame)
        if IsShownSafe(frame) then
            frames = frames + 1
            buttons = buttons + #CollectButtons(frame)
        end
    end
    count(_G.ContainerFrameCombinedBags)
    for i = 1, MAX_CONTAINER_FRAME_SCAN do
        count(_G["ContainerFrame" .. i])
    end
    add("打开的暴雪背包窗口=" .. frames .. "，按名字/Items 找到格子=" .. buttons)

    -- 诊断时强制重新识别一次，避免定时器还没走到
    pcall(DiscoverBagRoots, true)

    local learned, bagnon = 0, 0
    local learnedNames = {}
    for root in pairs(extraRoots) do
        if IsShownSafe(root) then
            learned = learned + 1
            if #learnedNames < 8 then
                learnedNames[#learnedNames + 1] = tostring(Safe(root.GetName, root))
            end
        end
    end
    for _, root in ipairs(BagnonRoots()) do
        if IsShownSafe(root) then bagnon = bagnon + 1 end
    end
    add("自动识别的窗口=" .. learned .. "，整合背包窗口=" .. bagnon)
    if #learnedNames > 0 then
        add("自动识别窗口名：" .. table.concat(learnedNames, "，"))
    end

    local bagAddon = "无"
    if _G.Bagnonium then bagAddon = "Bagnonium"
    elseif _G.BagBrother then bagAddon = "BagBrother"
    elseif _G.Bagnon then bagAddon = "Bagnon" end
    add("背包插件=" .. bagAddon)
    local itemClass = _G.Bagnonium and _G.Bagnonium.Item
    if type(itemClass) == "table" then
        local method = itemClass.UpdateSecondary and "UpdateSecondary"
            or itemClass.UpdatePrimary and "UpdatePrimary"
            or itemClass.Update and "Update"
            or "无"
        add("Bagnonium 格子更新方法=" .. method)
    end

    add("整合背包挂钩=" .. (#hookStats.installed > 0
        and table.concat(hookStats.installed, "，") or "未挂上"))
    if #hookStats.errors > 0 then
        add("整合背包挂钩失败：" .. table.concat(hookStats.errors, "；"))
    end
    add("格子刷新回调次数=" .. hookStats.calls
        .. "，最近背包=" .. tostring(hookStats.lastBag)
        .. "，格子=" .. tostring(hookStats.lastSlot))
    if hookStats.lastError ~= "" then
        add("格子刷新回调出错：" .. hookStats.lastError)
    end

    EachBagAddon(function(addon, addonName)
        local frames = addon.Frames
        if type(frames) ~= "table" then
            add(addonName .. ".Frames=无")
            return
        end
        local value
        if type(frames.Get) == "function" then
            local okGet, got = pcall(frames.Get, frames, "inventory")
            if okGet then value = got end
        end
        local frame = FrameFromValue(value)
        local frameName = frame and Safe(frame.GetName, frame) or nil
        add(addonName .. " 背包窗口="
            .. (frame and tostring(frameName) or ("占位表 " .. type(value)))
            .. "，显示=" .. tostring(frame and IsShownSafe(frame) or false))
        if type(frames.Registry) == "table" then
            local created = 0
            for _, entry in ipairs(frames.Registry) do
                if type(entry) == "table" and type(entry.GetChildren) == "function" then
                    created = created + 1
                end
            end
            add(addonName .. " 注册窗口=" .. #frames.Registry .. "，已创建=" .. created)
        end
    end)

    local firstBag = _G.ContainerFrame1
    if firstBag then
        local parent = Safe(firstBag.GetParent, firstBag)
        add("暴雪背包窗口1：父窗口=" .. tostring(parent and Safe(parent.GetName, parent))
            .. "，显示=" .. tostring(IsShownSafe(firstBag)))
    end

    local named = {}
    if type(UIParent) == "table" and type(UIParent.GetChildren) == "function" then
        local okChildren, children = pcall(UIParent.GetChildren, UIParent)
        if okChildren and type(children) == "table" then
            for _, child in ipairs(children) do
                local childName = Safe(child.GetName, child)
                if type(childName) == "string" then
                    local lower = childName:lower()
                    if lower:find("bag", 1, true) or lower:find("inventory", 1, true) then
                        if #named < 12 then
                            named[#named + 1] = childName
                                .. (IsShownSafe(child) and "（显示）" or "（隐藏）")
                        end
                    end
                end
            end
        end
    end
    add("界面上的背包窗口：" .. (#named > 0 and table.concat(named, "，") or "无"))
    add("以上数字请在打开背包后查看；窗口和格子都是 0 说明没有扫描到背包界面。")

    add("—— 当前打开背包里的格子 ——")

    local function ButtonBag(button)
        local bag = Safe(button.GetBagID, button)
        if type(bag) ~= "number" then bag = Safe(button.GetBag, button) end
        if type(bag) ~= "number" then
            local ok, parent = pcall(button.GetParent, button)
            if ok and type(parent) == "table" and parent.GetID then
                bag = Safe(parent.GetID, parent)
            end
        end
        return bag
    end

    local dumped = 0
    local dumpedFrames = {}
    local function dumpFrame(frame)
        if not frame or dumpedFrames[frame] or dumped >= 40 or not IsShownSafe(frame) then return end
        dumpedFrames[frame] = true
        local frameName = Safe(frame.GetName, frame)
        local frameBag = Safe(frame.GetID, frame)
        if type(frameBag) ~= "number" and type(frameName) == "string" then
            local index = tonumber(frameName:match("^ContainerFrame(%d+)$"))
            if index then frameBag = index - 1 end
        end
        if type(frameBag) ~= "number" then frameBag = nil end
        add("窗口 " .. tostring(frameName) .. "：窗口背包=" .. tostring(frameBag))

        local function dump(button, key)
            if dumped >= 40 then return end
            dumped = dumped + 1
            -- 和实际标记用同一套解析：先信按钮自己的 GetID，再退回 Items 的键
            local slot = Safe(button.GetID, button)
            if type(slot) ~= "number" or slot <= 0 then
                slot = type(key) == "number" and key or nil
            end
            local buttonBag = ButtonBag(button)
            local bag = buttonBag
            if type(bag) ~= "number" then bag = frameBag end
            local bagText
            if type(buttonBag) == "number" then
                bagText = tostring(buttonBag)
                if type(frameBag) == "number" and frameBag ~= buttonBag then
                    bagText = bagText .. "（窗口=" .. tostring(frameBag) .. "）"
                end
            else
                bagText = tostring(bag) .. "（窗口兜底）"
            end
            local itemID = (type(bag) == "number" and type(slot) == "number")
                and ContainerItemID(bag, slot) or nil
            local text = "格子 " .. tostring(slot) .. "：背包=" .. bagText
                .. "，物品=" .. tostring(itemID) .. "，显示=" .. tostring(IsShownSafe(button))
            if type(itemID) == "number" then
                local verdict = "索引未就绪"
                if indexReady then
                    verdict = GetVerdict(itemID) and "可标记" or "不标"
                end
                text = text .. "，判定=" .. verdict
            end
            local overlay = button.lpextQuestItemOverlay
            if overlay then
                text = text .. "，图标标记=" .. (IsShownSafe(overlay) and "显示" or "隐藏")
            end
            add(text)
        end

        local items = frame.Items
        if type(items) == "table" and next(items) ~= nil then
            for key, button in pairs(items) do
                if type(button) == "table" then dump(button, key) end
            end
        else
            for _, button in ipairs(CollectButtons(frame)) do dump(button, nil) end
        end
    end
    dumpFrame(_G.ContainerFrameCombinedBags)
    for i = 1, MAX_CONTAINER_FRAME_SCAN do
        dumpFrame(_G["ContainerFrame" .. i])
    end
    for root in pairs(extraRoots) do
        local rootName = Safe(root.GetName, root)
        if type(rootName) ~= "string" or not rootName:find("^ContainerFrame") then
            dumpFrame(root)
        end
    end
    for _, root in ipairs(BagnonRoots()) do
        dumpFrame(root)
    end
    if dumped == 0 then add("（当前没有打开的背包格子）") end

    if lastHover then
        local ownerName = lastHover.button and Safe(lastHover.button.GetName, lastHover.button)
        add("最近一次悬停标记：物品=" .. tostring(lastHover.item)
            .. "，背包=" .. tostring(lastHover.bag) .. "，格子=" .. tostring(lastHover.slot)
            .. (type(ownerName) == "string" and ("，格子名=" .. ownerName) or ""))
    end

    add("—— 背包里的任务物品 ——")
    local db = GetDB()
    local listed = {}
    for _, where in pairs(tracked) do
        local bag, slot = where[1], where[2]
        local itemID = ContainerItemID(bag, slot)
        if itemID and not listed[itemID] then
            local isQuestItem = GetBagQuestInfo(bag, slot)
            local related = db and IsQuestRelatedItem(itemID, db)
            if isQuestItem or related then
                listed[itemID] = true
                local name = (db and ItemName(itemID, db)) or ("物品 " .. itemID)
                add(name .. "（" .. itemID .. "）：背包=" .. tostring(bag)
                    .. " 格子=" .. tostring(slot) .. "，"
                    .. (db and DescribeVerdict(itemID, db) or "QuestieDB 未加载"))
            end
        end
    end
    if next(listed) == nil then
        add("（当前没有识别到任务物品）")
    end
    return lines
end

local questieWarned = false

NS.RegisterModule({
    key = "questItemCleanup",
    section = "任务",
    label = "标记多余的任务物品",
    tip = "在背包里把任务已经交完、不再需要的任务物品描红，并在角落显示 ×，方便出售或删除。"
        .. "\n\n只标记确定没用的物品；任务还没做完、还没接，或者无法确定的都不会标记。"
        .. "\n\n需要安装 Questie。",
    default = DEFAULT,
    onToggle = function(value)
        Apply(value == true)
        if value and not GetDB() and not questieWarned then
            questieWarned = true
            print("|cff66ccffLeatrixPlusExt|r 标记多余的任务物品需要安装 Questie。")
        end
    end,
})
