-- LeatrixPlusExt 模块：双击快速标记/信号
-- 双击单位打开标记环；信号动作直接发送一个情境 ping
-- 信号走两步：第一次按下先备好安全按钮和宏，第二次点击优先让按钮接收硬件点击；
-- 若点击被世界捕获框收到（按钮没拿到），就在捕获回调里对按钮做一次程序化点击补发。
local addonName, NS = ...

local DB = NS.DB
local Utils = NS.Utils

local DEFAULT = true
local DOUBLE_SECONDS = 0.36
local DOUBLE_DISTANCE = 38
local RADIUS, ICON_SIZE, HIT_RADIUS = 68, 32, 20
local OPEN_SECONDS = 0.18
local AUTO_CLOSE_SECONDS = 8
local HOVER_UPDATE = 0.03

-- 本客户端的 /ping 不区分类型参数（实测 Assist/Attack/Warning 都一样），
-- 只会按目标关系发情境信号；但命令里必须带一个类型才会真正发送。
--
-- 四个双击槽位各自独立配置，可选 5 种效果：
--   默认双击 / Alt + 双击 / Ctrl + 双击 / Shift + 双击
--     → ping + 默认标记 / ping / ping + 标记环 / 默认标记 / 标记环
local EFFECTS = {
    { key = "pingMarkDefault", label = "信号 + 默认标记", ping = true, mark = true },
    { key = "ping",            label = "信号",            ping = true },
    { key = "pingMarkRing",    label = "信号 + 标记环",   ping = true, ring = true },
    { key = "markDefault",     label = "默认标记",         mark = true },
    { key = "markRing",        label = "标记环",           ring = true },
}

local EFFECT_MAP = {}
for _, effect in ipairs(EFFECTS) do EFFECT_MAP[effect.key] = effect end

-- 早期版本保存的旧值：mark = 标记环，signal = 信号
local LEGACY_EFFECTS = { mark = "markRing", signal = "ping" }

-- 序号必须和客户端一致：SetRaidTargetIconTexture / /tm 的 1 是星形，8 才是骷髅。
local MARKERS = {
    { key = "1", label = "1 星形" },
    { key = "2", label = "2 圆圈" },
    { key = "3", label = "3 菱形" },
    { key = "4", label = "4 三角" },
    { key = "5", label = "5 月亮" },
    { key = "6", label = "6 方块" },
    { key = "7", label = "7 十字" },
    { key = "8", label = "8 骷髅" },
}

local DEFAULTS = {
    action = "ping",             -- 默认双击
    altAction = "markRing",      -- Alt + 双击
    ctrlAction = "markDefault",  -- Ctrl + 双击
    shiftAction = "pingMarkDefault", -- Shift + 双击
    defaultMarker = 8,           -- “默认标记”效果使用的目标标记（8 = 骷髅）
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

-- 信号不可用时，带 ping 的效果退化为同一次双击里已经做好的标记部分
local PING_FALLBACKS = {
    pingMarkDefault = "markDefault",
    pingMarkRing = "markRing",
    ping = "markDefault",
}

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
        print("|cffffd100LeatrixPlusExt|r 信号系统未开启，双击已改用标记效果。"
            .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。")
    end
    return fallback
end

-- 本次点击实际会触发哪个效果：Ctrl > Alt > Shift > 默认双击
local function EffectForClick()
    local key
    if IsControlKeyDown() then
        key = GetCtrlAction()
    elseif IsAltKeyDown() then
        key = GetAltAction()
    elseif IsShiftKeyDown() then
        key = GetShiftAction()
    else
        key = GetAction()
    end
    return ResolveEffect(key)
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

local function createSecureButton(parent, size, frameLevel)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "SecureActionButtonTemplate")
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

local function hideButton(button)
    if not button then return end
    button:SetAlpha(0)
    button:SetScale(1)
    button:EnableMouse(false)
    if button.Icon then button.Icon:SetVertexColor(1, 1, 1, 1) end
end

local function tintButton(button, hovered)
    if not button.Icon then return end
    local factor = hovered and 1 or 0.85
    button.Icon:SetVertexColor(factor, factor, factor, 1)
end

function QM:HideRing()
    if self.overlay then
        self.overlay:SetScript("OnUpdate", nil)
        self.overlay:Hide()
    end
    if self.ring then self.ring:Hide() end
    self.mode, self.pendingOpen, self.openAnimation = nil, nil, nil
    self.hoveredIndex = nil
    if self.unitButtons then
        for _, button in ipairs(self.unitButtons) do hideButton(button) end
    end
    hideButton(self.clearUnitButton)
end

function QM:HitAnyButton()
    if not GetCursorPosition then return false end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local list = self.unitButtons
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
    local center = self.clearUnitButton
    if center and center:IsShown() then
        local bx, by = center:GetCenter()
        if bx and (x - bx) * (x - bx) + (y - by) * (y - by) <= HIT_RADIUS * HIT_RADIUS then
            return true
        end
    end
    return false
end

local function closeAfterClick()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() QM:HideRing() end)
    else
        QM:HideRing()
    end
end

-- 只改透明度和鼠标开关，绝不 Hide/Show：
-- 标记环的按钮从创建后一直保持显示，只有透明度变化，所以点击能执行 /tm；
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

    local effect, x, y = QM.armedEffect, QM.armedX, QM.armedY
    -- ping + 标记环：等客户端执行完 ping 后，在点击位置打开标记环
    if effect == "pingMarkRing" and x and y then
        local px, py = x, y
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if IsEnabled() and not inCombat() then QM:ShowRing(px, py) end
            end)
        else
            QM:ShowRing(x, y)
        end
    end
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
    ring:SetSize(216, 216)
    ring:SetFrameStrata("MEDIUM")
    ring:SetFrameLevel(1)
    ring:Hide()
    self.ring = ring

    local title = ring:CreateFontString(nil, "OVERLAY")
    title:SetFont(GameFontNormalSmall:GetFont(), 12, "OUTLINE")
    title:SetPoint("CENTER", ring, "CENTER", 0, RADIUS - 100)
    title:SetTextColor(1, 1, 1, 1)
    self.title = title

    -- 双击单位后先把 mouseover 锁成 target，保证环上的按钮作用于双击时的单位
    local locker = createSecureButton(UIParent, 1, frameLevel)
    if not locker then self.secureUnavailable = true return false end
    SetMacroAction(locker, "/target mouseover")
    locker:SetPoint("CENTER", UIParent, "CENTER", -10000, -10000)
    locker.Icon:SetTexture(nil)
    self.targetLocker = locker

    -- 直接执行效果用的隐藏按钮：和标记环的按钮一样，宏在创建时就固定写死，
    -- 双击时只做「移到光标下 + 显示 + 启用鼠标」，不再临时改属性。
    -- 本客户端的 ping 只认硬件点击，所以 ping / 默认标记都放在按钮宏里执行。
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

    self.markButtons, self.comboButtons = {}, {}
    for index = 1, 8 do
        local markButton = CreateDirectButton("/tm " .. index, frameLevel, directAnchor)
        if not markButton then self.secureUnavailable = true return false end
        self.markButtons[index] = markButton

        local comboButton = CreateDirectButton(pingText .. "\n/tm " .. index, frameLevel, directAnchor)
        if not comboButton then self.secureUnavailable = true return false end
        self.comboButtons[index] = comboButton
    end
    self.directButton = self.pingButton

    self.unitButtons = {}

    for index = 1, 8 do
        local angle = math.rad(90 - (index - 1) * 45)
        local px = math.cos(angle) * RADIUS
        local py = math.sin(angle) * RADIUS

        local ub = createSecureButton(UIParent, ICON_SIZE, frameLevel)
        if not ub then self.secureUnavailable = true return false end
        SetMacroAction(ub, "/tm " .. index)
        ub:SetPoint("CENTER", ring, "CENTER", px, py)
        setMarkerIcon(ub.Icon, index)
        ub:HookScript("OnClick", closeAfterClick)
        self.unitButtons[index] = ub
    end

    local cu = createSecureButton(UIParent, ICON_SIZE, frameLevel)
    if not cu then self.secureUnavailable = true return false end
    cu:SetAttribute("type1", "raidtarget")
    cu:SetAttribute("action1", "clear-all")
    cu:SetPoint("CENTER", ring, "CENTER", 0, 0)
    cu.Icon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    cu:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("清除全部目标标记")
        GameTooltip:Show()
    end)
    cu:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cu:HookScript("OnClick", closeAfterClick)
    self.clearUnitButton = cu

    return true
end

function QM:HoveredIndex()
    if not self.overlay or not self.overlay:IsShown() then return nil end
    if not GetCursorPosition then return nil end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local list = self.unitButtons
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

function QM:OnUpdate(elapsed)
    if not self.mode then return end
    local now = GetTime()
    if now - self.openedAt > AUTO_CLOSE_SECONDS then self:HideRing(); return end

    local list = self.unitButtons
    if not list then return end

    if self.openAnimation then
        local t = math.min(1, (now - self.openAnimation) / OPEN_SECONDS)
        local eased = 1 - (1 - t) * (1 - t) * (1 - t)
        for _, button in ipairs(list) do
            button:SetAlpha(0.3 + 0.7 * eased)
            button:EnableMouse(true)
        end
        local center = self.clearUnitButton
        if center then
            center:SetAlpha(eased)
            center:EnableMouse(true)
        end
        if t >= 1 then
            self.openAnimation = nil
            for _, button in ipairs(list) do button:SetAlpha(1) end
            if center then center:SetAlpha(1) end
        end
        return
    end

    self.nextHoverAt = self.nextHoverAt + elapsed
    if self.nextHoverAt < HOVER_UPDATE then return end
    self.nextHoverAt = 0
    local hovered = self:HoveredIndex()
    if hovered == self.hoveredIndex then return end
    self.hoveredIndex = hovered
    for index, button in ipairs(list) do
        tintButton(button, index == hovered)
    end
end

function QM:ShowRing(x, y)
    if inCombat() or not IsEnabled() then return end
    if not self:CreateRing() then return end
    self:HideRing()

    local scale = UIParent:GetEffectiveScale()
    local uiX, uiY = x / scale, y / scale

    self.ring:ClearAllPoints()
    self.ring:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
    self.ring:Show()

    self.mode = "unit"
    self.title:SetText("目标")

    local list = self.unitButtons
    local center = self.clearUnitButton

    for _, button in ipairs(list) do
        button:SetAlpha(0.25)
        button:SetScale(1)
        button:EnableMouse(false)
        button:Show()
    end
    if center then
        center:SetAlpha(0)
        center:EnableMouse(false)
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
-- 宏内容：/ping [@target] <类型>（带默认标记时再追加 /tm N）。
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

-- 标记走 API 补一次：/tm 属于受保护动作，程序化点击执行时客户端会静默忽略；
-- SetRaidTarget 在非战斗状态下可以直接调用，所以不依赖哪条点击路径成功。
function QM:ApplyPendingMark()
    local marker = self.pendingMark
    if not marker then return end
    self.pendingMark = nil
    local guid = self.pendingMarkGUID
    self.pendingMarkGUID = nil
    if inCombat() or not IsEnabled() then return end

    local unit = FindUnitByGUID(guid)
    if not unit then
        if UnitExists("mouseover") then
            unit = "mouseover"
        elseif UnitExists("target") then
            unit = "target"
        end
    end
    if not unit then return end

    -- 硬件点击路径里的 /tm 已经执行过一次，客户端已经标上就不再重复调用
    if type(_G.GetRaidTargetIndex) == "function" and _G.GetRaidTargetIndex(unit) then
        return
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
    if self.comboButtons then
        for _, button in ipairs(self.comboButtons) do DisableDirectButton(button) end
    end
end

function QM:DisarmPing()
    self.pingToken = nil
    self.pingConsumed = nil
    self.buttonEnabled = nil
    self.pendingMark = nil
    self.pendingMarkGUID = nil
    self.armedEffect, self.armedX, self.armedY = nil, nil, nil
    self.lastClickAt, self.lastX, self.lastY = nil, nil, nil
    self:DisableAllDirect()
end

-- 第一次按下时准备：锁目标、拼好宏、把按钮摆到光标下（先不启用鼠标）。
-- effect 为 EFFECTS 中的一条；只有带 ping / mark 的效果才需要这个按钮。
function QM:PrepareEffect(effect, x, y)
    if not effect or not IsEnabled() or inCombat() then return end
    if not x or not y or not GetCursorPosition then return end
    if not self:CreateRing() then return end

    -- 目标在第一次抬起时再锁（见 EnableArmedButton）：那时按钮还没启用鼠标，
    -- mouseover 仍然有效，也不会被拖视角误触发。

    -- 宏在创建时就固定好了，这里只挑对应效果的那个按钮
    local marker = effect.mark and GetDefaultMarker() or nil
    local button
    if effect.ping and marker then
        button = self.comboButtons and self.comboButtons[marker]
    elseif effect.ping then
        button = self.pingButton
    elseif marker then
        button = self.markButtons and self.markButtons[marker]
    end
    if not button then return end

    -- 布置前把它们全部收掉：所有直接按钮叠在同一个锚点下，
    -- 只要有一个残留启用状态，就会抢走这次点击并执行错的宏
    self:DisableAllDirect()
    self.directButton = button

    -- 标记的 API 补发在点击真正发生时做，这里先记下要用的标记和双击时的单位
    self.pendingMark = effect.mark and GetDefaultMarker() or nil
    if effect.mark and type(_G.UnitGUID) == "function" then
        self.pendingMarkGUID = _G.UnitGUID("mouseover")
    else
        self.pendingMarkGUID = nil
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

    -- 从按下算起一个完整的双击窗口，到点自动收掉
    local token = {}
    self.pingToken = token
    if C_Timer and C_Timer.After then
        C_Timer.After(DOUBLE_SECONDS + 0.12, function()
            if QM.pingToken == token then QM:DisarmPing() end
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

    -- 趁按钮还没启用鼠标时先锁目标（此时 mouseover 仍指向世界单位）
    local okUnit, onUnit = pcall(UnitExists, "mouseover")
    if okUnit and onUnit and self.targetLocker then
        pcall(self.targetLocker.Click, self.targetLocker)
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

function QM:WorldMouseDown(button)
    if button ~= "LeftButton" then return end
    if not IsEnabled() or inCombat() then
        self.lastClickAt, self.lastX, self.lastY, self.pendingOpen = nil, nil, nil, nil
        if self.mode then self:HideRing() end
        return
    end
    if not GetCursorPosition then return end
    local x, y = GetCursorPosition()
    local now = GetTime()
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
        local ok, onUnit = pcall(UnitExists, "mouseover")
        onUnit = ok and onUnit or false

        -- 所有效果都只对单位生效；双击空地不做任何事。
        -- 第二次点击能走到这里，说明它没落在隐藏按钮上（原地双击时客户端常用
        -- 缓存的鼠标焦点，按钮经常收不到这次点击）。这里直接用程序化点击执行
        -- 第一次按下时准备好的宏；执行完立刻收掉按钮，避免这次点击的抬起
        -- 又落到按钮上造成重复触发。
        local effect = EFFECT_MAP[EffectForClick()]
        if self.armedEffect then
            -- 这里不再检查 mouseover：按钮就压在光标下，mouseover 很可能已经是空的，
            -- 但第一次抬起时已经把目标锁好了
            local button = self.directButton
            if self.pingConsumed then
                -- 按钮已经处理过这次点击（硬件在前、捕获在后），这里只负责收尾
                self:DisarmPing()
            elseif button and not self.buttonEnabled then
                -- 按钮没启用（例如拖动判定没通过）：只能程序化补发一次。
                -- 按钮已经启用时不再补发，避免抢在按钮的硬件点击前面把它收掉。
                pcall(button.Click, button)
                self:DisarmPing()
            end
        elseif onUnit and effect and effect.ring and self:CreateRing() then
            -- 点环上按钮前先把双击时的单位锁成 target
            if self.targetLocker then
                pcall(self.targetLocker.Click, self.targetLocker)
            end
            self.pendingOpen = { x = x, y = y, at = now }
        end
    else
        self.lastClickAt, self.lastX, self.lastY = now, x, y
        -- 第一次按下就准备好宏和按钮：不依赖抬起事件是否送达
        local ok, onUnit = pcall(UnitExists, "mouseover")
        onUnit = ok and onUnit or false
        local effect = EFFECT_MAP[EffectForClick()]
        if onUnit and effect and (effect.ping or effect.mark) then
            self:PrepareEffect(effect, x, y)
        end
    end
end

function QM:WorldMouseUp(button)
    if button ~= "LeftButton" then return end

    -- 第一次点击抬起：把按下时准备好的按钮启用，接第二次物理点击
    if self.armedEffect and not self.buttonEnabled and self.lastClickAt
        and (GetTime() - self.lastClickAt) <= DOUBLE_SECONDS and not self.mode then
        -- 不能在抬起事件里直接启用：客户端会把这次抬起当成落在按钮上的一次点击，
        -- 这种“按下不在按钮上、抬起才出现”的点击会触发 OnClick，却执行不了
        -- /tm 这类受保护命令（/ping 是普通聊天命令，所以看起来只是标记失效）。
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
            QM:ShowRing(pending.x, pending.y)
        end)
    else
        self:ShowRing(pending.x, pending.y)
    end
end

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
                QM:HideRing()
                return
            end
            QM:WorldMouseDown(btn)
        end)
        capture:SetScript("OnMouseUp", function(_, btn)
            QM:WorldMouseUp(btn)
        end)
        capture:Show()
    else
        capture:Hide()
        if WorldFrame.HookScript then
            WorldFrame:HookScript("OnMouseDown", function(_, btn)
                if btn == "LeftButton" and QM.mode and not QM:HitAnyButton() then
                    QM:HideRing()
                    return
                end
                QM:WorldMouseDown(btn)
            end)
            WorldFrame:HookScript("OnMouseUp", function(_, btn)
                QM:WorldMouseUp(btn)
            end)
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if IsEnabled() and not inCombat() then
            QM:CreateRing()
            QM:HideRing()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        QM:HideRing()
        QM:DisarmPing()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 战斗中 Show/Hide 受保护，出战斗后再收一次
        QM:DisarmPing()
    end
end)

-- ---------------------------------------------------------------------------
-- 二级设置页
-- ---------------------------------------------------------------------------
local function BuildQuickMarkPanel(parent)
    local MakeHeading = Utils.MakeHeading
    local MakeLabel = Utils.MakeLabel
    local CreateDropdown = Utils.CreateDropdown

    local EFFECT_OPTIONS = {}
    for _, effect in ipairs(EFFECTS) do
        EFFECT_OPTIONS[#EFFECT_OPTIONS + 1] = { key = effect.key, label = effect.label }
    end

    MakeHeading(parent, "双击动作", 0, 0)

    local function AddEffectRow(y, labelText, tip, getValue, onSelect)
        MakeLabel(parent, labelText, 0, y - 7)
        return CreateDropdown(parent, 82, y, 170, tip, EFFECT_OPTIONS, getValue, onSelect)
    end

    local actionDropdown = AddEffectRow(-22, "默认双击",
        "不按修饰键双击单位时触发的效果。",
        function() return GetAction() end,
        function(key) SetOption("action", key) end)

    local altDropdown = AddEffectRow(-54, "Alt + 双击",
        "按住 Alt 双击单位时触发的效果。",
        function() return GetAltAction() end,
        function(key) SetOption("altAction", key) end)

    local ctrlDropdown = AddEffectRow(-86, "Ctrl + 双击",
        "按住 Ctrl 双击单位时触发的效果。",
        function() return GetCtrlAction() end,
        function(key) SetOption("ctrlAction", key) end)

    local shiftDropdown = AddEffectRow(-118, "Shift + 双击",
        "按住 Shift 双击单位时触发的效果。",
        function() return GetShiftAction() end,
        function(key) SetOption("shiftAction", key) end)

    MakeLabel(parent, "默认标记", 0, -157)
    local markerDropdown = CreateDropdown(parent, 82, -150, 170,
        "“默认标记”和“信号 + 默认标记”效果使用的目标标记。",
        MARKERS,
        function() return tostring(GetDefaultMarker()) end,
        function(key) SetOption("defaultMarker", tonumber(key)) end)

    UpdatePanel = function()
        actionDropdown.refresh()
        altDropdown.refresh()
        ctrlDropdown.refresh()
        shiftDropdown.refresh()
        markerDropdown.refresh()
    end

    parent:HookScript("OnShow", UpdatePanel)
    UpdatePanel()
end

local function SetModuleEnabled(enabled)
    if not enabled then
        QM:HideRing()
        QM:DisarmPing()
        return
    end
    if not inCombat() then QM:CreateRing() end
end

local MODULE_TIP = "双击单位执行所选效果，可选"
    .. " 信号 + 默认标记 / 信号 / 信号 + 标记环 / 默认标记 / 标记环。"
    .. "默认双击、Alt + 双击、Ctrl + 双击、Shift + 双击四个槽位各自独立配置。"
    .. "双击空地不触发任何效果；标记环单击空地、再次双击或 8 秒后自动关闭，战斗中不可用。"
    .. "\n\n右侧齿轮可设置四个双击槽位的效果和“默认标记”使用的标记。"

-- 设置页顶部不再放功能说明，只在信号系统关闭时显示红色警告
local function GetPanelDesc()
    if PingSystemEnabled() then return "" end
    return "|cffff2020信号系统未开启：带信号的效果会改用对应的标记效果。"
        .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。|r"
end

-- 悬停提示按当前设置动态生成：系统信号关闭时直接说明 ping 会退化
local function GetModuleTip()
    if PingSystemEnabled() then return MODULE_TIP end
    return MODULE_TIP
        .. "\n\n|cffff2020检测到信号系统未开启：带信号的效果会自动改用对应的标记效果。"
        .. "可在 设置选项 → 游戏功能 → 信号系统 中开启。|r"
end

NS.RegisterModule({
    key = "quickMark",
    section = "标记/信号",
    label = "双击快速标记/信号",
    tip = GetModuleTip,
    default = DEFAULT,
    panelTitle = "双击快速标记/信号",
    panelDesc = GetPanelDesc,
    buildPanel = BuildQuickMarkPanel,
    reset = function()
        local opts = GetOptions()
        opts.action = DEFAULTS.action
        opts.altAction = DEFAULTS.altAction
        opts.ctrlAction = DEFAULTS.ctrlAction
        opts.shiftAction = DEFAULTS.shiftAction
        opts.defaultMarker = DEFAULTS.defaultMarker
        if UpdatePanel then UpdatePanel() end
    end,
    onToggle = SetModuleEnabled,
})
