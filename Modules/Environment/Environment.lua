-- LeatrixPlusExt 模块：在小地图原生坐标下方显示当前区域的环境类型
local addonName, NS = ...

local DATA = NS.EnvironmentData
local BIOME_BY_MAP = DATA and DATA.byMap or {}
local BIOME_BY_NAME = DATA and DATA.byName or {}

local UPDATE_RATE = 0.2

local TAG_ORDER = {
    "forest", "snow", "desert", "mountain", "swamp",
    "wasteland", "haunted", "underground", "stronghold",
}

local TAG_LABELS = {
    forest = "森林/草原",
    snow = "雪地",
    desert = "沙漠",
    mountain = "山地",
    swamp = "沼泽",
    wasteland = "荒地",
    haunted = "鬼魅",
    underground = "地下",
    stronghold = "要塞/城市",
}

local display
local ticker

-- 名称索引：英文名不区分大小写，中文名保持不变
local NAME_INDEX = {}
for name, tags in pairs(BIOME_BY_NAME) do
    NAME_INDEX[name] = tags
    local lower = string.lower(name)
    if NAME_INDEX[lower] == nil then
        NAME_INDEX[lower] = tags
    end
end

-- ---------------------------------------------------------------------------
-- 安全访问：这个客户端会返回机密数值，不能比较、不能运算
-- ---------------------------------------------------------------------------
local function Legible(value)
    if value == nil then
        return nil
    end
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if not ok or not allowed then
            return nil
        end
    end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then
            return nil
        end
    end
    return value
end

local function SafeString(value)
    value = Legible(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

local function SafeNumber(value)
    value = Legible(value)
    if type(value) ~= "number" then
        return nil
    end
    return value
end

local function GetAPIText(name)
    local fn = _G[name]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn)
    if not ok then
        return nil
    end
    return SafeString(value)
end

-- ---------------------------------------------------------------------------
-- 环境归类
-- ---------------------------------------------------------------------------
local function AddTags(target, list)
    if type(list) ~= "table" then
        return false
    end
    local added = false
    for _, tag in ipairs(list) do
        if TAG_LABELS[tag] then
            target[tag] = true
            added = true
        end
    end
    return added
end

-- 去掉「厄运之槌（东）」这类后缀，再查一次
local function StripAreaSuffix(name)
    local base = name:match("^(.-)%s*%(")
    if not base then
        base = name:match("^(.-)%s*（")
    end
    if base then
        base = base:match("^%s*(.-)%s*$")
        if base ~= "" then
            return base
        end
    end

    for _, suffix in ipairs({ "东", "西", "南", "北" }) do
        if name:sub(-#suffix) == suffix then
            base = name:sub(1, -#suffix - 1)
            base = base:match("^%s*(.-)%s*$")
            base = base:gsub("%-+%s*$", "")
            base = base:gsub("：%s*$", "")
            base = base:gsub(":%s*$", "")
            base = base:match("^%s*(.-)%s*$")
            if base ~= "" then
                return base
            end
        end
    end
    return nil
end

local function LookupName(name)
    if type(name) ~= "string" then
        return nil
    end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then
        return nil
    end

    local list = NAME_INDEX[name] or NAME_INDEX[string.lower(name)]
    if list then
        return list
    end

    local base = StripAreaSuffix(name)
    if base then
        return NAME_INDEX[base] or NAME_INDEX[string.lower(base)]
    end
    return nil
end

local function AddNameTags(tags, name)
    local list = LookupName(name)
    if not list then
        return false
    end
    return AddTags(tags, list)
end

-- 名字查不到时，沿地图层级向上找
local function AddMapTags(tags)
    local api = _G.C_Map
    if type(api) ~= "table" or type(api.GetBestMapForUnit) ~= "function" then
        return
    end

    local ok, mapID = pcall(api.GetBestMapForUnit, "player")
    mapID = ok and SafeNumber(mapID) or nil
    if not mapID then
        return
    end

    local seen = {}
    for _ = 1, 12 do
        if seen[mapID] then
            break
        end
        seen[mapID] = true

        AddTags(tags, BIOME_BY_MAP[mapID])

        if type(api.GetMapInfo) ~= "function" then
            break
        end
        local infoOK, info = pcall(api.GetMapInfo, mapID)
        if not infoOK or type(info) ~= "table" then
            break
        end
        local parent = SafeNumber(info.parentMapID)
        if not parent or parent == 0 or parent == mapID then
            break
        end
        mapID = parent
    end
end

local function CollectTags()
    local tags = {}
    local matched = false

    local names = {
        GetAPIText("GetRealZoneText"),
        GetAPIText("GetZoneText"),
        GetAPIText("GetMinimapZoneText"),
        GetAPIText("GetSubZoneText"),
    }
    for _, name in ipairs(names) do
        if AddNameTags(tags, name) then
            matched = true
        end
    end

    if not matched then
        AddMapTags(tags)
    end
    return tags
end

local function BuildText(tags)
    local parts = {}
    for _, tag in ipairs(TAG_ORDER) do
        if tags[tag] then
            parts[#parts + 1] = TAG_LABELS[tag]
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "·")
end

-- ---------------------------------------------------------------------------
-- 显示
-- ---------------------------------------------------------------------------
-- PlayerCoords 是一个 Frame，里面只有一个 FontString，文本形如「43.7（39.5）」
local function GetCoords()
    local cluster = _G.MinimapCluster
    local container = cluster and cluster.MinimapContainer
    local coords = container and container.PlayerCoords
    if not coords then
        return nil
    end

    local text = coords.CoordText
    if not text and type(coords.GetRegions) == "function" then
        local ok, region = pcall(coords.GetRegions, coords)
        if ok then
            text = region
        end
    end
    if not text then
        return nil
    end
    return coords, text
end

local function CoordsShown(coords)
    if type(coords.IsVisible) == "function" then
        local ok, shown = pcall(coords.IsVisible, coords)
        if not ok or not shown then
            return false
        end
    elseif type(coords.IsShown) == "function" then
        local ok, shown = pcall(coords.IsShown, coords)
        if not ok or not shown then
            return false
        end
    end

    local getBool = _G.GetCVarBool
    if type(getBool) == "function" then
        local ok, shown = pcall(getBool, "minimapShowPlayerCoords")
        if ok then
            shown = Legible(shown)
            if shown ~= nil then
                return shown and true or false
            end
        end
    end

    local get = _G.GetCVar
    if type(get) == "function" then
        local ok, value = pcall(get, "minimapShowPlayerCoords")
        if ok then
            value = Legible(value)
            if value == "0" or value == 0 or value == false or value == "false" then
                return false
            end
        end
    end
    return true
end

local function CreateDisplay(coords, text)
    local fs = coords:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")

    local font, size, flags
    if type(text.GetFont) == "function" then
        local ok, f, s, fl = pcall(text.GetFont, text)
        if ok then
            font, size, flags = SafeString(f), SafeNumber(s), SafeString(fl)
        end
    end
    if font then
        local ok = pcall(fs.SetFont, fs, font, size or 11, flags)
        if not ok then
            pcall(fs.SetFont, fs, "Fonts\\ARKai_T.ttf", 11)
        end
    else
        pcall(fs.SetFont, fs, "Fonts\\ARKai_T.ttf", 11)
    end

    if type(text.GetTextColor) == "function" then
        local ok, r, g, b, a = pcall(text.GetTextColor, text)
        r, g, b = SafeNumber(r), SafeNumber(g), SafeNumber(b)
        if r and g and b then
            pcall(fs.SetTextColor, fs, r, g, b, SafeNumber(a) or 1)
        end
    end
    return fs
end

-- 小地图标题在小地图下方时，坐标下方会被标题占用
local function HeaderUnderneath()
    local cluster = _G.MinimapCluster
    local zone = cluster and cluster.ZoneTextButton
    if not zone then
        return false
    end

    if type(zone.GetPoint) == "function" then
        local ok, point = pcall(zone.GetPoint, zone, 1)
        point = ok and SafeString(point) or nil
        if point == "BOTTOM" or point == "BOTTOMLEFT" or point == "BOTTOMRIGHT" then
            return true
        end
    end

    -- 有些界面会重新锚定标题按钮，锚点看不出位置时按实际几何判断
    local minimap = cluster.MinimapContainer and cluster.MinimapContainer.Minimap
    if minimap and type(zone.GetTop) == "function" and type(minimap.GetBottom) == "function" then
        local okTop, zoneTop = pcall(zone.GetTop, zone)
        local okBottom, minimapBottom = pcall(minimap.GetBottom, minimap)
        zoneTop, minimapBottom = Legible(zoneTop), Legible(minimapBottom)
        if okTop and okBottom
            and type(zoneTop) == "number" and type(minimapBottom) == "number" then
            return zoneTop < minimapBottom
        end
    end
    return false
end

-- 默认放在坐标下方；小地图标题在下方时改放到坐标上方
local function AnchorDisplay(fs, coords)
    fs:ClearAllPoints()
    if HeaderUnderneath() then
        fs:SetPoint("BOTTOM", coords, "TOP", 0, 2)
    else
        fs:SetPoint("TOP", coords, "BOTTOM", 0, -2)
    end
end

local function Update()
    local coords, text = GetCoords()
    if not coords or not CoordsShown(coords) then
        if display then
            display:Hide()
        end
        return
    end

    local value = BuildText(CollectTags())
    if not value then
        if display then
            display:Hide()
        end
        return
    end

    if not display then
        display = CreateDisplay(coords, text)
    end
    if not display then
        return
    end

    AnchorDisplay(display, coords)
    display:SetText(value)
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
    key = "showEnvironment",
    section = "系统界面",
    label = "显示当前环境",
    tip = "在小地图坐标下方显示当前区域的环境类型，例如沙漠、雪地、森林/草原。\n\n一个区域可能同时属于多种环境，会用「·」分隔。",
    default = true,
    onToggle = function(enabled)
        Apply(enabled and true or false)
    end,
})
