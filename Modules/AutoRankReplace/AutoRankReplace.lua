-- LeatrixPlusExt 模块：学会新等级后自动替换动作条上的低级技能
-- 自动替换只处理刚学会的那个法术；设置页可以扫描当前动作条、维护排除名单或批量替换。
local addonName, NS = ...

local DB = NS.DB
local Utils = NS.Utils

local DEFAULT = true
local ROW_HEIGHT = 20
local LEFT_WIDTH = 360
local RIGHT_X = 370
local CONTENT_WIDTH = 538
local LEFT_CHILD_WIDTH = 324
local RIGHT_CHILD_WIDTH = 132
local SCAN_DELAY = 0.2
local CURSOR_RETRY = 1

local BAR_SHORT = {
    [1] = "主条",
    [2] = "第2页",
    [3] = "右条",
    [4] = "左条",
    [5] = "右下",
    [6] = "左下",
}
local BAR_FULL = {
    [1] = "主动作条",
    [2] = "第2页",
    [3] = "右侧动作条",
    [4] = "左侧动作条",
    [5] = "右下动作条",
    [6] = "左下动作条",
}

-- ---------------------------------------------------------------------------
-- 安全访问：这个客户端会返回机密数值，不能比较、不能运算
-- ---------------------------------------------------------------------------
local function Legible(value)
    if value == nil then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

local function SafeNumber(value)
    if Legible(value) == nil then return nil end
    if type(value) ~= "number" then return nil end
    return value
end

local function PlayerKey()
    local name = UnitName("player")
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    if name and realm then return realm .. "-" .. name end
    return name or "player"
end

-- ---------------------------------------------------------------------------
-- 动作条法术
-- ---------------------------------------------------------------------------
-- 动作槽位覆盖所有页（1..120 起），具体上限取决于客户端
local function MaxActionSlot()
    local max = 0
    local pages = tonumber(_G.NUM_ACTIONBAR_PAGES)
    local buttons = tonumber(_G.NUM_ACTIONBAR_BUTTONS)
    if pages and buttons then max = pages * buttons end
    local constants = _G.Constants
    if type(constants) == "table" and type(constants.ActionBarConstants) == "table" then
        local actionBar = constants.ActionBarConstants
        local value = tonumber(actionBar.NUM_ACTION_SLOTS) or tonumber(actionBar.MAX_ACTION_BUTTONS)
        if value and value > max then max = value end
    end
    if max < 120 then max = 120 end
    if max > 240 then max = 240 end
    return math.floor(max)
end

-- GetActionInfo 的返回值可能是机密值，直接比较会报错；整段放进 pcall 里读
local function ActionAt(slot)
    if type(GetActionInfo) ~= "function" then return nil end
    local ok, actionType, id = pcall(function()
        local kind, value = GetActionInfo(slot)
        if type(kind) ~= "string" or type(value) ~= "number" then return nil end
        return kind, value
    end)
    if not ok or type(actionType) ~= "string" then return nil end
    id = SafeNumber(id)
    if not id then return nil end
    return actionType, id
end

local function SpellName(spellID)
    local api = _G.C_Spell
    local name
    if type(api) == "table" and type(api.GetSpellName) == "function" then
        local ok, value = pcall(function()
            local result = api.GetSpellName(spellID)
            if type(result) == "string" and result ~= "" then return result end
        end)
        if ok then name = Legible(value) end
    end
    if type(name) ~= "string" and type(api) == "table" and type(api.GetSpellInfo) == "function" then
        local ok, info = pcall(api.GetSpellInfo, spellID)
        if ok and type(info) == "table" then name = Legible(info.name) end
    end
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

-- 按名字查询时，客户端返回的是玩家已学会的最高等级
local function HighestRank(name)
    local api = _G.C_Spell
    if type(api) ~= "table" or type(api.GetSpellInfo) ~= "function" then return nil end
    local ok, spellID = pcall(function()
        local info = api.GetSpellInfo(name)
        local value = type(info) == "table" and info.spellID or nil
        if type(value) ~= "number" then return nil end
        if type(IsPlayerSpell) == "function" then
            local knownOk, known = pcall(IsPlayerSpell, value)
            if not knownOk or not known then return nil end
        end
        return value
    end)
    if not ok then return nil end
    return SafeNumber(spellID)
end

local function SpellRankText(spellID)
    local api = _G.C_Spell
    local text
    if type(api) == "table" and type(api.GetSpellSubtext) == "function" then
        local ok, value = pcall(api.GetSpellSubtext, spellID)
        if ok then text = Legible(value) end
    end
    if text == nil and type(_G.GetSpellSubtext) == "function" then
        local ok, value = pcall(_G.GetSpellSubtext, spellID)
        if ok then text = Legible(value) end
    end
    if text == nil and type(_G.GetSpellInfo) == "function" then
        local ok, _, rank = pcall(_G.GetSpellInfo, spellID)
        if ok then text = Legible(rank) end
    end
    if type(text) ~= "string" or text == "" then return nil end
    return text
end

-- "等级 3" / "Rank 3" 只取数字，列表里放得下
local function RankNumber(text)
    if type(text) ~= "string" then return nil end
    local ok, number = pcall(string.match, text, "(%d+)%s*$")
    if ok then return number end
    return nil
end

local function SpellIcon(spellID)
    local api = _G.C_Spell
    local texture
    if type(api) == "table" and type(api.GetSpellTexture) == "function" then
        local ok, value = pcall(api.GetSpellTexture, spellID)
        if ok then texture = value end
    end
    local ok, result = pcall(function()
        if type(texture) == "string" or type(texture) == "number" then return texture end
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end)
    if ok and result then return result end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- 动作槽位 → 动作条上的位置，只用于列表显示
local function SlotInfo(slot)
    local bar = math.floor((slot - 1) / 12) + 1
    local cell = (slot - 1) % 12 + 1
    local short = BAR_SHORT[bar] or ("第" .. bar .. "页")
    local full = BAR_FULL[bar] or ("第" .. bar .. "页")
    return short .. "-" .. cell, full .. "第" .. cell .. "格"
end

local function SlotFull(slot)
    local _, full = SlotInfo(slot)
    return full
end

-- ---------------------------------------------------------------------------
-- 排除名单（按角色保存，按法术等级记录）
-- 每个等级有独立的法术 ID，保留名单存的就是这些 ID
-- ---------------------------------------------------------------------------
local function IsEnabled()
    local value = DB.autoRankReplace
    if value == nil then return DEFAULT end
    return value and true or false
end

local function ExclusionSet(create)
    if type(DB.autoRankExclusions) ~= "table" then
        if not create then return nil end
        DB.autoRankExclusions = {}
    end
    local key = PlayerKey()
    local set = DB.autoRankExclusions[key]
    if type(set) ~= "table" then
        if not create then return nil end
        set = {}
        DB.autoRankExclusions[key] = set
    end
    return set
end

local function IsExcluded(spellID)
    local set = ExclusionSet(false)
    if not set or type(spellID) ~= "number" then return false end
    local ok, excluded = pcall(function() return set[spellID] == true end)
    return ok and excluded and true or false
end

local function SetExcluded(spellID, excluded)
    if type(spellID) ~= "number" then return end
    local set = ExclusionSet(excluded)
    if not set then return end
    if excluded then
        set[spellID] = true
    else
        set[spellID] = nil
    end
end

-- ---------------------------------------------------------------------------
-- 扫描动作条
-- ---------------------------------------------------------------------------
-- 每条记录对应一个具体的技能等级：同一法术的不同等级各占一行
local function ScanActions()
    local list, byID = {}, {}
    for slot = 1, MaxActionSlot() do
        local actionType, id = ActionAt(slot)
        if actionType == "spell" and id then
            local name = SpellName(id)
            if name then
                local target = HighestRank(name)
                if target and target ~= id then
                    local entry = byID[id]
                    if not entry then
                        entry = { id = id, name = name, target = target, slots = {} }
                        byID[id] = entry
                        list[#list + 1] = entry
                    end
                    entry.slots[#entry.slots + 1] = slot
                end
            end
        end
    end

    for _, entry in ipairs(list) do
        entry.icon = SpellIcon(entry.id)
        local currentText = SpellRankText(entry.id)
        entry.currentText = RankNumber(currentText) or currentText or "?"
        local targetText = SpellRankText(entry.target)
        entry.targetText = RankNumber(targetText) or targetText or "?"
    end

    pcall(table.sort, list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        local na = tonumber(a.currentText) or math.huge
        local nb = tonumber(b.currentText) or math.huge
        if na ~= nb then return na < nb end
        return a.id < b.id
    end)
    return list
end

local function PositionText(entry)
    local short = SlotInfo(entry.slots[1])
    local count = #entry.slots
    if count > 1 then return short .. " +" .. (count - 1) end
    return short
end

local function EntryTip(entry, excluded)
    local parts = { entry.name }
    parts[#parts + 1] = "等级 " .. entry.currentText .. " → 等级 " .. entry.targetText
    local positions = {}
    for _, slot in ipairs(entry.slots) do
        positions[#positions + 1] = SlotFull(slot)
    end
    parts[#parts + 1] = "位置：" .. table.concat(positions, "、")
    if excluded then
        parts[#parts + 1] = "|cffffcc33已保留：自动替换和批量替换都会跳过这个等级。|r"
    else
        parts[#parts + 1] = "点击勾选后保留这个等级，不再自动替换。"
    end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- 替换
-- ---------------------------------------------------------------------------
local function IsCombatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked and true or false
end

local function HasCursor()
    if type(GetCursorInfo) ~= "function" then return false end
    local ok, hasCursor = pcall(function()
        return GetCursorInfo() ~= nil
    end)
    return ok and hasCursor and true or false
end

local function PickupSpell(spellID)
    local api = _G.C_Spell
    if type(api) == "table" and type(api.PickupSpell) == "function" then
        return pcall(api.PickupSpell, spellID)
    end
    if type(_G.PickupSpell) == "function" then
        return pcall(_G.PickupSpell, spellID)
    end
    return false
end

local function PlaceHighest(spellID, slot)
    if type(PlaceAction) ~= "function" then return false end
    if not PickupSpell(spellID) then
        pcall(ClearCursor)
        return false
    end
    local ok = pcall(PlaceAction, slot)
    pcall(ClearCursor)
    if not ok then return false end
    -- 放置被拒绝时动作槽位不会变，按槽位里的实际法术判断是否成功
    local actionType, id = ActionAt(slot)
    return actionType == "spell" and id == spellID
end

-- 批量替换：只替换指定的这个等级
local function ReplaceRank(spellID)
    if IsExcluded(spellID) then return 0 end
    local name = SpellName(spellID)
    if not name then return 0 end
    local target = HighestRank(name)
    if not target or target == spellID then return 0 end

    local replaced = 0
    for slot = 1, MaxActionSlot() do
        local actionType, id = ActionAt(slot)
        if actionType == "spell" and id == spellID then
            if PlaceHighest(target, slot) then
                replaced = replaced + 1
            end
        end
    end
    return replaced
end

-- 自动替换：学到新等级后，把这个法术所有未保留的低级等级换成最高等级
local function ReplaceLowerRanks(name)
    local target = HighestRank(name)
    if not target then return 0 end

    local replaced = 0
    for slot = 1, MaxActionSlot() do
        local actionType, id = ActionAt(slot)
        if actionType == "spell" and id and id ~= target then
            if SpellName(id) == name and not IsExcluded(id) then
                if PlaceHighest(target, slot) then
                    replaced = replaced + 1
                end
            end
        end
    end
    return replaced
end

-- 面板刷新入口：只有面板已经打开时才重新扫描
local panelScan
local panelFrame
local function RefreshPanelIfShown()
    if panelScan and panelFrame and panelFrame:IsShown() then
        pcall(panelScan)
    end
end

local pendingNames = {}
local cursorPollQueued = false
local FlushPending

local function ClearPending()
    for name in pairs(pendingNames) do
        pendingNames[name] = nil
    end
end

FlushPending = function()
    if not IsEnabled() then
        ClearPending()
        return
    end
    if next(pendingNames) == nil then return end

    -- 战斗中不能放动作，等 PLAYER_REGEN_ENABLED 再处理
    if IsCombatLocked() then return end
    -- 光标上有东西时放置会把东西丢到动作条上，等玩家放下
    if HasCursor() then
        if not cursorPollQueued and type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            cursorPollQueued = true
            C_Timer.After(CURSOR_RETRY, function()
                cursorPollQueued = false
                FlushPending()
            end)
        end
        return
    end

    local names = {}
    for name in pairs(pendingNames) do
        names[#names + 1] = name
    end
    ClearPending()

    local total = 0
    for _, name in ipairs(names) do
        total = total + ReplaceLowerRanks(name)
    end
    if total > 0 then
        print("|cff66ccffLeatrixPlusExt|r 已把 " .. total .. " 个低级技能换成最高等级。")
        RefreshPanelIfShown()
    end
end

-- 学习事件后法术书才更新，稍等再读
local events = CreateFrame("Frame")
events:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "LEARNED_SPELL_IN_SKILL_LINE" then
        if not IsEnabled() then return end
        local spellID = SafeNumber(arg1)
        if not spellID then return end
        local name = SpellName(spellID)
        if not name then return end
        pendingNames[name] = true
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(SCAN_DELAY, FlushPending)
        else
            FlushPending()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if IsEnabled() and next(pendingNames) ~= nil then
            FlushPending()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- 二级设置页
-- ---------------------------------------------------------------------------
local function BuildPanel(parent, configPanel)
    local MakeHeading = Utils.MakeHeading
    local MakeLabel = Utils.MakeLabel
    local CreateButton = Utils.CreateButton
    local CreateScrollArea = Utils.CreateScrollArea
    local AssignTooltip = Utils.AssignTooltip

    panelFrame = configPanel

    MakeHeading(parent, "可替换的技能", 0, 0)
    MakeHeading(parent, "已保留的技能等级", RIGHT_X, 0)

    local status = MakeLabel(parent, "", 0, -20, LEFT_WIDTH)
    status:SetTextColor(0.8, 0.8, 0.8)

    local scanButton = CreateButton(parent, "重新扫描", "重新读取当前动作条上的技能。", parent)
    scanButton:SetPoint("TOPLEFT", 0, -36)

    local excludeAllButton = CreateButton(parent, "全选", "勾选列表里的全部技能等级，把它们加入保留名单。", parent)
    excludeAllButton:SetPoint("LEFT", scanButton, "RIGHT", 6, 0)

    local clearAllButton = CreateButton(parent, "全不选", "取消列表中全部勾选。", parent)
    clearAllButton:SetPoint("LEFT", excludeAllButton, "RIGHT", 6, 0)

    local bulkButton = CreateButton(parent, "批量替换", "把列表中未勾选的技能换成已学会的最高等级。", parent)
    bulkButton:SetPoint("LEFT", clearAllButton, "RIGHT", 6, 0)

    local function SetButtonText(button, text)
        button:SetText(text)
        if button.f then
            button.f:SetText(text)
            button:SetWidth(math.max(button.f:GetStringWidth() + 20, 40))
        end
    end

    local function SetButtonEnabled(button, enabled)
        button:SetEnabled(enabled)
        if button.f then
            if enabled then
                button.f:SetTextColor(1, 1, 1)
            else
                button.f:SetTextColor(0.45, 0.45, 0.45)
            end
        end
    end

    local function Header(text, x)
        local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", x, -66)
        fs:SetText(text)
        fs:SetTextColor(0.9, 0.9, 0.9)
        return fs
    end
    Header("技能", 50)
    Header("等级", 154)
    Header("位置", 252)

    -- CreateScrollArea 的第二个坐标相对父框右下角，所以用「距右边多远」表示宽度
    local _, leftScroll = CreateScrollArea(parent, 0, -80, LEFT_WIDTH - CONTENT_WIDTH, 6)
    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetSize(LEFT_CHILD_WIDTH, 1)
    leftScroll:SetScrollChild(leftChild)

    local _, rightScroll = CreateScrollArea(parent, RIGHT_X, -22, 0, 6)
    local rightChild = CreateFrame("Frame", nil, rightScroll)
    rightChild:SetSize(RIGHT_CHILD_WIDTH, 1)
    rightScroll:SetScrollChild(rightChild)

    local leftEmpty = leftChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    leftEmpty:SetPoint("TOPLEFT", 4, -4)
    leftEmpty:SetWidth(LEFT_CHILD_WIDTH - 8)
    leftEmpty:SetJustifyH("LEFT")
    leftEmpty:SetTextColor(0.7, 0.7, 0.7)
    leftEmpty:SetText("当前动作条上没有可替换的低级技能。")

    local rightEmpty = rightChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rightEmpty:SetPoint("TOPLEFT", 4, -4)
    rightEmpty:SetWidth(RIGHT_CHILD_WIDTH - 8)
    rightEmpty:SetJustifyH("LEFT")
    rightEmpty:SetTextColor(0.7, 0.7, 0.7)
    rightEmpty:SetText("暂无保留的技能等级。")

    local entries = {}
    local Render
    local leftRows, rightRows = {}, {}

    local function AddCheckMark(row)
        local box = row:CreateTexture(nil, "ARTWORK")
        box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
        box:SetSize(16, 16)
        box:SetPoint("LEFT", 2, 0)

        local check = row:CreateTexture(nil, "OVERLAY")
        check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check:SetSize(16, 16)
        check:SetPoint("LEFT", 2, 0)
        return check
    end

    local function GetLeftRow(index)
        local row = leftRows[index]
        if row then return row end

        row = CreateFrame("Button", nil, leftChild)
        row:SetSize(LEFT_CHILD_WIDTH, ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.check = AddCheckMark(row)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 24, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.nameText:SetPoint("LEFT", 44, 0)
        row.nameText:SetWidth(100)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        row.rankText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.rankText:SetPoint("LEFT", 148, 0)
        row.rankText:SetWidth(94)
        row.rankText:SetJustifyH("LEFT")
        row.rankText:SetWordWrap(false)

        row.posText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.posText:SetPoint("LEFT", 246, 0)
        row.posText:SetWidth(72)
        row.posText:SetJustifyH("LEFT")
        row.posText:SetWordWrap(false)
        row.posText:SetTextColor(0.8, 0.8, 0.8)

        row:SetScript("OnClick", function(self)
            if not IsEnabled() or type(self.spellID) ~= "number" then return end
            SetExcluded(self.spellID, not IsExcluded(self.spellID))
            Render()
        end)

        AssignTooltip(row, "", parent)
        leftRows[index] = row
        return row
    end

    local function GetRightRow(index)
        local row = rightRows[index]
        if row then return row end

        row = CreateFrame("Button", nil, rightChild)
        row:SetSize(RIGHT_CHILD_WIDTH, ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.check = AddCheckMark(row)

        row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.nameText:SetPoint("LEFT", 24, 0)
        row.nameText:SetWidth(104)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        row:SetScript("OnClick", function(self)
            if not IsEnabled() or type(self.spellID) ~= "number" then return end
            SetExcluded(self.spellID, not IsExcluded(self.spellID))
            Render()
        end)

        AssignTooltip(row, "", parent)
        rightRows[index] = row
        return row
    end

    Render = function()
        local enabled = IsEnabled()

        local excludedCount, replaceCount = 0, 0
        for _, entry in ipairs(entries) do
            if IsExcluded(entry.id) then
                excludedCount = excludedCount + 1
            else
                replaceCount = replaceCount + 1
            end
        end

        SetButtonEnabled(scanButton, enabled)
        SetButtonEnabled(excludeAllButton, enabled and #entries > 0)
        SetButtonEnabled(clearAllButton, enabled and excludedCount > 0)
        SetButtonEnabled(bulkButton, enabled and replaceCount > 0)
        SetButtonText(bulkButton, ("批量替换（%d）"):format(replaceCount))
        bulkButton.tiptext = ("把未勾选的 %d 个技能等级换成已学会的最高等级。"):format(replaceCount)

        if not enabled then
            status:SetText("开启「自动替换低级技能」后可用。")
        elseif #entries == 0 then
            status:SetText("当前动作条上没有可替换的低级技能。")
        else
            status:SetText(("扫描到 %d 个可替换的技能等级，其中 %d 个已保留。"):format(#entries, excludedCount))
        end

        for index, entry in ipairs(entries) do
            local row = GetLeftRow(index)
            local excluded = IsExcluded(entry.id)
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -2 - (index - 1) * ROW_HEIGHT)
            row:SetAlpha(enabled and 1 or 0.5)
            row.spellID = entry.id
            if excluded then row.check:Show() else row.check:Hide() end
            row.icon:SetTexture(entry.icon)
            row.nameText:SetText(entry.name)
            row.rankText:SetText(entry.currentText .. " → " .. entry.targetText)
            row.posText:SetText(PositionText(entry))
            row.tiptext = EntryTip(entry, excluded)
        end
        for index = #entries + 1, #leftRows do
            leftRows[index]:Hide()
        end
        leftEmpty:SetShown(#entries == 0)
        leftChild:SetSize(LEFT_CHILD_WIDTH, math.max(40, 4 + #entries * ROW_HEIGHT))

        local excludedList = {}
        local set = ExclusionSet(false)
        if set then
            for id in pairs(set) do
                if type(id) == "number" then
                    local rankText = SpellRankText(id)
                    excludedList[#excludedList + 1] = {
                        id = id,
                        name = SpellName(id) or ("未知法术 #" .. id),
                        rank = RankNumber(rankText) or rankText,
                        rankText = rankText,
                    }
                end
            end
        end
        pcall(table.sort, excludedList, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            local na, nb = tonumber(a.rank), tonumber(b.rank)
            if na and nb and na ~= nb then return na < nb end
            if na and not nb then return true end
            if nb and not na then return false end
            return a.id < b.id
        end)

        for index, item in ipairs(excludedList) do
            local row = GetRightRow(index)
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -2 - (index - 1) * ROW_HEIGHT)
            row:SetAlpha(enabled and 1 or 0.5)
            row.spellID = item.id
            row.check:Show()
            if item.rank then
                row.nameText:SetText(item.name .. " " .. item.rank)
            else
                row.nameText:SetText(item.name)
            end
            local full = item.rankText and (item.name .. "（" .. item.rankText .. "）") or item.name
            row.tiptext = full .. "\n这个技能等级已被保留。取消勾选后，它会重新参与自动替换和批量替换。"
        end
        for index = #excludedList + 1, #rightRows do
            rightRows[index]:Hide()
        end
        rightEmpty:SetShown(#excludedList == 0)
        rightChild:SetSize(RIGHT_CHILD_WIDTH, math.max(40, 4 + #excludedList * ROW_HEIGHT))
    end

    scanButton:SetScript("OnClick", function()
        if not panelScan then return end
        panelScan()
    end)

    excludeAllButton:SetScript("OnClick", function()
        if not IsEnabled() then return end
        for _, entry in ipairs(entries) do
            SetExcluded(entry.id, true)
        end
        Render()
    end)

    clearAllButton:SetScript("OnClick", function()
        if not IsEnabled() then return end
        for _, entry in ipairs(entries) do
            SetExcluded(entry.id, false)
        end
        Render()
    end)

    local function BulkReplace()
        if not IsEnabled() then return end
        if IsCombatLocked() then
            print("|cff66ccffLeatrixPlusExt|r 战斗中不能调整动作条，等战斗结束后再试。")
            return
        end
        if HasCursor() then
            print("|cff66ccffLeatrixPlusExt|r 请先放下光标上的物品，再批量替换。")
            return
        end

        local total = 0
        for _, entry in ipairs(entries) do
            if not IsExcluded(entry.id) then
                total = total + ReplaceRank(entry.id)
            end
        end
        if total > 0 then
            print(("|cff66ccffLeatrixPlusExt|r 已把 %d 个低级技能换成最高等级。"):format(total))
        else
            print("|cff66ccffLeatrixPlusExt|r 没有可替换的低级技能。")
        end
        if panelScan then panelScan() end
    end

    bulkButton:SetScript("OnClick", BulkReplace)

    panelScan = function()
        entries = ScanActions()
        Render()
        leftScroll:SetVerticalScroll(0)
        rightScroll:SetVerticalScroll(0)
    end
end

local MODULE_TIP = "学会新等级后，自动把动作条上这个技能的低级等级换成已学会的最高等级。"
    .. "\n\n右侧齿轮可以扫描当前动作条，按等级勾选想保留的技能，或一次替换全部低级技能。"

local PANEL_DESC = "学会新等级后，动作条上的低级技能会自动换成最高等级。"
    .. "下面按等级列出可替换的技能，勾选想保留的等级，或一次替换全部。"

NS.RegisterModule({
    key = "autoRankReplace",
    section = "系统界面",
    label = "自动替换低级技能",
    tip = MODULE_TIP,
    default = DEFAULT,
    panelTitle = "自动替换低级技能",
    panelDesc = PANEL_DESC,
    buildPanel = BuildPanel,
    onShow = function()
        if panelScan then pcall(panelScan) end
    end,
    reset = function()
        if type(DB.autoRankExclusions) == "table" then
            DB.autoRankExclusions[PlayerKey()] = nil
        end
        RefreshPanelIfShown()
    end,
    onToggle = function(enabled)
        if not enabled then
            ClearPending()
        end
        RefreshPanelIfShown()
    end,
})
