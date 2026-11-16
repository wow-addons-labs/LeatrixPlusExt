-- LeatrixPlusExt 模块：增强自动拾取
-- 逻辑移植自 SpeedyAutoLoot 插件（作者 Yuyuli），按 LeatrixPlusExt 的模块体系做了精简：
-- 保留分格节流、拾取品质门槛、背包空间检查、失败回退与钓鱼收线音效；
-- 未移植 LootDisplay 战利品滚动列表、ElvUI 拾取框接管和自动确认绑定。
local addonName, NS = ...

local DB = NS.DB

local DEFAULT = false
local LOOT_TICK = 0.033            -- 每 33ms 拾取一格（约 30 格/秒）
local DEFAULT_LOOT_THRESHOLD = 10  -- 非需求/贪婪分配时，品质 >= 10 的装备不自动拾取

local IsGameStandard = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

local EnumLootSlotType = Enum and Enum.LootSlotType
local SLOT_TYPE_ITEM = EnumLootSlotType and EnumLootSlotType.Item
local SLOT_TYPE_NONE = EnumLootSlotType and EnumLootSlotType.None
local LootMethodEnum = Enum and Enum.LootMethod
local KeyringBag = Enum and Enum.BagIndex and Enum.BagIndex.Keyring
local ReagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag

local GetNumFreeSlots = (C_Container and C_Container.GetContainerNumFreeSlots)
    or GetContainerNumFreeSlots
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemFamily = C_Item and C_Item.GetItemFamily
local band = bit and bit.band

-- 与原插件 SetGameInfo 一致：WoD 及之后的任务物品会进入任务背包
local hasQuestBag = LE_EXPANSION_LEVEL_CURRENT and LE_EXPANSION_WARLORDS_OF_DRAENOR
    and LE_EXPANSION_LEVEL_CURRENT >= LE_EXPANSION_WARLORDS_OF_DRAENOR

local internal = {
    frame = CreateFrame("frame", nil, UIParent),
    lootThreshold = DEFAULT_LOOT_THRESHOLD,
    isLooting = false,
    lastNumLoot = nil,
    lootFailure = false,
    isHidden = true,
    initialAutoLootState = false,
    lootTicker = nil,
    hasEditModeWithLootWindow = LootFrame ~= nil
        and type(LootFrame.UpdateShownState) == "function",
}
internal.frame:SetToplevel(true)
internal.frame:Hide()

local function IsEnabled()
    local value = DB.speedyAutoLoot
    if value == nil then return DEFAULT end
    return value and true or false
end

-- ---------------------------------------------------------------------------
-- 与 Leatrix Plus 的「加速自动拾取」二选一
-- ---------------------------------------------------------------------------
-- Leatrix Plus 在自己的 ADDON_LOADED 里把 LeaPlusDB["FasterLooting"] 读进文件内的
-- 局部变量，再在 PLAYER_LOGIN 时决定是否安装 LOOT_READY 加速逻辑。那份运行状态
-- 外部访问不到，所以本插件不去改它，而是以它的保存值为准：
--   * 登录/重载时它是 On —— 本模块保持关闭，避免两套逻辑同时调用 LootSlot；
--   * 它是 Off —— 本模块按自己的开关运行。
-- 这样两个插件的加载顺序不再重要，TOC 只声明 OptionalDeps（见 LeatrixPlusExt.toc）。
local function LeatrixFasterLootOn()
    local leaDB = _G.LeaPlusDB
    return type(leaDB) == "table" and leaDB["FasterLooting"] == "On"
end

-- 文件加载时先按保存值让位一次，确保模块在 PLAYER_LOGIN 之前就不会接管拾取
local yieldedToLeatrixAtLoad = false
if IsEnabled() and LeatrixFasterLootOn() then
    DB.speedyAutoLoot = false
    yieldedToLeatrixAtLoad = true
end

local function HasKeyring()
    if IsKeyRingEnabled then return IsKeyRingEnabled() end
    if C_ActionBar and C_ActionBar.ShouldShowKeyring then
        return C_ActionBar.ShouldShowKeyring()
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 背包空间检查（与原插件 ProcessLootItem 一致）
-- ---------------------------------------------------------------------------
local function ProcessLootItem(itemLink, itemQuantity)
    if not itemLink then return true end

    local itemStackCount, _, _, _, _, _, _, _, _, isCraftingReagent =
        select(8, GetItemInfo(itemLink))
    local itemFamily = GetItemFamily and GetItemFamily(itemLink) or 0

    if KeyringBag and itemFamily == 256 and HasKeyring() and GetNumFreeSlots then
        local freeKeyringSlots = GetNumFreeSlots(KeyringBag)
        if freeKeyringSlots and freeKeyringSlots > 0 then
            return true
        end
    end

    local inventoryItemCount = GetItemCount and GetItemCount(itemLink) or 0
    if inventoryItemCount > 0 and itemStackCount and itemStackCount > 1 then
        if ((itemStackCount - inventoryItemCount) % itemStackCount) >= (itemQuantity or 1) then
            return true
        end
    end

    if not GetNumFreeSlots then return true end

    for bagSlot = BACKPACK_CONTAINER, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
        local freeSlots, bagFamily = GetNumFreeSlots(bagSlot)
        if freeSlots and freeSlots > 0 then
            if ReagentBag and bagSlot == ReagentBag then
                if isCraftingReagent then
                    return true
                end
            elseif not bagFamily or bagFamily == 0
                or (band and band(itemFamily, bagFamily) > 0) then
                return true
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- 逐格拾取
-- ---------------------------------------------------------------------------
local ShowLootFrame -- 前置声明，StartLooting 会回调它

local function CancelLootTicker()
    if internal.lootTicker then
        internal.lootTicker:Cancel()
        internal.lootTicker = nil
    end
end

local function LootSlotWithChecks(slot)
    local slotType = GetLootSlotType(slot)
    if slotType == SLOT_TYPE_NONE then
        return true
    end

    local lootQuantity, _, lootQuality, lootLocked, isQuestItem =
        select(3, GetLootSlotInfo(slot))

    -- 锁定中或达到需求/贪婪门槛的物品留给玩家自己处理
    if lootLocked or (slotType == SLOT_TYPE_ITEM
        and lootQuality and lootQuality >= internal.lootThreshold) then
        return false
    end

    if slotType ~= SLOT_TYPE_ITEM
        or (hasQuestBag and isQuestItem)
        or ProcessLootItem(GetLootSlotLink(slot), lootQuantity) then
        LootSlot(slot)
        return true
    end

    return false
end

local function SetLootThreshold()
    if IsGameStandard then
        local _, instanceType = IsInInstance()
        local isInRaidInstance = IsInGroup() and instanceType == "raid"
        internal.lootThreshold = isInRaidInstance and 2 or DEFAULT_LOOT_THRESHOLD
        return
    end

    if C_PartyInfo and C_PartyInfo.GetLootMethod and LootMethodEnum then
        local lootMethod = C_PartyInfo.GetLootMethod()
        local usesThreshold = lootMethod == LootMethodEnum.Group
            or lootMethod == LootMethodEnum.Needbeforegreed
            or lootMethod == LootMethodEnum.Masterlooter
        if IsInGroup() and usesThreshold and type(GetLootThreshold) == "function" then
            internal.lootThreshold = GetLootThreshold()
        else
            internal.lootThreshold = DEFAULT_LOOT_THRESHOLD
        end
    else
        internal.lootThreshold = DEFAULT_LOOT_THRESHOLD
    end
end

local function StartLooting(numItems)
    CancelLootTicker()
    local currentLootSlot = numItems

    internal.lootTicker = C_Timer.NewTicker(LOOT_TICK, function()
        if currentLootSlot >= 1 then
            if not LootSlotWithChecks(currentLootSlot) then
                internal.lootFailure = true
            end
            currentLootSlot = currentLootSlot - 1
        else
            if internal.lootFailure then
                ShowLootFrame()
            end
            CancelLootTicker()
        end
    end, numItems + 1)
end

-- ---------------------------------------------------------------------------
-- 拾取框显示 / 复位（与原插件的隐藏与回退逻辑一致）
-- ---------------------------------------------------------------------------
local function AnchorLootFrame()
    local frame = LootFrame
    if not frame then return end

    if GetCVarBool("lootUnderMouse") then
        local x, y = GetCursorPosition()
        frame:ClearAllPoints()

        if internal.hasEditModeWithLootWindow then
            x = x / frame:GetEffectiveScale() - 30
            y = math.max((y / frame:GetEffectiveScale()) + 50, 350)
            frame:SetPoint("TOPLEFT", nil, "BOTTOMLEFT", x, y)
        else
            x = x / frame:GetEffectiveScale()
            y = y / frame:GetEffectiveScale()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x - 40, y + 20)
            frame:GetCenter()
        end
        frame:Raise()
    elseif internal.hasEditModeWithLootWindow then
        local scale = frame:GetScale()
        local info = frame.systemInfo and frame.systemInfo.anchorInfo
        if info then
            frame:SetPoint(info.point, info.relativeTo, info.relativePoint,
                info.offsetX / scale, info.offsetY / scale)
        end
    else
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -125)
    end
end

ShowLootFrame = function(delayed)
    internal.isHidden = false
    if LootFrame and LootFrame:IsEventRegistered("LOOT_OPENED") then
        LootFrame:SetParent(UIParent)
        LootFrame:SetFrameStrata("HIGH")
        AnchorLootFrame()
        if delayed then
            AnchorLootFrame()
        end
    end
end

local function ResetLootFrame()
    if LootFrame and LootFrame:IsEventRegistered("LOOT_OPENED") then
        -- 挂到隐藏的父框上，自动拾取期间不显示暴雪拾取框
        LootFrame:SetParent(internal.frame)
    end
end

-- ---------------------------------------------------------------------------
-- 事件处理
-- ---------------------------------------------------------------------------
local function OnLootReady(autoLoot)
    internal.isLooting = true

    -- 连续点击时 LOOT_READY 的 autoLoot 值会来回变，只认第一次的状态
    if not internal.initialAutoLootState then
        internal.initialAutoLootState = autoLoot
            or (not autoLoot
                and GetCVarBool("autoLootDefault") ~= IsModifiedClick("AUTOLOOTTOGGLE"))
    end

    local numItems = GetNumLootItems()
    if numItems == 0 or internal.lastNumLoot == numItems then
        return
    end

    if type(IsFishingLoot) == "function" and IsFishingLoot()
        and SOUNDKIT and SOUNDKIT.FISHING_REEL_IN then
        PlaySound(SOUNDKIT.FISHING_REEL_IN, "master")
    end

    if internal.initialAutoLootState then
        SetLootThreshold()
        StartLooting(numItems)
    else
        ShowLootFrame()
    end

    internal.lastNumLoot = numItems
end

local function OnLootClosed()
    CancelLootTicker()
    internal.isLooting = false
    internal.isHidden = true
    internal.lastNumLoot = nil
    internal.initialAutoLootState = false
    internal.lootFailure = false

    if IsEnabled() then
        ResetLootFrame()
    end
end

local function OnErrorMessage(message)
    if not IsEnabled() or not internal.isLooting or not internal.isHidden then
        return
    end

    if message == ERR_INV_FULL or message == ERR_ITEM_MAX_COUNT
        or message == ERR_LOOT_ROLL_PENDING then
        ShowLootFrame(true)
    end
end

local function OnBindConfirm(slot)
    if not IsEnabled() or not internal.isLooting then return end

    if type(LootSlotHasItem) == "function" and LootSlotHasItem(slot)
        and internal.isHidden then
        ShowLootFrame(true)
    end
end

-- 编辑模式下让暴雪编辑模式能正常预览拾取框
if internal.hasEditModeWithLootWindow then
    hooksecurefunc(LootFrame, "UpdateShownState", function(frame)
        if not IsEnabled() then return end
        frame:SetParent(frame.isInEditMode and UIParent or internal.frame)
    end)
end

local speedyModule

local function ResetInternalState()
    CancelLootTicker()
    internal.isLooting = false
    internal.isHidden = true
    internal.lastNumLoot = nil
    internal.initialAutoLootState = false
    internal.lootFailure = false
    if LootFrame then
        -- 停止接管，把拾取框还给暴雪
        LootFrame:SetParent(UIParent)
    end
end

local YIELD_MESSAGE = "|cff66ccffLeatrixPlusExt|r Leatrix Plus 的「加速自动拾取」已开启，"
    .. "「增强自动拾取」保持关闭。需要本功能接管时，"
    .. "请先在 Leatrix Plus 里关闭「加速自动拾取」，重载界面后再勾选本功能。"

-- Leatrix Plus 的「加速自动拾取」优先：它开着时本模块让位。
-- 不改写 LeaPlusDB，只把自己的开关关掉；重载后仍以 Leatrix Plus 的设置为准。
local function YieldToLeatrix(showMessage)
    if not IsEnabled() then return false end
    if not LeatrixFasterLootOn() then return false end

    DB.speedyAutoLoot = false
    if speedyModule and speedyModule.checkbox then
        speedyModule.checkbox:SetChecked(false)
    end
    ResetInternalState()

    if showMessage then print(YIELD_MESSAGE) end
    return true
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("LOOT_READY")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("LOOT_BIND_CONFIRM")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        if yieldedToLeatrixAtLoad then
            print(YIELD_MESSAGE)
            yieldedToLeatrixAtLoad = false
        end
        -- 文件加载时 LeaPlusDB 可能还没就绪，这里再确认一次
        if not YieldToLeatrix(true) and IsEnabled() then
            ResetLootFrame()
        end
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
        return
    end

    if not IsEnabled() then return end

    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        OnLootReady(arg1)
    elseif event == "LOOT_CLOSED" then
        OnLootClosed()
    elseif event == "LOOT_BIND_CONFIRM" then
        OnBindConfirm(arg1)
    elseif event == "UI_ERROR_MESSAGE" then
        OnErrorMessage(arg2)
    end
end)

-- ---------------------------------------------------------------------------
-- 模块注册
-- ---------------------------------------------------------------------------
local function SetModuleEnabled(enabled)
    if enabled then
        -- Leatrix Plus 的「加速自动拾取」优先：它开着时本模块保持关闭
        if YieldToLeatrix(true) then
            return
        end
        ResetLootFrame()
    else
        ResetInternalState()
    end
end

speedyModule = NS.RegisterModule({
    key = "speedyAutoLoot",
    section = "拾取",
    label = "增强自动拾取",
    tip = "加快自动拾取，自动跳过需要 roll 或装不下的物品，失败时展开拾取框。"
        .. "\n\n与 Leatrix Plus 的「加速自动拾取」二选一：它开启时本功能会保持关闭。"
        .. "需要本插件接管时，请先在 Leatrix Plus 里关闭它并重载界面，再勾选本功能。",
    default = DEFAULT,
    onToggle = SetModuleEnabled,
})
