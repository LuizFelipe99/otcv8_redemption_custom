local taskOpcode = 17

local difficultyFilterOptions = {
	{ label = 'All difficulties', value = 'all' },
	{ label = 'Easy', value = 'easy' },
	{ label = 'Medium', value = 'medium' },
	{ label = 'Hard', value = 'hard' }
}

local statusFilterOptions = {
	{ label = 'All', value = 'all' },
	{ label = 'Available', value = 'available' },
	{ label = 'In Progress', value = 'inProgress' },
	{ label = 'Completed', value = 'completed' }
}

local selectedDifficultyFilter = 'easy'
local selectedStatusFilter = 'all'

local window = nil
local selectedEntry = nil
local consoleEvent = nil
local cancelConfirmWindow = nil
local taskButton = nil
local tasksData = {}

local function hideAllActionButtons()
	window.finishButton:hide()
	window.startButton:hide()
	window.abortButton:hide()
end

local function sendOpcode(data)
	local protocolGame = g_game.getProtocolGame()
	if not protocolGame then
		return
	end

	protocolGame:sendExtendedOpcode(taskOpcode, json.encode(data))
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
		window.info:setText('')
	end, 5000)
end

local function requireSelectedEntry()
	if selectedEntry then
		return true
	end

	setTaskConsoleText("Please select a task from the list.", "red")
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

local function createTaskButton(task, taskState)
	local button = g_ui.createWidget("SelectionButton", window.taskListPanel.selectionList)
	button:setId(task.id)
	button.taskState = taskState
	button.taskDifficulty = task.difficulty
	button.creature:setOutfit(task.looktype)
	button.creature:getCreature():setStaticWalking(1000)
	button.name:setText(task.name)
	button.reward:setText('Reward: ' .. task.exp .. ' exp')

	if taskState == 'available' then
		button.kills:setText('Kills: ' .. task.kills)
		button.progress:setWidth(0)
		return button
	end

	if taskState == 'onCooldown' then
		button.kills:setText('Done - back tomorrow')
		button.progress:setWidth(button.progressEmpty:getWidth())
		return button
	end

	button.kills:setText('Kills: ' .. task.done .. '/' .. task.kills)
	local fullProgressWidth = button.progressEmpty:getWidth()
	button.progress:setWidth(fullProgressWidth * task.done / task.kills)
	return button
end

local function setupDifficultyFilter()
	local comboBox = window.listSearch.difficultyFilterComboBox
	comboBox:clearOptions()

	for _, option in ipairs(difficultyFilterOptions) do
		comboBox:addOption(option.label)
	end

	selectedDifficultyFilter = 'easy'
	comboBox:setCurrentOption('Easy')
	comboBox.onOptionChange = onDifficultyFilterChange
end

local function setupStatusFilter()
	local comboBox = window.listSearch.statusFilterComboBox
	comboBox:clearOptions()

	for _, option in ipairs(statusFilterOptions) do
		comboBox:addOption(option.label)
	end

	selectedStatusFilter = 'all'
	comboBox:setCurrentOption('All')
	comboBox.onOptionChange = onStatusFilterChange
end

function init()
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = destroy
	})

	window = g_ui.displayUI('tasks')
	window:setVisible(false)
	setupDifficultyFilter()
	setupStatusFilter()

	Keybind.new('Windows', 'show/hide Tasks Windows', 'Ctrl+A', '')
	Keybind.bind('Windows', 'show/hide Tasks Windows', {
		{
			type = KEY_DOWN,
			callback = toggleWindow
		}
	})

	g_keyboard.bindKeyDown('Escape', hideWindowOnEscape)
	taskButton = modules.client_topmenu.addLeftGameButton('taskButton', tr('Tasks'), '/modules/game_tasks_mission/images/taskIcon', toggleWindow)
	ProtocolGame.registerExtendedOpcode(taskOpcode, parseOpcode)
end

function terminate()
	disconnect(g_game, {
		onGameEnd = destroy
	})
	ProtocolGame.unregisterExtendedOpcode(taskOpcode)
	taskButton:destroy()
	destroy()
	Keybind.delete('Windows', 'show/hide Tasks Windows')
end

function onGameStart()
	if window then
		window:destroy()
		window = nil
	end

	window = g_ui.displayUI('tasks')
	window:setVisible(false)
	window.listSearch.search.onKeyPress = onFilterSearch
	setupDifficultyFilter()
	setupStatusFilter()
end

function destroy()
	if not window then
		return
	end

	window:destroy()
	window = nil
end

function parseOpcode(protocol, opcode, buffer)
	updateTasks(json.decode(buffer))
end

function onItemSelect(list, focusedChild, unfocusedChild, reason)
	if not focusedChild then
		return
	end

	selectedEntry = tonumber(focusedChild:getId())
	if not selectedEntry then
		return
	end

	hideAllActionButtons()

	if focusedChild.taskState == 'completed' then
		window.finishButton:show()
		return
	end

	if focusedChild.taskState == 'inProgress' then
		window.abortButton:show()
		return
	end

	if focusedChild.taskState == 'onCooldown' then
		return
	end

	window.startButton:show()
end

function onFilterSearch()
	addEvent(function()
		local searchText = window.listSearch.search:getText():lower():trim()
		local children = window.taskListPanel.selectionList:getChildren()

		for _, child in ipairs(children) do
			local matchesSearch = searchText:len() == 0 or child.name:getText():lower():find(searchText)
			local matchesDifficulty = selectedDifficultyFilter == 'all' or child.taskDifficulty == selectedDifficultyFilter
			local matchesStatus = selectedStatusFilter == 'all'
				or child.taskState == selectedStatusFilter
				or (selectedStatusFilter == 'completed' and child.taskState == 'onCooldown')

			if matchesSearch and matchesDifficulty and matchesStatus then
				child:show()
			else
				child:hide()
			end
		end
	end)
end

function onDifficultyFilterChange(comboBox, optionText)
	for _, option in ipairs(difficultyFilterOptions) do
		if option.label == optionText then
			selectedDifficultyFilter = option.value
		end
	end

	onFilterSearch()
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

	cancelConfirmWindow = displayGeneralBox(tr('Tasks'), tr("Do you really want to abort this task?"), {
		{ text = tr('Yes'), callback = onConfirm },
		{ text = tr('No'), callback = onDeny },
		anchor = AnchorHorizontalCenter
	}, onConfirm, onDeny)
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

	local selectionList = window.taskListPanel.selectionList
	selectionList.onChildFocusChange = onItemSelect
	selectionList:destroyChildren()
	hideAllActionButtons()

	local playerTaskIds = {}

	for _, task in ipairs(data['playerTasks']) do
		table.insert(playerTaskIds, task.id)
		local taskState = task.done >= task.kills and 'completed' or 'inProgress'
		createTaskButton(task, taskState)
	end

	for _, task in ipairs(data['allTasks']) do
		if not table.contains(playerTaskIds, task.id) then
			local taskState = task.onCooldownToday and 'onCooldown' or 'available'
			createTaskButton(task, taskState)
		end
	end

	local firstChild = selectionList:getFirstChild()
	selectionList:focusChild(firstChild)
	onFilterSearch()

	if firstChild then
		onItemSelect(selectionList, firstChild)
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

	window.detailTab:setVisible(false)
	window.listSearch:setVisible(true)
	window.taskListPanel:setVisible(true)
	window.toggleButton:setVisible(true)
	window.info:setVisible(true)

	local focused = window.taskListPanel.selectionList:getFocusedChild()
	if focused then
		onItemSelect(window.taskListPanel.selectionList, focused)
	end
end

function onTaskClick(widget)
	showTaskDetails(tonumber(widget:getId()))
end

function showTaskDetails(taskId)
	local task = findTaskById(taskId)
	if not task then
		return
	end

	local detailScene = window.detailTab.detailScene
	local statsBlock = window.detailTab.detailInfo.statsBlock
	local itemsBlock = window.detailTab.detailInfo.itemsBlock
	local statusBlock = window.detailTab.detailInfo.statusBlock

	detailScene.creatureName:setText(task.name)

	detailScene.creatureRow:destroyChildren()

	local monsterLooktypes = task.monsterLooktypes or { task.looktype }
	local creatureSize = 84
	local creatureSpacing = 20

	for _, monsterLooktype in ipairs(monsterLooktypes) do
		local creatureWidget = g_ui.createWidget('UICreature', detailScene.creatureRow)
		creatureWidget:setPhantom(true)
		creatureWidget:resize(creatureSize, creatureSize)
		creatureWidget:setOutfit(monsterLooktype)
		creatureWidget:getCreature():setStaticWalking(1000)
	end

	local creatureCount = #monsterLooktypes
	local rowWidth = (creatureCount * creatureSize) + ((creatureCount - 1) * creatureSpacing)
	detailScene.creatureRow:setWidth(rowWidth)

	if task.done then
		statsBlock.detailKills:setText("Kills: " .. task.done .. " / " .. task.kills)
	else
		statsBlock.detailKills:setText("Kills: " .. task.kills)
	end

	statsBlock.detailExp:setText("Experience: " .. task.exp)

	if task.onCooldownToday then
		statusBlock.detailStatus:setText("Already completed today")
		statusBlock.detailStatus:setColor('#ff5252')
	else
		statusBlock.detailStatus:setText("Available today")
		statusBlock.detailStatus:setColor('#00e676')
	end

	if task.monsterNames then
		statusBlock.detailMonsterNames:setText(table.concat(task.monsterNames, ", "))
	end

	itemsBlock.rewardItems:destroyChildren()

	if task.itemRewards and #task.itemRewards > 0 then
		itemsBlock.rewardTitle:setVisible(true)

		for _, item in ipairs(task.itemRewards) do
			local itemWidget = g_ui.createWidget('Item', itemsBlock.rewardItems)
			itemWidget:setItemId(item.clientId)
			itemWidget:setItemCount(item.count)
			itemWidget:setVirtual(true)

			if item.name then
				itemWidget:setTooltip(item.name .. " (" .. item.count .. "x)")
			end
		end
	else
		itemsBlock.rewardTitle:setVisible(false)
	end

	window.listSearch:setVisible(false)
	window.taskListPanel:setVisible(false)
	window.toggleButton:setVisible(false)
	hideAllActionButtons()
	window.info:setVisible(false)

	window.detailTab:setVisible(true)
end