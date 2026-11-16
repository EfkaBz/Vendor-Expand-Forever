-- Vendor Expand (Forever)
-- Elargit la fenetre du marchand pour afficher 10 a 50 objets, sans changer son interface.
-- En mode elargi : recherche, filtres rapides et tri. Partout : molette pour changer de
-- page et Maj+clic pour acheter en lot.

local ADDON = ...

local NORMAL_COLS, NORMAL_ROWS = 2, 5
local BUYBACK_COUNT = BUYBACK_ITEMS_PER_PAGE or 12
local SIZES = { 10, 20, 30, 40, 50 }
local LAYOUTS = {           -- objets par page = colonnes x lignes
    [20] = { 4, 5 },
    [30] = { 5, 6 },
    [40] = { 5, 8 },
    [50] = { 5, 10 },
}
local MAX_ITEMS = 50

local isFR = GetLocale() == "frFR"
local L = {
    expand    = isFR and "Elargir la fenêtre du marchand" or "Expand merchant window",
    collapse  = isFR and "Taille normale" or "Normal size",
    items     = isFR and "Objets" or "Items",
    perPage   = isFR and "objets par page" or "items per page",
    page      = isFR and "Page %d / %d" or "Page %d / %d",
    search    = isFR and "Rechercher..." or "Search...",
    filters   = isFR and "Filtres" or "Filters",
    fUsable   = isFR and "Utilisables seulement" or "Usable only",
    fAfford   = isFR and "Abordables seulement" or "Affordable only",
    fKnown    = isFR and "Masquer les déjà connus" or "Hide already known",
    sort      = isFR and "Tri" or "Sort",
    sDefault  = isFR and "Défaut" or "Default",
    sName     = isFR and "Nom" or "Name",
    sPriceLo  = isFR and "Prix (bas)" or "Price (low)",
    sPriceHi  = isFR and "Prix (haut)" or "Price (high)",
    sQuality  = isFR and "Qualité" or "Quality",
    noMatch   = isFR and "Aucun objet ne correspond" or "No items match",
    bulkTitle = isFR and "Acheter en lot" or "Buy in bulk",
    unit      = isFR and "Prix unitaire : " or "Unit price: ",
    altCost   = isFR and "Payé en monnaie spéciale" or "Paid with a special currency",
    total     = isFR and "Total : " or "Total: ",
    maxInfo   = isFR and "Maximum : %d %s" or "Maximum: %d %s",
    rMoney    = isFR and "(argent)" or "(money)",
    rStock    = isFR and "(stock du marchand)" or "(merchant stock)",
    rCurrency = isFR and "(monnaie)" or "(currency)",
    cantBuy   = isFR and "Achat impossible" or "Cannot buy this",
    buy       = isFR and "Acheter" or "Buy",
    cancel    = isFR and "Annuler" or "Cancel",
    max       = "Max",
    buying    = isFR and "Achat... %d / %d" or "Buying... %d / %d",
    wheelTip  = isFR and "Maj+clic sur un objet : acheter en lot" or "Shift-click an item: buy in bulk",
}

-- API selon le client
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemCount = GetItemCount or (C_Item and C_Item.GetItemCount)

-- somme avec les icones or / argent / cuivre, quelle que soit l'API du client
local function MoneyText(copper)
    copper = math.floor(copper or 0)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then return C_CurrencyInfo.GetCoinTextureString(copper) end
    if GetMoneyString then return GetMoneyString(copper) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local icon = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. icon:format("Gold") end
    if s > 0 then parts[#parts + 1] = s .. icon:format("Silver") end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. icon:format("Copper") end
    return table.concat(parts, " ")
end

local db
local origWidth, origHeight
local origPoints = {}       -- ancrages d'origine des MerchantItem1..12
local hgap, vgap            -- espacements mesures sur la mise en page Blizzard
local page, lastNumPages = 1, 1
local toggleButton, dropButton, nav, backdrop, toolbar, searchBox, filterButton, sortButton, emptyText
local hiddenArt = {}
local OpenBulk               -- defini plus bas

local function IsExpanded() return db.perPage and db.perPage > 10 end
local function Layout() return LAYOUTS[db.perPage] or LAYOUTS[30] end
local function OnMerchantTab() return (MerchantFrame.selectedTab or 1) == 1 end

-- ----------------------------------------------------------------------------
-- Infos objets
-- ----------------------------------------------------------------------------
local function ItemInfo(index)
    local t
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if info then
            t = { name = info.name, texture = info.texture, price = info.price, stackCount = info.stackCount,
                numAvailable = info.numAvailable, isPurchasable = info.isPurchasable, isUsable = info.isUsable,
                extendedCost = info.hasExtendedCost }
        end
    else
        local name, texture, price, stackCount, numAvailable, isPurchasable, isUsable, extendedCost = GetMerchantItemInfo(index)
        if name or texture then
            t = { name = name, texture = texture, price = price, stackCount = stackCount, numAvailable = numAvailable,
                isPurchasable = isPurchasable, isUsable = isUsable, extendedCost = extendedCost }
        end
    end
    if t then
        t.index = index
        t.price = t.price or 0
        t.stackCount = math.max(1, t.stackCount or 1)
    end
    return t
end

local function ItemID(index)
    local id = GetMerchantItemID and GetMerchantItemID(index)
    if not id then
        local link = GetMerchantItemLink(index)
        id = link and tonumber(link:match("item:(%d+)"))
    end
    return id
end

local function Quality(index)
    local id = ItemID(index)
    if not id then return 0 end
    if C_Item and C_Item.GetItemQualityByID then return C_Item.GetItemQualityByID(id) or 0 end
    return select(3, GetItemInfo(id)) or 0
end

-- "Deja connu" (recettes, montures, mascottes...) : lu dans l'infobulle, garde en cache
local knownCache = {}
local scanTip
local function IsKnown(index)
    local link = GetMerchantItemLink(index)
    if not link then return false end
    if knownCache[link] ~= nil then return knownCache[link] end
    local known, lines = false, 0
    if C_TooltipInfo and C_TooltipInfo.GetMerchantItem then
        local data = C_TooltipInfo.GetMerchantItem(index)
        if data and data.lines then
            lines = #data.lines
            for _, l in ipairs(data.lines) do
                if l.leftText == ITEM_SPELL_KNOWN then known = true break end
            end
        end
    else
        if not scanTip then
            scanTip = CreateFrame("GameTooltip", "VendorExpandForeverScanTip", nil, "GameTooltipTemplate")
        end
        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
        scanTip:ClearLines()
        scanTip:SetMerchantItem(index)
        lines = scanTip:NumLines()
        for i = 2, lines do
            local fs = _G["VendorExpandForeverScanTipTextLeft" .. i]
            if fs and fs:GetText() == ITEM_SPELL_KNOWN then known = true break end
        end
        scanTip:Hide()
    end
    if known or lines > 1 then knownCache[link] = known end   -- pas de cache si l'infobulle n'est pas chargee
    return known
end

-- quantite maximale achetable (en unites) et ce qui la limite : argent, monnaie, stock
local UNLIMITED = 99999
local function MaxBuy(index, info)
    local stack = info.stackCount
    local best, reason = math.huge, nil
    local function cap(n, why) if n < best then best, reason = n, why end end
    if info.price > 0 then cap(math.floor(GetMoney() / info.price) * stack, L.rMoney) end
    if info.extendedCost and GetMerchantItemCostInfo and GetMerchantItemCostItem then
        for c = 1, GetMerchantItemCostInfo(index) or 0 do
            local _, value, link = GetMerchantItemCostItem(index, c)
            if value and value > 0 and link then
                local owned
                if link:find("item:") then
                    owned = GetItemCount(link)
                elseif C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfoFromLink then
                    local ci = C_CurrencyInfo.GetCurrencyInfoFromLink(link)
                    owned = ci and ci.quantity
                end
                if owned then cap(math.floor(owned / value) * stack, L.rCurrency) end
            end
        end
    end
    if info.numAvailable and info.numAvailable >= 0 then cap(info.numAvailable * stack, L.rStock) end
    -- comme TSM : pas de limite liee aux sacs ni a la taille d'une pile
    if best == math.huge then best = math.floor(UNLIMITED / stack) * stack end
    return math.max(0, best), reason
end

-- ----------------------------------------------------------------------------
-- Vue : recherche + filtres + tri appliques a la liste du marchand
-- ----------------------------------------------------------------------------
local view = {}

local function ActiveFilters()
    local n = 0
    for _, on in pairs(db.filters) do if on then n = n + 1 end end
    return n
end

local function SearchText()
    return searchBox and (searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
end

local function ViewActive()
    return SearchText() ~= "" or ActiveFilters() > 0 or db.sort ~= "default"
end

local SORTS = {
    name = function(a, b)
        if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
        return a.index < b.index
    end,
    priceLo = function(a, b)
        if a.price ~= b.price then return a.price < b.price end
        return a.index < b.index
    end,
    priceHi = function(a, b)
        if a.price ~= b.price then return a.price > b.price end
        return a.index < b.index
    end,
    quality = function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
        return a.index < b.index
    end,
}

local function BuildView()
    wipe(view)
    local num = GetMerchantNumItems()
    local q = SearchText()
    local f = db.filters
    for index = 1, num do
        local info = ItemInfo(index)
        if info then
            local ok = true
            if q ~= "" then ok = info.name ~= nil and info.name:lower():find(q, 1, true) ~= nil end
            if ok and f.usable then ok = info.isUsable ~= false and info.isPurchasable ~= false end
            if ok and f.afford then ok = MaxBuy(index, info) >= info.stackCount end
            if ok and f.known then ok = not IsKnown(index) end
            if ok then
                if db.sort == "quality" then info.quality = Quality(index) end
                view[#view + 1] = info
            end
        end
    end
    local cmp = SORTS[db.sort]
    if cmp and #view > 1 then table.sort(view, cmp) end
    return num
end

-- ----------------------------------------------------------------------------
-- Cases d'objets
-- ----------------------------------------------------------------------------
local function HookBuyButton(btn)
    if not btn or btn.vefHooked then return end
    btn.vefHooked = true
    local orig = btn:GetScript("OnClick")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Maj + clic gauche ou droit : fenetre d'achat en lot (remplace la petite fenetre de pile de Blizzard)
    btn:SetScript("OnClick", function(self, button, ...)
        if (button == "LeftButton" or button == "RightButton") and IsShiftKeyDown() and not IsControlKeyDown() and not IsAltKeyDown()
            and OnMerchantTab() and not (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) then
            OpenBulk(self:GetID())
            return
        end
        if orig then return orig(self, button, ...) end
    end)
end

local function GetItem(i)
    local f = _G["MerchantItem" .. i]
    if not f then
        f = CreateFrame("Frame", "MerchantItem" .. i, MerchantFrame, "MerchantItemTemplate")
        f:SetID(i)
        f:Hide()
    end
    HookBuyButton(_G["MerchantItem" .. i .. "ItemButton"])
    return f
end

local function SavePoints()
    for i = 1, BUYBACK_COUNT do
        local f = _G["MerchantItem" .. i]
        if f then
            local pts = {}
            for p = 1, f:GetNumPoints() do pts[p] = { f:GetPoint(p) } end
            origPoints[i] = pts
        end
    end
end

local function RestorePoints()
    for i, pts in pairs(origPoints) do
        local f = _G["MerchantItem" .. i]
        f:ClearAllPoints()
        for _, pt in ipairs(pts) do f:SetPoint(unpack(pt)) end
    end
end

local function HideExtras(from)
    for i = from, MAX_ITEMS do
        local f = _G["MerchantItem" .. i]
        if f then f:Hide() end
    end
end

local function SetColor(merchantButton, itemButton, r, g, b)
    if SetItemButtonNameFrameVertexColor then SetItemButtonNameFrameVertexColor(merchantButton, r, g, b) end
    if SetItemButtonSlotVertexColor then SetItemButtonSlotVertexColor(merchantButton, r, g, b) end
    SetItemButtonTextureVertexColor(itemButton, r, g, b)
    SetItemButtonNormalTextureVertexColor(itemButton, r, g, b)
end

-- Remplit la case i avec un objet du marchand (meme rendu que Blizzard)
local function FillItem(i, info)
    local f = GetItem(i)
    local index = info.index
    local name = f:GetName()
    local itemButton = _G[name .. "ItemButton"]
    local moneyFrame = _G[name .. "MoneyFrame"]
    local altFrame = _G[name .. "AltCurrencyFrame"]

    _G[name .. "Name"]:SetText(info.name)
    SetItemButtonCount(itemButton, info.stackCount)
    if SetItemButtonStock then SetItemButtonStock(itemButton, info.numAvailable) end
    SetItemButtonTexture(itemButton, info.texture)
    local itemID = GetMerchantItemID and GetMerchantItemID(index)
    if SetItemButtonQuality and itemID and C_Item and C_Item.GetItemQualityByID then
        SetItemButtonQuality(itemButton, C_Item.GetItemQualityByID(itemID), itemID)
    end

    if info.extendedCost and info.price <= 0 then
        moneyFrame:Hide()
        if MerchantFrame_UpdateAltCurrency then MerchantFrame_UpdateAltCurrency(index, i) end
        if altFrame then altFrame:Show() end
    else
        if altFrame then altFrame:Hide() end
        MoneyFrame_Update(moneyFrame:GetName(), info.price)
        moneyFrame:Show()
        if info.extendedCost and MerchantFrame_UpdateAltCurrency then
            MerchantFrame_UpdateAltCurrency(index, i)
            if altFrame then
                altFrame:ClearAllPoints()
                altFrame:SetPoint("LEFT", moneyFrame, "RIGHT", -14, 0)
                altFrame:Show()
            end
        end
    end

    itemButton.hasItem = true
    itemButton:SetID(index)
    itemButton.link = GetMerchantItemLink(index)
    itemButton.texture = info.texture
    itemButton.price = info.price
    itemButton.extendedCost = info.extendedCost
    itemButton.name = info.name
    itemButton.numInStock = info.numAvailable
    itemButton:Show()

    if info.numAvailable == 0 then
        SetColor(f, itemButton, 0.5, 0.5, 0.5)
    elseif not info.isPurchasable or not info.isUsable then
        SetColor(f, itemButton, 0.9, 0, 0)
    else
        SetColor(f, itemButton, 1, 1, 1)
    end
    f:Show()
end

-- ----------------------------------------------------------------------------
-- Elements du bas
-- ----------------------------------------------------------------------------
local function IsMerchantItem(f)
    local n = f:GetName()
    return n and n:match("^MerchantItem%d+$")
end

-- Fantomes : copie invisible de la fenetre normale (et de ses 12 cases) collee en bas
-- de la vraie fenetre. Les elements du bas qui s'ancrent sur une case ou sur le haut
-- de la fenetre sont rebranches sur ces fantomes : ils gardent leur place d'origine,
-- quel que soit l'ancrage que Blizzard (ou un autre addon) leur redonne ensuite.
local ghostL, ghostR
local ghostItems = {}
local ghostOf, realOf = {}, {}

local function CreateGhosts()
    ghostL = CreateFrame("Frame", nil, MerchantFrame)
    ghostL:SetSize(origWidth, origHeight)
    ghostL:SetPoint("BOTTOMLEFT")
    ghostR = CreateFrame("Frame", nil, MerchantFrame)
    ghostR:SetSize(origWidth, origHeight)
    ghostR:SetPoint("BOTTOMRIGHT")
    realOf[ghostL], realOf[ghostR] = MerchantFrame, MerchantFrame

    local w, h = MerchantItem1:GetSize()
    for i = 1, BUYBACK_COUNT do
        local g = CreateFrame("Frame", nil, MerchantFrame)
        g:SetSize(w, h)
        ghostItems[i] = g
        local item = _G["MerchantItem" .. i]
        if item then ghostOf[item], realOf[g] = g, item end
    end
    for i, pts in pairs(origPoints) do
        for _, pt in ipairs(pts) do
            local point, rel, relPoint, x, y = unpack(pt)
            if rel == MerchantFrame then
                rel = relPoint:find("RIGHT") and ghostR or ghostL
            else
                rel = ghostOf[rel] or rel
            end
            ghostItems[i]:SetPoint(point, rel, relPoint, x, y)
        end
    end
end

local function IsOurs(c)
    return c == toggleButton or c == dropButton or c == nav or c == backdrop or c == toolbar
        or c == ghostL or c == ghostR or realOf[c] or c == MerchantFrame.NineSlice or IsMerchantItem(c)
end

-- Ancrage sur le haut de la fenetre mais place dans sa moitie basse ?
local function InBottomArea(relPoint, y)
    if relPoint:find("BOTTOM") then return false end
    if relPoint:find("TOP") then return (y or 0) < -origHeight * 0.55 end
    return (y or 0) < -origHeight * 0.05
end

-- on = rebranche sur les fantomes ; off = rend les ancrages d'origine
local function Relocate(on)
    if not ghostL then return end
    for _, c in ipairs({ MerchantFrame:GetChildren() }) do
        if not IsOurs(c) and c:GetNumPoints() > 0 then
            local todo
            for p = 1, c:GetNumPoints() do
                local point, rel, relPoint, x, y = c:GetPoint(p)
                local target
                if on then
                    if ghostOf[rel] then
                        target = ghostOf[rel]
                    elseif rel == MerchantFrame and InBottomArea(relPoint, y) then
                        target = relPoint:find("RIGHT") and ghostR or ghostL
                    end
                elseif rel and realOf[rel] then
                    target = realOf[rel]
                end
                if target then
                    todo = todo or {}
                    todo[#todo + 1] = { point, target, relPoint, x, y }
                end
            end
            if todo then
                for _, pt in ipairs(todo) do c:SetPoint(unpack(pt)) end
            end
        end
    end
end

-- Mesure les espacements reels entre les cases (mise en page normale, fenetre visible)
local measured
local function Measure()
    measured = true
    if hgap then return end
    local a, b, c = MerchantItem1, MerchantItem2, MerchantItem3
    if a and b and c and a:GetRight() and b:GetLeft() and c:GetTop() then
        hgap = b:GetLeft() - a:GetRight()
        vgap = a:GetBottom() - c:GetTop()
        if hgap < 0 or hgap > 60 then hgap = nil end
        if vgap and (vgap < 0 or vgap > 40) then vgap = nil end
    end
end

-- ----------------------------------------------------------------------------
-- Fond de secours (ancien cadre en textures fixes uniquement)
-- ----------------------------------------------------------------------------
local function SetExpandedArt(expanded)
    if MerchantFrame.NineSlice then return end
    if expanded then
        if not backdrop then
            backdrop = CreateFrame("Frame", nil, MerchantFrame, "BackdropTemplate")
            backdrop:SetFrameStrata("BACKGROUND")
            backdrop:SetPoint("TOPLEFT", 10, -12)
            backdrop:SetPoint("BOTTOMRIGHT", -2, 60)
            backdrop:SetBackdrop({
                bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        end
        if #hiddenArt == 0 then
            for _, r in ipairs({ MerchantFrame:GetRegions() }) do
                if r:GetObjectType() == "Texture" and r:IsShown() and r ~= MerchantFramePortrait then
                    local layer = r:GetDrawLayer()
                    if layer == "BACKGROUND" or layer == "BORDER" or layer == "ARTWORK" then
                        r:Hide()
                        hiddenArt[#hiddenArt + 1] = r
                    end
                end
            end
        end
        backdrop:Show()
    else
        for _, r in ipairs(hiddenArt) do r:Show() end
        wipe(hiddenArt)
        if backdrop then backdrop:Hide() end
    end
end

-- ----------------------------------------------------------------------------
-- Mise en page elargie
-- ----------------------------------------------------------------------------
local function LayoutGrid(count, cols)
    local h, v = hgap or 12, vgap or 8
    for i = 2, count do
        local f = GetItem(i)
        f:ClearAllPoints()
        if (i - 1) % cols == 0 then
            f:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - cols)], "BOTTOMLEFT", 0, -v)
        else
            f:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 1)], "TOPRIGHT", h, 0)
        end
    end
end

local function ApplySize()
    local cols, rows = unpack(Layout())
    local w, h = MerchantItem1:GetWidth(), MerchantItem1:GetHeight()
    MerchantFrame:SetWidth(origWidth + (cols - NORMAL_COLS) * (w + (hgap or 12)))
    MerchantFrame:SetHeight(origHeight + (rows - NORMAL_ROWS) * (h + (vgap or 8)))
end

local function SetBlizzardPaging(shown)
    for _, f in ipairs({ MerchantPrevPageButton, MerchantNextPageButton, MerchantPageText }) do
        if f then f:SetAlpha(shown and 1 or 0); if f.EnableMouse then f:EnableMouse(shown) end end
    end
end

local function UpdateNav(numPages)
    if numPages > 1 then
        nav.text:SetFormattedText(L.page, page, numPages)
        nav.prev:SetEnabled(page > 1)
        nav.next:SetEnabled(page < numPages)
        nav:Show()
    else
        nav:Hide()
    end
end

local function ShowToolbar(shown)
    toolbar:SetShown(shown)
end

local function OnMerchantUpdate()
    if not IsExpanded() then
        ShowToolbar(false)
        emptyText:Hide()
        return
    end
    local cols = Layout()[1]
    local perPage = db.perPage
    local num = BuildView()
    local numPages = math.max(1, math.ceil(#view / perPage))
    if page > numPages then page = numPages end
    lastNumPages = numPages

    ApplySize()
    LayoutGrid(perPage, cols)
    Relocate(true)
    SetBlizzardPaging(false)
    ShowToolbar(true)

    for i = 1, perPage do
        local info = view[(page - 1) * perPage + i]
        if info then FillItem(i, info) else GetItem(i):Hide() end
    end
    HideExtras(perPage + 1)
    UpdateNav(numPages)

    searchBox.count:SetText(ViewActive() and (#view .. " / " .. num) or "")
    emptyText:SetShown(#view == 0 and num > 0)
end

local function OnBuybackUpdate()
    ShowToolbar(false)
    emptyText:Hide()
    if not IsExpanded() then return end
    ApplySize()
    LayoutGrid(BUYBACK_COUNT, Layout()[1])
    Relocate(true)
    HideExtras(BUYBACK_COUNT + 1)
    nav:Hide()
end

local function Refresh()
    page = 1
    if MerchantFrame:IsShown() then MerchantFrame_Update() end
end

-- ----------------------------------------------------------------------------
-- Changement de taille
-- ----------------------------------------------------------------------------
local function UpdateControls()
    local tex = IsExpanded() and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage"
    toggleButton:SetNormalTexture(tex .. "-Up")
    toggleButton:SetPushedTexture(tex .. "-Down")
    dropButton:Refresh()
end

local function Apply(animate)
    if IsExpanded() then
        for i = 1, db.perPage do GetItem(i) end
        SetExpandedArt(true)
    else
        MerchantFrame:SetWidth(origWidth)
        MerchantFrame:SetHeight(origHeight)
        RestorePoints()
        Relocate(false)
        HideExtras(BUYBACK_COUNT + 1)
        SetBlizzardPaging(true)
        SetExpandedArt(false)
        nav:Hide()
        ShowToolbar(false)
        emptyText:Hide()
    end
    UpdateControls(animate)
    if MerchantFrame:IsShown() then MerchantFrame_Update() end
end

local function SetPerPage(n)
    if not IsExpanded() then Measure() end   -- mesures prises en mode normal
    if n > 10 then db.lastSize = n end
    db.perPage = n
    page = 1
    Apply(true)
end

local function Toggle()
    SetPerPage(IsExpanded() and 10 or (db.lastSize or 30))
    if GameTooltip:IsOwned(toggleButton) then
        GameTooltip:SetText(IsExpanded() and L.collapse or L.expand)
    end
end

-- ----------------------------------------------------------------------------
-- Controles : fleche, nombre d'objets, barre d'outils, pagination
-- ----------------------------------------------------------------------------
local function Tooltip(frame, text, sub)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(type(text) == "function" and text() or text)
        if sub then GameTooltip:AddLine(sub, 0.75, 0.75, 0.75) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
end

local TOOLTIP_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- un seul menu ouvert a la fois
local openMenu
local function ShowMenu(m)
    if openMenu and openMenu ~= m then openMenu:Hide() end
    if m:IsShown() then m:Hide() else m:Show() end
end

-- cadre de menu Blizzard (bordure de tooltip) sous `owner`
local function CreateMenu(owner, width, height)
    local m = CreateFrame("Frame", nil, owner, "BackdropTemplate")
    m:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    m:SetSize(width, height)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetBackdrop(TOOLTIP_BACKDROP)
    m:SetBackdropColor(0, 0, 0, 0.95)
    m:EnableMouse(true)
    m:Hide()
    m:SetScript("OnShow", function(self) openMenu = self; if self.onOpen then self.onOpen() end end)
    m:SetScript("OnHide", function(self) if openMenu == self then openMenu = nil end end)
    return m
end

-- liste deroulante facon Blizzard : options = { {valeur, texte du bouton, texte du menu}, ... }
local function CreateDropdown(parent, width, menuWidth, options, getValue, onSelect)
    local d = CreateFrame("Button", nil, parent, "BackdropTemplate")
    d:SetSize(width, 22)
    d:SetBackdrop(TOOLTIP_BACKDROP)
    d:SetBackdropColor(0, 0, 0, 0.8)
    d:SetBackdropBorderColor(0.6, 0.6, 0.6)
    d.text = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.text:SetPoint("LEFT", 8, 0)
    d.text:SetPoint("RIGHT", -18, 0)
    d.text:SetJustifyH("LEFT")
    d.text:SetWordWrap(false)
    local arrow = d:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(18, 18)
    arrow:SetPoint("RIGHT", 0, 0)
    d:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    local m = CreateMenu(d, menuWidth, 12 + #options * 18)
    local rows = {}
    for idx, o in ipairs(options) do
        local r = CreateFrame("Button", nil, m)
        r:SetSize(menuWidth - 8, 18)
        r:SetPoint("TOP", 0, -6 - (idx - 1) * 18)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 8, 0)
        r.text:SetText(o[3])
        r:SetScript("OnClick", function()
            m:Hide()
            onSelect(o[1])
            d:Refresh()
        end)
        rows[idx] = r
    end
    m.onOpen = function()
        local v = getValue()
        for idx, r in ipairs(rows) do
            local on = options[idx][1] == v
            r.text:SetTextColor(1, on and 0.82 or 1, on and 0 or 1)
        end
    end
    d:SetScript("OnClick", function() ShowMenu(m) end)
    function d:Refresh()
        local v = getValue()
        for _, o in ipairs(options) do
            if o[1] == v then self.text:SetText(o[2]) end
        end
    end
    d:Refresh()
    return d
end

local function UpdateFilterLabel()
    local n = ActiveFilters()
    filterButton:SetText(n > 0 and (L.filters .. " (" .. n .. ")") or L.filters)
    local fs = filterButton:GetFontString()
    if fs then
        if n > 0 then fs:SetTextColor(1, 0.82, 0) else fs:SetTextColor(1, 1, 1) end
    end
end

-- champ de recherche Blizzard (loupe + croix) ; repli sur le champ de saisie simple
local function CreateSearchBox(parent, width)
    local ok, e = pcall(CreateFrame, "EditBox", "VendorExpandForeverSearch", parent, "SearchBoxTemplate")
    if ok and e then
        if e.Instructions then e.Instructions:SetText(L.search) end
        e.countInset = 22
    else
        e = CreateFrame("EditBox", "VendorExpandForeverSearch", parent, "InputBoxTemplate")
        e:SetAutoFocus(false)
        local hint = e:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("LEFT", 2, 0)
        hint:SetText(L.search)
        local function refresh(self) hint:SetShown(self:GetText() == "" and not self:HasFocus()) end
        e:HookScript("OnTextChanged", refresh)
        e:HookScript("OnEditFocusGained", refresh)
        e:HookScript("OnEditFocusLost", refresh)
        e:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
        e.countInset = 4
    end
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e.count = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    e.count:SetPoint("RIGHT", -e.countInset, 0)
    return e
end

local function CreateToolbar(level)
    toolbar = CreateFrame("Frame", nil, MerchantFrame)
    toolbar:SetFrameLevel(level)
    toolbar:SetSize(420, 22)
    toolbar:SetPoint("RIGHT", dropButton, "LEFT", -12, 0)
    toolbar:Hide()

    -- Tri
    local sep = isFR and " : " or ": "
    local sorts = {
        { "default", L.sort .. sep .. L.sDefault, L.sDefault },
        { "name",    L.sort .. sep .. L.sName,    L.sName },
        { "priceLo", L.sort .. sep .. L.sPriceLo, L.sPriceLo },
        { "priceHi", L.sort .. sep .. L.sPriceHi, L.sPriceHi },
        { "quality", L.sort .. sep .. L.sQuality, L.sQuality },
    }
    sortButton = CreateDropdown(toolbar, 124, 124, sorts,
        function() return db.sort end,
        function(v) db.sort = v; Refresh() end)
    sortButton:SetPoint("RIGHT")

    -- Filtres : bouton Blizzard + menu de cases a cocher, qui reste ouvert
    filterButton = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    filterButton:SetSize(96, 22)
    filterButton:SetPoint("RIGHT", sortButton, "LEFT", -6, 0)
    local FILTERS = { { "usable", L.fUsable }, { "afford", L.fAfford }, { "known", L.fKnown } }
    local menu = CreateMenu(filterButton, 210, #FILTERS * 24 + 12)
    local checks = {}
    for i, f in ipairs(FILTERS) do
        local c = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
        c:SetSize(24, 24)
        c:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 24)
        local label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", c, "RIGHT", 2, 0)
        label:SetText(f[2])
        c:SetHitRectInsets(0, -(label:GetStringWidth() + 6), 0, 0)
        c:SetScript("OnClick", function(self)
            db.filters[f[1]] = self:GetChecked() and true or nil
            UpdateFilterLabel()
            Refresh()
        end)
        checks[f[1]] = c
    end
    menu.onOpen = function()
        for key, c in pairs(checks) do c:SetChecked(db.filters[key] and true or false) end
    end
    filterButton:SetScript("OnClick", function() ShowMenu(menu) end)
    UpdateFilterLabel()

    -- Recherche
    searchBox = CreateSearchBox(toolbar, 180)
    searchBox:SetPoint("RIGHT", filterButton, "LEFT", -10, 0)
    searchBox:HookScript("OnTextChanged", function()
        page = 1
        if MerchantFrame:IsShown() then MerchantFrame_Update() end
    end)

    -- message quand rien ne correspond
    emptyText = MerchantFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    emptyText:SetPoint("CENTER", MerchantFrame, "CENTER", 0, 20)
    emptyText:SetText(L.noMatch)
    emptyText:Hide()
end

local function CreateControls()
    local level = MerchantFrame:GetFrameLevel() + 600

    -- Fleche : elargir / revenir a la taille normale
    toggleButton = CreateFrame("Button", "VendorExpandForeverToggle", MerchantFrame)
    toggleButton:SetSize(28, 28)
    toggleButton:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -8, -28)
    toggleButton:SetFrameLevel(level)
    toggleButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    toggleButton:SetScript("OnClick", Toggle)
    Tooltip(toggleButton, function() return IsExpanded() and L.collapse or L.expand end, L.wheelTip)

    -- Nombre d'objets par page
    local sep = isFR and " : " or ": "
    local options = {}
    for _, n in ipairs(SIZES) do options[#options + 1] = { n, L.items .. sep .. n, n .. " " .. L.perPage } end
    dropButton = CreateDropdown(MerchantFrame, 96, 140, options,
        function() return db.perPage or 10 end, SetPerPage)
    dropButton:SetPoint("RIGHT", toggleButton, "LEFT", -4, 0)
    dropButton:SetFrameLevel(level)

    CreateToolbar(level)
    MerchantFrame:HookScript("OnHide", function() if openMenu then openMenu:Hide() end end)

    -- Pagination du mode elargi (sous la grille, a droite des cases du bas)
    nav = CreateFrame("Frame", nil, MerchantFrame)
    nav:SetSize(260, 32)
    nav:SetFrameLevel(level)
    nav:Hide()
    nav.text = nav:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nav.text:SetPoint("CENTER")
    local function PageButton(dir)
        local p = CreateFrame("Button", nil, nav)
        p:SetSize(32, 32)
        local tex = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage"
        p:SetNormalTexture(tex .. "-Up")
        p:SetPushedTexture(tex .. "-Down")
        p:SetDisabledTexture(tex .. "-Disabled")
        p:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        p:SetScript("OnClick", function()
            page = page + dir
            MerchantFrame_Update()
        end)
        return p
    end
    nav.prev = PageButton(-1)
    nav.prev:SetPoint("LEFT")
    nav.next = PageButton(1)
    nav.next:SetPoint("RIGHT")
    nav:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -16, 66)

    UpdateControls()
end


-- ----------------------------------------------------------------------------
-- Molette : page precedente / suivante
-- ----------------------------------------------------------------------------
local function OnWheel(_, delta)
    if not OnMerchantTab() then return end
    if IsExpanded() then
        local to = page - delta
        if to >= 1 and to <= lastNumPages and to ~= page then
            page = to
            MerchantFrame_Update()
        end
    else
        local b = delta > 0 and MerchantPrevPageButton or MerchantNextPageButton
        if b and b:IsShown() and b:IsEnabled() then b:Click() end
    end
end

-- ----------------------------------------------------------------------------
-- Achat en lot (Maj+clic sur un objet)
-- ----------------------------------------------------------------------------
local bulk

local function PanelButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height or 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateBulk()
    local f = CreateFrame("Frame", "VendorExpandForeverBulk", UIParent, "BackdropTemplate")
    f:SetSize(300, 214)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:Hide()
    tinsert(UISpecialFrames, "VendorExpandForeverBulk")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -18)
    f.title:SetText(L.bulkTitle)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- objet
    local icon = CreateFrame("Button", nil, f)
    icon:SetSize(37, 37)
    icon:SetPoint("TOPLEFT", 22, -44)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints()
    local slot = icon:CreateTexture(nil, "OVERLAY")
    slot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    slot:SetPoint("TOPLEFT", -15, 15)
    slot:SetPoint("BOTTOMRIGHT", 15, -15)
    icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetMerchantItem(f.index)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    f.icon = icon

    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
    f.name:SetPoint("RIGHT", -22, 0)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    f.unit = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.unit:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 10, 2)

    -- quantite : - [champ] + Max
    local minus = PanelButton(f, "-", 26, 22, function() f:Step(-1) end)
    minus:SetPoint("TOPLEFT", 22, -96)
    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetSize(70, 20)
    edit:SetPoint("LEFT", minus, "RIGHT", 10, 0)
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    edit:SetJustifyH("CENTER")
    edit:EnableMouseWheel(true)
    edit:SetScript("OnMouseWheel", function(_, d) f:Step(d) end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); f:Buy() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:HookScript("OnTextChanged", function() f:UpdateTotal() end)
    edit:HookScript("OnEditFocusLost", function() f:SetQty(tonumber(edit:GetText()) or 0) end)
    f.edit = edit
    local plus = PanelButton(f, "+", 26, 22, function() f:Step(1) end)
    plus:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    local maxB = PanelButton(f, L.max, 60, 22, function() f:SetQty(f.max) end)
    maxB:SetPoint("LEFT", plus, "RIGHT", 8, 0)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.info:SetPoint("TOPLEFT", minus, "BOTTOMLEFT", 0, -10)
    f.total = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.total:SetPoint("TOPLEFT", f.info, "BOTTOMLEFT", 0, -6)

    f.buy = PanelButton(f, L.buy, 100, 22, function() f:Buy() end)
    f.buy:SetPoint("BOTTOMRIGHT", -20, 18)
    local cancel = PanelButton(f, L.cancel, 90, 22, function() f:Hide() end)
    cancel:SetPoint("RIGHT", f.buy, "LEFT", -6, 0)

    function f:SetQty(n)
        local step = self.info_.stackCount
        n = math.floor((n or 0) / step + 0.5) * step
        n = math.max(math.min(step, self.max), math.min(n, self.max))
        self.edit:SetText(n)
        self:UpdateTotal()
    end

    function f:Step(dir)
        local mult = IsShiftKeyDown() and 10 or 1
        self:SetQty((tonumber(self.edit:GetText()) or 0) + dir * self.info_.stackCount * mult)
    end

    function f:UpdateTotal()
        local info = self.info_
        if not info then return end
        local n = tonumber(self.edit:GetText()) or 0
        if info.price > 0 then
            local cost = math.ceil(info.price * n / info.stackCount)
            self.total:SetText(L.total .. MoneyText(cost))
        else
            self.total:SetText("")
        end
        local ok = not self.buying and self.max >= info.stackCount and n >= info.stackCount and n <= self.max
        self.buy:SetEnabled(ok)
    end

    function f:Load(index)
        local info = ItemInfo(index)
        if not info then return false end
        self.index, self.info_ = index, info
        self.icon.tex:SetTexture(info.texture)
        local q = Quality(index)
        local r, g, b = 1, 1, 1
        local qualityColor = (C_Item and C_Item.GetItemQualityColor) or GetItemQualityColor
        if qualityColor and q then r, g, b = qualityColor(q) end
        self.name:SetText(info.name or "")
        self.name:SetTextColor(r, g, b)
        if info.price > 0 then
            local per = info.stackCount > 1 and (" / " .. info.stackCount) or ""
            self.unit:SetText(L.unit .. MoneyText(info.price) .. per)
        else
            self.unit:SetText(L.altCost)
        end
        local max, reason = MaxBuy(index, info)
        self.max = max
        if max < info.stackCount then
            self.info:SetText(L.cantBuy .. " " .. (reason or ""))
            self.info:SetTextColor(1, 0.3, 0.3)
        else
            self.info:SetText(reason and L.maxInfo:format(max, reason) or "")
            self.info:SetTextColor(0.8, 0.8, 0.8)
        end
        self:SetQty(info.stackCount)
        return true
    end

    function f:Buy()
        if self.buying or not self.buy:IsEnabled() then return end
        local index, info = self.index, self.info_
        local qty = tonumber(self.edit:GetText()) or 0
        local step = info.stackCount
        local per = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(index)) or step
        per = math.max(step, math.floor(per / step) * step)
        local done = 0
        self.buying = true
        self.buy:SetEnabled(false)
        local function stop()
            if self.ticker then self.ticker:Cancel(); self.ticker = nil end
            self.buying = nil
        end
        local function tick()
            if not self.buying then return end
            if not MerchantFrame:IsShown() then stop(); self:Hide() return end
            local n = math.min(per, qty - done)
            BuyMerchantItem(index, n)
            done = done + n
            self.info:SetText(L.buying:format(done, qty))
            if done >= qty then
                stop()
                C_Timer.After(0.3, function() self:Hide() end)
            end
        end
        tick()
        if self.buying then
            if C_Timer.NewTicker then
                self.ticker = C_Timer.NewTicker(0.25, tick)
            else
                local function loop() if self.buying then tick(); C_Timer.After(0.25, loop) end end
                C_Timer.After(0.25, loop)
            end
        end
    end

    -- fermer la fenetre (Echap, croix, marchand ferme) arrete un achat en cours
    f:SetScript("OnHide", function(self)
        if self.ticker then self.ticker:Cancel(); self.ticker = nil end
        self.buying = nil
    end)
    return f
end

OpenBulk = function(index)
    bulk = bulk or CreateBulk()
    if bulk.buying then return end
    if not bulk:Load(index) then return end
    bulk:ClearAllPoints()
    bulk:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 10, -60)
    bulk:Show()
    bulk.edit:SetFocus()
    bulk.edit:HighlightText()
end


-- ----------------------------------------------------------------------------
-- Initialisation
-- ----------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, name)
    if event ~= "ADDON_LOADED" then
        if event == "MERCHANT_SHOW" then wipe(knownCache)
        elseif event == "MERCHANT_CLOSED" then
            if bulk and bulk:IsShown() then bulk:Hide() end
        else
            wipe(knownCache)   -- recette / sort appris
        end
        return
    end
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    for _, ev in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "LEARNED_SPELL_IN_TAB", "NEW_RECIPE_LEARNED" }) do
        pcall(self.RegisterEvent, self, ev)
    end

    VendorExpandForeverDB = VendorExpandForeverDB or {}
    db = VendorExpandForeverDB
    if db.expanded ~= nil then          -- ancienne version
        db.perPage = db.expanded and 30 or 10
        db.expanded = nil
    end
    db.perPage = db.perPage or 10
    db.filters = db.filters or {}
    db.sort = db.sort or "default"

    origWidth, origHeight = MerchantFrame:GetWidth(), MerchantFrame:GetHeight()
    SavePoints()
    for i = 1, BUYBACK_COUNT do GetItem(i) end   -- Maj+clic sur les cases de Blizzard
    CreateControls()
    CreateGhosts()

    hooksecurefunc("MerchantFrame_UpdateMerchantInfo", OnMerchantUpdate)
    hooksecurefunc("MerchantFrame_UpdateBuybackInfo", OnBuybackUpdate)
    -- Blizzard replace les boutons de reparation / vente des camelotes a part
    -- (durabilite, banque de guilde...) : on les recale a chaque fois
    for _, fn in ipairs({ "MerchantFrame_UpdateRepairButtons", "MerchantFrame_UpdateSellAllJunkButton" }) do
        if _G[fn] then
            hooksecurefunc(fn, function()
                if IsExpanded() and MerchantFrame:IsShown() then Relocate(true) end
            end)
        end
    end

    MerchantFrame:EnableMouseWheel(true)
    MerchantFrame:HookScript("OnMouseWheel", OnWheel)

    MerchantFrame:HookScript("OnHide", function()
        searchBox:SetText("")
        searchBox:ClearFocus()
    end)
    MerchantFrame:HookScript("OnShow", function()
        page = 1
        if not measured and IsExpanded() then
            -- Premiere ouverture : mesurer en mode normal, puis elargir
            local wanted = db.perPage
            db.perPage = 10
            Apply()
            C_Timer.After(0, function()
                Measure()
                db.perPage = wanted
                Apply()
            end)
            return
        end
        Apply()
    end)
end)

SLASH_VENDOREXPANDFOREVER1 = "/vef"
SlashCmdList.VENDOREXPANDFOREVER = function(msg)
    if not db then return end
    if msg == "debug" then
        local function nameOf(f)
            if not f then return "nil" end
            if f == ghostL then return "ghostL" elseif f == ghostR then return "ghostR" end
            if realOf[f] then return "ghost:" .. (realOf[f]:GetName() or "?") end
            return f:GetName() or tostring(f)
        end
        local list = { "MerchantRepairAllButton", "MerchantRepairItemButton", "MerchantGuildBankRepairButton",
            "MerchantRepairText", "MerchantBuyBackItem", "MerchantSellAllJunkButton" }
        local frames = {}
        for _, n in ipairs(list) do if _G[n] then frames[#frames + 1] = _G[n] end end
        if MerchantBuyBackItem then
            for _, c in ipairs({ MerchantBuyBackItem:GetChildren() }) do
                if not c:GetName() then frames[#frames + 1] = c end
            end
        end
        print(("|cff33ff99VEF|r perPage=%s frame=%dx%d orig=%dx%d"):format(db.perPage, MerchantFrame:GetWidth(),
            MerchantFrame:GetHeight(), origWidth, origHeight))
        local fl, fb = MerchantFrame:GetLeft() or 0, MerchantFrame:GetBottom() or 0
        for _, f in ipairs(frames) do
            local s = ("%s shown=%s pos=%d,%d"):format(nameOf(f), tostring(f:IsShown()),
                (f:GetLeft() or 0) - fl, (f:GetBottom() or 0) - fb)
            for p = 1, f:GetNumPoints() do
                local point, rel, relPoint, x, y = f:GetPoint(p)
                s = s .. (" | %s>%s:%s %.1f,%.1f"):format(point, nameOf(rel), tostring(relPoint), x or 0, y or 0)
            end
            print(s)
        end
        return
    end
    local n = tonumber(msg)
    if n and LAYOUTS[n] or n == 10 then SetPerPage(n) else Toggle() end
end
