-- LeatrixPlusExt 模块：标记已学会的物品
-- 在商人、拍卖行和公会银行中给已学会/已收集的物品染色
local addonName, NS = ...

local DB = NS.DB

local DEFAULT = true
local DEFAULT_R, DEFAULT_G, DEFAULT_B = 0, 1, 0 -- 固定绿色标记

local ItemClass = Enum and Enum.ItemClass
local ItemMisc = Enum and Enum.ItemMiscellaneousSubclass

-- 从全局字符串构造“宠物已收集”匹配式（与 AlreadyKnown 相同）
local S_PET_KNOWN = ITEM_PET_KNOWN and ITEM_PET_KNOWN:match("[^%(]+")

-- 已知物品缓存（只缓存 true，避免反复扫描 tooltip）
local knownTable = {}

-- 扫描用 tooltip（与商人/拍卖行无关，只用来读取物品说明）
local scannerTip

-- ---------------------------------------------------------------------------
-- 设置读取
-- ---------------------------------------------------------------------------
local function GetColor()
    return DEFAULT_R, DEFAULT_G, DEFAULT_B
end

local function IsEnabled()
    local value = DB.alreadyKnown
    if value == nil then return DEFAULT end
    return value and true or false
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    return (pcall(fn, ...))
end

-- ---------------------------------------------------------------------------
-- 物品数据
-- ---------------------------------------------------------------------------
-- 这些容器里的配方无法从物品本身判断是否已学会，只能逐个检查内容物
local containerItems = {
    [21740] = { 21724, 21725, 21726 }, -- Small Rocket Recipes
    [21741] = { 21730, 21731, 21732 }, -- Cluster Rocket Recipes
    [21742] = { 21727, 21728, 21729 }, -- Large Rocket Recipes
    [21743] = { 21733, 21734, 21735 }, -- Large Cluster Rocket Recipes
}

-- 术士宠物技能书：物品 ID -> 法术 ID
local spellbookItems = {
    [16302] = 7799, [16316] = 7800, [16317] = 7801, [16318] = 7802,
    [16319] = 11762, [16320] = 1176,
    [16321] = 6307, [16322] = 7804, [16323] = 7805, [16324] = 11766,
    [16325] = 1176,
    [16326] = 2947, [16327] = 8316, [16328] = 8317, [16329] = 11700,
    [16330] = 11701,
    [16331] = 4511,
    [16346] = 7809, [16347] = 7810, [16348] = 7811, [16349] = 11774,
    [16350] = 11775,
    [16351] = 7812, [16352] = 19438, [16353] = 19440, [16354] = 19441,
    [16355] = 19442, [16356] = 1944,
    [16357] = 17767, [16358] = 17850, [16359] = 17851, [16360] = 17852,
    [16361] = 17853, [16362] = 17854,
    [16363] = 17735, [16364] = 17750, [16365] = 17751, [16366] = 17752,
    [16368] = 7815, [16371] = 7816, [16372] = 11778, [16373] = 11779,
    [16374] = 11780,
    [16375] = 6360, [16376] = 7813, [16377] = 11784, [16378] = 11785,
    [16379] = 6358, [16380] = 7870,
    [16381] = 19731, [16382] = 19734, [16383] = 19736,
    [16384] = 19478, [16385] = 19655, [16386] = 19656, [16387] = 19660,
    [16388] = 19244, [16389] = 19647,
    [16390] = 19480,
}

-- ---------------------------------------------------------------------------
-- 已知判断
-- ---------------------------------------------------------------------------
local function GetScanner()
    if scannerTip then return scannerTip end
    local ok, tip = pcall(CreateFrame, "GameTooltip",
        "LeatrixPlusExtAKScanningTooltip", nil, "GameTooltipTemplate")
    if ok and tip then
        tip:SetOwner(UIParent, "ANCHOR_NONE")
        scannerTip = tip
    end
    return scannerTip
end

local function ItemInfoInstant(itemLink)
    if C_Item and C_Item.GetItemInfoInstant then
        return C_Item.GetItemInfoInstant(itemLink)
    end
    if type(GetItemInfoInstant) == "function" then
        return GetItemInfoInstant(itemLink)
    end
    return nil
end

local function CheckTooltipLine(text, i, itemLink)
    if not text then return false end

    if ITEM_SPELL_KNOWN and text == ITEM_SPELL_KNOWN then
        return true -- 物品已学会
    end

    if S_PET_KNOWN and text:match(S_PET_KNOWN) then
        return true -- 宠物已收集
    end

    if TOY and text == TOY then
        local tipName = scannerTip and scannerTip:GetName()
        local nextLine = tipName and _G[tipName .. "TextLeft" .. (i + 2)]
        if nextLine and nextLine:GetText() == ITEM_SPELL_KNOWN then
            return true -- 玩具已学会
        end
    end

    if ITEM_COSMETIC and text == ITEM_COSMETIC
        and itemLink and C_TransmogCollection
        and C_TransmogCollection.PlayerHasTransmogByItemInfo then
        local known = C_TransmogCollection.PlayerHasTransmogByItemInfo(itemLink)
        if known then return true end
    end

    return false
end

local function IsKnown(itemLink)
    if not itemLink then return false end
    if knownTable[itemLink] then return true end

    local itemId, _, _, _, itemIcon, classId, subclassId = ItemInfoInstant(itemLink)
    itemId = itemId or tonumber(itemLink:match("item:(%d+)"))

    local function MarkKnown()
        knownTable[itemLink] = true
        return true
    end

    if itemId then
        -- 容器（火箭配方包）
        local contents = containerItems[itemId]
        if contents then
            local knownCount = 0
            for i = 1, #contents do
                if IsKnown(("item:%d"):format(contents[i])) then
                    knownCount = knownCount + 1
                end
            end
            if knownCount == #contents then return MarkKnown() end
            return false
        end

        -- 术士宠物技能书
        local spellId = spellbookItems[itemId]
        if spellId and type(HasPetSpells) == "function" then
            local numSpells, petToken = HasPetSpells()
            if numSpells and petToken == "DEMON" and BOOKTYPE_PET then
                for i = 1, numSpells do
                    local _, _, knownSpellId = GetSpellBookItemName(i, BOOKTYPE_PET)
                    if knownSpellId == spellId then return MarkKnown() end
                end
            end
            return false
        end
    end

    -- 笼装战斗宠物
    if itemLink:match("|H(.-):") == "battlepet" then
        local _, battlepetId = strsplit(":", itemLink)
        battlepetId = tonumber(battlepetId)
        if battlepetId and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
            if (C_PetJournal.GetNumCollectedInfo(battlepetId) or 0) > 0 then
                return MarkKnown()
            end
        end
        return false
    end

    -- 小伙伴 / 坐骑（说明文字里不一定有"已学会"）
    if itemId and classId and ItemClass and ItemMisc then
        if classId == ItemClass.Miscellaneous and subclassId == ItemMisc.CompanionPet then
            local itemName = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemId)
                or (type(GetItemInfo) == "function" and GetItemInfo(itemId))
            if itemName then
                if C_PetJournal and C_PetJournal.GetNumPets then
                    local _, numOwned = C_PetJournal.GetNumPets()
                    for i = 1, numOwned do
                        local _, _, owned, _, _, _, _, speciesName, icon =
                            C_PetJournal.GetPetInfoByIndex(i)
                        if owned and icon == itemIcon and speciesName
                            and itemName:find(speciesName, 1, true) then
                            return MarkKnown()
                        end
                    end
                elseif type(GetNumCompanions) == "function" then
                    local numCompanions = GetNumCompanions("CRITTER") or 0
                    for i = 1, numCompanions do
                        local _, creatureName, _, icon = GetCompanionInfo("CRITTER", i)
                        if icon == itemIcon and creatureName
                            and itemName:find(creatureName, 1, true) then
                            return MarkKnown()
                        end
                    end
                end
            end
            return false
        end

        if classId == ItemClass.Miscellaneous and subclassId == ItemMisc.Mount
            and C_MountJournal and C_MountJournal.GetNumMounts then
            local itemName = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemId)
                or (type(GetItemInfo) == "function" and GetItemInfo(itemId))
            if itemName then
                local numMounts = C_MountJournal.GetNumMounts()
                for i = 1, numMounts do
                    local creatureName, _, icon, _, _, _, _, _, _, _, isCollected =
                        C_MountJournal.GetDisplayedMountInfo(i)
                    if isCollected and icon == itemIcon and creatureName
                        and itemName:find(creatureName, 1, true) then
                        return MarkKnown()
                    end
                end
            end
            return false
        end
    end

    -- 最后扫描物品说明
    local tip = GetScanner()
    if not tip then return false end
    pcall(tip.ClearLines, tip)
    local ok = pcall(tip.SetHyperlink, tip, itemLink)
    if not ok then return false end

    local numLines = tip:NumLines() or 0
    for i = 2, numLines do -- 第 1 行是物品名
        local line = _G["LeatrixPlusExtAKScanningTooltipTextLeft" .. i]
        local text = line and line:GetText()
        if CheckTooltipLine(text, i, itemLink) then
            return MarkKnown()
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- 商人
-- ---------------------------------------------------------------------------
local function ApplyMerchant()
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    if not MERCHANT_ITEMS_PER_PAGE or not MerchantFrame.page then return end

    local r, g, b = GetColor()
    local enabled = IsEnabled()

    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        local index = ((MerchantFrame.page - 1) * MERCHANT_ITEMS_PER_PAGE) + i
        local itemButton = _G["MerchantItem" .. i .. "ItemButton"]
        local merchantButton = _G["MerchantItem" .. i]
        local icon = _G["MerchantItem" .. i .. "ItemButtonIconTexture"]
        local itemLink = type(GetMerchantItemLink) == "function"
            and GetMerchantItemLink(index)

        local known = enabled and itemLink and IsKnown(itemLink)

        if itemButton and merchantButton then
            local vr, vg, vb = 1, 1, 1
            if known then vr, vg, vb = r, g, b end

            SafeCall(SetItemButtonNameFrameVertexColor, merchantButton, vr, vg, vb)
            SafeCall(SetItemButtonSlotVertexColor, merchantButton, vr, vg, vb)
            SafeCall(SetItemButtonTextureVertexColor, itemButton,
                known and 0.9 * r or 1, known and 0.9 * g or 1, known and 0.9 * b or 1)
            SafeCall(SetItemButtonNormalTextureVertexColor, itemButton,
                known and 0.9 * r or 1, known and 0.9 * g or 1, known and 0.9 * b or 1)

            if icon then
                SafeCall(icon.SetDesaturated, icon, false)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 拍卖行：旧版（Classic Era）
-- ---------------------------------------------------------------------------
local function ApplyAuctionClassic()
    if not BrowseScrollFrame or not NUM_BROWSE_TO_DISPLAY then return end

    local r, g, b = GetColor()
    local enabled = IsEnabled()
    local offset = 0
    if type(FauxScrollFrame_GetOffset) == "function" then
        offset = FauxScrollFrame_GetOffset(BrowseScrollFrame) or 0
    end

    for i = 1, NUM_BROWSE_TO_DISPLAY do
        local icon = _G["BrowseButton" .. i .. "ItemIconTexture"]
        local button = _G["BrowseButton" .. i .. "Item"]
        if icon and button then
            local itemLink = type(GetAuctionItemLink) == "function"
                and GetAuctionItemLink("list", offset + i)
            local known = enabled and itemLink and IsKnown(itemLink)
            if known then
                SafeCall(icon.SetVertexColor, icon, r, g, b)
            else
                SafeCall(icon.SetVertexColor, icon, 1, 1, 1)
            end
            SafeCall(icon.SetDesaturated, icon, false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 拍卖行：新版
-- ---------------------------------------------------------------------------
local function ApplyAuctionModern(scrollBox)
    if not scrollBox or not scrollBox.ScrollTarget then return end

    local r, g, b = GetColor()
    local enabled = IsEnabled()

    local children = { scrollBox.ScrollTarget:GetChildren() }
    for i = 1, #children do
        local button = children[i]
        local itemKey = button and button.rowData and button.rowData.itemKey
        if itemKey and itemKey.itemID then
            local itemLink
            if itemKey.itemID == 82800 and itemKey.battlePetSpeciesID then
                itemLink = ("|Hbattlepet:%d::::::|h[Dummy]|h"):format(itemKey.battlePetSpeciesID)
            else
                itemLink = ("item:%d"):format(itemKey.itemID)
            end

            local known = enabled and IsKnown(itemLink)
            local cell = button.cells and button.cells[2]
            if known then
                if button.SelectedHighlight then
                    button.SelectedHighlight:Show()
                    SafeCall(button.SelectedHighlight.SetVertexColor,
                        button.SelectedHighlight, r, g, b)
                    SafeCall(button.SelectedHighlight.SetAlpha,
                        button.SelectedHighlight, 0.2)
                end
                if cell then
                    if cell.Icon then
                        SafeCall(cell.Icon.SetVertexColor, cell.Icon, r, g, b)
                        SafeCall(cell.Icon.SetDesaturated, cell.Icon, false)
                    end
                    if cell.IconBorder then
                        SafeCall(cell.IconBorder.SetVertexColor, cell.IconBorder, r, g, b)
                    end
                end
            else
                if button.SelectedHighlight then
                    SafeCall(button.SelectedHighlight.SetVertexColor,
                        button.SelectedHighlight, 1, 1, 1)
                end
                if cell then
                    if cell.Icon then
                        SafeCall(cell.Icon.SetVertexColor, cell.Icon, 1, 1, 1)
                        SafeCall(cell.Icon.SetDesaturated, cell.Icon, false)
                    end
                    if cell.IconBorder then
                        SafeCall(cell.IconBorder.SetVertexColor, cell.IconBorder, 1, 1, 1)
                    end
                end
            end
        end
    end
end

local function GetModernAHScrollBox()
    local frame = _G.AuctionHouseFrame
    local browse = frame and frame.BrowseResultsFrame
    local list = browse and browse.ItemList
    return list and list.ScrollBox
end

-- ---------------------------------------------------------------------------
-- 公会银行
-- ---------------------------------------------------------------------------
local function ApplyGuildBank()
    if not GuildBankFrame or not GuildBankFrame.Columns then return end
    if type(GetCurrentGuildBankTab) ~= "function" then return end

    local slotsPerTab = MAX_GUILDBANK_SLOTS_PER_TAB or 98
    local slotsPerGroup = NUM_SLOTS_PER_GUILDBANK_GROUP or 14
    local tab = GetCurrentGuildBankTab()
    local r, g, b = GetColor()
    local enabled = IsEnabled()

    for i = 1, slotsPerTab do
        local index = i % slotsPerGroup
        if index == 0 then index = slotsPerGroup end
        local column = math.ceil((i - 0.5) / slotsPerGroup)
        local columnFrame = GuildBankFrame.Columns[column]
        local button = columnFrame and columnFrame.Buttons and columnFrame.Buttons[index]
        local itemLink = type(GetGuildBankItemLink) == "function"
            and GetGuildBankItemLink(tab, i)

        if button and itemLink and itemLink:find("item:82800", 1, true) then
            -- 笼装战斗宠物：从 tooltip 数据里取 speciesID
            local tip = GetScanner()
            if tip then
                local ok, speciesId = pcall(tip.SetGuildBankItem, tip, tab, i)
                if ok and type(speciesId) == "number" and speciesId > 0 then
                    itemLink = ("|Hbattlepet:%d::::::|h[Dummy]|h"):format(speciesId)
                end
            end
        end

        if button then
            local known = enabled and itemLink and IsKnown(itemLink)
            if known then
                SafeCall(SetItemButtonTextureVertexColor, button,
                    0.9 * r, 0.9 * g, 0.9 * b)
                SafeCall(SetItemButtonDesaturated, button, false)
            else
                SafeCall(SetItemButtonTextureVertexColor, button, 1, 1, 1)
                SafeCall(SetItemButtonDesaturated, button, false)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 刷新 / 钩子
-- ---------------------------------------------------------------------------
local function RefreshAll()
    pcall(ApplyMerchant)
    pcall(ApplyAuctionClassic)
    pcall(ApplyGuildBank)
    local scrollBox = GetModernAHScrollBox()
    if scrollBox then pcall(ApplyAuctionModern, scrollBox) end
end

local merchantHooked = false
local function HookMerchant()
    if merchantHooked then return end
    if type(MerchantFrame_UpdateMerchantInfo) == "function" then
        hooksecurefunc("MerchantFrame_UpdateMerchantInfo", ApplyMerchant)
        merchantHooked = true
    end
end

local hookedAddons = {}

local function HookBlizzardAddon(name)
    if hookedAddons[name] then return end
    if name == "Blizzard_AuctionUI" then
        if type(AuctionFrameBrowse_Update) == "function" then
            hooksecurefunc("AuctionFrameBrowse_Update", ApplyAuctionClassic)
            hookedAddons[name] = true
        end
    elseif name == "Blizzard_AuctionHouseUI" then
        local scrollBox = GetModernAHScrollBox()
        if scrollBox then
            hooksecurefunc(scrollBox, "Update", ApplyAuctionModern)
            hookedAddons[name] = true
        end
    elseif name == "Blizzard_GuildBankUI" then
        if _G.GuildBankFrame then
            hooksecurefunc(_G.GuildBankFrame, "Update", ApplyGuildBank)
            hookedAddons[name] = true
        end
    end
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == "Blizzard_AuctionUI"
            or name == "Blizzard_AuctionHouseUI"
            or name == "Blizzard_GuildBankUI" then
            HookBlizzardAddon(name)
        end
    else
        HookBlizzardAddon("Blizzard_AuctionUI")
        HookBlizzardAddon("Blizzard_AuctionHouseUI")
        HookBlizzardAddon("Blizzard_GuildBankUI")
        HookMerchant()
        RefreshAll()
    end
end)

HookMerchant()

NS.RegisterModule({
    key = "alreadyKnown",
    section = "物品",
    label = "标记已学会的物品",
    tip = "在商人、拍卖行和公会银行中用绿色标出已学会/已收集的物品。",
    default = DEFAULT,
    onToggle = function()
        knownTable = {}
        RefreshAll()
    end,
})
