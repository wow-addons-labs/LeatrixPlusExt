-- LeatrixPlusExt：Leatrix Plus 扩展工具（核心）
-- 不修改 Leatrix Plus，也不依赖 debug 库。
-- 通过识别 Leatrix Plus 主面板（570x370，标题 Leatrix Plus）和它的导航按钮，
-- 在运行时挂「扩展功能A*」「扩展功能B*」两个页与导航项（位于 Settings 之前）。
-- 具体功能位于 Modules/<功能名>/，通过 ns.RegisterModule 注册选项行与齿轮配置页。

local addonName, ns = ...

local DB = _G.LeatrixPlusExtDB
if type(DB) ~= "table" then
    DB = {}
    _G.LeatrixPlusExtDB = DB
end

local panel          -- Leatrix Plus 主面板
local extensionPage  -- 扩展页容器（整页，包含 A/B 两个页签）
local extensionNav   -- 第一个扩展导航按钮
local extensionReady = false
local initMessageShown = false

local extensionModules = {}
local modulePanels = {}
-- [页签 key] = { key, title, navLabel, page, nav, selected }
local extensionTabs = {}
local activeExtensionTab = "A"


-- ---------------------------------------------------------------------------
-- 安全访问（避免受保护/禁止对象报错）
-- ---------------------------------------------------------------------------
local function SafeMethod(object, method, ...)
    if not object then return nil end
    local okFn, fn = pcall(function() return object[method] end)
    if not okFn or type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(fn, object, ...)
    if ok then return a, b, c, d, e end
    return nil
end

local function SafeChildren(frame)
    if not frame then return {} end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok and type(children) == "table" then return children end
    return {}
end

local function SafeRegions(frame)
    if not frame then return {} end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok and type(regions) == "table" then return regions end
    return {}
end

local function SafeSize(frame)
    local width = SafeMethod(frame, "GetWidth")
    local height = SafeMethod(frame, "GetHeight")
    return tonumber(width), tonumber(height)
end

local function SafeString(value)
    local ok, text = pcall(tostring, value)
    return ok and text or "<无法显示>"
end

local function AddLine(lines, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = SafeString(select(i, ...))
    end
    lines[#lines + 1] = table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- 主面板发现
-- ---------------------------------------------------------------------------
local function HasLeatrixTitle(frame)
    for _, region in ipairs(SafeRegions(frame)) do
        local objType = SafeMethod(region, "GetObjectType")
        if objType == "FontString" then
            local text = SafeMethod(region, "GetText")
            if type(text) == "string" and text:find("Leatrix Plus", 1, true) then
                return true
            end
        end
    end
    return false
end

local function FindLeaPlusPanel()
    local children = SafeChildren(UIParent)
    local candidates = {}

    -- 旧版 Leatrix Plus 暴露的全局主面板（Dreadful 插件也用它）
    local globalPanel = _G.LeaPlusGlobalPanel
    if globalPanel and HasLeatrixTitle(globalPanel) then
        return globalPanel, candidates
    end

    -- 标题是最可靠的标识；不依赖具体面板尺寸
    for _, frame in ipairs(children) do
        if HasLeatrixTitle(frame) then
            return frame, candidates
        end
    end

    -- 兜底：按旧版面板尺寸识别
    for _, frame in ipairs(children) do
        local width, height = SafeSize(frame)
        if width and height
            and width >= 550 and width <= 590
            and height >= 350 and height <= 390 then
            candidates[#candidates + 1] = frame
        end
    end

    return nil, candidates
end

local function GetNavButtons(targetPanel)
    local navs = {}
    for _, child in ipairs(SafeChildren(targetPanel)) do
        local objType = SafeMethod(child, "GetObjectType")
        if objType == "Button" then
            local point, relativeTo, _, x, y = SafeMethod(child, "GetPoint", 1)
            if point == "TOPLEFT"
                and (relativeTo == targetPanel or relativeTo == nil)
                and type(x) == "number" and math.abs(x - 16) <= 3
                and type(y) == "number" and y < 0 then
                navs[#navs + 1] = { frame = child, y = y }
            end
        end
    end
    table.sort(navs, function(a, b) return a.y > b.y end)
    return navs
end

-- 打开扩展页时隐藏 Leatrix 的侧边配置面板（CreatePanel 生成的窗口有 f/r/h/b 字段）
local function HideLeatrixSidePanels(mainPanel)
    for _, name in ipairs(UISpecialFrames or {}) do
        if type(name) == "string" then
            local side = _G[name]
            if side and side ~= mainPanel
                and side.f and side.r and side.h and side.b then
                pcall(side.Hide, side)
            end
        end
    end
end

local function GetPageFrames(targetPanel, exclude)
    local pages = {}
    local panelWidth, panelHeight = SafeSize(targetPanel)
    if not panelWidth or not panelHeight then return pages end

    for _, child in ipairs(SafeChildren(targetPanel)) do
        if child ~= exclude then
            local width, height = SafeSize(child)
            if width and height
                and math.abs(width - panelWidth) <= 2
                and math.abs(height - panelHeight) <= 2 then
                pages[#pages + 1] = child
            end
        end
    end
    return pages
end

-- ---------------------------------------------------------------------------
-- Leatrix 风格辅助
-- ---------------------------------------------------------------------------
local LEATRIX_BUTTON_TEXTURE = "Interface\\AddOns\\Leatrix_Plus\\Leatrix_Plus.blp"
local COG_TIP = "点击配置此选项的设置。"

-- pcall 会返回 ok + 函数的所有返回值，这里只取第一个返回值（isLoaded）
local function AddonIsLoaded(name)
    if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
        return ok and loaded and true or false
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        return ok and loaded and true or false
    end
    return false
end

local function LeatrixMediaAvailable()
    return AddonIsLoaded("Leatrix_Plus")
end

-- 使用 Leatrix 自己的按钮贴图，让按钮看起来属于同一个插件
local function StyleButton(button)
    if not button or not LeatrixMediaAvailable() then return end
    pcall(function()
        button:SetNormalTexture(LEATRIX_BUTTON_TEXTURE)
        local normal = button.GetNormalTexture and button:GetNormalTexture()
        if normal and normal.SetTexCoord then
            normal:SetTexCoord(0.5, 1, 0, 0.125)
        end

        button:SetHighlightTexture(LEATRIX_BUTTON_TEXTURE)
        local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
        if highlight and highlight.SetTexCoord then
            highlight:SetTexCoord(0, 0.5, 0, 0.125)
        end

        -- 隐藏 UIPanelButtonTemplate 的分段贴图，避免和 Leatrix 贴图叠加
        local function hideDefaultPieces()
            for _, key in ipairs({ "Left", "Middle", "Right" }) do
                local piece = button[key]
                if piece and piece.Hide then
                    pcall(piece.Hide, piece)
                end
            end
        end
        hideDefaultPieces()
        for _, scriptName in ipairs({ "OnShow", "OnEnable", "OnDisable", "OnMouseDown", "OnMouseUp" }) do
            pcall(button.HookScript, button, scriptName, hideDefaultPieces)
        end
    end)
end


-- ---------------------------------------------------------------------------
-- Leatrix UI 组件（与官方布局保持一致）
-- ---------------------------------------------------------------------------

-- 官方 LeaPlusLC:TipSee / ShowTooltip：贴边时把提示放在面板另一侧
local function LeatrixTooltip(owner, ref, text)
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    ref = ref or owner:GetParent()
    if ref then
        local pscale = ref:GetEffectiveScale()
        local gscale = UIParent:GetEffectiveScale()
        local tscale = GameTooltip:GetEffectiveScale()
        local gap = (UIParent:GetRight() * gscale) - (ref:GetRight() * pscale)
        if gap < (250 * tscale) then
            GameTooltip:SetPoint("TOPRIGHT", ref, "TOPLEFT", 0, 0)
        else
            GameTooltip:SetPoint("TOPLEFT", ref, "TOPRIGHT", 0, 0)
        end
    end
    GameTooltip:SetText(text, nil, nil, nil, nil, true)
end

-- 提示文字可以是字符串，也可以是函数：每次悬停时重新求值，便于反映当前设置
local function ResolveTipText(text)
    if type(text) ~= "function" then return text end
    local ok, value = pcall(text)
    if ok then return value end
    return nil
end

local function AssignTooltip(widget, text, ref)
    widget.tiptext = text
    widget:SetScript("OnEnter", function(self)
        local anchor = type(ref) == "function" and ref() or ref
        LeatrixTooltip(self, anchor, ResolveTipText(self.tiptext) or "")
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- 官方 MakeTx：小节标题
local function MakeHeading(frame, text, x, y)
    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

-- 官方 MakeWD：说明文字
local function MakeLabel(frame, text, x, y, width)
    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    if width then
        fs:SetWidth(width)
        fs:SetJustifyH("LEFT")
    end
    fs:SetText(text)
    return fs
end

-- 官方 CreateButton：UIPanelButtonTemplate + Leatrix 贴图，宽度由文字决定
local function CreateLeatrixButton(parent, text, tip, ref, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetHeight(height or 25)
    button:SetHitRectInsets(0, 0, 0, 0)
    button:SetText(text)

    local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetText(text)
    button:SetWidth(label:GetStringWidth() + 20)
    button.f = label

    AssignTooltip(button, tip or text, ref)
    StyleButton(button)
    return button
end

-- 下拉菜单：与 Leatrix Plus 的 CreateDropdown 使用同一套组件
-- （DropdownButton + WowStyle1DropdownTemplate + 自绘弹出列表）。
-- 不使用游戏自带的菜单系统：游戏菜单会把插件写入的状态带进世界地图代码（污染），
-- 自绘列表只是普通 frame，不会影响地图。
-- items: { { key = ..., label = "..." }, ... }；getValue() 返回当前 key；onSelect(key) 应用。
local function CreateDropdown(parent, x, y, width, tip, items, getValue, onSelect)
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", x, y)
    dropdown:SetWidth(width or 160)

    if tip and tip ~= "" then
        AssignTooltip(dropdown, tip, parent)
    end

    local function CurrentLabel()
        local value = getValue()
        for _, item in ipairs(items) do
            if item.key == value then return item.label end
        end
        return items[1] and items[1].label or ""
    end

    local function UpdateText()
        dropdown:OverrideText(CurrentLabel())
    end

    -- 自绘弹出列表（样式与 LeaPlusLC:CreatePopupList 一致：深色底、勾选标记、悬停高亮）
    local rowHeight, columnWidth = 20, width or 160
    local rows = {}

    local list = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetClampedToScreen(true)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    list:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    list:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:Hide()

    local function IsChecked(item)
        return item.key == getValue()
    end

    local function SetRowCheck(row)
        if row.item and IsChecked(row.item) then
            row.check:Show()
            row.text:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
        else
            row.check:Hide()
            row.text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())
        end
    end

    local function Apply(item)
        onSelect(item.key)
        UpdateText()
        if list:IsShown() then
            for index = 1, #items do
                if rows[index] then SetRowCheck(rows[index]) end
            end
        end
    end

    local function Choose(item)
        Apply(item)
        list:Hide()
    end

    local function GetRow(index)
        local row = rows[index]
        if not row then
            row = CreateFrame("Button", nil, list)
            row:SetSize(columnWidth, rowHeight)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.check = row:CreateTexture(nil, "ARTWORK")
            row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            row.check:SetSize(16, 16)
            row.check:SetPoint("LEFT", 4, 0)
            row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            row.text:SetPoint("LEFT", 22, 0)
            row.text:SetPoint("RIGHT", -4, 0)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row:SetScript("OnClick", function(self)
                if self.item then Choose(self.item) end
            end)
            rows[index] = row
        end
        return row
    end

    local function Open()
        for index, item in ipairs(items) do
            local row = GetRow(index)
            row.item = item
            row.text:SetText(item.label)
            SetRowCheck(row)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -8 - (index - 1) * rowHeight)
            row:Show()
        end
        for index = #items + 1, #rows do
            rows[index]:Hide()
            rows[index].item = nil
        end
        list:SetSize(columnWidth + 16, #items * rowHeight + 16)
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
        list:SetFrameLevel(dropdown:GetFrameLevel() + 20)
        list:Show()
    end

    local function Step(delta)
        local value = getValue()
        local index = 1
        for i, item in ipairs(items) do
            if item.key == value then index = i break end
        end
        index = index + (delta < 0 and 1 or -1)
        if index < 1 or index > #items then return end
        Apply(items[index])
    end

    -- 左键点击打开自绘列表（模板本身不挂菜单，与 Leatrix 的处理一致）
    dropdown:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or not self:IsEnabled() then return end
        if list:IsShown() then list:Hide() else Open() end
    end)

    -- 按钮上滚轮直接切换上一项 / 下一项
    dropdown:EnableMouseWheel(true)
    dropdown:HookScript("OnMouseWheel", function(_, delta) Step(delta) end)

    -- 列表上滚轮同样切换，并阻止列表下面的界面跟着滚动
    list:SetScript("OnMouseWheel", function(_, delta) Step(delta) end)

    -- 点击列表以外的地方时收起
    list:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not dropdown:IsMouseOver() then
            self:Hide()
        end
    end)

    dropdown:HookScript("OnShow", UpdateText)

    -- 父面板隐藏时一并收起列表
    if parent.HookScript then
        parent:HookScript("OnHide", function() list:Hide() end)
    end

    UpdateText()
    dropdown.refresh = UpdateText
    dropdown.list = list
    return dropdown
end

-- 官方 CreateEditBox：输入框外加一层 Tooltip 边框背景
local function AddInputBackdrop(editBox)
    local backdrop = CreateFrame("Frame", nil, editBox, "BackdropTemplate")
    backdrop:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    backdrop:SetPoint("LEFT", -6, 0)
    backdrop:SetWidth(editBox:GetWidth() + 6)
    backdrop:SetHeight(editBox:GetHeight())
    backdrop:SetBackdropColor(1.0, 1.0, 1.0, 0.3)
    editBox.backdrop = backdrop
    return backdrop
end

-- 官方滚动列表背景：深色底 + 蓝色内框，优先使用 Leatrix 的滚动条模板
local function CreateScrollArea(parent, x1, y1, x2, y2)
    local backFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    backFrame:SetPoint("TOPLEFT", x1, y1)
    backFrame:SetPoint("BOTTOMRIGHT", x2, y2)
    backFrame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background" })
    backFrame:SetBackdropColor(0, 0, 1, 0.5)

    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, backFrame,
        "LeaPlusConfigurationPanelScrollFrameTemplate")
    if not ok or not scroll then
        scroll = CreateFrame("ScrollFrame", nil, backFrame, "UIPanelScrollFrameTemplate")
    end
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -29, 6)
    if scroll.SetPanExtent then pcall(scroll.SetPanExtent, scroll, 20) end

    return backFrame, scroll
end

-- ---------------------------------------------------------------------------
-- CVar 工具
-- ---------------------------------------------------------------------------
-- 读取当前值：怀旧客户端是全局 GetCVar，8.x 之后部分客户端只留 C_CVar.GetCVar。
-- 部分客户端会把返回值标成机密值，tostring / 比较都会报错，这里一律按「读不到」处理。
local function SafeToString(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then return nil end
    end
    local okNil, isNil = pcall(function() return value == nil end)
    if not okNil or isNil then return nil end
    local ok, text = pcall(tostring, value)
    if ok and text ~= nil then return text end
    return nil
end

local function GetCVarValue(cvar)
    if type(_G.GetCVar) == "function" then
        local ok, value = pcall(_G.GetCVar, cvar)
        if ok and value ~= nil then
            local text = SafeToString(value)
            if text ~= nil then return text end
        end
    end
    local api = _G.C_CVar
    if type(api) == "table" and type(api.GetCVar) == "function" then
        local ok, value = pcall(api.GetCVar, cvar)
        if ok and value ~= nil then
            local text = SafeToString(value)
            if text ~= nil then return text end
        end
    end
    return nil
end

-- 读取系统默认值：怀旧客户端是全局 GetCVarDefault，8.1.5 之后是 C_CVar.GetCVarDefault。
-- 客户端不提供这个接口时返回 nil，由调用方退回已知默认值或修改前的原值。
local function GetCVarDefaultValue(cvar)
    local api = _G.C_CVar
    if type(api) == "table" and type(api.GetCVarDefault) == "function" then
        local ok, value = pcall(api.GetCVarDefault, cvar)
        if ok and value ~= nil then
            local text = SafeToString(value)
            if text ~= nil then return text end
        end
    end
    if type(_G.GetCVarDefault) == "function" then
        local ok, value = pcall(_G.GetCVarDefault, cvar)
        if ok and value ~= nil then
            local text = SafeToString(value)
            if text ~= nil then return text end
        end
    end
    return nil
end

-- SetCVar 返回 false 表示客户端没有这个 CVar；返回 nil 按成功处理（老客户端不返回值）
local function SetApplied(applied)
    local ok, accepted = pcall(function()
        if applied == nil then return true end
        return applied ~= false
    end)
    -- 返回值是机密值时无法判断，按成功处理，避免误报
    if not ok then return true end
    return accepted
end

-- 写入 CVar：怀旧客户端用全局 SetCVar，部分新客户端只留 C_CVar.SetCVar
-- 写入后如果客户端能读到该值，再核对一次；被拒绝或被客户端改写时记进调试控制台
local function VerifyCVarWrite(cvar, wanted)
    local current = GetCVarValue(cvar)
    if current == nil then return end
    local target, actual = tonumber(wanted), tonumber(current)
    local mismatch
    if target and actual then
        mismatch = math.abs(target - actual) > 0.001
    else
        mismatch = current ~= wanted
    end
    if mismatch and type(ns.AppendDebugLine) == "function" then
        pcall(ns.AppendDebugLine, string.format(
            "[CVar] %s 写入 %s 后，客户端读回 %s", cvar, wanted, current))
    end
end

local function SetCVarValue(cvar, value)
    local text = SafeToString(value)
    if text == nil then return false end

    if type(_G.SetCVar) == "function" then
        local ok, applied = pcall(_G.SetCVar, cvar, text)
        if ok and SetApplied(applied) then
            VerifyCVarWrite(cvar, text)
            return true
        end
    end
    local api = _G.C_CVar
    if type(api) == "table" and type(api.SetCVar) == "function" then
        local ok, applied = pcall(api.SetCVar, cvar, text)
        if ok and SetApplied(applied) then
            VerifyCVarWrite(cvar, text)
            return true
        end
    end
    return false
end

-- 修改 CVar 前先把原值记进 SavedVariables（LeatrixPlusExtDB.cvarBackups）。
-- 这条记录同时用来标记「该 CVar 是本插件改的」：关闭功能时只还原这些 CVar，
-- 避免每次登录把玩家自己改过的设置一并重置。原值只在客户端查不到系统默认值时兜底。
-- 客户端读不到原值时记 false 作为标记，否则关闭功能会因为「没有备份」而不写回默认值。
local function SetCVarWithBackup(cvar, value)
    local backups = DB.cvarBackups
    if type(backups) ~= "table" then
        backups = {}
        DB.cvarBackups = backups
    end

    if backups[cvar] == nil then
        backups[cvar] = GetCVarValue(cvar) or false
    end

    return SetCVarValue(cvar, value)
end

-- 关闭功能时把 CVar 还原成系统默认值：优先问客户端要默认值，其次用模块给出的已知默认值
-- （fallback），两者都拿不到才退回修改前的原值。写入成功后才删除记录，失败了下次登录还会再试。
-- force 为 true 时跳过客户端默认值，直接用 fallback（用于客户端 API 默认值与实际效果不符的情况）。
local function RestoreCVar(cvar, fallback, force)
    local backups = DB.cvarBackups
    if type(backups) ~= "table" then return false end

    local original = backups[cvar]
    if original == nil then return false end

    local target
    if force then
        target = fallback
    else
        target = GetCVarDefaultValue(cvar) or fallback
    end
    if target == nil and original ~= false then target = original end
    if target == nil then return false end

    local ok = SetCVarValue(cvar, target)
    if ok then
        backups[cvar] = nil
    end
    return ok
end

ns.DB = DB
ns.Utils = {
    SafeMethod = SafeMethod,
    SafeChildren = SafeChildren,
    SafeRegions = SafeRegions,
    SafeSize = SafeSize,
    SafeString = SafeString,
    AddLine = AddLine,
    StyleButton = StyleButton,
    LeatrixMediaAvailable = LeatrixMediaAvailable,
    LeatrixTooltip = LeatrixTooltip,
    AssignTooltip = AssignTooltip,
    MakeHeading = MakeHeading,
    MakeLabel = MakeLabel,
    CreateButton = CreateLeatrixButton,
    CreateDropdown = CreateDropdown,
    AddInputBackdrop = AddInputBackdrop,
    CreateScrollArea = CreateScrollArea,
    GetCVarValue = GetCVarValue,
    GetCVarDefaultValue = GetCVarDefaultValue,
    SetCVarWithBackup = SetCVarWithBackup,
    RestoreCVar = RestoreCVar,
    AddonIsLoaded = AddonIsLoaded,
    COG_TIP = COG_TIP,
}

-- 图腾栏模块可能后加载；通过命名空间调用
local function ApplySystemTotemBar()
    if type(ns.ApplySystemTotemBar) == "function" then
        ns.ApplySystemTotemBar()
    end
end

-- ---------------------------------------------------------------------------
-- 功能模块：主页选项行 + 齿轮二级配置面板
-- ---------------------------------------------------------------------------
local PALETTE = "Interface\\ACHIEVEMENTFRAME\\UI-GuildAchievement-Parchment-Horizontal-Desaturated.png"

local function GetModuleValue(module)
    local value = DB[module.key]
    if value == nil then
        return module.default ~= false
    end
    return value and true or false
end

-- 齿轮状态：默认与官方 LockOption 一致（选项关闭时禁用并变暗）；
-- gearRequiresDebug 的模块（调试专用入口）改为跟随「调试控制台」开关：
-- 调试关闭时隐藏齿轮，调试开启时才显示并解锁。
local function UpdateGearLock(module)
    local gear = module.gear
    if not gear then return end

    local enabled
    if module.gearRequiresDebug then
        enabled = DB.debugEnabled and true or false
        gear:SetShown(enabled)
    else
        enabled = GetModuleValue(module)
    end

    if enabled then
        if gear.Enable then pcall(gear.Enable, gear) end
        gear:SetAlpha(1)
    else
        if gear.Disable then pcall(gear.Disable, gear) end
        gear:SetAlpha(0.3)
    end
end

local function SetModuleValue(module, value)
    value = value and true or false
    DB[module.key] = value
    if module.checkbox then module.checkbox:SetChecked(value) end
    UpdateGearLock(module)

    -- 调试开关会影响其他模块的齿轮入口；关闭调试时同时关掉调试专用页面
    if module.key == "debugEnabled" then
        for _, other in ipairs(extensionModules) do
            if other.gearRequiresDebug then
                UpdateGearLock(other)
                if not value and modulePanels[other.key] then
                    modulePanels[other.key]:Hide()
                end
            end
        end
    end

    if module.onToggle then pcall(module.onToggle, value) end
end

-- 官方 CfgBtn：齿轮是复选框的子控件，紧贴文字右侧，悬停提示锚定主面板
local function CreateGear(checkbox, labelFS, onClick, anchorFrame)
    local gear = CreateFrame("Button", nil, checkbox)
    gear:SetSize(20, 20)
    gear:SetPoint("LEFT", labelFS, "RIGHT", 0, 0)

    gear.t = gear:CreateTexture(nil, "BORDER")
    gear.t:SetAllPoints()
    gear.t:SetTexture("Interface\\WorldMap\\Gear_64.png")
    gear.t:SetTexCoord(0, 0.50, 0, 0.50)
    gear.t:SetVertexColor(1.0, 0.82, 0, 1.0)

    gear:SetHighlightTexture("Interface\\WorldMap\\Gear_64.png")
    local highlight = gear.GetHighlightTexture and gear:GetHighlightTexture()
    if highlight and highlight.SetTexCoord then
        highlight:SetTexCoord(0, 0.50, 0, 0.50)
    end

    AssignTooltip(gear, COG_TIP, anchorFrame)
    gear:SetScript("OnClick", onClick)
    return gear
end

local function HideMainPanel()
    if not panel then return end
    for _, pageFrame in ipairs(GetPageFrames(panel, extensionPage)) do
        pageFrame:Hide()
    end
    panel:Hide()
end

local HideConfigPanels
local ShowMainPanel
local OpenConfigPanel

HideConfigPanels = function()
    for _, configPanel in pairs(modulePanels) do
        configPanel:Hide()
    end
end

ShowMainPanel = function()
    HideConfigPanels()
    if panel then
        panel:Show()
        for _, pageFrame in ipairs(GetPageFrames(panel, extensionPage)) do
            pageFrame:Hide()
        end
        if extensionPage then extensionPage:Show() end
        HideLeatrixSidePanels(panel)
    elseif extensionPage then
        extensionPage:Show()
        if extensionPage.Raise then extensionPage:Raise() end
    end
end

local function CreateConfigPanel(module)
    local panelName = addonName .. "Config" .. tostring(#modulePanels + 1)
    local configPanel = CreateFrame("Frame", panelName, UIParent, "BackdropTemplate")
    configPanel:SetSize(570, 370)
    configPanel:SetPoint("CENTER")
    configPanel:SetClampedToScreen(true)
    configPanel:SetClampRectInsets(500, -500, -300, 300)
    configPanel:SetFrameStrata("FULLSCREEN_DIALOG")
    configPanel:SetMovable(true)
    configPanel:EnableMouse(true)
    configPanel:RegisterForDrag("LeftButton")
    configPanel:SetScript("OnDragStart", configPanel.StartMoving)
    configPanel:SetScript("OnDragStop", configPanel.StopMovingOrSizing)
    configPanel:Hide()

    -- 背景与贴图：与 Leatrix CreatePanel 完全一致
    local background = configPanel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.05, 0.05, 0.9)
    configPanel.t = background

    local footer = configPanel:CreateTexture(nil, "BORDER")
    footer:SetTexture(PALETTE)
    footer:SetSize(570, 48)
    footer:SetPoint("BOTTOM")
    footer:SetVertexColor(0.5, 0.5, 0.5, 1.0)

    local mainTexture = configPanel:CreateTexture(nil, "BORDER")
    mainTexture:SetTexture(PALETTE)
    mainTexture:SetSize(570, 323)
    mainTexture:SetPoint("TOPRIGHT")
    mainTexture:SetVertexColor(0.7, 0.7, 0.7, 0.7)
    if mainTexture.SetTexCoord then mainTexture:SetTexCoord(0.09, 1, 0, 1) end

    local title = configPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(module.panelTitle or module.section or module.title or module.key)
    configPanel.titleText = title

    local desc = configPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetHeight(32)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("RIGHT", configPanel, -32, 0)
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    configPanel.descText = desc

    -- 内容区：有说明文字时从 -72 开始；说明为空时整行隐藏，内容随之上移到
    -- 说明文字原来的起始位置，避免标题和第一个控件之间留下一条空白。
    local content = CreateFrame("Frame", nil, configPanel)
    configPanel.content = content
    local function UpdateContentOffset(hasDesc)
        local top = hasDesc and -72 or -44
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", 16, top)
        content:SetPoint("BOTTOMRIGHT", -16, 98)
    end

    -- 说明文字可以是字符串或函数；为空时整行隐藏，让页面顶部留给动态提示
    local function RefreshPanelDesc()
        local text = module.panelDesc
        if type(text) == "function" then
            local ok, value = pcall(text)
            text = ok and value or nil
        end
        if text == nil then text = "配置面板" end
        local hasDesc = text ~= ""
        desc:SetText(text)
        desc:SetShown(hasDesc)
        UpdateContentOffset(hasDesc)
    end
    configPanel.refreshDesc = RefreshPanelDesc
    RefreshPanelDesc()

    local close = CreateFrame("Button", nil, configPanel)
    close:SetSize(30, 30)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    close:SetDisabledTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Disabled")
    close:SetScript("OnClick", function()
        configPanel:Hide()
    end)
    configPanel.closeButton = close

    -- 底部按钮：重置 / 帮助 / 返回主菜单 / 重载
    local reset = CreateLeatrixButton(configPanel, "重置", "点击重置此页面的设置。", configPanel)
    reset:SetPoint("BOTTOMLEFT", 16, 53)
    reset:SetScript("OnClick", function()
        if module.reset then pcall(module.reset, configPanel) end
        SetModuleValue(module, module.default ~= false)
    end)
    configPanel.resetButton = reset

    local help = CreateLeatrixButton(configPanel, "帮助", "此页面没有可用的帮助。", configPanel)
    help:SetPoint("LEFT", reset, "RIGHT", 10, 0)
    if help.SetPushedTextOffset then pcall(help.SetPushedTextOffset, help, 0, 0) end
    configPanel.helpButton = help

    local back = CreateLeatrixButton(configPanel, "返回主菜单", "点击返回主菜单。", configPanel)
    back:SetPoint("BOTTOMRIGHT", -16, 53)
    back:SetScript("OnClick", function()
        configPanel:Hide()
        ShowMainPanel()
    end)
    configPanel.backButton = back

    local reload = CreateLeatrixButton(configPanel, "重载",
        "部分改动需要重载界面才能生效。|n|n完成改动后点击此按钮即可让改动生效。", configPanel)
    reload:SetPoint("BOTTOMRIGHT", -16, 10)
    reload:SetScript("OnClick", function() ReloadUI() end)

    configPanel:SetScript("OnShow", function(self)
        if panel then
            local point, relativeTo, relativePoint, x, y = panel:GetPoint(1)
            if point then
                self:ClearAllPoints()
                self:SetPoint(point, relativeTo or UIParent, relativePoint or point, x or 0, y or 0)
            end
            local dbScale = tonumber(_G.LeaPlusDB and _G.LeaPlusDB["PlusPanelScale"])
            self:SetScale(dbScale or panel:GetScale() or 1)
            if panel.t and panel.t.GetAlpha then
                background:SetAlpha(panel.t:GetAlpha())
            end
            if panel:IsShown() then panel:Hide() end
        end
        HideLeatrixSidePanels(panel)
        if configPanel.refreshDesc then pcall(configPanel.refreshDesc) end
        if module.onShow then pcall(module.onShow, self) end
    end)

    if UISpecialFrames then
        local exists = false
        for _, value in ipairs(UISpecialFrames) do
            if value == panelName then exists = true; break end
        end
        if not exists then table.insert(UISpecialFrames, panelName) end
    end

    if module.buildPanel then
        local ok, err = pcall(module.buildPanel, content, configPanel)
        if not ok then
            print("|cffff3333LeatrixPlusExt|r 这个功能的设置页未能打开，请 /reload 后重试。")
            if ns.AppendDebugLine then
                ns.AppendDebugLine("模块 " .. tostring(module.key)
                    .. " 配置页构建失败：" .. tostring(err))
            end
        end
    end

    modulePanels[module.key] = configPanel
    module.configPanel = configPanel
    return configPanel
end

OpenConfigPanel = function(module)
    local configPanel = modulePanels[module.key] or CreateConfigPanel(module)
    HideMainPanel()
    HideLeatrixSidePanels(panel)
    configPanel:Show()
end

local function FindModule(key)
    for _, module in ipairs(extensionModules) do
        if module.key == key then return module end
    end
end

local RefreshModuleLayout

-- 模块入口可见性：默认显示；模块提供 isVisible 时按它的结果显示/隐藏整行
local function ModuleEntryVisible(module)
    if not module.isVisible then return true end
    local ok, value = pcall(module.isVisible)
    return ok and value and true or false
end

local function UpdateModuleVisibility(module)
    local visible = ModuleEntryVisible(module)
    local changed = module.entryVisible ~= nil and module.entryVisible ~= visible
    module.entryVisible = visible
    if module.checkbox then module.checkbox:SetShown(visible) end
    -- 隐藏的入口不占位，可见性变化后重新排一次，避免留下空位
    if changed and RefreshModuleLayout then RefreshModuleLayout() end
    return visible
end

-- /lpext console：切换「启用调试控制台」入口的可见性（默认隐藏）
local function SetDebugEntryVisible(visible)
    visible = visible and true or false
    DB.showDebugEntry = visible
    local debugModule = FindModule("debugEnabled")
    if debugModule then
        UpdateModuleVisibility(debugModule)
    end
    if not visible and modulePanels["debugEnabled"] then
        modulePanels["debugEnabled"]:Hide()
    end
    return visible
end

-- /lpext reset：把所有设置恢复成默认值
-- 模块自己负责子设置（滑条数值、触发方式、标记动作、组队筛选、调试记录），
-- 然后统一把开关恢复到注册时的 default；onToggle 会同步 CVar 和画面效果。
local function ResetAllSettings()
    -- 调试入口默认隐藏，它不属于任何模块开关
    SetDebugEntryVisible(false)

    for _, module in ipairs(extensionModules) do
        if module.reset then pcall(module.reset, module.configPanel) end
        SetModuleValue(module, module.default)
    end

    print("|cff66ccffLeatrixPlusExt|r 的所有设置已恢复默认值。")
end

-- 恢复默认后重载一次界面，让 CVar、布局和各功能都按新设置重新初始化
local function ResetAndReload()
    ResetAllSettings()
    ReloadUI()
end

-- /lpext reset：先弹确认框，确认后才恢复默认并重载
local RESET_POPUP = "LEATRIXPLUSEXT_RESET_ALL"

local function ShowResetConfirm()
    if type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function" then
        StaticPopupDialogs[RESET_POPUP] = {
            text = "LeatrixPlusExt 的所有设置将恢复默认值。\n\n确认后界面会重新加载（reload）一次。",
            button1 = "恢复并重载",
            button2 = "取消",
            OnAccept = ResetAndReload,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show(RESET_POPUP)
        return
    end

    -- 极少数客户端没有 StaticPopup：退回 /lpext reset confirm
    print("|cff66ccffLeatrixPlusExt|r 游戏不支持确认弹窗。"
        .. "输入 /lpext reset confirm 确认恢复 LeatrixPlusExt 的所有设置并重载。")
end

local function BuildModuleRow(parent, module, x, y)
    -- 页面不再显示分类标题，复选框直接放在分配到的行位置
    -- 复选框（官方 MakeCB 样式：文字是复选框自己的 FontString）
    local checkbox = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", x, y)
    local label = checkbox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", 20, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(module.label or module.title or module.key)
    checkbox.f = label

    -- 官方宽度上限与点击区域规则
    if label:GetWidth() > 152 then
        label:SetWidth(152)
    end
    if label:GetStringWidth() > 152 then
        checkbox:SetHitRectInsets(0, -142, 0, 0)
    else
        checkbox:SetHitRectInsets(0, -label:GetStringWidth() + 4, 0, 0)
    end

    module.checkbox = checkbox
    local enabled = GetModuleValue(module)
    checkbox:SetChecked(enabled)

    -- 复选框提示（官方每个复选框都有提示）
    AssignTooltip(checkbox, module.tip or module.label or module.title or module.key, parent)

    checkbox:SetScript("OnClick", function(self)
        SetModuleValue(module, self:GetChecked() and true or false)
    end)

    if module.buildPanel then
        module.gear = CreateGear(checkbox, label, function()
            OpenConfigPanel(module)
        end, parent)
        UpdateGearLock(module)
    end

    if module.onToggle then pcall(module.onToggle, enabled) end

    -- 入口默认显示；调试控制台等模块可自行决定是否隐藏
    UpdateModuleVisibility(module)
end

-- 与官方 Social 页底部一致：底部选项位于页脚上方（主面板高 370）
local BOTTOM_ROW_Y = -282
-- 普通选项两列排列，从 -72 开始，行距 26，与 Leatrix 自带页面保持等距
local MODULE_ROW_START_Y = -72
local MODULE_ROW_STEP = 26

-- 功能按页签分组（只影响排列顺序，页面不显示分类标题）：
-- 组内按列补位；没有列进分组的新模块接在所属页签的最后。
local MODULE_GROUPS = {
    A = {
        { "任务",       { "questFocusOnKill", "quest2RareScanner", "nameplateQuestProgress",
                          "questItemCleanup" } },
        { "组队",       { "lfgWhere", "lfgFilter" } },
        { "拾取与物品", { "speedyAutoLoot", "alreadyKnown", "showItemLevel",
                          "groupLootCounts", "bulkBuy" } },
    },
    B = {
        { "战斗与画面", { "questItemHighlight", "nameplateDistance", "nameplateRange",
                          "worldTextScale", "quickMark" } },
        -- 条目数为奇数的组放最后，空出来的格子落在底部，不会卡在中间
        { "界面",       { "hideSystemTotemBar", "showPlayerSpeed", "autoRankReplace",
                          "showEnvironment", "debugEnabled" } },
    },
}

local DEFAULT_MODULE_PAGE = "A"

-- 模块所属页签：模块可以用 page = "A"/"B" 明确指定，否则按分组表判断
local function GetModuleTab(module)
    if module.page == "A" or module.page == "B" then
        return module.page
    end
    for tabKey, groups in pairs(MODULE_GROUPS) do
        for _, group in ipairs(groups) do
            for _, entry in ipairs(group[2]) do
                if entry == module or entry == module.key then
                    return tabKey
                end
            end
        end
    end
    return DEFAULT_MODULE_PAGE
end

-- 算出某个页签里每个入口所在的行/列；隐藏的入口不占位置。
-- 上一组只占了左半格时，下一组直接补满这一行，避免右侧留空。
local function ComputeModuleLayout(tabKey)
    local layout = {}
    local row, col = 0, 0

    local function AddGroup(entries)
        for _, entry in ipairs(entries) do
            local module = type(entry) == "string" and FindModule(entry) or entry
            if type(module) == "table" and not module.bottomRow
                and not layout[module] and ModuleEntryVisible(module)
                and GetModuleTab(module) == tabKey then
                layout[module] = { col = col, row = row }
                col = col + 1
                if col >= 2 then
                    col, row = 0, row + 1
                end
            end
        end
    end

    for _, group in ipairs(MODULE_GROUPS[tabKey] or {}) do
        AddGroup(group[2])
    end

    -- 没列进分组的模块按注册顺序接在这个页签的最后
    local rest = {}
    for _, module in ipairs(extensionModules) do
        if not module.bottomRow and GetModuleTab(module) == tabKey then
            rest[#rest + 1] = module
        end
    end
    AddGroup(rest)
    return layout
end

local function GetModulePosition(module)
    local tabKey = GetModuleTab(module)

    if module.bottomRow then
        local bottomIndex = 0
        for _, existing in ipairs(extensionModules) do
            if existing.bottomRow and ModuleEntryVisible(existing)
                and GetModuleTab(existing) == tabKey then
                bottomIndex = bottomIndex + 1
            end
            if existing == module then break end
        end
        local column = (bottomIndex - 1) % 2
        return column == 0 and 146 or 340, BOTTOM_ROW_Y
    end

    local slot = ComputeModuleLayout(tabKey)[module]
    if not slot then
        -- 入口当前不可见，位置无所谓；可见时 RefreshModuleLayout 会重新排
        return 146, MODULE_ROW_START_Y
    end
    local x = slot.col == 0 and 146 or 340
    local y = MODULE_ROW_START_Y - slot.row * MODULE_ROW_STEP
    return x, y
end

-- 入口可见性在运行时变化时（目前只有调试控制台）重新排一次两列位置
RefreshModuleLayout = function()
    if not extensionPage then return end
    for _, module in ipairs(extensionModules) do
        if module.checkbox then
            local x, y = GetModulePosition(module)
            module.checkbox:ClearAllPoints()
            module.checkbox:SetPoint("TOPLEFT", x, y)
        end
    end
end

local function RegisterModule(module)
    if type(module) ~= "table" or type(module.key) ~= "string" then return end
    for _, existing in ipairs(extensionModules) do
        if existing.key == module.key then return existing end
    end
    module.default = module.default ~= false
    extensionModules[#extensionModules + 1] = module

    -- 页面已建好时支持后续追加到对应页签
    if extensionPage then
        local tab = extensionTabs[GetModuleTab(module)]
        if tab and tab.page then
            local x, y = GetModulePosition(module)
            BuildModuleRow(tab.page, module, x, y)
            if RefreshModuleLayout then RefreshModuleLayout() end
        end
    end
    return module
end

_G.LeatrixPlusExt = _G.LeatrixPlusExt or {}
_G.LeatrixPlusExt.RegisterModule = RegisterModule
ns.RegisterModule = RegisterModule
ns.HideConfigPanel = function(key)
    local configPanel = modulePanels[key]
    if configPanel then configPanel:Hide() end
end
ns.ShowMainPanel = ShowMainPanel

-- 左侧菜单里的两个扩展页签
local EXTENSION_TABS = {
    { key = "A", navLabel = "扩展功能A*", title = "LeatrixPlusExt 扩展功能A" },
    { key = "B", navLabel = "扩展功能B*", title = "LeatrixPlusExt 扩展功能B" },
}

-- 导航文字后面的 * 表示这一页由 LeatrixPlusExt 独立提供，不是 Leatrix Plus 自带选项
local EXTENSION_NAV_TIP = "带 * 的扩展页由 LeatrixPlusExt 独立提供，不属于 Leatrix Plus 自带选项。"

-- 一级页面：标题 + 两列选项（与 Leatrix 页面一致）
local function BuildExtensionPageBody(tab)
    local parent = tab.page
    local title = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 146, -16)
    title:SetText(tab.title)

    for _, module in ipairs(extensionModules) do
        if GetModuleTab(module) == tab.key then
            local x, y = GetModulePosition(module)
            BuildModuleRow(parent, module, x, y)
        end
    end
end

-- 只显示当前页签；容器隐藏时两个页面和导航高亮一起隐藏
local function UpdateTabVisibility()
    local shown = extensionPage and extensionPage:IsShown()
    for _, info in ipairs(EXTENSION_TABS) do
        local tab = extensionTabs[info.key]
        if tab then
            local current = shown and activeExtensionTab == info.key
            tab.page:SetShown(current)
            if tab.selected then tab.selected:SetShown(current) end
        end
    end
end

-- 创建一个页签的左侧导航按钮（与 Leatrix 导航同样的样式）
local function CreateExtensionNav(parent, tab, y, tooltipFrame, onClick)
    local nav = CreateFrame("Button", nil, parent)
    nav:SetSize(112, 20)
    nav:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    nav:SetFrameLevel((parent:GetFrameLevel() or 1) + 10)

    local label = nav:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("LEFT", 16, 0)
    label:SetText(tab.navLabel)

    local selected = nav:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(0.3, 0.3, 0.0, 0.8)
    selected:Hide()
    tab.selected = selected

    local hover = nav:CreateTexture(nil, "BACKGROUND")
    hover:SetAllPoints()
    hover:SetColorTexture(0.3, 0.3, 0.0, 0.56)
    hover:Hide()
    nav:SetScript("OnEnter", function(self)
        hover:Show()
        LeatrixTooltip(self, tooltipFrame, EXTENSION_NAV_TIP)
    end)
    nav:SetScript("OnLeave", function()
        hover:Hide()
        GameTooltip:Hide()
    end)
    nav:SetScript("OnClick", onClick)
    return nav
end

-- 在整页容器里创建两个页签页面并构建选项
local function BuildExtensionTabs(container)
    extensionTabs = {}
    for _, info in ipairs(EXTENSION_TABS) do
        local page = CreateFrame("Frame", nil, container)
        page:SetAllPoints(container)
        page:SetFrameLevel((container:GetFrameLevel() or 1) + 1)
        page:Hide()
        local tab = {
            key = info.key,
            title = info.title,
            navLabel = info.navLabel,
            page = page,
        }
        extensionTabs[info.key] = tab
        BuildExtensionPageBody(tab)
    end
    activeExtensionTab = EXTENSION_TABS[1].key
end

local function CreateExtensionUI(targetPanel)
    local navs = GetNavButtons(targetPanel)

    -- Dreadful 的做法：在 Settings 之前插入扩展导航，并下移 Settings / Media，
    -- 尽量保留 Leatrix 原有的分组间距。
    local lastY = navs[#navs] and navs[#navs].y
    local prevY = navs[#navs - 1] and navs[#navs - 1].y
    local beforeY = navs[#navs - 2] and navs[#navs - 2].y
    -- 真实 Leatrix 在 Settings 前有 40px 分组间距，才够插入两项；
    -- 如果只是普通 20px 间距，改用压缩模式，避免和上一项重叠。
    local surgical = #navs >= 3
        and type(lastY) == "number" and lastY <= -270
        and type(prevY) == "number" and type(beforeY) == "number"
        and math.abs(prevY - beforeY) >= 30

    local navYs = {}
    if surgical then
        -- 占用 Settings 前面空出来的 40px：A 放在原空位，B 接管 Settings 的位置，
        -- Settings 和 Media 各下移 20px。
        navYs[1] = prevY + 20
        navYs[2] = prevY
    else
        -- 压缩模式：所有原有导航按 20px 重新排列，扩展导航接在最后
        navYs[1] = -72 - #navs * 20
        navYs[2] = navYs[1] - 20
    end

    extensionPage = CreateFrame("Frame", nil, targetPanel)
    extensionPage:SetAllPoints(targetPanel)
    extensionPage:SetFrameLevel((targetPanel:GetFrameLevel() or 1) + 5)
    extensionPage:Hide()

    -- 先构建两个页签；失败时不要留下被反复移动的导航
    local buildOk, buildError = pcall(BuildExtensionTabs, extensionPage)
    if not buildOk then
        extensionPage:Hide()
        extensionPage = nil
        extensionTabs = {}
        error(tostring(buildError), 0)
    end

    -- 页面构建成功后再调整原有导航，避免失败重试时反复移动
    if surgical then
        for index = #navs - 1, #navs do
            local info = navs[index]
            local navFrame = info.frame
            local point, relativeTo, relativePoint, x, y = SafeMethod(navFrame, "GetPoint", 1)
            if point and type(y) == "number" then
                navFrame:ClearAllPoints()
                navFrame:SetPoint(point, relativeTo or targetPanel, relativePoint or point, x or 16, y - 20)
                info.y = y - 20
            end
        end
    else
        for index, navInfo in ipairs(navs) do
            local navFrame = navInfo.frame
            navFrame:ClearAllPoints()
            navFrame:SetPoint("TOPLEFT", targetPanel, "TOPLEFT", 16, -72 - (index - 1) * 20)
            navInfo.y = -72 - (index - 1) * 20
        end
    end

    extensionPage:SetScript("OnShow", UpdateTabVisibility)
    extensionPage:SetScript("OnHide", UpdateTabVisibility)

    for index, info in ipairs(EXTENSION_TABS) do
        local tab = extensionTabs[info.key]
        tab.nav = CreateExtensionNav(targetPanel, tab, navYs[index], targetPanel, function()
            HideLeatrixSidePanels(targetPanel)
            targetPanel:Show()
            for _, pageFrame in ipairs(GetPageFrames(targetPanel, extensionPage)) do
                pageFrame:Hide()
            end
            activeExtensionTab = info.key
            extensionPage:Show()
            UpdateTabVisibility()
        end)
    end
    extensionNav = extensionTabs[EXTENSION_TABS[1].key].nav

    -- 原有导航/搜索结果被显示时，隐藏扩展页（比只钩导航点击更稳）
    for _, pageFrame in ipairs(GetPageFrames(targetPanel, extensionPage)) do
        pcall(pageFrame.HookScript, pageFrame, "OnShow", function()
            if extensionPage then extensionPage:Hide() end
        end)
    end

    -- 点击原有导航时隐藏扩展页（保留，覆盖没有 OnShow 的页面）
    for _, navInfo in ipairs(navs) do
        navInfo.frame:HookScript("OnClick", function()
            if extensionPage then extensionPage:Hide() end
        end)
    end

    -- 使用 Leatrix 的选项搜索时隐藏扩展页，避免盖住搜索结果
    for _, child in ipairs(SafeChildren(targetPanel)) do
        if SafeMethod(child, "GetObjectType") == "EditBox" then
            pcall(child.HookScript, child, "OnTextChanged", function()
                if extensionPage then extensionPage:Hide() end
            end)
        end
    end

    -- 关闭主面板时隐藏扩展页，避免下次打开时覆盖 Leatrix 自己的页面
    targetPanel:HookScript("OnHide", function()
        if extensionPage then extensionPage:Hide() end
    end)

    -- 与 Leatrix 的配置面板一致：主面板显示时若有二级配置面板，隐藏主面板
    targetPanel:HookScript("OnShow", function()
        for _, configPanel in pairs(modulePanels) do
            if configPanel:IsShown() then
                targetPanel:Hide()
                break
            end
        end
    end)

    return extensionPage
end

-- 找不到 Leatrix 主面板时的独立窗口回退
local function CreateStandaloneWindow()
    local f = CreateFrame("Frame", "LeatrixPlusExtWindow", UIParent, "BackdropTemplate")
    f:SetSize(570, 370)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.4, 0.8, 1, 0.9)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local note = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", 16, 12)
    note:SetText("Leatrix Plus 不可用：独立窗口")

    -- 独立窗口没有 Leatrix 的左侧菜单，在这里放一组同样的页签导航
    local container = CreateFrame("Frame", nil, f)
    container:SetAllPoints(f)
    container:SetFrameLevel((f:GetFrameLevel() or 1) + 5)

    local buildOk, buildError = pcall(BuildExtensionTabs, container)
    if not buildOk then
        extensionTabs = {}
        error(tostring(buildError), 0)
    end

    for index, info in ipairs(EXTENSION_TABS) do
        local tab = extensionTabs[info.key]
        tab.nav = CreateExtensionNav(f, tab, -60 - (index - 1) * 20, f, function()
            activeExtensionTab = info.key
            UpdateTabVisibility()
        end)
    end

    f:SetScript("OnShow", UpdateTabVisibility)
    f:SetScript("OnHide", UpdateTabVisibility)
    f:Hide()

    if UISpecialFrames then
        local name = f:GetName()
        local exists = false
        for _, value in ipairs(UISpecialFrames) do
            if value == name then exists = true; break end
        end
        if name and not exists then table.insert(UISpecialFrames, name) end
    end

    return f
end

local function IsLeatrixPlusLoaded()
    return AddonIsLoaded("Leatrix_Plus")
end

local function TryInitialize(allowFallback)
    if extensionReady then return true end

    local targetPanel = FindLeaPlusPanel()
    if targetPanel then
        local ok, page = pcall(CreateExtensionUI, targetPanel)
        if not ok or not page then
            print("|cffff3333LeatrixPlusExt|r 扩展页未能创建，请 /reload 后重试。")
            if ns.AppendDebugLine then
                ns.AppendDebugLine("扩展页创建失败：" .. tostring(page))
            end
            return false
        end

        panel = targetPanel
        extensionReady = true
        ApplySystemTotemBar()
        print("|cff66ccffLeatrixPlusExt|r 已就绪：左侧菜单「扩展功能A*」「扩展功能B*」，或输入 /lpext 打开。")
        return true
    end

    -- Leatrix Plus 还没加载时先等待，不要过早回退到独立窗口
    if not allowFallback and not IsLeatrixPlusLoaded() then
        return false
    end

    -- 回退：独立窗口
    local ok, page = pcall(CreateStandaloneWindow)
    if ok and page then
        extensionPage = page
        panel = nil
        extensionReady = true
        ApplySystemTotemBar()
        -- 区分「没装/没启用 Leatrix Plus」和「装了但没找到主面板」，方便排查
        if IsLeatrixPlusLoaded() then
            print("|cffff3333LeatrixPlusExt|r 未找到 Leatrix Plus 主界面，已使用独立窗口。输入 /lpext 打开。")
        else
            print("|cffff3333LeatrixPlusExt|r 未检测到 Leatrix Plus，已使用独立窗口。输入 /lpext 打开。")
        end
        return true
    end

    return false
end

local function OpenExtension()
    if not extensionReady then
        TryInitialize(true)
    end
    if not (extensionReady and extensionPage) then
        print("|cffff3333LeatrixPlusExt|r 扩展页尚未就绪，请确认 Leatrix Plus 已启用。")
        print("|cff66ccffLeatrixPlusExt|r 输入 /lpext diag 查看诊断。")
        return
    end
    ShowMainPanel()
end

-- ---------------------------------------------------------------------------
-- 可复制诊断窗口
-- ---------------------------------------------------------------------------
local diagFrame, diagBox

local function ShowDiagnosticWindow(title, text)
    if not diagFrame then
        local ok = pcall(function()
            local f = CreateFrame("Frame", "LeatrixPlusExtDiagFrame", UIParent, "BackdropTemplate")
            f:SetSize(720, 480)
            f:SetPoint("CENTER")
            f:SetFrameStrata("DIALOG")
            f:SetClampedToScreen(true)
            f:SetMovable(true)
            f:EnableMouse(true)
            f:RegisterForDrag("LeftButton")
            f:SetScript("OnDragStart", function(self) self:StartMoving() end)
            f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
            f:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            f:SetBackdropColor(0, 0, 0, 0.96)
            f:SetBackdropBorderColor(0.4, 0.8, 1, 0.9)

            local heading = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
            heading:SetPoint("TOP", 0, -10)
            heading:SetText(title or "LeatrixPlusExt 诊断")

            local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            close:SetPoint("TOPRIGHT", -2, -2)

            local scroll = CreateFrame("ScrollFrame", "LeatrixPlusExtDiagScrollFrame", f, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", 12, -36)
            scroll:SetPoint("BOTTOMRIGHT", -30, 44)

            local edit = CreateFrame("EditBox", nil, scroll)
            edit:SetMultiLine(true)
            edit:SetAutoFocus(false)
            edit:SetWidth(660)
            edit:SetHeight(380)
            edit:SetPoint("TOPLEFT", 0, 0)
            edit:SetTextInsets(6, 6, 4, 4)
            pcall(edit.SetFontObject, edit, ChatFontNormal or GameFontHighlightSmall)
            edit:SetMaxLetters(0)
            edit:SetScript("OnEscapePressed", function() f:Hide() end)
            scroll:SetScrollChild(edit)
            diagBox = edit

            local copy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            copy:SetSize(140, 22)
            copy:SetPoint("BOTTOMLEFT", 12, 12)
            copy:SetText("全选（Ctrl+C）")
            copy:SetScript("OnClick", function()
                edit:SetFocus()
                edit:HighlightText()
            end)

            local close2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            close2:SetSize(90, 22)
            close2:SetPoint("BOTTOMRIGHT", -30, 12)
            close2:SetText("关闭")
            close2:SetScript("OnClick", function() f:Hide() end)

            if UISpecialFrames then
                local name = f:GetName()
                local exists = false
                for _, value in ipairs(UISpecialFrames) do
                    if value == name then exists = true; break end
                end
                if name and not exists then table.insert(UISpecialFrames, name) end
            end

            f:Hide()
            diagFrame = f
        end)
        if not ok or not diagFrame then
            print("|cffff3333LeatrixPlusExt|r 无法创建诊断窗口。")
            return
        end
    end

    diagBox:SetText(text or "")
    diagBox:SetCursorPosition(0)
    local _, count = (text or ""):gsub("\n", "\n")
    diagBox:SetHeight(math.max(40, (count + 1) * 14 + 16))
    diagFrame:Show()
    diagFrame:Raise()
end

local function BuildDiagnostics()
    local lines = {}
    local function add(text) lines[#lines + 1] = tostring(text) end

    add("LeatrixPlusExt 接入诊断（UI 识别模式）")
    add("")
    add("debug 库：" .. type(debug))
    add("Leatrix_Plus 已加载：" .. tostring(IsLeatrixPlusLoaded()))
    add("_G.LeaPlusGlobalPanel：" .. type(_G.LeaPlusGlobalPanel))
    add("UIParent 子 frame 数：" .. #SafeChildren(UIParent))

    local foundPanel, candidates = FindLeaPlusPanel()
    add("主面板识别：" .. (foundPanel and "FOUND" or "nil"))
    add("570x370 候选数：" .. #(candidates or {}))

    if foundPanel then
        local name = SafeMethod(foundPanel, "GetName")
        local width, height = SafeSize(foundPanel)
        add("面板：" .. tostring(name or "nil") .. " " .. tostring(width) .. "x" .. tostring(height))
        add("标题包含 Leatrix Plus：" .. tostring(HasLeatrixTitle(foundPanel)))

        local navs = GetNavButtons(foundPanel)
        add("导航按钮数：" .. #navs)
        for index, navInfo in ipairs(navs) do
            local nav = navInfo.frame
            local label
            for _, region in ipairs(SafeRegions(nav)) do
                if SafeMethod(region, "GetObjectType") == "FontString" then
                    local text = SafeMethod(region, "GetText")
                    if type(text) == "string" and text ~= "" then
                        label = text
                        break
                    end
                end
            end
            add(string.format("  %d: y=%s label=%s", index, tostring(navInfo.y), tostring(label or "?")))
        end

        local pages = GetPageFrames(foundPanel, extensionPage)
        add("整页 frame 数：" .. #pages)
    end

    add("")
    add("扩展页状态：" .. tostring(extensionReady)
        .. (extensionReady and (panel and " (embedded)" or " (standalone)") or ""))
    add("功能模块数：" .. tostring(#extensionModules))
    for _, module in ipairs(extensionModules) do
        add("  " .. tostring(module.key)
            .. " section=" .. tostring(module.section)
            .. " value=" .. tostring(GetModuleValue(module))
            .. " checkbox=" .. tostring(module.checkbox ~= nil)
            .. " gear=" .. tostring(module.gear ~= nil)
            .. " panel=" .. tostring(module.configPanel ~= nil))
    end
    return table.concat(lines, "\n")
end

-- 小地图结构诊断：把原生坐标元素的位置、文本、字体、锚点全部摊开，
-- 方便直接在可复制窗口里整段取走。注意客户端可能返回机密字符串，
-- 任何读取/格式化都要包在 pcall 里。
local function BuildMinimapDiagnostics()
    local lines = {}
    local function add(text) lines[#lines + 1] = tostring(text) end

    local function SafeTextOf(region)
        if not region then return nil end
        local okRead, text = pcall(function() return region:GetText() end)
        if not okRead or text == nil then return nil end
        -- 机密字符串连长度都取不到；这里失败就当成机密值处理
        local okLength = pcall(function() return #text end)
        if not okLength then return "<机密字符串>" end
        local okType, kind = pcall(type, text)
        if not okType or kind ~= "string" or text == "" then return nil end
        return text
    end

    -- 这个客户端的原生坐标格式是「43.7（39.5）」，不是「43, 39」；
    -- 半角/全角逗号和括号都要认（全角字符是多字节，不能放进字符集合）
    local function LooksLikeCoords(text)
        local ok, found = pcall(function()
            return text:find("%d+%s*,%s*%d+")
                or text:find("%d+%s*，%s*%d+")
                or text:find("%d+%.?%d*%s*%(%s*%d+")
                or text:find("%d+%.?%d*%s*（%s*%d+")
        end)
        return (ok and found) and true or false
    end

    local function PointText(region)
        local ok, point, relativeTo, relativePoint, x, y = pcall(function()
            return region:GetPoint(1)
        end)
        if not ok then return "<读取失败>" end
        if not point then return "<无锚点>" end
        local relativeName = SafeMethod(relativeTo, "GetName")
        if not relativeName then relativeName = SafeMethod(relativeTo, "GetObjectType") end
        if relativeTo == UIParent then relativeName = "UIParent" end
        return string.format("%s -> %s %s (%s, %s)",
            tostring(point), tostring(relativeName or "?"), tostring(relativePoint or "?"),
            SafeString(x), SafeString(y))
    end

    local function DescribeRegion(label, region, indent)
        local pad = string.rep("  ", indent or 0)
        if region == nil then
            add(pad .. label .. " = nil")
            return
        end
        add(pad .. label .. " = " .. tostring(SafeMethod(region, "GetObjectType") or "?")
            .. "  name=" .. tostring(SafeMethod(region, "GetName") or "?")
            .. "  shown=" .. tostring(SafeMethod(region, "IsShown"))
            .. "  size=" .. tostring(SafeMethod(region, "GetWidth")) .. "x"
            .. tostring(SafeMethod(region, "GetHeight")))
        add(pad .. "  anchor: " .. PointText(region))

        local text = SafeTextOf(region)
        if text then
            local okFormat, quoted = pcall(string.format, "%q", text)
            if not okFormat then quoted = text end
            add(pad .. "  text=" .. tostring(quoted)
                .. "  stringWidth=" .. tostring(SafeMethod(region, "GetStringWidth")))
            add(pad .. "  justify=" .. tostring(SafeMethod(region, "GetJustifyH"))
                .. "/" .. tostring(SafeMethod(region, "GetJustifyV")))

            local fontPath, fontSize, fontFlags = SafeMethod(region, "GetFont")
            add(pad .. "  font=" .. tostring(fontPath) .. " " .. tostring(fontSize)
                .. " " .. tostring(fontFlags))

            local r, g, b, a = SafeMethod(region, "GetTextColor")
            add(pad .. "  color=" .. tostring(r) .. "," .. tostring(g) .. ","
                .. tostring(b) .. "," .. tostring(a))
        end
    end

    add("LeatrixPlusExt 小地图坐标诊断")
    add("点「全选（Ctrl+C）」复制整段发给我即可。")
    add("")

    local version, build, _, toc = GetBuildInfo()
    add("== 环境 ==")
    add("locale=" .. tostring(GetLocale()) .. "  version=" .. tostring(version)
        .. "  build=" .. tostring(build) .. "  toc=" .. tostring(toc)
        .. "  WOW_PROJECT_ID=" .. tostring(_G.WOW_PROJECT_ID))
    add("Minimap=" .. tostring(_G.Minimap and "存在" or "nil")
        .. "  MinimapCluster=" .. tostring(_G.MinimapCluster and "存在" or "nil"))
    add("")

    local cluster = _G.MinimapCluster
    local container = cluster and cluster.MinimapContainer

    add("== 已知元素 ==")
    DescribeRegion("Minimap", _G.Minimap, 0)
    DescribeRegion("MinimapCluster", cluster, 0)
    DescribeRegion("MinimapCluster.ZoneTextButton", cluster and cluster.ZoneTextButton, 0)
    DescribeRegion("MinimapZoneText", _G.MinimapZoneText, 0)
    DescribeRegion("MinimapCluster.MinimapContainer", container, 0)
    DescribeRegion("MinimapCluster.MinimapContainer.PlayerCoords",
        container and container.PlayerCoords, 0)
    DescribeRegion("TimeManagerClockButton", _G.TimeManagerClockButton, 0)
    add("")

    -- PlayerCoords 是个 Frame，真正的文字可能是它内部的 FontString；
    -- 这里把区域/子元素/Lua 字段全部列出来（包括空文本和隐藏的）
    add("== PlayerCoords 内部 ==")
    local playerCoords = container and container.PlayerCoords
    if not playerCoords then
        add("  PlayerCoords = nil")
    else
        add("  IsShown=" .. tostring(SafeMethod(playerCoords, "IsShown"))
            .. "  IsVisible=" .. tostring(SafeMethod(playerCoords, "IsVisible"))
            .. "  alpha=" .. tostring(SafeMethod(playerCoords, "GetAlpha"))
            .. "  scale=" .. tostring(SafeMethod(playerCoords, "GetEffectiveScale")))

        local regions = SafeRegions(playerCoords)
        add("  区域数=" .. tostring(#regions))
        for index, region in ipairs(regions) do
            local text = SafeTextOf(region)
            local okFormat, quoted = pcall(string.format, "%q", text or "")
            add("   #" .. tostring(index)
                .. " [" .. tostring(SafeMethod(region, "GetObjectType") or "?") .. "]"
                .. " name=" .. tostring(SafeMethod(region, "GetName") or "?")
                .. " shown=" .. tostring(SafeMethod(region, "IsShown"))
                .. " size=" .. tostring(SafeMethod(region, "GetWidth"))
                .. "x" .. tostring(SafeMethod(region, "GetHeight"))
                .. " text=" .. tostring(okFormat and quoted or "<读取失败>")
                .. (text and "" or " <空/非文本>"))
        end

        local children = SafeChildren(playerCoords)
        add("  子元素数=" .. tostring(#children))
        for index, child in ipairs(children) do
            add("   #" .. tostring(index)
                .. " [" .. tostring(SafeMethod(child, "GetObjectType") or "?") .. "]"
                .. " name=" .. tostring(SafeMethod(child, "GetName") or "?")
                .. " shown=" .. tostring(SafeMethod(child, "IsShown"))
                .. " text=" .. tostring(SafeTextOf(child) or "<空/非文本>"))
        end

        add("  Lua 字段：")
        local okPairs = pcall(function()
            local count = 0
            for key, value in pairs(playerCoords) do
                count = count + 1
                if count > 40 then
                    add("   ...")
                    return
                end
                if type(value) ~= "function" then
                    add("   " .. tostring(key) .. " = " .. type(value))
                end
            end
            if count == 0 then
                add("   （无 Lua 字段）")
            end
        end)
        if not okPairs then
            add("   （字段遍历失败）")
        end
    end
    add("")

    add("== 子树扫描（带文字的 FontString） ==")
    local seen = {}
    local scanned = 0
    local function scan(frame, path, depth)
        if not frame or depth > 4 or seen[frame] or scanned > 400 then return end
        seen[frame] = true
        scanned = scanned + 1

        for _, region in ipairs(SafeRegions(frame)) do
            if SafeMethod(region, "GetObjectType") == "FontString" then
                local text = SafeTextOf(region)
                if text then
                    local flag = LooksLikeCoords(text) and "  <== 疑似坐标" or ""
                    local okFormat, quoted = pcall(string.format, "%q", text)
                    if not okFormat then quoted = text end
                    add(string.format("%s%s.%s  shown=%s  w=%s  %s%s",
                        string.rep("  ", depth), path,
                        tostring(SafeMethod(region, "GetName") or "<无名字>"),
                        tostring(SafeMethod(region, "IsShown")),
                        tostring(SafeMethod(region, "GetStringWidth")),
                        tostring(quoted), flag))
                end
            end
        end

        for _, child in ipairs(SafeChildren(frame)) do
            local childName = SafeMethod(child, "GetName")
            if not childName then childName = SafeMethod(child, "GetObjectType") or "?" end
            scan(child, path .. "." .. childName, depth + 1)
        end
    end
    if cluster then scan(cluster, "MinimapCluster", 0) end
    if _G.Minimap and not seen[_G.Minimap] then scan(_G.Minimap, "Minimap", 0) end
    add("")

    -- 如果坐标元素不在小地图子树里，就在整个 UI 里找「数字,数字」格式的文字
    add("== 全局坐标文本扫描（UIParent 子树） ==")
    local hits, visited = 0, 0
    local globalSeen = {}
    local function scanGlobal(frame, path, depth)
        if not frame or depth > 6 or visited > 2500 or hits >= 20 then return end
        if globalSeen[frame] then return end
        globalSeen[frame] = true
        visited = visited + 1

        if SafeMethod(frame, "IsShown") == false then return end

        for _, region in ipairs(SafeRegions(frame)) do
            if SafeMethod(region, "GetObjectType") == "FontString" then
                local text = SafeTextOf(region)
                if text then
                    if LooksLikeCoords(text) then
                        hits = hits + 1
                        local okFormat, quoted = pcall(string.format, "%q", text)
                        add(string.format("%s.%s  shown=%s  %s",
                            path,
                            tostring(SafeMethod(region, "GetName") or "<无名字>"),
                            tostring(SafeMethod(region, "IsShown")),
                            tostring(okFormat and quoted or "<读取失败>")))
                    end
                end
            end
        end

        for _, child in ipairs(SafeChildren(frame)) do
            local childName = SafeMethod(child, "GetName")
            if not childName then childName = SafeMethod(child, "GetObjectType") or "?" end
            scanGlobal(child, path .. "." .. childName, depth + 1)
        end
    end
    scanGlobal(UIParent, "UIParent", 0)
    if hits == 0 then
        add("  未找到含坐标样式的 FontString（数字,数字 / 数字（数字））")
    end
    add("  扫描帧数=" .. tostring(visited) .. "  命中=" .. tostring(hits))
    add("")

    add("== 子元素清单 ==")
    local function ListChildren(frame, label)
        if not frame then
            add(label .. " = nil")
            return
        end
        local children = SafeChildren(frame)
        add(label .. " 子元素 " .. tostring(#children) .. " 个：")
        for _, child in ipairs(children) do
            add("  " .. tostring(SafeMethod(child, "GetName") or "?")
                .. " [" .. tostring(SafeMethod(child, "GetObjectType") or "?") .. "]"
                .. " shown=" .. tostring(SafeMethod(child, "IsShown")))
        end
    end
    ListChildren(cluster, "MinimapCluster")
    if container and container ~= cluster then
        ListChildren(container, "MinimapCluster.MinimapContainer")
    end

    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 事件与命令
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
for _, eventName in ipairs({
    "PLAYER_ENTERING_WORLD",
    "PLAYER_TOTEM_UPDATE",
    "UPDATE_MULTI_CAST_ACTIONBAR",
    "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR",
    "PLAYER_REGEN_ENABLED",
}) do
    pcall(frame.RegisterEvent, frame, eventName)
end

frame:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" then
        if addon == "Leatrix_Plus" then
            TryInitialize(true)
            C_Timer.After(1, ApplySystemTotemBar)
        elseif addon == addonName then
            -- 兜底：正常情况下 TOC 里的 LoadSavedVariablesFirst 会让保存变量
            -- 在文件加载前就绪，Core 和各模块拿到的是同一张表。
            -- 万一客户端没有提前恢复，保存变量会在文件加载后才覆盖全局，
            -- 此时把已保存的值合并回这张表，并让全局重新指向它，
            -- 保证之后所有勾选都能正常存盘。
            local saved = _G.LeatrixPlusExtDB
            if type(saved) == "table" and saved ~= DB then
                for key, value in pairs(saved) do
                    DB[key] = value
                end
                _G.LeatrixPlusExtDB = DB
            end
            TryInitialize(false)
        end
    elseif event == "PLAYER_LOGIN" then
        TryInitialize(false)
        C_Timer.After(2, function()
            if not TryInitialize(true) and not initMessageShown then
                initMessageShown = true
                if IsLeatrixPlusLoaded() then
                    print("|cffff3333LeatrixPlusExt|r 未找到 Leatrix Plus 主界面，也无法创建独立窗口。")
                else
                    print("|cffff3333LeatrixPlusExt|r 未检测到 Leatrix Plus，也无法创建独立窗口。")
                end
                print("|cff66ccffLeatrixPlusExt|r 输入 /lpext diag 查看诊断。")
            end
        end)
        C_Timer.After(1, ApplySystemTotemBar)
    else
        ApplySystemTotemBar()
    end
end)

SLASH_LEATRIXPLUSEXT1 = "/lpext"
SlashCmdList["LEATRIXPLUSEXT"] = function(message)
    local full = tostring(message or ""):lower():match("^%s*(.-)%s*$")
    local command, argument = full:match("^(%S+)%s*(.-)$")

    -- /lpext diag [layout|lfg|lfgfilter|lfgacts|questfocus|q2rs|questitemcleanup|minimap]：诊断窗口
    -- 不带参数时查看接入诊断；结果放在可复制的窗口里，方便整段复制
    if command == "diag" then
        local module = (argument ~= "" and argument) or "layout"
        if module == "minimap" or module == "coords" then
            -- 小地图结构诊断：找原生坐标元素，文本可直接复制
            ShowDiagnosticWindow("LeatrixPlusExt 小地图坐标诊断", BuildMinimapDiagnostics())
        elseif module == "layout" then
            ShowDiagnosticWindow("LeatrixPlusExt 接入诊断", BuildDiagnostics())
        elseif module == "lfg" then
            -- 寻求组队位置诊断（先打开寻求组队的浏览页）
            if type(ns.DiagnoseLFGWhere) == "function" then
                local lines = ns.DiagnoseLFGWhere()
                ShowDiagnosticWindow("LeatrixPlusExt 组队位置诊断", table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 寻求组队位置模块还没有加载。")
            end
        elseif module == "lfgfilter" then
            -- 寻求组队筛选的布局/状态诊断（先打开寻求组队浏览页）
            if type(ns.DiagnoseLFGFilter) == "function" then
                local lines = ns.DiagnoseLFGFilter()
                ShowDiagnosticWindow("LeatrixPlusExt 组队筛选诊断", table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 寻求组队筛选模块还没有加载。")
            end
        elseif module == "lfgacts" then
            -- 列出全部组队活动，标注哪些还没进副本所在地对照表
            if type(ns.ListLFGActivities) == "function" then
                local lines = ns.ListLFGActivities()
                ShowDiagnosticWindow("LeatrixPlusExt 组队活动列表", table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 寻求组队位置模块还没有加载。")
            end
        elseif module == "questitemcleanup" then
            if type(ns.DiagnoseQuestItemCleanup) == "function" then
                local lines = ns.DiagnoseQuestItemCleanup()
                ShowDiagnosticWindow("LeatrixPlusExt 任务物品标记诊断",
                    table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 标记多余的任务物品模块还没有加载。")
            end
        elseif module == "questfocus" then
            -- 自动设置任务焦点的状态诊断
            if type(ns.DiagnoseQuestFocus) == "function" then
                local lines = ns.DiagnoseQuestFocus()
                ShowDiagnosticWindow("LeatrixPlusExt 任务焦点诊断", table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 任务焦点模块还没有加载。")
            end
        elseif module == "q2rs" then
            -- 任务 NPC 加入 RareScanner 的状态诊断
            if type(ns.DiagnoseQuest2RareScanner) == "function" then
                local lines = ns.DiagnoseQuest2RareScanner()
                ShowDiagnosticWindow("LeatrixPlusExt 任务 NPC 追踪诊断", table.concat(lines or {}, "\n"))
            else
                print("|cff66ccffLeatrixPlusExt|r 任务 NPC 加入 RareScanner 模块还没有加载。")
            end
        else
            print("|cff66ccffLeatrixPlusExt|r 未知诊断模块：" .. tostring(module)
                .. "（可用：layout / lfg / lfgfilter / lfgacts / questfocus / q2rs / questitemcleanup / minimap）")
        end
        return
    end

    -- /lpext console [on|off]：调试控制台入口默认隐藏，用这个命令切换
    if command == "console" then
        local visible
        if argument == "on" or argument == "show" then
            visible = true
        elseif argument == "off" or argument == "hide" then
            visible = false
        else
            visible = not (DB.showDebugEntry == true)
        end
        SetDebugEntryVisible(visible)
        if visible then
            print("|cff66ccffLeatrixPlusExt|r 调试控制台入口已显示。")
        else
            print("|cff66ccffLeatrixPlusExt|r 调试控制台入口已隐藏。输入 /lpext console 可重新显示。")
        end
        return
    end

    -- /lpext reset：弹确认框，确认后恢复默认值并重载一次
    if command == "reset" then
        if argument == "confirm" then
            ResetAndReload()
        else
            ShowResetConfirm()
        end
        return
    end

    -- /lpext q2rs [delete|debug]：任务 NPC 加入 RareScanner 的帮助/状态/维护
    if command == "q2rs" then
        if type(ns.Q2RSCommand) == "function" then
            ns.Q2RSCommand(argument)
        else
            print("|cff66ccffLeatrixPlusExt|r 任务 NPC 加入 RareScanner 模块还没有加载。")
        end
        return
    end

    OpenExtension()
end

