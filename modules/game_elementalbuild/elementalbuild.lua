local ELEMENTALBUILD_OPCODE = 14
local DEFAULT_POINTS_CAP = 500
local DEFAULT_DAMAGE_RATIO = 1.0
local EMBLEM_PATH = '/game_cyclopedia/images/bestiary/icons/monster-icon-%s-resist'

local DEFAULT_ELEMENTS = {
	{ combatType = 0, key = 'physical', name = 'Physical', color = '#b8b6ad', description = 'Increases all physical damage from melee attacks and physical spells.' },
	{ combatType = 1, key = 'energy', name = 'Energy', color = '#5aa2ec', description = 'Increases damage from energy spells like Thunderstorm and Energy Beam.' },
	{ combatType = 2, key = 'earth', name = 'Earth', color = '#7fbf3a', description = 'Increases damage from earth spells like Stone Shower and Terra Strike.' },
	{ combatType = 3, key = 'fire', name = 'Fire', color = '#ec6a3c', description = 'Increases damage from fire spells like Great Fireball and Fire Wave.' },
	{ combatType = 9, key = 'ice', name = 'Ice', color = '#95c8f2', description = 'Increases damage from ice spells, runes and imbuements like Avalanche and Ice Wave.' },
	{ combatType = 10, key = 'holy', name = 'Holy', color = '#f2b23f', description = 'Increases damage from holy spells like Divine Missile and Holy Flash.' },
	{ combatType = 11, key = 'death', name = 'Death', color = '#9a93ec', description = 'Increases damage from death spells like Sudden Death and Death Strike.' }
}

local MISSION_STATE_APPEARANCE = {
	completed = { label = 'Completed', color = '#6fd38a', nodeImage = '/images/game/wheel/backdrop_skillwheel_socket_active', numberColor = '#6fd38a', lineColor = '#2f9e44' },
	current = { label = 'In progress', color = '#f0c060', nodeImage = '/images/game/wheel/backdrop_skillwheel_socket_active', numberColor = '#ffe7a8', lineColor = '#3a3a3a' },
	locked = { label = 'Locked', color = '#6a6a6a', nodeImage = '/images/game/wheel/backdrop_skillwheel_socket_inactive', numberColor = '#6a6a6a', lineColor = '#3a3a3a' }
}

local elementalBuildWindow

local elements = DEFAULT_ELEMENTS
local pointsCap = DEFAULT_POINTS_CAP
local damageRatio = DEFAULT_DAMAGE_RATIO
local availablePoints = 0
local investedPoints = {}
local pendingPoints = {}
local missions = {}
local selectedMissionId = nil
local activeTab = 'missions'

local function initializePointTables()
	investedPoints = {}
	pendingPoints = {}
	for _, element in ipairs(elements) do
		investedPoints[element.combatType] = 0
		pendingPoints[element.combatType] = 0
	end
end

local function sendToServer(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(ELEMENTALBUILD_OPCODE, json.encode(payload))
end

local function formatBonus(points)
	return '+' .. math.floor(points * damageRatio) .. '%'
end

local function totalPendingUsed()
	local total = 0
	for _, points in pairs(pendingPoints) do
		total = total + points
	end
	return total
end

local function hasPendingChanges()
	for combatType, points in pairs(pendingPoints) do
		if points ~= (investedPoints[combatType] or 0) then
			return true
		end
	end
	return false
end

local function findDefaultElement(combatType)
	for _, element in ipairs(DEFAULT_ELEMENTS) do
		if element.combatType == combatType then
			return element
		end
	end
	return nil
end

local function mergeServerElements(serverElements)
	if type(serverElements) ~= 'table' or #serverElements == 0 then
		return
	end

	local mergedElements = {}
	for _, serverElement in ipairs(serverElements) do
		local combatType = tonumber(serverElement.combatType)
		local defaultElement = findDefaultElement(combatType) or {}
		table.insert(mergedElements, {
			combatType = combatType,
			key = serverElement.key or defaultElement.key or 'physical',
			name = serverElement.name or defaultElement.name or tostring(combatType),
			color = serverElement.color or defaultElement.color or '#dfdfdf',
			description = serverElement.description or defaultElement.description or ''
		})
	end

	elements = mergedElements
end

local function applyServerRules(data)
	pointsCap = tonumber(data.pointsCap) or pointsCap
	damageRatio = tonumber(data.damageRatio) or damageRatio
	mergeServerElements(data.elements)
end

local function applyEmblem(emblemWidget, element)
	emblemWidget:setImageSource(string.format(EMBLEM_PATH, element.key))
end

local function rebuildOrbBar()
	local orbBar = elementalBuildWindow.orbBar
	orbBar:destroyChildren()

	local orbWidth = math.floor((orbBar:getWidth() - (#elements - 1) * 4) / #elements)
	for _, element in ipairs(elements) do
		local orb = g_ui.createWidget('ElementalOrb', orbBar)
		orb:setWidth(orbWidth)
		orb.elementCombatType = element.combatType
		applyEmblem(orb.emblem, element)
		orb.elementName:setText(element.name)
		orb.fillTrack.fill:setBackgroundColor(element.color)
		orb:setTooltip(element.description)
	end
end

local function updateOrbBar()
	for _, orb in ipairs(elementalBuildWindow.orbBar:getChildren()) do
		local element = nil
		for _, candidate in ipairs(elements) do
			if candidate.combatType == orb.elementCombatType then
				element = candidate
			end
		end

		local invested = investedPoints[orb.elementCombatType] or 0
		local hasBonus = invested > 0
		orb.bonus:setText(hasBonus and formatBonus(invested) or '0%')
		orb.bonus:setColor(hasBonus and element.color or '#666666')
		orb.elementName:setColor(hasBonus and '#dfdfdf' or '#8a8a8a')
		orb.fillTrack.fill:setWidth(math.floor(orb.fillTrack:getWidth() * math.min(invested, pointsCap) / pointsCap))
	end
end

local function updatePointsSummary()
	local buildTab = elementalBuildWindow.buildTab
	local used = totalPendingUsed()

	buildTab.availableSummary.caption:setText(tr('Available'))
	buildTab.availableSummary.value:setText(availablePoints - used)
	buildTab.usedSummary.caption:setText(tr('Allocated'))
	buildTab.usedSummary.value:setText(used)
	buildTab.capSummary.caption:setText(tr('Cap per element'))
	buildTab.capSummary.value:setText(pointsCap)

	local isDirty = hasPendingChanges()
	buildTab.applyButton:setEnabled(isDirty)
	buildTab.revertButton:setEnabled(isDirty)
	buildTab.pendingHint:setText(isDirty and tr('Unsaved changes - press Apply to confirm.') or '')
end

local function updateAttunementRow(rowWidget)
	local combatType = rowWidget.elementCombatType
	local pending = pendingPoints[combatType] or 0
	local invested = investedPoints[combatType] or 0
	local remainingPoints = availablePoints - totalPendingUsed()

	rowWidget.elementPoints:setText(pending .. ' / ' .. pointsCap)
	rowWidget.progressBarBg.progressBarFill:setWidth(math.floor(rowWidget.progressBarBg:getWidth() * math.min(pending, pointsCap) / pointsCap))

	if pending ~= invested then
		rowWidget.bonusPreview:setText(formatBonus(invested) .. ' -> ' .. formatBonus(pending))
		rowWidget.bonusPreview:setColor('#f0c060')
	else
		rowWidget.bonusPreview:setText(invested > 0 and formatBonus(invested) or '')
		rowWidget.bonusPreview:setColor('#9d9d9d')
	end

	local canIncrease = remainingPoints > 0 and pending < pointsCap
	local canDecrease = pending > 0
	rowWidget.increaseOne:setEnabled(canIncrease)
	rowWidget.increaseTen:setEnabled(canIncrease)
	rowWidget.decreaseOne:setEnabled(canDecrease)
	rowWidget.decreaseTen:setEnabled(canDecrease)
	rowWidget.emblemFrame:setImageSource(pending > 0 and '/images/game/wheel/backdrop_skillwheel_socket_active' or '/images/game/wheel/backdrop_skillwheel_socket_inactive')
end

local function refreshAllRows()
	if not elementalBuildWindow then
		return
	end

	for _, rowWidget in ipairs(elementalBuildWindow.buildTab.elementRows:getChildren()) do
		updateAttunementRow(rowWidget)
	end

	updatePointsSummary()
end

local function buildStepButtonHandler(combatType, stepAmount)
	return function(widget, mousePosition, mouseButton)
		if not widget:containsPoint(mousePosition) then
			return false
		end

		if mouseButton == MouseRightButton then
			return false
		end

		local amount = g_keyboard.isShiftPressed() and pointsCap or math.abs(stepAmount)
		if stepAmount > 0 then
			onAddPoints(combatType, amount)
			return true
		end

		onRemovePoints(combatType, amount)
		return true
	end
end

local function rebuildAttunementRows()
	local rowsContainer = elementalBuildWindow.buildTab.elementRows
	rowsContainer:destroyChildren()

	for _, element in ipairs(elements) do
		local rowWidget = g_ui.createWidget('AttunementRow', rowsContainer)
		rowWidget.elementCombatType = element.combatType

		applyEmblem(rowWidget.emblemFrame.emblem, element)
		rowWidget.elementName:setText(element.name)
		rowWidget.elementName:setColor(element.color)
		rowWidget.elementDescription:setText(element.description)
		rowWidget.elementDescription:setTooltip(element.description)
		rowWidget.progressBarBg.progressBarFill:setBackgroundColor(element.color)

		rowWidget.increaseOne.onMouseRelease = buildStepButtonHandler(element.combatType, 1)
		rowWidget.increaseTen.onMouseRelease = buildStepButtonHandler(element.combatType, 10)
		rowWidget.decreaseOne.onMouseRelease = buildStepButtonHandler(element.combatType, -1)
		rowWidget.decreaseTen.onMouseRelease = buildStepButtonHandler(element.combatType, -10)
	end

	refreshAllRows()
end

local function resolveMissionState(mission)
	if mission.completed then
		return 'completed'
	end

	if mission.isCurrent then
		return 'current'
	end

	return 'locked'
end

local function countDeliveredItems(mission)
	local metItemCount = 0
	for _, item in ipairs(mission.items or {}) do
		if item.progress >= item.total then
			metItemCount = metItemCount + 1
		end
	end
	return metItemCount
end

local function allMissionItemsMet(mission)
	return countDeliveredItems(mission) == #(mission.items or {})
end

local function findMissionById(missionId)
	for _, mission in ipairs(missions) do
		if mission.id == missionId then
			return mission
		end
	end
	return nil
end

local function findCurrentMission()
	for _, mission in ipairs(missions) do
		if mission.isCurrent then
			return mission
		end
	end
	return missions[#missions]
end

local function describeMissionState(mission, missionState)
	if missionState == 'current' then
		return tr('In progress') .. ' - ' .. countDeliveredItems(mission) .. '/' .. #(mission.items or {}) .. ' ' .. tr('items')
	end

	return tr(MISSION_STATE_APPEARANCE[missionState].label)
end

local function styleJourneyNode(nodeWidget, mission, isFirst, isLast)
	local missionState = resolveMissionState(mission)
	local appearance = MISSION_STATE_APPEARANCE[missionState]

	nodeWidget.node:setImageSource(appearance.nodeImage)
	nodeWidget.node.nodeNumber:setText(mission.id)
	nodeWidget.node.nodeNumber:setColor(appearance.numberColor)
	nodeWidget.node.nodeNumber:setVisible(missionState ~= 'completed')
	nodeWidget.node.nodeCheck:setVisible(missionState == 'completed')

	nodeWidget.missionName:setText(mission.name)
	nodeWidget.missionName:setColor(missionState == 'locked' and '#7a7a7a' or '#e8e8e8')
	nodeWidget.missionState:setText(describeMissionState(mission, missionState))
	nodeWidget.missionState:setColor(appearance.color)

	nodeWidget.lineTop:setVisible(not isFirst)
	nodeWidget.lineBottom:setVisible(not isLast)
	nodeWidget.lineTop:setBackgroundColor(missionState == 'locked' and '#3a3a3a' or '#2f9e44')
	nodeWidget.lineBottom:setBackgroundColor(appearance.lineColor)
end

local function fillRequiredItems(mission)
	local requiredItems = elementalBuildWindow.missionsTab.missionDetail.requiredItems
	requiredItems:destroyChildren()

	for _, item in ipairs(mission.items or {}) do
		local itemRow = g_ui.createWidget('RequiredItemRow', requiredItems)
		local isItemMet = item.progress >= item.total
		local progressColor = isItemMet and '#2f9e44' or '#c28400'

		itemRow.itemIcon:setItemId(item.clientId)
		itemRow.itemIcon:setTooltip(item.name)
		itemRow.itemName:setText(item.name)
		itemRow.itemProgress:setText(math.min(item.progress, item.total) .. ' / ' .. item.total)
		itemRow.itemProgress:setColor(isItemMet and '#6fd38a' or '#f0c060')
		itemRow.itemProgressBar:setPercent(item.total > 0 and math.min(100, item.progress * 100 / item.total) or 0)
		itemRow.itemProgressBar:setBackgroundColor(progressColor)
	end
end

local function showMissionDetail(mission)
	local missionDetail = elementalBuildWindow.missionsTab.missionDetail
	local missionState = resolveMissionState(mission)
	local appearance = MISSION_STATE_APPEARANCE[missionState]

	missionDetail.missionTitle:setText(mission.id .. '. ' .. mission.name)
	missionDetail.missionStatus:setText(tr(appearance.label))
	missionDetail.missionStatus:setColor(appearance.color)
	missionDetail.missionDescription:setText(mission.description or '')
	missionDetail.itemsHeader.title:setText(tr('Required items'))
	missionDetail.itemsHeader.detail:setText(countDeliveredItems(mission) .. ' / ' .. #(mission.items or {}))
	missionDetail.rewardLabel:setText(tr('Reward') .. ': +' .. mission.points .. ' ' .. (mission.points == 1 and tr('elemental point') or tr('elemental points')))
	fillRequiredItems(mission)

	local deliverButton = missionDetail.deliverButton
	if missionState == 'completed' then
		deliverButton:setText(tr('Completed'))
		deliverButton:setEnabled(false)
		return
	end

	if missionState == 'locked' then
		deliverButton:setText(tr('Locked'))
		deliverButton:setEnabled(false)
		return
	end

	local canDeliver = allMissionItemsMet(mission)
	deliverButton:setText(canDeliver and tr('Deliver') or tr('Missing items'))
	deliverButton:setEnabled(canDeliver)
end

local function onJourneyNodeFocus(list, focusedChild)
	if not focusedChild then
		return
	end

	local mission = findMissionById(focusedChild.missionId)
	if not mission then
		return
	end

	selectedMissionId = mission.id
	showMissionDetail(mission)
end

local function rebuildJourney()
	local missionRows = elementalBuildWindow.missionsTab.journeyPanel.missionRows
	missionRows.onChildFocusChange = nil
	missionRows:destroyChildren()

	local completedCount = 0
	for missionIndex, mission in ipairs(missions) do
		if mission.completed then
			completedCount = completedCount + 1
		end

		local nodeWidget = g_ui.createWidget('JourneyNode', missionRows)
		nodeWidget:setId('mission' .. mission.id)
		nodeWidget.missionId = mission.id
		styleJourneyNode(nodeWidget, mission, missionIndex == 1, missionIndex == #missions)
	end

	local journeyHeader = elementalBuildWindow.missionsTab.journeyPanel.journeyHeader
	journeyHeader.title:setText(tr('Journey'))
	journeyHeader.detail:setText(completedCount .. ' / ' .. #missions .. ' ' .. tr('completed'))

	missionRows.onChildFocusChange = onJourneyNodeFocus

	local missionToSelect = findMissionById(selectedMissionId) or findCurrentMission()
	if not missionToSelect then
		return
	end

	local nodeToFocus = missionRows:getChildById('mission' .. missionToSelect.id)
	missionRows:focusChild(nodeToFocus, ActiveFocusReason)
	missionRows:ensureChildVisible(nodeToFocus)
	onJourneyNodeFocus(missionRows, nodeToFocus)
end

function onAddPoints(combatType, amount)
	local current = pendingPoints[combatType] or 0
	local canAdd = math.min(amount, availablePoints - totalPendingUsed(), pointsCap - current)
	if canAdd <= 0 then
		return
	end

	pendingPoints[combatType] = current + canAdd
	refreshAllRows()
end

function onRemovePoints(combatType, amount)
	local current = pendingPoints[combatType] or 0
	local canRemove = math.min(amount, current)
	if canRemove <= 0 then
		return
	end

	pendingPoints[combatType] = current - canRemove
	refreshAllRows()
end

function onRevert()
	for combatType, points in pairs(investedPoints) do
		pendingPoints[combatType] = points
	end

	refreshAllRows()
end

function onApply()
	if not hasPendingChanges() then
		return
	end

	local payload = { action = 'invest', points = {} }
	for combatType, points in pairs(pendingPoints) do
		payload.points[tostring(combatType)] = points
	end

	sendToServer(payload)
end

function switchTab(tabName)
	activeTab = tabName

	elementalBuildWindow.missionsTab:setVisible(tabName == 'missions')
	elementalBuildWindow.buildTab:setVisible(tabName == 'build')
	elementalBuildWindow.tabBar.missionsTabButton:setOn(tabName == 'missions')
	elementalBuildWindow.tabBar.buildTabButton:setOn(tabName == 'build')
end

function onDeliverMission()
	local mission = findMissionById(selectedMissionId)
	if not mission or not mission.isCurrent or not allMissionItemsMet(mission) then
		return
	end

	sendToServer({ action = 'deliver', missionId = mission.id })
end

local function applyInvestedPoints(serverInvestedPoints)
	for combatTypeText, points in pairs(serverInvestedPoints or {}) do
		local combatType = tonumber(combatTypeText)
		investedPoints[combatType] = points
		pendingPoints[combatType] = points
	end
end

local function applyServerState(data)
	applyServerRules(data)
	initializePointTables()
	availablePoints = data.availablePoints or 0
	missions = data.missions or {}
	applyInvestedPoints(data.investedPoints)

	rebuildOrbBar()
	updateOrbBar()
	rebuildAttunementRows()
	rebuildJourney()

	elementalBuildWindow:show()
	elementalBuildWindow:raise()
	elementalBuildWindow:focus()
	switchTab(activeTab)
end

local function applyInvestResult(data)
	if not data.success then
		onRevert()
		return
	end

	availablePoints = data.availablePoints or availablePoints
	applyInvestedPoints(data.investedPoints)
	refreshAllRows()
	updateOrbBar()
end

local function applyMissionResult(data)
	if not data.success then
		return
	end

	availablePoints = data.availablePoints or availablePoints
	missions = data.missions or missions
	selectedMissionId = nil

	rebuildJourney()
	refreshAllRows()
end

local function onExtendedOpcode(protocol, opcode, buffer)
	if opcode ~= ELEMENTALBUILD_OPCODE then
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

	if data.action == 'investResult' then
		applyInvestResult(data)
		return
	end

	if data.action == 'missionResult' then
		applyMissionResult(data)
	end
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(ELEMENTALBUILD_OPCODE, onExtendedOpcode)
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(ELEMENTALBUILD_OPCODE)
	hide()
	elements = DEFAULT_ELEMENTS
	pointsCap = DEFAULT_POINTS_CAP
	damageRatio = DEFAULT_DAMAGE_RATIO
	availablePoints = 0
	missions = {}
	selectedMissionId = nil
	activeTab = 'missions'
	initializePointTables()
end

function show()
	elementalBuildWindow:show()
	elementalBuildWindow:raise()
	elementalBuildWindow:focus()
	sendToServer({ action = 'request' })
end

function hide()
	elementalBuildWindow:hide()
end

function toggle()
	if elementalBuildWindow:isVisible() then
		return hide()
	end

	show()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	initializePointTables()

	elementalBuildWindow = g_ui.displayUI('elementalbuild')
	elementalBuildWindow:hide()
	switchTab('missions')

	if g_game.isOnline() then
		onGameStart()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	if not elementalBuildWindow then
		return
	end

	elementalBuildWindow:destroy()
	elementalBuildWindow = nil
end
