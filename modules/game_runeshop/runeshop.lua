local RUNESHOP_OPCODE = 11
local GOLD_COIN_CLIENT_ID = 3031
local DEFAULT_DELIVERY_CONTAINER_ID = 2854
local DEFAULT_CONTAINER_SLOTS = 20
local DEFAULT_STACK_SIZE = 100
local DEFAULT_QUANTITY_OPTIONS = { 100, 300, 500, 1000 }
local STATUS_MESSAGE_DURATION = 5000

local CATEGORY_DEFINITIONS = {
	all = { buttonId = 'allTabButton', label = 'All', color = '#c0c0c0' },
	attack = { buttonId = 'attackTabButton', label = 'Attack', color = '#ff8a5c' },
	healing = { buttonId = 'healingTabButton', label = 'Healing', color = '#6fd38a' },
	support = { buttonId = 'supportTabButton', label = 'Support', color = '#7ab8ff' },
	field = { buttonId = 'fieldTabButton', label = 'Fields', color = '#d08cff' }
}

local CATEGORY_ORDER = { 'all', 'attack', 'healing', 'support', 'field' }

local runeShopWindow
local statusMessageEvent
local shopState = {}

local function createShopState()
	return {
		runes = {},
		filteredRunes = {},
		playerBalance = 0,
		freeCapacity = nil,
		quantityOptions = DEFAULT_QUANTITY_OPTIONS,
		stackSize = DEFAULT_STACK_SIZE,
		deliveryContainerId = DEFAULT_DELIVERY_CONTAINER_ID,
		containerWeight = nil,
		selectedCategory = 'all',
		searchText = '',
		selectedClientId = 0,
		selectedQuantity = DEFAULT_QUANTITY_OPTIONS[1],
		purchasePending = false
	}
end

local function sendToServer(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(RUNESHOP_OPCODE, json.encode(payload))
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

local function formatOunces(hundredthsOfOunce)
	local wholeOunces = math.floor(hundredthsOfOunce / 100)
	local fractionalOunces = math.floor(hundredthsOfOunce % 100)
	return string.format('%s.%02d oz', formatNumber(wholeOunces), fractionalOunces)
end

local function capitalizeWords(text)
	return (tostring(text or ''):gsub('(%a)([%w]*)', function(firstLetter, remainingLetters)
		return firstLetter:upper() .. remainingLetters
	end))
end

local function findRuneByClientId(clientId)
	for _, rune in ipairs(shopState.runes) do
		if rune.clientId == clientId then
			return rune
		end
	end

	return nil
end

local function selectedRune()
	return findRuneByClientId(shopState.selectedClientId)
end

local function countRunesInCategory(categoryName)
	if categoryName == 'all' then
		return #shopState.runes
	end

	local runeCount = 0
	for _, rune in ipairs(shopState.runes) do
		if rune.category == categoryName then
			runeCount = runeCount + 1
		end
	end

	return runeCount
end

local function runeMatchesFilters(rune)
	if shopState.selectedCategory ~= 'all' and rune.category ~= shopState.selectedCategory then
		return false
	end

	if shopState.searchText == '' then
		return true
	end

	local searchableText = (tostring(rune.itemName or '') .. ' ' .. tostring(rune.shortName or '')):lower()
	return searchableText:find(shopState.searchText, 1, true) ~= nil
end

local function buildFilteredRunes()
	shopState.filteredRunes = {}
	for _, rune in ipairs(shopState.runes) do
		if runeMatchesFilters(rune) then
			table.insert(shopState.filteredRunes, rune)
		end
	end
end

local function calculateStackCount(quantity)
	return math.ceil(quantity / math.max(1, shopState.stackSize))
end

local function calculateRequiredWeight(rune, quantity)
	if not rune.weight or not shopState.containerWeight then
		return nil
	end

	return rune.weight * quantity + shopState.containerWeight
end

local function evaluatePurchase(rune)
	local quantity = shopState.selectedQuantity
	local totalPrice = rune.price * quantity
	local requiredWeight = calculateRequiredWeight(rune, quantity)
	local hasEnoughGold = shopState.playerBalance >= totalPrice
	local hasEnoughCapacity = true
	if requiredWeight and shopState.freeCapacity then
		hasEnoughCapacity = shopState.freeCapacity >= requiredWeight
	end

	return {
		quantity = quantity,
		totalPrice = totalPrice,
		requiredWeight = requiredWeight,
		stackCount = calculateStackCount(quantity),
		hasEnoughGold = hasEnoughGold,
		hasEnoughCapacity = hasEnoughCapacity
	}
end

local function hideStatusMessage()
	if statusMessageEvent then
		removeEvent(statusMessageEvent)
		statusMessageEvent = nil
	end

	if runeShopWindow then
		runeShopWindow.checkoutPanel.statusBanner:setText('')
	end
end

local function showStatusMessage(success, message)
	if not message or message == '' then
		return
	end

	hideStatusMessage()
	local statusBanner = runeShopWindow.checkoutPanel.statusBanner
	statusBanner:setText(message)
	statusBanner:setColor(success and '#6fd38a' or '#ff7a6a')
	statusMessageEvent = scheduleEvent(function()
		statusMessageEvent = nil
		hideStatusMessage()
	end, STATUS_MESSAGE_DURATION)
end

local function applyHeaderStrip()
	local headerStrip = runeShopWindow.headerStrip

	local balanceChip = headerStrip.balanceChip
	balanceChip.icon:setItemId(GOLD_COIN_CLIENT_ID)
	balanceChip.icon:setItemCount(100)
	balanceChip.icon:setShowCount(false)
	balanceChip.caption:setText(tr('Bank'))
	balanceChip.value:setText(formatNumber(shopState.playerBalance))
	balanceChip.value:setColor('#f0c060')
	balanceChip:setTooltip(tr('Runes are paid with your bank balance.'))

	local capacityChip = headerStrip.capacityChip
	capacityChip.icon:setWidth(0)
	capacityChip.caption:setMarginLeft(5)
	capacityChip.caption:setText(tr('Free capacity'))
	capacityChip.value:setText(shopState.freeCapacity and formatOunces(shopState.freeCapacity) or '-')

	local deliveryChip = headerStrip.deliveryChip
	deliveryChip.icon:setItemId(shopState.deliveryContainerId)
	deliveryChip.caption:setText(tr('Delivered inside a backpack'))
	deliveryChip.value:setText('')
	deliveryChip:setTooltip(tr('Every purchase arrives in a new backpack, in stacks of %d.', shopState.stackSize))
end

local function applyCategoryTabs()
	local tabBar = runeShopWindow.tabBar
	for _, categoryName in ipairs(CATEGORY_ORDER) do
		local categoryDefinition = CATEGORY_DEFINITIONS[categoryName]
		local tabButton = tabBar[categoryDefinition.buttonId]
		tabButton:setText(tr(categoryDefinition.label) .. ' (' .. countRunesInCategory(categoryName) .. ')')
		tabButton:setOn(categoryName == shopState.selectedCategory)
	end
end

local function rebuildQuantityButtons()
	local quantityButtons = runeShopWindow.checkoutPanel.quantityButtons
	quantityButtons:destroyChildren()

	for _, quantity in ipairs(shopState.quantityOptions) do
		local quantityButton = g_ui.createWidget('RuneShopQuantityButton', quantityButtons)
		quantityButton:setText(formatNumber(quantity))
		quantityButton:setOn(quantity == shopState.selectedQuantity)
		quantityButton.onClick = function()
			selectQuantity(quantity)
		end
	end
end

local function setCheckoutContentVisible(isVisible)
	local checkoutPanel = runeShopWindow.checkoutPanel
	for _, child in ipairs(checkoutPanel:getChildren()) do
		child:setVisible(isVisible)
	end
	checkoutPanel.emptyCheckoutLabel:setVisible(not isVisible)
end

local function describePurchaseBlocker(purchase)
	if shopState.purchasePending then
		return tr('Processing...')
	end

	if not purchase.hasEnoughGold then
		return tr('Not enough gold in the bank')
	end

	if not purchase.hasEnoughCapacity then
		return tr('Not enough free capacity')
	end

	return nil
end

local function applyDeliveryCard(rune, purchase)
	local deliveryCard = runeShopWindow.checkoutPanel.deliveryCard
	deliveryCard.containerIcon:setItemId(shopState.deliveryContainerId)
	deliveryCard.runeIcon:setItemId(rune.clientId)
	deliveryCard.runeIcon:setItemCount(math.min(purchase.quantity, shopState.stackSize))

	local stackLabel = purchase.stackCount == 1 and tr('stack') or tr('stacks')
	deliveryCard.title:setText(tr('1 backpack with %d %s of %d', purchase.stackCount, stackLabel, shopState.stackSize))
	deliveryCard.subtitle:setText(tr('Uses %d of %d backpack slots', purchase.stackCount, DEFAULT_CONTAINER_SLOTS))
end

local function applySummaryRows(purchase)
	local checkoutPanel = runeShopWindow.checkoutPanel

	local totalRow = checkoutPanel.totalRow
	totalRow.caption:setText(tr('Total price'))
	totalRow.value:setText(formatNumber(purchase.totalPrice) .. ' gp')
	totalRow.value:setColor(purchase.hasEnoughGold and '#f0c060' or '#ff7a6a')

	local balanceAfterRow = checkoutPanel.balanceAfterRow
	balanceAfterRow.caption:setText(tr('Bank after purchase'))
	if purchase.hasEnoughGold then
		balanceAfterRow.value:setText(formatNumber(shopState.playerBalance - purchase.totalPrice) .. ' gp')
		balanceAfterRow.value:setColor('#dfdfdf')
	else
		balanceAfterRow.value:setText(tr('Missing %s gp', formatNumber(purchase.totalPrice - shopState.playerBalance)))
		balanceAfterRow.value:setColor('#ff7a6a')
	end

	local weightRow = checkoutPanel.weightRow
	local capacityBar = checkoutPanel.capacityBar
	weightRow.caption:setText(tr('Weight'))
	weightRow:setTooltip(tr('Includes the backpack. Compared with your free capacity.'))

	if not purchase.requiredWeight or not shopState.freeCapacity then
		weightRow.value:setText(purchase.requiredWeight and formatOunces(purchase.requiredWeight) or '-')
		weightRow.value:setColor('#dfdfdf')
		capacityBar:setVisible(false)
		return
	end

	weightRow.value:setText(formatOunces(purchase.requiredWeight) .. ' / ' .. formatOunces(shopState.freeCapacity))
	weightRow.value:setColor(purchase.hasEnoughCapacity and '#dfdfdf' or '#ff7a6a')

	local capacityUsagePercent = 100
	if shopState.freeCapacity > 0 then
		capacityUsagePercent = math.min(100, math.floor(purchase.requiredWeight * 100 / shopState.freeCapacity))
	end
	capacityBar:setPercent(capacityUsagePercent)
	capacityBar:setBackgroundColor(purchase.hasEnoughCapacity and '#6fd38a' or '#ff7a6a')
	capacityBar:setTooltip(tr('%d%% of your free capacity', capacityUsagePercent))
end

local function updateCheckout()
	local rune = selectedRune()
	if not rune then
		setCheckoutContentVisible(false)
		return
	end

	setCheckoutContentVisible(true)

	local checkoutPanel = runeShopWindow.checkoutPanel
	local categoryDefinition = CATEGORY_DEFINITIONS[rune.category]
	local header = checkoutPanel.header
	header.headerIcon:setItemId(rune.clientId)
	header.title:setText(capitalizeWords(rune.itemName))
	if categoryDefinition then
		header.tag:setText(tr(categoryDefinition.label) .. '  |  ' .. formatNumber(rune.price) .. ' ' .. tr('gold each'))
		header.tag:setColor(categoryDefinition.color)
	else
		header.tag:setText(formatNumber(rune.price) .. ' ' .. tr('gold each'))
		header.tag:setColor('#9d9d9d')
	end

	local purchase = evaluatePurchase(rune)
	applyDeliveryCard(rune, purchase)
	applySummaryRows(purchase)

	local purchaseBlocker = describePurchaseBlocker(purchase)
	local buyButton = checkoutPanel.buyButton
	buyButton:setEnabled(purchaseBlocker == nil)
	buyButton:setText(purchaseBlocker or tr('Buy %s runes for %s gp', formatNumber(purchase.quantity), formatNumber(purchase.totalPrice)))
end

local function applyCardSelection()
	for _, card in ipairs(runeShopWindow.catalogPanel.runeCards:getChildren()) do
		card:setOn(card.runeClientId == shopState.selectedClientId)
	end
end

local function rebuildRuneCards()
	local catalogPanel = runeShopWindow.catalogPanel
	local runeCards = catalogPanel.runeCards
	runeCards:destroyChildren()

	for _, rune in ipairs(shopState.filteredRunes) do
		local card = g_ui.createWidget('RuneShopCard', runeCards)
		card.runeClientId = rune.clientId
		card.icon:setItemId(rune.clientId)
		card.name:setText(rune.shortName or capitalizeWords(rune.itemName))
		card.price:setText(formatNumber(rune.price) .. ' gp')
		card:setTooltip(capitalizeWords(rune.itemName))

		local categoryDefinition = CATEGORY_DEFINITIONS[rune.category]
		card.categoryAccent:setBackgroundColor(categoryDefinition and categoryDefinition.color or '#00000000')
		card.onClick = function()
			selectRune(rune.clientId)
		end
	end

	catalogPanel.listCountLabel:setText(#shopState.filteredRunes .. ' / ' .. #shopState.runes .. ' ' .. tr('runes'))
	catalogPanel.emptyListLabel:setVisible(#shopState.filteredRunes == 0)
	applyCardSelection()
end

local function refreshCatalog()
	buildFilteredRunes()
	applyCategoryTabs()
	rebuildRuneCards()
	updateCheckout()
end

local function ensureValidSelection()
	if selectedRune() then
		return
	end

	local firstRune = shopState.filteredRunes[1] or shopState.runes[1]
	shopState.selectedClientId = firstRune and firstRune.clientId or 0
end

local function ensureValidQuantity()
	for _, quantity in ipairs(shopState.quantityOptions) do
		if quantity == shopState.selectedQuantity then
			return
		end
	end

	shopState.selectedQuantity = shopState.quantityOptions[1] or DEFAULT_QUANTITY_OPTIONS[1]
end

function selectRune(clientId)
	if not findRuneByClientId(clientId) then
		return
	end

	shopState.selectedClientId = clientId
	applyCardSelection()
	updateCheckout()
end

function selectQuantity(quantity)
	shopState.selectedQuantity = quantity
	for _, quantityButton in ipairs(runeShopWindow.checkoutPanel.quantityButtons:getChildren()) do
		quantityButton:setOn(quantityButton:getText() == formatNumber(quantity))
	end
	updateCheckout()
end

function selectCategory(categoryName)
	if not CATEGORY_DEFINITIONS[categoryName] then
		return
	end

	shopState.selectedCategory = categoryName
	refreshCatalog()
end

function onSearchChange(text)
	shopState.searchText = tostring(text or ''):lower()
	refreshCatalog()
end

function buySelectedRune()
	local rune = selectedRune()
	if not rune then
		return
	end

	local purchase = evaluatePurchase(rune)
	if describePurchaseBlocker(purchase) then
		return
	end

	shopState.purchasePending = true
	updateCheckout()
	sendToServer({
		action = 'buy',
		clientId = rune.clientId,
		quantity = purchase.quantity
	})
end

local function applyServerState(data)
	shopState.runes = data.runes or {}
	shopState.playerBalance = tonumber(data.playerBalance) or 0
	shopState.freeCapacity = tonumber(data.freeCapacity)
	shopState.quantityOptions = (data.quantities and #data.quantities > 0) and data.quantities or DEFAULT_QUANTITY_OPTIONS
	shopState.stackSize = tonumber(data.stackSize) or DEFAULT_STACK_SIZE
	shopState.deliveryContainerId = tonumber(data.deliveryContainerId) or DEFAULT_DELIVERY_CONTAINER_ID
	shopState.containerWeight = tonumber(data.containerWeight)
	shopState.purchasePending = false

	ensureValidQuantity()
	buildFilteredRunes()
	ensureValidSelection()
	applyHeaderStrip()
	rebuildQuantityButtons()
	refreshCatalog()
	show()
end

local function applyBuyResult(data)
	shopState.purchasePending = false
	shopState.playerBalance = tonumber(data.newBalance) or shopState.playerBalance
	shopState.freeCapacity = tonumber(data.freeCapacity) or shopState.freeCapacity

	applyHeaderStrip()
	updateCheckout()
	showStatusMessage(data.success ~= false, data.message)
end

local function onExtendedOpcode(protocol, opcode, buffer)
	if opcode ~= RUNESHOP_OPCODE then
		return
	end

	local decodedSuccessfully, data = pcall(function()
		return json.decode(buffer)
	end)

	if not decodedSuccessfully or not data then
		return
	end

	if data.action == 'data' then
		applyServerState(data)
		return
	end

	if data.action == 'buyResult' then
		applyBuyResult(data)
	end
end

function requestData()
	sendToServer({ action = 'request' })
end

function show()
	runeShopWindow:show()
	runeShopWindow:raise()
	runeShopWindow:focus()
end

function hide()
	runeShopWindow:hide()
	hideStatusMessage()
end

function toggle()
	if runeShopWindow:isVisible() then
		return hide()
	end

	requestData()
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(RUNESHOP_OPCODE, onExtendedOpcode)
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(RUNESHOP_OPCODE)
	hide()
	shopState = createShopState()
	runeShopWindow.catalogPanel.searchInput:setText('')
	refreshCatalog()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	shopState = createShopState()
	runeShopWindow = g_ui.displayUI('runeshop')
	runeShopWindow:hide()
	applyHeaderStrip()
	rebuildQuantityButtons()
	refreshCatalog()

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

	if runeShopWindow then
		runeShopWindow:destroy()
		runeShopWindow = nil
	end
end
