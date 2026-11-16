-- LeatrixPlusExt 模块：图腾栏
local addonName, NS = ...

local Utils = NS.Utils
local DB = NS.DB
local SafeMethod = Utils.SafeMethod
local MakeHeading = Utils.MakeHeading

-- ---------------------------------------------------------------------------
-- 隐藏系统图腾栏
-- ---------------------------------------------------------------------------
-- 图腾栏只有萨满会用到：其他职业既不显示选项，也不会去隐藏
local function PlayerClassToken()
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, classToken = pcall(UnitClass, "player")
    if not ok then return nil end
    return classToken
end

local function IsShaman()
    return PlayerClassToken() == "SHAMAN"
end

-- 入口可见性：职业信息还读不到时先显示，避免萨满在加载早期丢掉入口
local function ShowTotemEntry()
    local classToken = PlayerClassToken()
    return classToken == nil or classToken == "SHAMAN"
end

local function HideSystemFrame(frame)
    if not frame then return false end
    local hidden = pcall(frame.Hide, frame)
    if not frame.__leatrixPlusExtHooked then
        frame.__leatrixPlusExtHooked = true
        pcall(frame.HookScript, frame, "OnShow", function(self)
            if DB.hideSystemTotemBar and IsShaman() then
                pcall(self.Hide, self)
            end
        end)
    end
    return hidden
end

local function ApplySystemTotemBar()
    if not IsShaman() then return end
    if not DB.hideSystemTotemBar then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return
    end
    -- 系统图腾动作条/多图腾条
    HideSystemFrame(_G.MultiCastActionBarFrame)
    -- 暴雪图腾计时框（通常已被 TotemTimers 隐藏，这里兜底）
    HideSystemFrame(_G.TotemFrame)
end

NS.ApplySystemTotemBar = ApplySystemTotemBar

-- ---------------------------------------------------------------------------
-- 调试入口：图腾栏状态
-- 只有启用「调试控制台」后才显示右侧齿轮
-- ---------------------------------------------------------------------------
local function BuildTotemPanel(parent)
    MakeHeading(parent, "系统图腾栏状态", 0, 0)

    local status = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    status:SetPoint("TOPLEFT", 0, -20)
    status:SetWidth(520)
    status:SetJustifyH("LEFT")

    local function FrameState(name)
        local frame = _G[name]
        if not frame then return name .. " = nil" end
        local shown = SafeMethod(frame, "IsShown")
        local visible = SafeMethod(frame, "IsVisible")
        return name .. " shown=" .. tostring(shown) .. " visible=" .. tostring(visible)
    end

    local function RefreshStatus()
        status:SetText(FrameState("MultiCastActionBarFrame") .. "\n" .. FrameState("TotemFrame"))
    end

    local refreshButton = Utils.CreateButton(parent, "刷新状态", "重新读取图腾栏的显示状态。", parent)
    refreshButton:SetPoint("TOPLEFT", 0, -58)
    refreshButton:SetScript("OnClick", RefreshStatus)

    MakeHeading(parent, "说明", 0, -98)

    local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", 0, -118)
    note:SetWidth(520)
    note:SetJustifyH("LEFT")
    note:SetText("关闭「隐藏系统图腾栏」后，系统图腾栏可能需要 /reload 才会恢复。")
    note:SetTextColor(0.7, 0.7, 0.7)

    parent:HookScript("OnShow", RefreshStatus)
    RefreshStatus()
end

NS.RegisterModule({
    key = "hideSystemTotemBar",
    section = "系统界面",
    label = "隐藏系统图腾栏",
    tip = "隐藏游戏自带的图腾动作条和计时框（仅萨满可见）。"
        .. "关闭后可能需要 /reload 才会恢复。",
    -- 图腾栏只对萨满有意义，其他职业不显示这个入口
    isVisible = ShowTotemEntry,
    default = false,
    gearRequiresDebug = true,
    panelTitle = "图腾栏状态",
    panelDesc = "查看图腾栏当前的显示状态。",
    buildPanel = BuildTotemPanel,
    onToggle = function()
        ApplySystemTotemBar()
    end,
})
