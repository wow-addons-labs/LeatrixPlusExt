-- LeatrixPlusExt 模块：寻求组队位置
-- 在“寻求组队”列表的每条信息右侧标出队长或玩家的当前所在区域
local addonName, NS = ...

local DB = NS.DB

local LABEL = "队长："
local DEFAULT = true
local SAME_COLOR = { 0.25, 0.94, 0.54 }   -- 和你在同一区域：绿色
local OTHER_COLOR = { 0.85, 0.70, 0.35 }  -- 其他区域：金色

local function IsEnabled()
    local value = DB.lfgWhere
    if value == nil then return DEFAULT end
    return value and true or false
end

-- 机密值（聊天锁定等）读不了就当作没有
-- 这个接口本身也可能对普通值报错，异常时按「可读」处理，别把扫描卡死
local function Accessible(value)
    if type(canaccessvalue) ~= "function" then return true end
    local ok, result = pcall(canaccessvalue, value)
    if not ok then return true end
    return result and true or false
end

-- 当前位置的所有写法（大区域、子区域、小地图、当前地图名）
-- 这些接口可能返回 nil 或机密值：nil 不能当表的键，读不到就跳过
local function PlayerZones()
    local zones = {}
    local function Add(zone)
        if zone ~= nil and Accessible(zone) then
            zones[zone] = true
        end
    end
    if type(GetRealZoneText) == "function" then Add(GetRealZoneText()) end
    if type(GetSubZoneText) == "function" then Add(GetSubZoneText()) end
    if type(GetMinimapZoneText) == "function" then Add(GetMinimapZoneText()) end
    if C_Map and C_Map.GetBestMapForUnit then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID and Accessible(mapID) and C_Map.GetMapInfo then
            local mapInfo = C_Map.GetMapInfo(mapID)
            if mapInfo then Add(mapInfo.name) end
        end
    end
    return zones
end

-- ---------------------------------------------------------------------------
-- 副本所在地
-- 活动表里的 mapID 指向副本地图，从它往上走地图链：
-- 副本名 → 所在区域（→ 上级区域），走到大陆就停。
-- 队长/玩家的区域命中链上任一名字，就说明人在副本所在地。
-- ---------------------------------------------------------------------------
local mapChainCache = {}

local function MapChainEntry(mapID)
    local cached = mapChainCache[mapID]
    if cached ~= nil then return cached end
    if not (C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    local entry = false
    if ok and type(info) == "table" then
        local name = info.name
        if name ~= nil and not Accessible(name) then name = nil end
        local parent = info.parentMapID
        if parent ~= nil and not Accessible(parent) then parent = nil end
        local mapType = info.mapType
        if mapType ~= nil and not Accessible(mapType) then mapType = nil end
        entry = { name = name, parent = parent, mapType = mapType }
    end
    mapChainCache[mapID] = entry
    return entry
end

local function AddDungeonZones(mapID, zones)
    local depth = 0
    while type(mapID) == "number" and mapID > 0 and depth < 8 do
        local entry = MapChainEntry(mapID)
        if entry == nil or entry == false then return end
        -- 大陆 / 世界地图往上就超出「副本所在地」的范畴了，不要算进去
        if type(entry.mapType) == "number" and entry.mapType <= 2 then return end
        if entry.name then zones[entry.name] = true end
        mapID = entry.parent
        depth = depth + 1
    end
end

-- 列表里所有活动对应的副本所在地集合
local function DungeonZonesFromInfo(info)
    if type(info) ~= "table" or not Accessible(info) then return nil end
    local okIDs, activityIDs = pcall(function() return info.activityIDs end)
    if not okIDs or type(activityIDs) ~= "table" or not Accessible(activityIDs) then
        return nil
    end
    if not (C_LFGList and C_LFGList.GetActivityInfoTable) then return nil end
    local zones = {}
    for _, activityID in ipairs(activityIDs) do
        local okActivity, activity = pcall(C_LFGList.GetActivityInfoTable, activityID)
        if okActivity and type(activity) == "table" and Accessible(activity) then
            local okMap, mapID = pcall(function() return activity.mapID end)
            if okMap and type(mapID) == "number" and Accessible(mapID) then
                AddDungeonZones(mapID, zones)
            end
        end
    end
    return zones
end

-- 这个客户端的地图数据里没有副本地图层：剃刀高地的 mapID=129 查不到地图信息，
-- 所以再备一份经典副本 → 所在地的对照表。地图链能查到时会和它合并使用。
local DUNGEON_ZONE_NAMES = {
    ["怒焰裂谷"] = { "奥格瑞玛", "杜隆塔尔" },
    ["哀嚎洞穴"] = { "贫瘠之地", "奥格瑞玛" },
    ["死亡矿井"] = { "西部荒野", "暴风城" },
    ["暴风城监狱"] = { "暴风城" },
    ["黑暗深渊"] = { "灰谷" },
    ["影牙城堡"] = { "银松森林", "幽暗城" },
    ["剃刀沼泽"] = { "贫瘠之地", "千针石林" },
    ["剃刀高地"] = { "贫瘠之地", "千针石林" },
    ["诺莫瑞根"] = { "丹莫罗", "铁炉堡" },
    ["奥达曼"] = { "荒芜之地" },
    ["玛拉顿"] = { "凄凉之地" },
    ["祖尔法拉克"] = { "塔纳利斯" },
    ["沉没的神庙"] = { "悲伤沼泽" },
    ["厄运之槌"] = { "菲拉斯" },
    ["厄运之槌（东）"] = { "菲拉斯" },
    ["厄运之槌（西）"] = { "菲拉斯" },
    ["厄运之槌（北）"] = { "菲拉斯" },
    ["黑石深渊"] = { "黑石山", "燃烧平原", "灼热峡谷" },
    ["黑石塔"] = { "黑石山", "燃烧平原", "灼热峡谷" },
    ["熔火之心"] = { "黑石山", "燃烧平原", "灼热峡谷" },
    ["黑翼之巢"] = { "黑石山", "燃烧平原", "灼热峡谷" },
    ["通灵学院"] = { "西瘟疫之地" },
    ["斯坦索姆"] = { "东瘟疫之地" },
    ["血色修道院"] = { "提瑞斯法林地", "幽暗城" },
    ["血色军械库"] = { "提瑞斯法林地", "幽暗城" },
    ["血色大教堂"] = { "提瑞斯法林地", "幽暗城" },
    ["血色图书馆"] = { "提瑞斯法林地", "幽暗城" },
    ["奥妮克希亚的巢穴"] = { "尘泥沼泽" },
    ["祖尔格拉布"] = { "荆棘谷" },
    ["安其拉废墟"] = { "希利苏斯" },
    ["安其拉神殿"] = { "希利苏斯" },
    ["纳克萨玛斯"] = { "东瘟疫之地" },

    -- 《魔兽世界：无限》新增五人副本
    -- 社区译名不统一，常见几种写法都收录；游戏内以活动列表显示的名字为准
    ["诸王大厅"] = { "铁炉堡", "丹莫罗" },
    ["领主大厅"] = { "铁炉堡", "丹莫罗" },
    ["洛丹伦废墟"] = { "提瑞斯法林地", "幽暗城" },
    ["湿地发掘场"] = { "湿地" },
    ["湿地挖掘场"] = { "湿地" },
    ["挖掘场：湿地"] = { "湿地" },
    ["维尔加挖掘场"] = { "湿地" },
    ["达拉然城"] = { "奥特兰克山脉", "达拉然", "希尔斯布莱德丘陵" },
    ["沉没之城"] = { "荆棘谷", "藏宝海湾" },
    ["克罗多克要塞"] = { "河林" },
    ["奥卡兹监狱"] = { "尘泥沼泽", "奥卡兹岛" },
    ["阿尔卡兹监狱"] = { "尘泥沼泽", "阿尔卡兹岛" },
    ["黑喉要塞"] = { "艾萨拉" },
    ["塑造者之台"] = { "安戈洛环形山" },
    ["塑世者之台"] = { "安戈洛环形山" },
    ["塑造者平台"] = { "安戈洛环形山" },

    -- 《魔兽世界：无限》新增团本
    ["荒冢深穴"] = { "海加尔山", "艾萨拉" },
    ["深穴"] = { "海加尔山", "艾萨拉" },
    ["海加尔山巅"] = { "海加尔山" },
    ["海加尔峰"] = { "海加尔山" },
}

-- 名称 → 所在地集合；副本名本身也算（人在副本里时区域名就是副本名）
local dungeonZoneSets = {}
for name, zones in pairs(DUNGEON_ZONE_NAMES) do
    local set = { [name] = true }
    for _, zone in ipairs(zones) do set[zone] = true end
    dungeonZoneSets[name] = set
end

-- 活动名可能带括号后缀（「厄运之槌（东）」），先精确匹配再去后缀匹配
-- 注意：不能用字符类排除「（」，UTF-8 多字节会被按字节拆开，只能在原串上明文查找
local function StripSuffix(name)
    local cut
    local marks = { "（", "(" }
    for _, mark in ipairs(marks) do
        local pos = string.find(name, mark, 1, true)
        if pos and (cut == nil or pos < cut) then cut = pos end
    end
    if cut == nil then return name end
    local base = string.sub(name, 1, cut - 1)
    base = string.match(base, "^%s*(.-)%s*$")
    return base
end

local function KnownDungeonZones(name)
    if type(name) ~= "string" then return nil end
    local set = dungeonZoneSets[name]
    if set then return set end
    local base = StripSuffix(name)
    if base ~= "" and base ~= name then return dungeonZoneSets[base] end
    return nil
end

-- 队长的区域和队伍人数（与独立版 LFGWhere 保持一致）
-- 单人列表没有队长信息时，玩家列表里的第一个人就是列表主人
local function LeaderArea(resultID)
    if not resultID or not C_LFGList then
        return nil
    end
    -- 明确查不到这条结果才退出；接口本身不可用时继续尝试下面的读法
    if C_LFGList.HasSearchResultInfo then
        local ok, has = pcall(C_LFGList.HasSearchResultInfo, resultID)
        if ok and not has then return nil end
    end

    local area
    if C_LFGList.GetSearchResultLeaderInfo then
        local okLeader, leader = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
        if okLeader and type(leader) == "table" then
            local value = leader.areaName
            if value ~= nil and Accessible(value) then area = value end
        end
    end

    local numMembers = 1
    local dungeonZones
    if C_LFGList.GetSearchResultInfo then
        local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
        if okInfo and type(info) == "table" then
            local value = info.numMembers
            if value ~= nil and Accessible(value) then numMembers = value end
            dungeonZones = DungeonZonesFromInfo(info)
        end
    end

    -- 兜底：单人列表从玩家信息里取区域
    if area == nil and numMembers == 1 and C_LFGList.GetSearchResultPlayerInfo then
        local okMember, member = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, 1)
        if okMember and type(member) == "table" then
            local value = member.areaName
            if value ~= nil and Accessible(value) then area = value end
        end
    end

    return area, numMembers, dungeonZones
end

-- 活动（副本）名称：从搜索结果的活动 ID 里取第一个可读的名字
local function ActivityNameFromInfo(info)
    if type(info) ~= "table" or not Accessible(info) then return nil end
    local okIDs, activityIDs = pcall(function() return info.activityIDs end)
    if not okIDs or type(activityIDs) ~= "table" or not Accessible(activityIDs) then
        return nil
    end
    if type(C_LFGList.GetActivityInfoTable) ~= "function" then return nil end
    for _, activityID in ipairs(activityIDs) do
        local okActivity, activity = pcall(C_LFGList.GetActivityInfoTable, activityID)
        if okActivity and type(activity) == "table" then
            for _, key in ipairs({ "shortName", "fullName", "name" }) do
                local okValue, value = pcall(function() return activity[key] end)
                if okValue and type(value) == "string" and value ~= ""
                    and Accessible(value) then
                    return value
                end
            end
        end
    end
    return nil
end

-- 区域是否算「副本所在地」：地图链命中、区域就是副本名、或命中内置对照表
local function SameAsDungeon(area, activityName, dungeonZones)
    if area == nil then return false end
    if dungeonZones and dungeonZones[area] then return true end
    if type(activityName) == "string" and activityName ~= "" then
        if activityName == area then return true end
        local known = KnownDungeonZones(activityName)
        if known and known[area] then return true end
    end
    return false
end

-- 供「寻找组队筛选」模块调用：队长/玩家区域、队伍人数、是否在副本所在地
function NS.GetLeaderInfo(resultID)
    local area, numMembers, dungeonZones = LeaderArea(resultID)
    if area == nil then return nil, numMembers, false end
    local activityName
    if C_LFGList and C_LFGList.GetSearchResultInfo then
        local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
        if ok and type(info) == "table" then
            activityName = ActivityNameFromInfo(info)
        end
    end
    return area, numMembers, SameAsDungeon(area, activityName, dungeonZones)
end

-- 行的搜索结果 ID：优先读暴雪写在行上的字段，读不到再问 elementData
local function RowResultID(row)
    local id = row.resultID
    if id ~= nil then return id end
    if row.GetElementData then
        local ok, data = pcall(row.GetElementData, row)
        if ok and type(data) == "table" and Accessible(data) then
            local okID, value = pcall(function() return data.resultID end)
            if okID then return value end
        end
    end
    return nil
end

-- 行上已经显示的副本（活动）名，直接复用暴雪写入的文本，不用再查一遍接口
local function RowActivityName(row)
    local fontString = row.ActivityName
    if not fontString then return nil end
    local ok, text = pcall(fontString.GetText, fontString)
    if not ok or type(text) ~= "string" or not Accessible(text) then return nil end
    local trimmed
    local okTrim, value = pcall(string.match, text, "^%s*(.-)%s*$")
    if okTrim then trimmed = value end
    if type(trimmed) ~= "string" or trimmed == "" then return nil end
    -- 自己的列表会显示「自己的列表」，没必要再跟在区域后面
    if LFG_SELF_LISTING ~= nil and trimmed == LFG_SELF_LISTING then return nil end
    return trimmed
end

local function EnsureTag(row)
    local tag = row.LFGWhereTag
    if not tag then
        tag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tag:SetJustifyH("LEFT")
        tag:SetWordWrap(false)
        row.LFGWhereTag = tag
    end
    -- 跟在第二行（副本/活动名）后面
    local anchor = row.ActivityName or row
    tag:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    return tag
end

local function UpdateRow(row)
    local area, numMembers, dungeonZones = LeaderArea(RowResultID(row))
    local tag = row.LFGWhereTag
    if not area then
        if tag then tag:Hide() end
        row.LFGWhereText = nil
        return
    end
    tag = EnsureTag(row)
    local text = (numMembers and numMembers > 1 and LABEL or "") .. area
    if row.LFGWhereText ~= text then
        row.LFGWhereText = text
        tag:SetText(text)
    end
    -- 绿色表示队长/玩家就在副本所在地（地图链 / 副本名 / 内置对照表任一命中）
    local same = SameAsDungeon(area, RowActivityName(row), dungeonZones)
    local color = same and SAME_COLOR or OTHER_COLOR
    tag:SetTextColor(color[1], color[2], color[3])
    tag:Show()
end

-- ---------------------------------------------------------------------------
-- 定位列表行
-- 不同客户端版本的滚动列表实现不一样：有的把行挂在 ScrollTarget 下，
-- 有的要通过 GetFrames/EnumerateFrames 取，所以逐级尝试，最后再递归兜底。
-- ---------------------------------------------------------------------------
local function SafeChildren(frame)
    if type(frame) ~= "table" then return nil end
    local ok, children = pcall(frame.GetChildren, frame)
    if ok and type(children) == "table" then return children end
    return nil
end

local function RowsFromEnumerate(scrollBox)
    if type(scrollBox.EnumerateFrames) ~= "function" then return nil end
    local ok, iterator, state, initial = pcall(scrollBox.EnumerateFrames, scrollBox)
    if not ok or type(iterator) ~= "function" then return nil end
    local rows = {}
    for _, frame in iterator, state, initial do
        if type(frame) == "table" then rows[#rows + 1] = frame end
    end
    return rows
end

-- 从容器里递归找带 resultID 的帧（最多 4 层）
local function CollectRows(container, rows, seen, depth)
    if depth > 4 then return end
    local children = SafeChildren(container)
    if not children then return end
    for _, child in ipairs(children) do
        if type(child) == "table" and not seen[child] then
            seen[child] = true
            local ok, resultID = pcall(function() return child.resultID end)
            if ok and resultID ~= nil then
                rows[#rows + 1] = child
            else
                CollectRows(child, rows, seen, depth + 1)
            end
        end
    end
end

local function GetScrollBox()
    local scrollBox = _G.LFGBrowseFrameScrollBox
    if scrollBox then return scrollBox end
    local frame = _G.LFGBrowseFrame
    return frame and frame.ScrollBox
end

local function GetRows()
    local scrollBox = GetScrollBox()
    if not scrollBox then return nil end

    -- 1. 滚动框自己的活动行列表
    if type(scrollBox.GetFrames) == "function" then
        local ok, frames = pcall(scrollBox.GetFrames, scrollBox)
        if ok and type(frames) == "table" and #frames > 0 then return frames end
    end

    -- 2. 官方枚举接口
    local enumerated = RowsFromEnumerate(scrollBox)
    if enumerated and #enumerated > 0 then return enumerated end

    -- 3. ScrollTarget 的直接子对象
    local children = SafeChildren(scrollBox.ScrollTarget)
    if children and #children > 0 then return children end

    -- 4. 递归找带 resultID 的帧
    local rows, seen = {}, {}
    CollectRows(scrollBox, rows, seen, 0)
    return rows
end

local function HideAllTags()
    local rows = GetRows()
    if not rows then return end
    for _, row in ipairs(rows) do
        if row.LFGWhereTag then row.LFGWhereTag:Hide() end
    end
end

-- 同时写到聊天框和调试控制台（控制台里可以整段复制）
local function Report(message, detail)
    print("|cff66ccffLeatrixPlusExt|r " .. message)
    if type(NS.AppendDebugLine) == "function" then
        local line = "[组队位置] " .. message
        if detail then line = line .. "：" .. detail end
        pcall(NS.AppendDebugLine, line)
    end
end

-- ---------------------------------------------------------------------------
-- 事件驱动
-- 暴雪每次绑定/刷新列表行都会调用全局 LFGBrowseSearchEntry_Update，
-- 钩住它就能在行出现、刷新、复用的同一帧更新标签，不再定时轮询。
-- 该函数属于懒加载的 Blizzard_GroupFinder，所以要等它加载后再挂钩子。
-- ---------------------------------------------------------------------------
local lastRowError
local events, hooked, frameHooked
local HookBrowseFrame

local function RefreshRow(row)
    if not IsEnabled() or type(row) ~= "table" then return end
    local ok, err = pcall(UpdateRow, row)
    if not ok and err ~= lastRowError then
        lastRowError = err
        Report("组队列表刷新失败，请 /reload 后重试。", tostring(err))
    end
    -- 行都出现了，说明面板也已存在，顺手把 OnShow 补上
    if not frameHooked then HookBrowseFrame() end
end

-- 全量刷新当前可见行（面板打开、区域变化、开关切换时用）
local function RefreshAll()
    if not IsEnabled() then return end
    local frame = _G.LFGBrowseFrame
    if not frame or not frame:IsShown() then return end
    local rows = GetRows() or {}
    for _, row in ipairs(rows) do
        local ok, err = pcall(UpdateRow, row)
        if not ok and err ~= lastRowError then
            lastRowError = err
            Report("组队列表刷新失败，请 /reload 后重试。", tostring(err))
        end
    end
end

local function OnBrowseShow()
    RefreshAll()
    -- 面板刚打开时行可能还没渲染完，稍后再补一次
    if type(C_Timer) == "table" and C_Timer.After then
        C_Timer.After(1, RefreshAll)
    end
end

function HookBrowseFrame()
    if frameHooked then return end
    local frame = _G.LFGBrowseFrame
    if not frame then return end
    local ok = pcall(frame.HookScript, frame, "OnShow", OnBrowseShow)
    frameHooked = ok and true or false
end

local function TryHook(name)
    if type(_G[name]) ~= "function" then return false end
    local ok = pcall(hooksecurefunc, name, RefreshRow)
    return ok and true or false
end

local function EnsureHooked()
    if not hooked then
        -- Update 是行绑定和刷新的统一入口；Init 再补一个触发点
        local installed = TryHook("LFGBrowseSearchEntry_Update")
        if TryHook("LFGBrowseSearchEntry_Init") then installed = true end
        hooked = installed
        if hooked then RefreshAll() end
    end
    HookBrowseFrame()
end

local function EnsureEvents()
    if events then return events end
    events = CreateFrame("Frame")
    events:RegisterEvent("ADDON_LOADED")
    events:SetScript("OnEvent", EnsureHooked)
    EnsureHooked()
    return events
end

-- ---------------------------------------------------------------------------
-- 诊断：/lpext diag lfg（需要先打开「寻求组队」的浏览页）
-- ---------------------------------------------------------------------------
local function TryCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function DescribeValue(value)
    if value == nil then return "nil" end
    if not Accessible(value) then return "机密值" end
    return type(value) .. "：" .. tostring(value)
end

-- 诊断用：安全读表字段
local function Field(value, key)
    if type(value) ~= "table" or not Accessible(value) then return nil end
    local ok, result = pcall(function() return value[key] end)
    if ok and result ~= nil and Accessible(result) then return result end
    return nil
end

-- 诊断用：这条结果最终会被当成「副本所在地」的区域名（地图链 + 内置对照表）
local function DungeonZoneNames(resultID)
    if not resultID or not C_LFGList or not C_LFGList.GetSearchResultInfo then
        return nil
    end
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not ok or type(info) ~= "table" then return nil end
    local zones = DungeonZonesFromInfo(info) or {}
    local activityIDs = Field(info, "activityIDs")
    if type(activityIDs) == "table" and type(C_LFGList.GetActivityInfoTable) == "function" then
        for _, activityID in ipairs(activityIDs) do
            local okActivity, activity = pcall(C_LFGList.GetActivityInfoTable, activityID)
            if okActivity and type(activity) == "table" then
                local name = Field(activity, "name") or Field(activity, "shortName")
                local known = KnownDungeonZones(name)
                if known then
                    for zone in pairs(known) do zones[zone] = true end
                end
            end
        end
    end
    local names = {}
    for name in pairs(zones) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil end
    return names
end

-- 诊断用：把活动的地图链整条打出来，带上地图类型
local function ChainText(mapID)
    if type(mapID) ~= "number" then return "无 mapID" end
    local parts = {}
    local depth = 0
    while mapID ~= nil and mapID > 0 and depth < 8 do
        local entry = MapChainEntry(mapID)
        if entry == nil or entry == false then
            parts[#parts + 1] = tostring(mapID) .. "（无地图数据）"
            break
        end
        parts[#parts + 1] = ("%s[类型=%s]"):format(tostring(entry.name), tostring(entry.mapType))
        mapID = entry.parent
        depth = depth + 1
    end
    if #parts == 0 then return "空" end
    return table.concat(parts, " > ")
end

-- 诊断用：这条结果的每个活动 ID、名称、mapID 和地图链
local function DungeonDetailText(resultID)
    if not resultID or not C_LFGList or not C_LFGList.GetSearchResultInfo then
        return "无"
    end
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not ok or type(info) ~= "table" then return "读不到搜索结果" end
    local activityIDs = Field(info, "activityIDs")
    if type(activityIDs) ~= "table" then return "无 activityIDs" end
    if type(C_LFGList.GetActivityInfoTable) ~= "function" then
        return "无 GetActivityInfoTable"
    end
    local parts = {}
    for _, activityID in ipairs(activityIDs) do
        local okActivity, activity = pcall(C_LFGList.GetActivityInfoTable, activityID)
        if not okActivity or type(activity) ~= "table" then
            parts[#parts + 1] = tostring(activityID) .. "/读取失败"
        else
            local name = Field(activity, "name") or Field(activity, "shortName") or "?"
            local mapID = Field(activity, "mapID")
            parts[#parts + 1] = ("%s「%s」mapID=%s：%s"):format(
                tostring(activityID), tostring(name), tostring(mapID), ChainText(mapID))
        end
    end
    if #parts == 0 then return "空" end
    return table.concat(parts, "；")
end

-- 诊断：/lpext diag lfgacts，列出全部组队活动，标注哪些还没进对照表
local function LFGActivityName(activityID)
    if type(C_LFGList.GetActivityInfoTable) ~= "function" then return "?" end
    local ok, activity = pcall(C_LFGList.GetActivityInfoTable, activityID)
    if not ok or type(activity) ~= "table" then return "?" end
    return Field(activity, "shortName") or Field(activity, "fullName")
        or Field(activity, "name") or "?"
end

function NS.ListLFGActivities()
    local lines = {}
    local function Add(line) lines[#lines + 1] = line end
    Add("寻求组队活动列表（用于核对副本名称）：")
    if not (C_LFGList and C_LFGList.GetAvailableActivities) then
        Add("  当前客户端没有 GetAvailableActivities 接口。")
        return lines
    end

    local seen = {}
    local total = 0
    local function AddActivities(categoryID)
        local okActs, activities = pcall(C_LFGList.GetAvailableActivities, categoryID)
        if not okActs or type(activities) ~= "table" then return end
        local entries = {}
        for _, activityID in ipairs(activities) do
            if not seen[activityID] then
                seen[activityID] = true
                local name = LFGActivityName(activityID)
                local known = KnownDungeonZones(name) ~= nil
                entries[#entries + 1] = ("    %s %s（活动ID=%s）"):format(
                    known and "已收录" or "未收录", tostring(name), tostring(activityID))
                total = total + 1
            end
        end
        if #entries == 0 then return end
        table.sort(entries)
        for _, entry in ipairs(entries) do Add(entry) end
    end

    local okCats, categories = pcall(C_LFGList.GetAvailableCategories)
    if okCats and type(categories) == "table" and #categories > 0 then
        for _, categoryID in ipairs(categories) do
            local categoryName
            if type(C_LFGList.GetLfgCategoryInfo) == "function" then
                local okCat, category = pcall(C_LFGList.GetLfgCategoryInfo, categoryID)
                if okCat and type(category) == "table" then
                    categoryName = Field(category, "name")
                end
            end
            Add("  " .. tostring(categoryName or ("分类 " .. tostring(categoryID))))
            AddActivities(categoryID)
        end
    else
        Add("  （没有分类信息，直接列出全部）")
        AddActivities(nil)
    end
    Add(("  共 %d 个活动。"):format(total))
    return lines
end

function NS.DiagnoseLFGWhere()
    local lines = {}
    local function Add(line) lines[#lines + 1] = line end
    local function Num(value)
        if type(value) == "number" then return string.format("%.0f", value) end
        return tostring(value)
    end

    Add("组队位置诊断（打开寻求组队浏览页后运行）：")
    Add("  模块开关：" .. (IsEnabled() and "开" or "关")
        .. "，DB.lfgWhere=" .. tostring(DB.lfgWhere))
    Add("  数据接口：C_Map.GetMapInfo=" .. tostring(C_Map ~= nil and type(C_Map.GetMapInfo) == "function")
        .. "，GetActivityInfoTable="
        .. tostring(C_LFGList ~= nil and type(C_LFGList.GetActivityInfoTable) == "function"))

    local frame = _G.LFGBrowseFrame
    if not frame then
        Add("  找不到 LFGBrowseFrame：寻求组队面板还没加载。")
        return lines
    end
    local forbidden = TryCall(frame.IsForbidden, frame)
    Add("  LFGBrowseFrame：显示=" .. tostring(TryCall(frame.IsShown, frame))
        .. "，可见=" .. tostring(TryCall(frame.IsVisible, frame))
        .. "，禁止对象=" .. tostring(forbidden))

    local globalsBox = _G.LFGBrowseFrameScrollBox
    local fieldBox = frame.ScrollBox
    Add("  滚动框：全局=" .. tostring(globalsBox ~= nil)
        .. "，frame.ScrollBox=" .. tostring(fieldBox ~= nil)
        .. "，同一个=" .. tostring(globalsBox ~= nil and globalsBox == fieldBox))
    local scrollBox = GetScrollBox()
    local target = scrollBox and scrollBox.ScrollTarget
    Add("  ScrollTarget=" .. tostring(target ~= nil))

    -- 各取行方式的数量，用来判断行到底挂在哪里
    local direct = target and SafeChildren(target)
    local enumerated = scrollBox and RowsFromEnumerate(scrollBox)
    local got = GetRows() or {}
    local full = nil
    if scrollBox and type(scrollBox.GetFrames) == "function" then
        local okFrames, frames = pcall(scrollBox.GetFrames, scrollBox)
        if okFrames and type(frames) == "table" then full = frames end
    end
    Add(("  取行：GetFrames=%s，EnumerateFrames=%s，ScrollTarget子对象=%s，GetRows=%d"):format(
        full and tostring(#full) or "无接口",
        enumerated and tostring(#enumerated) or "无接口",
        direct and tostring(#direct) or "调用失败",
        #got))

    -- 数据端有没有结果：API 有数据但 UI 没行，说明卡在列表渲染
    if C_LFGList then
        local results = TryCall(C_LFGList.GetSearchResults)
        local filtered = TryCall(C_LFGList.GetFilteredSearchResults)
        Add("  搜索结果：" .. tostring(type(results) == "table" and #results or "无")
            .. "，过滤后：" .. tostring(type(filtered) == "table" and #filtered or "无"))
    end

    -- 三个子页的显示状态，确认看的是不是「浏览」页
    local listing = _G.LFGListingFrame
    local browse = _G.LFGBrowseFrame
    local who = _G.LFGWhoListFrame
    Add("  子页：列表=" .. tostring(listing and TryCall(listing.IsShown, listing))
        .. "，浏览=" .. tostring(browse and TryCall(browse.IsShown, browse))
        .. "，玩家=" .. tostring(who and TryCall(who.IsShown, who)))

    if #got == 0 then
        Add("  没有找到任何列表行。")
        return lines
    end
    local rows = got
    Add("  行数：" .. #rows)

    local okZones, zones = pcall(PlayerZones)
    if not okZones or type(zones) ~= "table" then zones = {} end
    local zoneNames = {}
    for zone in pairs(zones) do zoneNames[#zoneNames + 1] = zone end
    Add("  玩家所在地：" .. (#zoneNames > 0 and table.concat(zoneNames, "、") or "（读不到）"))

    local withID, withArea, withTag = 0, 0, 0
    for index, row in ipairs(rows) do
        local id = RowResultID(row)
        if id ~= nil then withID = withID + 1 end
        local area = id ~= nil and LeaderArea(id) or nil
        if area then withArea = withArea + 1 end
        if row.LFGWhereTag then withTag = withTag + 1 end
        if index <= 5 then
            local dungeonZones = DungeonZoneNames(id)
            Add(("  行%d：类型=%s，禁止对象=%s，resultID=%s，区域=%s，活动=%s，副本所在地=%s，标签=%s"):format(
                index,
                tostring(TryCall(row.GetObjectType, row) or "?"),
                tostring(row.IsForbidden and TryCall(row.IsForbidden, row)),
                DescribeValue(id),
                tostring(area),
                tostring(RowActivityName(row)),
                dungeonZones and table.concat(dungeonZones, "/") or "（读不到）",
                row.LFGWhereTag and "有" or "无"))
            Add("    活动详情：" .. DungeonDetailText(id))
        end
    end
    Add(("  汇总：行=%d，有 resultID=%d，读到区域=%d，已有标签=%d")
        :format(#rows, withID, withArea, withTag))

    -- 几何信息：标签有没有落在列表可见范围内
    local sample
    for _, row in ipairs(rows) do
        if row.LFGWhereTag and TryCall(row.LFGWhereTag.IsShown, row.LFGWhereTag) then
            sample = row
            break
        end
    end
    if sample then
        local tag = sample.LFGWhereTag
        Add(("  标签几何：行左=%s，行右=%s，行宽=%s，滚动框左=%s，滚动框右=%s，面板右=%s，标签左=%s，标签右=%s，标签宽=%s")
            :format(
                Num(TryCall(sample.GetLeft, sample)),
                Num(TryCall(sample.GetRight, sample)),
                Num(TryCall(sample.GetWidth, sample)),
                Num(scrollBox and TryCall(scrollBox.GetLeft, scrollBox)),
                Num(scrollBox and TryCall(scrollBox.GetRight, scrollBox)),
                Num(TryCall(frame.GetRight, frame)),
                Num(TryCall(tag.GetLeft, tag)),
                Num(TryCall(tag.GetRight, tag)),
                Num(TryCall(tag.GetStringWidth, tag))))
    end
    return lines
end

NS.RegisterModule({
    key = "lfgWhere",
    section = "组队",
    label = "寻求组队显示玩家区域",
    tip = "在「寻求组队」列表的副本名称后显示队伍/玩家所在区域；"
        .. "已在副本所在地时显示为绿色，否则为金色。",
    default = DEFAULT,
    onToggle = function(enabled)
        EnsureEvents()
        if enabled then
            RefreshAll()
        else
            HideAllTags()
        end
    end,
})

EnsureEvents()
