-- LeatrixPlusExt 模块：标记已学会/不可用物品
-- 在商人、拍卖行和公会银行中给已学会/已收集的物品染色
local addonName, NS = ...

local DB = NS.DB

local DEFAULT = true
local DEFAULT_R, DEFAULT_G, DEFAULT_B = 0, 1, 0 -- 绿色：已学会/已收集
local TEMPORARY_R, TEMPORARY_G, TEMPORARY_B = 1, 0.9, 0 -- 黄色：等级或技能暂时不够
local PERMANENT_R, PERMANENT_G, PERMANENT_B = 1, 0.2, 0.2 -- 红色：本职业以后也不能用

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

-- 这个客户端会把部分数值标记为机密，读出来也不能比较或运算
local function Legible(value)
    if value == nil then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

-- 物品说明里需求未满足的提示会显示为红色（等级、职业、声望等）
local function IsRedLine(line)
    if not line or type(line.GetTextColor) ~= "function" then return false end
    local ok, r, g, b = pcall(line.GetTextColor, line)
    if not ok then return false end
    r, g, b = Legible(r), Legible(g), Legible(b)
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
        return false
    end
    return r > 0.9 and g < 0.2 and b < 0.2
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
-- 本职业能否装备：用于区分「以后也不能用」和「暂时不能用」
-- ---------------------------------------------------------------------------
local ARMOR_CLASS = (ItemClass and ItemClass.Armor) or 4
local WEAPON_CLASS = (ItemClass and ItemClass.Weapon) or 2

local ArmorSubclass = Enum and Enum.ItemArmorSubclass
local WeaponSubclass = Enum and Enum.ItemWeaponSubclass

local function SubclassSet(enumTable, names)
    if not enumTable then return nil end
    local set = {}
    for i = 1, #names do
        local id = enumTable[names[i]]
        if type(id) == "number" then set[id] = true end
    end
    return set
end

-- 1 布甲、2 皮甲、3 锁甲、4 板甲、6 盾牌；其他子类（杂项、战袍等）不限制
local ARMOR_PROFICIENCY = {
    WARRIOR = SubclassSet(ArmorSubclass, { "Cloth", "Leather", "Mail", "Plate", "Shield" }),
    PALADIN = SubclassSet(ArmorSubclass, { "Cloth", "Leather", "Mail", "Plate", "Shield" }),
    HUNTER  = SubclassSet(ArmorSubclass, { "Cloth", "Leather", "Mail" }),
    ROGUE   = SubclassSet(ArmorSubclass, { "Cloth", "Leather" }),
    PRIEST  = SubclassSet(ArmorSubclass, { "Cloth" }),
    SHAMAN  = SubclassSet(ArmorSubclass, { "Cloth", "Leather", "Mail", "Shield" }),
    MAGE    = SubclassSet(ArmorSubclass, { "Cloth" }),
    WARLOCK = SubclassSet(ArmorSubclass, { "Cloth" }),
    DRUID   = SubclassSet(ArmorSubclass, { "Cloth", "Leather" }),
}

local WEAPON_PROFICIENCY = {
    WARRIOR = SubclassSet(WeaponSubclass, {
        "Axe1H", "Axe2H", "Mace1H", "Mace2H", "Sword1H", "Sword2H",
        "Polearm", "Staff", "Unarmed", "Dagger", "Thrown",
        "Bows", "Crossbow", "Guns", "Fishingpole", "Generic",
    }),
    PALADIN = SubclassSet(WeaponSubclass, {
        "Axe1H", "Axe2H", "Mace1H", "Mace2H", "Sword1H", "Sword2H",
        "Polearm", "Fishingpole", "Generic",
    }),
    HUNTER = SubclassSet(WeaponSubclass, {
        "Axe1H", "Axe2H", "Sword1H", "Sword2H", "Dagger", "Polearm",
        "Staff", "Unarmed", "Bows", "Crossbow", "Guns", "Thrown",
        "Fishingpole", "Generic",
    }),
    ROGUE = SubclassSet(WeaponSubclass, {
        -- 无限服按巫妖王之怒规则：盗贼可以用单手斧
        "Axe1H", "Sword1H", "Mace1H", "Dagger", "Unarmed", "Thrown",
        "Bows", "Crossbow", "Guns", "Fishingpole", "Generic",
    }),
    PRIEST = SubclassSet(WeaponSubclass, {
        "Mace1H", "Dagger", "Staff", "Wand", "Fishingpole", "Generic",
    }),
    SHAMAN = SubclassSet(WeaponSubclass, {
        "Axe1H", "Axe2H", "Mace1H", "Mace2H", "Dagger", "Staff",
        "Unarmed", "Fishingpole", "Generic",
    }),
    MAGE = SubclassSet(WeaponSubclass, {
        "Sword1H", "Dagger", "Staff", "Wand", "Fishingpole", "Generic",
    }),
    WARLOCK = SubclassSet(WeaponSubclass, {
        "Sword1H", "Dagger", "Staff", "Wand", "Fishingpole", "Generic",
    }),
    DRUID = SubclassSet(WeaponSubclass, {
        -- 无限服按巫妖王之怒规则：德鲁伊可以用长柄武器
        "Mace1H", "Mace2H", "Dagger", "Staff", "Polearm", "Unarmed",
        "Fishingpole", "Generic",
    }),
}

-- 只对已知的护甲/武器子类下判断，避免把没见过的新类型误标成不能用
local RestrictedArmor = SubclassSet(ArmorSubclass, {
    "Cloth", "Leather", "Mail", "Plate", "Buckler", "Shield",
}) or {}

local KnownWeaponSubclasses = {}
for _, set in pairs(WEAPON_PROFICIENCY) do
    if set then
        for id in pairs(set) do KnownWeaponSubclasses[id] = true end
    end
end

local classToken

local function PlayerClassToken()
    if classToken then return classToken end
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(UnitClass, "player")
    if ok and type(token) == "string" then classToken = token end
    return classToken
end

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

-- 从游戏内置字符串构造需求提示的匹配式
local function RequirementPattern(format)
    if type(format) ~= "string" then return nil end
    local pattern = format:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
    pattern = pattern:gsub("%%d", "%%d+")
    pattern = pattern:gsub("%%s", ".+")
    return "^" .. pattern
end

local CLASS_ALLOWED_PATTERN = RequirementPattern(ITEM_CLASSES_ALLOWED)
local RACE_ALLOWED_PATTERN = RequirementPattern(ITEM_RACES_ALLOWED)

local function LineText(line)
    if not line or type(line.GetText) ~= "function" then return nil end
    local ok, text = pcall(line.GetText, line)
    if not ok or type(text) ~= "string" then return nil end
    return Legible(text)
end

local function ItemSubclass(itemLink)
    if type(ItemInfoInstant) ~= "function" then return nil, nil end
    local ok, _, _, _, _, _, classId, subclassId = pcall(ItemInfoInstant, itemLink)
    if not ok then return nil, nil end
    return Legible(classId), Legible(subclassId)
end

-- 本职业永远不能装备的护甲/武器类型
local function CannotEquipType(classId, subclassId)
    if type(classId) ~= "number" or type(subclassId) ~= "number" then
        return false
    end
    local token = PlayerClassToken()
    if not token then return false end

    if classId == ARMOR_CLASS then
        if not RestrictedArmor[subclassId] then return false end
        local allowed = ARMOR_PROFICIENCY[token]
        return allowed ~= nil and allowed[subclassId] ~= true
    end

    if classId == WEAPON_CLASS then
        if not KnownWeaponSubclasses[subclassId] then return false end
        local allowed = WEAPON_PROFICIENCY[token]
        return allowed ~= nil and allowed[subclassId] ~= true
    end

    return false
end

-- 返回 "permanent"（以后也不能用）、"temporary"（暂时不能用）或 nil（可以使用）
local function GetUnusableKind(itemLink)
    if not itemLink then return nil end

    local classId, subclassId = ItemSubclass(itemLink)
    if CannotEquipType(classId, subclassId) then
        return "permanent"
    end

    local tip = GetScanner()
    local sawRed = false
    if tip then
        pcall(tip.ClearLines, tip)
        local ok = pcall(tip.SetHyperlink, tip, itemLink)
        if ok then
            local numLines = tip:NumLines() or 0
            for i = 2, numLines do -- 第 1 行是物品名
                local line = _G["LeatrixPlusExtAKScanningTooltipTextLeft" .. i]
                if IsRedLine(line) then
                    sawRed = true
                    local text = LineText(line)
                    if text and (
                        (CLASS_ALLOWED_PATTERN and text:find(CLASS_ALLOWED_PATTERN))
                        or (RACE_ALLOWED_PATTERN and text:find(RACE_ALLOWED_PATTERN))
                    ) then
                        return "permanent" -- 职业/种族限制不会随等级改变
                    end
                end
            end
        end
    end

    -- 等级兜底：需求等级高于当前等级时，无论提示是否变色都算暂时不能用
    local requiredLevel
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, _, _, level = pcall(C_Item.GetItemInfo, itemLink)
        if ok then requiredLevel = level end
    elseif type(GetItemInfo) == "function" then
        local ok, _, _, _, level = pcall(GetItemInfo, itemLink)
        if ok then requiredLevel = level end
    end
    requiredLevel = Legible(requiredLevel)
    if type(requiredLevel) == "number" and requiredLevel > 0
        and type(UnitLevel) == "function" then
        local ok, playerLevel = pcall(UnitLevel, "player")
        playerLevel = ok and Legible(playerLevel) or nil
        if type(playerLevel) == "number" and playerLevel < requiredLevel then
            return "temporary"
        end
    end

    if sawRed then return "temporary" end -- 技能、声望等以后可能满足的需求
    return nil
end

local function GetItemMark(itemLink)
    if not itemLink then return nil end
    if IsKnown(itemLink) then return "known" end
    return GetUnusableKind(itemLink)
end

-- 不能用的物品先把图标去色再染色，避免彩色图标把黄/红冲淡
local function ShouldDesaturate(mark)
    return mark == "temporary" or mark == "permanent"
end

-- ---------------------------------------------------------------------------
-- 商人
-- ---------------------------------------------------------------------------
-- 商人界面默认会把“已学会”和“不能用”的物品名称显示成红色。
-- 只染图标和名称底色的话，名称文字仍然是红的，所以要把文字颜色也一起改掉。
local merchantNameDefaults = {}

local function GetTextColor(name)
    if not name or type(name.GetTextColor) ~= "function" then return nil end
    local ok, r, g, b = pcall(name.GetTextColor, name)
    if not ok then return nil end
    r, g, b = Legible(r), Legible(g), Legible(b)
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
        return nil
    end
    return r, g, b
end

local function ApplyMerchant(vendorUpdated)
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

        local mark
        if enabled and itemLink then
            mark = GetItemMark(itemLink)
        end

        if itemButton and merchantButton then
            local vr, vg, vb = 1, 1, 1
            local ir, ig, ib = 1, 1, 1
            if mark == "known" then
                vr, vg, vb = r, g, b
                ir, ig, ib = 0.9 * r, 0.9 * g, 0.9 * b
            elseif mark == "permanent" then
                vr, vg, vb = PERMANENT_R, PERMANENT_G, PERMANENT_B
                ir, ig, ib = 0.9 * PERMANENT_R,
                    0.9 * PERMANENT_G, 0.9 * PERMANENT_B
            elseif mark == "temporary" then
                vr, vg, vb = TEMPORARY_R, TEMPORARY_G, TEMPORARY_B
                ir, ig, ib = 0.9 * TEMPORARY_R,
                    0.9 * TEMPORARY_G, 0.9 * TEMPORARY_B
            end

            -- 记住商人原本的名称颜色，取消标记或关闭功能时恢复
            local name = merchantButton.Name
            local saved = merchantNameDefaults[merchantButton]
            if saved and saved.link ~= itemLink then
                saved = nil
                merchantNameDefaults[merchantButton] = nil
            end
            if mark then
                if vendorUpdated or not saved then
                    local sr, sg, sb = GetTextColor(name)
                    if sr then
                        saved = { link = itemLink, r = sr, g = sg, b = sb }
                        merchantNameDefaults[merchantButton] = saved
                    end
                end
            elseif saved then
                if not vendorUpdated then
                    SafeCall(name and name.SetTextColor, name,
                        saved.r, saved.g, saved.b)
                end
                merchantNameDefaults[merchantButton] = nil
            end

            -- 名称底色压暗，让上面的彩色文字更清楚
            local nr, ng, nb = 1, 1, 1
            if mark then
                nr, ng, nb = 0.25 * vr, 0.25 * vg, 0.25 * vb
            end
            SafeCall(SetItemButtonNameFrameVertexColor, merchantButton, nr, ng, nb)
            SafeCall(SetItemButtonSlotVertexColor, merchantButton, vr, vg, vb)
            SafeCall(SetItemButtonTextureVertexColor, itemButton, ir, ig, ib)
            SafeCall(SetItemButtonNormalTextureVertexColor, itemButton, ir, ig, ib)

            if mark and name then
                SafeCall(name.SetTextColor, name, vr, vg, vb)
            end

            if icon then
                SafeCall(icon.SetDesaturated, icon, ShouldDesaturate(mark))
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
            local mark
            if enabled and itemLink then
                mark = GetItemMark(itemLink)
            end
            if mark == "known" then
                SafeCall(icon.SetVertexColor, icon, r, g, b)
            elseif mark == "permanent" then
                SafeCall(icon.SetVertexColor, icon,
                    PERMANENT_R, PERMANENT_G, PERMANENT_B)
            elseif mark == "temporary" then
                SafeCall(icon.SetVertexColor, icon,
                    TEMPORARY_R, TEMPORARY_G, TEMPORARY_B)
            else
                SafeCall(icon.SetVertexColor, icon, 1, 1, 1)
            end
            SafeCall(icon.SetDesaturated, icon, ShouldDesaturate(mark))
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

            local mark
            if enabled then
                mark = GetItemMark(itemLink)
            end

            local cr, cg, cb = 1, 1, 1
            if mark == "known" then
                cr, cg, cb = r, g, b
            elseif mark == "permanent" then
                cr, cg, cb = PERMANENT_R, PERMANENT_G, PERMANENT_B
            elseif mark == "temporary" then
                cr, cg, cb = TEMPORARY_R, TEMPORARY_G, TEMPORARY_B
            end

            local marked = mark ~= nil
            local cell = button.cells and button.cells[2]
            if button.SelectedHighlight then
                if marked then
                    button.SelectedHighlight:Show()
                    SafeCall(button.SelectedHighlight.SetVertexColor,
                        button.SelectedHighlight, cr, cg, cb)
                    SafeCall(button.SelectedHighlight.SetAlpha,
                        button.SelectedHighlight, 0.2)
                else
                    SafeCall(button.SelectedHighlight.SetVertexColor,
                        button.SelectedHighlight, 1, 1, 1)
                end
            end
            if cell then
                if cell.Icon then
                    SafeCall(cell.Icon.SetVertexColor, cell.Icon, cr, cg, cb)
                    SafeCall(cell.Icon.SetDesaturated, cell.Icon, ShouldDesaturate(mark))
                end
                if cell.IconBorder then
                    SafeCall(cell.IconBorder.SetVertexColor, cell.IconBorder, cr, cg, cb)
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
            local mark
            if enabled and itemLink then
                mark = GetItemMark(itemLink)
            end
            if mark == "known" then
                SafeCall(SetItemButtonTextureVertexColor, button,
                    0.9 * r, 0.9 * g, 0.9 * b)
            elseif mark == "permanent" then
                SafeCall(SetItemButtonTextureVertexColor, button,
                    0.9 * PERMANENT_R, 0.9 * PERMANENT_G, 0.9 * PERMANENT_B)
            elseif mark == "temporary" then
                SafeCall(SetItemButtonTextureVertexColor, button,
                    0.9 * TEMPORARY_R, 0.9 * TEMPORARY_G, 0.9 * TEMPORARY_B)
            else
                SafeCall(SetItemButtonTextureVertexColor, button, 1, 1, 1)
            end
            SafeCall(SetItemButtonDesaturated, button, ShouldDesaturate(mark))
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
        hooksecurefunc("MerchantFrame_UpdateMerchantInfo", function()
            ApplyMerchant(true)
        end)
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
hookFrame:RegisterEvent("PLAYER_LEVEL_UP") -- 等级变化后重新判断哪些物品暂时不能用
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
    label = "标记已学会/不可用物品",
    tip = "在商人、拍卖行和公会银行中标记物品：绿色为已学会/已收集，黄色为等级、技能或声望暂时不够，红色为本职业以后也不能用。不能用的物品图标会变灰。",
    default = DEFAULT,
    onToggle = function()
        knownTable = {}
        RefreshAll()
    end,
})
