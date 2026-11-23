-- LeatrixPlusExt 模块：在商人处批量购买
-- 交互和数量上限参考 BuyEmAll（BuyEmAll Classic，MIT 许可）；
-- 实际购买采用 BulkBuy 的整组循环方式，并接管游戏自己的购买确认弹窗。
local _, NS = ...

local DB = NS.DB
local Utils = NS.Utils
local MakeHeading = Utils.MakeHeading

local DEFAULT = true
local MAX_PURCHASE = 10000
local DEFAULT_BAG_SLOTS = 4
local CURRENCY_SLOTS = 3
local CONFIRM_KEY = "LEATRIXPLUSEXT_BULK_BUY_CONFIRM"

local PANEL_WIDTH, PANEL_HEIGHT = 230, 134

-- ---------------------------------------------------------------------------
-- 子设置
-- ---------------------------------------------------------------------------
local OPTION_KEY = "bulkBuyOptions"
local OPTION_DEFAULTS = {
    confirmLarge = true,
}

local function GetOptions()
    local options = DB[OPTION_KEY]
    if type(options) ~= "table" then
        options = {}
        DB[OPTION_KEY] = options
    end
    return options
end

local function GetOption(key)
    local value = GetOptions()[key]
    if value == nil then return OPTION_DEFAULTS[key] end
    return value
end

local function SetOption(key, value)
    GetOptions()[key] = value
end

local function IsEnabled()
    return DB.bulkBuy ~= false
end

-- ---------------------------------------------------------------------------
-- 客户端兼容层
-- 这个客户端把 GetMerchantItemInfo 移进了 C_MerchantFrame；
-- 老接口还在时仍然优先用老接口，行为不变。
-- ---------------------------------------------------------------------------
local MerchantItemInfo
if type(_G.GetMerchantItemInfo) == "function" then
    MerchantItemInfo = function(index)
        local ok, name, texture, price, stackCount, numAvailable,
            isPurchasable, isUsable, extendedCost, currencyID, spellID =
            pcall(_G.GetMerchantItemInfo, index)
        if not ok then return nil end
        return name, texture, price, stackCount, numAvailable,
            isPurchasable, isUsable, extendedCost, currencyID, spellID
    end
elseif _G.C_MerchantFrame and type(_G.C_MerchantFrame.GetItemInfo) == "function" then
    MerchantItemInfo = function(index)
        local ok, info = pcall(_G.C_MerchantFrame.GetItemInfo, index)
        if not ok or type(info) ~= "table" then return nil end
        return info.name, info.texture, info.price, info.stackCount, info.numAvailable,
            info.isPurchasable, info.isUsable, info.hasExtendedCost,
            info.currencyID, info.spellID
    end
else
    MerchantItemInfo = function() return nil end
end

local function MerchantItemLink(index)
    local getter = _G.GetMerchantItemLink
    if type(getter) ~= "function" then return nil end
    local ok, link = pcall(getter, index)
    if ok and type(link) == "string" then return link end
    return nil
end

local function ItemStackSize(itemID)
    if not itemID then return nil end
    local getter = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    if type(getter) ~= "function" then return nil end
    local ok, _, _, _, _, _, _, _, stackCount = pcall(getter, itemID)
    if ok and type(stackCount) == "number" and stackCount > 0 then
        return stackCount
    end
    return nil
end

local function MerchantMaxStack(index)
    local getter = _G.GetMerchantItemMaxStack
    if type(getter) == "function" then
        local ok, value = pcall(getter, index)
        if ok and type(value) == "number" and value > 0 then
            return math.floor(value)
        end
    end

    -- 接口被客户端移除时，退回按物品自身的堆叠上限估算
    local link = MerchantItemLink(index)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    local stackCount = ItemStackSize(itemID)
    if stackCount then return stackCount end

    local _, _, _, quantity = MerchantItemInfo(index)
    if type(quantity) == "number" and quantity > 0 then
        return math.floor(quantity)
    end
    return 1
end

local function OwnedItemCount(itemID)
    if not itemID then return 0 end
    local getter = (_G.C_Item and _G.C_Item.GetItemCount) or _G.GetItemCount
    if type(getter) ~= "function" then return 0 end
    local ok, count = pcall(getter, itemID, true)
    if ok and type(count) == "number" then return count end
    return 0
end

-- 货币数量：优先用 12.x 的结构体接口，老客户端退回多返回值接口
local function CurrencyQuantity(currencyID)
    if not currencyID then return 0, 0 end

    local api = _G.C_CurrencyInfo
    if type(api) == "table" and type(api.GetCurrencyInfo) == "function" then
        local ok, info = pcall(api.GetCurrencyInfo, currencyID)
        if ok and type(info) == "table" then
            return tonumber(info.quantity) or 0, tonumber(info.maxQuantity) or 0
        end
    end

    if type(_G.GetCurrencyInfo) == "function" then
        local ok, first, second, _, fourth = pcall(_G.GetCurrencyInfo, currencyID)
        if ok then
            -- 有的客户端返回结构体，有的客户端返回 name, quantity, icon, maxQuantity
            if type(first) == "table" then
                return tonumber(first.quantity) or 0, tonumber(first.maxQuantity) or 0
            end
            return tonumber(second) or 0, tonumber(fourth) or 0
        end
    end
    return 0, 0
end

-- 背包格位：0 是背包，1~NUM_BAG_SLOTS 是装备的背包；
-- NUM_BAG_SLOTS 之后、NUM_TOTAL_EQUIPPED_BAG_SLOTS 之内的格位是材料包。
-- 这个客户端把材料包的类型报告为 0，所以不能按背包类型判断它收不收得下物品。
local function BagRange()
    local normal = tonumber(_G.NUM_BAG_SLOTS) or DEFAULT_BAG_SLOTS
    local last = tonumber(_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS) or normal

    local reagent = tonumber(_G.REAGENTBAG_CONTAINER)
    local enum = _G.Enum
    if not reagent and type(enum) == "table" and type(enum.BagIndex) == "table" then
        reagent = tonumber(enum.BagIndex.ReagentBag)
    end
    if not reagent and last > normal then
        reagent = normal + 1
    end
    if not reagent then
        -- 客户端新增材料包但没有公开格位时，按正式服的位置补上第 5 格
        reagent = DEFAULT_BAG_SLOTS + 1
        if reagent > last then last = reagent end
    end

    return math.floor(last), math.floor(reagent)
end

-- 材料包只收材料。和 BagBrother 一样，用 GetItemInfo 的第 17 个返回值
-- isCraftingReagent 判断，而不是背包类型（客户端把材料包类型报告为 0）。
local function BagAcceptsItem(itemID)
    local getter = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    if type(getter) ~= "function" then return true end

    local info = { pcall(getter, itemID) }
    if not info[1] or info[2] == nil then
        -- 物品信息还没缓存，无法判断时按可存放处理
        return true
    end
    return info[18] and true or false
end

-- 背包和材料包里还能放下多少个这种物品：空格按整组算，已有堆叠只补差额。
-- 同时返回已经有多少个，供“一组”按钮先补满已有堆叠。
local function BagCapacity(itemID, maxStack)
    maxStack = math.max(1, tonumber(maxStack) or 1)
    local fit = 0
    local owned = 0
    local lastBag, reagentBag = BagRange()

    local modernEnabled = false
    pcall(function()
        local container = _G.C_Container
        local item = _G.C_Item
        local location = _G.ItemLocation
        if not (container and item and location and location.CreateFromBagAndSlot) then
            return
        end
        modernEnabled = true

        for bag = 0, lastBag do
            local canStore = true
            if bag == reagentBag then
                canStore = BagAcceptsItem(itemID)
            end
            local slots = container.GetContainerNumSlots and container.GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local locationObject = location:CreateFromBagAndSlot(bag, slot)
                if locationObject and item.DoesItemExist(locationObject) then
                    if item.GetItemID(locationObject) == itemID then
                        local info = container.GetContainerItemInfo(bag, slot)
                        local count = info and tonumber(info.stackCount) or 0
                        owned = owned + count
                        if maxStack > count then
                            fit = fit + (maxStack - count)
                        end
                    end
                elseif canStore then
                    fit = fit + maxStack
                end
            end
        end
        return true
    end)

    -- 现代接口可用时以扫描结果为准；中途出错也保留已经数到的空位
    if modernEnabled then return fit, owned end

    -- 旧接口
    fit = 0
    owned = 0
    if type(_G.GetContainerItemInfo) ~= "function" then return 0, 0 end
    for bag = 0, lastBag do
        local canStore = true
        if bag == reagentBag then
            canStore = BagAcceptsItem(itemID)
        end
        local getSlots = _G.GetContainerNumSlots
        local slots = type(getSlots) == "function" and getSlots(bag) or 0
        for slot = 1, slots do
            local link = type(_G.GetContainerItemLink) == "function"
                and _G.GetContainerItemLink(bag, slot) or nil
            if link then
                if tonumber(tostring(link):match("item:(%d+)")) == itemID then
                    local _, count = _G.GetContainerItemInfo(bag, slot)
                    count = tonumber(count) or 0
                    owned = owned + count
                    if maxStack > count then
                        fit = fit + (maxStack - count)
                    end
                end
            elseif canStore then
                fit = fit + maxStack
            end
        end
    end
    return fit, owned
end

-- “一组”的第一次点击数量：先补满背包里已有的零散堆叠。
-- 已有数量是多组时按整组取余，例如每组 20、已有 27 个，就补 13 个。
local function FillFromOwned(owned, stack)
    stack = math.max(1, tonumber(stack) or 1)
    local remainder = (tonumber(owned) or 0) % stack
    if remainder == 0 then return stack end
    return stack - remainder
end

-- ---------------------------------------------------------------------------
-- 当前购买状态
-- ---------------------------------------------------------------------------
local S = {}

-- ---------------------------------------------------------------------------
-- 购买执行
-- ---------------------------------------------------------------------------
-- 整组循环：先按商人允许的单次数量买满整组，最后补上余数。
-- 参考 BulkBuy：替代货币只能整组兑换，先向下取整到商人每组数量。
local function BulkBuyMerchantItem(index, quantity)
    quantity = tonumber(quantity)
    if not quantity or quantity <= 0 then return end
    if quantity > MAX_PURCHASE then quantity = MAX_PURCHASE end

    local buy = _G.BuyMerchantItem
    if type(buy) ~= "function" then return end

    local _, _, price, stackCount = MerchantItemInfo(index)
    if type(price) == "number" and price <= 0 then
        local merchantStack = tonumber(stackCount) or 1
        if merchantStack > 0 then
            quantity = math.floor(quantity / merchantStack) * merchantStack
        end
    end
    if quantity <= 0 then return end

    local stackSize = math.max(1, MerchantMaxStack(index))
    while quantity > stackSize do
        if not pcall(buy, index, stackSize) then return end
        quantity = quantity - stackSize
    end
    if quantity > 0 then pcall(buy, index, quantity) end
end

local function AltCurrencyRounding(amount)
    amount = math.floor(tonumber(amount) or 0)
    local preset = math.max(1, tonumber(S.preset) or 1)

    local singleCost = false
    for i = 1, (S.numAltCurrency or 0) do
        if S.altPrice and S.altPrice[i] == 1 then
            singleCost = true
            break
        end
    end
    if not singleCost then return amount end

    local remainder = amount % preset
    if remainder < preset / 2 then
        return amount - remainder
    end
    return amount + (preset - remainder)
end

-- ---------------------------------------------------------------------------
-- 界面
-- ---------------------------------------------------------------------------
local ui
local UpdateDisplay

local function HidePanel()
    if ui and ui.frame then ui.frame:Hide() end
    if type(_G.StaticPopup_Hide) == "function" then
        pcall(_G.StaticPopup_Hide, CONFIRM_KEY)
    end
end

local function ComputeStackClick()
    local unit = math.max(1, tonumber(S.stack) or 1)
    local split = math.max(1, tonumber(S.split) or 1)
    local fill = math.max(0, tonumber(S.fill) or 0)

    -- 还没补满已有堆叠时，先补到整组；之后每次再加一整组
    if split < fill then return fill end
    local offset = (split - fill) % unit
    if offset == 0 then return split + unit end
    return split + (unit - offset)
end

UpdateDisplay = function()
    if not (ui and ui.frame) then return end

    local maxValue = math.max(0, tonumber(S.max) or 0)
    local preset = math.max(1, tonumber(S.preset) or 1)
    local minValue = S.altCurrencyMode and preset or 1
    local split = math.floor(tonumber(S.split) or minValue)

    if split < 0 then split = 0 end
    if split > maxValue then split = maxValue end
    S.split = split

    ui.qty:SetText(tostring(split))

    S.stackClick = ComputeStackClick()

    if ui.left then ui.left:SetEnabled(split > minValue) end
    if ui.right then ui.right:SetEnabled(split < maxValue) end
    if ui.maxButton then ui.maxButton:SetEnabled(split < maxValue) end
    if ui.stackButton then ui.stackButton:SetEnabled(S.stackClick <= maxValue) end

    if S.altCurrencyMode then
        local amount = AltCurrencyRounding(split)
        local purchases = math.floor(amount / preset)
        for i = 1, CURRENCY_SLOTS do
            local icon, text = ui.icons[i], ui.amounts[i]
            if icon and text then
                local price = S.altPrice and S.altPrice[i]
                if price then
                    icon:SetTexture(S.altTexture and S.altTexture[i] or nil)
                    text:SetText(tostring(math.floor(purchases * price)))
                    icon:Show()
                    text:Show()
                else
                    icon:Hide()
                    text:SetText("")
                end
            end
        end
    else
        local cost
        if preset > 1 then
            cost = math.ceil(split * (tonumber(S.price) or 0) / preset)
        else
            cost = math.ceil(split * (tonumber(S.price) or 0))
        end
        cost = math.max(0, math.floor(cost))

        local gold = math.floor(cost / 10000)
        local silver = math.floor((cost % 10000) / 100)
        local copper = cost % 100

        local icons = { "Interface\\MONEYFRAME\\UI-GoldIcon",
            "Interface\\MONEYFRAME\\UI-SilverIcon",
            "Interface\\MONEYFRAME\\UI-CopperIcon" }
        local values = { gold, silver, copper }
        for i = 1, CURRENCY_SLOTS do
            local icon, text = ui.icons[i], ui.amounts[i]
            if icon then
                icon:SetTexture(icons[i])
                icon:Show()
            end
            if text then
                text:SetText(tostring(values[i] or 0))
                text:Show()
            end
        end
    end
end

local function SetSplit(value)
    value = math.floor(tonumber(value) or 0)
    local preset = math.max(1, tonumber(S.preset) or 1)
    local minValue = S.altCurrencyMode and preset or 1
    local maxValue = math.max(minValue, tonumber(S.max) or minValue)

    if value < minValue then value = minValue end
    if value > maxValue then value = maxValue end
    S.split = value
    UpdateDisplay()
end

local function StepAmount(direction)
    local preset = math.max(1, tonumber(S.preset) or 1)
    local step = S.altCurrencyMode and preset or 1
    SetSplit((tonumber(S.split) or 1) + direction * step)
end

local function InputDigit(digit)
    if not S.typing then
        S.typing = true
        S.split = 0
    end

    local input = (tonumber(S.split) or 0) * 10 + digit
    if input <= 0 then input = 1 end
    local maxValue = math.max(1, tonumber(S.max) or 1)
    if input > maxValue then input = maxValue end
    S.split = input
    UpdateDisplay()
end

local DoPurchase
local VerifyPurchase
local BuyOne

DoPurchase = function(amount)
    HidePanel()
    if not IsEnabled() then return end

    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    if S.altCurrencyMode then amount = AltCurrencyRounding(amount) end
    if amount <= 0 then return end

    -- 用货币购买货币：交给游戏按数量处理，不再拆成多组
    if S.itemLink and tostring(S.itemLink):find("currency", 1, true) then
        local buy = _G.BuyMerchantItem
        if type(buy) == "function" then pcall(buy, S.itemIndex, amount) end
        return
    end

    BulkBuyMerchantItem(S.itemIndex, amount)
end

local function EnsureConfirmDialog()
    if type(_G.StaticPopupDialogs) ~= "table" then return false end
    if type(_G.StaticPopup_Show) ~= "function" then return false end

    _G.StaticPopupDialogs[CONFIRM_KEY] = {
        text = "是否要购买\n%2$s × %1$d 个？",
        button1 = _G.YES or "确定",
        button2 = _G.NO or "取消",
        OnAccept = function(dialog)
            DoPurchase(dialog.data)
        end,
        timeout = 0,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    return true
end

VerifyPurchase = function(amount)
    amount = math.floor(tonumber(amount) or tonumber(S.split) or 0)
    if S.altCurrencyMode then amount = AltCurrencyRounding(amount) end
    if amount <= 0 then return end

    local unit = math.max(1, tonumber(S.stack) or 1)
    local preset = math.max(1, tonumber(S.preset) or 1)
    if amount > unit and amount > preset and GetOption("confirmLarge") then
        if EnsureConfirmDialog() then
            local dialog = _G.StaticPopup_Show(CONFIRM_KEY, amount, S.itemName or "")
            if dialog then
                dialog.data = amount
                return
            end
        end
    end
    DoPurchase(amount)
end

BuyOne = function(itemButton, index)
    local click = _G.MerchantItemButton_OnClick
    if type(click) == "function" then
        local ok = pcall(click, itemButton, "LeftButton")
        if ok then return end
    end
    local buy = _G.BuyMerchantItem
    if type(buy) == "function" then pcall(buy, index, 1) end
end

local function CreateArrow(parent, direction)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)
    button:SetNormalTexture("Interface\\MoneyFrame\\Arrow-" .. direction .. "-Up")
    button:SetPushedTexture("Interface\\MoneyFrame\\Arrow-" .. direction .. "-Down")
    button:SetDisabledTexture("Interface\\MoneyFrame\\Arrow-" .. direction .. "-Disabled")
    return button
end

local function AddTooltipLine(...)
    if _G.GameTooltip then _G.GameTooltip:AddDoubleLine(...) end
end

local function EnsureUI()
    if ui then return ui end
    ui = { icons = {}, amounts = {} }

    local frame = CreateFrame("Frame", "LeatrixPlusExtBulkBuyFrame", UIParent)
    frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:EnableKeyboard(true)
    frame:Hide()
    ui.frame = frame

    -- 面板外观沿用 BuyEmAll：用金钱框贴图拼出上下边框和中间的底色
    local moneyFrame = "Interface\\MoneyFrame\\UI-MoneyFrame2"
    local top = frame:CreateTexture(nil, "BACKGROUND")
    top:SetTexture(moneyFrame)
    top:SetSize(PANEL_WIDTH, 14)
    top:SetPoint("TOP")
    top:SetTexCoord(0, 0.671875, 0, 0.109375)

    local bottom = frame:CreateTexture(nil, "BACKGROUND")
    bottom:SetTexture(moneyFrame)
    bottom:SetSize(PANEL_WIDTH, 20)
    bottom:SetPoint("BOTTOM")
    bottom:SetTexCoord(0, 0.671875, 0.59375, 0.75)

    local back = frame:CreateTexture(nil, "BACKGROUND")
    back:SetTexture(moneyFrame)
    back:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, 0)
    back:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, 0)
    back:SetTexCoord(0, 0.671875, 0.109375, 0.59375)

    -- 数量压在金钱框贴图上，左右各一个箭头
    local moneyTex = frame:CreateTexture(nil, "BORDER")
    moneyTex:SetTexture("Interface\\MoneyFrame\\UI-MoneyFrame")
    moneyTex:SetSize(121, 33)
    moneyTex:SetPoint("TOP", 1, -14)
    moneyTex:SetTexCoord(0.10546875, 0.578125, 0.109375, 0.3671875)

    local qty = frame:CreateFontString(nil, "BORDER", "GameFontHighlight")
    qty:SetPoint("RIGHT", moneyTex, "RIGHT", -12, 2)
    qty:SetJustifyH("RIGHT")
    ui.qty = qty

    local left = CreateArrow(frame, "Left")
    left:SetPoint("TOPRIGHT", moneyTex, "TOP", -60, -8)
    left:SetScript("OnClick", function() StepAmount(-1) end)
    ui.left = left

    local right = CreateArrow(frame, "Right")
    right:SetPoint("TOPLEFT", moneyTex, "TOP", 63, -8)
    right:SetScript("OnClick", function() StepAmount(1) end)
    ui.right = right

    -- 金币或替代货币：三个图标加数量，位置与 BuyEmAll 一致
    local currencyFrame = CreateFrame("Frame", nil, frame)
    currencyFrame:SetSize(204, 24)
    currencyFrame:SetPoint("TOP", 2, -45)

    local iconX = { 48, 116, 184 }
    local amountX = { -2, 66, 134 }
    for i = 1, CURRENCY_SLOTS do
        local icon = currencyFrame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", iconX[i], 0)
        icon:Hide()
        ui.icons[i] = icon

        local text = currencyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetSize(52, 20)
        text:SetPoint("LEFT", amountX[i], 0)
        text:SetText("")
        ui.amounts[i] = text
    end

    local function MakeButton(text, handler)
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(78, 24)
        button:SetText(text)
        button:SetScript("OnClick", handler)
        return button
    end

    local okay = MakeButton("确定", function()
        VerifyPurchase(S.split)
    end)
    okay:SetPoint("RIGHT", frame, "BOTTOM", -3, 30)
    ui.okay = okay

    local cancel = MakeButton("取消", function()
        HidePanel()
    end)
    cancel:SetPoint("LEFT", frame, "BOTTOM", 5, 30)
    ui.cancel = cancel

    local stackButton = MakeButton("一组", function()
        SetSplit(S.stackClick or S.split)
    end)
    stackButton:SetPoint("BOTTOM", okay, "TOP", 0, 2)
    stackButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("按组购买 - " .. tostring(math.floor(tonumber(S.stackClick) or 0)), 1, 1, 1)
        AddTooltipLine("每组数量", tostring(math.floor(tonumber(S.stack) or 1)))
        AddTooltipLine("整组差值", tostring(math.floor(tonumber(S.fill) or 0)))
        GameTooltip:Show()
    end)
    stackButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.stackButton = stackButton

    local maxButton = MakeButton("最多", function()
        SetSplit(S.max)
    end)
    maxButton:SetPoint("BOTTOM", cancel, "TOP", 0, 2)
    maxButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("最多购买 - " .. tostring(math.floor(tonumber(S.max) or 0)), 1, 1, 1)
        AddTooltipLine("现金最多购买", tostring(math.floor(tonumber(S.afford) or 0)))
        AddTooltipLine("背包最多存放", tostring(math.floor(tonumber(S.fit) or 0)))
        if (tonumber(S.available) or -1) > 1 then
            AddTooltipLine("商人存货数量", tostring(math.floor(S.available)))
        end
        GameTooltip:Show()
    end)
    maxButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.maxButton = maxButton

    frame:SetScript("OnKeyDown", function(_, key)
        if not frame:IsShown() then return end

        if key == "BACKSPACE" or key == "DELETE" then
            if not S.typing then return end
            if (tonumber(S.split) or 0) <= 1 then
                S.typing = false
                return
            end
            S.split = math.floor((tonumber(S.split) or 1) / 10)
            if S.split < 1 then S.split = 1 end
            if S.split == 1 then S.typing = false end
            UpdateDisplay()
        elseif key == "ENTER" then
            VerifyPurchase(S.split)
        elseif key == "ESCAPE" then
            HidePanel()
        elseif key == "LEFT" or key == "DOWN" then
            StepAmount(-1)
        elseif key == "RIGHT" or key == "UP" then
            StepAmount(1)
        end
    end)

    -- 数字用 OnChar 读取，避免和 OnKeyDown 重复处理同一次按键
    frame:SetScript("OnChar", function(_, text)
        if not frame:IsShown() then return end
        if type(text) == "string" and text:match("^%d$") then
            InputDigit(tonumber(text))
        end
    end)

    return ui
end

local function ShowPanel(itemButton)
    EnsureUI()
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("BOTTOMLEFT", itemButton, "TOPLEFT", 0, 0)
    ui.frame:Raise()
    ui.frame:Show()

    S.typing = false
    if S.altCurrencyMode then
        S.split = math.max(1, tonumber(S.preset) or 1)
    else
        S.split = 1
    end
    S.stackClick = ComputeStackClick()
    UpdateDisplay()
end

-- ---------------------------------------------------------------------------
-- 打开购买面板
-- ---------------------------------------------------------------------------
local function StartAltCurrency(index)
    S.altCurrencyMode = true
    S.altTexture = {}
    S.altPrice = {}
    S.altAfford = {}
    S.numAltCurrency = 0

    local getCount = _G.GetMerchantItemCostInfo
    local getItem = _G.GetMerchantItemCostItem
    if type(getCount) ~= "function" or type(getItem) ~= "function" then
        return false
    end

    local ok, count = pcall(getCount, index)
    if not ok then return false end
    count = tonumber(count) or 0
    if count <= 0 then return false end

    local minAfford
    for i = 1, math.min(count, CURRENCY_SLOTS) do
        local itemOk, texture, amount, link = pcall(getItem, index, i)
        if not itemOk or type(amount) ~= "number" or amount <= 0 then
            return false
        end

        local affordable = 0
        local currencyID = tostring(link or ""):match("currency:(%d+)")
        if currencyID then
            local quantity = CurrencyQuantity(tonumber(currencyID))
            affordable = math.floor(quantity / amount) * S.preset
        else
            local itemID = tonumber(tostring(link or ""):match("item:(%d+)"))
            affordable = math.floor(OwnedItemCount(itemID) / amount) * S.preset
        end

        S.altTexture[i] = texture
        S.altPrice[i] = amount
        S.altAfford[i] = affordable
        if not minAfford or affordable < minAfford then minAfford = affordable end
    end

    S.numAltCurrency = math.min(count, CURRENCY_SLOTS)
    S.afford = minAfford or 0
    S.max = math.min(tonumber(S.fit) or 0, S.afford)
    if (tonumber(S.available) or -1) > -1 then
        S.max = math.min(S.max, S.available * S.preset)
    end
    S.max = math.min(S.max, MAX_PURCHASE)
    S.max = math.floor(S.max / S.preset) * S.preset
    S.fill = (tonumber(S.fit) or 0) % math.max(1, tonumber(S.stack) or 1)
    S.defaultStack = S.preset
    S.split = S.preset
    return S.max > 0
end

local function BeginPurchase(itemButton)
    if not itemButton or type(itemButton.GetID) ~= "function" then return false end
    local index = itemButton:GetID()
    if type(index) ~= "number" or index <= 0 then return false end

    local name, _, price, quantity, available, _, _, hasExtendedCost = MerchantItemInfo(index)
    if name == nil then return false end

    local link = MerchantItemLink(index)
    if not link then return false end

    S.itemIndex = index
    S.itemName = name
    S.itemLink = link
    S.price = tonumber(price) or 0
    S.preset = math.max(1, tonumber(quantity) or 1)
    S.available = tonumber(available) or -1
    S.hasExtendedCost = hasExtendedCost and true or false
    S.altCurrencyMode = false
    S.altTexture = nil
    S.altPrice = nil
    S.altAfford = nil
    S.numAltCurrency = 0
    S.fit = 0
    S.afford = 0
    S.owned = 0
    S.fill = 0
    S.stack = math.max(1, MerchantMaxStack(index))

    local isCurrencyLink = link:find("currency", 1, true) and true or false

    if isCurrencyLink and S.price == 0 then
        -- 用货币购买货币
        local currencyID = tonumber(link:match("currency:(%d+)"))
        if not currencyID then return false end
        local _, maxQuantity = CurrencyQuantity(currencyID)
        S.fit = (maxQuantity and maxQuantity > 0) and maxQuantity or MAX_PURCHASE
        S.stack = S.preset
    elseif link:find("item", 1, true) then
        local itemID = tonumber(link:match("item:(%d+)"))
        if not itemID then return false end
        S.stack = math.max(1, MerchantMaxStack(index))
        S.fit, S.owned = BagCapacity(itemID, S.stack)
        S.fill = FillFromOwned(S.owned, S.stack)
    elseif isCurrencyLink then
        local currencyID = tonumber(link:match("currency:(%d+)"))
        if not currencyID then return false end
        S.stack = S.preset
        local quantityOwned, maxQuantity = CurrencyQuantity(currencyID)
        S.fit = (maxQuantity and maxQuantity > 0) and maxQuantity or MAX_PURCHASE
        S.fill = math.max(0, (maxQuantity or 0) - (quantityOwned or 0))
    else
        return false
    end

    if S.hasExtendedCost and S.price == 0 then
        if not StartAltCurrency(index) then return false end
    else
        if S.price == 0 then
            S.afford = S.fit
        else
            local perItem = math.ceil(S.price / S.preset)
            if perItem < 1 then perItem = 1 end
            S.afford = math.floor((tonumber(_G.GetMoney()) or 0) / perItem)
        end

        S.max = math.min(S.fit, S.afford)
        if S.available > -1 then
            S.max = math.min(S.max, S.available)
        end
        S.max = math.min(S.max, MAX_PURCHASE)
        S.defaultStack = S.preset
        S.split = 1
    end

    if not S.max or S.max <= 0 then
        -- 已经接住这次点击，但确实买不了：不再打开游戏的拆分窗口
        return true
    end
    if S.max == 1 then
        BuyOne(itemButton, index)
        return true
    end

    ShowPanel(itemButton)
    return true
end

local function HandleShiftClick(itemButton)
    if not IsEnabled() then return false end

    local merchant = _G.MerchantFrame
    if not merchant or merchant.selectedTab ~= 1 then return false end

    local isShiftDown = _G.IsShiftKeyDown
    if type(isShiftDown) ~= "function" or not isShiftDown() then return false end

    local isControlDown = _G.IsControlKeyDown
    if type(isControlDown) == "function" and isControlDown() then return false end

    local editBox = _G.ChatFrame1EditBox
    if editBox and editBox:HasFocus() then return false end

    return BeginPurchase(itemButton)
end

-- ---------------------------------------------------------------------------
-- 接管商人的 Shift 点击与游戏的购买确认
-- 模块关闭时全部转交原函数，不改变游戏原本的行为。
-- ---------------------------------------------------------------------------
local clickInstalled = false
local popupInstalled = false
local merchantInstalled = false
local installFrame = CreateFrame("Frame")

local function InstallClickHook()
    if clickInstalled then return end
    local original = _G.MerchantItemButton_OnModifiedClick
    if type(original) ~= "function" then return end

    _G.MerchantItemButton_OnModifiedClick = function(itemButton, mouseButton, ...)
        if IsEnabled() then
            local ok, handled = pcall(HandleShiftClick, itemButton)
            if ok and handled then return end
        end
        return original(itemButton, mouseButton, ...)
    end
    clickInstalled = true
end

local function InstallPopupHooks()
    if popupInstalled then return end
    if type(_G.StaticPopupDialogs) ~= "table" then return end

    local any = false
    local keys = { "CONFIRM_PURCHASE_TOKEN_ITEM", "CONFIRM_PURCHASE_NONREFUNDABLE_ITEM" }
    for _, key in ipairs(keys) do
        local dialog = _G.StaticPopupDialogs[key]
        if type(dialog) == "table" then
            any = true
            local original = dialog.OnAccept
            dialog.OnAccept = function(dialogFrame, ...)
                local merchant = _G.MerchantFrame
                if IsEnabled() and merchant and merchant.itemIndex then
                    local count = tonumber(merchant.count) or 1
                    BulkBuyMerchantItem(merchant.itemIndex, count)
                    return
                end
                if type(original) == "function" then
                    return original(dialogFrame, ...)
                end
            end
        end
    end
    popupInstalled = any
end

local function InstallMerchantHook()
    if merchantInstalled then return end
    local merchant = _G.MerchantFrame
    if type(merchant) ~= "table" or type(merchant.HookScript) ~= "function" then return end

    merchant:HookScript("OnHide", function()
        HidePanel()
    end)
    merchantInstalled = true
end

local function TryInstall()
    InstallClickHook()
    InstallPopupHooks()
    InstallMerchantHook()
    EnsureConfirmDialog()

    if clickInstalled and popupInstalled and merchantInstalled then
        installFrame:UnregisterAllEvents()
    end
end

installFrame:RegisterEvent("ADDON_LOADED")
installFrame:RegisterEvent("PLAYER_LOGIN")
-- 商人界面按需加载时，等它显示后再补一次安装
installFrame:RegisterEvent("MERCHANT_SHOW")
installFrame:SetScript("OnEvent", TryInstall)
TryInstall()

-- ---------------------------------------------------------------------------
-- 设置页
-- ---------------------------------------------------------------------------
local UpdatePanel

local function BuildPanel(parent)
    MakeHeading(parent, "购买确认", 0, 0)

    local confirm = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
    confirm:SetPoint("TOPLEFT", 0, -28)

    local label = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", 20, 0)
    label:SetJustifyH("LEFT")
    label:SetText("一次购买超过一组时先确认")
    confirm:SetHitRectInsets(0, -label:GetStringWidth() + 4, 0, 0)

    Utils.AssignTooltip(confirm,
        "一次购买的数量超过一组时，先弹出确认窗口。"
        .. "关闭后，按确定会直接开始购买。", parent)

    confirm:SetScript("OnClick", function(self)
        SetOption("confirmLarge", self:GetChecked() and true or false)
        if UpdatePanel then UpdatePanel() end
    end)

    UpdatePanel = function()
        confirm:SetChecked(GetOption("confirmLarge") and true or false)
    end
    UpdatePanel()

    local hint = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 0, -60)
    hint:SetWidth(520)
    hint:SetJustifyH("LEFT")
    hint:SetText("在商人购买页按住 Shift 左键点击物品，可以直接输入数量，"
        .. "也可以选择“一组”或“最多”。\n"
        .. "“一组”按商人每组数量对齐，“最多”按金钱、背包空位和商人存货计算。")
end

local MODULE_TIP = "在商人购买页按住 Shift 左键点击物品，可以一次购买超过一组。"
    .. "面板支持直接输入数量、“一组”按整组对齐，"
    .. "“最多”会按金钱、背包空位和商人存货算出上限。"
    .. "用替代货币出售的物品按整组购买。"
    .. "\n\n一次购买超过一组时会先弹出确认，可在右侧齿轮里关闭。"
    .. "操作时按回车购买，按 Esc 关闭；方向键或左右按钮调整数量。"

local PANEL_DESC = "在商人购买页按住 Shift 左键点击物品，可以一次购买超过一组。"

NS.RegisterModule({
    key = "bulkBuy",
    section = "拾取与物品",
    label = "批量购买",
    tip = MODULE_TIP,
    default = DEFAULT,
    panelTitle = "批量购买",
    panelDesc = PANEL_DESC,
    buildPanel = BuildPanel,
    reset = function()
        SetOption("confirmLarge", true)
        if UpdatePanel then UpdatePanel() end
    end,
    onToggle = function(enabled)
        if not enabled then
            HidePanel()
        end
    end,
})
