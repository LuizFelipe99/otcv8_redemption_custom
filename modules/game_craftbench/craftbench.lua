local CRAFTBENCH_OPCODE = 13

local RARITY_BORDER_COLORS = {
    common    = "#9d9d9d",
    uncommon  = "#1eaa31",
    rare      = "#3656c4",
    epic      = "#a335ee",
    legendary = "#ff8000",
}

local RESOURCE_ITEM_SLOTS = {
    { widgetId = "goldenRubyNv1",    clientId = 60483 },
    { widgetId = "goldenRubyNv2",    clientId = 60490 },
    { widgetId = "goldenRubyNv3",    clientId = 60497 },
    { widgetId = "goldenRubyNv4",    clientId = 63401 },
    { widgetId = "platinumRubyNv1",  clientId = 60482 },
    { widgetId = "platinumRubyNv2",  clientId = 60489 },
    { widgetId = "platinumRubyNv3",  clientId = 60496 },
    { widgetId = "platinumRubyNv4",  clientId = 63400 },
}

local GOLD_MATERIAL_CLIENT_IDS = {
    [60483] = true,
    [60490] = true,
    [60497] = true,
    [63401] = true,
}

local PLATINUM_MATERIAL_CLIENT_IDS = {
    [60482] = true,
    [60489] = true,
    [60496] = true,
    [63400] = true,
}

local CLASSIFICATION_FILTER_OPTIONS = {
    { label = "All",     value = "all" },
    { label = "None",    value = "none" },
    { label = "Class 1", value = 1 },
    { label = "Class 2", value = 2 },
    { label = "Class 3", value = 3 },
    { label = "Class 4", value = 4 },
    { label = "Class 5", value = 5 },
}

local VOCATION_FILTER_OPTIONS = {
    { label = "All",      value = "all" },
    { label = "Knight",   value = "knight" },
    { label = "Paladin",  value = "paladin" },
    { label = "Druid",    value = "druid" },
    { label = "Sorcerer", value = "sorcerer" },
    { label = "Monk",     value = "monk" },
    { label = "Attribute Gem",     value = "atribute_gem" },
}

local craftBenchWindow
local activeTabName = "craft"

local tabs = {
    craft = {
        name           = "craft",
        panelId        = "craftTab",
        buttonId       = "craftTabButton",
        recipes        = {},
        filteredRecipes = {},
        searchText     = "",
        selectedIndex  = 0,
        categoryFilterField   = "vocation",
        categoryFilterOptions = VOCATION_FILTER_OPTIONS,
        categoryFilter = "all",
        materialFilters = { gold = false, platinum = false },
        ownedOnly      = false,
    },
    desmanche = {
        name           = "desmanche",
        panelId        = "desmancheTab",
        buttonId       = "desmancheTabButton",
        recipes        = {},
        filteredRecipes = {},
        searchText     = "",
        selectedIndex  = 0,
        categoryFilterField   = "classification",
        categoryFilterOptions = CLASSIFICATION_FILTER_OPTIONS,
        categoryFilter = "all",
        materialFilters = { gold = false, platinum = false },
        ownedOnly      = false,
    },
    fusao = {
        name           = "fusao",
        panelId        = "fusaoTab",
        buttonId       = "fusaoTabButton",
        recipes        = {},
        filteredRecipes = {},
        searchText     = "",
        selectedIndex  = 0,
        categoryFilterField   = nil,
        categoryFilterOptions = nil,
        categoryFilter = "all",
        materialFilters = { gold = false, platinum = false },
        ownedOnly      = false,
    },
}

local function getTabPanel(tab)
    return craftBenchWindow[tab.panelId]
end

local function getRarityColor(rarity)
    return RARITY_BORDER_COLORS[rarity or "common"] or RARITY_BORDER_COLORS.common
end

local function formatGoldCost(amount)
    local formatted = tostring(amount)
    local withSeparators = formatted:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return withSeparators:gsub("^,", "")
end

local function applyResourceBar(resources)
    if not resources then
        return
    end

    local resourceBar = craftBenchWindow.resourceBar

    resourceBar.goldSlot.icon:setVisible(true)
    resourceBar.goldSlot.icon:setItemId(3031)
    resourceBar.goldSlot.amount:setText(formatGoldCost(resources.gold or 0))

    local itemAmounts = resources.items or {}

    for _, slot in ipairs(RESOURCE_ITEM_SLOTS) do
        local slotWidget = resourceBar[slot.widgetId]
        local amount = itemAmounts[tostring(slot.clientId)] or 0

        slotWidget.icon:setVisible(true)
        slotWidget.icon:setItemId(slot.clientId)
        slotWidget.amount:setText(tostring(amount))
    end
end

local STATUS_MESSAGE_DURATION = 4000

local function showStatusMessage(success, message)
    if not message or message == "" then
        return
    end

    local statusBanner = craftBenchWindow.statusBanner

    statusBanner:setText(message)
    statusBanner:setColor(success and "#4caf50" or "#e05656")
    statusBanner:setVisible(true)

    scheduleEvent(function()
        if statusBanner then
            statusBanner:setVisible(false)
        end
    end, STATUS_MESSAGE_DURATION)
end

local function recipeMatchesSearch(recipe, query)
    if query == "" then
        return true
    end

    return recipe.resultName:lower():find(query, 1, true) ~= nil
end

local function recipeMatchesCategory(recipe, tab)
    local filterValue = tab.categoryFilter

    if not tab.categoryFilterField then
        return true
    end

    if filterValue == "all" then
        return true
    end

    if tab.categoryFilterField == "classification" and filterValue == "none" then
        return (recipe.classification or 0) == 0
    end

    return recipe[tab.categoryFilterField] == filterValue
end

local function recipeHasIngredientInSet(recipe, materialIdSet)
    for _, ingredient in ipairs(recipe.ingredients or {}) do
        if materialIdSet[ingredient.clientId] then
            return true
        end
    end

    return false
end

local function recipeMatchesMaterial(recipe, tab)
    local materialFilters = tab.materialFilters
    local hasActiveMaterialFilter = materialFilters.gold or materialFilters.platinum

    if not hasActiveMaterialFilter then
        return true
    end

    local matchesGold = materialFilters.gold and recipeHasIngredientInSet(recipe, GOLD_MATERIAL_CLIENT_IDS)
    local matchesPlatinum = materialFilters.platinum and recipeHasIngredientInSet(recipe, PLATINUM_MATERIAL_CLIENT_IDS)

    return matchesGold or matchesPlatinum
end

local function recipeMatchesOwnedFilter(recipe, tab)
    if not tab.ownedOnly then
        return true
    end

    return recipe.hasRequiredItems == true
end

local function buildFilteredRecipes(tab)
    local query = tab.searchText:lower()

    tab.filteredRecipes = {}

    for _, recipe in ipairs(tab.recipes) do
        local matches = recipeMatchesSearch(recipe, query)
            and recipeMatchesCategory(recipe, tab)
            and recipeMatchesMaterial(recipe, tab)
            and recipeMatchesOwnedFilter(recipe, tab)

        if matches then
            tab.filteredRecipes[#tab.filteredRecipes + 1] = recipe
        end
    end
end

local function formatIngredientAmount(ingredient)
    if ingredient.minAmount and ingredient.maxAmount then
        return "x" .. ingredient.minAmount .. "-" .. ingredient.maxAmount
    end

    return "x" .. ingredient.amount
end

local function buildIngredientSlot(ingredient, container)
    local slotWidget = g_ui.createWidget("CraftBenchIngredientSlot", container)

    slotWidget.icon:setItemId(ingredient.clientId)
    slotWidget.name:setText(ingredient.name)
    slotWidget.amount:setText(formatIngredientAmount(ingredient))
end

local function clearIngredientSlots(tab)
    local ingredientSlots = getTabPanel(tab).rightPanel.ingredientsPanel.ingredientSlots
    ingredientSlots:destroyChildren()
end

local function applyIngredientSlots(tab, ingredients)
    clearIngredientSlots(tab)

    local ingredientSlots = getTabPanel(tab).rightPanel.ingredientsPanel.ingredientSlots

    for _, ingredient in ipairs(ingredients) do
        buildIngredientSlot(ingredient, ingredientSlots)
    end
end

local function clearResultPanel(tab)
    local rightPanel = getTabPanel(tab).rightPanel

    rightPanel.resultPanel.resultIcon:setVisible(false)
    rightPanel.resultPanel.resultName:setText(tr("Select an item"))
    rightPanel.resultPanel.resultAmount:setText("")

    rightPanel.descriptionPanel.descriptionIcon:setVisible(false)
    rightPanel.descriptionPanel.descriptionName:setText("")
    rightPanel.descriptionPanel.descriptionText:setText("")

    clearIngredientSlots(tab)
end

local function applyResultPanel(tab, recipe)
    local resultPanel = getTabPanel(tab).rightPanel.resultPanel
    local hasResultIcon = (recipe.resultClientId or 0) > 0

    resultPanel.resultIcon:setVisible(hasResultIcon)

    if hasResultIcon then
        resultPanel.resultIcon:setItemId(recipe.resultClientId)
        resultPanel.resultIcon:setBorderColor(getRarityColor(recipe.resultRarity))
    end

    resultPanel.resultName:setText(recipe.resultName)
    resultPanel.resultAmount:setText(recipe.resultAmount > 0 and ("x" .. recipe.resultAmount) or "")

    local hasGoldCost = (recipe.goldCost or 0) > 0
    resultPanel.costLabel:setVisible(hasGoldCost)

    if hasGoldCost then
        resultPanel.costLabel:setText("Cost: " .. formatGoldCost(recipe.goldCost) .. " gold")
    end

    local hasSuccessChance = (recipe.successChance or 100) < 100
    resultPanel.chanceLabel:setVisible(hasSuccessChance)

    if hasSuccessChance then
        resultPanel.chanceLabel:setText("Success chance: " .. recipe.successChance .. "%")
    end
end

local function applyDescriptionPanel(tab, recipe)
    local descriptionPanel = getTabPanel(tab).rightPanel.descriptionPanel
    local hasResultIcon = (recipe.resultClientId or 0) > 0

    descriptionPanel.descriptionIcon:setVisible(hasResultIcon)

    if hasResultIcon then
        descriptionPanel.descriptionIcon:setItemId(recipe.resultClientId)
        descriptionPanel.descriptionIcon:setBorderColor(getRarityColor(recipe.resultRarity))
    end

    descriptionPanel.descriptionName:setText(recipe.resultName)
    descriptionPanel.descriptionText:setText(recipe.resultDescription or "")
end

local function markSelectedRow(tab, index)
    local rowsContainer = getTabPanel(tab).leftPanel.recipeListPanel.recipeRows

    for _, rowWidget in pairs(rowsContainer:getChildren()) do
        rowWidget:setChecked(rowWidget.recipeIndex == index)
    end
end

local function selectRecipe(tab, index)
    local recipe = tab.recipes[index]

    if not recipe then
        return
    end

    tab.selectedIndex = index

    applyIngredientSlots(tab, recipe.ingredients or {})
    applyResultPanel(tab, recipe)
    applyDescriptionPanel(tab, recipe)
    markSelectedRow(tab, index)
end

function onRecipeRowClicked(rowWidget)
    local tab = tabs[rowWidget.tabName]

    if not tab then
        return
    end

    selectRecipe(tab, rowWidget.recipeIndex)
end

local function createRecipeRowWidget(tab, recipe, rowsContainer)
    local rowWidget = g_ui.createWidget("CraftBenchRecipeRow", rowsContainer)
    rowWidget.recipeIndex = recipe.index
    rowWidget.tabName = tab.name

    local hasResultIcon = (recipe.resultClientId or 0) > 0
    rowWidget.icon:setVisible(hasResultIcon)

    if hasResultIcon then
        rowWidget.icon:setItemId(recipe.resultClientId)
        rowWidget.icon:setBorderColor(getRarityColor(recipe.resultRarity))
    end

    rowWidget.name:setText(recipe.resultName)
    rowWidget.subtitle:setText(#(recipe.ingredients or {}) .. " ingredients")
    rowWidget:setChecked(recipe.index == tab.selectedIndex)

    local hasClassification = (recipe.classification or 0) > 0
    rowWidget.classificationBadge:setVisible(hasClassification)

    if hasClassification then
        rowWidget.classificationBadge:setText("CLASS " .. recipe.classification)
    end
end

local function rebuildRecipeListWidget(tab)
    if not craftBenchWindow then
        return
    end

    local rowsContainer = getTabPanel(tab).leftPanel.recipeListPanel.recipeRows
    rowsContainer:destroyChildren()

    for _, recipe in ipairs(tab.filteredRecipes) do
        createRecipeRowWidget(tab, recipe, rowsContainer)
    end
end

function onSearchChange(tabName, text)
    local tab = tabs[tabName]

    if not tab then
        return
    end

    tab.searchText = text or ""
    buildFilteredRecipes(tab)
    rebuildRecipeListWidget(tab)
end

function setCategoryFilter(tabName, categoryValue)
    local tab = tabs[tabName]

    if not tab then
        return
    end

    tab.categoryFilter = categoryValue
    buildFilteredRecipes(tab)
    rebuildRecipeListWidget(tab)
end

function onCategoryFilterChange(tabName, comboBoxWidget)
    local currentOption = comboBoxWidget:getCurrentOption()

    if not currentOption then
        return
    end

    setCategoryFilter(tabName, currentOption.data)
end

function setMaterialFilter(tabName, material, isChecked)
    local tab = tabs[tabName]

    if not tab then
        return
    end

    tab.materialFilters[material] = isChecked
    buildFilteredRecipes(tab)
    rebuildRecipeListWidget(tab)
end

function setOwnedOnlyFilter(tabName, isChecked)
    local tab = tabs[tabName]

    if not tab then
        return
    end

    tab.ownedOnly = isChecked
    buildFilteredRecipes(tab)
    rebuildRecipeListWidget(tab)
end

local function sendToServer(payload)
    local protocol = g_game.getProtocolGame()

    if not protocol then
        return
    end

    protocol:sendExtendedOpcode(CRAFTBENCH_OPCODE, json.encode(payload))
end

local function requestTabData(tab)
    sendToServer({ action = "request", tab = tab.name })
end

function performTabAction()
    local tab = tabs[activeTabName]

    if tab.selectedIndex == 0 then
        return
    end

    sendToServer({
        action      = "execute",
        tab         = tab.name,
        recipeIndex = tab.selectedIndex
    })
end

local function applyTabVisualState(tabName)
    for name, tab in pairs(tabs) do
        getTabPanel(tab):setVisible(name == tabName)
        craftBenchWindow.tabBar[tab.buttonId]:setEnabled(name ~= tabName)
    end
end

function switchTab(tabName)
    local tab = tabs[tabName]

    if not tab then
        return
    end

    if tabName == activeTabName then
        return
    end

    activeTabName = tabName
    applyTabVisualState(tabName)
    requestTabData(tab)
end

local function populateCategoryFilterOptions(tab)
    local comboBoxWidget = getTabPanel(tab).leftPanel.classFilterComboBox

    for _, option in ipairs(tab.categoryFilterOptions) do
        comboBoxWidget:addOption(tr(option.label), option.value)
    end
end

local function resetFilterWidgets(tab)
    local leftPanel = getTabPanel(tab).leftPanel
    local comboBoxWidget = leftPanel.classFilterComboBox

    if not comboBoxWidget then
        return
    end

    comboBoxWidget:setCurrentOption(tr("All"))
    leftPanel.materialFilterBar.materialGoldToggle:setChecked(false)
    leftPanel.materialFilterBar.materialPlatinumToggle:setChecked(false)

    if leftPanel.ownedOnlyCheckbox then
        leftPanel.ownedOnlyCheckbox:setChecked(false)
    end
end

local function resetTabState(tab)
    tab.recipes = {}
    tab.filteredRecipes = {}
    tab.searchText = ""
    tab.selectedIndex = 0
    tab.categoryFilter = "all"
    tab.materialFilters = { gold = false, platinum = false }
    tab.ownedOnly = false
end

local function resetState()
    for _, tab in pairs(tabs) do
        resetTabState(tab)
    end

    resetFilterWidgets(tabs.craft)
    resetFilterWidgets(tabs.desmanche)
    activeTabName = "craft"
end

local function applyServerState(tab, data)
    tab.recipes = data.recipes or {}
    tab.searchText = ""
    tab.selectedIndex = 0

    buildFilteredRecipes(tab)
    clearResultPanel(tab)
    rebuildRecipeListWidget(tab)
    applyResourceBar(data.resources)

    getTabPanel(tab).leftPanel.searchInput:setText("")

    craftBenchWindow:show()
    craftBenchWindow:raise()
    craftBenchWindow:focus()
end

local function applyExecutionResult(tab, data)
    tab.recipes = data.recipes or tab.recipes

    buildFilteredRecipes(tab)
    rebuildRecipeListWidget(tab)
    applyResourceBar(data.resources)
    showStatusMessage(data.success, data.message)
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= CRAFTBENCH_OPCODE then
        return
    end

    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then
        return
    end

    local resolvedTabName = data.tab or "craft"
    local tab = tabs[resolvedTabName]

    if not tab then
        g_logger.warning("game_craftbench: aba desconhecida recebida do servidor: " .. tostring(data.tab))
        return
    end

    if data.action == "data" then
        applyServerState(tab, data)
    elseif data.action == "result" then
        applyExecutionResult(tab, data)
    end
end

local function onGameStart()
    ProtocolGame.registerExtendedOpcode(CRAFTBENCH_OPCODE, onExtendedOpcode)
end

function show()
    craftBenchWindow:show()
    craftBenchWindow:raise()
    craftBenchWindow:focus()
    requestTabData(tabs[activeTabName])
end

function hide()
    craftBenchWindow:hide()
end

function toggle()
    if craftBenchWindow:isVisible() then
        return hide()
    end

    show()
end

local function onGameEnd()
    ProtocolGame.unregisterExtendedOpcode(CRAFTBENCH_OPCODE)
    hide()
    resetState()
end

function init()
    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd   = onGameEnd
    })

    craftBenchWindow = g_ui.displayUI("craftbench")
    craftBenchWindow:hide()

    applyTabVisualState(activeTabName)
    populateCategoryFilterOptions(tabs.craft)
    populateCategoryFilterOptions(tabs.desmanche)

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd   = onGameEnd
    })

    if craftBenchWindow then
        craftBenchWindow:destroy()
    end
end