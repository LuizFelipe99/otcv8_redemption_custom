local BATTLEPASS_OPCODE = 10

local DAY_CARD_STYLE = {
	selected = { background = '#c2840030', border = '#ffd27a', borderWidth = 2 },
	current = { background = '#00000055', border = '#f0c060', borderWidth = 2 },
	done = { background = '#00000055', border = '#2f9e44', borderWidth = 1 },
	locked = { background = '#00000055', border = '#3a3a3a', borderWidth = 1 }
}

local DAY_STATE_LABEL = {
	current = { text = 'Current', color = '#f0c060', icon = '' },
	done = { text = 'Done', color = '#6fd38a', icon = '/images/game/wheel/icon-socketed' },
	locked = { text = 'Locked', color = '#707070', icon = '/images/game/wheel/icon-locked' }
}

local TRACK_APPEARANCE = {
	pro = { title = 'PRO', accent = '#c28400', titleColor = '#f0c060' },
	free = { title = 'FREE', accent = '#2f9e44', titleColor = '#6fd38a' }
}

local battlePassWindow
local battlePassButton
local battlePassState
local selectedDayNumber

local function resetSessionState()
	battlePassState = nil
	selectedDayNumber = nil
end

local function sendToServer(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(BATTLEPASS_OPCODE, json.encode(payload))
end

local function applyItemWidget(itemWidget, itemId)
	local hasItem = (tonumber(itemId) or 0) > 0
	itemWidget:setVisible(hasItem)
	if not hasItem then
		return
	end

	itemWidget:setItemId(itemId)
end

local function resolveDayState(day)
	if day.isDone then
		return 'done'
	end

	if day.isCurrent then
		return 'current'
	end

	return 'locked'
end

local function findDay(dayNumber)
	for _, day in ipairs(battlePassState.days or {}) do
		if tonumber(day.number) == tonumber(dayNumber) then
			return day
		end
	end

	return nil
end

local function parseProgressFraction(progressText)
	local ownedText, requiredText = tostring(progressText or ''):match('(%d+)%s*/%s*(%d+)')
	return tonumber(ownedText), tonumber(requiredText)
end

local function resolveMissionProgress()
	local ownedAmount = tonumber(battlePassState.missionItemCount)
	local requiredAmount = tonumber(battlePassState.missionAmount)

	if not ownedAmount or not requiredAmount then
		ownedAmount, requiredAmount = parseProgressFraction(battlePassState.missionProgress)
	end

	if not ownedAmount or not requiredAmount or requiredAmount <= 0 then
		return 0
	end

	return math.min(100, ownedAmount * 100 / requiredAmount)
end

local function canDeliverFreeReward()
	if battlePassState.canDeliver ~= nil then
		return battlePassState.canDeliver == true
	end

	return battlePassState.freeRewardStatus == 'Deliver'
end

local function canClaimProReward()
	if battlePassState.canClaimPro ~= nil then
		return battlePassState.canClaimPro == true
	end

	return battlePassState.proRewardStatus == 'Claim'
end

local function resolvePrimaryAction()
	if battlePassState.primaryAction then
		return battlePassState.primaryAction
	end

	if canClaimProReward() then
		return 'deliverPro'
	end

	if canDeliverFreeReward() then
		return 'deliver'
	end

	return nil
end

local function styleDayCard(dayCard, day)
	local dayState = resolveDayState(day)
	local isSelected = tonumber(day.number) == tonumber(selectedDayNumber)
	local cardStyle = isSelected and DAY_CARD_STYLE.selected or DAY_CARD_STYLE[dayState]
	local stateLabel = DAY_STATE_LABEL[dayState]

	dayCard:setBackgroundColor(cardStyle.background)
	dayCard:setBorderColor(cardStyle.border)
	dayCard:setBorderWidth(cardStyle.borderWidth)

	dayCard.status:setText(stateLabel.text)
	dayCard.status:setColor(stateLabel.color)
	dayCard.item:setOpacity(dayState == 'locked' and 0.55 or 1)

	local hasStateIcon = stateLabel.icon ~= ''
	dayCard.stateIcon:setVisible(hasStateIcon)
	dayCard.status:setMarginLeft(hasStateIcon and 8 or 0)
	if not hasStateIcon then
		return
	end

	dayCard.stateIcon:setImageSource(stateLabel.icon)
	dayCard.stateIcon:resize(dayCard.stateIcon:getImageTextureWidth(), dayCard.stateIcon:getImageTextureHeight())
end

local function rebuildDayGrid()
	local dayGrid = battlePassWindow.leftPanel.dayScrollArea
	dayGrid:destroyChildren()

	for _, day in ipairs(battlePassState.days or {}) do
		local dayCard = g_ui.createWidget('BattlePassDayCard', dayGrid)
		dayCard.dayNumberValue = tonumber(day.number)
		dayCard.dayNumber:setText(tr('Day') .. ' ' .. day.number)
		applyItemWidget(dayCard.item, day.itemId)
		styleDayCard(dayCard, day)
	end
end

local function restyleDayGrid()
	for _, dayCard in ipairs(battlePassWindow.leftPanel.dayScrollArea:getChildren()) do
		local day = findDay(dayCard.dayNumberValue)
		if day then
			styleDayCard(dayCard, day)
		end
	end
end

local function updateHeader()
	local headerBar = battlePassWindow.headerBar
	local isVip = battlePassState.isVip == true

	headerBar.seasonLabel:setText(battlePassState.seasonName or '')
	headerBar.dateLabel:setText(battlePassState.dateRange or '')
	headerBar.passBadge.passBadgeLabel:setText(isVip and 'PRO' or 'FREE')
	headerBar.passBadge.passBadgeLabel:setColor(isVip and '#ffd27a' or '#dfdfdf')
	headerBar.passHint:setText(isVip and tr('Battle Pass PRO active') or tr('Use a PRO scroll to unlock PRO rewards'))

	local progressRow = battlePassWindow.progressRow
	local completedMissions = tonumber(battlePassState.completedMissions) or 0
	local totalMissions = tonumber(battlePassState.totalMissions) or 0
	progressRow.progressBar:setPercent(tonumber(battlePassState.progressPct) or 0)
	progressRow.progressBar:setText(completedMissions .. ' / ' .. totalMissions .. ' ' .. tr('days completed'))
	progressRow.dayCounterLabel:setText(tr('Day') .. ' ' .. (battlePassState.currentDay or 0) .. ' / ' .. (battlePassState.totalDays or 0))

	battlePassWindow.leftPanel.daysHeader.title:setText(tr('Daily missions'))
	battlePassWindow.leftPanel.daysHeader.detail:setText(completedMissions .. ' / ' .. totalMissions)
end

local function updateMissionPanel()
	local missionPanel = battlePassWindow.leftPanel.missionPanel
	local selectedDay = findDay(selectedDayNumber)
	local isDayDone = selectedDay and selectedDay.isDone == true

	missionPanel.missionTitle:setText(tr('Mission'))
	missionPanel.missionDayIndicator:setText(tr('Day') .. ' ' .. tostring(selectedDayNumber or ''))
	applyItemWidget(missionPanel.missionItem, battlePassState.missionItemId)
	missionPanel.missionDesc:setText(battlePassState.missionDescription or '')

	local progressBar = missionPanel.missionProgressBar
	progressBar:setPercent(isDayDone and 100 or resolveMissionProgress())
	progressBar:setText(isDayDone and tr('Completed') or (battlePassState.missionProgress or ''))
end

local function fillRewardList(rewardList, rewards)
	rewardList:destroyChildren()

	for _, reward in ipairs(rewards or {}) do
		local rewardRow = g_ui.createWidget('BattlePassRewardRow', rewardList)
		rewardRow.icon:setItemId(reward.itemId)
		rewardRow.icon:setItemCount(reward.amount)
		rewardRow.amount:setText('x' .. tostring(reward.amount))
		rewardRow.itemName:setText(reward.name or '')
		rewardRow.icon:setTooltip(tostring(reward.amount) .. 'x ' .. (reward.name or ''))
	end
end

local function updateTrack(track, appearance, hintText, rewards, buttonText, isButtonEnabled)
	track.accent:setBackgroundColor(appearance.accent)
	track.trackTitle:setText(appearance.title)
	track.trackTitle:setColor(appearance.titleColor)
	track.trackHint:setText(hintText)
	fillRewardList(track.rewardList, rewards)
	track.claimButton:setText(buttonText or '')
	track.claimButton:setEnabled(isButtonEnabled)
end

local function updateDetailPanel()
	local rightPanel = battlePassWindow.rightPanel
	local selectedDay = findDay(selectedDayNumber)
	local dayState = selectedDay and resolveDayState(selectedDay) or 'locked'
	local stateLabel = DAY_STATE_LABEL[dayState]
	local isVip = battlePassState.isVip == true

	rightPanel.detailHeader.title:setText(tr('Day') .. ' ' .. tostring(selectedDayNumber or '') .. ' ' .. tr('rewards'))
	rightPanel.detailHeader.detail:setText(stateLabel.text)
	rightPanel.detailHeader.detail:setColor(stateLabel.color)

	updateTrack(rightPanel.proTrack, TRACK_APPEARANCE.pro, isVip and tr('Active') or tr('VIP only'), battlePassState.proRewards, battlePassState.proRewardStatus, canClaimProReward())
	updateTrack(rightPanel.freeTrack, TRACK_APPEARANCE.free, tr('For everyone'), battlePassState.freeRewards, battlePassState.freeRewardStatus, canDeliverFreeReward())

	rightPanel.dayStatusLabel:setText(battlePassState.dayStatusText or '')
	rightPanel.dayStatusLabel:setVisible(resolvePrimaryAction() == nil)
end

local function updateFooter()
	local footer = battlePassWindow.footer
	applyItemWidget(footer.finalRewardFrame.finalItem, battlePassState.finalRewardItemId)
	footer.finalRewardFrame.finalItemName:setText(battlePassState.finalRewardLabel or '')

	local primaryAction = resolvePrimaryAction()
	local primaryActionButton = footer.primaryActionButton
	primaryActionButton:setEnabled(primaryAction ~= nil)

	if primaryAction == 'deliverPro' then
		primaryActionButton:setText(tr('Claim PRO reward'))
		return
	end

	if primaryAction == 'deliver' then
		primaryActionButton:setText(tr('Deliver items'))
		return
	end

	primaryActionButton:setText(tr('Nothing to claim'))
end

local function showLoadingState()
	if not battlePassWindow then
		return
	end

	battlePassWindow.headerBar.seasonLabel:setText(tr('Loading season...'))
	battlePassWindow.headerBar.dateLabel:setText('')
	battlePassWindow.footer.primaryActionButton:setEnabled(false)
	battlePassWindow.footer.primaryActionButton:setText(tr('Nothing to claim'))
end

local function updateUI(shouldRebuildGrid)
	if not battlePassWindow or not battlePassState then
		return
	end

	updateHeader()

	if shouldRebuildGrid then
		rebuildDayGrid()
	else
		restyleDayGrid()
	end

	updateMissionPanel()
	updateDetailPanel()
	updateFooter()
end

local function applyServerState(data)
	battlePassState = data
	selectedDayNumber = tonumber(data.selectedDay) or selectedDayNumber or tonumber(data.currentDay)
	updateUI(true)
end

local function onExtendedOpcode(protocol, opcode, buffer)
	if opcode ~= BATTLEPASS_OPCODE then
		return
	end

	local decodedSuccessfully, data = pcall(function()
		return json.decode(buffer)
	end)

	if not decodedSuccessfully or not data then
		return
	end

	if data.action ~= 'data' then
		return
	end

	applyServerState(data)
end

function onDayClicked(dayCard)
	if not battlePassState then
		return
	end

	selectedDayNumber = dayCard.dayNumberValue
	restyleDayGrid()
	sendToServer({ action = 'request', day = dayCard.dayNumberValue })
end

function claimFreeReward()
	if not battlePassState or not canDeliverFreeReward() then
		return
	end

	sendToServer({ action = 'deliver' })
end

function claimProReward()
	if not battlePassState or not canClaimProReward() then
		return
	end

	sendToServer({ action = 'deliverPro' })
end

function onStatusAction()
	if not battlePassState then
		return
	end

	local primaryAction = resolvePrimaryAction()
	if not primaryAction then
		return
	end

	sendToServer({ action = primaryAction })
end

function show()
	battlePassWindow:show()
	battlePassWindow:raise()
	battlePassWindow:focus()

	if battlePassButton then
		battlePassButton:setOn(true)
	end

	if not battlePassState then
		showLoadingState()
	end

	sendToServer({ action = 'request', day = selectedDayNumber })
end

function hide()
	battlePassWindow:hide()

	if battlePassButton then
		battlePassButton:setOn(false)
	end
end

function toggle()
	if battlePassWindow:isVisible() then
		return hide()
	end

	show()
end

local function setupTracks()
	local rightPanel = battlePassWindow.rightPanel
	rightPanel.proTrack.claimButton.onClick = claimProReward
	rightPanel.freeTrack.claimButton.onClick = claimFreeReward
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(BATTLEPASS_OPCODE, onExtendedOpcode)

	if battlePassButton then
		return
	end

	battlePassButton = modules.game_mainpanel.addToggleButton(
		'battlePassButton',
		tr('Battle Pass'),
		'/images/options/battle_pass',
		toggle,
		false,
		1007
	)
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(BATTLEPASS_OPCODE)
	hide()
	resetSessionState()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	battlePassWindow = g_ui.displayUI('battlepass')
	battlePassWindow:hide()
	setupTracks()
	showLoadingState()

	if g_game.isOnline() then
		onGameStart()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd
	})

	if battlePassButton then
		battlePassButton:destroy()
		battlePassButton = nil
	end

	if battlePassWindow then
		battlePassWindow:destroy()
		battlePassWindow = nil
	end
end
