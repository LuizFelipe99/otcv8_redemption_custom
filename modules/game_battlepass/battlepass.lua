local BATTLEPASS_OPCODE = 10

local CURRENT_DAY_BORDER_COLOR  = "#c28400"
local CURRENT_DAY_BG_COLOR      = "#26200a"
local DEFAULT_DAY_BG_COLOR      = "#18162a"
local DEFAULT_DAY_BORDER_COLOR  = "#2e2b4a"
local SELECTED_DAY_BG_COLOR     = "#12213a"
local SELECTED_DAY_BORDER_COLOR = "#4a90d9"
local DONE_DAY_BG_COLOR         = "#0a2a0a"
local DONE_DAY_BORDER_COLOR     = "#3a9a3a"
local DONE_DAY_STATUS_COLOR     = "#5c5878"
local LOCKED_DAY_STATUS_COLOR   = "#585070"
local CURRENT_DAY_STATUS_COLOR  = "#c08000"
local PRO_REWARD_BORDER_COLOR   = "#6a4a00"
local FREE_REWARD_BORDER_COLOR  = "#1a4a1a"

local battlePassWindow
local battlePassButton

local seasonName        = "Season 1"
local dateRange         = "01/06/26 - 30/06/26"
local currentDay        = 1
local totalDays         = 14
local completedMissions = 0
local totalMissions     = 14
local progressPct       = 0
local freeProgress      = "0/14"
local proProgress       = "0/14"
local days              = {}
local selectedDayNumber = 1
local selectedDayLabel  = "DAY 1 (CURRENT)"
local missionItemId     = 0
local missionDescription = ""
local missionProgress   = ""
local freeRewards       = {}
local freeRewardStatus  = "Locked"
local proRewards        = {}
local proRewardStatus   = "Be VIP"
local dayStatusText     = "Collect the required items"
local finalRewardItemId = 0
local finalRewardLabel  = ""
local dayCounterText    = "1/14 Days"
local isVip             = false
local dayGridBuilt      = false

local function resetSessionState()
    seasonName          = "Season 1"
    dateRange           = "01/06/26 - 30/06/26"
    currentDay          = 1
    totalDays           = 14
    completedMissions   = 0
    totalMissions       = 14
    progressPct         = 0
    freeProgress        = "0/14"
    proProgress         = "0/14"
    days                = {}
    selectedDayNumber   = 1
    selectedDayLabel    = "DAY 1 (CURRENT)"
    missionItemId       = 0
    missionDescription  = ""
    missionProgress     = ""
    freeRewards         = {}
    freeRewardStatus    = "Locked"
    proRewards          = {}
    proRewardStatus     = "Be VIP"
    dayStatusText       = "Collect the required items"
    finalRewardItemId   = 0
    finalRewardLabel    = ""
    dayCounterText      = "1/14 Days"
    isVip               = false
    dayGridBuilt        = false
end

local function applyItemWidget(itemWidget, itemId)
    local hasItem = (itemId or 0) > 0
    itemWidget:setVisible(hasItem)
    if hasItem then
        itemWidget:setItemId(itemId)
    end
end

local function isSelectedDay(dayNumber)
    return tonumber(dayNumber) == tonumber(selectedDayNumber)
end

local function resolveDayCardColors(day)
    if isSelectedDay(day.number) then
        return SELECTED_DAY_BG_COLOR, SELECTED_DAY_BORDER_COLOR
    end
    if day.isCurrent then
        return CURRENT_DAY_BG_COLOR, CURRENT_DAY_BORDER_COLOR
    end
    if day.isDone then
        return DONE_DAY_BG_COLOR, DONE_DAY_BORDER_COLOR
    end
    return DEFAULT_DAY_BG_COLOR, DEFAULT_DAY_BORDER_COLOR
end

local function resolveDayStatusColor(day)
    if day.isDone    then return DONE_DAY_STATUS_COLOR    end
    if day.isCurrent then return CURRENT_DAY_STATUS_COLOR end
    return LOCKED_DAY_STATUS_COLOR
end

local function applyDayCardColors(dayWidget, day)
    local bgColor, borderColor = resolveDayCardColors(day)
    dayWidget:setBackgroundColor(bgColor)
    dayWidget:setBorderColor(borderColor)
    dayWidget.status:setColor(resolveDayStatusColor(day))
end

local function createDayCardWidget(day, gridContainer)
    local dayWidget = g_ui.createWidget("BattlePassDay", gridContainer)
    dayWidget.dayNumberValue = day.number
    dayWidget.isCurrent      = day.isCurrent
    dayWidget.isDone         = day.isDone

    dayWidget.dayNumber:setText("Day " .. day.number)
    dayWidget.status:setText(day.label or "")

    applyItemWidget(dayWidget.item, day.itemId)
    applyDayCardColors(dayWidget, day)

    dayWidget:setOn("current", day.isCurrent == true)
    dayWidget:setOn("done",    day.isDone    == true)
end

local function rebuildDayGrid()
    if not battlePassWindow then return end

    local gridContainer = battlePassWindow.leftPanel.dayScrollArea
    gridContainer:destroyChildren()

    for _, day in ipairs(days) do
        createDayCardWidget(day, gridContainer)
    end

    dayGridBuilt = true
end

local function updateDayGridColors()
    if not battlePassWindow then return end

    local gridContainer = battlePassWindow.leftPanel.dayScrollArea
    for _, dayWidget in pairs(gridContainer:getChildren()) do
        local day = {
            number    = dayWidget.dayNumberValue,
            isCurrent = dayWidget.isCurrent,
            isDone    = dayWidget.isDone,
        }
        applyDayCardColors(dayWidget, day)
    end
end

local function buildRewardItemWidget(reward, container, borderColor)
    local rewardWidget = g_ui.createWidget("BattlePassRewardItem", container)
    rewardWidget.icon:setItemId(reward.itemId)
    rewardWidget.icon:setBorderColor(borderColor)
    rewardWidget.qty:setText("x" .. reward.amount)
    rewardWidget.itemName:setText(reward.name or "")
end

local function rebuildProRewardItems()
    local container = battlePassWindow.rightPanel.proRewardBlock.proRewardItems
    container:destroyChildren()

    for _, reward in ipairs(proRewards) do
        buildRewardItemWidget(reward, container, PRO_REWARD_BORDER_COLOR)
    end
end

local function rebuildFreeRewardItems()
    local container = battlePassWindow.rightPanel.freeRewardBlock.freeRewardItems
    container:destroyChildren()

    for _, reward in ipairs(freeRewards) do
        buildRewardItemWidget(reward, container, FREE_REWARD_BORDER_COLOR)
    end
end

local function updateMissionPanel()
    local missionBar = battlePassWindow.leftPanel.missionBar
    missionBar.missionDayIndicator:setText("Day " .. selectedDayNumber)
    applyItemWidget(missionBar.missionItem, missionItemId)
    missionBar.missionDesc:setText(missionDescription)
    missionBar.missionProgress:setText(missionProgress)
end

local function updateRightPanel()
    local rightPanel = battlePassWindow.rightPanel
    rightPanel.detailHeader.detailDayLabel:setText(selectedDayLabel)
    rightPanel.proRewardBlock.proClaimButton:setText(proRewardStatus)
    rightPanel.freeRewardBlock.freeClaimButton:setText(freeRewardStatus)
    rightPanel.statusButton:setText(dayStatusText)
    rebuildProRewardItems()
    rebuildFreeRewardItems()
end

local function updateFooter()
    local footer = battlePassWindow.footer
    applyItemWidget(footer.finalItem, finalRewardItemId)
    footer.finalItemName:setText(finalRewardLabel)
    footer.dayCounterLabel:setText(dayCounterText)
end

local function updateHeaderAndProgress()
    battlePassWindow.subHeader.seasonLabel:setText(seasonName)
    battlePassWindow.subHeader.dayBadge:setText("Day " .. currentDay .. "/" .. totalDays)
    battlePassWindow.subHeader.dateLabel:setText(dateRange)
    battlePassWindow.progressRow.progressBar:setPercent(progressPct)
    battlePassWindow.progressRow.progressBar:setText(completedMissions .. "/" .. totalMissions .. " Missions")
    battlePassWindow.progressRow.progressSideLabel:setText("Free: " .. freeProgress .. "  |  Pro: " .. proProgress)
end

local function updateUI()
    if not battlePassWindow then return end

    updateHeaderAndProgress()

    if not dayGridBuilt then
        rebuildDayGrid()
    else
        updateDayGridColors()
    end

    updateMissionPanel()
    updateRightPanel()
    updateFooter()
end

local function applyServerState(data)
    seasonName          = data.seasonName          or seasonName
    dateRange           = data.dateRange           or dateRange
    currentDay          = data.currentDay          or currentDay
    totalDays           = data.totalDays           or totalDays
    completedMissions   = data.completedMissions   or completedMissions
    totalMissions       = data.totalMissions       or totalMissions
    progressPct         = data.progressPct         or progressPct
    freeProgress        = data.freeProgress        or freeProgress
    proProgress         = data.proProgress         or proProgress
    days                = data.days                or days
    selectedDayLabel    = data.selectedDayLabel    or selectedDayLabel
    missionItemId       = data.missionItemId       or missionItemId
    missionDescription  = data.missionDescription  or missionDescription
    missionProgress     = data.missionProgress     or missionProgress
    freeRewards         = data.freeRewards         or {}
    freeRewardStatus    = data.freeRewardStatus    or freeRewardStatus
    proRewards          = data.proRewards          or {}
    proRewardStatus     = data.proRewardStatus     or proRewardStatus
    dayStatusText       = data.dayStatusText       or dayStatusText
    finalRewardItemId   = data.finalRewardItemId   or finalRewardItemId
    finalRewardLabel    = data.finalRewardLabel    or finalRewardLabel
    dayCounterText      = data.dayCounterText      or dayCounterText
    isVip               = data.isVip

    updateUI()
end

local function sendToServer(payload)
    local protocol = g_game.getProtocolGame()
    if not protocol then return end
    protocol:sendExtendedOpcode(BATTLEPASS_OPCODE, json.encode(payload))
end

local function requestData()
    sendToServer({ action = "request" })
end

local function highlightSelectedDay()
    if not battlePassWindow then return end

    local gridContainer = battlePassWindow.leftPanel.dayScrollArea
    for _, dayWidget in pairs(gridContainer:getChildren()) do
        local day = {
            number    = dayWidget.dayNumberValue,
            isCurrent = dayWidget.isCurrent,
            isDone    = dayWidget.isDone,
        }
        applyDayCardColors(dayWidget, day)
    end
end

function onDayClicked(dayWidget)
    selectedDayNumber = dayWidget.dayNumberValue
    highlightSelectedDay()

    sendToServer({
        action = "request",
        day    = dayWidget.dayNumberValue
    })
end

function claimFreeReward()
    sendToServer({ action = "deliver" })
end

function claimProReward()
    sendToServer({ action = "deliverPro" })
end

function onStatusAction()
    if proRewardStatus == "Claim" then
        sendToServer({ action = "deliverPro" })
        return
    end
    sendToServer({ action = "deliver" })
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= BATTLEPASS_OPCODE then return end

    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then return end
    if data.action ~= "data" then return end

    applyServerState(data)
end

function show()
    battlePassWindow:show()
    battlePassWindow:raise()
    battlePassWindow:focus()

    if battlePassButton then
        battlePassButton:setOn(true)
    end

    requestData()
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

local function onGameStart()
    ProtocolGame.registerExtendedOpcode(BATTLEPASS_OPCODE, onExtendedOpcode)

    if battlePassButton then return end

    battlePassButton = modules.game_mainpanel.addToggleButton(
        "battlePassButton",
        tr("Battle Pass"),
        "/images/options/battle_pass",
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
        onGameEnd   = onGameEnd
    })

    battlePassWindow = g_ui.displayUI("battlepass")
    battlePassWindow:hide()

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd   = onGameEnd
    })

    if battlePassButton then
        battlePassButton:destroy()
        battlePassButton = nil
    end

    if battlePassWindow then
        battlePassWindow:destroy()
    end
end