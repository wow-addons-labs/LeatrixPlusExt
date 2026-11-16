-- LeatrixPlusExt 模块：客户端优化
-- 常用的 /console CVar 调整，直接作为扩展页的一级选项：
--   画面：任务物品高亮
--   战斗：扩大血条显示距离、放大伤害/治疗数字
-- 超远视野和死亡灰屏由 Leatrix Plus 自带的 System 页选项提供，这里不再重复。
-- 数值可调的选项在主菜单上带齿轮，进入二级设置页单独调整。
-- 关闭某一项时，只把那一项的 CVar 还原成系统默认值。
local addonName, NS = ...

local DB = NS.DB
local Utils = NS.Utils
local SetCVarWithBackup = Utils.SetCVarWithBackup
local RestoreCVar = Utils.RestoreCVar
local MakeHeading = Utils.MakeHeading

-- 滑条上的「默认」是本插件开启功能时使用的值，不是游戏默认值
local DEFAULT_WORLD_TEXT_SCALE = 3

-- 姓名板距离：按实际效果取值。游戏自带选项是默认 20、上限 41；CVar 虽然接受
-- 45 / 60，但超过 41 后画面上的距离不再变化（实测无效），所以只使用 20-41。
local NAMEPLATE_DEFAULT = 20
local MIN_NAMEPLATE_DISTANCE = 20
local MAX_NAMEPLATE_DISTANCE = 41

-- 浮动战斗数字：不同客户端用的 CVar 名不同。优先只写客户端真实存在的那个；
-- 两个都读不到时才两个都试（例如值被标成机密值）。
local WORLD_TEXT_CVARS = {}
for _, cvar in ipairs({ "WorldTextScale", "WorldTextScale_v2" }) do
    if Utils.GetCVarValue(cvar) ~= nil or Utils.GetCVarDefaultValue(cvar) ~= nil then
        WORLD_TEXT_CVARS[#WORLD_TEXT_CVARS + 1] = cvar
    end
end
if #WORLD_TEXT_CVARS == 0 then
    WORLD_TEXT_CVARS = { "WorldTextScale", "WorldTextScale_v2" }
end

-- 关闭功能时还原的系统默认值。优先用客户端 GetCVarDefault 的返回值，
-- 查不到才用下面这组兜底值：
--   outlineModeShowLootEffectWhenDisabled 默认 0（关闭）
--   nameplateMaxDistance 实际默认 20（客户端 API 报的是 45，与实际效果不符）
--   WorldTextScale / WorldTextScale_v2 默认 1
local GAME_DEFAULTS = {
    outlineModeShowLootEffectWhenDisabled = "0",
    nameplateMaxDistance = "20",
    WorldTextScale = "1",
    WorldTextScale_v2 = "1",
}

-- 二级页滑条的位置：内容区坐标相对左上角 (0, 0)
local SLIDER_X = 16
local SLIDER_Y = -34
local SLIDER_WIDTH = 220

-- ---------------------------------------------------------------------------
-- 数值读取：统一做范围限制和步进取整，避免旧存档或手改存档出现越界值
-- ---------------------------------------------------------------------------
local function ClampNumber(value, minValue, maxValue, defaultValue, step)
    if type(value) ~= "number" then return defaultValue end
    if step and step > 0 then
        value = math.floor((value - minValue) / step + 0.5) * step + minValue
    end
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    -- 消除 0.5 步长带来的浮点误差
    return math.floor(value * 1000 + 0.5) / 1000
end

local function GetNameplateRange()
    return MIN_NAMEPLATE_DISTANCE, MAX_NAMEPLATE_DISTANCE
end

local function GetNameplateDistance()
    local minValue, maxValue = GetNameplateRange()
    return ClampNumber(DB.nameplateDistanceValue, minValue, maxValue, maxValue, 1)
end

-- 旧存档可能存着超出当前范围的值，直接归到开启时的默认值
do
    local minNameplate, maxNameplate = GetNameplateRange()
    local nameplateValue = DB.nameplateDistanceValue
    if type(nameplateValue) ~= "number"
        or nameplateValue < minNameplate or nameplateValue > maxNameplate then
        DB.nameplateDistanceValue = maxNameplate
    end
    -- Tab 距离选项已移除，清掉旧存档里的开关和数值
    DB.tabDistance = nil
    DB.tabDistanceValue = nil
end

local function GetWorldTextScale()
    return ClampNumber(DB.worldTextScaleValue, 1, 5, DEFAULT_WORLD_TEXT_SCALE, 1)
end

-- ---------------------------------------------------------------------------
-- 二级设置页：数值滑条（Leatrix 配置面板的滑条模板）
-- opts: min / max / step / value / format / hint / onChange
-- ---------------------------------------------------------------------------
local function CreateValuePanel(parent, opts)
    MakeHeading(parent, "数值设置", 0, 0)

    local slider = CreateFrame("Slider", nil, parent, "LeaPlusConfigurationPanelSliderTemplate")
    slider:SetMinMaxValues(opts.min, opts.max)
    slider:SetValueStep(opts.step)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(20)
    slider:SetHitRectInsets(0, 0, 0, 0)
    slider:SetPoint("TOPLEFT", SLIDER_X, SLIDER_Y)
    slider:EnableMouseWheel(true)
    -- 部分客户端没有这个方法，有则让拖动时也按步进对齐
    if slider.SetObeyStepOnDrag then
        pcall(slider.SetObeyStepOnDrag, slider, true)
    end

    local valueText = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("LEFT", slider, "RIGHT", 12, 0)

    local hint = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 2, SLIDER_Y - 28)
    hint:SetWidth(480)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText(opts.hint or "")
    hint:SetTextColor(0.7, 0.7, 0.7)

    local updating = false

    local function ShowValue(value)
        valueText:SetFormattedText(opts.format or "%g", value)
    end

    local function Round(rawValue)
        return ClampNumber(rawValue, opts.min, opts.max, opts.value, opts.step)
    end

    -- 写回滑条并触发回调；updating 防止 SetValue 再次进入 OnValueChanged 造成循环
    local function Apply(self, value)
        ShowValue(value)
        if updating then return end
        updating = true
        self:SetValue(value)
        updating = false
        if opts.onChange then opts.onChange(value) end
    end

    slider:SetScript("OnValueChanged", function(self, rawValue)
        Apply(self, Round(rawValue))
    end)
    slider:SetScript("OnMouseWheel", function(self, delta)
        Apply(self, Round(self:GetValue() + delta * opts.step))
    end)

    -- 初始化：只显示，不触发回调（回调里有 CVar 写入）
    updating = true
    slider:SetValue(opts.value)
    updating = false
    ShowValue(opts.value)

    return slider
end

-- 数值变化时：总是记进 DB；功能启用时立即写入 CVar
local function MakeValueChanged(dbKey, cvar, enabledKey, getter)
    return function(value)
        DB[dbKey] = value
        if DB[enabledKey] == true then
            SetCVarWithBackup(cvar, getter())
        end
    end
end

-- 关闭功能：还原成系统默认值。
-- nameplateMaxDistance 的客户端默认值（45）与实际有效默认值（20）不符，
-- 这一项强制按 GAME_DEFAULTS 里的 20 还原，其余 CVar 仍优先用客户端默认值。
local function RestoreDefault(cvar)
    if cvar == "nameplateMaxDistance" then
        return RestoreCVar(cvar, GAME_DEFAULTS[cvar], true)
    end
    return RestoreCVar(cvar, GAME_DEFAULTS[cvar])
end

-- 功能开关：启用时按当前数值写入 CVar，关闭时还原成系统默认值
-- onValue 可以是固定值，也可以是返回当前数值的函数
local function ToggleCVar(cvar, onValue)
    return function(enabled)
        if enabled then
            local value = onValue
            if type(value) == "function" then value = value() end
            if not SetCVarWithBackup(cvar, value) then
                print("|cff66ccffLeatrixPlusExt|r 这项设置没有生效，请确认游戏版本是否支持。")
            end
        else
            RestoreDefault(cvar)
        end
    end
end

-- 浮动数字的 CVar 名因客户端版本而异，只写本客户端真实存在的那个；关闭时同样只还原它
local function ApplyWorldTextScale(scale)
    scale = scale or GetWorldTextScale()
    local applied = false
    for _, cvar in ipairs(WORLD_TEXT_CVARS) do
        if SetCVarWithBackup(cvar, scale) then applied = true end
    end
    return applied
end

local function RestoreWorldTextScale()
    for _, cvar in ipairs(WORLD_TEXT_CVARS) do
        RestoreDefault(cvar)
    end
end

-- ---------------------------------------------------------------------------
-- 画面
-- ---------------------------------------------------------------------------
NS.RegisterModule({
    key = "questItemHighlight",
    section = "画面",
    label = "任务物品高亮",
    tip = "让地上的任务物品发光。不会改动你的轮廓（描边）设置；"
        .. "轮廓模式开着时，任务物品会显示轮廓而不是闪光。\n"
        .. "关闭后需要登出再登录（不是 /reload），不必重启游戏；"
        .. "切换画质后如果发现失效，重新勾选即可。",
    default = false,
    onToggle = ToggleCVar("outlineModeShowLootEffectWhenDisabled", 1),
})

-- ---------------------------------------------------------------------------
-- 战斗
-- ---------------------------------------------------------------------------
local nameplateSlider

NS.RegisterModule({
    key = "nameplateDistance",
    section = "战斗",
    label = "扩大血条显示距离",
    tip = "把姓名板距离调到最远。游戏默认 20 码，最远 41 码。"
        .. "\n\n关闭或调小距离会立即生效；调大距离后，已经被隐藏的远处姓名板"
        .. "需要重载界面（齿轮页底部的「重载」）才会重新出现。"
        .. "关闭后恢复游戏默认值（20 码）。",
    default = false,
    onToggle = ToggleCVar("nameplateMaxDistance", GetNameplateDistance),
    panelTitle = "扩大血条显示距离",
    panelDesc = "姓名板的显示距离。",
    buildPanel = function(parent)
        local minValue, maxValue = GetNameplateRange()
        nameplateSlider = CreateValuePanel(parent, {
            min = minValue,
            max = maxValue,
            step = 1,
            value = GetNameplateDistance(),
            format = "%d",
            hint = string.format(
                "范围 %d - %d 码，开启时默认 %d 码（游戏默认 %d 码）。"
                    .. "关闭功能后恢复游戏默认值（%d 码）。"
                    .. "调大距离后，远处已经被隐藏的姓名板需要重载界面才会重新出现。",
                minValue, maxValue, maxValue, NAMEPLATE_DEFAULT, NAMEPLATE_DEFAULT),
            onChange = MakeValueChanged("nameplateDistanceValue", "nameplateMaxDistance",
                "nameplateDistance", GetNameplateDistance),
        })
    end,
    reset = function()
        local _, maxValue = GetNameplateRange()
        DB.nameplateDistanceValue = maxValue
        if nameplateSlider then nameplateSlider:SetValue(maxValue) end
    end,
})

local worldTextScaleSlider

NS.RegisterModule({
    key = "worldTextScale",
    section = "战斗",
    label = "放大伤害/治疗数字",
    tip = "放大浮动伤害/治疗数字。"
        .. "\n\n点右侧齿轮可选择倍率（1-5，1 为游戏默认），调整后立即生效。"
        .. "关闭后恢复游戏默认值（1）。",
    default = false,
    onToggle = function(enabled)
        if enabled then
            if not ApplyWorldTextScale() then
                print("|cff66ccffLeatrixPlusExt|r 这项设置没有生效，请确认游戏版本是否支持。")
            end
        else
            RestoreWorldTextScale()
        end
    end,
    panelTitle = "放大伤害/治疗数字",
    panelDesc = "浮动伤害/治疗数字的缩放倍率。",
    buildPanel = function(parent)
        worldTextScaleSlider = CreateValuePanel(parent, {
            min = 1,
            max = 5,
            step = 1,
            value = GetWorldTextScale(),
            format = "%d",
            hint = "范围 1 - 5，开启时默认 3。1 为游戏默认大小，数值越大浮动数字越醒目。"
                .. "关闭功能后恢复游戏默认值 1。",
            onChange = function(value)
                DB.worldTextScaleValue = value
                if DB.worldTextScale == true then
                    ApplyWorldTextScale(GetWorldTextScale())
                end
            end,
        })
    end,
    reset = function()
        DB.worldTextScaleValue = DEFAULT_WORLD_TEXT_SCALE
        if worldTextScaleSlider then worldTextScaleSlider:SetValue(DEFAULT_WORLD_TEXT_SCALE) end
    end,
})

-- ---------------------------------------------------------------------------
-- 画质预设会把 outlineModeShowLootEffectWhenDisabled 重置为 0；
-- 功能开启期间在画质变化或该 CVar 被写成 0 后自动写回，避免悄悄失效
-- ---------------------------------------------------------------------------
local WATCHED_CVARS = {
    outlinemodeshowlooteffectwhendisabled = true,
    graphicsquality = true,
    raidgraphicsquality = true,
}

local reapplyFrame = CreateFrame("Frame")
reapplyFrame:RegisterEvent("CVAR_UPDATE")
reapplyFrame:SetScript("OnEvent", function(_, _, cvar, value)
    if DB.questItemHighlight ~= true then return end
    cvar = string.lower(tostring(cvar or ""))
    if not WATCHED_CVARS[cvar] then return end
    -- 只处理被重置成 0 的情况，插件自己写入 1 时不再触发一轮
    if cvar == "outlinemodeshowlooteffectwhendisabled" and tostring(value) ~= "0" then
        return
    end
    C_Timer.After(1, function()
        if DB.questItemHighlight ~= true then return end
        if Utils.GetCVarValue("outlineModeShowLootEffectWhenDisabled") ~= "1" then
            SetCVarWithBackup("outlineModeShowLootEffectWhenDisabled", 1)
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- 进入世界后客户端可能重新套用 Config.wtf 里的值，把插件刚写的 CVar 覆盖掉。
-- 登录、切换地图、重载后延迟 1 秒，把仍处于开启状态的选项再写一次。
-- ---------------------------------------------------------------------------
local enterWorldFrame = CreateFrame("Frame")
enterWorldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
enterWorldFrame:SetScript("OnEvent", function()
    C_Timer.After(1, function()
        if DB.questItemHighlight == true then
            SetCVarWithBackup("outlineModeShowLootEffectWhenDisabled", 1)
        end
        if DB.nameplateDistance == true then
            SetCVarWithBackup("nameplateMaxDistance", GetNameplateDistance())
        end
        if DB.worldTextScale == true then
            ApplyWorldTextScale()
        end
    end)
end)
