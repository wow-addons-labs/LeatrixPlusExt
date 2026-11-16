-- LeatrixPlusExt 模块：调试
local addonName, NS = ...

local Utils = NS.Utils
local DB = NS.DB
local SafeMethod = Utils.SafeMethod
local SafeString = Utils.SafeString
local AddLine = Utils.AddLine
local MakeHeading = Utils.MakeHeading

local commandBox, outputBox, outputScroll

-- ---------------------------------------------------------------------------
-- 调试数据
-- ---------------------------------------------------------------------------
local function CollectMouseFrame()
    local lines = {}
    local frame = GetMouseFocus()
    if not frame then
        return "鼠标下没有 frame。"
    end
    AddLine(lines, "鼠标下的 frame 链：")
    local current = frame
    for depth = 1, 8 do
        if not current then break end
        local name = SafeMethod(current, "GetName")
        local objType = SafeMethod(current, "GetObjectType")
        local shown = SafeMethod(current, "IsShown")
        local visible = SafeMethod(current, "IsVisible")
        AddLine(lines, string.format("%d: %s [%s] shown=%s visible=%s",
            depth, tostring(name or "nil"), tostring(objType or "?"),
            tostring(shown), tostring(visible)))
        current = SafeMethod(current, "GetParent")
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 调试控制台
-- ---------------------------------------------------------------------------
local function SetOutput(text)
    if not outputBox then return end
    text = tostring(text or "")
    outputBox:SetText(text)
    outputBox:SetCursorPosition(0)
    local _, newlines = text:gsub("\n", "\n")
    local height = math.max(20, (newlines + 1) * 14 + 12)
    outputBox:SetHeight(height)
    if outputScroll then
        outputScroll:SetVerticalScroll(0)
    end
end

-- 追加一行输出（供其他模块实时写入控制台）
-- 面板还没创建时先缓存，等输出框建好再一次性补上
local pendingOutput = {}

local function AppendOutput(text)
    text = tostring(text or "")
    if text == "" then return end
    if not outputBox then
        pendingOutput[#pendingOutput + 1] = text
        if #pendingOutput > 200 then table.remove(pendingOutput, 1) end
        return
    end
    local current = outputBox:GetText() or ""
    if #current > 0 then
        current = current .. "\n"
    end
    -- 控制台只保留最近的输出，避免长时间运行后越积越大
    if #current > 20000 then
        current = current:sub(-16000)
        local cut = current:find("\n", 1, true)
        if cut then current = current:sub(cut + 1) end
    end
    SetOutput(current .. text)
    -- 滚到最新一行
    if outputScroll and outputScroll.GetVerticalScrollRange then
        local ok, range = pcall(outputScroll.GetVerticalScrollRange, outputScroll)
        if ok and range then outputScroll:SetVerticalScroll(range) end
    end
end
NS.AppendDebugLine = AppendOutput

local function FlushPendingOutput()
    if #pendingOutput == 0 or not outputBox then return end
    local text = table.concat(pendingOutput, "\n")
    pendingOutput = {}
    AppendOutput(text)
end

local function RunLua(code)
    code = tostring(code or "")
    if code:match("^%s*$") then
        return "请输入 Lua 代码。"
    end

    local lines = {}
    local oldPrint = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = SafeString(select(i, ...))
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end

    local loader = loadstring or load
    local chunk, compileError
    if type(loader) == "function" then
        chunk, compileError = loader(code, "LeatrixPlusExtConsole")
    else
        compileError = "当前客户端没有 loadstring/load"
    end

    local runOk, runResult
    if chunk then
        runOk, runResult = pcall(chunk)
    end

    _G.print = oldPrint

    if not chunk then
        return "编译错误：" .. tostring(compileError)
    end
    if not runOk then
        return "运行错误：" .. SafeString(runResult)
    end
    if runResult ~= nil then
        lines[#lines + 1] = "返回：" .. SafeString(runResult)
    end
    if #lines == 0 then
        lines[1] = "（执行完成，无输出）"
    end
    return table.concat(lines, "\n")
end

local function Execute()
    if not commandBox then return end
    local code = commandBox:GetText() or ""
    DB.lastCommand = code
    SetOutput("> " .. code .. "\n" .. RunLua(code))
    commandBox:ClearFocus()
end

local function ExecuteAndShowResult(title, text)
    SetOutput("== " .. title .. " ==\n" .. text)
end

-- ---------------------------------------------------------------------------
-- 配置项读取
-- 列出插件能设置的 CVar：系统当前值、系统默认值、插件开关和插件数值。
-- 数值可调的选项和 ClientTweaks.lua 里的滑条对应；括号里的「默认」是插件默认值。
-- ---------------------------------------------------------------------------
local CONFIG_CVARS = {
    {
        label = "任务物品高亮",
        switchKey = "questItemHighlight",
        enabledValue = "1",
        cvars = { "outlineModeShowLootEffectWhenDisabled" },
    },
    {
        label = "扩大血条显示距离",
        switchKey = "nameplateDistance",
        valueKey = "nameplateDistanceValue",
        fallbackValue = 41,
        cvars = { "nameplateMaxDistance" },
    },
    {
        label = "放大伤害/治疗数字",
        switchKey = "worldTextScale",
        valueKey = "worldTextScaleValue",
        fallbackValue = 3,
        cvars = { "WorldTextScale", "WorldTextScale_v2" },
    },
}

local function FormatSwitch(value)
    if value == true then return "开" end
    if value == false then return "关" end
    return "未设置"
end

-- 插件启用时应该写入的值；没有数值项的功能用 enabledValue
local function GetPluginValue(item)
    if item.enabledValue then return item.enabledValue end
    if item.valueKey then
        local value = DB[item.valueKey]
        if type(value) == "number" then return tostring(value) end
        if item.fallbackValue then return tostring(item.fallbackValue) end
    end
    return nil
end

-- 部分客户端把 CVar 标成机密值或直接返回 nil；去掉浮点默认值后面的多余 0
local function TrimNumber(text)
    if type(text) ~= "string" or not text:match("^%-?%d+%.%d+$") then
        return text
    end
    text = text:gsub("0+$", ""):gsub("%.$", "")
    if text == "-0" then return "0" end
    return text
end

local function DescribeValue(value)
    local okNil, isNil = pcall(function() return value == nil end)
    if not okNil then return nil, "机密值" end
    if isNil then return nil, "返回 nil" end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then return nil, "机密值" end
    end
    local ok, text = pcall(tostring, value)
    if ok and text ~= nil then return TrimNumber(text), nil end
    return nil, "无法转成文本"
end

-- C_CVar.GetCVarInfo：名字不存在时返回 nil，存在时返回「当前值, 默认值, ...」。
-- 返回 true/false，nil 表示客户端没有这个接口、无法判断。
local function CVarExists(cvar)
    local api = _G.C_CVar
    if type(api) ~= "table" or type(api.GetCVarInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(api.GetCVarInfo, cvar)
    if not ok then return false end
    local okNil, isNil = pcall(function() return info == nil end)
    if not okNil then return nil end
    return not isNil
end

local function TryCVarFunction(name, fn, cvar)
    if type(fn) ~= "function" then return nil, name .. " 无接口" end
    local ok, value = pcall(fn, cvar)
    if not ok then return nil, name .. " 调用报错" end
    local text, reason = DescribeValue(value)
    if text == nil then return nil, name .. " " .. reason end
    return text
end

-- 依次尝试新旧两套接口，成功时返回值；失败时返回原因，方便判断是客户端没暴露还是机密值
local function ReadCVarDetailed(cvar, getDefault)
    local reasons = {}

    local function Attempt(name, fn)
        local text, reason = TryCVarFunction(name, fn, cvar)
        if text ~= nil then return text end
        reasons[#reasons + 1] = reason
        return nil
    end

    if getDefault then
        local api = _G.C_CVar
        if type(api) == "table" then
            local text = Attempt("C_CVar.GetCVarDefault", api.GetCVarDefault)
            if text then return text end
        else
            reasons[#reasons + 1] = "C_CVar 不存在"
        end
        local text = Attempt("GetCVarDefault", _G.GetCVarDefault)
        if text then return text end
    else
        local text = Attempt("GetCVar", _G.GetCVar)
        if text then return text end
        local api = _G.C_CVar
        if type(api) == "table" then
            text = Attempt("C_CVar.GetCVar", api.GetCVar)
            if text then return text end
        else
            reasons[#reasons + 1] = "C_CVar 不存在"
        end
    end
    return "读不到", table.concat(reasons, "；")
end

local function CollectConfigValues()
    local lines = {}
    local backups = type(DB.cvarBackups) == "table" and DB.cvarBackups or nil

    for _, item in ipairs(CONFIG_CVARS) do
        local switch = DB[item.switchKey]
        local expected = GetPluginValue(item)

        AddLine(lines, item.label)
        for _, cvar in ipairs(item.cvars) do
            -- GetCVarInfo 能明确区分「客户端没有这个设置」和「有但读不到」
            if CVarExists(cvar) == false then
                AddLine(lines, string.format("  %s：客户端没有这个设置", cvar))
            else
                local current, currentReason = ReadCVarDetailed(cvar, false)
                local default, defaultReason = ReadCVarDetailed(cvar, true)

                local backup = nil
                if backups then backup = backups[cvar] end
                local backupText
                if backup == nil then
                    backupText = "无"
                elseif backup == false then
                    backupText = "读不到"
                else
                    backupText = SafeString(backup)
                end

                -- 功能开着但系统值和插件设置不一样，多半是客户端拒绝了写入；
                -- 读不到时无法核对，不能当成「不一致」
                local mark = ""
                if switch == true and expected ~= nil then
                    if current == "读不到" then
                        mark = "  ← 客户端读不到，无法核对"
                    elseif current ~= expected then
                        mark = "  ← 与插件设置不一致"
                    end
                end

                AddLine(lines, string.format("  %s：当前=%s  默认=%s  备份=%s%s",
                    cvar, current, default, backupText, mark))

                local reasons = {}
                if current == "读不到" and currentReason then
                    reasons[#reasons + 1] = "当前 " .. currentReason
                end
                if default == "读不到" and defaultReason and defaultReason ~= currentReason then
                    reasons[#reasons + 1] = "默认 " .. defaultReason
                end
                if #reasons > 0 then
                    AddLine(lines, "    读不到原因：" .. table.concat(reasons, "；"))
                end
            end
        end

        local plugin = "  插件：开关=" .. FormatSwitch(switch)
        if item.valueKey then
            local value = DB[item.valueKey]
            if type(value) == "number" then
                plugin = plugin .. "  数值=" .. SafeString(value)
            elseif item.fallbackValue then
                plugin = plugin .. "  数值=" .. tostring(item.fallbackValue) .. "（默认）"
            else
                plugin = plugin .. "  数值=未设置"
            end
        end
        AddLine(lines, plugin)
    end

    AddLine(lines, "")
    AddLine(lines, "「备份」是插件第一次改这个 CVar 前读到的原值，关闭功能时用它还原。")
    AddLine(lines, "「客户端没有这个设置」表示当前版本不提供该 CVar，写了也不会生效。")
    AddLine(lines, "「读不到」表示客户端有这项设置，但没把值暴露给 Lua（可能被标记为机密值），"
        .. "插件无法核对设置是否生效。")
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- CVar 支持探测
-- 判断插件用到的设置在当前客户端里是否真的存在：
--   1. 有 C_Console.GetAllCommands 时，直接读取客户端注册的全部 CVar / 命令；
--   2. 同时记录 GetCVar / GetCVarInfo / GetCVarDefault 的结果；
--   3. 对已知存在的 CVar 做一次写入测试，确认客户端接受写入。
-- ---------------------------------------------------------------------------
local CVAR_PROBE_NAMES = {
    "nameplateMaxDistance",
    "WorldTextScale",
    "WorldTextScale_v2",
}

-- 外部参考资料：
--   BleakfibersUnitToggles-Forever（同为 Interface 16001）在 Config.lua 里使用下面这 20 个 CVar；
--   botwowforever 的控制台命令指南列出 cameraDistanceMaxZoomFactor（1.9 - 2.6）和
--   nameplateMaxVerticalDistance。这里只做存在性检查，方便判断本客户端能不能用。
local UNIT_NAME_CVARS = {
    "UnitNameFriendlyPlayerName", "UnitNameFriendlyPetName",
    "UnitNameFriendlyMinionName", "UnitNameFriendlyGuardianName",
    "UnitNameFriendlyTotemName", "UnitNameFriendlySpecialNPCName",
    "UnitNameOwn", "UnitNameNPC", "UnitNameInteractiveNPC",
    "UnitNameNonCombatCreatureName", "UnitNameEnemyPlayerName",
    "UnitNameEnemyPetName", "UnitNameEnemyMinionName",
    "UnitNameEnemyGuardianName", "UnitNameEnemyTotemName",
    "UnitNameHostleNPC", "UnitNamePlayerGuild", "UnitNameGuildTitle",
    "UnitNamePlayerPVPTitle", "UnitNameForceHideMinus",
}
local REFERENCE_CVARS = {
    "cameraDistanceMaxZoomFactor",
    "nameplateMaxVerticalDistance",
    -- 部分客户端用它单独限制玩家姓名板的距离；为 0 时远处玩家血条不显示
    "nameplatePlayerMaxDistance",
}

local function CVarStateText(cvar)
    if CVarExists(cvar) == false then return "客户端没有" end
    local current, reason = ReadCVarDetailed(cvar, false)
    local default = ReadCVarDetailed(cvar, true)
    if current == "读不到" and default == "读不到" then
        return "读不到（" .. tostring(reason) .. "）"
    end
    return string.format("当前=%s  默认=%s", current, default)
end

local function ResolveAPI(path)
    local current = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(current) ~= "table" then return nil end
        local ok, value = pcall(function() return current[part] end)
        if not ok then return nil end
        current = value
    end
    return current
end

-- 机密值不能用 == nil / tostring 直接判断，比较也要放进 pcall
local function IsNilValue(value)
    local ok, isNil = pcall(function() return value == nil end)
    return ok and isNil
end

local function DescribeCall(path, cvar)
    local fn = ResolveAPI(path)
    if type(fn) ~= "function" then return "无接口" end
    local ok, a, b, c = pcall(fn, cvar)
    if not ok then return "报错：" .. SafeString(a) end
    local parts = {}
    if not IsNilValue(a) then parts[#parts + 1] = SafeString(a) end
    if not IsNilValue(b) then parts[#parts + 1] = SafeString(b) end
    if not IsNilValue(c) then parts[#parts + 1] = SafeString(c) end
    if #parts == 0 then return "返回 nil" end
    return "返回：" .. table.concat(parts, ", ")
end

local function SetCVarResult(path, cvar, value)
    local fn = ResolveAPI(path)
    if type(fn) ~= "function" then return "无接口" end
    local ok, result = pcall(fn, cvar, tostring(value))
    if not ok then return "报错：" .. SafeString(result) end
    return "返回：" .. SafeString(result)
end

-- C_Console.GetAllCommands 在不同版本里可能返回数组或「名称 -> 记录」的表，
-- 两种都按名称整理出来
local function CollectCommandList()
    local fn = ResolveAPI("C_Console.GetAllCommands")
    if type(fn) ~= "function" then
        return nil, "当前客户端没有 C_Console.GetAllCommands"
    end
    local ok, list = pcall(fn)
    if not ok then return nil, "调用报错：" .. SafeString(list) end
    if type(list) ~= "table" then return nil, "返回值不是表" end

    local names, seen = {}, {}
    local function Add(name, entry)
        if type(name) ~= "string" or name == "" or seen[name] then return end
        seen[name] = true
        names[#names + 1] = { name = name, entry = entry }
    end

    for key, entry in pairs(list) do
        if type(entry) == "table" then
            local name = entry.command or entry.name
            if not name and type(key) == "string" then name = key end
            Add(name, entry)
        elseif type(entry) == "string" then
            Add(entry, nil)
        elseif type(key) == "string" then
            Add(key, nil)
        end
    end
    table.sort(names, function(a, b) return a.name < b.name end)
    return names
end

local function CollectCVarSupport()
    local lines = {}
    AddLine(lines, "== 客户端接口 ==")
    local apiPaths = {
        "C_Console.GetAllCommands",
        "C_CVar.GetCVar", "C_CVar.GetCVarDefault", "C_CVar.GetCVarInfo", "C_CVar.SetCVar",
        "GetCVar", "GetCVarDefault", "GetCVarInfo", "GetCVarMin", "GetCVarMax", "SetCVar",
    }
    for _, path in ipairs(apiPaths) do
        AddLine(lines, string.format("  %s：%s", path,
            type(ResolveAPI(path)) == "function" and "有" or "没有"))
    end

    AddLine(lines, "")
    local commands, listError = CollectCommandList()
    if commands then
        AddLine(lines, "== 客户端注册的 CVar / 命令 ==")
        AddLine(lines, "共 " .. #commands .. " 个")
        AddLine(lines, "要列出全部名称，在 Lua 命令框执行：")
        AddLine(lines, [[local t={} for _,v in pairs(C_Console.GetAllCommands()) do t[#t+1]=v.command end table.sort(t) return table.concat(t,"\n")]])
    else
        AddLine(lines, "== 客户端注册的 CVar / 命令 ==")
        AddLine(lines, "  " .. tostring(listError))
    end

    AddLine(lines, "")
    AddLine(lines, "== 存在性测试 ==")
    local readers = {
        "GetCVar", "C_CVar.GetCVar",
        "GetCVarDefault", "C_CVar.GetCVarDefault",
        "GetCVarInfo", "C_CVar.GetCVarInfo",
    }
    local availableReaders = {}
    for _, path in ipairs(readers) do
        if type(ResolveAPI(path)) == "function" then
            availableReaders[#availableReaders + 1] = path
        end
    end
    if #availableReaders == 0 then
        AddLine(lines, "  客户端没有任何 GetCVar 类接口。")
    end

    local setterPath = type(ResolveAPI("SetCVar")) == "function"
        and "SetCVar" or "C_CVar.SetCVar"

    for _, cvar in ipairs(CVAR_PROBE_NAMES) do
        AddLine(lines, "")
        AddLine(lines, cvar .. "：")
        if #availableReaders == 0 then
            AddLine(lines, "    没有可用的读取接口")
        else
            for _, path in ipairs(availableReaders) do
                AddLine(lines, "    " .. path .. "：" .. DescribeCall(path, cvar))
            end
        end
    end

    AddLine(lines, "")
    AddLine(lines, "== 参考资料中的 CVar ==")
    for _, cvar in ipairs(REFERENCE_CVARS) do
        AddLine(lines, "  " .. cvar .. "：" .. CVarStateText(cvar))
    end
    local unitKnown, unitMissing, unitUnknown = 0, {}, 0
    for _, cvar in ipairs(UNIT_NAME_CVARS) do
        local exists = CVarExists(cvar)
        if exists == true then
            unitKnown = unitKnown + 1
        elseif exists == false then
            unitMissing[#unitMissing + 1] = cvar
        else
            unitUnknown = unitUnknown + 1
        end
    end
    local unitText = string.format("  UnitName 系列 %d 个：存在 %d 个",
        #UNIT_NAME_CVARS, unitKnown)
    if unitUnknown > 0 then
        unitText = unitText .. string.format("，无法判断 %d 个", unitUnknown)
    end
    AddLine(lines, unitText)
    if #unitMissing > 0 then
        AddLine(lines, "    客户端没有：" .. table.concat(unitMissing, "、"))
    end

    AddLine(lines, "")
    AddLine(lines, "== 写入测试 ==")
    local nameplateValue = Utils.GetCVarValue("nameplateMaxDistance")
    if nameplateValue then
        AddLine(lines, "  nameplateMaxDistance（写成当前值 " .. nameplateValue .. "，不会改变设置）")
        AddLine(lines, "    " .. SetCVarResult(setterPath, "nameplateMaxDistance", nameplateValue))
    else
        AddLine(lines, "  nameplateMaxDistance 读不到，无法测试写入。")
    end

    AddLine(lines, "")
    AddLine(lines, "== 结论 ==")
    local summary = {}
    for _, cvar in ipairs(CVAR_PROBE_NAMES) do
        local exists = CVarExists(cvar)
        local text
        if exists == true then
            text = "存在"
        elseif exists == false then
            text = "客户端没有"
        else
            text = "无法判断"
        end
        summary[#summary + 1] = cvar .. " " .. text
    end
    AddLine(lines, "  插件用到的 CVar：" .. table.concat(summary, "；"))
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 构建二级配置页内容
-- （坐标与官方配置面板一致：左上角 16,-72；控件从 0,0 开始）
-- ---------------------------------------------------------------------------
local function BuildDebugPanel(parent)
    MakeHeading(parent, "Lua 命令", 0, 0)

    commandBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    commandBox:SetPoint("TOPLEFT", 0, -20)
    commandBox:SetSize(430, 24)
    commandBox:SetAutoFocus(false)
    commandBox:SetMaxLetters(0)
    pcall(commandBox.SetFontObject, commandBox, GameFontNormal)
    commandBox:SetTextColor(1.0, 1.0, 1.0)
    commandBox:SetText(DB.lastCommand or "")
    commandBox:SetScript("OnEscapePressed", commandBox.ClearFocus)
    commandBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Execute()
    end)
    Utils.AddInputBackdrop(commandBox)

    local runButton = Utils.CreateButton(parent, "执行", "执行输入的 Lua 代码。", parent)
    runButton:SetPoint("LEFT", commandBox, "RIGHT", 8, 0)
    runButton:SetScript("OnClick", Execute)

    local mouseButton = Utils.CreateButton(parent, "3 秒取鼠标元素",
        "点击后 3 秒内把鼠标移到目标上，查看它对应的界面元素。", parent)
    mouseButton:SetPoint("TOPLEFT", 0, -52)
    mouseButton:SetScript("OnClick", function()
        ExecuteAndShowResult("鼠标界面元素", "3 秒内把鼠标移到目标上……")
        C_Timer.After(3, function()
            ExecuteAndShowResult("鼠标界面元素", CollectMouseFrame())
        end)
    end)

    local clearButton = Utils.CreateButton(parent, "清空输出", "清空下方输出。", parent)
    clearButton:SetPoint("LEFT", mouseButton, "RIGHT", 8, 0)
    clearButton:SetScript("OnClick", function() SetOutput("") end)

    local copyButton = Utils.CreateButton(parent, "全选复制", "选中全部输出，按 Ctrl+C 复制。", parent)
    copyButton:SetPoint("LEFT", clearButton, "RIGHT", 8, 0)
    copyButton:SetScript("OnClick", function()
        if outputBox then
            outputBox:SetFocus()
            outputBox:HighlightText()
        end
    end)

    local configButton = Utils.CreateButton(parent, "读取配置项",
        "读取插件涉及的游戏设置：当前值、默认值和插件开关/数值。", parent)
    configButton:SetPoint("LEFT", copyButton, "RIGHT", 8, 0)
    configButton:SetScript("OnClick", function()
        ExecuteAndShowResult("配置项", CollectConfigValues())
    end)

    local cvarButton = Utils.CreateButton(parent, "CVar 探测",
        "检查插件用到的 CVar 在本客户端是否存在，并附带参考资料里的相关设置。", parent)
    cvarButton:SetPoint("LEFT", configButton, "RIGHT", 8, 0)
    cvarButton:SetScript("OnClick", function()
        ExecuteAndShowResult("CVar 探测", CollectCVarSupport())
    end)

    MakeHeading(parent, "输出", 0, -86)

    -- 内容区高 200（面板 370 - 顶部 72 - 底部 98）；输出区底边留 6px 边距
    local _, scroll = Utils.CreateScrollArea(parent, 0, -106, 0, 6)
    outputScroll = scroll

    outputBox = CreateFrame("EditBox", nil, scroll)
    outputBox:SetMultiLine(true)
    outputBox:SetAutoFocus(false)
    outputBox:SetWidth(495)
    outputBox:SetHeight(20)
    outputBox:SetPoint("TOPLEFT", scroll, "TOPLEFT", 2, -2)
    outputBox:SetTextInsets(4, 4, 2, 2)
    outputBox:SetMaxLetters(0)
    pcall(outputBox.SetFontObject, outputBox, GameFontNormal)
    outputBox:SetTextColor(1.0, 1.0, 1.0)
    outputBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(outputBox)

    SetOutput("")
    FlushPendingOutput()
end

NS.RegisterModule({
    key = "debugEnabled",
    section = "调试",
    label = "启用调试控制台",
    bottomRow = true,
    -- 入口默认隐藏；输入 /lpext console 显示（设置保存在 LeatrixPlusExtDB.showDebugEntry）
    isVisible = function()
        return DB.showDebugEntry == true
    end,
    tip = "启用后可打开调试控制台，并显示其他功能的调试入口。"
        .. "\n\n控制台用于执行 Lua 命令和查看输出，输出可选中复制。",
    default = false,
    panelTitle = "调试控制台",
    panelDesc = "",
    buildPanel = BuildDebugPanel,
    reset = function()
        DB.lastCommand = ""
        if commandBox then commandBox:SetText("") end
        SetOutput("")
    end,
    onToggle = function(enabled)
        if not enabled and NS.HideConfigPanel then
            NS.HideConfigPanel("debugEnabled")
        end
    end,
})
