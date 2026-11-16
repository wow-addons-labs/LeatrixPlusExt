-- LeatrixPlusExt 模块：寻找组队筛选
-- 在「寻求组队」浏览页上加三个筛选维度：
--   玩家区域：区域不限 / 只看副本附近（队长或玩家已在副本所在地）
--   玩家职责：队伍只留还缺所选职责的，单人玩家只留勾选了所选职责的（多选时满足任一即可）
--   玩家职业：勾选后不显示已含该职业的队伍（多选，默认勾选本职业）
-- 过滤方式是重写数据源的 GetLinearized，列表布局、滚动和行回收仍走暴雪自己的逻辑。
local addonName, NS = ...

local DB = NS.DB

local DEFAULT = true
local AREA_ANY = "any"
local AREA_DUNGEON = "dungeon"

local ROLE_OPTIONS = {
    { key = "TANK", text = "坦克", short = "坦" },
    { key = "HEALER", text = "治疗", short = "治" },
    { key = "DAMAGER", text = "输出", short = "DPS" },
}

-- 职业列表：优先用客户端提供的本地化职业信息，取英文职业标识做键
local function ClassInfo(classID)
    if C_CreatureInfo and type(C_CreatureInfo.GetClassInfo) == "function" then
        local ok, info = pcall(C_CreatureInfo.GetClassInfo, classID)
        if ok and type(info) == "table" and info.className and info.classFile then
            return info
        end
    end
    if type(GetClassInfo) == "function" then
        local ok, name, file = pcall(GetClassInfo, classID)
        if ok and name and file then
            return { className = name, classFile = file }
        end
    end
    return nil
end

local CLASS_OPTIONS = {}
do
    for classID = 1, 13 do
        local info = ClassInfo(classID)
        if info then
            CLASS_OPTIONS[#CLASS_OPTIONS + 1] = {
                file = info.classFile,
                name = info.className,
            }
        end
    end
end

local function IsEnabled()
    local value = DB.lfgFilter
    if value == nil then return DEFAULT end
    return value and true or false
end

-- ---------------------------------------------------------------------------
-- 筛选状态：区域全局保存，职责/职业按角色保存
-- ---------------------------------------------------------------------------
local function PlayerKey()
    local name = UnitName("player")
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    if name and realm then return realm .. "-" .. name end
    return name or "player"
end

local function RoleSet()
    if type(DB.lfgFilterRoles) ~= "table" then DB.lfgFilterRoles = {} end
    local key = PlayerKey()
    local set = DB.lfgFilterRoles[key]
    if type(set) ~= "table" then
        set = {}
        DB.lfgFilterRoles[key] = set
    end
    return set
end

-- 第一次使用某个角色时，默认勾选本职业（勾选 = 不显示含该职业的队伍）
local function ClassSet()
    if type(DB.lfgFilterClasses) ~= "table" then DB.lfgFilterClasses = {} end
    local key = PlayerKey()
    local set = DB.lfgFilterClasses[key]
    if type(set) ~= "table" then
        set = {}
        local _, classFile = UnitClass("player")
        if classFile then set[classFile] = true end
        DB.lfgFilterClasses[key] = set
    end
    return set
end

local function AreaDungeonOnly()
    return DB.lfgFilterArea == AREA_DUNGEON
end

local function RoleFilterActive()
    local set = RoleSet()
    for _, option in ipairs(ROLE_OPTIONS) do
        if set[option.key] then return true end
    end
    return false
end

local function ClassFilterActive()
    local set = ClassSet()
    for _, option in ipairs(CLASS_OPTIONS) do
        if set[option.file] then return true end
    end
    return false
end

local function FiltersActive()
    return AreaDungeonOnly() or RoleFilterActive() or ClassFilterActive()
end

-- ---------------------------------------------------------------------------
-- 数据缓存：每条搜索结果的位置、类型（队伍/单人）、空缺职责、玩家职责、职业构成
-- ---------------------------------------------------------------------------
local dungeonCache = {}
local roleCache = {}
local classCache = {}
local cacheReady = false        -- 缓存没建好时先不过滤，避免把列表清空

local function SafeNumber(value)
    if type(value) ~= "number" then return 0 end
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if not ok or not allowed then return 0 end
    end
    return value
end

-- 机密值（聊天锁定等）读不了就当作没有；接口本身报错时按可读处理
local function Accessible(value)
    if type(canaccessvalue) ~= "function" then return true end
    local ok, result = pcall(canaccessvalue, value)
    if not ok then return true end
    return result and true or false
end

-- 单人玩家列表：客户端浏览页自己也是按 numMembers == 1 判断的
-- （见 LFGBrowseSearchEntry_Update 的 isSolo，单人时显示职业图标和玩家职责图标）
local function IsSoloResult(resultID)
    if type(C_LFGList.GetSearchResultInfo) ~= "function" then return false end
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not ok or type(info) ~= "table" then return false end
    local okNum, num = pcall(function() return info.numMembers end)
    if not okNum then return false end
    return SafeNumber(num) == 1
end

-- LFGRoles 的字段名和我们的职责键不同：tank / healer / dps
local ROLE_FIELDS = {
    TANK = "tank",
    HEALER = "healer",
    DAMAGER = "dps",
}

-- 单人玩家自己勾选的职责（LFGRoles）；读不到时退回队长分配职责
local function SoloRoles(resultID)
    local roles = {}
    if type(C_LFGList.GetSearchResultPlayerInfo) ~= "function" then return roles end
    local ok, info = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, 1)
    if not ok or type(info) ~= "table" then return roles end

    local okRoles, lfgRoles = pcall(function() return info.lfgRoles end)
    if okRoles and type(lfgRoles) == "table" and Accessible(lfgRoles) then
        for key, field in pairs(ROLE_FIELDS) do
            local okValue, value = pcall(function() return lfgRoles[field] end)
            if okValue and value ~= nil and Accessible(value) then
                local okTrue, isTrue = pcall(function() return value == true end)
                if okTrue and isTrue then roles[key] = true end
            end
        end
    end

    if next(roles) == nil then
        local okRole, assigned = pcall(function() return info.assignedRole end)
        if okRole and Accessible(assigned) then
            if assigned == "TANK" or assigned == "HEALER" or assigned == "DAMAGER" then
                roles[assigned] = true
            end
        end
    end
    return roles
end

-- 单人玩家的职业：客户端在单人行上显示的职业图标就取自这里的 classFilename
local function SoloClass(resultID)
    if type(C_LFGList.GetSearchResultPlayerInfo) ~= "function" then return nil end
    local ok, info = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, 1)
    if not ok or type(info) ~= "table" then return nil end
    local okClass, classFile = pcall(function() return info.classFilename end)
    if not okClass or type(classFile) ~= "string"
        or classFile == "" or not Accessible(classFile) then
        return nil
    end
    for _, option in ipairs(CLASS_OPTIONS) do
        if option.file == classFile then return classFile end
    end
    return nil
end

local function MemberCounts(resultID)
    if not resultID or not C_LFGList
        or type(C_LFGList.GetSearchResultMemberCounts) ~= "function" then
        return nil, nil
    end
    local ok, counts = pcall(C_LFGList.GetSearchResultMemberCounts, resultID)
    if not ok or type(counts) ~= "table" then return nil, nil end

    local roles = {
        TANK = SafeNumber(counts.TANK_REMAINING),
        HEALER = SafeNumber(counts.HEALER_REMAINING),
        DAMAGER = SafeNumber(counts.DAMAGER_REMAINING),
    }
    -- 队伍里出现的职业（队长和队员都算在这个统计里）
    local classes = {}
    for _, option in ipairs(CLASS_OPTIONS) do
        if SafeNumber(counts[option.file]) > 0 then
            classes[option.file] = true
        end
    end
    return roles, classes
end

local function RefreshCache(provider)
    dungeonCache, roleCache, classCache = {}, {}, {}
    cacheReady = false
    if not provider or not provider.LFGFilterBaseGetLinearized then return end
    local nodes = provider.LFGFilterBaseGetLinearized(provider)
    for i = 1, #nodes do
        local data = nodes[i].data
        local resultID = data and data.resultID
        if resultID then
            local atDungeon = false
            if type(NS.GetLeaderInfo) == "function" then
                local _, _, flag = NS.GetLeaderInfo(resultID)
                atDungeon = flag and true or false
            end
            dungeonCache[resultID] = atDungeon
            local remaining, classes = MemberCounts(resultID)
            local solo = IsSoloResult(resultID)
            if solo then
                -- 单人玩家按玩家自己的职业算（成员计数里不一定带单人职业）
                local soloClass = SoloClass(resultID)
                if soloClass then
                    classes = { [soloClass] = true }
                elseif classes and next(classes) == nil then
                    classes = nil     -- 两种来源都读不到：按不满足处理
                end
            end
            roleCache[resultID] = {
                solo = solo,
                remaining = remaining,
                roles = solo and SoloRoles(resultID) or nil,
            }
            classCache[resultID] = classes
        end
    end
    cacheReady = true
end

local function PassesArea(resultID)
    if not AreaDungeonOnly() then return true end
    return dungeonCache[resultID] == true
end

-- 玩家职责：
--   多人队伍：只留还缺所选职责的队伍，勾选多个时缺任一即可（或）；
--   单人玩家：只留勾选了所选职责的玩家，勾选多个时满足任一即可（或）。
-- 读不到数据时按不满足处理，避免把未知内容混进筛选结果。
local function PassesRoles(resultID)
    if not RoleFilterActive() then return true end
    local info = roleCache[resultID]
    if not info then return false end
    local set = RoleSet()

    if info.solo then
        local roles = info.roles
        if not roles then return false end
        for _, option in ipairs(ROLE_OPTIONS) do
            if set[option.key] and roles[option.key] then
                return true
            end
        end
        return false
    end

    local remaining = info.remaining
    if not remaining then return false end
    for _, option in ipairs(ROLE_OPTIONS) do
        if set[option.key] and (remaining[option.key] or 0) > 0 then
            return true
        end
    end
    return false
end

-- 勾选的职业表示「不想看到」：队伍或单人玩家出现任意一个就不显示
local function PassesClasses(resultID)
    if not ClassFilterActive() then return true end
    local classes = classCache[resultID]
    if not classes then return false end           -- 读不到职业构成：按不满足处理
    local set = ClassSet()
    for _, option in ipairs(CLASS_OPTIONS) do
        if set[option.file] and classes[option.file] then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 数据源：重写 GetLinearized 做过滤，标题/分隔行始终保留
-- ---------------------------------------------------------------------------
local state = {
    provider = nil,
    frameHooked = false,
    events = nil,
    areaDropdown = nil,
    roleDropdown = nil,
    classDropdown = nil,
    refreshPending = false,
}

local function InstallProvider(provider)
    if not provider or provider.LFGFilterBaseGetLinearized then return end
    local base = provider.GetLinearized
    if type(base) ~= "function" then return end
    provider.LFGFilterBaseGetLinearized = base
    provider.GetLinearized = function(self)
        local nodes = self.LFGFilterBaseGetLinearized(self)
        if not FiltersActive() or not cacheReady then return nodes end
        local filtered = {}
        for i = 1, #nodes do
            local node = nodes[i]
            local data = node.data
            local resultID = data and data.resultID
            if not resultID or data.dividerType then
                filtered[#filtered + 1] = node
            elseif PassesArea(resultID) and PassesRoles(resultID)
                and PassesClasses(resultID) then
                filtered[#filtered + 1] = node
            end
        end
        return filtered
    end
end

local function UninstallProvider(target)
    local provider = target or state.provider
    if not provider or not provider.LFGFilterBaseGetLinearized then return end
    provider.GetLinearized = provider.LFGFilterBaseGetLinearized
    provider.LFGFilterBaseGetLinearized = nil
end

local function GetScrollBox()
    local frame = _G.LFGBrowseFrame
    return _G.LFGBrowseFrameScrollBox or (frame and frame.ScrollBox)
end

-- 过滤后列表长度变了，让滚动条重新量一次总高度
local function RefreshScrollBox()
    local scrollBox = GetScrollBox()
    if not scrollBox then return end
    -- 还没挂数据源时不用量（LayoutControls 在列表首次出现前也会调用）
    if scrollBox.GetDataProvider and not scrollBox:GetDataProvider() then return end
    if scrollBox.RecalculateDerivedExtent then
        scrollBox:RecalculateDerivedExtent()
    end
    if scrollBox.FullUpdate then
        scrollBox:FullUpdate(true)
    end
end

-- ---------------------------------------------------------------------------
-- 控件：全部直接使用原生 WowStyle1DropdownTemplate（与「类型 / 活动」下拉框同款），
-- 不遮原图集、不加自绘边框、不改字体，高度也跟原生一致
-- ---------------------------------------------------------------------------
local RefreshNow
local UpdateAreaDropdown
local UpdateRoleDropdown
local UpdateClassDropdown

local CONTROL_WIDTH_AREA = 118
local CONTROL_WIDTH_ROLE = 92
local CONTROL_WIDTH_CLASS = 92
local CONTROL_GAP = 5

local function AreaLabel()
    return AreaDungeonOnly() and "副本附近" or "区域不限"
end

-- 模板在菜单开关时会用「逗号拼接」改写选中文本，这里在它更新之后写回摘要
local function HookDropdownText(dropdown, update)
    if dropdown.LeatrixPlusExtTextHooked then return end
    local base = dropdown.UpdateToMenuSelections
    if type(base) ~= "function" then return end
    dropdown.LeatrixPlusExtTextHooked = true
    dropdown.UpdateToMenuSelections = function(self, ...)
        base(self, ...)
        update()
    end
end

local function ApplyDropdownText(dropdown, label)
    dropdown:SetDefaultText(label)
    -- 原生「活动」下拉框就是用 OverrideText 写标题的
    if dropdown.OverrideText then
        dropdown:OverrideText(label)
    end
end

local function CreateAreaDropdown()
    local frame = _G.LFGBrowseFrame
    if not frame then return nil end
    local dropdown = state.areaDropdown
    if not dropdown then
        dropdown = CreateFrame("DropdownButton", "LeatrixPlusExtLFGAreaDropdown", frame,
            "WowStyle1DropdownTemplate")
        state.areaDropdown = dropdown
    end
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 70, -72)
    dropdown:SetWidth(CONTROL_WIDTH_AREA)

    dropdown:SetupMenu(function(_, rootDescription)
        rootDescription:CreateRadio("区域不限", function()
            return not AreaDungeonOnly()
        end, function()
            DB.lfgFilterArea = AREA_ANY
            UpdateAreaDropdown()
            RefreshNow()
        end)
        rootDescription:CreateRadio("副本附近", function()
            return AreaDungeonOnly()
        end, function()
            DB.lfgFilterArea = AREA_DUNGEON
            UpdateAreaDropdown()
            RefreshNow()
        end)
    end)

    if not state.areaTooltipHooked then
        state.areaTooltipHooked = true
        dropdown:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("区域筛选")
            GameTooltip:AddLine("「副本附近」只显示位置在副本所在地的队伍或玩家", 1, 1, 1, true)
            GameTooltip:AddLine("当前：" .. AreaLabel(), 0.25, 0.94, 0.54)
            GameTooltip:Show()
        end)
        dropdown:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    UpdateAreaDropdown()
    return dropdown
end

UpdateAreaDropdown = function()
    local dropdown = state.areaDropdown
    if not dropdown then return end
    ApplyDropdownText(dropdown, AreaLabel())
end

local function RoleLabel()
    local set = RoleSet()
    local selected = {}
    for _, option in ipairs(ROLE_OPTIONS) do
        if set[option.key] then selected[#selected + 1] = option.short end
    end
    if #selected == 0 then return "职责不限" end
    return table.concat(selected, "/")
end

local function ClassLabel()
    local set = ClassSet()
    local names = {}
    for _, option in ipairs(CLASS_OPTIONS) do
        if set[option.file] then names[#names + 1] = option.name end
    end
    if #names == 0 then return "所有职业" end
    if #names == 1 then return "不含" .. names[1] end
    return "不含" .. #names .. "个"
end

UpdateRoleDropdown = function()
    local dropdown = state.roleDropdown
    if not dropdown then return end
    ApplyDropdownText(dropdown, RoleLabel())
end

UpdateClassDropdown = function()
    local dropdown = state.classDropdown
    if not dropdown then return end
    ApplyDropdownText(dropdown, ClassLabel())
end

local function CreateRoleDropdown()
    local frame = _G.LFGBrowseFrame
    if not frame then return nil end
    local dropdown = state.roleDropdown
    if not dropdown then
        dropdown = CreateFrame("DropdownButton", "LeatrixPlusExtLFGRoleDropdown", frame,
            "WowStyle1DropdownTemplate")
        state.roleDropdown = dropdown
    end
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT",
        70 + CONTROL_WIDTH_AREA + CONTROL_GAP, -72)
    dropdown:SetWidth(CONTROL_WIDTH_ROLE)
    HookDropdownText(dropdown, UpdateRoleDropdown)

    dropdown:SetupMenu(function(_, rootDescription)
        for _, option in ipairs(ROLE_OPTIONS) do
            rootDescription:CreateCheckbox(option.text, function()
                return RoleSet()[option.key] == true
            end, function()
                local set = RoleSet()
                if set[option.key] then
                    set[option.key] = nil
                else
                    set[option.key] = true
                end
                UpdateRoleDropdown()
                RefreshNow()
            end)
        end
    end)
    -- 用 HookScript，只挂一次（ShowControls 每次都会走到这里）
    if not state.roleTooltipHooked then
        state.roleTooltipHooked = true
        dropdown:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("职责筛选")
            GameTooltip:AddLine("队伍：只显示还缺所选职责的队伍", 1, 1, 1, true)
            GameTooltip:AddLine("玩家：只显示勾选了所选职责的玩家", 1, 1, 1, true)
            GameTooltip:AddLine("勾选多个时，满足任意一个即可", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("全部取消 = 职责不限", 0.7, 0.7, 0.7)
            if RoleFilterActive() then
                GameTooltip:AddLine("当前：" .. RoleLabel(), 0.25, 0.94, 0.54)
            else
                GameTooltip:AddLine("当前：不限", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        dropdown:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    UpdateRoleDropdown()
    return dropdown
end

local function CreateClassDropdown()
    local frame = _G.LFGBrowseFrame
    if not frame then return nil end
    local dropdown = state.classDropdown
    if not dropdown then
        dropdown = CreateFrame("DropdownButton", "LeatrixPlusExtLFGClassDropdown", frame,
            "WowStyle1DropdownTemplate")
        state.classDropdown = dropdown
    end
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT",
        70 + CONTROL_WIDTH_AREA + CONTROL_GAP + CONTROL_WIDTH_ROLE + CONTROL_GAP, -72)
    dropdown:SetWidth(CONTROL_WIDTH_CLASS)
    HookDropdownText(dropdown, UpdateClassDropdown)

    dropdown:SetupMenu(function(_, rootDescription)
        for _, option in ipairs(CLASS_OPTIONS) do
            rootDescription:CreateCheckbox(option.name, function()
                return ClassSet()[option.file] == true
            end, function()
                local set = ClassSet()
                if set[option.file] then
                    set[option.file] = nil
                else
                    set[option.file] = true
                end
                UpdateClassDropdown()
                RefreshNow()
            end)
        end
    end)
    if not state.classTooltipHooked then
        state.classTooltipHooked = true
        dropdown:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("职业筛选")
            GameTooltip:AddLine("勾选后隐藏已含该职业的队伍或玩家（队伍里任何成员都算；单人看自己的职业）", 1, 1, 1, true)
            GameTooltip:AddLine("全部取消 = 所有职业", 0.7, 0.7, 0.7)
            if ClassFilterActive() then
                GameTooltip:AddLine("当前：" .. ClassLabel(), 0.25, 0.94, 0.54)
            else
                GameTooltip:AddLine("当前：所有职业", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        dropdown:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    UpdateClassDropdown()
    return dropdown
end

-- ---------------------------------------------------------------------------
-- 内嵌布局：筛选排到原始顶部栏的第二行，列表区域整体下移腾出空间
-- 原始界面有两种样式：
--   现代样式有 BarTop/Inset，BackgroundArt 同时锚住上下边，移动上边即可整体下移；
--   经典样式只有 BackgroundArt + ScrollBox 的固定尺寸，需要同时改高度。
-- 记录原值，关闭模块时还原，避免反复进出时累积偏移。
-- ---------------------------------------------------------------------------
local ROW_HEIGHT = 32   -- 原生下拉框默认高度，实际以 CategoryDropdown 为准
local ROW_GAP_ABOVE = 6
local ROW_GAP_BELOW = 8
local MAX_SHIFT = 60

local layoutState = {
    recorded = false,
    art = nil,
    scroll = nil,
    shift = 0,
}

local function FirstTopPoint(region)
    local count = region.GetNumPoints and region:GetNumPoints() or 0
    for i = 1, count do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(i)
        if point == "TOPLEFT" or point == "TOP" then
            return point, relativeTo, relativePoint, x, y
        end
    end
    return nil
end

local function SetTopOffset(region, point, relativeTo, relativePoint, x, y)
    if relativeTo then
        region:SetPoint(point, relativeTo, relativePoint or point, x, y)
    else
        region:SetPoint(point, x, y)
    end
end

local function RecordLayout()
    if layoutState.recorded then return end
    layoutState.recorded = true
    local frame = _G.LFGBrowseFrame
    local art = frame and frame.BackgroundArt
    if art then
        local point, relativeTo, relativePoint, x, y = FirstTopPoint(art)
        if point then
            layoutState.art = {
                region = art,
                point = point,
                relativeTo = relativeTo,
                relativePoint = relativePoint,
                x = x,
                y = y,
                height = art:GetHeight(),
                hasBottom = (art.GetNumPoints and art:GetNumPoints() or 0) >= 2,
            }
        end
    end
    -- 现代样式的 ScrollBox 跟着 BackgroundArt 走，不用单独移动；
    -- 经典样式的 BackgroundArt 只有左上角锚点，ScrollBox 要自己挪
    local artHasBottom = layoutState.art and layoutState.art.hasBottom
    local scrollBox = GetScrollBox()
    if scrollBox and not artHasBottom then
        local point, relativeTo, relativePoint, x, y = FirstTopPoint(scrollBox)
        if point then
            layoutState.scroll = {
                region = scrollBox,
                point = point,
                relativeTo = relativeTo,
                relativePoint = relativePoint,
                x = x,
                y = y,
                height = scrollBox:GetHeight(),
            }
        end
    end
end

local function LayoutControls()
    local frame = _G.LFGBrowseFrame
    local category = frame and frame.CategoryDropdown
    if not category then return end

    local frameTop, frameLeft = frame:GetTop(), frame:GetLeft()
    local catBottom, catLeft = category:GetBottom(), category:GetLeft()
    if not (frameTop and frameLeft and catBottom and catLeft) then return end

    -- 第二行贴着原始两个筛选项的底边，左边与「类型」下拉框对齐
    local rowTop = (catBottom - frameTop) - ROW_GAP_ABOVE
    local left = catLeft - frameLeft
    if left < 0 then left = 0 end

    local roleLeft = left + CONTROL_WIDTH_AREA + CONTROL_GAP
    local classLeft = roleLeft + CONTROL_WIDTH_ROLE + CONTROL_GAP
    if rowTop ~= state.rowTop or left ~= state.rowLeft then
        state.rowTop, state.rowLeft = rowTop, left
        if state.areaDropdown then
            state.areaDropdown:ClearAllPoints()
            state.areaDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", left, rowTop)
        end
        if state.roleDropdown then
            state.roleDropdown:ClearAllPoints()
            state.roleDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", roleLeft, rowTop)
        end
        if state.classDropdown then
            state.classDropdown:ClearAllPoints()
            state.classDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", classLeft, rowTop)
        end
    end

    RecordLayout()
    -- 行高跟原生下拉框一致，换客户端样式时不用再调
    local rowHeight = category:GetHeight() or ROW_HEIGHT
    local artInfo = layoutState.art
    local scrollInfo = layoutState.scroll
    local targetTop = rowTop - rowHeight - ROW_GAP_BELOW
    local shift
    if artInfo then
        shift = artInfo.y - targetTop
    elseif scrollInfo then
        shift = scrollInfo.y - targetTop
    else
        return
    end
    if shift < 0 then shift = 0 end
    if shift > MAX_SHIFT then shift = MAX_SHIFT end
    if shift == layoutState.shift then return end
    layoutState.shift = shift

    if artInfo then
        SetTopOffset(artInfo.region, artInfo.point, artInfo.relativeTo,
            artInfo.relativePoint, artInfo.x, artInfo.y - shift)
        if not artInfo.hasBottom then
            artInfo.region:SetHeight(math.max(120, artInfo.height - shift))
        end
    end

    if scrollInfo then
        SetTopOffset(scrollInfo.region, scrollInfo.point, scrollInfo.relativeTo,
            scrollInfo.relativePoint, scrollInfo.x, scrollInfo.y - shift)
        scrollInfo.region:SetHeight(math.max(120, scrollInfo.height - shift))
    end

    -- 可视区变矮，滚动条要重新量一次
    RefreshScrollBox()
end

local function RestoreLayout()
    local artInfo = layoutState.art
    if artInfo then
        SetTopOffset(artInfo.region, artInfo.point, artInfo.relativeTo,
            artInfo.relativePoint, artInfo.x, artInfo.y)
        if not artInfo.hasBottom then
            artInfo.region:SetHeight(artInfo.height)
        end
    end
    local scrollInfo = layoutState.scroll
    if scrollInfo then
        SetTopOffset(scrollInfo.region, scrollInfo.point, scrollInfo.relativeTo,
            scrollInfo.relativePoint, scrollInfo.x, scrollInfo.y)
        scrollInfo.region:SetHeight(scrollInfo.height)
    end
    layoutState.recorded = false
    layoutState.art = nil
    layoutState.scroll = nil
    layoutState.shift = 0
    state.rowTop, state.rowLeft = nil, nil
end

local function ShowControls()
    CreateAreaDropdown()
    CreateRoleDropdown()
    CreateClassDropdown()
    if state.areaDropdown then state.areaDropdown:Show() end
    if state.roleDropdown then state.roleDropdown:Show() end
    if state.classDropdown then state.classDropdown:Show() end
    LayoutControls()
end

local function HideControls()
    if state.areaDropdown then state.areaDropdown:Hide() end
    if state.roleDropdown then state.roleDropdown:Hide() end
    if state.classDropdown then state.classDropdown:Hide() end
end

-- ---------------------------------------------------------------------------
-- 刷新：筛选变化、搜索结果更新、面板打开时重算缓存并让列表重排
-- ---------------------------------------------------------------------------
-- 当前能通过的队伍集合：集合没变就不重排，避免列表自己跳回顶部
local function ResultSignature()
    local ids = {}
    for resultID in pairs(dungeonCache) do
        if PassesArea(resultID) and PassesRoles(resultID)
            and PassesClasses(resultID) then
            ids[#ids + 1] = tostring(resultID)
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

RefreshNow = function()
    if not IsEnabled() then return end
    if not _G.LFGBrowseFrame then return end
    ShowControls()

    local scrollBox = GetScrollBox()
    local provider = scrollBox and scrollBox.GetDataProvider
        and scrollBox:GetDataProvider()
    if not provider then return end

    InstallProvider(provider)
    state.provider = provider

    local active = FiltersActive()
    local needsRefresh
    if active then
        RefreshCache(provider)
        local signature = ResultSignature()
        -- 换了数据源要重排（新数据源是未过滤的）；过滤结果变了也要重排
        needsRefresh = provider ~= state.filteredProvider
            or signature ~= state.resultSignature
        state.resultSignature = signature
    else
        -- 从「有筛选」切回「区域不限」时重排一次，恢复完整列表
        needsRefresh = state.lastActive == true
        state.resultSignature = nil
    end
    state.lastActive = active

    if needsRefresh then
        if active then state.filteredProvider = provider end
        if provider.Invalidate then provider:Invalidate() end
        RefreshScrollBox()
    end
end

local function ScheduleRefresh()
    if state.refreshPending then return end
    state.refreshPending = true
    local function run()
        state.refreshPending = false
        RefreshNow()
    end
    if type(C_Timer) == "table" and C_Timer.After then
        C_Timer.After(0.2, run)
    else
        run()
    end
end

local function HookBrowseFrame()
    local frame = _G.LFGBrowseFrame
    if not frame or state.frameHooked then return end
    -- 列表重建（打开面板、收到新结果）时数据源会换新的，装好过滤后立即重排
    local ok = pcall(hooksecurefunc, frame, "UpdateResults", RefreshNow)
    if ok then
        state.frameHooked = true
    elseif type(C_Timer) == "table" and C_Timer.After then
        -- UpdateResults 可能还没挂到 frame 上，稍后再试（最多 20 次）
        state.hookAttempts = (state.hookAttempts or 0) + 1
        if state.hookAttempts <= 20 then
            C_Timer.After(1, HookBrowseFrame)
        end
    end
    if not state.showHooked and type(frame.HookScript) == "function" then
        state.showHooked = pcall(frame.HookScript, frame, "OnShow", ScheduleRefresh) and true
    end
end

local function EnsureEvents()
    if state.events then return state.events end
    local events = CreateFrame("Frame")
    state.events = events
    events:RegisterEvent("ADDON_LOADED")
    events:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
    events:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
    events:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            HookBrowseFrame()
            local frame = _G.LFGBrowseFrame
            if IsEnabled() and frame and frame.IsVisible and frame:IsVisible() then
                ScheduleRefresh()
            end
            return
        end
        -- 搜索结果或队伍成员变化：稍后统一重算
        ScheduleRefresh()
    end)
    HookBrowseFrame()
    return events
end

-- 关闭模块：撤掉过滤，恢复完整列表
local function Disable()
    HideControls()
    RestoreLayout()
    cacheReady = false
    state.filteredProvider = nil
    state.resultSignature = nil
    state.lastActive = nil
    local scrollBox = GetScrollBox()
    local provider = scrollBox and scrollBox.GetDataProvider
        and scrollBox:GetDataProvider()
    if not provider then provider = state.provider end
    UninstallProvider(provider)
    state.provider = nil
    if provider and provider.Invalidate then provider:Invalidate() end
    RefreshScrollBox()
end

-- /lpext diag lfgfilter：布局与筛选状态诊断（先打开寻求组队的浏览页）
local function CountKeys(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function OffsetText(region, frame)
    if not region or not frame then return "无" end
    local top = region:GetTop()
    local bottom = region:GetBottom()
    local left = region:GetLeft()
    local frameTop = frame:GetTop()
    local frameLeft = frame:GetLeft()
    if not (top and bottom and left and frameTop and frameLeft) then
        return "无坐标"
    end
    return string.format("上=%.1f 下=%.1f 左=%.1f 宽=%s 高=%s",
        top - frameTop, bottom - frameTop, left - frameLeft,
        tostring(region:GetWidth()), tostring(region:GetHeight()))
end

function NS.DiagnoseLFGFilter()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add("寻找组队筛选诊断")
    add("模块开关=" .. (IsEnabled() and "开" or "关")
        .. " 区域=" .. (AreaDungeonOnly() and "副本附近" or "区域不限"))
    add("职责=" .. RoleLabel() .. " 职业=" .. ClassLabel())
    add("缓存就绪=" .. tostring(cacheReady)
        .. " 队伍=" .. CountKeys(dungeonCache)
        .. " 职责数据=" .. CountKeys(roleCache)
        .. " 职业数据=" .. CountKeys(classCache))

    local frame = _G.LFGBrowseFrame
    if not frame then
        add("LFGBrowseFrame=未加载（先打开寻求组队浏览页）")
        return lines
    end
    add("LFGBrowseFrame=" .. tostring(frame:GetWidth()) .. "x" .. tostring(frame:GetHeight())
        .. " 样式=" .. (frame.BarTop and "现代（有 BarTop）" or "经典（无 BarTop）"))
    add("CategoryDropdown: " .. OffsetText(frame.CategoryDropdown, frame))
    add("ActivityDropdown: " .. OffsetText(frame.ActivityDropdown, frame))
    add("BackgroundArt: " .. OffsetText(frame.BackgroundArt, frame))
    add("ScrollBox: " .. OffsetText(GetScrollBox(), frame))

    local art = frame.BackgroundArt
    if art and art.GetNumPoints then
        local points = {}
        for i = 1, art:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = art:GetPoint(i)
            points[#points + 1] = string.format("%s(%s,%s)", tostring(point),
                tostring(x), tostring(y))
        end
        add("BackgroundArt 锚点=" .. table.concat(points, " ")
            .. " 锚点数=" .. art:GetNumPoints())
    end
    add("布局位移=" .. tostring(layoutState.shift)
        .. " 第二行上沿=" .. tostring(state.rowTop)
        .. " 左沿=" .. tostring(state.rowLeft))
    add("区域下拉: " .. OffsetText(state.areaDropdown, frame))
    add("职责下拉: " .. OffsetText(state.roleDropdown, frame))
    add("职业下拉: " .. OffsetText(state.classDropdown, frame))
    return lines
end

NS.RegisterModule({
    key = "lfgFilter",
    section = "组队",
    label = "寻找组队筛选",
    tip = "在「寻求组队」浏览页顶部加一行筛选，三个条件同时生效：\n"
        .. "· 区域：只看已在副本所在地的队伍/玩家；\n"
        .. "· 职责：队伍只显示还缺所选职责的，单人玩家只显示勾选了所选职责的；\n"
        .. "· 职业：隐藏已包含所选职业的队伍/玩家，默认勾选本职业。",
    default = DEFAULT,
    -- /lpext reset 使用：当前角色回到默认筛选（区域不限、职责不限、只勾本职业）
    reset = function()
        DB.lfgFilterArea = AREA_ANY
        local roles = RoleSet()
        for key in pairs(roles) do roles[key] = nil end
        local classes = ClassSet()
        for key in pairs(classes) do classes[key] = nil end
        local _, classFile = UnitClass("player")
        if classFile then classes[classFile] = true end
        UpdateAreaDropdown()
        UpdateRoleDropdown()
        UpdateClassDropdown()
        RefreshNow()
    end,
    onToggle = function(enabled)
        if enabled then
            EnsureEvents()
            ShowControls()
            RefreshNow()
        else
            Disable()
        end
    end,
})

EnsureEvents()
