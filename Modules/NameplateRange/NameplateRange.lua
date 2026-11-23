-- LeatrixPlusExt 模块：在可攻击单位的姓名板右上角显示估算距离
local _, NS = ...

local DEFAULT = true

local UPDATE_INTERVAL = 0.3
local BASE_FONT_SIZE = 12
local MELEE_RANGE = 8
local MAX_SPELL_RANGE = 41
local FALLBACK_RANGE = 28
local INF = math.huge
local MAX_MEMORY = 500

local COLOR_GREEN = { 0.1, 1, 0.1 }
local COLOR_YELLOW = { 1, 0.82, 0 }
local COLOR_RED = { 1, 0.1, 0.1 }

-- 和客户端自己的交互距离判定一致（LibRangeCheck 的实测值）
local INTERACT = { [3] = 8, [4] = 28 }
local INTERACT_BY_RACE = {
    Tauren = { [3] = 6, [4] = 25 },
    Scourge = { [3] = 7, [4] = 27 },
}

local enabled = false
local ticker
-- 按距离分组的检查项：{ range = 码数, probes = { { key, test }, ... } }
local slots = {}
-- 当前角色最长伤害技能射程，超过它显示红色
local maxHarmful = FALLBACK_RANGE

local holders = {}      -- [姓名板] = 我们的文字框
local active = {}       -- [单位 token] = 文字框
local answeredFor = {}  -- [GUID] = { [检查项] = true }
local answeredCount = 0

-- 部分客户端会把 API 返回值标记成秘密值，既不能比较也不能显示
local function Plain(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then
            return nil
        end
    end
    return value
end

local function GetNameplateScale()
    local questie = _G.Questie
    local profile = questie and questie.db and questie.db.profile
    local scale = profile and profile.nameplateScale
    if type(scale) ~= "number" or scale <= 0 then
        scale = 1.1
    end
    return scale
end

-- 姓名板上的单位 token；Client 的姓名板框架自己提供 GetUnit
local function GetPlateUnit(plate)
    if plate.GetUnit then
        local unit = plate:GetUnit()
        if type(unit) == "string" then
            return unit
        end
    end
    local unit = plate.namePlateUnitToken
    if type(unit) == "string" then
        return unit
    end
end

-- 距离检查：同一码数下的技能和交互方式都问一遍，任意一个说了算
local function BuildSlots()
    local grouped = {}
    local function Add(range, key, test)
        range = math.floor(range + 0.5)
        if range <= 0 or range > MAX_SPELL_RANGE then
            return
        end
        local slot = grouped[range]
        if not slot then
            slot = { range = range, probes = {} }
            grouped[range] = slot
        end
        for _, probe in ipairs(slot.probes) do
            if probe.key == key then
                return
            end
        end
        slot.probes[#slot.probes + 1] = { key = key, test = test }
    end

    local _, race = UnitRace("player")
    race = Plain(race)
    local distances = INTERACT_BY_RACE[race] or INTERACT
    for index, range in pairs(distances) do
        local interactIndex = index
        Add(range, "i" .. interactIndex, function(unit)
            local ok, answer = pcall(CheckInteractDistance, unit, interactIndex)
            if not ok then
                return nil
            end
            return Plain(answer)
        end)
    end

    maxHarmful = FALLBACK_RANGE
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    if bank and spellType and C_SpellBook and C_Spell then
        local okLines, lineCount = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        if okLines and type(lineCount) == "number" then
            for line = 1, lineCount do
                local okLine, lineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
                if okLine and lineInfo and not lineInfo.offSpecID then
                    local first = (lineInfo.itemIndexOffset or 0) + 1
                    local last = first + (lineInfo.numSpellBookItems or 0) - 1
                    for index = first, last do
                        local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, index, bank)
                        if okItem and item and item.itemType == spellType
                            and not item.isPassive and not item.isOffSpec and item.spellID then
                            local okSpell, spell = pcall(C_Spell.GetSpellInfo, item.spellID)
                            local maxRange = okSpell and spell and Plain(spell.maxRange)
                            if maxRange and maxRange > 0 and maxRange <= MAX_SPELL_RANGE then
                                maxRange = math.floor(maxRange + 0.5)
                                local minRange = math.floor((Plain(spell.minRange) or 0) + 0.5)
                                local okHarmful, harmful = pcall(C_Spell.IsSpellHarmful, item.spellID)
                                if okHarmful and Plain(harmful) then
                                    if maxRange > maxHarmful then
                                        maxHarmful = maxRange
                                    end
                                    -- 有最小射程的技能在死区里不回答，只用来判断最远射程
                                    if minRange <= 0 then
                                        local spellID = item.spellID
                                        Add(maxRange, "s" .. spellID, function(unit)
                                            local ok, answer = pcall(C_Spell.IsSpellInRange, spellID, unit)
                                            if not ok then
                                                return nil
                                            end
                                            return Plain(answer)
                                        end)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local list = {}
    for _, slot in pairs(grouped) do
        list[#list + 1] = slot
    end
    table.sort(list, function(a, b)
        return a.range < b.range
    end)
    slots = list
end

-- WoW Forever 上技能超出射程后返回 nil 而不是 false：先回答过、
-- 现在又不回答的检查项，按超出射程处理
local function GetMemory(unit)
    local guid = Plain(UnitGUID(unit))
    if type(guid) ~= "string" then
        return nil
    end
    local memory = answeredFor[guid]
    if not memory then
        if answeredCount >= MAX_MEMORY then
            answeredFor = {}
            answeredCount = 0
        end
        memory = {}
        answeredFor[guid] = memory
        answeredCount = answeredCount + 1
    end
    return memory
end

local function TestSlot(slot, unit, memory)
    local sawFalse = false
    for _, probe in ipairs(slot.probes) do
        local answer = probe.test(unit)
        if answer == nil and memory and memory[probe.key] then
            answer = false
        end
        if answer ~= nil then
            if memory then
                memory[probe.key] = true
            end
            if answer then
                return true
            end
            sawFalse = true
        end
    end
    if sawFalse then
        return false
    end
end

-- 已经确定上界后，把更远的检查项各问一次，方便单位走远后直接读出下界
local function Learn(from, unit, memory)
    for i = from, #slots do
        for _, probe in ipairs(slots[i].probes) do
            if not memory[probe.key] then
                local answer = probe.test(unit)
                if answer ~= nil then
                    memory[probe.key] = true
                end
            end
        end
    end
end

local function GetRange(unit)
    local memory = GetMemory(unit)
    local low, high, answered = 0, INF, false
    for index, slot in ipairs(slots) do
        local inRange = TestSlot(slot, unit, memory)
        if inRange then
            high, answered = slot.range, true
            if memory then
                Learn(index + 1, unit, memory)
            end
            break
        elseif inRange == false then
            low, answered = slot.range, true
        end
    end
    if not answered then
        return nil
    end
    return math.min(low, high), high
end

local function GetExactDistance(unit)
    local ok, distanceSquared, checked = pcall(UnitDistanceSquared, unit)
    if not ok then
        return nil
    end
    distanceSquared, checked = Plain(distanceSquared), Plain(checked)
    if checked and type(distanceSquared) == "number" then
        return math.sqrt(distanceSquared)
    end
end

local function BracketColor(low, high)
    if high <= MELEE_RANGE then
        return COLOR_GREEN
    end
    if low >= maxHarmful then
        return COLOR_RED
    end
    return COLOR_YELLOW
end

local function ExactColor(distance)
    if distance <= MELEE_RANGE then
        return COLOR_GREEN
    end
    if distance > maxHarmful then
        return COLOR_RED
    end
    return COLOR_YELLOW
end

-- 返回显示文字和颜色；算不出来时返回 nil
local function DistanceText(unit)
    local exact = GetExactDistance(unit)
    if exact then
        return tostring(math.floor(exact + 0.5)), ExactColor(exact)
    end

    local low, high = GetRange(unit)
    if not low or low >= high then
        return nil
    end
    if low > 0 then
        return low .. "+", BracketColor(low, high)
    end
    if high < INF then
        return high .. "-", BracketColor(low, high)
    end
end

local function GetHolder(plate)
    local holder = holders[plate]
    if holder then
        return holder
    end
    holder = CreateFrame("Frame", nil, plate)
    holder:SetSize(1, 1)
    holder:SetPoint("CENTER")
    holder.plate = plate
    holder.text = holder:CreateFontString(nil, "OVERLAY")
    holder.text:SetJustifyH("RIGHT")
    holder:Hide()
    holders[plate] = holder
    return holder
end

local function Add(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then
        return
    end
    local holder = GetHolder(plate)
    if holder.unit and active[holder.unit] == holder then
        active[holder.unit] = nil
    end
    holder.unit = unit
    holder.anchor = nil
    holder:SetFrameLevel(math.min(plate:GetFrameLevel() + 20, 9000))
    holder:Hide()
    active[unit] = holder
end

local function Remove(unit)
    local holder = active[unit]
    if holder then
        active[unit] = nil
        holder.unit = nil
        holder.anchor = nil
        holder:Hide()
    end
end

local function Rescan()
    for unit in pairs(active) do
        active[unit] = nil
    end
    for _, holder in pairs(holders) do
        holder:Hide()
    end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local unit = GetPlateUnit(plate)
        if unit and C_NamePlate.GetNamePlateForUnit(unit) == plate then
            Add(unit)
        end
    end
end

local function UpdateHolder(holder)
    local plate, unit = holder.plate, holder.unit
    if not enabled or not unit or not plate:IsShown() then
        holder:Hide()
        return
    end
    if not Plain(UnitExists(unit)) or not Plain(UnitCanAttack("player", unit)) then
        holder:Hide()
        return
    end

    local text, color = DistanceText(unit)
    if not text then
        holder:Hide()
        return
    end

    -- 放在血条上方靠右，和左侧的任务进度图标处于同一高度
    local unitFrame = plate.UnitFrame
    local healthBars = unitFrame and unitFrame.HealthBarsContainer
    local healthBar = healthBars and healthBars.healthBar
    local anchor = healthBars or healthBar or (unitFrame and unitFrame.healthBar) or unitFrame or plate
    if holder.anchor ~= anchor then
        holder.anchor = anchor
        holder.text:ClearAllPoints()
        holder.text:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 1)
    end

    -- 字体和任务进度一致
    local size = math.max(8, math.floor(BASE_FONT_SIZE * GetNameplateScale() + 0.5))
    if holder.fontSize ~= size then
        holder.fontSize = size
        local font = SystemFont_NamePlate and SystemFont_NamePlate:GetFont()
        if not (font and holder.text:SetFont(font, size, "OUTLINE")) then
            holder.text:SetFontObject("GameFontNormalSmall")
        end
    end

    if holder.text:GetText() ~= text then
        holder.text:SetText(text)
    end
    holder.text:SetTextColor(color[1], color[2], color[3])
    holder:Show()
end

local function UpdateAll()
    if not enabled then
        return
    end
    for _, holder in pairs(active) do
        -- 一个单位出错不影响其他姓名板
        pcall(UpdateHolder, holder)
    end
end

local eventFrame = CreateFrame("Frame")
local EVENTS = {
    "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED",
    "PLAYER_ENTERING_WORLD",
    "SPELLS_CHANGED",
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

eventFrame:SetScript("OnEvent", function(_, event, unit)
    if not enabled then
        return
    end

    if event == "NAME_PLATE_UNIT_ADDED" then
        Add(unit)
        local holder = active[unit]
        if holder then
            pcall(UpdateHolder, holder)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        Remove(unit)
    elseif event == "SPELLS_CHANGED" then
        BuildSlots()
    else
        BuildSlots()
        Rescan()
        UpdateAll()
        -- 姓名板可能比进入世界稍晚出现
        C_Timer.After(0.5, function()
            if enabled then
                Rescan()
                UpdateAll()
            end
        end)
    end
end)

local function Start()
    enabled = true
    RegisterEvents()
    BuildSlots()
    Rescan()
    UpdateAll()
    if ticker then
        ticker:Cancel()
    end
    ticker = C_Timer.NewTicker(UPDATE_INTERVAL, UpdateAll)
end

local function Stop()
    enabled = false
    UnregisterEvents()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    for unit, holder in pairs(active) do
        active[unit] = nil
        holder.unit = nil
        holder.anchor = nil
        holder:Hide()
    end
end

NS.RegisterModule({
    key = "nameplateRange",
    section = "战斗与画面",
    label = "姓名板显示距离",
    tip = "在可攻击单位的姓名板右上角显示距离。"
        .. "\n\n绿色表示在近战范围内，黄色表示在技能射程内，红色表示超出你的最长技能射程。",
    default = DEFAULT,
    onToggle = function(value)
        if value then
            Start()
        else
            Stop()
        end
    end,
})
