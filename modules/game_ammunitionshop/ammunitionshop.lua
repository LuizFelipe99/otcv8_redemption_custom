local AMMUNITION_SHOP_OPCODE = 12
local GOLD_COIN_CLIENT_ID = 3031
local DEFAULT_DELIVERY_CONTAINER_ID = 2854
local DEFAULT_CONTAINER_SLOTS = 20
local DEFAULT_STACK_SIZE = 100
local DEFAULT_QUANTITY_OPTIONS = { 1, 100, 300, 500, 1000 }
local STATUS_MESSAGE_DURATION = 5000

local CATEGORY_DEFINITIONS = {
	all = { buttonId = 'allTabButton', label = 'All', color = '#c0c0c0' },
	arrow = { buttonId = 'arrowTabButton', label = 'Arrows', color = '#6fd38a' },
	bolt = { buttonId = 'boltTabButton', label = 'Bolts', color = '#7ab8ff' },
	throwing = { buttonId = 'throwingTabButton', label = 'Throwing', color = '#ff8a5c' },
	equipment = { buttonId = 'equipmentTabButton', label = 'Equipment', color = '#d08cff' }
}

local CATEGORY_ORDER = { 'all', 'arrow', 'bolt', 'throwing', 'equipment' }

local ammunitionShopWindow
local statusMessageEvent
local shopState = {}

local function createShopState()
	return {
		ammunitions = {},
		filteredAmmunitions = {},
		playerBalance = 0,
		freeCapacity = nil,
		stackSize = DEFAULT_STACK_SIZE,
		deliveryContainerId = DEFAULT_DELIVERY_CONTAINER_ID,
		containerWeight = nil,
		selectedCategory = 'all',
		searchText = '',
		selectedClientId = 0,
		selectedQuantity = 0,
		purchasePending = false
	}
end

local function sendToServer(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(AMMUNITION_SHOP_OPCODE, json.encode(payload))
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

local function quantityOptionsOf(ammunition)
	if ammunition.quantities and #ammunition.quantities > 0 then
		return ammunition.quantities
	end

	return DEFAULT_QUANTITY_OPTIONS
end

local function findAmmunitionByClientId(clientId)
	for _, ammunition in ipairs(shopState.ammunitions) do
		if ammunition.clientId == clientId then
			return ammunition
		end
	end

	return nil
end

local function selectedAmmunition()
	return findAmmunitionByClientId(shopState.selectedClientId)
end

local function countAmmunitionsInCategory(categoryName)
	if categoryName == 'all' then
		return #shopState.ammunitions
	end

	local ammunitionCount = 0
	for _, ammunition in ipairs(shopState.ammunitions) do
		if ammunition.category == categoryName then
			ammunitionCount = ammunitionCount + 1
		end
	end

	return ammunitionCount
end

local function ammunitionMatchesFilters(ammunition)
	if shopState.selectedCategory ~= 'all' and ammunition.category ~= shopState.selectedCategory then
		return false
	end

	if shopState.searchText == '' then
		return true
	end

	local searchableText = (tostring(ammunition.itemName or '') .. ' ' .. tostring(ammunition.shortName or '')):lower()
	return searchableText:find(shopState.searchText, 1, true) ~= nil
end

local function buildFilteredAmmunitions()
	shopState.filteredAmmunitions = {}
	for _, ammunition in ipairs(shopState.ammunitions) do
		if ammunitionMatchesFilters(ammunition) then
			table.insert(shopState.filteredAmmunitions, ammunition)
		end
	end
end

local function calculateStackCount(quantity)
	return math.ceil(quantity / math.max(1, shopState.stackSize))
end

local function calculateRequiredWeight(ammunition, quantity)
	if not ammunition.weight then
		return nil
	end

	if not ammunition.deliverInBackpack then
		return ammunition.weight * quantity
	end

	if not shopState.containerWeight then
		return nil
	end

	return ammunition.weight * quantity + shopState.containerWeight
end

local function evaluatePurchase(ammunition)
	local quantity = shopState.selectedQuantity
	local totalPrice = ammunition.price * quantity
	local requiredWeight = calculateRequiredWeight(ammunition, quantity)
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

	if ammunitionShopWindow then
		ammunitionShopWindow.checkoutPanel.statusBanner:setText('')
	end
end

local function showStatusMessage(success, message)
	if not message or message == '' then
		return
	end

	hideStatusMessage()
	local statusBanner = ammunitionShopWindow.checkoutPanel.statusBanner
	statusBanner:setText(message)
	statusBanner:setColor(success and '#6fd38a' or '#ff7a6a')
	statusMessageEvent = scheduleEvent(function()
		statusMessageEvent = nil
		hideStatusMessage()
	end, STATUS_MESSAGE_DURATION)
end

local function applyHeaderStrip()
	local headerStrip = ammunitionShopWindow.headerStrip

	local balanceChip = headerStrip.balanceChip
	balanceChip.icon:setItemId(GOLD_COIN_CLIENT_ID)
	balanceChip.icon:setItemCount(100)
	balanceChip.icon:setShowCount(false)
	balanceChip.caption:setText(tr('Bank'))
	balanceChip.value:setText(formatNumber(shopState.playerBalance))
	balanceChip.value:setColor('#f0c060')
	balanceChip:setTooltip(tr('Purchases are paid with your bank balance.'))

	local capacityChip = headerStrip.capacityChip
	capacityChip.icon:setWidth(0)
	capacityChip.caption:setMarginLeft(5)
	capacityChip.caption:setText(tr('Free capacity'))
	capacityChip.value:setText(shopState.freeCapacity and formatOunces(shopState.freeCapacity) or '-')

	local deliveryChip = headerStrip.deliveryChip
	deliveryChip.icon:setItemId(shopState.deliveryContainerId)
	deliveryChip.caption:setText(tr('Ammo arrives in a backpack'))
	deliveryChip.value:setText('')
	deliveryChip:setTooltip(tr('Stackable ammunition arrives in a new backpack, in stacks of %d. Equipment goes straight to your inventory.', shopState.stackSize))
end

local function applyCategoryTabs()
	local tabBar = ammunitionShopWindow.tabBar
	for _, categoryName in ipairs(CATEGORY_ORDER) do
		local categoryDefinition = CATEGORY_DEFINITIONS[categoryName]
		local tabButton = tabBar[categoryDefinition.buttonId]
		tabButton:setText(tr(categoryDefinition.label) .. ' (' .. countAmmunitionsInCategory(categoryName) .. ')')
		tabButton:setOn(categoryName == shopState.selectedCategory)
	end
end

local function rebuildQuantityButtons(ammunition)
	local quantityButtons = ammunitionShopWindow.checkoutPanel.quantityButtons
	quantityButtons:destroyChildren()

	for _, quantity in ipairs(quantityOptionsOf(ammunition)) do
		local quantityButton = g_ui.createWidget('AmmoShopQuantityButton', quantityButtons)
		quantityButton.quantity = quantity
		quantityButton:setText(formatNumber(quantity))
		quantityButton:setOn(quantity == shopState.selectedQuantity)
		quantityButton.onClick = function()
			selectQuantity(quantity)
		end
	end
end

local function setCheckoutContentVisible(isVisible)
	local checkoutPanel = ammunitionShopWindow.checkoutPanel
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

local function applyDirectDeliveryCard(deliveryCard, ammunition, purchase)
	deliveryCard.containerIcon:setWidth(0)
	deliveryCard.itemIcon:setMarginLeft(0)
	deliveryCard.itemIcon:setItemCount(1)
	deliveryCard.title:setText(tr('%dx %s', purchase.quantity, capitalizeWords(ammunition.itemName)))
	deliveryCard.subtitle:setText(tr('Delivered straight to your inventory'))
end

local function applyBackpackDeliveryCard(deliveryCard, purchase)
	deliveryCard.containerIcon:setWidth(36)
	deliveryCard.containerIcon:setItemId(shopState.deliveryContainerId)
	deliveryCard.itemIcon:setMarginLeft(4)
	deliveryCard.itemIcon:setItemCount(math.min(purchase.quantity, shopState.stackSize))

	local stackLabel = purchase.stackCount == 1 and tr('stack') or tr('stacks')
	deliveryCard.title:setText(tr('1 backpack with %d %s of %d', purchase.stackCount, stackLabel, shopState.stackSize))
	deliveryCard.subtitle:setText(tr('Uses %d of %d backpack slots', purchase.stackCount, DEFAULT_CONTAINER_SLOTS))
end

local function applyDeliveryCard(ammunition, purchase)
	local deliveryCard = ammunitionShopWindow.checkoutPanel.deliveryCard
	deliveryCard.itemIcon:setItemId(ammunition.clientId)

	if not ammunition.deliverInBackpack then
		return applyDirectDeliveryCard(deliveryCard, ammunition, purchase)
	end

	applyBackpackDeliveryCard(deliveryCard, purchase)
end

local function applySummaryRows(ammunition, purchase)
	local checkoutPanel = ammunitionShopWindow.checkoutPanel

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
	weightRow:setTooltip(ammunition.deliverInBackpack and tr('Includes the backpack. Compared with your free capacity.') or tr('Compared with your free capacity.'))

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

local function applyCheckoutHeader(ammunition)
	local header = ammunitionShopWindow.checkoutPanel.header
	local categoryDefinition = CATEGORY_DEFINITIONS[ammunition.category]
	header.headerIcon:setItemId(ammunition.clientId)
	header.title:setText(capitalizeWords(ammunition.itemName))

	if not categoryDefinition then
		header.tag:setText(formatNumber(ammunition.price) .. ' ' .. tr('gold each'))
		header.tag:setColor('#9d9d9d')
		return
	end

	header.tag:setText(tr(categoryDefinition.label) .. '  |  ' .. formatNumber(ammunition.price) .. ' ' .. tr('gold each'))
	header.tag:setColor(categoryDefinition.color)
end

local function updateCheckout()
	local ammunition = selectedAmmunition()
	if not ammunition then
		setCheckoutContentVisible(false)
		return
	end

	setCheckoutContentVisible(true)
	applyCheckoutHeader(ammunition)

	local purchase = evaluatePurchase(ammunition)
	applyDeliveryCard(ammunition, purchase)
	applySummaryRows(ammunition, purchase)

	local purchaseBlocker = describePurchaseBlocker(purchase)
	local buyButton = ammunitionShopWindow.checkoutPanel.buyButton
	buyButton:setEnabled(purchaseBlocker == nil)
	buyButton:setText(purchaseBlocker or tr('Buy %s for %s gp', formatNumber(purchase.quantity), formatNumber(purchase.totalPrice)))
end

local function applyCardSelection()
	for _, card in ipairs(ammunitionShopWindow.catalogPanel.ammunitionCards:getChildren()) do
		card:setOn(card.ammunitionClientId == shopState.selectedClientId)
	end
end

local function rebuildAmmunitionCards()
	local catalogPanel = ammunitionShopWindow.catalogPanel
	local ammunitionCards = catalogPanel.ammunitionCards
	ammunitionCards:destroyChildren()

	for _, ammunition in ipairs(shopState.filteredAmmunitions) do
		local card = g_ui.createWidget('AmmoShopCard', ammunitionCards)
		card.ammunitionClientId = ammunition.clientId
		card.icon:setItemId(ammunition.clientId)
		card.name:setText(ammunition.shortName or capitalizeWords(ammunition.itemName))
		card.price:setText(formatNumber(ammunition.price) .. ' gp')
		card:setTooltip(capitalizeWords(ammunition.itemName))

		local categoryDefinition = CATEGORY_DEFINITIONS[ammunition.category]
		card.categoryAccent:setBackgroundColor(categoryDefinition and categoryDefinition.color or '#00000000')
		card.onClick = function()
			selectAmmunition(ammunition.clientId)
		end
	end

	catalogPanel.listCountLabel:setText(#shopState.filteredAmmunitions .. ' / ' .. #shopState.ammunitions .. ' ' .. tr('items'))
	catalogPanel.emptyListLabel:setVisible(#shopState.filteredAmmunitions == 0)
	applyCardSelection()
end

local function refreshCatalog()
	buildFilteredAmmunitions()
	applyCategoryTabs()
	rebuildAmmunitionCards()
	updateCheckout()
end

local function ensureValidQuantity(ammunition)
	local quantityOptions = quantityOptionsOf(ammunition)
	for _, quantity in ipairs(quantityOptions) do
		if quantity == shopState.selectedQuantity then
			return
		end
	end

	shopState.selectedQuantity = quantityOptions[1]
end

local function ensureValidSelection()
	if selectedAmmunition() then
		return
	end

	local firstAmmunition = shopState.filteredAmmunitions[1] or shopState.ammunitions[1]
	shopState.selectedClientId = firstAmmunition and firstAmmunition.clientId or 0
end

local function applySelectedAmmunition()
	local ammunition = selectedAmmunition()
	if not ammunition then
		ammunitionShopWindow.checkoutPanel.quantityButtons:destroyChildren()
		return
	end

	ensureValidQuantity(ammunition)
	rebuildQuantityButtons(ammunition)
end

function selectAmmunition(clientId)
	if not findAmmunitionByClientId(clientId) then
		return
	end

	shopState.selectedClientId = clientId
	applySelectedAmmunition()
	applyCardSelection()
	updateCheckout()
end

function selectQuantity(quantity)
	shopState.selectedQuantity = quantity
	for _, quantityButton in ipairs(ammunitionShopWindow.checkoutPanel.quantityButtons:getChildren()) do
		quantityButton:setOn(quantityButton.quantity == quantity)
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

function buySelectedAmmunition()
	local ammunition = selectedAmmunition()
	if not ammunition then
		return
	end

	local purchase = evaluatePurchase(ammunition)
	if describePurchaseBlocker(purchase) then
		return
	end

	shopState.purchasePending = true
	updateCheckout()
	sendToServer({
		action = 'buy',
		clientId = ammunition.clientId,
		quantity = purchase.quantity
	})
end

local function applyServerState(data)
	shopState.ammunitions = data.ammunitions or {}
	shopState.playerBalance = tonumber(data.playerBalance) or 0
	shopState.freeCapacity = tonumber(data.freeCapacity)
	shopState.stackSize = tonumber(data.stackSize) or DEFAULT_STACK_SIZE
	shopState.deliveryContainerId = tonumber(data.deliveryContainerId) or DEFAULT_DELIVERY_CONTAINER_ID
	shopState.containerWeight = tonumber(data.containerWeight)
	shopState.purchasePending = false

	buildFilteredAmmunitions()
	ensureValidSelection()
	applySelectedAmmunition()
	applyHeaderStrip()
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
	if opcode ~= AMMUNITION_SHOP_OPCODE then
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
	ammunitionShopWindow:show()
	ammunitionShopWindow:raise()
	ammunitionShopWindow:focus()
end

function hide()
	ammunitionShopWindow:hide()
	hideStatusMessage()
end

function toggle()
	if ammunitionShopWindow:isVisible() then
		return hide()
	end

	requestData()
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(AMMUNITION_SHOP_OPCODE, onExtendedOpcode)
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(AMMUNITION_SHOP_OPCODE)
	hide()
	shopState = createShopState()
	ammunitionShopWindow.catalogPanel.searchInput:setText('')
	applySelectedAmmunition()
	refreshCatalog()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	shopState = createShopState()
	ammunitionShopWindow = g_ui.displayUI('ammunitionshop')
	ammunitionShopWindow:hide()
	applyHeaderStrip()
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

	if ammunitionShopWindow then
		ammunitionShopWindow:destroy()
		ammunitionShopWindow = nil
	end
end
