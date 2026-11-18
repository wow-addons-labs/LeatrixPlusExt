-- LeatrixPlusExt 模块：在背包、银行和角色装备栏显示物品等级
local addonName, NS = ...

local TEXT_SIZE = 12
local UPDATE_RATE = 1

local enabled = false
local ticker
local queued = false

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
end

local function Number(value)
    if type(value) ~= "number" then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then return nil end
    end
    if type(canaccessvalue) == "function" then
        local ok, accessible = pcall(canaccessvalue, value)
        if ok and accessible == false then return nil end
    end
    return value
end

local function Text(value)
    if type(value) ~= "string" or value == "" then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then return nil end
    end
    if type(canaccessvalue) == "function" then
        local ok, accessible = pcall(canaccessvalue, value)
        if ok and accessible == false then return nil end
    end
    return value
end

-- ---------------------------------------------------------------------------
-- 物品信息
-- ---------------------------------------------------------------------------
-- 会显示等级的装备部位：武器和护甲，排除背包、弹药、箭袋、衬衣、战袍
local GEAR_EQUIP = {}
for _, key in ipairs({
    "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_CHEST", "INVTYPE_ROBE",
    "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND",
    "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_CLOAK",
    "INVTYPE_WEAPON", "INVTYPE_WEAPONMAINHAND", "INVTYPE_2HWEAPON", "INVTYPE_WEAPONOFFHAND",
    "INVTYPE_SHIELD", "INVTYPE_HOLDABLE",
    "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC",
}) do
    GEAR_EQUIP[key] = true
end

-- 品质色兜底（客户端的 GetItemQualityColor 不可用或返回机密值时使用）
local QUALITY_FALLBACK = {
    [0] = { 0.62, 0.62, 0.62 },
    [1] = { 0.94, 0.94, 0.94 },
    [2] = { 0.12, 0.78, 0.00 },
    [3] = { 0.00, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 },
    [5] = { 0.88, 0.38, 0.00 },
    [6] = { 0.90, 0.80, 0.50 },
    [7] = { 0.31, 0.77, 0.88 },
}

local itemCache = {}
local itemCount = 0

local function ItemIDOf(link)
    local ok, value = pcall(string.match, link, "item:(%d+)")
    if ok and value then return tonumber(value) end
end

local function RequestItem(itemID)
    if not itemID then return end
    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local function ItemInfo(link)
    link = Text(link)
    if not link then return nil end

    local hit = itemCache[link]
    if hit then return hit end

    local itemID = ItemIDOf(link)
    if not itemID then return nil end

    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, equipLoc, _, classID = Call(getInstant, link)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, quality, baseLevel = Call(getInfo, link)
    if not Text(name) then
        RequestItem(itemID)
        return nil
    end

    local getLevel = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    local level = Number(Call(getLevel, link)) or Number(baseLevel)
    if not level then
        RequestItem(itemID)
        return nil
    end

    local info = {
        level = level,
        quality = Number(quality),
        equipLoc = Text(equipLoc),
        classID = Number(classID),
    }

    if itemCount > 3000 then
        wipe(itemCache)
        itemCount = 0
    end
    itemCache[link] = info
    itemCount = itemCount + 1
    return info
end

local function IsGear(info)
    if type(info) ~= "table" then return false end
    if not info.level or info.level <= 1 then return false end
    if info.classID ~= 2 and info.classID ~= 4 then return false end
    if not info.quality or info.quality <= 0 then return false end
    if not (info.equipLoc and GEAR_EQUIP[info.equipLoc]) then return false end
    return true
end

local qualityColors = {}
local function QualityColor(quality)
    quality = Number(quality) or 1
    local cached = qualityColors[quality]
    if cached then return cached[1], cached[2], cached[3] end

    local r, g, b
    if C_Item and type(C_Item.GetItemQualityColor) == "function" then
        local ok, rr, gg, bb = pcall(C_Item.GetItemQualityColor, quality)
        if ok then
            r, g, b = Number(rr), Number(gg), Number(bb)
        end
    end
    if not (r and g and b) then
        local fallback = QUALITY_FALLBACK[quality]
        if fallback then
            r, g, b = fallback[1], fallback[2], fallback[3]
        end
    end
    if not (r and g and b) then
        r, g, b = 1, 1, 1
    end

    cached = { r, g, b }
    qualityColors[quality] = cached
    return r, g, b
end

-- ---------------------------------------------------------------------------
-- 数字
-- ---------------------------------------------------------------------------
local FONT_BASE = rawget(_G, "NumberFont_Outline_Med") or rawget(_G, "NumberFontNormal")
local overlays = setmetatable({}, { __mode = "k" })

local function FontPath()
    if FONT_BASE and type(FONT_BASE.GetFont) == "function" then
        local ok, path = pcall(FONT_BASE.GetFont, FONT_BASE)
        if ok then
            path = Text(path)
            if path then return path end
        end
    end
    return "Fonts\\ARKai_T.ttf"
end

local function CreateOverlay(button)
    local overlay = overlays[button]
    if overlay then return overlay end

    overlay = CreateFrame("Frame", nil, button)
    overlay:SetAllPoints(button)
    overlay:EnableMouse(false)

    local frameLevel = Number(Call(button.GetFrameLevel, button))
    if frameLevel then
        pcall(overlay.SetFrameLevel, overlay, frameLevel + 4)
    end

    local text = overlay:CreateFontString(nil, "ARTWORK")
    pcall(text.SetDrawLayer, text, "ARTWORK", 1)
    text:SetPoint("TOPLEFT", 2, -2)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    local path = FontPath()
    pcall(text.SetFont, text, path, TEXT_SIZE, "OUTLINE")
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 0.8)
    text:Hide()

    overlay.text = text
    overlays[button] = overlay
    return overlay
end

local function HideLevel(button)
    local overlay = overlays[button]
    if not overlay then return end
    overlay.link = nil
    if overlay.text:IsShown() then
        overlay.text:Hide()
    end
end

local function ShowLevel(button, link)
    if not enabled or type(button) ~= "table" then return end

    link = Text(link)
    local info = link and ItemInfo(link)
    if not (info and IsGear(info)) then
        HideLevel(button)
        return
    end

    local overlay = CreateOverlay(button)
    if overlay.link ~= link then
        overlay.link = link
        overlay.text:SetText(tostring(math.floor(info.level + 0.5)))
        local r, g, b = QualityColor(info.quality)
        overlay.text:SetTextColor(r, g, b)
    end
    if not overlay.text:IsShown() then
        overlay.text:Show()
    end
end

local function HideAll()
    for _, overlay in pairs(overlays) do
        overlay.link = nil
        if overlay.text then overlay.text:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- 背包与银行
-- ---------------------------------------------------------------------------
local function ContainerLink(bag, slot)
    bag, slot = Number(bag), Number(slot)
    if not (bag and slot) then return nil end
    local get = (C_Container and C_Container.GetContainerItemLink) or rawget(_G, "GetContainerItemLink")
    return Text(Call(get, bag, slot))
end

local function IsShownFrame(frame)
    if type(frame) ~= "table" then return false end
    if type(frame.IsVisible) == "function" then
        local ok, visible = pcall(frame.IsVisible, frame)
        if ok and type(visible) == "boolean" then return visible end
    end
    if type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        return ok and shown == true
    end
    return false
end

local function FrameByPath(path)
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then return nil end
        local ok, nextValue = pcall(function() return value[part] end)
        if not ok then return nil end
        value = nextValue
    end
    if type(value) == "table" then return value end
end

-- 容器窗口自己的格子列表；背包返回 (序号, 按钮)，银行返回 (按钮, true)
local function EnumerateButtons(frame)
    local out = {}
    if type(frame) ~= "table" or type(frame.EnumerateValidItems) ~= "function" then
        return out
    end

    local ok, iter, state, start = pcall(frame.EnumerateValidItems, frame)
    if not ok or type(iter) ~= "function" then return out end

    local count = 0
    local iterOk = pcall(function()
        for a, b in iter, state, start do
            if count >= 400 then break end
            local button = type(a) == "table" and a or b
            if type(button) == "table" then
                count = count + 1
                out[count] = button
            end
        end
    end)
    if not iterOk then wipe(out) end
    return out
end

local function BagOf(button)
    return Number(Call(button.GetBagID, button)) or Number(Call(button.GetBag, button))
end

local function SlotOf(button)
    return Number(Call(button.GetID, button))
end

local function BankBagOf(button)
    return Number(Call(button.GetBankTabID, button))
        or Number(Call(button.GetBagID, button))
        or Number(Call(button.GetBag, button))
end

local function BankSlotOf(button)
    return Number(Call(button.GetContainerSlotID, button)) or Number(Call(button.GetID, button))
end

local function RefreshContainer(frame, bank)
    if not IsShownFrame(frame) then return end

    local bagOf = bank and BankBagOf or BagOf
    local slotOf = bank and BankSlotOf or SlotOf

    for _, button in ipairs(EnumerateButtons(frame)) do
        local bag, slot = bagOf(button), slotOf(button)
        if bag and slot then
            ShowLevel(button, ContainerLink(bag, slot))
        else
            HideLevel(button)
        end
    end
end

local CONTAINER_NAMES = { "ContainerFrameCombinedBags" }
for index = 1, 13 do
    CONTAINER_NAMES[#CONTAINER_NAMES + 1] = "ContainerFrame" .. index
end

local BANK_PATHS = { "BankPanel", "BankFrame.BankPanel" }

local function RefreshContainers()
    for _, name in ipairs(CONTAINER_NAMES) do
        RefreshContainer(rawget(_G, name), false)
    end
    for _, path in ipairs(BANK_PATHS) do
        RefreshContainer(FrameByPath(path), true)
    end
end

-- ---------------------------------------------------------------------------
-- 角色装备栏
-- ---------------------------------------------------------------------------
local SLOT_ORDER = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
    "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
    "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

local SLOT_IDS = {
    HeadSlot = 1, NeckSlot = 2, ShoulderSlot = 3, ShirtSlot = 4, ChestSlot = 5, WaistSlot = 6,
    LegsSlot = 7, FeetSlot = 8, WristSlot = 9, HandsSlot = 10, Finger0Slot = 11, Finger1Slot = 12,
    Trinket0Slot = 13, Trinket1Slot = 14, BackSlot = 15, MainHandSlot = 16, SecondaryHandSlot = 17,
    RangedSlot = 18, TabardSlot = 19,
}

local function ResolveSlots()
    for name in pairs(SLOT_IDS) do
        local id = Number(Call(GetInventorySlotInfo, name))
        if id and id > 0 then
            SLOT_IDS[name] = id
        end
    end
end

local function RefreshEquipment()
    for _, name in ipairs(SLOT_ORDER) do
        local button = rawget(_G, "Character" .. name)
        if type(button) == "table" then
            local link = Text(Call(GetInventoryItemLink, "player", SLOT_IDS[name]))
            if link then
                ShowLevel(button, link)
            else
                HideLevel(button)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 整合背包（Bagnon / Bagnonium / BagBrother）
-- ---------------------------------------------------------------------------
local BAG_ADDON_NAMES = { "BagBrother", "Bagnon", "Bagnonium" }
local tracked = setmetatable({}, { __mode = "k" })

local function BagButtonLink(button)
    local ok, info = pcall(function() return button.info end)
    if ok and type(info) == "table" then
        local okLink, link = pcall(function() return info.hyperlink end)
        if okLink then
            link = Text(link)
            if link then return link end
        end
    end
    return ContainerLink(BagOf(button), SlotOf(button))
end

local function OnBagButtonUpdate(button)
    if type(button) ~= "table" then return end
    tracked[button] = true
    if not enabled then return end
    pcall(function()
        ShowLevel(button, BagButtonLink(button))
    end)
end

local function HookButtonClass(class)
    if type(class) ~= "table" then return end
    local method = type(class.UpdateSecondary) == "function" and "UpdateSecondary"
        or type(class.UpdatePrimary) == "function" and "UpdatePrimary"
        or type(class.Update) == "function" and "Update"
    if not method then return end

    local flag = "lpextItemLevelHooked" .. method
    if class[flag] then return end

    local ok = pcall(hooksecurefunc, class, method, OnBagButtonUpdate)
    if ok then class[flag] = true end
end

local function InstallBagAddonHooks()
    for _, name in ipairs(BAG_ADDON_NAMES) do
        local addon = _G[name]
        if type(addon) == "table" then
            HookButtonClass(addon.Item)
            if type(addon.ContainerItem) == "table" and addon.ContainerItem ~= addon.Item then
                HookButtonClass(addon.ContainerItem)
            end
        end
    end
end

local function RefreshBagAddonButtons()
    for button in pairs(tracked) do
        if IsShownFrame(button) then
            ShowLevel(button, BagButtonLink(button))
        end
    end
end

-- 开关刚打开时，整合背包窗口里的格子可能已经画好了；
-- 让整合背包自己重画一次，钩子会重新给每个格子标等级。
local function UpdateBagAddonFrame(frame)
    frame = type(frame) == "table" and frame or nil
    if not frame then return end

    local target = rawget(frame, 0)
    if type(target) ~= "table" then
        local inner = rawget(frame, "frame")
        target = type(inner) == "table" and inner or frame
    end

    if type(target.UpdateBags) == "function" then
        pcall(target.UpdateBags, target)
    elseif type(target.Update) == "function" then
        pcall(target.Update, target)
    elseif type(target.ItemGroup) == "table" and type(target.ItemGroup.Layout) == "function" then
        pcall(target.ItemGroup.Layout, target.ItemGroup)
    end
end

local function ForceBagAddonUpdate()
    for _, name in ipairs(BAG_ADDON_NAMES) do
        local addon = _G[name]
        local frames = type(addon) == "table" and rawget(addon, "Frames")
        if type(frames) == "table" then
            if type(frames.Update) == "function" then
                pcall(frames.Update, frames)
            end
            if type(frames.Get) == "function" then
                for _, id in ipairs({ "inventory", "bank", "guild" }) do
                    local ok, frame = pcall(frames.Get, frames, id)
                    if ok then
                        UpdateBagAddonFrame(frame)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 刷新
-- ---------------------------------------------------------------------------
local function RefreshAll()
    if not enabled then return end
    RefreshContainers()
    RefreshEquipment()
    RefreshBagAddonButtons()
end

local function QueueRefresh(delay)
    if queued then return end
    queued = true
    C_Timer.After(delay or 0.2, function()
        queued = false
        RefreshAll()
    end)
end

local eventFrame = CreateFrame("Frame")
for _, eventName in ipairs({
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_DELAYED",
    "PLAYERBANKSLOTS_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, eventName)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "BagBrother" or arg1 == "Bagnon" or arg1 == "Bagnonium" then
            InstallBagAddonHooks()
            QueueRefresh(0.2)
        end
        return
    end

    if not enabled then return end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        ResolveSlots()
        InstallBagAddonHooks()
        QueueRefresh(0.3)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        RefreshEquipment()
        QueueRefresh(0.5)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        QueueRefresh(0.2)
    else
        QueueRefresh(0.2)
    end
end)

local function Apply(state)
    enabled = state and true or false

    if enabled then
        ResolveSlots()
        InstallBagAddonHooks()
        ForceBagAddonUpdate()
        if not ticker then
            ticker = C_Timer.NewTicker(UPDATE_RATE, RefreshAll)
        end
        RefreshAll()
        QueueRefresh(0.5)
    else
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
        HideAll()
    end
end

InstallBagAddonHooks()

NS.RegisterModule({
    key = "showItemLevel",
    section = "拾取与物品",
    label = "显示物品等级",
    tip = "在背包、银行和角色装备栏的装备左上角显示物品等级，数字颜色与物品品质一致。\n\n灰色物品和消耗品不显示。",
    default = true,
    onToggle = function(state)
        Apply(state)
    end,
})
