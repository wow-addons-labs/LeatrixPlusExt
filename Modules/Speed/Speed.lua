-- LeatrixPlusExt 模块：把移动速度显示在小地图原生坐标后面
local addonName, NS = ...

local DB = NS.DB

local UPDATE_RATE = 0.2

-- 这个客户端的 GetUnitSpeed 返回机密数值，不能比较、不能算术，
-- 只能交给 AbbreviateNumbers 缩放：0.0699 ≈ 7 码/秒 ÷ 100。
local SPEED_OPTIONS = {
    breakpointData = {
        {
            breakpoint = 0,
            abbreviation = "%",
            significandDivisor = 0.0699,
            fractionDivisor = 1,
            abbreviationIsGlobal = false,
        },
    },
}

local display
local ticker

-- PlayerCoords 是一个 Frame，里面只有一个 FontString，文本形如「43.7（39.5）」
local function GetCoordsText()
    local cluster = _G.MinimapCluster
    local container = cluster and cluster.MinimapContainer
    local coords = container and container.PlayerCoords
    if not coords then
        return nil
    end
    return coords, coords:GetRegions()
end

local function Update()
    local coords, text = GetCoordsText()
    if not coords or not text then
        return
    end

    if not display then
        display = coords:CreateFontString(nil, "OVERLAY")
        display:SetJustifyH("LEFT")
        display:SetJustifyV("MIDDLE")

        local font, size, flags = text:GetFont()
        if font then
            display:SetFont(font, size, flags)
        else
            display:SetFont("Fonts\\ARKai_T.ttf", 11)
        end
        display:SetTextColor(text:GetTextColor())
    end

    -- 贴在坐标文字右侧；和坐标在同一个（被缩放的）框里，偏移不用换算
    local width = text:GetStringWidth() or 0
    local justify = text:GetJustifyH()
    display:ClearAllPoints()
    if justify == "CENTER" then
        display:SetPoint("LEFT", text, "CENTER", width / 2 + 4, 0)
    elseif justify == "RIGHT" then
        display:SetPoint("LEFT", text, "RIGHT", 4, 0)
    else
        display:SetPoint("LEFT", text, "LEFT", width + 4, 0)
    end

    display:SetText(AbbreviateNumbers(GetUnitSpeed("player"), SPEED_OPTIONS))
    display:Show()
end

local function Apply(enabled)
    if enabled then
        if not ticker then
            ticker = C_Timer.NewTicker(UPDATE_RATE, Update)
        end
        Update()
    else
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
        if display then
            display:Hide()
        end
    end
end

NS.RegisterModule({
    key = "showPlayerSpeed",
    section = "系统界面",
    label = "显示移动速度",
    tip = "在小地图坐标后面显示当前移动速度（百分比）。\n\n隐藏小地图坐标时，速度文字也会一起隐藏。",
    default = true,
    onToggle = function(enabled)
        Apply(enabled and true or false)
    end,
})
