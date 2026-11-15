-- Vendor Expand (Forever)
-- Elargit la fenetre du marchand pour afficher 10 a 50 objets, sans changer son interface.

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
    expand   = isFR and "Elargir la fenetre du marchand" or "Expand merchant window",
    collapse = isFR and "Taille normale" or "Normal size",
    items    = isFR and "Objets" or "Items",
    perPage  = isFR and "Objets par page" or "Items per page",
    page     = MERCHANT_PAGE_NUMBER or "Page %s of %s",
}

local db
local origWidth, origHeight
local origPoints = {}       -- ancrages d'origine des MerchantItem1..12
local hgap, vgap            -- espacements mesures sur la mise en page Blizzard
local page = 1
local toggleButton, dropButton, dropMenu, nav, backdrop
local hiddenArt = {}

local function IsExpanded() return db.perPage and db.perPage > 10 end
local function Layout() return LAYOUTS[db.perPage] or LAYOUTS[30] end

-- ----------------------------------------------------------------------------
-- Cases d'objets
-- ----------------------------------------------------------------------------
local function GetItem(i)
    local f = _G["MerchantItem" .. i]
    if not f then
        f = CreateFrame("Frame", "MerchantItem" .. i, MerchantFrame, "MerchantItemTemplate")
        f:SetID(i)
        f:Hide()
    end
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

-- Remplit une case avec l'objet n° index du marchand (meme rendu que Blizzard)
local function FillItem(i, index)
    local f = GetItem(i)
    local name = f:GetName()
    local itemButton = _G[name .. "ItemButton"]
    local moneyFrame = _G[name .. "MoneyFrame"]
    local altFrame = _G[name .. "AltCurrencyFrame"]

    local itemName, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if info then
            itemName, texture, price, quantity = info.name, info.texture, info.price, info.stackCount
            numAvailable, isPurchasable, isUsable, extendedCost = info.numAvailable, info.isPurchasable, info.isUsable, info.hasExtendedCost
        end
    else
        itemName, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost = GetMerchantItemInfo(index)
    end
    if not itemName and not texture then
        f:Hide()
        return
    end

    _G[name .. "Name"]:SetText(itemName)
    SetItemButtonCount(itemButton, quantity)
    if SetItemButtonStock then SetItemButtonStock(itemButton, numAvailable) end
    SetItemButtonTexture(itemButton, texture)
    local itemID = GetMerchantItemID and GetMerchantItemID(index)
    if SetItemButtonQuality and itemID and C_Item and C_Item.GetItemQualityByID then
        SetItemButtonQuality(itemButton, C_Item.GetItemQualityByID(itemID), itemID)
    end

    if extendedCost and (price or 0) <= 0 then
        moneyFrame:Hide()
        if MerchantFrame_UpdateAltCurrency then MerchantFrame_UpdateAltCurrency(index, i) end
        if altFrame then altFrame:Show() end
    else
        if altFrame then altFrame:Hide() end
        MoneyFrame_Update(moneyFrame:GetName(), price)
        moneyFrame:Show()
        if extendedCost and MerchantFrame_UpdateAltCurrency then
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
    itemButton.texture = texture
    itemButton.price = price
    itemButton.extendedCost = extendedCost
    itemButton.name = itemName
    itemButton.numInStock = numAvailable
    itemButton:Show()

    if numAvailable == 0 then
        SetColor(f, itemButton, 0.5, 0.5, 0.5)
    elseif not isPurchasable or not isUsable then
        SetColor(f, itemButton, 0.9, 0, 0)
    else
        SetColor(f, itemButton, 1, 1, 1)
    end
    f:Show()
end

-- ----------------------------------------------------------------------------
-- Mesures et elements du bas
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
    return c == toggleButton or c == dropButton or c == dropMenu or c == nav or c == backdrop
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

local function OnMerchantUpdate()
    if not IsExpanded() then return end
    local cols = Layout()[1]
    local perPage = db.perPage
    local num = GetMerchantNumItems()
    local numPages = math.max(1, math.ceil(num / perPage))
    if page > numPages then page = numPages end

    ApplySize()
    LayoutGrid(perPage, cols)
    Relocate(true)
    SetBlizzardPaging(false)

    for i = 1, perPage do
        local index = (page - 1) * perPage + i
        if index <= num then FillItem(i, index) else GetItem(i):Hide() end
    end
    HideExtras(perPage + 1)
    UpdateNav(numPages)
end

local function OnBuybackUpdate()
    if not IsExpanded() then return end
    ApplySize()
    LayoutGrid(BUYBACK_COUNT, Layout()[1])
    Relocate(true)
    HideExtras(BUYBACK_COUNT + 1)
    nav:Hide()
end

-- ----------------------------------------------------------------------------
-- Changement de taille
-- ----------------------------------------------------------------------------
local function UpdateControls()
    local tex = IsExpanded() and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage"
    toggleButton:SetNormalTexture(tex .. "-Up")
    toggleButton:SetPushedTexture(tex .. "-Down")
    dropButton.text:SetText(L.items .. ": " .. (db.perPage or 10))
end

local function Apply()
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
    end
    UpdateControls()
    if MerchantFrame:IsShown() then MerchantFrame_Update() end
end

local function SetPerPage(n)
    if not IsExpanded() then Measure() end   -- mesures prises en mode normal
    if n > 10 then db.lastSize = n end
    db.perPage = n
    page = 1
    Apply()
end

local function Toggle()
    SetPerPage(IsExpanded() and 10 or (db.lastSize or 30))
    if GameTooltip:IsOwned(toggleButton) then
        GameTooltip:SetText(IsExpanded() and L.collapse or L.expand)
    end
end

-- ----------------------------------------------------------------------------
-- Controles : fleche, menu deroulant, pagination
-- ----------------------------------------------------------------------------
local function CreateControls()
    local level = MerchantFrame:GetFrameLevel() + 600

    -- Fleche
    local b = CreateFrame("Button", "VendorExpandForeverToggle", MerchantFrame)
    b:SetSize(28, 28)
    b:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -8, -28)
    b:SetFrameLevel(level)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", Toggle)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(IsExpanded() and L.collapse or L.expand)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    toggleButton = b

    -- Menu deroulant (fait maison : pas de UIDropDownMenu sur Forever)
    local d = CreateFrame("Button", "VendorExpandForeverDropDown", MerchantFrame, "BackdropTemplate")
    d:SetSize(96, 22)
    d:SetPoint("RIGHT", b, "LEFT", -4, 0)
    d:SetFrameLevel(level)
    d:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    d:SetBackdropColor(0, 0, 0, 0.8)
    d:SetBackdropBorderColor(0.6, 0.6, 0.6)
    d.text = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.text:SetPoint("LEFT", 8, 0)
    local arrow = d:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(18, 18)
    arrow:SetPoint("RIGHT", 0, 0)
    d:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    dropButton = d

    local m = CreateFrame("Frame", nil, d, "BackdropTemplate")
    m:SetPoint("TOPRIGHT", d, "BOTTOMRIGHT", 0, -2)
    m:SetSize(96, 12 + #SIZES * 18)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    m:SetBackdropColor(0, 0, 0, 0.95)
    m:Hide()
    for idx, n in ipairs(SIZES) do
        local o = CreateFrame("Button", nil, m)
        o:SetSize(88, 18)
        o:SetPoint("TOP", 0, -6 - (idx - 1) * 18)
        o:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        o.text = o:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        o.text:SetPoint("LEFT", 8, 0)
        o.text:SetText(n)
        o:SetScript("OnClick", function()
            m:Hide()
            SetPerPage(n)
        end)
        o:SetScript("OnShow", function(self)
            local cur = db.perPage or 10
            self.text:SetTextColor(1, cur == n and 0.82 or 1, cur == n and 0 or 1)
        end)
    end
    dropMenu = m
    d:SetScript("OnClick", function() m:SetShown(not m:IsShown()) end)
    d:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.perPage)
        GameTooltip:Show()
    end)
    d:SetScript("OnLeave", GameTooltip_Hide)
    MerchantFrame:HookScript("OnHide", function() m:Hide() end)

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

    UpdateControls()
end

local function PlaceNav()
    -- en bas a droite, juste au-dessus de la barre d'argent
    nav:ClearAllPoints()
    nav:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -16, 66)
end

-- ----------------------------------------------------------------------------
-- Initialisation
-- ----------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    VendorExpandForeverDB = VendorExpandForeverDB or {}
    db = VendorExpandForeverDB
    if db.expanded ~= nil then          -- ancienne version
        db.perPage = db.expanded and 30 or 10
        db.expanded = nil
    end
    db.perPage = db.perPage or 10

    origWidth, origHeight = MerchantFrame:GetWidth(), MerchantFrame:GetHeight()
    SavePoints()
    CreateControls()
    PlaceNav()
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
