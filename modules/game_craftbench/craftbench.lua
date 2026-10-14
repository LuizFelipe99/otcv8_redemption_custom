local CRAFTBENCH_OPCODE = 13
local GOLD_COIN_CLIENT_ID = 3031
local STATUS_MESSAGE_DURATION = 4000

local FALLBACK_RESOURCE_SLOTS = {
	{ clientId = 60483, name = 'Golden Ruby Crafter Nv. 1', group = 'gold' },
	{ clientId = 60490, name = 'Golden Ruby Crafter Nv. 2', group = 'gold' },
	{ clientId = 60497, name = 'Golden Ruby Crafter Nv. 3', group = 'gold' },
	{ clientId = 63401, name = 'Golden Ruby Crafter Nv. 4', group = 'gold' },
	{ clientId = 60482, name = 'Platinum Ruby Crafter Nv. 1', group = 'platinum' },
	{ clientId = 60489, name = 'Platinum Ruby Crafter Nv. 2', group = 'platinum' },
	{ clientId = 60496, name = 'Platinum Ruby Crafter Nv. 3', group = 'platinum' },
	{ clientId = 63400, name = 'Platinum Ruby Crafter Nv. 4', group = 'platinum' }
}

local VOCATION_LABELS = {
	knight = 'Knight',
	paladin = 'Paladin',
	druid = 'Druid',
	sorcerer = 'Sorcerer',
	monk = 'Monk',
	atribute_gem = 'Attribute Gem'
}

local TAB_DEFINITIONS = {
	craft = {
		buttonId = 'craftTabButton',
		actionLabel = 'Craft',
		inputHeader = 'Ingredients',
		outputHeader = 'You receive',
		categoryField = 'vocation',
		allCategoriesLabel = 'All vocations',
		consumesResult = false
	},
	desmanche = {
		buttonId = 'desmancheTabButton',
		actionLabel = 'Dismantle',
		inputHeader = 'Item to dismantle',
		outputHeader = 'You receive (random amount)',
		categoryField = 'classification',
		allCategoriesLabel = 'All classes',
		consumesResult = true
	},
	fusao = {
		buttonId = 'fusaoTabButton',
		actionLabel = 'Fuse',
		inputHeader = 'Gems to fuse',
		outputHeader = 'Result',
		categoryField = nil,
		allCategoriesLabel = nil,
		consumesResult = false
	}
}

local TAB_ORDER = { 'craft', 'desmanche', 'fusao' }

local craftBenchWindow
local activeTabName = 'craft'
local statusMessageEvent
local resourceSlots = FALLBACK_RESOURCE_SLOTS
local materialGroups = nil
local tabStates = {}

local function createTabState()
	return {
		recipes = {},
		filteredRecipes = {},
		searchText = '',
		selectedIndex = 0,
		categoryFilter = 'all',
		materialFilters = { gold = false, platinum = false },
		readyOnly = false
	}
end

local function resetTabStates()
	for _, tabName in ipairs(TAB_ORDER) do
		tabStates[tabName] = createTabState()
	end
end

local function activeTab()
	return tabStates[activeTabName], TAB_DEFINITIONS[activeTabName]
end

local function sendToServer(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(CRAFTBENCH_OPCODE, json.encode(payload))
end

local function formatNumber(amount)
	local formattedNumber = tostring(math.floor(tonumber(amount) or 0))
	while true do
		local replacedNumber, replacementCount = formattedNumber:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
		formattedNumber = replacedNumber
		if replacementCount == 0 then
			return formattedNumber
		end
	end
end

local function formatGoldShort(amount)
	local value = tonumber(amount) or 0
	if value >= 1000000 then
		local millions = value / 1000000
		return (millions == math.floor(millions) and string.format('%dkk', millions) or string.format('%.1fkk', millions))
	end

	if value >= 1000 then
		return string.format('%dk', math.floor(value / 1000))
	end

	return tostring(value)
end

local function canExecuteRecipe(recipe)
	if recipe.canExecute ~= nil then
		return recipe.canExecute == true
	end

	return recipe.hasRequiredItems == true
end

local function resolveCategoryLabel(tabDefinition, value)
	if tabDefinition.categoryField == 'classification' then
		if tonumber(value) == 0 then
			return tr('No class')
		end
		return tr('Class') .. ' ' .. value
	end

	local knownLabel = VOCATION_LABELS[value]
	if knownLabel then
		return tr(knownLabel)
	end

	local text = tostring(value or '')
	return text:sub(1, 1):upper() .. text:sub(2)
end

local function buildMaterialIdSets()
	local idSets = { gold = {}, platinum = {} }

	if materialGroups then
		for groupName, clientIds in pairs(materialGroups) do
			idSets[groupName] = idSets[groupName] or {}
			for _, clientId in ipairs(clientIds) do
				idSets[groupName][tonumber(clientId)] = true
			end
		end
		return idSets
	end

	for _, slot in ipairs(FALLBACK_RESOURCE_SLOTS) do
		idSets[slot.group][slot.clientId] = true
	end
	return idSets
end

local function recipeUsesMaterialGroup(recipe, idSet)
	for _, ingredient in ipairs(recipe.ingredients or {}) do
		if idSet[tonumber(ingredient.clientId)] then
			return true
		end
	end
	return false
end

local function recipeMatchesFilters(recipe, tabState, tabDefinition, materialIdSets)
	local query = tabState.searchText:lower()
	if query ~= '' and not recipe.resultName:lower():find(query, 1, true) then
		return false
	end

	if tabDefinition.categoryField and tabState.categoryFilter ~= 'all' then
		local recipeCategory = recipe[tabDefinition.categoryField]
		if tostring(recipeCategory) ~= tostring(tabState.categoryFilter) then
			return false
		end
	end

	local filters = tabState.materialFilters
	if filters.gold or filters.platinum then
		local matchesGold = filters.gold and recipeUsesMaterialGroup(recipe, materialIdSets.gold)
		local matchesPlatinum = filters.platinum and recipeUsesMaterialGroup(recipe, materialIdSets.platinum)
		if not matchesGold and not matchesPlatinum then
			return false
		end
	end

	if tabState.readyOnly and not canExecuteRecipe(recipe) then
		return false
	end

	return true
end

local function buildFilteredRecipes()
	local tabState, tabDefinition = activeTab()
	local materialIdSets = buildMaterialIdSets()

	tabState.filteredRecipes = {}
	for _, recipe in ipairs(tabState.recipes) do
		if recipeMatchesFilters(recipe, tabState, tabDefinition, materialIdSets) then
			table.insert(tabState.filteredRecipes, recipe)
		end
	end
end

local function findRecipe(tabState, recipeIndex)
	for _, recipe in ipairs(tabState.recipes) do
		if recipe.index == recipeIndex then
			return recipe
		end
	end
	return nil
end

local function applyResourceStrip(resources)
	if not resources or not craftBenchWindow then
		return
	end

	local resourceStrip = craftBenchWindow.resourceStrip
	resourceStrip.goldChip.icon:setItemId(GOLD_COIN_CLIENT_ID)
	resourceStrip.goldChip.amount:setText(formatNumber(resources.gold or 0))
	resourceStrip.goldChip:setTooltip(tr('Gold (backpack + bank)') .. ': ' .. formatNumber(resources.gold or 0))

	local slots = resources.slots or {}
	if #slots == 0 then
		for _, fallbackSlot in ipairs(resourceSlots) do
			table.insert(slots, {
				clientId = fallbackSlot.clientId,
				name = fallbackSlot.name,
				amount = (resources.items or {})[tostring(fallbackSlot.clientId)] or 0
			})
		end
	end

	local resourceChips = resourceStrip.resourceChips
	resourceChips:destroyChildren()
	for _, slot in ipairs(slots) do
		local chip = g_ui.createWidget('CraftResourceChip', resourceChips)
		chip.icon:setItemId(slot.clientId)
		chip.amount:setText(tostring(slot.amount or 0))
		chip.amount:setColor((slot.amount or 0) > 0 and '#dfdfdf' or '#6a6a6a')
		chip:setTooltip((slot.name or '') .. ': ' .. tostring(slot.amount or 0))
	end
end

local function hideStatusMessage()
	if statusMessageEvent then
		removeEvent(statusMessageEvent)
		statusMessageEvent = nil
	end

	if craftBenchWindow then
		craftBenchWindow.workbench.statusBanner:setText('')
	end
end

local function showStatusMessage(success, message)
	if not message or message == '' then
		return
	end

	hideStatusMessage()
	local statusBanner = craftBenchWindow.workbench.statusBanner
	statusBanner:setText(message)
	statusBanner:setColor(success and '#6fd38a' or '#ff7a6a')
	statusMessageEvent = scheduleEvent(function()
		statusMessageEvent = nil
		hideStatusMessage()
	end, STATUS_MESSAGE_DURATION)
end

local function formatIngredientAmount(ingredient)
	if ingredient.minAmount and ingredient.maxAmount then
		return ingredient.minAmount .. '-' .. ingredient.maxAmount
	end

	return tostring(ingredient.amount or 0)
end

local function createMaterialRow(container, clientId, name, requiredAmount, ownedAmount, amountText)
	local materialRow = g_ui.createWidget('CraftMaterialRow', container)
	materialRow.icon:setItemId(clientId)
	materialRow.icon:setTooltip(name)
	materialRow.name:setText(name)

	if ownedAmount == nil then
		materialRow.amount:setText('x' .. amountText)
		materialRow.amount:setColor('#c0c0c0')
		materialRow.ownedBar:setVisible(false)
		return
	end

	local hasEnough = ownedAmount >= requiredAmount
	materialRow.amount:setText(formatNumber(math.min(ownedAmount, requiredAmount)) .. ' / ' .. formatNumber(requiredAmount))
	materialRow.amount:setColor(hasEnough and '#6fd38a' or '#f0c060')
	materialRow.ownedBar:setPercent(requiredAmount > 0 and math.min(100, ownedAmount * 100 / requiredAmount) or 100)
	materialRow.ownedBar:setBackgroundColor(hasEnough and '#2f9e44' or '#c28400')
end

local function fillIngredientRows(container, recipe, showOwned)
	for _, ingredient in ipairs(recipe.ingredients or {}) do
		local ownedAmount = showOwned and tonumber(ingredient.owned) or nil
		createMaterialRow(container, ingredient.clientId, ingredient.name or '', tonumber(ingredient.amount) or 0, ownedAmount, formatIngredientAmount(ingredient))
	end
end

local function fillResultRow(container, recipe, showOwned)
	local ownedAmount = showOwned and tonumber(recipe.resultOwned) or nil
	createMaterialRow(container, recipe.resultClientId, recipe.resultName, tonumber(recipe.resultAmount) or 1, ownedAmount, tostring(recipe.resultAmount or 1))
end

local function chanceColor(successChance)
	if successChance >= 90 then
		return '#6fd38a'
	end

	if successChance >= 50 then
		return '#f0c060'
	end

	return '#ff7a6a'
end

local function setWorkbenchContentVisible(isVisible)
	local workbench = craftBenchWindow.workbench
	for _, child in ipairs(workbench:getChildren()) do
		child:setVisible(isVisible == (child:getId() ~= 'emptyWorkbenchLabel'))
	end
end

local function describeRecipeTag(recipe, tabDefinition)
	if tabDefinition.categoryField == 'vocation' and recipe.vocation and recipe.vocation ~= '' then
		return resolveCategoryLabel(tabDefinition, recipe.vocation)
	end

	if tabDefinition.categoryField == 'classification' and (tonumber(recipe.classification) or 0) > 0 then
		return resolveCategoryLabel(tabDefinition, recipe.classification)
	end

	return tr(tabDefinition.actionLabel)
end

local function updateWorkbench()
	local tabState, tabDefinition = activeTab()
	local recipe = findRecipe(tabState, tabState.selectedIndex)
	local workbench = craftBenchWindow.workbench

	if not recipe then
		setWorkbenchContentVisible(false)
		return
	end

	setWorkbenchContentVisible(true)
	workbench.statusBanner:setVisible(true)

	workbench.header.headerIcon:setItemId(recipe.resultClientId)
	workbench.header.title:setText(recipe.resultName)
	workbench.header.tag:setText(describeRecipeTag(recipe, tabDefinition))

	workbench.inputHeader:setText(tr(tabDefinition.inputHeader))
	workbench.outputHeader:setText('>> ' .. tr(tabDefinition.outputHeader))
	workbench.inputList:destroyChildren()
	workbench.outputList:destroyChildren()

	if tabDefinition.consumesResult then
		fillResultRow(workbench.inputList, recipe, true)
		fillIngredientRows(workbench.outputList, recipe, false)
	else
		fillIngredientRows(workbench.inputList, recipe, true)
		fillResultRow(workbench.outputList, recipe, false)
	end

	local goldCost = tonumber(recipe.goldCost) or 0
	workbench.costChip.caption:setText(tr('Cost'))
	workbench.costChip.value:setText(goldCost > 0 and (formatNumber(goldCost) .. ' gp') or tr('Free'))
	workbench.costChip.value:setColor(recipe.hasEnoughGold == false and '#ff7a6a' or '#f0c060')

	local successChance = tonumber(recipe.successChance) or 100
	workbench.chanceChip.caption:setText(tr('Success chance'))
	workbench.chanceChip.value:setText(successChance .. '%')
	workbench.chanceChip.value:setColor(chanceColor(successChance))

	workbench.description:setText(recipe.resultDescription or '')

	local isReady = canExecuteRecipe(recipe)
	workbench.actionButton:setText(tr(tabDefinition.actionLabel))
	workbench.actionButton:setEnabled(isReady)
end

local function describeRecipeSubtitle(recipe, tabDefinition)
	local parts = {}
	local tag = describeRecipeTag(recipe, tabDefinition)
	if tag ~= tr(tabDefinition.actionLabel) then
		table.insert(parts, tag)
	end

	local successChance = tonumber(recipe.successChance) or 100
	if successChance < 100 then
		table.insert(parts, successChance .. '% ' .. tr('chance'))
	end

	local goldCost = tonumber(recipe.goldCost) or 0
	if goldCost > 0 then
		table.insert(parts, formatGoldShort(goldCost) .. ' gp')
	end

	if #parts == 0 then
		return #(recipe.ingredients or {}) .. ' ' .. tr('materials')
	end

	return table.concat(parts, '  -  ')
end

local function onRecipeRowFocus(recipeRows, focusedRow)
	if not focusedRow then
		return
	end

	local tabState = activeTab()
	tabState.selectedIndex = focusedRow.recipeIndex
	updateWorkbench()
end

local function rebuildRecipeList()
	local tabState, tabDefinition = activeTab()
	local leftPanel = craftBenchWindow.leftPanel
	local recipeRows = leftPanel.recipeRows

	recipeRows.onChildFocusChange = nil
	recipeRows:destroyChildren()

	local selectedRow = nil
	for _, recipe in ipairs(tabState.filteredRecipes) do
		local row = g_ui.createWidget('CraftRecipeRow', recipeRows)
		row:setId('recipe' .. recipe.index)
		row.recipeIndex = recipe.index
		row.icon:setItemId(recipe.resultClientId)
		row.name:setText(recipe.resultName)
		row.subtitle:setText(describeRecipeSubtitle(recipe, tabDefinition))

		local isReady = canExecuteRecipe(recipe)
		row.readyLabel:setText(isReady and tr('Ready') or '')
		row.readyLabel:setColor('#6fd38a')
		row.onClick = function()
			recipeRows:focusChild(row, MouseFocusReason)
			onRecipeRowFocus(recipeRows, row)
		end

		if recipe.index == tabState.selectedIndex then
			selectedRow = row
		end
	end

	leftPanel.listCountLabel:setText(#tabState.filteredRecipes .. ' / ' .. #tabState.recipes .. ' ' .. tr('recipes'))
	leftPanel.emptyListLabel:setVisible(#tabState.filteredRecipes == 0)
	recipeRows.onChildFocusChange = onRecipeRowFocus

	selectedRow = selectedRow or recipeRows:getFirstChild()
	if not selectedRow then
		tabState.selectedIndex = 0
		updateWorkbench()
		return
	end

	recipeRows:focusChild(selectedRow, ActiveFocusReason)
	recipeRows:ensureChildVisible(selectedRow)
	onRecipeRowFocus(recipeRows, selectedRow)
end

local function refreshList()
	buildFilteredRecipes()
	rebuildRecipeList()
end

local function rebuildCategoryOptions()
	local tabState, tabDefinition = activeTab()
	local categoryFilter = craftBenchWindow.leftPanel.categoryFilter
	categoryFilter.onOptionChange = nil
	categoryFilter:clearOptions()

	if not tabDefinition.categoryField then
		categoryFilter:setVisible(false)
		return
	end

	categoryFilter:setVisible(true)
	categoryFilter:addOption(tr(tabDefinition.allCategoriesLabel), 'all')

	local seenValues = {}
	local orderedValues = {}
	for _, recipe in ipairs(tabState.recipes) do
		local value = recipe[tabDefinition.categoryField]
		if value ~= nil and value ~= '' and not seenValues[tostring(value)] then
			seenValues[tostring(value)] = true
			table.insert(orderedValues, value)
		end
	end

	table.sort(orderedValues, function(firstValue, secondValue)
		return tostring(firstValue) < tostring(secondValue)
	end)

	local selectedLabel = tr(tabDefinition.allCategoriesLabel)
	for _, value in ipairs(orderedValues) do
		local label = resolveCategoryLabel(tabDefinition, value)
		categoryFilter:addOption(label, value)
		if tostring(value) == tostring(tabState.categoryFilter) then
			selectedLabel = label
		end
	end

	categoryFilter:setCurrentOption(selectedLabel)
	categoryFilter.onOptionChange = function(comboBox, optionText, optionData)
		tabState.categoryFilter = optionData or 'all'
		refreshList()
	end
end

local function syncFilterWidgets()
	local tabState = activeTab()
	local leftPanel = craftBenchWindow.leftPanel

	leftPanel.searchInput:setText(tabState.searchText)
	leftPanel.goldToggle:setChecked(tabState.materialFilters.gold)
	leftPanel.platinumToggle:setChecked(tabState.materialFilters.platinum)
	leftPanel.readyOnlyToggle:setChecked(tabState.readyOnly)
	rebuildCategoryOptions()
end

local function applyTabButtons()
	for _, tabName in ipairs(TAB_ORDER) do
		craftBenchWindow.tabBar[TAB_DEFINITIONS[tabName].buttonId]:setOn(tabName == activeTabName)
	end
end

function onSearchChange(text)
	local tabState = activeTab()
	if not tabState then
		return
	end

	tabState.searchText = text or ''
	refreshList()
end

function setMaterialFilter(materialGroup, isChecked)
	local tabState = activeTab()
	if not tabState or tabState.materialFilters[materialGroup] == isChecked then
		return
	end

	tabState.materialFilters[materialGroup] = isChecked
	refreshList()
end

function setReadyOnlyFilter(isChecked)
	local tabState = activeTab()
	if not tabState or tabState.readyOnly == isChecked then
		return
	end

	tabState.readyOnly = isChecked
	refreshList()
end

function performTabAction()
	local tabState = activeTab()
	local recipe = findRecipe(tabState, tabState.selectedIndex)
	if not recipe or not canExecuteRecipe(recipe) then
		return
	end

	sendToServer({ action = 'execute', tab = activeTabName, recipeIndex = recipe.index })
end

function switchTab(tabName)
	if not TAB_DEFINITIONS[tabName] or tabName == activeTabName then
		return
	end

	activeTabName = tabName
	hideStatusMessage()
	applyTabButtons()
	syncFilterWidgets()
	refreshList()
	sendToServer({ action = 'request', tab = tabName })
end

local function applyServerRules(data)
	if type(data.materialGroups) == 'table' then
		materialGroups = data.materialGroups
	end
end

local function applyServerState(tabName, data)
	local tabState = tabStates[tabName]
	tabState.recipes = data.recipes or {}
	applyServerRules(data)
	applyResourceStrip(data.resources)

	if tabName ~= activeTabName then
		return
	end

	syncFilterWidgets()
	refreshList()

	craftBenchWindow:show()
	craftBenchWindow:raise()
	craftBenchWindow:focus()
end

local function applyExecutionResult(tabName, data)
	local tabState = tabStates[tabName]
	tabState.recipes = data.recipes or tabState.recipes
	applyServerRules(data)
	applyResourceStrip(data.resources)

	if tabName ~= activeTabName then
		return
	end

	refreshList()
	showStatusMessage(data.success, data.message)
end

local function onExtendedOpcode(protocol, opcode, buffer)
	if opcode ~= CRAFTBENCH_OPCODE then
		return
	end

	local decodedSuccessfully, data = pcall(function()
		return json.decode(buffer)
	end)

	if not decodedSuccessfully or not data then
		return
	end

	local tabName = data.tab or 'craft'
	if not tabStates[tabName] then
		g_logger.warning('game_craftbench: unknown tab received from server: ' .. tostring(data.tab))
		return
	end

	if data.action == 'data' then
		applyServerState(tabName, data)
		return
	end

	if data.action == 'result' then
		applyExecutionResult(tabName, data)
	end
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(CRAFTBENCH_OPCODE, onExtendedOpcode)
end

function show()
	craftBenchWindow:show()
	craftBenchWindow:raise()
	craftBenchWindow:focus()
	sendToServer({ action = 'request', tab = activeTabName })
end

function hide()
	craftBenchWindow:hide()
	hideStatusMessage()
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
	resetTabStates()
	materialGroups = nil
	activeTabName = 'craft'
	applyTabButtons()
	syncFilterWidgets()
	refreshList()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	resetTabStates()
	craftBenchWindow = g_ui.displayUI('craftbench')
	craftBenchWindow:hide()
	applyTabButtons()
	syncFilterWidgets()
	refreshList()

	if g_game.isOnline() then
		onGameStart()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	hideStatusMessage()

	if craftBenchWindow then
		craftBenchWindow:destroy()
		craftBenchWindow = nil
	end
end
