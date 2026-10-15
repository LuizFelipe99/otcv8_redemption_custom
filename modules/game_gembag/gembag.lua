gemBagWindow = nil
gemBagButton = nil
gemBagSlots = {}

local gemBagOpcode = 18
local gemBagSlotCount = 9

local equipmentGroups = {
	{ groupId = 'helmetGroup', iconId = 'helmetSlotIcon', title = 'Helmet', itemId = 60938 },
	{ groupId = 'bodyGroup', iconId = 'bodySlotIcon', title = 'Armor', itemId = 60939 },
	{ groupId = 'weaponGroup', iconId = 'weaponSlotIcon', title = 'Weapon', itemId = 60941 }
}

local attributeDisplayOrder = { 'health', 'mana', 'critChance', 'critDamage', 'attackSpeed' }

local attributeDisplay = {
	health = { caption = 'Max health', icon = '/images/icons/icon_health', color = '#e06c6c', suffix = '' },
	mana = { caption = 'Max mana', icon = '/images/icons/icon_magic', color = '#6ca0e0', suffix = '' },
	critChance = { caption = 'Critical chance', icon = '/images/game/wheel/icon-crit', color = '#f0c060', suffix = '%' },
	critDamage = { caption = 'Critical damage', icon = '/images/icons/icon-damage', color = '#f08a4b', suffix = '%' },
	attackSpeed = { caption = 'Attack speed', icon = '/images/icons/icon_sword', color = '#6fd38a', suffix = '' }
}

local function formatNumber(number)
	local formattedNumber = tostring(math.floor(tonumber(number) or 0))
	local thousandsPattern = '^(-?%d+)(%d%d%d)'

	while true do
		local replacedNumber, replacementCount = formattedNumber:gsub(thousandsPattern, '%1,%2')
		formattedNumber = replacedNumber
		if replacementCount == 0 then
			return formattedNumber
		end
	end
end

local function formatAttributeValue(attribute, value)
	local display = attributeDisplay[attribute]
	local suffix = display and display.suffix or ''
	return '+' .. formatNumber(value) .. suffix
end

local function getAttributeCaption(attribute)
	local display = attributeDisplay[attribute]
	if display then
		return display.caption
	end

	return tostring(attribute)
end

local function getSlotWidgetByIndex(slotIndex)
	return gemBagSlots[slotIndex]
end

local function sendGemBagAction(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(gemBagOpcode, json.encode(payload))
end

local function requestSocketGem(slotIndex, itemId)
	sendGemBagAction({
		action = "socket",
		slotIndex = slotIndex,
		itemId = itemId
	})
end

local function requestUnsocketGem(slotIndex)
	sendGemBagAction({
		action = "unsocket",
		slotIndex = slotIndex
	})
end

local function buildSlotTooltip(slotDetails)
	if not slotDetails or not slotDetails.attribute then
		return tr('Right-click to remove this gem.')
	end

	local gemName = slotDetails.name or tr('Gem')
	local bonusText = formatAttributeValue(slotDetails.attribute, slotDetails.value) .. ' ' .. getAttributeCaption(slotDetails.attribute):lower()
	return gemName .. '\n' .. bonusText .. '\n' .. tr('Right-click to remove this gem.')
end

local function updateSlotVisual(slotIndex, itemId, slotDetails)
	local slotWidget = getSlotWidgetByIndex(slotIndex)
	if not slotWidget then
		return
	end

	local isSocketFilled = itemId ~= 0
	slotWidget.activeRing:setVisible(isSocketFilled)
	slotWidget.activeGlow:setVisible(isSocketFilled)
	slotWidget:setOn(isSocketFilled)

	if not isSocketFilled then
		slotWidget:setItemId(0)
		slotWidget:setTooltip(tr('Empty socket. Drag a gem here.'))
		return
	end

	slotWidget:setItemId(itemId)
	slotWidget:setTooltip(buildSlotTooltip(slotDetails))
end

local function sumBonusesByAttribute(slotDetailsList)
	local bonusTotalByAttribute = {}

	for _, slotDetails in ipairs(slotDetailsList) do
		if slotDetails.attribute then
			local currentTotal = bonusTotalByAttribute[slotDetails.attribute] or 0
			bonusTotalByAttribute[slotDetails.attribute] = currentTotal + (tonumber(slotDetails.value) or 0)
		end
	end

	return bonusTotalByAttribute
end

local function collectOrderedAttributes(bonusTotalByAttribute)
	local orderedAttributes = {}
	local alreadyListed = {}

	for _, attribute in ipairs(attributeDisplayOrder) do
		if bonusTotalByAttribute[attribute] then
			table.insert(orderedAttributes, attribute)
			alreadyListed[attribute] = true
		end
	end

	for attribute in pairs(bonusTotalByAttribute) do
		if not alreadyListed[attribute] then
			table.insert(orderedAttributes, attribute)
		end
	end

	return orderedAttributes
end

local function createBonusRow(bonusList, attribute, totalValue)
	local bonusRow = g_ui.createWidget('GemBonusRow', bonusList)
	local display = attributeDisplay[attribute]

	bonusRow.caption:setText(getAttributeCaption(attribute))
	bonusRow.value:setText(formatAttributeValue(attribute, totalValue))

	if not display then
		bonusRow.value:setColor('#dfdfdf')
		return
	end

	bonusRow.icon:setImageSource(display.icon)
	bonusRow.value:setColor(display.color)
end

local function countSocketedGems(slotItemIds)
	local socketedGemCount = 0

	for slotIndex = 0, gemBagSlotCount - 1 do
		if (slotItemIds[slotIndex + 1] or 0) ~= 0 then
			socketedGemCount = socketedGemCount + 1
		end
	end

	return socketedGemCount
end

local function updateSocketedCount(socketedGemCount)
	local bonusPanel = gemBagWindow.bonusPanel
	bonusPanel.socketedCountLabel:setText(tr('Gems socketed') .. ': ' .. socketedGemCount .. ' / ' .. gemBagSlotCount)
	bonusPanel.socketedProgress:setPercent(socketedGemCount * 100 / gemBagSlotCount)
end

local function showBonusMessage(message)
	local bonusPanel = gemBagWindow.bonusPanel
	bonusPanel.bonusList:destroyChildren()
	bonusPanel.emptyBonusLabel:setText(message)
	bonusPanel.emptyBonusLabel:setVisible(true)
end

local function updateBonusSummary(slotItemIds, slotDetailsList)
	local bonusPanel = gemBagWindow.bonusPanel
	local socketedGemCount = countSocketedGems(slotItemIds)

	bonusPanel.bonusHeader.title:setText(tr('Active bonuses'))
	updateSocketedCount(socketedGemCount)

	if socketedGemCount == 0 then
		showBonusMessage(tr('No gems socketed yet.\nDrag a gem onto a socket to start.'))
		return
	end

	if not slotDetailsList then
		showBonusMessage(tr('Your socketed gems are active.'))
		return
	end

	local bonusTotalByAttribute = sumBonusesByAttribute(slotDetailsList)
	local orderedAttributes = collectOrderedAttributes(bonusTotalByAttribute)

	if #orderedAttributes == 0 then
		showBonusMessage(tr('Your socketed gems are active.'))
		return
	end

	bonusPanel.emptyBonusLabel:setVisible(false)
	bonusPanel.bonusList:destroyChildren()

	for _, attribute in ipairs(orderedAttributes) do
		createBonusRow(bonusPanel.bonusList, attribute, bonusTotalByAttribute[attribute])
	end
end

local function onGemBagOpcode(protocol, opcode, buffer)
	if opcode ~= gemBagOpcode then
		return
	end

	local state = json.decode(buffer)
	if not state or not state.slots then
		return
	end

	local slotDetailsList = type(state.details) == 'table' and state.details or nil

	for slotIndex = 0, gemBagSlotCount - 1 do
		local slotDetails = slotDetailsList and slotDetailsList[slotIndex + 1] or nil
		updateSlotVisual(slotIndex, state.slots[slotIndex + 1] or 0, slotDetails)
	end

	updateBonusSummary(state.slots, slotDetailsList)
end

local function onGemSlotClick(slotIndex)
	local slotWidget = getSlotWidgetByIndex(slotIndex)
	if not slotWidget then
		return
	end

	if slotWidget:getItemId() == 0 then
		return
	end

	requestUnsocketGem(slotIndex)
end

function toggle()
	if gemBagWindow:isVisible() then
		gemBagWindow:hide()
		gemBagButton:setOn(false)
		return
	end

	gemBagWindow:show()
	gemBagWindow:raise()
	gemBagWindow:focus()
	gemBagButton:setOn(true)
end

local function createGemSlotDropHandler(slotIndex)
	return function(widget, droppedWidget, mousePosition)
		if not droppedWidget or not droppedWidget.currentDragThing then
			return false
		end

		local item = droppedWidget.currentDragThing
		requestSocketGem(slotIndex, item:getId())
		return true
	end
end

local function setupEquipmentGroups()
	for _, equipmentGroup in ipairs(equipmentGroups) do
		local groupPanel = gemBagWindow:recursiveGetChildById(equipmentGroup.groupId)
		if groupPanel then
			groupPanel.groupTitle:setText(tr(equipmentGroup.title))
		end

		local equipmentIcon = gemBagWindow:recursiveGetChildById(equipmentGroup.iconId)
		if equipmentIcon then
			equipmentIcon:setItemId(equipmentGroup.itemId)
		end
	end
end

local function setupGemSlots()
	for slotIndex = 0, gemBagSlotCount - 1 do
		local slotWidget = gemBagWindow:recursiveGetChildById('gemSlot' .. slotIndex)
		gemBagSlots[slotIndex] = slotWidget

		slotWidget.onDrop = createGemSlotDropHandler(slotIndex)

		slotWidget.onDragEnter = function(widget, mousePosition)
			UIDragIcon:raise()
			return false
		end

		slotWidget.onMouseRelease = function(widget, mousePosition, mouseButton)
			if mouseButton == MouseRightButton then
				onGemSlotClick(slotIndex)
			end
		end

		updateSlotVisual(slotIndex, 0, nil)
	end
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(gemBagOpcode)
	gemBagWindow:hide()
	gemBagButton:setOn(false)
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(gemBagOpcode, onGemBagOpcode)
end

function init()
	gemBagWindow = g_ui.displayUI('gembag')
	gemBagWindow:hide()

	setupEquipmentGroups()
	setupGemSlots()
	updateBonusSummary({}, nil)

	gemBagButton = modules.client_topmenu.addRightGameToggleButton('gemBagButton', tr('Gem Bag'), '/images/options/button_gembag', toggle)
	gemBagButton:setOn(false)

	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	if g_game.isOnline() then
		onGameStart()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	gemBagButton:destroy()
	gemBagWindow:destroy()
end
