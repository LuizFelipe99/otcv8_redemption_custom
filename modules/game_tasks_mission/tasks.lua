local taskOpcode = 17
local consoleMessageDurationMs = 5000
local imagesPath = '/modules/game_tasks_mission/images/'
local creatureFramebufferSize = 64
local creatureBoxFillRatio = 0.85
local maximumCreatureUpscale = 2

local difficultyDefinitions = {
	{ value = 'easy', label = 'Easy', badge = imagesPath .. 'difficulty_easy', tabId = 'tabEasy' },
	{ value = 'medium', label = 'Medium', badge = imagesPath .. 'difficulty_medium', tabId = 'tabMedium' },
	{ value = 'hard', label = 'Hard', badge = imagesPath .. 'difficulty_hard', tabId = 'tabHard' }
}

local statusFilterOptions = {
	{ label = 'All', value = 'all' },
	{ label = 'Available', value = 'available' },
	{ label = 'In Progress', value = 'inProgress' },
	{ label = 'Completed', value = 'completed' }
}

local taskStateAppearance = {
	available = { label = 'Available', detailLabel = 'Available', color = '#9d9d9d', barColor = '#c28400' },
	inProgress = { label = 'In progress', detailLabel = 'In progress', color = '#f0c060', barColor = '#c28400' },
	completed = { label = 'Ready to hand in', detailLabel = 'Ready to hand in', color = '#6fd38a', barColor = '#2f9e44' },
	onCooldown = { label = 'Done today', detailLabel = 'Completed today - available again tomorrow', color = '#707070', barColor = '#3d5a40' }
}

local selectedDifficultyFilter = 'all'
local selectedStatusFilter = 'all'

local window = nil
local selectedEntry = nil
local consoleEvent = nil
local cancelConfirmWindow = nil
local taskButton = nil
local tasksData = {}
local taskStateById = {}

local function sendOpcode(data)
	local protocolGame = g_game.getProtocolGame()
	if not protocolGame then
		return
	end

	protocolGame:sendExtendedOpcode(taskOpcode, json.encode(data))
end

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

local function findDifficultyDefinition(difficultyValue)
	for _, difficultyDefinition in ipairs(difficultyDefinitions) do
		if difficultyDefinition.value == difficultyValue then
			return difficultyDefinition
		end
	end

	return nil
end

local function getDifficultyLabel(difficultyValue)
	local difficultyDefinition = findDifficultyDefinition(difficultyValue)
	if difficultyDefinition then
		return difficultyDefinition.label
	end

	local fallbackLabel = tostring(difficultyValue or '')
	return fallbackLabel:sub(1, 1):upper() .. fallbackLabel:sub(2)
end

local function applyDifficultyBadge(badgeWidget, difficultyValue)
	local difficultyDefinition = findDifficultyDefinition(difficultyValue)
	if not difficultyDefinition then
		badgeWidget:setImageSource('')
		badgeWidget:resize(0, 20)
		return
	end

	badgeWidget:setImageSource(difficultyDefinition.badge)
	badgeWidget:resize(badgeWidget:getImageTextureWidth(), badgeWidget:getImageTextureHeight())
end

local function calculateCreatureDrawSize(creature, boxSize)
	local exactSpriteSize = creature:getExactSize(0, 0, 0, 0, 0)
	if not exactSpriteSize or exactSpriteSize <= 0 then
		return boxSize
	end

	local fillingDrawSize = math.floor(boxSize * creatureFramebufferSize * creatureBoxFillRatio / exactSpriteSize)
	return math.max(boxSize, math.min(fillingDrawSize, boxSize * maximumCreatureUpscale))
end

local function applyCreatureOutfit(creatureBox, outfit)
	if not outfit then
		return
	end

	local creatureWidget = creatureBox.creature
	creatureWidget:setOutfit(outfit)

	local creature = creatureWidget:getCreature()
	if not creature then
		return
	end

	creature:setStaticWalking(1000)

	local creatureDrawSize = calculateCreatureDrawSize(creature, creatureBox:getWidth())
	creatureWidget:resize(creatureDrawSize, creatureDrawSize)
end

local function setTaskConsoleText(text, color)
	if not window then
		return
	end

	window.info:setText(text)
	window.info:setColor(color or 'white')

	if consoleEvent then
		removeEvent(consoleEvent)
		consoleEvent = nil
	end

	consoleEvent = scheduleEvent(function()
		consoleEvent = nil
		if not window then
			return
		end
		window.info:setText('')
	end, consoleMessageDurationMs)
end

local function requireSelectedEntry()
	if selectedEntry then
		return true
	end

	setTaskConsoleText('Please select a task from the list.', 'red')
	return false
end

local function findTaskInList(taskList, taskId)
	if not taskList then
		return nil
	end

	for _, task in ipairs(taskList) do
		if task.id == taskId then
			return task
		end
	end

	return nil
end

local function findTaskById(taskId)
	return findTaskInList(tasksData.playerTasks, taskId) or findTaskInList(tasksData.allTasks, taskId)
end

local function getKillsDone(task, taskState)
	if taskState == 'onCooldown' then
		return task.kills
	end

	return math.min(task.done or 0, task.kills)
end

local function fillProgressBar(progressBar, task, taskState)
	local killsDone = getKillsDone(task, taskState)
	local progressPercent = task.kills > 0 and (killsDone * 100 / task.kills) or 0

	progressBar:setOn(true)
	progressBar:setPercent(progressPercent)
	progressBar:setBackgroundColor(taskStateAppearance[taskState].barColor)
	progressBar:setText(formatNumber(killsDone) .. ' / ' .. formatNumber(task.kills))
end

local function matchesSearchText(task, searchText)
	if searchText:len() == 0 then
		return true
	end

	if task.name:lower():find(searchText, 1, true) then
		return true
	end

	for _, monsterName in ipairs(task.monsterNames or {}) do
		if monsterName:lower():find(searchText, 1, true) then
			return true
		end
	end

	return false
end

local function matchesStatusFilter(taskState)
	if selectedStatusFilter == 'all' then
		return true
	end

	if selectedStatusFilter == 'completed' then
		return taskState == 'completed' or taskState == 'onCooldown'
	end

	return taskState == selectedStatusFilter
end

local function updateActionButtons(taskState)
	if not window then
		return
	end

	window.startButton:setEnabled(taskState == 'available')
	window.finishButton:setEnabled(taskState == 'completed')
	window.abortButton:setEnabled(taskState == 'inProgress')
end

local function clearTaskDetails()
	local detailPanel = window.detailPanel

	for _, child in ipairs(detailPanel:getChildren()) do
		child:setVisible(child:getId() == 'emptyDetailLabel')
	end

	updateActionButtons(nil)
end

local function showDetailWidgets()
	for _, child in ipairs(window.detailPanel:getChildren()) do
		child:setVisible(child:getId() ~= 'emptyDetailLabel')
	end
end

local function fillMonsterList(monsterList, task)
	monsterList:destroyChildren()

	local monsterNames = task.monsterNames or { task.name }
	local monsterLooktypes = task.monsterLooktypes or { task.looktype }

	for monsterIndex, monsterName in ipairs(monsterNames) do
		local monsterRow = g_ui.createWidget('TaskMonsterRow', monsterList)
		monsterRow.name:setText(monsterName)
		applyCreatureOutfit(monsterRow.creatureBox, monsterLooktypes[monsterIndex] or task.looktype)
	end
end

local function describeTokenReward(tokenReward)
	local rewardText = formatNumber(tokenReward.count) .. 'x ' .. (tokenReward.name or 'task token')
	if (tokenReward.chance or 0) >= 100 then
		return rewardText
	end

	return rewardText .. ' (' .. tokenReward.chance .. '%)'
end

local function addTokenRewardRow(rewardItemsPanel, tokenReward)
	if not tokenReward or (tokenReward.count or 0) <= 0 then
		return
	end

	local rewardRow = g_ui.createWidget('TaskRewardItemRow', rewardItemsPanel)
	rewardRow.item:setItemId(tokenReward.clientId or tokenReward.itemId)
	rewardRow.item:setItemCount(tokenReward.count)
	rewardRow.item:setVirtual(true)
	rewardRow.name:setText(describeTokenReward(tokenReward))
	rewardRow.name:setColor('#f0c060')
	rewardRow:setTooltip(tr('%d%% chance to receive this token when you hand in the task.', tokenReward.chance or 0))
end

local function fillRewardItems(rewardItemsPanel, task)
	rewardItemsPanel:destroyChildren()

	for _, itemReward in ipairs(task.itemRewards or {}) do
		local rewardRow = g_ui.createWidget('TaskRewardItemRow', rewardItemsPanel)
		rewardRow.item:setItemId(itemReward.clientId)
		rewardRow.item:setItemCount(itemReward.count)
		rewardRow.item:setVirtual(true)

		local itemName = itemReward.name or 'item'
		rewardRow.name:setText(formatNumber(itemReward.count) .. 'x ' .. itemName)
		rewardRow.item:setTooltip(itemName .. ' (' .. itemReward.count .. 'x)')
	end

	addTokenRewardRow(rewardItemsPanel, task.tokenReward)
end

function showTaskDetails(taskId)
	if not window then
		return
	end

	local task = findTaskById(taskId)
	if not task then
		clearTaskDetails()
		return
	end

	local taskState = taskStateById[task.id] or 'available'
	local detailPanel = window.detailPanel
	local monsterCount = #(task.monsterNames or { task.name })

	showDetailWidgets()

	detailPanel.titleBar.title:setText(task.name)
	detailPanel.name:setText(task.name)
	applyDifficultyBadge(detailPanel.difficultyBadge, task.difficulty)
	applyCreatureOutfit(detailPanel.creatureBox, task.looktype)

	local stateAppearance = taskStateAppearance[taskState]
	detailPanel.status:setText(getDifficultyLabel(task.difficulty) .. '  -  ' .. stateAppearance.detailLabel)
	detailPanel.status:setColor(stateAppearance.color)
	fillProgressBar(detailPanel.progress, task, taskState)

	detailPanel.monstersHeader.title:setText('Monsters (' .. monsterCount .. ')')
	fillMonsterList(detailPanel.monsterList, task)

	detailPanel.rewardsHeader.title:setText('Rewards')
	detailPanel.experienceReward:setText(formatNumber(task.exp) .. ' experience')
	fillRewardItems(detailPanel.rewardItems, task)

	updateActionButtons(taskState)
end

local function createTaskRow(task, taskState)
	local taskRow = g_ui.createWidget('TaskListRow', window.listPanel.selectionList)
	taskRow:setId(task.id)
	taskRow.taskId = task.id
	taskRow.taskState = taskState
	taskRow.taskDifficulty = task.difficulty
	taskRow.task = task

	taskRow.name:setText(task.name)
	applyCreatureOutfit(taskRow.creatureBox, task.looktype)
	applyDifficultyBadge(taskRow.difficultyBadge, task.difficulty)

	local stateAppearance = taskStateAppearance[taskState]
	taskRow.state:setText(stateAppearance.label)
	taskRow.state:setColor(stateAppearance.color)
	fillProgressBar(taskRow.progress, task, taskState)

	return taskRow
end

local function countTasksByDifficulty()
	local taskCountByDifficulty = { all = 0 }

	for _, task in ipairs(tasksData.allTasks or {}) do
		taskCountByDifficulty.all = taskCountByDifficulty.all + 1
		taskCountByDifficulty[task.difficulty] = (taskCountByDifficulty[task.difficulty] or 0) + 1
	end

	return taskCountByDifficulty
end

local function updateDifficultyTabs()
	if not window then
		return
	end

	local tabsPanel = window.difficultyTabs
	local taskCountByDifficulty = countTasksByDifficulty()

	tabsPanel.tabAll:setText('All tasks (' .. taskCountByDifficulty.all .. ')')
	tabsPanel.tabAll:setOn(selectedDifficultyFilter == 'all')

	for _, difficultyDefinition in ipairs(difficultyDefinitions) do
		local difficultyTab = tabsPanel[difficultyDefinition.tabId]
		local taskCount = taskCountByDifficulty[difficultyDefinition.value] or 0
		difficultyTab:setText(difficultyDefinition.label .. ' (' .. taskCount .. ')')
		difficultyTab:setOn(selectedDifficultyFilter == difficultyDefinition.value)
	end
end

local function updateSummaryBar()
	if not window then
		return
	end

	local readyTaskCount = 0
	local cooldownTaskCount = 0

	for _, taskState in pairs(taskStateById) do
		if taskState == 'completed' then
			readyTaskCount = readyTaskCount + 1
		elseif taskState == 'onCooldown' then
			cooldownTaskCount = cooldownTaskCount + 1
		end
	end

	local summaryBar = window.summaryBar
	summaryBar.activeSummary.caption:setText('Active tasks')
	summaryBar.activeSummary.value:setText(#(tasksData.playerTasks or {}))
	summaryBar.readySummary.caption:setText('Ready to hand in')
	summaryBar.readySummary.value:setText(readyTaskCount)
	summaryBar.cooldownSummary.caption:setText('Completed today')
	summaryBar.cooldownSummary.value:setText(cooldownTaskCount)
end

local function focusFirstVisibleRow()
	local selectionList = window.listPanel.selectionList

	for _, taskRow in ipairs(selectionList:getChildren()) do
		if taskRow:isVisible() then
			selectionList:focusChild(taskRow, ActiveFocusReason)
			return
		end
	end

	selectedEntry = nil
	clearTaskDetails()
end

local function applyListFilters()
	if not window then
		return
	end

	local searchText = window.listPanel.search:getText():lower():trim()
	local selectionList = window.listPanel.selectionList
	local visibleRowCount = 0

	for _, taskRow in ipairs(selectionList:getChildren()) do
		local matchesDifficulty = selectedDifficultyFilter == 'all' or taskRow.taskDifficulty == selectedDifficultyFilter
		local isRowVisible = matchesDifficulty and matchesStatusFilter(taskRow.taskState) and matchesSearchText(taskRow.task, searchText)
		taskRow:setVisible(isRowVisible)

		if isRowVisible then
			visibleRowCount = visibleRowCount + 1
		end
	end

	window.listPanel.emptyListLabel:setVisible(visibleRowCount == 0)

	local focusedRow = selectionList:getFocusedChild()
	if focusedRow and focusedRow:isVisible() then
		return
	end

	focusFirstVisibleRow()
end

local function setupStatusFilter()
	local comboBox = window.summaryBar.statusFilterComboBox
	comboBox:clearOptions()

	for _, option in ipairs(statusFilterOptions) do
		comboBox:addOption(option.label)
	end

	selectedStatusFilter = 'all'
	comboBox:setCurrentOption('All')
	comboBox.onOptionChange = onStatusFilterChange
end

local function createWindow()
	window = g_ui.displayUI('tasks')
	window:setVisible(false)
	window.listPanel.search.onTextChange = onFilterSearch
	window.listPanel.selectionList.onChildFocusChange = onItemSelect
	selectedDifficultyFilter = 'all'
	selectedEntry = nil
	setupStatusFilter()
	updateDifficultyTabs()
	updateSummaryBar()
	clearTaskDetails()
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = destroy
	})

	createWindow()

	g_keyboard.bindKeyDown('Escape', hideWindowOnEscape)
	taskButton = modules.client_topmenu.addLeftGameButton('taskButton', tr('Tasks'), imagesPath .. 'taskIcon', toggleWindow)
	ProtocolGame.registerExtendedOpcode(taskOpcode, parseOpcode)
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = destroy
	})
	ProtocolGame.unregisterExtendedOpcode(taskOpcode)
	g_keyboard.unbindKeyDown('Escape', hideWindowOnEscape)

	if taskButton then
		taskButton:destroy()
		taskButton = nil
	end

	destroy()
end

function onGameStart()
	destroy()
	createWindow()
end

function destroy()
	if consoleEvent then
		removeEvent(consoleEvent)
		consoleEvent = nil
	end

	if cancelConfirmWindow then
		cancelConfirmWindow:destroy()
		cancelConfirmWindow = nil
	end

	if not window then
		return
	end

	window:destroy()
	window = nil
	tasksData = {}
	taskStateById = {}
	selectedEntry = nil
end

function parseOpcode(protocol, opcode, buffer)
	updateTasks(json.decode(buffer))
end

function onItemSelect(list, focusedChild, unfocusedChild, reason)
	if not focusedChild then
		return
	end

	local focusedTaskId = tonumber(focusedChild:getId())
	if not focusedTaskId then
		return
	end

	selectedEntry = focusedTaskId
	showTaskDetails(focusedTaskId)
end

function onFilterSearch()
	addEvent(applyListFilters)
end

function onDifficultyTabClick(difficultyValue)
	selectedDifficultyFilter = difficultyValue
	updateDifficultyTabs()
	applyListFilters()
end

function onDifficultyFilterChange(comboBox, optionText)
	for _, difficultyDefinition in ipairs(difficultyDefinitions) do
		if difficultyDefinition.label == optionText then
			onDifficultyTabClick(difficultyDefinition.value)
			return
		end
	end

	onDifficultyTabClick('all')
end

function onStatusFilterChange(comboBox, optionText)
	for _, option in ipairs(statusFilterOptions) do
		if option.label == optionText then
			selectedStatusFilter = option.value
		end
	end

	onFilterSearch()
end

function start()
	if not requireSelectedEntry() then
		return
	end

	sendOpcode({ action = 'start', entry = selectedEntry })
end

function finish()
	if not requireSelectedEntry() then
		return
	end

	sendOpcode({ action = 'finish', entry = selectedEntry })
end

function abort()
	if not requireSelectedEntry() then
		return
	end

	if cancelConfirmWindow then
		cancelConfirmWindow:destroy()
		cancelConfirmWindow = nil
	end

	local abortedEntry = selectedEntry

	local function onConfirm()
		cancelConfirmWindow:destroy()
		cancelConfirmWindow = nil
		sendOpcode({ action = 'cancel', entry = abortedEntry })
	end

	local function onDeny()
		cancelConfirmWindow:destroy()
		cancelConfirmWindow = nil
	end

	cancelConfirmWindow = displayGeneralBox(tr('Tasks'), tr('Do you really want to abort this task?'), {
		{ text = tr('Yes'), callback = onConfirm },
		{ text = tr('No'), callback = onDeny },
		anchor = AnchorHorizontalCenter
	}, onConfirm, onDeny)
end

local function resolveAvailableTaskState(task)
	if task.onCooldownToday then
		return 'onCooldown'
	end

	return 'available'
end

local function resolvePlayerTaskState(task)
	if task.done >= task.kills then
		return 'completed'
	end

	return 'inProgress'
end

function updateTasks(data)
	if not window then
		return
	end

	if data['message'] then
		setTaskConsoleText(data['message'], data['color'])
		return
	end

	tasksData = data
	taskStateById = {}

	local previouslySelectedEntry = selectedEntry
	local selectionList = window.listPanel.selectionList
	selectionList.onChildFocusChange = nil
	selectionList:destroyChildren()

	local playerTaskIds = {}

	for _, task in ipairs(data['playerTasks'] or {}) do
		playerTaskIds[task.id] = true
		local taskState = resolvePlayerTaskState(task)
		taskStateById[task.id] = taskState
		createTaskRow(task, taskState)
	end

	for _, task in ipairs(data['allTasks'] or {}) do
		if not playerTaskIds[task.id] then
			local taskState = resolveAvailableTaskState(task)
			taskStateById[task.id] = taskState
			createTaskRow(task, taskState)
		end
	end

	selectionList.onChildFocusChange = onItemSelect
	updateDifficultyTabs()
	updateSummaryBar()

	local previouslySelectedRow = previouslySelectedEntry and selectionList:getChildById(tostring(previouslySelectedEntry))
	if previouslySelectedRow then
		selectionList:focusChild(previouslySelectedRow, ActiveFocusReason)
	end

	applyListFilters()

	local focusedRow = selectionList:getFocusedChild()
	if focusedRow then
		onItemSelect(selectionList, focusedRow)
	end
end

function toggleWindow()
	if not window then
		return
	end

	if not g_game.isOnline() then
		return
	end

	if window:isVisible() then
		sendOpcode({ action = 'hide' })
		window:setVisible(false)
		return
	end

	openMainModule()
	sendOpcode({ action = 'info' })
	window:setVisible(true)
	window:raise()
	window:focus()
end

function hideWindowOnEscape()
	if not window then
		return
	end

	if not g_game.isOnline() then
		return
	end

	if not window:isVisible() then
		return
	end

	sendOpcode({ action = 'hide' })
	window:setVisible(false)
end

function openMainModule()
	if not window then
		return
	end

	local focusedRow = window.listPanel.selectionList:getFocusedChild()
	if not focusedRow then
		return
	end

	onItemSelect(window.listPanel.selectionList, focusedRow)
end
