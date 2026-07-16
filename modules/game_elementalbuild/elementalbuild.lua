local ELEMENTALBUILD_OPCODE = 14
local ELEMENTAL_BUILD_CAP   = 500

local ELEMENTAL_TYPES = {
    { combatType = 0,  name = "Physical", color = "#888780", summaryId = "physicalSummary", bonusLabelId = "physicalBonus", description = "Increases all physical damage from melee attacks and physical spells." },
    { combatType = 1,  name = "Energy",   color = "#378ADD", summaryId = "energySummary",   bonusLabelId = "energyBonus",   description = "Increases damage from energy spells like Thunderstorm and Energy Beam." },
    { combatType = 2,  name = "Earth",    color = "#639922", summaryId = "earthSummary",    bonusLabelId = "earthBonus",    description = "Increases damage from earth spells like Stone Shower and Terra Strike." },
    { combatType = 3,  name = "Fire",     color = "#D85A30", summaryId = "fireSummary",     bonusLabelId = "fireBonus",     description = "Increases damage from fire spells like Great Fireball and Fire Wave." },
    { combatType = 9,  name = "Ice",      color = "#85B7EB", summaryId = "iceSummary",      bonusLabelId = "iceBonus",      description = "Increases damage from ice spells, runes and imbuements like Avalanche and Ice Wave." },
    { combatType = 10, name = "Holy",     color = "#EF9F27", summaryId = "holySummary",     bonusLabelId = "holyBonus",     description = "Increases damage from holy spells like Divine Missile and Holy Flash." },
    { combatType = 11, name = "Death",    color = "#7F77DD", summaryId = "deathSummary",    bonusLabelId = "deathBonus",    description = "Increases damage from death spells like Sudden Death and Death Strike." },
}

local ELEMENTAL_TYPES_BY_COMBAT_TYPE = {}
for _, element in ipairs(ELEMENTAL_TYPES) do
    ELEMENTAL_TYPES_BY_COMBAT_TYPE[element.combatType] = element
end

local elementalBuildWindow

local availablePoints = 0
local investedPoints  = {}
local pendingPoints   = {}
local missions        = {}
local missionFilter   = "all"
local activeMissionId = nil
local activeTab       = "missions"

local function initializePointTables()
    for _, element in ipairs(ELEMENTAL_TYPES) do
        investedPoints[element.combatType] = 0
        pendingPoints[element.combatType]  = 0
    end
end

local function totalPendingUsed()
    local total = 0
    for _, points in pairs(pendingPoints) do
        total = total + points
    end
    return total
end

local function sendToServer(payload)
    local protocol = g_game.getProtocolGame()

    if not protocol then
        return
    end

    protocol:sendExtendedOpcode(ELEMENTALBUILD_OPCODE, json.encode(payload))
end

local function requestData()
    sendToServer({ action = "request" })
end

local function updateBonusSummaryBar()
    if not elementalBuildWindow then
        return
    end

    local summaryBar = elementalBuildWindow.bonusSummaryBar

    for _, element in ipairs(ELEMENTAL_TYPES) do
        local invested   = investedPoints[element.combatType] or 0
        local bonusLabel = summaryBar[element.summaryId][element.bonusLabelId]
        local hasBonus   = invested > 0

        bonusLabel:setText(hasBonus and ("+" .. invested .. "%") or "0%")
        bonusLabel:setColor(hasBonus and element.color or "#666666")
    end
end

local function updateHeaderLabels()
    local used = totalPendingUsed()
    elementalBuildWindow.buildTab.availableLabel:setText("Available: " .. (availablePoints - used))
    elementalBuildWindow.buildTab.usedLabel:setText("Used: " .. used)
    elementalBuildWindow.buildTab.capLabel:setText("Cap: " .. ELEMENTAL_BUILD_CAP)
end

local function updateBuildProgressBar(rowWidget, points)
    local fillWidth = math.floor((points / ELEMENTAL_BUILD_CAP) * rowWidget.progressBarBg:getWidth())
    rowWidget.progressBarBg.progressBarFill:setWidth(fillWidth)
end

local function updateElementRow(rowWidget, combatType)
    local points = pendingPoints[combatType] or 0
    rowWidget.elementPoints:setText(points .. " / " .. ELEMENTAL_BUILD_CAP)
    updateBuildProgressBar(rowWidget, points)
end

local function refreshAllRows()
    local rowsContainer = elementalBuildWindow.buildTab.elementsPanel.elementRows

    for _, rowWidget in pairs(rowsContainer:getChildren()) do
        updateElementRow(rowWidget, rowWidget.elementCombatType)
    end

    updateHeaderLabels()
end

local function buildButtonMouseRelease(combatType, positiveAmount, negativeAmount)
    return function(widget, mousePos, mouseButton)
        if not widget:containsPoint(mousePos) then
            return false
        end

        if mouseButton == MouseRightButton then
            return false
        end

        if g_keyboard.isShiftPressed() then
            if positiveAmount > 0 then
                modules.game_elementalbuild.onAddPoints(combatType, ELEMENTAL_BUILD_CAP)
            else
                modules.game_elementalbuild.onRemovePoints(combatType, ELEMENTAL_BUILD_CAP)
            end
            return true
        end

        if positiveAmount > 0 then
            modules.game_elementalbuild.onAddPoints(combatType, positiveAmount)
        else
            modules.game_elementalbuild.onRemovePoints(combatType, -negativeAmount)
        end

        return true
    end
end

local function rebuildElementRows()
    if not elementalBuildWindow then
        return
    end

    local rowsContainer = elementalBuildWindow.buildTab.elementsPanel.elementRows
    rowsContainer:destroyChildren()

    for _, element in ipairs(ELEMENTAL_TYPES) do
        local rowWidget = g_ui.createWidget("ElementalBuildElementRow", rowsContainer)
        rowWidget.elementCombatType = element.combatType

        rowWidget.elementName:setText(element.name)
        rowWidget.elementName:setColor(element.color)
        rowWidget.progressBarBg.progressBarFill:setBackgroundColor(element.color)

        updateElementRow(rowWidget, element.combatType)

        rowWidget.increaseOne.onMouseRelease = buildButtonMouseRelease(element.combatType, 1, 0)
        rowWidget.increaseTen.onMouseRelease = buildButtonMouseRelease(element.combatType, 10, 0)
        rowWidget.decreaseOne.onMouseRelease = buildButtonMouseRelease(element.combatType, 0, -1)
        rowWidget.decreaseTen.onMouseRelease = buildButtonMouseRelease(element.combatType, 0, -10)
    end
end

local function rebuildInfoRows()
    if not elementalBuildWindow then
        return
    end

    local rowsContainer = elementalBuildWindow.infoTab.infoPanel.infoRows
    rowsContainer:destroyChildren()

    for _, element in ipairs(ELEMENTAL_TYPES) do
        local rowWidget = g_ui.createWidget("ElementalBuildInfoRow", rowsContainer)
        local invested  = investedPoints[element.combatType] or 0
        local hasBonus  = invested > 0

        rowWidget.infoElementName:setText(element.name)
        rowWidget.infoElementName:setColor(element.color)
        rowWidget.infoBonusLabel:setText(hasBonus and ("+" .. invested .. "%") or "not invested")
        rowWidget.infoBonusLabel:setColor(hasBonus and element.color or "#666666")
        rowWidget.infoDescription:setText(element.description)

        local fillWidth = math.floor((invested / ELEMENTAL_BUILD_CAP) * rowWidget.progressBarBg:getWidth())
        rowWidget.progressBarBg.progressBarFill:setWidth(fillWidth)
        rowWidget.progressBarBg.progressBarFill:setBackgroundColor(element.color)
    end
end

function onAddPoints(combatType, amount)
    local used    = totalPendingUsed()
    local current = pendingPoints[combatType] or 0
    local canAdd  = math.min(amount, availablePoints - used, ELEMENTAL_BUILD_CAP - current)

    if canAdd <= 0 then
        return
    end

    pendingPoints[combatType] = current + canAdd
    refreshAllRows()
end

function onRemovePoints(combatType, amount)
    local current   = pendingPoints[combatType] or 0
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
    local payload = { action = "invest", points = {} }

    for combatType, points in pairs(pendingPoints) do
        payload.points[tostring(combatType)] = points
    end

    sendToServer(payload)
end

function switchTab(tabName)
    activeTab = tabName

    elementalBuildWindow.missionsTab:setVisible(tabName == "missions")
    elementalBuildWindow.buildTab:setVisible(tabName == "build")
    elementalBuildWindow.infoTab:setVisible(tabName == "info")

    elementalBuildWindow.tabBar.missionsTabButton:setOn(tabName == "missions")
    elementalBuildWindow.tabBar.buildTabButton:setOn(tabName == "build")
    elementalBuildWindow.tabBar.infoTabButton:setOn(tabName == "info")

    if tabName == "info" then
        rebuildInfoRows()
    end
end

local function allMissionItemsMet(mission)
    for _, item in ipairs(mission.items) do
        if item.progress < item.total then
            return false
        end
    end
    return true
end

local function resolveMissionNameWithStatus(mission)
    if mission.completed then
        return mission.name .. " (done)", "#3a9a3a"
    end

    if mission.isCurrent then
        return mission.name .. " (current)", "#f0c060"
    end

    return mission.name .. " (locked)", "#555555"
end

local function resolveMissionSubtitleColor(mission)
    if mission.completed then return "#3a9a3a" end
    if mission.isLocked  then return "#444444" end
    return "#888888"
end

local function resolveMissionNameColor(mission)
    if mission.isLocked then return "#555555" end
    return "#e0e0e0"
end

local function updateMissionProgressBar(rowWidget, mission)
    local totalRequired = 0
    local totalProgress = 0

    for _, item in ipairs(mission.items) do
        totalRequired = totalRequired + item.total
        totalProgress = totalProgress + math.min(item.progress, item.total)
    end

    local pct       = totalRequired > 0 and math.floor((totalProgress / totalRequired) * 100) or 0
    local fillWidth = math.floor((pct / 100) * rowWidget.progressBarBg:getWidth())
    rowWidget.progressBarBg.progressBarFill:setWidth(fillWidth)
end

local function applyMissionRowStyle(rowWidget, mission)
    if mission.completed then
        rowWidget:setBorderColor("#3a7a3a")
        rowWidget.progressBarBg.progressBarFill:setBackgroundColor("#3a9a3a")
        return
    end

    if mission.isCurrent then
        rowWidget:setBorderColor("#4a90d9")
        rowWidget.progressBarBg.progressBarFill:setBackgroundColor("#4a90d9")
        return
    end

    rowWidget:setBorderColor("#2a2a2a")
    rowWidget.progressBarBg.progressBarFill:setBackgroundColor("#333333")
end

local function missionMatchesFilter(mission)
    if missionFilter == "done"    then return mission.completed end
    if missionFilter == "pending" then return not mission.completed end
    return true
end

local function rebuildMissionRows()
    if not elementalBuildWindow then
        return
    end

    local rowsContainer = elementalBuildWindow.missionsTab.missionsPanel.missionRows
    local filterBar     = elementalBuildWindow.missionsTab.missionsFilterBar
    rowsContainer:destroyChildren()

    local completedCount = 0
    for _, mission in ipairs(missions) do
        if mission.completed then
            completedCount = completedCount + 1
        end
    end

    filterBar.missionsProgressLabel:setText(completedCount .. " / " .. #missions .. " completed")

    for _, mission in ipairs(missions) do
        if not missionMatchesFilter(mission) then
            goto continue
        end

        local rowWidget = g_ui.createWidget("ElementalBuildMissionRow", rowsContainer)
        rowWidget.missionId = mission.id

        local nameText, nameColor = resolveMissionNameWithStatus(mission)
        local itemCount           = #mission.items
        local subtitle            = mission.completed
            and ("+" .. mission.points .. " points earned")
            or  (itemCount .. " item" .. (itemCount > 1 and "s" or "") .. " required: +" .. mission.points .. " pts")

        rowWidget.missionName:setText(nameText)
        rowWidget.missionName:setColor(nameColor)
        rowWidget.missionSubtitle:setText(subtitle)
        rowWidget.missionSubtitle:setColor(resolveMissionSubtitleColor(mission))

        rowWidget.viewButton:setEnabled(not mission.isLocked)
        rowWidget.viewButton:setText(mission.isLocked and "Locked" or "View")

        applyMissionRowStyle(rowWidget, mission)
        updateMissionProgressBar(rowWidget, mission)

        rowWidget.viewButton.onClick = function()
            modules.game_elementalbuild.onViewMission(mission.id)
        end

        ::continue::
    end
end

function setMissionFilter(filter)
    missionFilter = filter
    rebuildMissionRows()
end

local function buildModalItemSlots(mission)
    local modalItemSlots = elementalBuildWindow.missionDetailModal.modalPanel.modalItemsPanel.modalItemSlots
    modalItemSlots:destroyChildren()

    for _, item in ipairs(mission.items) do
        local slotWidget = g_ui.createWidget("ElementalBuildModalItemSlot", modalItemSlots)
        local met        = item.progress >= item.total
        local pct        = math.floor((math.min(item.progress, item.total) / item.total) * 100)
        local fillWidth  = math.floor((pct / 100) * slotWidget.progressBarBg:getWidth())

        slotWidget.itemIcon:setItemId(item.clientId)
        slotWidget.itemName:setText(item.name)
        slotWidget.itemProgress:setText(item.progress .. " / " .. item.total)
        slotWidget.itemProgress:setColor(met and "#3a9a3a" or "#4a90d9")
        slotWidget.progressBarBg.progressBarFill:setWidth(fillWidth)
        slotWidget.progressBarBg.progressBarFill:setBackgroundColor(met and "#3a9a3a" or "#4a90d9")
    end
end

local function updateModalDeliverButton(mission)
    local deliverButton = elementalBuildWindow.missionDetailModal.modalPanel.modalFooter.modalDeliverButton
    local canDeliver    = allMissionItemsMet(mission) and not mission.completed

    deliverButton:setEnabled(canDeliver)
    deliverButton:setText(mission.completed and "Completed" or (allMissionItemsMet(mission) and "Deliver" or "Missing items"))
end

local function findMissionById(missionId)
    for _, mission in ipairs(missions) do
        if mission.id == missionId then
            return mission
        end
    end
    return nil
end

function onViewMission(missionId)
    local mission = findMissionById(missionId)

    if not mission or mission.isLocked then
        return
    end

    activeMissionId = missionId

    local modal = elementalBuildWindow.missionDetailModal
    modal.modalPanel.modalHeader.modalMissionName:setText(mission.name)
    modal.modalPanel.modalDescription:setText(mission.description)
    modal.modalPanel.modalFooter.modalRewardLabel:setText("+" .. mission.points .. " elemental build points")

    buildModalItemSlots(mission)
    updateModalDeliverButton(mission)

    modal:setVisible(true)
    modal:raise()
    modal:focus()
end

function closeMissionDetail()
    elementalBuildWindow.missionDetailModal:setVisible(false)
    activeMissionId = nil
end

function onDeliverMission()
    if not activeMissionId then
        return
    end

    sendToServer({ action = "deliver", missionId = activeMissionId })
end

local function applyInvestedPoints(serverInvestedPoints)
    for combatTypeStr, points in pairs(serverInvestedPoints or {}) do
        local key = tonumber(combatTypeStr)
        investedPoints[key] = points
        pendingPoints[key]  = points
    end
end

local function applyServerState(data)
    availablePoints = data.availablePoints or 0
    missions        = data.missions or {}

    applyInvestedPoints(data.investedPoints)

    rebuildElementRows()
    rebuildMissionRows()
    updateHeaderLabels()
    updateBonusSummaryBar()

    elementalBuildWindow:show()
    elementalBuildWindow:raise()
    elementalBuildWindow:focus()

    switchTab("missions")
end

local function applyInvestResult(data)
    if not data.success then
        return
    end

    availablePoints = data.availablePoints or availablePoints
    applyInvestedPoints(data.investedPoints)

    refreshAllRows()
    updateBonusSummaryBar()
end

local function applyMissionResult(data)
    if not data.success then
        return
    end

    availablePoints = data.availablePoints or availablePoints
    missions        = data.missions or missions

    rebuildMissionRows()
    updateHeaderLabels()
    updateBonusSummaryBar()
    closeMissionDetail()
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= ELEMENTALBUILD_OPCODE then
        return
    end

    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then
        return
    end

    if data.action == "data" then
        applyServerState(data)
    elseif data.action == "investResult" then
        applyInvestResult(data)
    elseif data.action == "missionResult" then
        applyMissionResult(data)
    end
end

local function onGameStart()
    ProtocolGame.registerExtendedOpcode(ELEMENTALBUILD_OPCODE, onExtendedOpcode)
end

local function onGameEnd()
    ProtocolGame.unregisterExtendedOpcode(ELEMENTALBUILD_OPCODE)
    hide()
    initializePointTables()
    missions        = {}
    missionFilter   = "all"
    activeMissionId = nil
end

function show()
    elementalBuildWindow:show()
    elementalBuildWindow:raise()
    elementalBuildWindow:focus()
    requestData()
end

function hide()
    elementalBuildWindow:hide()
    closeMissionDetail()
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
        onGameEnd   = onGameEnd
    })

    initializePointTables()

    elementalBuildWindow = g_ui.displayUI("elementalbuild")
    elementalBuildWindow:hide()

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd   = onGameEnd
    })

    if not elementalBuildWindow then
        return
    end

    elementalBuildWindow:destroy()
end