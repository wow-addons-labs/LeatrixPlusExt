-- LeatrixPlusExt 模块：快速标记/信号
-- 双击世界中的单位、单位框体或姓名板执行信号/标记效果；
-- 在队伍或团队中双击空地打开世界标记光柱环。
-- 已经打开的环进入战斗后保持显示，环上的安全按钮仍可点击；战斗中不能新开环。
-- 也可以在设置里给 Alt/Ctrl/Shift 单击单独配置效果：
-- 单击和双击各用各的效果，单击只在战斗外触发。
-- 信号走两步：第一次按下先备好安全按钮和宏，第二次点击优先让按钮接收硬件点击；
-- 若点击被世界捕获框收到（按钮没拿到），就在捕获回调里对按钮做一次程序化点击补发。
-- 信号盘改用「修饰键 + 单击」手势：常驻覆盖绑定把该组合交给游戏的
-- TOGGLEPINGLISTENER，快按发情境信号，按住展开信号盘（见下面的“信号盘”）。
-- 标记优先用客户端的安全按钮动作（raidtarget / worldmarker），不依赖 /tm、/wm 别名。
local addonName, NS = ...

local DB = NS.DB
local Utils = NS.Utils

local DEFAULT = true
local DOUBLE_SECONDS = 0.36
local DOUBLE_DISTANCE = 38
-- 环形菜单参照 SimpleRaidTargetIcons 的经典样式：
-- 深色圆盘 + 一圈同色芯片，悬停时图标放大、描边提亮并浮出光晕
local RING_SIZE = 190
local RADIUS, CHIP_SIZE, HIT_RADIUS = 60, 34, 20
local CHIP_ICON, CHIP_ICON_HOVER = 22, 27
local CENTER_SIZE = 52
-- 用圆形遮罩贴图把纯色方块裁成圆：圆盘、芯片、光晕都靠它
local RING_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CLEAR_TEXTURE = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local OPEN_SECONDS = 0.18
local AUTO_CLOSE_SECONDS = 8
local HOVER_UPDATE = 0.03

-- 本客户端的 /ping 不区分类型参数（实测 Assist/Attack/Warning 都一样），
-- 只会按目标关系发情境信号；但命令里必须带一个类型才会真正发送。
--
-- 四个双击槽位各自独立配置，每次只执行一个动作，可选 3 种效果或“禁用”：
--   默认双击 / Alt + 双击 / Ctrl + 双击 / Shift + 双击
--     → ping / 默认标记 / 标记环 / 禁用
-- 信号盘只能在「修饰键 + 单击」槽位选择（见 NATIVE_EFFECT）。
local EFFECTS = {
    { key = "ping",        label = "信号",    ping = true },
    { key = "markDefault", label = "默认标记", mark = true },
    { key = "markRing",    label = "标记环",   ring = true },
}

local EFFECT_MAP = {}
for _, effect in ipairs(EFFECTS) do EFFECT_MAP[effect.key] = effect end

-- 下拉菜单里的“禁用”：不放进 EFFECT_MAP，所以所有按效果表分发的路径
-- （双击、修饰键单击）查不到效果时会自然跳过，什么都不做。
local DISABLED_EFFECT = "none"
local DISABLED_LABEL = "禁用"

-- 单击槽位专用的「信号盘」：常驻覆盖绑定把该修饰键 + 左键交给游戏的信号监听。
-- 绑定必须在你按下之前就存在，所以只能用于单击手势，双击用不了。
local NATIVE_EFFECT = "nativePing"
local NATIVE_LABEL = "信号盘"

-- 早期版本保存的旧值：mark = 标记环，signal = 信号。
-- 组合效果已取消，旧设置按其中的标记/环部分迁移，避免直接掉回槽位默认。
-- pingRing 是旧的信号盘（只支持双击）；现在双击槽位不再提供，
-- 旧值退化成普通信号，避免下拉里看到一个不会再生效的选项。
local LEGACY_EFFECTS = {
    mark = "markRing",
    signal = "ping",
    pingRing = "ping",
    pingMarkDefault = "markDefault",
    pingMarkRing = "markRing",
}

-- 序号必须和客户端一致：SetRaidTargetIconTexture / /tm 的 1 是星形，8 才是骷髅。
-- name / color 用于环形菜单：图标芯片用与标记同色的描边和光晕。
local MARKERS = {
    { key = "1", label = "1 星形", name = "星形", color = { 1.00, 1.00, 0.00 } },
    { key = "2", label = "2 圆圈", name = "圆圈", color = { 1.00, 0.50, 0.00 } },
    { key = "3", label = "3 菱形", name = "菱形", color = { 1.00, 0.00, 1.00 } },
    { key = "4", label = "4 三角", name = "三角", color = { 0.49, 0.99, 0.00 } },
    { key = "5", label = "5 月亮", name = "月亮", color = { 0.78, 0.78, 0.81 } },
    { key = "6", label = "6 方块", name = "方块", color = { 0.00, 0.75, 1.00 } },
    { key = "7", label = "7 十字", name = "十字", color = { 1.00, 0.27, 0.00 } },
    { key = "8", label = "8 骷髅", name = "骷髅", color = { 1.00, 1.00, 1.00 } },
}

-- 优先用客户端自带的目标标记名称，没有时退回上面的中文名
local function MarkerName(index)
    local localized = _G["RAID_TARGET_" .. index]
    if type(localized) == "string" and localized ~= "" then return localized end
    return MARKERS[index].name
end

local DEFAULTS = {
    action = "ping",             -- 默认双击：信号（最轻量，误触无副作用）
    altAction = "markRing",      -- Alt + 双击：标记环（需要主动按住，适合展开环形菜单）
    ctrlAction = "markDefault",  -- Ctrl + 双击：默认标记（直接上标）
    shiftAction = DISABLED_EFFECT, -- Shift + 双击：禁用（三种效果已分配完，先留空避免误触）
    defaultMarker = 8,           -- “默认标记”效果使用的目标标记（8 = 骷髅）
    -- 修饰键 + 单击（只在战斗外触发，效果独立于双击槽位）
    clickAlt = DISABLED_EFFECT,
    clickCtrl = DISABLED_EFFECT,
    clickShift = DISABLED_EFFECT,
}

local QM = {}
local UpdatePanel

local function IsEnabled()
    local value = DB.quickMark
    if value == nil then return DEFAULT end
    return value and true or false
end

local function inCombat()
    return (InCombatLockdown and InCombatLockdown()) and true or false
end

-- 部分 API 会返回秘密值，不能直接比较或当字符串用
local function Plain(value)
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if not ok or not allowed then return nil end
    end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

-- 世界标记光柱优先用客户端的安全按钮动作放置，只能在队伍或团队中使用。
-- 命令/动作编号和标记环上的目标标记图标顺序不同，这里把两者对应起来。
local GROUND_MAP = { 5, 6, 3, 2, 7, 1, 4, 8 }

-- 单人时客户端不允许放置世界光柱
local function InGroupOrRaid()
    if type(_G.IsInRaid) == "function" then
        local ok, inRaid = pcall(_G.IsInRaid)
        if ok and inRaid then return true end
    end
    if type(_G.IsInGroup) == "function" then
        local ok, inGroup = pcall(_G.IsInGroup)
        if ok and inGroup then return true end
    end
    if type(_G.GetNumPartyMembers) == "function" then
        local ok, count = pcall(_G.GetNumPartyMembers)
        if ok and type(count) == "number" and count > 0 then return true end
    end
    if type(_G.GetNumRaidMembers) == "function" then
        local ok, count = pcall(_G.GetNumRaidMembers)
        if ok and type(count) == "number" and count > 0 then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 设置项
-- ---------------------------------------------------------------------------
local function GetOptions()
    local opts = DB.quickMarkOptions
    if type(opts) ~= "table" then
        opts = {}
        DB.quickMarkOptions = opts
    end
    return opts
end

local function GetOption(key)
    local value = GetOptions()[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

local function SetOption(key, value)
    GetOptions()[key] = value
end

local function NormalizeEffect(value, fallback)
    if LEGACY_EFFECTS[value] then return LEGACY_EFFECTS[value] end
    if value == DISABLED_EFFECT then return DISABLED_EFFECT end
    if value == NATIVE_EFFECT then return NATIVE_EFFECT end
    if EFFECT_MAP[value] then return value end
    return fallback
end

local function GetAction()
    return NormalizeEffect(GetOption("action"), DEFAULTS.action)
end

local function GetAltAction()
    return NormalizeEffect(GetOption("altAction"), DEFAULTS.altAction)
end

local function GetCtrlAction()
    return NormalizeEffect(GetOption("ctrlAction"), DEFAULTS.ctrlAction)
end

local function GetShiftAction()
    return NormalizeEffect(GetOption("shiftAction"), DEFAULTS.shiftAction)
end

local function GetDefaultMarker()
    local value = tonumber(GetOption("defaultMarker"))
    if not value or value < 1 or value > 8 then return DEFAULTS.defaultMarker end
    return math.floor(value)
end

-- 修饰键槽位：单击效果按 clickAlt/clickCtrl/clickShift 独立保存，
-- 和对应双击槽位的 altAction/ctrlAction/shiftAction 互不影响。
-- key 同时用来拼设置项名称（clickCtrl），所以保持大写开头
local KEY_SLOTS = {
    { key = "Ctrl",  label = "Ctrl",  option = "ctrlAction",  double = GetCtrlAction },
    { key = "Alt",   label = "Alt",   option = "altAction",   double = GetAltAction },
    { key = "Shift", label = "Shift", option = "shiftAction", double = GetShiftAction },
}

local KEY_SLOT_MAP = {}
for _, slot in ipairs(KEY_SLOTS) do KEY_SLOT_MAP[slot.key] = slot end

-- 旧版本把单击存成勾选框：true 表示沿用对应双击槽位效果，false 表示关闭。
-- 读到旧值时就地迁移成效果名，避免同一份存档在两种含义之间摇摆。
local function GetClickAction(slot)
    local key = "click" .. slot.key
    local value = GetOptions()[key]
    local raw = value
    if value == true then
        value = slot.double()
        SetOption(key, value)
    elseif value == false then
        value = DISABLED_EFFECT
        SetOption(key, value)
    end
    value = NormalizeEffect(value, DISABLED_EFFECT)
    -- 旧效果名（如 pingRing）读到时就地写回去，下次直接按新名字使用
    if raw ~= nil and raw ~= value then SetOption(key, value) end
    return value
end

-- 单击走和双击相同的修饰键优先级（Ctrl > Alt > Shift）；没按修饰键就不触发
local function ClickEffectKey()
    local slot
    if IsControlKeyDown() then
        slot = KEY_SLOT_MAP.Ctrl
    elseif IsAltKeyDown() then
        slot = KEY_SLOT_MAP.Alt
    elseif IsShiftKeyDown() then
        slot = KEY_SLOT_MAP.Shift
    end
    return slot and GetClickAction(slot)
end

-- ---------------------------------------------------------------------------
-- 系统信号开关
-- ---------------------------------------------------------------------------
-- 系统设置里的信号系统关闭时，客户端不会显示任何 ping。此时带 ping 的效果
-- 要退化成对应的标记效果，否则默认双击（默认配置为 ping）会看起来“没有反应”。
-- 「设置选项 → 游戏功能 → 信号系统」对应 CVar enablePings，关闭时读到 "0"。
-- 注意：本客户端的 C_Ping.IsPingSystemEnabled() 实测在关闭后仍返回 true，
-- 不能作为判断依据，只在 CVar 读不到时才退回它；
-- 两者都检测不到时按“已开启”处理，保持原有行为。
local function PingSystemEnabled()
    if type(_G.GetCVar) == "function" then
        local ok, value = pcall(_G.GetCVar, "enablePings")
        if ok and value ~= nil then
            local text = tostring(value)
            if text == "1" or text == "true" then return true end
            if text == "0" or text == "false" then return false end
        end
    end
    local ping = _G.C_Ping
    if type(ping) == "table" and type(ping.IsPingSystemEnabled) == "function" then
        local ok, enabled = pcall(ping.IsPingSystemEnabled, ping)
        if ok and type(enabled) == "boolean" then return enabled end
        if ok and enabled == 1 then return true end
        if ok and enabled == 0 then return false end
    end
    return true
end

-- 信号不可用时，信号类效果退化为对应的标记效果
local PING_FALLBACKS = {
    ping = "markDefault",
    nativePing = "markDefault",
}

-- 信号不可用时静默退化，真正的提示由双击路径的 ResolveEffect 负责。
local function EffectiveEffect(key)
    if PingSystemEnabled() then return key end
    return PING_FALLBACKS[key] or key
end

local pingDisabledWarned = false

local function ResolveEffect(key)
    local fallback = PING_FALLBACKS[key]
    if not fallback then return key end
    if PingSystemEnabled() then
        pingDisabledWarned = false
        return key
    end
    if not pingDisabledWarned then
        pingDisabledWarned = true
        print("|cffffd100LeatrixPlusExt|r 信号系统未开启，本次信号已改用对应的标记效果。"
            .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。")
    end
    return fallback
end

-- 本次点击用的是哪个槽位：Ctrl > Alt > Shift > 默认双击
local function SlotEffectKey()
    if IsControlKeyDown() then
        return GetCtrlAction()
    elseif IsAltKeyDown() then
        return GetAltAction()
    elseif IsShiftKeyDown() then
        return GetShiftAction()
    end
    return GetAction()
end

-- 本次点击实际会触发哪个效果（信号不可用时退化成标记）
local function EffectForClick()
    return ResolveEffect(SlotEffectKey())
end

-- ---------------------------------------------------------------------------
-- ping 命令
-- ---------------------------------------------------------------------------
-- 本客户端的 /ping 不区分类型（Assist / Attack / Warning 效果一样），
-- 但必须带一个类型参数才会发送；只有条件、没有类型时等同于切换信号监听，
-- 什么信号都不会发出去。这里沿用 DungeonsForever 的写法。
local PING_TYPE = "Attack"

local function PingCommand()
    local cmd = _G.SLASH_PING1
    if type(cmd) == "string" and cmd:find("^/[^%s%c]+$") then return cmd end
    return "/ping"
end

-- 世界光柱的斜杠命令别名由客户端注册（可能是 /wm，也可能是 /worldmarker），
-- 直接取客户端自己的别名，避免写死的命令名在别的客户端上不存在。
local function WorldMarkerCommand()
    local cmd = _G.SLASH_WORLD_MARKER1
    if type(cmd) == "string" and cmd:find("^/[^%s%c]+$") then return cmd end
    return "/wm"
end


-- ---------------------------------------------------------------------------
-- 安全按钮与环形菜单
-- ---------------------------------------------------------------------------
local function updateClickRegistration(button)
    local ok, v = pcall(GetCVar, "ActionButtonUseKeyDown")
    if ok and v == "1" then
        button:RegisterForClicks("LeftButtonDown")
        button.useDown = true
    else
        button:RegisterForClicks("LeftButtonUp")
        button.useDown = false
    end
end

local function createSecureButton(parent, size, frameLevel, name)
    local ok, button = pcall(CreateFrame, "Button", name, parent, "SecureActionButtonTemplate")
    if not ok or not button then return nil end
    button:SetSize(size, size)
    button:SetFrameStrata("FULLSCREEN_DIALOG")
    button:SetFrameLevel(frameLevel)
    updateClickRegistration(button)
    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetAllPoints()
    button:SetAlpha(0)
    button:EnableMouse(false)
    button:Show()
    return button
end

local function setMarkerIcon(icon, index)
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    if SetRaidTargetIconTexture then
        SetRaidTargetIconTexture(icon, index)
    else
        local col, row = (index - 1) % 4, math.floor((index - 1) / 4)
        icon:SetTexCoord(col / 4, (col + 1) / 4, row / 2, (row + 1) / 2)
    end
end

-- 用圆形遮罩创建一个纯色圆片；同色光晕用 ADD 混合叠在芯片后面
local function RingCircle(parent, sublevel, size, r, g, b, a)
    local circle = parent:CreateTexture(nil, "BACKGROUND", nil, sublevel)
    circle:SetTexture(RING_TEXTURE)
    circle:SetSize(size, size)
    circle:SetPoint("CENTER")
    circle:SetVertexColor(r, g, b, a)
    return circle
end

-- 图标芯片：彩色光晕 + 彩色描边 + 深色底盘，中间放标记图标
local function DecorateChip(button, index)
    local color = MARKERS[index].color
    button.glow = RingCircle(button, 0, CHIP_SIZE + 16, color[1], color[2], color[3], 1)
    button.glow:SetBlendMode("ADD")
    button.glow:SetAlpha(0)
    button.outline = RingCircle(button, 1, CHIP_SIZE + 2, color[1], color[2], color[3], 0.5)
    button.fill = RingCircle(button, 2, CHIP_SIZE - 2, 0.13, 0.13, 0.16, 1)
    button.Icon:ClearAllPoints()
    button.Icon:SetPoint("CENTER")
    button.Icon:SetSize(CHIP_ICON, CHIP_ICON)
end

-- 中心按钮：深色圆盘 + 金色高亮，给“清除”一个明确的落点
local function DecorateCenter(button)
    button.rim = RingCircle(button, 0, CENTER_SIZE, 0.30, 0.30, 0.36, 1)
    button.fill = RingCircle(button, 1, CENTER_SIZE - 2, 0.13, 0.13, 0.16, 1)
    button.Icon:ClearAllPoints()
    button.Icon:SetPoint("CENTER")
    button.Icon:SetSize(CENTER_SIZE * 0.46, CENTER_SIZE * 0.46)
    button.Icon:SetTexture(CLEAR_TEXTURE)
end

-- 悬停：图标放大、描边提亮、同色光晕淡入（参照 SimpleRaidTargetIcons）
local function applyButtonColor(button, hovered)
    if not button or not button.glow then return end
    button.glow:SetAlpha(hovered and 0.45 or 0)
    button.outline:SetAlpha(hovered and 1 or 0.5)
    local size = hovered and CHIP_ICON_HOVER or CHIP_ICON
    button.Icon:SetSize(size, size)
end

local function SetCenterHover(button, hovered)
    if not button or not button.rim then return end
    if hovered then
        button.rim:SetVertexColor(0.80, 0.68, 0.20, 1)
        button.fill:SetVertexColor(0.18, 0.16, 0.10, 1)
        button.Icon:SetVertexColor(1, 0.90, 0.50, 1)
    else
        button.rim:SetVertexColor(0.30, 0.30, 0.36, 1)
        button.fill:SetVertexColor(0.13, 0.13, 0.16, 1)
        button.Icon:SetVertexColor(1, 1, 1, 1)
    end
end

local function hideButton(button)
    if not button then return end
    button:SetAlpha(0)
    button:SetScale(1)
    button:EnableMouse(false)
    if button.glow then
        applyButtonColor(button, false)
    elseif button.rim then
        SetCenterHover(button, false)
    elseif button.Icon then
        button.Icon:SetVertexColor(1, 1, 1, 1)
    end
end

local function tintButton(button, hovered)
    applyButtonColor(button, hovered)
end

-- 两种环共用一套展开/悬停逻辑：目标标记、世界光柱
local function ModeButtons(self, mode)
    if mode == "unit" then return self.unitButtons end
    if mode == "ground" then return self.groundButtons end
end

local function ModeCenter(self, mode)
    if mode == "unit" then return self.clearUnitButton end
    if mode == "ground" then return self.clearGroundButton end
end

function QM:HideRing()
    -- 战斗锁定期间不能隐藏安全按钮，也关不掉它们的鼠标；环保持显示，
    -- 这次收起请求记下来，等战斗结束后再执行
    if inCombat() then
        if self.mode then self.closePending = true end
        return
    end
    if self.overlay then
        self.overlay:SetScript("OnUpdate", nil)
        self.overlay:Hide()
    end
    if self.ring then self.ring:Hide() end
    self.mode, self.pendingOpen, self.openAnimation = nil, nil, nil
    self.hoveredIndex = nil
    self.centerHovered = nil
    self.labelHovered, self.labelCenter = nil, nil
    for _, mode in ipairs({ "unit", "ground" }) do
        local list = ModeButtons(self, mode)
        if list then
            for _, button in ipairs(list) do hideButton(button) end
        end
    end
    hideButton(self.clearUnitButton)
    hideButton(self.clearGroundButton)
    self.closePending = nil
end

function QM:HitAnyButton()
    if not GetCursorPosition then return false end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local list = ModeButtons(self, self.mode)
    if list then
        local hit2 = HIT_RADIUS * HIT_RADIUS
        for _, button in ipairs(list) do
            if button:IsShown() then
                local bx, by = button:GetCenter()
                if bx and (x - bx) * (x - bx) + (y - by) * (y - by) <= hit2 then
                    return true
                end
            end
        end
    end
    local center = ModeCenter(self, self.mode)
    if center and center:IsShown() then
        local bx, by = center:GetCenter()
        if bx and (x - bx) * (x - bx) + (y - by) * (y - by) <= HIT_RADIUS * HIT_RADIUS then
            return true
        end
    end
    return false
end

local function closeAfterClick()
    -- 战斗中收不掉环，点完标记后继续保留，脱战后按正常规则关闭
    if inCombat() then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() QM:HideRing() end)
    else
        QM:HideRing()
    end
end

-- 只改透明度和鼠标开关，绝不 Hide/Show：
-- 标记环的按钮从创建后一直保持显示，只有透明度变化，所以点击能执行标记动作；
-- 隐藏过的安全按钮再显示出来后，点击就执行不了受保护命令（实测确认）。
local function DisableDirectButton(button)
    if not button then return end
    pcall(button.EnableMouse, button, false)
    pcall(button.SetAlpha, button, 0)
end

-- 双击效果按钮被点击后的统一处理
local function HandleDirectClick(button)
    -- 所有直接按钮都放在同一个锚点下，只有本次布置的那个是启用鼠标的。
    -- 万一有别的按钮残留启用状态（旧版本留下的），这里直接忽略，避免执行错的宏。
    if not QM.armedEffect or button ~= QM.directButton then
        DisableDirectButton(button)
        return
    end
    QM.pingConsumed = true
    -- 标记用 API 补发，不依赖这条点击路径是硬件还是程序化
    QM:ApplyPendingMark()

    -- 点击已经交给客户端处理，下一帧再收起，避免多余点击重复触发
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() QM:DisarmPing() end)
    else
        QM:DisarmPing()
    end
end

-- 安全按钮的属性是按「修饰键」查的：按住 Ctrl 时客户端先找 ctrl-type1 /
-- ctrl-macrotext1，找不到就当成没有动作 —— 整条宏都不会执行（实测：无修饰键
-- 能标、按住 Ctrl 标不上）。所以除了 type1/macrotext1，再设一份不带后缀的
-- type/macrotext 作为兜底，任何修饰键组合的点击都能执行同一个宏。
local function SetMacroAction(button, text)
    button:SetAttribute("type1", "macro")
    button:SetAttribute("macrotext1", text)
    button:SetAttribute("type", "macro")
    button:SetAttribute("macrotext", text)
end

-- 目标标记和光柱优先走客户端内置的安全按钮动作，行为与原生标记按钮一致，
-- 也不依赖客户端注册的斜杠命令别名；缺少对应 API 时才退回 /tm、/wm 宏。
local function HasRaidTargetAction()
    return type(_G.SetRaidTarget) == "function"
end

local function HasWorldMarkerAction()
    if type(_G.PlaceRaidMarker) ~= "function" then return false end
    local check = _G.IsRaidMarkerSystemEnabled
    if type(check) == "function" then
        local ok, enabled = pcall(check)
        if ok then
            enabled = Plain(enabled)
            if enabled == false then return false end
        end
    end
    return true
end

-- 安全属性的查找顺序是「修饰键前缀 → 通配 * → 无前缀」。
-- type1 供普通点击使用，*type1 保证按住 Ctrl/Alt/Shift 点击时也能读到同一个动作，
-- 否则客户端会认为这条按钮没有动作。
local function SetSecureAction(button, action, attributes)
    button:SetAttribute("type1", action)
    button:SetAttribute("*type1", action)
    for key, value in pairs(attributes or {}) do
        button:SetAttribute(key .. "1", value)
        button:SetAttribute("*" .. key .. "1", value)
    end
end

local function SetUnitMarkAction(button, marker, unit)
    if HasRaidTargetAction() then
        SetSecureAction(button, "raidtarget", {
            unit = unit or "target",
            marker = marker,
            action = "set",
        })
    else
        SetMacroAction(button, "/tm " .. marker)
    end
end

local function SetGroundMarkAction(button, marker)
    if HasWorldMarkerAction() then
        SetSecureAction(button, "worldmarker", {
            marker = marker,
            action = "set",
        })
    else
        SetMacroAction(button, WorldMarkerCommand() .. " " .. marker)
    end
end

-- 清除全部光柱：有原生动作时直接清除；否则优先用客户端注册的清除命令别名
local function SetClearWorldMarkerAction(button)
    if HasWorldMarkerAction() then
        -- 不设 marker 属性时，「clear」会清除全部光柱
        SetSecureAction(button, "worldmarker", { action = "clear" })
        return
    end

    local cmd = _G.SLASH_CLEAR_WORLD_MARKER1
    if type(cmd) == "string" and cmd:find("^/[^%s%c]+$") then
        local lines = {}
        for index = 1, 8 do
            lines[index] = cmd .. " " .. index
        end
        SetMacroAction(button, table.concat(lines, "\n"))
    end
end

-- 安全动作在某些情况下会静默不执行（例如点击时目标刚好失效）。
-- 标记环只在非战斗状态打开，这时可以直接用 API 补一次，不依赖宏或第二次点击。
local function VerifyUnitMark(marker)
    if inCombat() or not IsEnabled() then return end
    if not C_Timer or not C_Timer.After then return end
    C_Timer.After(0, function()
        if inCombat() or not IsEnabled() then return end
        local okExists, exists = pcall(UnitExists, "target")
        if not okExists or not exists then return end
        local ok, current = pcall(_G.GetRaidTargetIndex, "target")
        current = ok and Plain(current) or nil
        if current == marker then return end
        if type(_G.SetRaidTarget) ~= "function" then return end
        pcall(_G.SetRaidTarget, "target", marker)
    end)
end

-- 创建一个固定宏的点击按钮；宏只在创建时设置一次（和标记环按钮一样）。
-- 按钮本身永远不移动，跟着 anchor 走，避免对安全按钮做额外的点/移动操作。
local function CreateDirectButton(text, frameLevel, anchor)
    local button = createSecureButton(UIParent, 120, frameLevel)
    if not button then return nil end
    SetMacroAction(button, text)
    button:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    button.Icon:SetTexture(nil)
    button:HookScript("OnClick", function()
        HandleDirectClick(button)
    end)
    return button
end

-- 直接标记按钮：动作固定在创建时，点击时只移动锚点，不临时改属性
local function CreateMarkButton(marker, frameLevel, anchor)
    local button = createSecureButton(UIParent, 120, frameLevel)
    if not button then return nil end
    SetUnitMarkAction(button, marker, "target")
    button:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    button.Icon:SetTexture(nil)
    button:HookScript("OnClick", function()
        HandleDirectClick(button)
    end)
    return button
end

function QM:CreateRing()
    if self.overlay then return true end
    if self.secureUnavailable or inCombat() then return false end

    local overlay = CreateFrame("Frame", nil, UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetFrameLevel(1)
    overlay:EnableMouse(false)
    overlay:Hide()
    self.overlay = overlay
    local frameLevel = overlay:GetFrameLevel() + 10

    local ring = CreateFrame("Frame", nil, UIParent)
    ring:SetSize(RING_SIZE, RING_SIZE)
    ring:SetFrameStrata("MEDIUM")
    ring:SetFrameLevel(1)
    ring:SetClampedToScreen(true)
    -- 让环下方的名称/提示也能留在屏幕内
    ring:SetClampRectInsets(-30, 30, 0, -60)
    ring:Hide()
    self.ring = ring

    -- 视觉层：圆盘、圆环和环下方的名称/提示。它只是普通框体，
    -- 可以随意缩放、调透明度；安全按钮在更高的层上，不受它影响。
    local art = CreateFrame("Frame", nil, ring)
    art:SetSize(RING_SIZE, RING_SIZE)
    art:SetPoint("CENTER")
    art:SetFrameLevel(ring:GetFrameLevel())
    self.ringArt = art
    art.shadow1 = RingCircle(art, 0, 184, 0, 0, 0, 0.30)
    art.shadow2 = RingCircle(art, 1, 166, 0, 0, 0, 0.35)
    art.rim     = RingCircle(art, 2, 158, 0.32, 0.32, 0.38, 1)
    art.bg      = RingCircle(art, 3, 156, 0.06, 0.06, 0.08, 0.94)
    art.track   = RingCircle(art, 4, 71, 0.20, 0.20, 0.24, 1)
    art.inner   = RingCircle(art, 5, 69, 0.06, 0.06, 0.08, 1)

    local label = art:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", art, "CENTER", 0, -(RADIUS + CHIP_SIZE / 2 + 22))
    label:SetShadowOffset(1, -1)
    self.ringLabel = label
    local hint = art:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", label, "BOTTOM", 0, -2)
    hint:SetWidth(220)
    hint:SetJustifyH("CENTER")
    hint:SetShadowOffset(1, -1)
    self.ringHint = hint

    -- 双击单位后先把 mouseover 锁成 target，保证环上的按钮作用于双击时的单位
    local locker = createSecureButton(UIParent, 1, frameLevel)
    if not locker then self.secureUnavailable = true return false end
    SetMacroAction(locker, "/target mouseover")
    locker:SetPoint("CENTER", UIParent, "CENTER", -10000, -10000)
    locker.Icon:SetTexture(nil)
    self.targetLocker = locker

    -- 直接执行效果用的隐藏按钮：和标记环的按钮一样，动作在创建时就固定下来，
    -- 双击时只做「移到光标下 + 显示 + 启用鼠标」，不再临时改属性。
    -- 信号只能走 /ping 宏（本客户端只认硬件点击）；标记走 raidtarget 安全动作，
    -- 标记环外的情况再由 SetRaidTarget 补发。
    -- 尺寸 120 比双击距离（38）大，给两次点击之间的小幅移动留余量。
    -- 所有直接点击按钮共用一个普通（非安全）锚点，双击时只移动锚点
    local directAnchor = CreateFrame("Frame", nil, UIParent)
    directAnchor:SetSize(1, 1)
    directAnchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", -10000, -10000)
    directAnchor:SetFrameStrata("FULLSCREEN_DIALOG")
    self.directAnchor = directAnchor

    local pingText = PingCommand() .. " [@target] " .. PING_TYPE

    self.pingButton = CreateDirectButton(pingText, frameLevel, directAnchor)
    if not self.pingButton then self.secureUnavailable = true return false end

    -- 信号按钮只发信号；标记由各自的安全按钮执行，点击后再用 API 兜底补发。
    -- 安全按钮一次点击只能执行一种动作，不能把 /tm 拼进同一条宏。
    self.markButtons = {}
    for index = 1, 8 do
        local markButton = CreateMarkButton(index, frameLevel, directAnchor)
        if not markButton then self.secureUnavailable = true return false end
        self.markButtons[index] = markButton
    end
    self.directButton = self.pingButton

    self.unitButtons = {}
    self.groundButtons = {}

    for index = 1, 8 do
        local angle = math.rad(90 - (index - 1) * 45)
        local px = math.cos(angle) * RADIUS
        local py = math.sin(angle) * RADIUS

        local ub = createSecureButton(UIParent, CHIP_SIZE, frameLevel)
        if not ub then self.secureUnavailable = true return false end
        -- 双击时已经把目标锁成双击的单位，环上的按钮统一作用于 target
        SetUnitMarkAction(ub, index, "target")
        ub:SetPoint("CENTER", ring, "CENTER", px, py)
        setMarkerIcon(ub.Icon, index)
        DecorateChip(ub, index)
        ub:HookScript("OnClick", function()
            VerifyUnitMark(index)
            closeAfterClick()
        end)
        self.unitButtons[index] = ub

        local marker = GROUND_MAP[index]
        local gb = createSecureButton(UIParent, CHIP_SIZE, frameLevel)
        if not gb then self.secureUnavailable = true return false end
        SetGroundMarkAction(gb, marker)
        gb:SetPoint("CENTER", ring, "CENTER", px, py)
        setMarkerIcon(gb.Icon, index)
        DecorateChip(gb, index)
        gb:HookScript("OnClick", closeAfterClick)
        self.groundButtons[index] = gb
    end

    local cu = createSecureButton(UIParent, CENTER_SIZE, frameLevel)
    if not cu then self.secureUnavailable = true return false end
    SetSecureAction(cu, "raidtarget", { action = "clear-all" })
    cu:SetPoint("CENTER", ring, "CENTER", 0, 0)
    DecorateCenter(cu)
    cu:HookScript("OnClick", closeAfterClick)
    self.clearUnitButton = cu

    local cg = createSecureButton(UIParent, CENTER_SIZE, frameLevel)
    if not cg then self.secureUnavailable = true return false end
    SetClearWorldMarkerAction(cg)
    cg:SetPoint("CENTER", ring, "CENTER", 0, 0)
    DecorateCenter(cg)
    cg:HookScript("OnClick", closeAfterClick)
    self.clearGroundButton = cg

    return true
end

function QM:HoveredIndex()
    if not self.overlay or not self.overlay:IsShown() then return nil end
    if not GetCursorPosition then return nil end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local list = ModeButtons(self, self.mode)
    if not list then return nil end
    local hit2 = HIT_RADIUS * HIT_RADIUS
    for index, button in ipairs(list) do
        local bx, by = button:GetCenter()
        if bx and (x - bx) * (x - bx) + (y - by) * (y - by) <= hit2 then
            return index
        end
    end
    return nil
end

-- 光标是否落在中心按钮上；和图标一样，用圆形判定而不是按钮矩形
function QM:CenterHovered()
    if not self.overlay or not self.overlay:IsShown() then return false end
    if not GetCursorPosition then return false end
    local center = ModeCenter(self, self.mode)
    if not center or not center:IsShown() then return false end
    local bx, by = center:GetCenter()
    if not bx then return false end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local half = CENTER_SIZE / 2
    return (x - bx) * (x - bx) + (y - by) * (y - by) <= half * half
end

-- 环下方显示当前环的用途；悬停在图标或中心时改成对应动作
function QM:UpdateRingLabel(hovered, overCenter)
    local label, hint = self.ringLabel, self.ringHint
    if not label or not hint then return end
    local ground = self.mode == "ground"
    if hovered then
        local color = MARKERS[hovered].color
        label:SetText(MarkerName(hovered))
        label:SetTextColor(color[1], color[2], color[3])
        hint:SetText(ground and "左键：放置世界光柱" or "左键：标记目标")
    elseif overCenter then
        label:SetText("清除")
        label:SetTextColor(1, 0.82, 0)
        hint:SetText(ground and "清除全部世界光柱" or "清除全部目标标记")
    else
        label:SetText(ground and "世界光柱" or "目标标记")
        label:SetTextColor(1, 1, 1)
        hint:SetText("")
    end
end

function QM:OnUpdate(elapsed)
    if not self.mode then return end
    local now = GetTime()

    local list = ModeButtons(self, self.mode)
    if not list then return end

    -- 战斗中收不掉环（不能隐藏、不能关鼠标），自动关闭推迟到脱战之后
    if not inCombat() and now - self.openedAt > AUTO_CLOSE_SECONDS then
        self:HideRing()
        return
    end

    if self.openAnimation then
        -- 展开动画只改透明度和视觉层的缩放：鼠标在 ShowRing 时已经启用，
        -- 这样动画中途进入战斗也不会去碰受保护的 EnableMouse
        local t = math.min(1, (now - self.openAnimation) / OPEN_SECONDS)
        local eased = 1 - (1 - t) * (1 - t) * (1 - t)
        for _, button in ipairs(list) do
            button:SetAlpha(0.3 + 0.7 * eased)
        end
        local center = ModeCenter(self, self.mode)
        if center then
            center:SetAlpha(eased)
        end
        if self.ringArt then
            self.ringArt:SetAlpha(eased)
            self.ringArt:SetScale(0.85 + 0.15 * eased)
        end
        if t >= 1 then
            self.openAnimation = nil
            for _, button in ipairs(list) do button:SetAlpha(1) end
            if center then center:SetAlpha(1) end
            if self.ringArt then
                self.ringArt:SetAlpha(1)
                self.ringArt:SetScale(1)
            end
        end
        return
    end

    self.nextHoverAt = self.nextHoverAt + elapsed
    if self.nextHoverAt < HOVER_UPDATE then return end
    self.nextHoverAt = 0

    local hovered = self:HoveredIndex()
    if hovered ~= self.hoveredIndex then
        self.hoveredIndex = hovered
        for index, button in ipairs(list) do
            tintButton(button, index == hovered)
        end
    end

    local overCenter = self:CenterHovered()
    if overCenter ~= self.centerHovered then
        self.centerHovered = overCenter
        SetCenterHover(ModeCenter(self, self.mode), overCenter)
    end

    if hovered ~= self.labelHovered or overCenter ~= self.labelCenter then
        self.labelHovered, self.labelCenter = hovered, overCenter
        self:UpdateRingLabel(hovered, overCenter)
    end
end

function QM:ShowRing(mode, x, y)
    if inCombat() or not IsEnabled() then return end
    if mode == "ground" and not InGroupOrRaid() then return end
    if not self:CreateRing() then return end
    self:HideRing()

    local scale = UIParent:GetEffectiveScale()
    local uiX, uiY = x / scale, y / scale

    self.ring:ClearAllPoints()
    self.ring:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
    self.ring:Show()

    self.mode = mode
    if self.ringArt then
        self.ringArt:SetAlpha(0)
        self.ringArt:SetScale(0.85)
    end
    self.hoveredIndex = nil
    self.centerHovered = nil
    self.labelHovered, self.labelCenter = nil, nil
    self:UpdateRingLabel(nil, false)

    local list = ModeButtons(self, mode)
    local center = ModeCenter(self, mode)

    -- 收起另一种环的按钮和中心键，避免残留按钮抢走这次点击
    for _, other in ipairs({ "unit", "ground" }) do
        if other ~= mode then
            local otherList = ModeButtons(self, other)
            if otherList then
                for _, button in ipairs(otherList) do hideButton(button) end
            end
        end
    end
    if mode ~= "unit" then hideButton(self.clearUnitButton) end
    if mode ~= "ground" then hideButton(self.clearGroundButton) end

    -- 鼠标在打开时就启用：展开动画只改透明度。这样即使展开到一半进入战斗，
    -- 环上的按钮也已经可以点击（战斗中再也改不了鼠标状态）
    for _, button in ipairs(list) do
        button:SetAlpha(0.25)
        button:SetScale(1)
        button:EnableMouse(true)
        button:Show()
    end
    if center then
        center:SetAlpha(0)
        center:EnableMouse(true)
        center:Show()
    end

    self.overlay:Show()
    self.openedAt = GetTime()
    self.openAnimation = self.openedAt
    self.nextHoverAt = 0
    self.hoveredIndex = nil
    self.overlay:SetScript("OnUpdate", function(_, e) QM:OnUpdate(e) end)
end

-- ---------------------------------------------------------------------------
-- 双击与信号发送
-- ---------------------------------------------------------------------------
-- 双击的两次点击由两条路各自尝试执行宏，只要有一条通就能发出去：
--   1) 第一次按下时就把安全按钮摆到光标下，抬起后启用鼠标，让第二次物理点击
--      落在按钮上，由客户端自己执行宏；
--   2) 如果第二次点击没落在按钮上（鼠标焦点是缓存的话，原地双击经常如此），
--      第二次按下会回到世界层的捕获帧，那里用 button:Click() 程序化执行同一个宏。
-- 信号按钮的宏内容是 /ping [@target] <类型>；标记部分不拼进宏，由 API 补发。
-- 按 GUID 找回双击时的单位：第二次点击时按钮压在光标下，mouseover 可能是空的，
-- target 也可能还停在别的单位上（右键/软目标等），直接标 target 会标错。
local function FindUnitByGUID(guid)
    if not guid or type(_G.UnitGUID) ~= "function" then return nil end
    local tokens = { "mouseover", "target", "focus", "targettarget" }
    for i = 1, 4 do tokens[#tokens + 1] = "party" .. i end
    if _G.IsInRaid and _G.IsInRaid() then
        for i = 1, 40 do tokens[#tokens + 1] = "raid" .. i end
    end
    for i = 1, 40 do tokens[#tokens + 1] = "nameplate" .. i end
    for _, token in ipairs(tokens) do
        if UnitExists(token) and _G.UnitGUID(token) == guid then return token end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 信号盘（修饰键 + 单击）
-- ---------------------------------------------------------------------------
-- 客户端的信号轮盘由受保护的 TOGGLEPINGLISTENER 绑定打开，插件不能直接调用
-- C_Ping.TogglePingListener。这里仿照 PingAltClick 的做法：把「修饰键 + 鼠标
-- 左键」常驻覆盖成 TOGGLEPINGLISTENER，并把 pingMode 切到「按住」模式。
-- 按住该修饰键时，把光标下会吃掉点击的框体（以及本模块的世界捕获帧）临时
-- 放行左键，点击才能到达覆盖绑定，交给游戏自己的信号监听：
--   快速点击 = 情境信号；按住不放 = 信号盘，移动鼠标选择后松开。
-- 常驻绑定只在对应修饰键按下时才匹配，不影响平时的点击。
-- 但它会让这个修饰键的第一次点击就交给游戏，所以同一修饰键的双击槽位
-- 不能和「信号盘」同时使用；面板会在选择时把双击槽位改成禁用。
local NATIVE_ACTION = "TOGGLEPINGLISTENER"
local NATIVE_BUTTON = "BUTTON1"
local NATIVE_WATCH = 0.05

local PASS_BUTTONS = { "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5" }

-- 覆盖绑定必须带上「实际按住的全部修饰键」，否则游戏匹配不到。
-- 效果选择仍然按 Ctrl > Alt > Shift 的优先级，由上面的槽位函数负责。
local function ExactModifiers()
    local parts = {}
    if IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    return table.concat(parts, "-")
end

local MOD_SLOT = {
    ALT = KEY_SLOT_MAP.Alt,
    CTRL = KEY_SLOT_MAP.Ctrl,
    SHIFT = KEY_SLOT_MAP.Shift,
}

-- 配置为「信号盘」的单击槽位，按 Ctrl、Alt、Shift 顺序
local function NativePingModifiers()
    local list = {}
    for _, name in ipairs({ "CTRL", "ALT", "SHIFT" }) do
        local slot = MOD_SLOT[name]
        if slot and GetClickAction(slot) == NATIVE_EFFECT then
            list[#list + 1] = name
        end
    end
    return list
end

-- 当前按住的修饰键是否正好是某个信号盘槽位。
-- 多按或漏按修饰键都不算：覆盖绑定按完整组合匹配。
local function NativePingHeldModifier()
    local mods = ExactModifiers()
    local slot = MOD_SLOT[mods]
    if not slot then return nil end
    if GetClickAction(slot) ~= NATIVE_EFFECT then return nil end
    return mods
end

-- 信号盘是否正在接管这次点击（模块和游戏信号系统都开启时）
function QM:NativeSignalHeld()
    if not IsEnabled() or not PingSystemEnabled() then return false end
    return NativePingHeldModifier() ~= nil
end

local function TakesClicks(frame)
    if type(frame) ~= "table" then return false end
    local fn = frame.IsMouseClickEnabled or frame.IsMouseEnabled
    if type(fn) ~= "function" then return false end
    local ok, enabled = pcall(fn, frame)
    return ok and enabled == true
end

local function PassesButton(frame, button)
    if type(frame.ShouldButtonPassThrough) ~= "function" then return nil end
    local ok, passes = pcall(frame.ShouldButtonPassThrough, frame, button)
    if not ok then return nil end
    return passes and true or false
end

-- 让一个框体放行左键：优先只让左键穿透（不影响框体的其他点击），
-- 客户端不支持时再整体关掉鼠标点击。返回恢复时需要的信息。
local function SuppressFrame(frame)
    if type(frame) ~= "table" then return nil end
    if type(frame.IsForbidden) == "function" then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if not ok or forbidden then return nil end
    end

    if type(frame.SetPassThroughButtons) == "function" and type(frame.ShouldButtonPassThrough) == "function" then
        if PassesButton(frame, "LeftButton") then return nil end
        local prev = {}
        for _, button in ipairs(PASS_BUTTONS) do
            if PassesButton(frame, button) then prev[#prev + 1] = button end
        end
        local list = {}
        for _, button in ipairs(prev) do list[#list + 1] = button end
        list[#list + 1] = "LeftButton"
        if pcall(frame.SetPassThroughButtons, frame, unpack(list))
            and PassesButton(frame, "LeftButton") then
            return { frame = frame, mode = "pass", prev = prev }
        end
    end

    if type(frame.IsMouseClickEnabled) == "function" and type(frame.SetMouseClickEnabled) == "function" then
        local ok, enabled = pcall(frame.IsMouseClickEnabled, frame)
        if ok and enabled and pcall(frame.SetMouseClickEnabled, frame, false) then
            return { frame = frame, mode = "click" }
        end
    end
    return nil
end

-- 恢复后回读一次，受保护函数在战斗锁定期间会静默失败
local function FrameRestored(entry)
    local frame = entry.frame
    if type(frame) ~= "table" then return true end
    if entry.mode == "pass" then
        if type(frame.ShouldButtonPassThrough) ~= "function" then return true end
        return PassesButton(frame, "LeftButton") == false
    elseif entry.mode == "click" then
        if type(frame.IsMouseClickEnabled) ~= "function" then return true end
        local ok, enabled = pcall(frame.IsMouseClickEnabled, frame)
        return ok and enabled == true
    end
    return true
end

local function RestoreFrame(entry)
    if not entry then return true end
    local frame = entry.frame
    if entry.mode == "pass" then
        if type(frame.SetPassThroughButtons) == "function" then
            pcall(frame.SetPassThroughButtons, frame, unpack(entry.prev or {}))
        end
    elseif entry.mode == "click" then
        if type(frame.SetMouseClickEnabled) == "function" then
            pcall(frame.SetMouseClickEnabled, frame, true)
        end
    end
    return FrameRestored(entry)
end

-- 光标下会吃掉这次点击的框体（含它们的父框体）。
-- 世界、穿透的姓名板、世界捕获框都不会吃掉点击，不需要处理。
local function ClickableFramesUnderCursor()
    if type(_G.GetMouseFoci) ~= "function" then return nil end
    local ok, foci = pcall(_G.GetMouseFoci)
    if not ok or type(foci) ~= "table" then return nil end
    local seen, frames = {}, {}
    for index = 1, math.min(#foci, 8) do
        local frame = foci[index]
        for _ = 1, 4 do
            if type(frame) ~= "table" then break end
            if not seen[frame] then
                seen[frame] = true
                if TakesClicks(frame) then frames[#frames + 1] = frame end
            end
            if type(frame.GetParent) ~= "function" then break end
            local okParent, parent = pcall(frame.GetParent, frame)
            if not okParent then break end
            frame = parent
        end
    end
    return frames
end

-- 只把真正恢复成功的项从列表里去掉；战斗锁定期间调用失败会留到脱战后重试
function QM:RestoreNativeFrames()
    if not self.nativeFrames then return end
    local pending = {}
    for _, entry in ipairs(self.nativeFrames) do
        if not RestoreFrame(entry) then pending[#pending + 1] = entry end
    end
    self.nativeFrames = #pending > 0 and pending or nil
end

-- 增量屏蔽：按住修饰键期间光标可能移到别的框体上，新的框体也要一起放行
function QM:SuppressNativeFrames(frames)
    if type(frames) ~= "table" then return end
    local list = self.nativeFrames or {}
    local known = {}
    for _, entry in ipairs(list) do known[entry.frame] = true end
    for _, frame in ipairs(frames) do
        if not known[frame] then
            local entry = SuppressFrame(frame)
            if entry then
                list[#list + 1] = entry
                known[frame] = true
            end
        end
    end
    if #list > 0 then self.nativeFrames = list end
end

-- 装/撤信号盘的常驻覆盖绑定。战斗锁定期间推迟到脱战后处理。
function QM:ApplyNativeSignal()
    if inCombat() then
        self.nativeApplyPending = true
        return
    end
    self.nativeApplyPending = nil
    local mods = (IsEnabled() and PingSystemEnabled()) and NativePingModifiers() or {}
    if not self.nativeBinder then
        local ok, binder = pcall(CreateFrame, "Frame")
        if ok then self.nativeBinder = binder end
    end
    if self.nativeBinder then
        pcall(ClearOverrideBindings, self.nativeBinder)
        for _, name in ipairs(mods) do
            pcall(SetOverrideBinding, self.nativeBinder, true,
                name .. "-" .. NATIVE_BUTTON, NATIVE_ACTION)
        end
    end
    if #mods > 0 then
        self:ForceHoldPingMode()
    else
        self:RestoreHoldPingMode()
        self:ReleaseNativeSignalFrames()
    end
end

-- 原生监听只有在「按住」模式（pingMode = 0）下才会展开轮盘。
-- 原值存进本模块设置里，关闭信号盘或整个模块时恢复。
function QM:ForceHoldPingMode()
    if type(_G.GetCVar) ~= "function" or type(_G.SetCVar) ~= "function" then return end
    local ok, value = pcall(_G.GetCVar, "pingMode")
    if not ok then return end
    local mode = Plain(value)
    mode = mode ~= nil and tostring(mode) or ""
    if mode == "" then return end
    local opts = GetOptions()
    if opts.nativePingMode == nil and mode ~= "0" then
        opts.nativePingMode = mode
    end
    if mode ~= "0" then pcall(_G.SetCVar, "pingMode", 0) end
end

function QM:RestoreHoldPingMode()
    local opts = GetOptions()
    local mode = opts.nativePingMode
    if mode == nil then return end
    opts.nativePingMode = nil
    if type(_G.GetCVar) ~= "function" or type(_G.SetCVar) ~= "function" then return end
    local ok, current = pcall(_G.GetCVar, "pingMode")
    local text = ok and Plain(current) or nil
    if text ~= nil and tostring(text) == "0" then
        pcall(_G.SetCVar, "pingMode", mode)
    end
end

-- 按住信号盘的修饰键期间，光标可能移到别的框体上：
-- 持续把新的框体也一起放行，否则那一次点击会被框体吃掉。
function QM:StartNativeSignalWatch()
    if self.nativeWatchToken then return end
    local token = {}
    self.nativeWatchToken = token
    local function check()
        if QM.nativeWatchToken ~= token then return end
        if not QM:NativeSignalHeld() or inCombat() then
            QM.nativeWatchToken = nil
            return
        end
        QM:SuppressNativeFrames(ClickableFramesUnderCursor())
        if QM.captureFrame then QM:SuppressNativeFrames({ QM.captureFrame }) end
        if C_Timer and C_Timer.After then C_Timer.After(NATIVE_WATCH, check) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(NATIVE_WATCH, check) end
end

-- 修饰键松开或不再匹配：恢复框体点击。受保护调用在战斗里可能失败，
-- 失败的项会留在列表里，脱战后由 FlushNativeClear 再恢复一次。
function QM:ReleaseNativeSignalFrames()
    self.nativeWatchToken = nil
    self:RestoreNativeFrames()
    self.nativeClearPending = (inCombat() or self.nativeFrames) and true or nil
end

-- 修饰键状态变化时更新放行列表；战斗里改不了受保护的鼠标状态，
-- 世界/地面点击仍然能走到覆盖绑定。
function QM:SyncNativeSignalFrames()
    if inCombat() then return end
    if self:NativeSignalHeld() then
        self:SuppressNativeFrames(ClickableFramesUnderCursor())
        if self.captureFrame then self:SuppressNativeFrames({ self.captureFrame }) end
        self:StartNativeSignalWatch()
    else
        self:ReleaseNativeSignalFrames()
    end
end

function QM:FlushNativeClear()
    if not self.nativeClearPending or inCombat() then return end
    self:RestoreNativeFrames()
    self.nativeClearPending = self.nativeFrames and true or nil
end

-- 标记走 API 补一次：程序化点击安全按钮时客户端不会执行受保护动作；
-- SetRaidTarget 在非战斗状态下可以直接调用，所以不依赖哪条点击路径成功。
function QM:ApplyPendingMark()
    local marker = self.pendingMark
    if not marker then return end
    self.pendingMark = nil
    local guid = self.pendingMarkGUID
    local preferred = self.pendingUnit
    self.pendingMarkGUID, self.pendingUnit = nil, nil
    if inCombat() or not IsEnabled() then return end

    -- 优先用双击时直接识别到的单位框体单位；它已经失效或换了单位时再按 GUID 找
    local unit
    if preferred then
        local okExists, exists = pcall(UnitExists, preferred)
        if okExists and exists then
            local guidOk = true
            if guid and type(_G.UnitGUID) == "function" then
                local okGuid, currentGUID = pcall(_G.UnitGUID, preferred)
                guidOk = okGuid and currentGUID == guid
            end
            if guidOk then unit = preferred end
        end
    end
    unit = unit or FindUnitByGUID(guid)
    if not unit then
        if UnitExists("mouseover") then
            unit = "mouseover"
        elseif UnitExists("target") then
            unit = "target"
        end
    end
    if not unit then return end

    -- 硬件点击路径已经标上同一个标记时不再重复；标着别的标记时仍然改成默认标记
    if type(_G.GetRaidTargetIndex) == "function" then
        local ok, current = pcall(_G.GetRaidTargetIndex, unit)
        current = ok and Plain(current) or nil
        if current == marker then return end
    end
    if type(_G.SetRaidTarget) ~= "function" then return end
    pcall(_G.SetRaidTarget, unit, marker)
end

-- 把全部直接按钮收回（战斗中 Show/Hide/EnableMouse 受保护，失败时下次再收）
function QM:DisableAllDirect()
    DisableDirectButton(self.pingButton)
    if self.markButtons then
        for _, button in ipairs(self.markButtons) do DisableDirectButton(button) end
    end
end

function QM:DisarmPing()
    self.pingToken = nil
    self.pingConsumed = nil
    self.buttonEnabled = nil
    self.pendingMark = nil
    self.pendingMarkGUID = nil
    self.pendingUnit = nil
    self.armedEffect, self.armedX, self.armedY = nil, nil, nil
    self.lastClickAt, self.lastX, self.lastY = nil, nil, nil
    self.clickPending = nil
    self:DisableAllDirect()
end

-- 第一次按下时准备：记下单位、把按钮摆到光标下（先不启用鼠标）。
-- effect 为 EFFECTS 中的一条；只有带 ping / mark 的效果才需要这个按钮。
-- unit 是光标下单位框体的单位；从世界/姓名板双击时为空，沿用 mouseover。
function QM:PrepareEffect(effect, x, y, unit)
    if not effect or not IsEnabled() or inCombat() then return end
    if not x or not y or not GetCursorPosition then return end
    if not self:CreateRing() then return end

    -- 目标在第一次抬起时再锁（见 EnableArmedButton）：那时按钮还没启用鼠标，
    -- mouseover 仍然有效，也不会被拖视角误触发。

    -- 动作在创建时就固定好了，这里只挑对应效果的那个按钮
    local marker = effect.mark and GetDefaultMarker() or nil
    local button
    if effect.ping then
        button = self.pingButton
    elseif marker then
        button = self.markButtons and self.markButtons[marker]
    end
    if not button then return end

    -- 布置前把它们全部收掉：所有直接按钮叠在同一个锚点下，
    -- 只要有一个残留启用状态，就会抢走这次点击并执行错的动作
    self:DisableAllDirect()
    self.directButton = button

    -- 标记的 API 补发在点击真正发生时做，这里先记下要用的标记和双击时的单位
    self.pendingMark = effect.mark and GetDefaultMarker() or nil
    -- 世界点击只记 GUID（第二次点击时按钮压在光标下，mouseover 可能已变），
    -- 框体点击则直接记住具体的单位 token，锁目标时也用它。
    self.pendingUnit = (unit and unit ~= "mouseover") and unit or nil
    self.pendingMarkGUID = nil
    if effect.mark and type(_G.UnitGUID) == "function" then
        local okGuid, guid = pcall(_G.UnitGUID, unit or "mouseover")
        self.pendingMarkGUID = okGuid and Plain(guid) or nil
    end
    -- 每次重新布置都清掉上一次的消耗标记，否则硬件路径成功过一次后，
    -- 下一次的补发会被误判成“已经执行过”
    self.pingConsumed = nil
    self.buttonEnabled = nil

    local anchor = self.directAnchor
    if anchor then
        local scale = UIParent:GetEffectiveScale() or 1
        anchor:ClearAllPoints()
        anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end
    button:SetAlpha(0)
    pcall(button.EnableMouse, button, false)

    self.armedEffect = effect.key
    self.armedX, self.armedY = x, y

    -- 从按下算起一个完整的双击窗口，到点自动收掉。
    -- 修饰键单击要等在双击窗口结束后才执行，按住不放时它会排在这个时间之后，
    -- 所以有等待执行的单击时先不收，由执行路径收尾。
    local token = {}
    self.pingToken = token
    if C_Timer and C_Timer.After then
        C_Timer.After(DOUBLE_SECONDS + 0.12, function()
            if QM.pingToken ~= token then return end
            if not QM.clickPending then
                QM:DisarmPing()
                return
            end
            -- 抬起事件可能没送达，单击就不会执行；给按钮一个上限，
            -- 避免它一直停在光标下备战
            C_Timer.After(2, function()
                if QM.pingToken ~= token then return end
                QM.clickPending = nil
                QM:DisarmPing()
            end)
        end)
    end
end

-- 第一次抬起：把准备好的按钮启用，给第二次物理点击一个落在按钮上的机会
function QM:EnableArmedButton()
    if not self.armedEffect then return end
    local button = self.directButton
    if not button or inCombat() or not GetCursorPosition then return end

    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1

    -- 按下到抬起之间光标跑远了说明是在拖动视角，不当作点击处理
    if self.lastX and self.lastY then
        local maxDist = DOUBLE_DISTANCE * scale
        local dx, dy = x - self.lastX, y - self.lastY
        if dx * dx + dy * dy > maxDist * maxDist then return end
    end

    -- 趁按钮还没启用鼠标时先锁目标（此时 mouseover 仍指向世界单位）。
    -- 双击单位框体时已知具体单位，优先直接锁它，避免 mouseover 被其他框体抢走。
    local locked = false
    if self.pendingUnit and type(_G.TargetUnit) == "function" then
        local ok, exists = pcall(UnitExists, self.pendingUnit)
        if ok and exists then
            locked = pcall(_G.TargetUnit, self.pendingUnit)
        end
    end
    if not locked then
        local okUnit, onUnit = pcall(UnitExists, "mouseover")
        if okUnit and onUnit and self.targetLocker then
            pcall(self.targetLocker.Click, self.targetLocker)
        end
    end

    self.armedX, self.armedY = x, y
    local anchor = self.directAnchor
    if anchor then
        anchor:ClearAllPoints()
        anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end
    button:SetAlpha(1)
    pcall(button.EnableMouse, button, true)
    self.buttonEnabled = true
end

-- 修饰键 + 单击：双击窗口内没有第二次按下时执行。
-- 先锁目标，再按“单击槽位”自己的效果挑按钮；单击效果可能和第一次按下时
-- 为双击准备的那个按钮不同，所以这里重新选择，而不是复用 self.directButton。
-- 只有标记环的效果没有安全按钮，直接在点击位置开环。
function QM:RunSingleClick(pending)
    if not pending or inCombat() or not IsEnabled() or self.mode then
        self:DisarmPing()
        return
    end
    local effect = EFFECT_MAP[pending.effect]
    if not effect then
        self:DisarmPing()
        return
    end

    -- 锁目标：框体点击直接锁那个单位；世界点击沿用 mouseover
    local locked = false
    if pending.unit and pending.unit ~= "mouseover" and type(_G.TargetUnit) == "function" then
        local ok, exists = pcall(UnitExists, pending.unit)
        if ok and exists then
            locked = pcall(_G.TargetUnit, pending.unit)
        end
    end
    if not locked then
        local ok, onUnit = pcall(UnitExists, "mouseover")
        if ok and onUnit and self.targetLocker then
            pcall(self.targetLocker.Click, self.targetLocker)
        end
    end

    if effect.ring then
        self:ShowRing("unit", pending.x, pending.y)
        self:DisarmPing()
        return
    end

    local widget
    if effect.ping then
        widget = self.pingButton
    elseif effect.mark then
        local marker = GetDefaultMarker()
        -- 第一次按下准备的可能是双击槽位的效果；这里按单击效果重设补发信息
        self.pendingMark = marker
        self.pendingUnit = (pending.unit and pending.unit ~= "mouseover")
            and pending.unit or nil
        self.pendingMarkGUID = pending.guid
        self:ApplyPendingMark()
        widget = self.markButtons and self.markButtons[marker]
    end
    if widget then
        pcall(widget.Click, widget)
    end
    self:DisarmPing()
end

-- button 是鼠标键；unit 是光标下单位框体的单位（世界/姓名板点击时为空）。
function QM:HandleMouseDown(button, unit)
    if button ~= "LeftButton" then return end
    if inCombat() then
        -- 战斗中不可能新开/收起环，已打开的环保持不动
        self.lastClickAt, self.lastX, self.lastY, self.pendingOpen = nil, nil, nil, nil
        return
    end
    if not IsEnabled() then
        self.lastClickAt, self.lastX, self.lastY, self.pendingOpen = nil, nil, nil, nil
        if self.mode then self:HideRing() end
        return
    end
    if not GetCursorPosition then return end
    local x, y = GetCursorPosition()
    local now = GetTime()

    -- 这个修饰键按住了信号盘：点击已经交给游戏的信号监听，
    -- 不再参与双击/单击判定，避免同一次点击执行两遍。
    if self:NativeSignalHeld() then
        self.lastClickAt, self.lastX, self.lastY = nil, nil, nil
        self.pendingOpen = nil
        self.clickPending = nil
        return
    end

    local timeOk = self.lastClickAt and (now - self.lastClickAt) <= DOUBLE_SECONDS
    local distOk = false
    if timeOk then
        local scale = UIParent:GetEffectiveScale() or 1
        local maxDist = DOUBLE_DISTANCE * scale
        local dx = x - (self.lastX or x)
        local dy = y - (self.lastY or y)
        distOk = (dx * dx + dy * dy) <= (maxDist * maxDist)
    end
    if timeOk and distOk then
        self.lastClickAt = nil
        self.pendingOpen = nil
        -- 这是双击，取消等待中的修饰键单击
        self.clickPending = nil
        local okUnit, exists = false, false
        if unit then okUnit, exists = pcall(UnitExists, unit) end
        local onUnit = okUnit and exists
        if not onUnit then
            local ok, hasUnit = pcall(UnitExists, "mouseover")
            onUnit = ok and hasUnit or false
            unit = onUnit and "mouseover" or nil
        end

        -- 双击单位：执行所选效果；双击空地：在队伍或团队中打开世界光柱环。
        -- 第二次点击能走到这里，说明它没落在隐藏按钮上（原地双击时客户端常用
        -- 缓存的鼠标焦点，按钮经常收不到这次点击）。这里直接用程序化点击执行
        -- 第一次按下时准备好的动作；执行完立刻收掉按钮，避免这次点击的抬起
        -- 又落到按钮上造成重复触发。
        local slotEffect = SlotEffectKey()
        local effect = EFFECT_MAP[ResolveEffect(slotEffect)]
        if self.armedEffect then
            -- 这里不再检查 mouseover：按钮就压在光标下，mouseover 很可能已经是空的，
            -- 但第一次抬起时已经把目标锁好了
            local buttonWidget = self.directButton
            if self.pingConsumed then
                -- 按钮已经处理过这次点击（硬件在前、捕获在后），这里只负责收尾
                self:DisarmPing()
            elseif buttonWidget and not self.buttonEnabled then
                -- 按钮没启用（例如拖动判定没通过）：只能程序化补发一次。
                -- 按钮已经启用时不再补发，避免抢在按钮的硬件点击前面把它收掉。
                if self.pendingUnit and type(_G.TargetUnit) == "function" then
                    pcall(_G.TargetUnit, self.pendingUnit)
                end
                pcall(buttonWidget.Click, buttonWidget)
                self:DisarmPing()
            end
        elseif onUnit then
            if effect and effect.ring and self:CreateRing() then
                -- 点环上按钮前先把双击时的单位锁成 target
                if unit ~= "mouseover" and type(_G.TargetUnit) == "function" then
                    pcall(_G.TargetUnit, unit)
                elseif self.targetLocker then
                    pcall(self.targetLocker.Click, self.targetLocker)
                end
                self.pendingOpen = { mode = "unit", x = x, y = y, at = now }
            end
        elseif slotEffect ~= DISABLED_EFFECT and InGroupOrRaid() and self:CreateRing() then
            -- 当前修饰键对应的槽位被禁用时，双击空地也不开光柱环
            self.pendingOpen = { mode = "ground", x = x, y = y, at = now }
        end
    else
        -- 新的一次单击：先收掉上一轮可能残留的按钮，再从零开始
        self:DisarmPing()
        self.lastClickAt, self.lastX, self.lastY = now, x, y
        -- 第一次按下就准备好按钮：不依赖抬起事件是否送达
        local ok, hasUnit = pcall(UnitExists, unit or "mouseover")
        if ok and hasUnit then
            unit = unit or "mouseover"
        else
            unit = nil
        end
        local effect = EFFECT_MAP[EffectForClick()]
        if unit and effect and (effect.ping or effect.mark) then
            self:PrepareEffect(effect, x, y, unit)
        end

        -- 修饰键 + 单击：记下这次点击，抬起后等双击窗口过去再执行。
        -- 单击效果独立于双击槽位，可能和上面准备的按钮不是同一个效果。
        local clickKey = ClickEffectKey()
        local clickEffect = clickKey and EFFECT_MAP[ResolveEffect(clickKey)]
        self.clickPending = nil
        if unit and clickEffect then
            local guid
            if type(_G.UnitGUID) == "function" then
                local okGuid, value = pcall(_G.UnitGUID, unit)
                guid = okGuid and Plain(value) or nil
            end
            self.clickPending = {
                effect = clickEffect.key,
                unit = unit,
                guid = guid,
                x = x,
                y = y,
            }
        end
    end
end

function QM:HandleMouseUp(button, unit)
    if button ~= "LeftButton" then return end

    -- 修饰键 + 单击：抬起后等双击窗口过去再执行。
    -- 计时从第一次按下算起，和双击判定共用一个窗口；第二次按下会取消它。
    local pending = self.clickPending
    if pending then
        local delay = DOUBLE_SECONDS
        if self.lastClickAt then
            delay = math.max(0, DOUBLE_SECONDS - (GetTime() - self.lastClickAt))
        end
        local function fire()
            if QM.clickPending ~= pending then return end
            QM.clickPending = nil
            QM:RunSingleClick(pending)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(delay, fire)
        else
            fire()
        end
    end

    -- 第一次点击抬起：把按下时准备好的按钮启用，接第二次物理点击
    if self.armedEffect and not self.buttonEnabled and self.lastClickAt
        and (GetTime() - self.lastClickAt) <= DOUBLE_SECONDS and not self.mode then
        -- 不能在抬起事件里直接启用：客户端会把这次抬起当成落在按钮上的一次点击，
        -- 这种“按下不在按钮上、抬起才出现”的点击会触发 OnClick，却执行不了
        -- 标记/光柱这类受保护动作（/ping 是普通聊天命令，所以看起来只是标记失效）。
        -- 推迟到本帧结束再启用，让第二次点击成为按钮收到的完整按下+抬起。
        local token = self.pingToken
        local function enable()
            if QM.pingToken == token and QM.armedEffect and not QM.buttonEnabled then
                QM:EnableArmedButton()
            end
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, enable)
        else
            self:EnableArmedButton()
        end
        return
    end

    -- 第二次点击抬起（按钮已经启用过）：按钮注册的是「抬起触发」时，如果抬起点击
    -- 也没落到按钮上，就在这里程序化补发一次；已经由按钮执行过的只做收尾
    if self.armedEffect and self.buttonEnabled and not self.mode then
        local direct = self.directButton
        if direct and not direct.useDown and not self.pingConsumed then
            pcall(direct.Click, direct)
        end
        self:DisarmPing()
    end

    local pending = self.pendingOpen
    self.pendingOpen = nil
    if not pending or GetTime() - pending.at > 1 then return end
    if inCombat() or not IsEnabled() then return end
    if C_Timer then
        C_Timer.After(0, function()
            if inCombat() or not IsEnabled() then return end
            QM:ShowRing(pending.mode or "unit", pending.x, pending.y)
        end)
    else
        self:ShowRing(pending.mode or "unit", pending.x, pending.y)
    end
end

-- ---------------------------------------------------------------------------
-- 单位框体点击
-- ---------------------------------------------------------------------------
-- 世界和穿透的姓名板由下面的捕获帧处理；队伍/团队/目标框体等会吃掉点击，
-- 世界捕获帧收不到，所以另外监听全局鼠标事件，识别光标下的单位框体。
-- 单位框体把单位写在 unit 属性里（暴雪框体）或 unit 字段里（部分第三方框体）
local function FrameUnit(frame)
    if type(frame) ~= "table" then return nil end
    if type(frame.IsForbidden) == "function" then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if not ok or forbidden then return nil end
    end
    if type(frame.GetAttribute) == "function" then
        local ok, unit = pcall(frame.GetAttribute, frame, "unit")
        unit = ok and Plain(unit) or nil
        if type(unit) == "string" and unit ~= "" then return unit end
    end
    local unit = Plain(rawget(frame, "unit"))
    if type(unit) == "string" and unit ~= "" then return unit end
    return nil
end

-- 只认真正会吃掉这次点击的帧：鼠标穿透的姓名板等仍然交给世界捕获帧，
-- 否则同一次点击会被两条路各处理一遍。
function QM:UnitUnderMouse()
    if type(_G.GetMouseFoci) ~= "function" then return nil end
    local ok, foci = pcall(_G.GetMouseFoci)
    if not ok or type(foci) ~= "table" then return nil end
    for index = 1, math.min(#foci, 4) do
        local focus = foci[index]
        if TakesClicks(focus) then
            local frame = focus
            for _ = 1, 4 do
                if type(frame) ~= "table" then return nil end
                local unit = FrameUnit(frame)
                if unit then return unit end
                local okParent, parent = pcall(frame.GetParent, frame)
                if not okParent then return nil end
                frame = parent
            end
            return nil
        end
    end
    return nil
end

local globalMouse = CreateFrame("Frame")
globalMouse:RegisterEvent("GLOBAL_MOUSE_DOWN")
globalMouse:RegisterEvent("GLOBAL_MOUSE_UP")
globalMouse:SetScript("OnEvent", function(_, event, button)
    if button ~= "LeftButton" then return end
    if event == "GLOBAL_MOUSE_DOWN" then
        if not IsEnabled() or inCombat() then return end
        -- 信号盘：这个修饰键按住时点击已经交给游戏的信号监听
        if QM:NativeSignalHeld() then
            QM.lastClickAt, QM.lastX, QM.lastY = nil, nil, nil
            QM.clickPending = nil
            if QM.mode then QM:HideRing() end
            return
        end
        if QM.mode then
            if not QM:HitAnyButton() then QM:HideRing() end
            return
        end
        local unit = QM:UnitUnderMouse()
        QM.globalUnit = unit
        if unit then QM:HandleMouseDown(button, unit) end
    else
        if QM:NativeSignalHeld() then
            QM.globalUnit = nil
            return
        end
        local unit = QM.globalUnit
        QM.globalUnit = nil
        if unit and not inCombat() and QM:UnitUnderMouse() == unit then
            QM:HandleMouseUp(button, unit)
        end
    end
end)

do
    local capture = CreateFrame("Frame", nil, UIParent)
    capture:SetAllPoints(WorldFrame)
    capture:SetFrameStrata("BACKGROUND")
    capture:SetFrameLevel(0)
    if capture.SetPropagateMouseClicks then
        if capture.SetMouseMotionEnabled then capture:SetMouseMotionEnabled(false) end
        if capture.SetMouseClickEnabled then capture:SetMouseClickEnabled(true)
        else capture:EnableMouse(true) end
        capture:SetPropagateMouseClicks(true)
        if capture.SetPropagateMouseMotion then capture:SetPropagateMouseMotion(true) end
        capture:SetScript("OnMouseDown", function(_, btn)
            if btn == "LeftButton" and QM.mode and not QM:HitAnyButton() then
                -- 战斗中关不掉环，点击环外只当普通世界点击
                if not inCombat() then QM:HideRing() end
                return
            end
            QM:HandleMouseDown(btn)
        end)
        capture:SetScript("OnMouseUp", function(_, btn)
            QM:HandleMouseUp(btn)
        end)
        capture:Show()
        -- 信号盘期间要让它也放行左键，否则点击会停在捕获帧上，到不了覆盖绑定
        QM.captureFrame = capture
    else
        capture:Hide()
        if WorldFrame.HookScript then
            WorldFrame:HookScript("OnMouseDown", function(_, btn)
                if btn == "LeftButton" and QM.mode and not QM:HitAnyButton() then
                    -- 战斗中关不掉环，点击环外只当普通世界点击
                    if not inCombat() then QM:HideRing() end
                    return
                end
                QM:HandleMouseDown(btn)
            end)
            WorldFrame:HookScript("OnMouseUp", function(_, btn)
                QM:HandleMouseUp(btn)
            end)
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("MODIFIER_STATE_CHANGED")
events:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if IsEnabled() and not inCombat() then
            QM:CreateRing()
            QM:HideRing()
        end
        QM:ApplyNativeSignal()
    elseif event == "MODIFIER_STATE_CHANGED" then
        if IsEnabled() then QM:SyncNativeSignalFrames() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- 已经打开的标记环继续保留：环上的按钮是安全按钮，战斗中的硬件点击
        -- 仍然能执行标记。战斗中无法移动/展开环，收起请求推迟到脱战。
        QM:DisarmPing()
        QM.nativeWatchToken = nil
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 战斗中 Show/Hide 受保护，出战斗后再收一次
        QM:DisarmPing()
        QM:FlushNativeClear()
        if QM.nativeApplyPending then QM:ApplyNativeSignal() end
        -- 战斗里松开修饰键时改不了框体鼠标状态，脱战后按当前按键状态补齐
        QM:SyncNativeSignalFrames()
        if QM.closePending then
            QM.closePending = nil
            QM:HideRing()
        elseif QM.mode then
            -- 环在战斗中保留下来了，脱战后重新给一个完整的自动关闭时间
            QM.openedAt = GetTime()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- 二级设置页
-- ---------------------------------------------------------------------------
local function BuildQuickMarkPanel(parent)
    local MakeHeading = Utils.MakeHeading
    local MakeLabel = Utils.MakeLabel
    local CreateDropdown = Utils.CreateDropdown

    local EFFECT_OPTIONS = { { key = DISABLED_EFFECT, label = DISABLED_LABEL } }
    for _, effect in ipairs(EFFECTS) do
        EFFECT_OPTIONS[#EFFECT_OPTIONS + 1] = { key = effect.key, label = effect.label }
    end

    -- 双击槽位：信号 / 默认标记 / 标记环 / 禁用。
    -- 信号盘要求点击在按下前就由覆盖绑定接管，双击做不到，所以只给单击槽位。
    local CLICK_EFFECT_OPTIONS = { { key = DISABLED_EFFECT, label = DISABLED_LABEL } }
    for _, effect in ipairs(EFFECTS) do
        CLICK_EFFECT_OPTIONS[#CLICK_EFFECT_OPTIONS + 1] = { key = effect.key, label = effect.label }
    end
    CLICK_EFFECT_OPTIONS[#CLICK_EFFECT_OPTIONS + 1] = { key = NATIVE_EFFECT, label = NATIVE_LABEL }

    -- 顶部冲突说明：单击和双击共用同一个判定窗口，信号盘还会占用双击槽位
    local conflict = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    conflict:SetPoint("TOPLEFT", 0, 0)
    conflict:SetWidth(510)
    conflict:SetJustifyH("LEFT")
    conflict:SetJustifyV("TOP")
    conflict:SetText("同一修饰键的单击和双击共用一次点击：普通单击会稍慢一步生效。"
        .. "选择“信号盘”会自动关闭该键的双击效果，"
        .. "给双击选了效果也会取消“信号盘”。")

    MakeHeading(parent, "双击动作", 82, -52)
    MakeHeading(parent, "单击动作", 262, -52)

    local function AddEffectRow(slot, y, labelText, tip, getValue, setOption)
        MakeLabel(parent, labelText, 0, y - 7)
        return CreateDropdown(parent, 82, y, 170, tip, EFFECT_OPTIONS, getValue,
            function(key)
                setOption(key)
                -- 同一修饰键的双击和信号盘不能共存：选了双击效果就关掉信号盘
                if slot and key ~= DISABLED_EFFECT and GetClickAction(slot) == NATIVE_EFFECT then
                    SetOption("click" .. slot.key, DISABLED_EFFECT)
                    QM:ApplyNativeSignal()
                end
                if UpdatePanel then UpdatePanel() end
            end)
    end

    local actionDropdown = AddEffectRow(nil, -74, "默认双击",
        "不按修饰键双击单位时触发的效果。",
        function() return GetAction() end,
        function(key) SetOption("action", key) end)

    -- 每个修饰键一行：左边双击、右边单击，两种手势独立配置
    local PANEL_SLOTS = { KEY_SLOT_MAP.Alt, KEY_SLOT_MAP.Ctrl, KEY_SLOT_MAP.Shift }
    local doubleDropdowns, clickDropdowns = {}, {}
    for index, slot in ipairs(PANEL_SLOTS) do
        local y = -106 - (index - 1) * 32
        doubleDropdowns[slot.key] = AddEffectRow(slot, y, slot.label,
            "按住 " .. slot.label .. " 双击单位时触发的效果。",
            function() return slot.double() end,
            function(key) SetOption(slot.option, key) end)
        clickDropdowns[slot.key] = CreateDropdown(parent, 262, y, 170,
            "按住 " .. slot.label .. " 单击时触发的效果。"
            .. "普通效果会稍慢一步生效，且只在战斗外触发。"
            .. "选择“信号盘”后由游戏直接响应：点一下发送信号，"
            .. "按住不动打开信号盘，移动鼠标选择后松开。",
            CLICK_EFFECT_OPTIONS,
            function() return GetClickAction(slot) end,
            function(key)
                SetOption("click" .. slot.key, key)
                if key == NATIVE_EFFECT then
                    SetOption(slot.option, DISABLED_EFFECT)
                end
                QM:ApplyNativeSignal()
                if UpdatePanel then UpdatePanel() end
            end)
    end

    MakeLabel(parent, "默认标记", 0, -209)
    local markerDropdown = CreateDropdown(parent, 82, -202, 170,
        "“默认标记”效果使用的目标标记。",
        MARKERS,
        function() return tostring(GetDefaultMarker()) end,
        function(key)
            SetOption("defaultMarker", tonumber(key))
        end)

    UpdatePanel = function()
        actionDropdown.refresh()
        markerDropdown.refresh()
        for _, slot in ipairs(PANEL_SLOTS) do
            local doubleDropdown = doubleDropdowns[slot.key]
            if doubleDropdown then doubleDropdown.refresh() end
            local clickDropdown = clickDropdowns[slot.key]
            if clickDropdown then clickDropdown.refresh() end
        end
    end

    parent:HookScript("OnShow", UpdatePanel)
    UpdatePanel()
end

local function SetModuleEnabled(enabled)
    if not enabled then
        QM:HideRing()
        QM:DisarmPing()
        -- 撤掉信号盘的常驻绑定并恢复 pingMode（战斗中自动推迟到战斗结束）
        QM:ApplyNativeSignal()
        return
    end
    if not inCombat() then
        QM:CreateRing()
    end
    QM:ApplyNativeSignal()
end

local MODULE_TIP = "双击世界中的单位、单位框体或姓名板执行所选效果，可选"
    .. " 信号 / 默认标记 / 标记环 / 禁用，每次只执行一个动作。"
    .. "默认双击、Alt + 双击、Ctrl + 双击、Shift + 双击四组手势各自独立配置。"
    .. "设为“禁用”后，该组合不执行任何动作；"
    .. "默认双击设为“禁用”时，双击空地同样不会打开光柱环。"
    .. "在队伍或团队中双击空地会打开世界标记光柱环，点选后把光柱放到双击的位置；"
    .. "不在队伍或团队中时不响应。"
    .. "标记环单击空地、再次双击或 8 秒后自动关闭。"
    .. "战斗中双击不响应，也无法新开标记环；但战斗前打开且尚未关闭的环会保留，"
    .. "环上的按钮战斗中仍可点击。"
    .. "\n\n在设置里还可以给 Alt/Ctrl/Shift 单击单独配置效果。"
    .. "普通效果只在战斗外触发，而且会稍慢一步生效。"
    .. "单击还能选“信号盘”：按住该修饰键左键单击，点一下发送信号，"
    .. "按住不动打开信号盘，移动鼠标选择后松开；这个效果由游戏直接响应。"
    .. "选择“信号盘”后，该键的双击效果会自动关闭，避免单击和双击互相影响。"
    .. "\n\n右侧齿轮可设置四个双击选项、三个修饰键单击和“默认标记”使用的标记。"

-- 设置页顶部不再放功能说明，只在信号系统关闭时显示红色警告
local function GetPanelDesc()
    if PingSystemEnabled() then return "" end
    return "|cffff2020信号系统未开启：“信号”和“信号盘”都会改用默认标记。"
        .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。|r"
end

-- 悬停提示按当前设置动态生成：系统信号关闭时直接说明 ping 会退化
local function GetModuleTip()
    if PingSystemEnabled() then return MODULE_TIP end
    return MODULE_TIP
        .. "\n\n|cffff2020检测到信号系统未开启：“信号”和“信号盘”"
        .. "都会自动改用默认标记。"
        .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。|r"
end

NS.RegisterModule({
    key = "quickMark",
    section = "标记/信号",
    label = "快速标记/信号",
    tip = GetModuleTip,
    default = DEFAULT,
    panelTitle = "快速标记/信号",
    panelDesc = GetPanelDesc,
    buildPanel = BuildQuickMarkPanel,
    reset = function()
        local opts = GetOptions()
        opts.action = DEFAULTS.action
        opts.altAction = DEFAULTS.altAction
        opts.ctrlAction = DEFAULTS.ctrlAction
        opts.shiftAction = DEFAULTS.shiftAction
        opts.defaultMarker = DEFAULTS.defaultMarker
        for _, slot in ipairs(KEY_SLOTS) do
            opts["click" .. slot.key] = DEFAULTS["click" .. slot.key] or DISABLED_EFFECT
            -- 旧版本遗留的快捷键设置一并清掉
            opts["key" .. slot.key] = nil
        end
        -- 信号盘被重置掉：常驻绑定和 pingMode 一起撤掉
        QM:ApplyNativeSignal()
        if UpdatePanel then UpdatePanel() end
    end,
    onToggle = SetModuleEnabled,
})
