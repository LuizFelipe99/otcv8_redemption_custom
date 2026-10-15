local POTION_COOLDOWN_OPCODE = 20

local NO_COOLDOWN_COLOR = "#c0c0c0"
local ACTIVE_COOLDOWN_COLOR = "#ff9854"

local potionCooldownWindow
local potionCooldownButton
local countdownEvent
local isOpcodeRegistered = false

local cooldownEntries = {}
local rowWidgetsByPotionId = {}

local function formatRemainingTime(remainingSeconds)
    if remainingSeconds <= 0 then
        return "No Cooldown", NO_COOLDOWN_COLOR
    end

    if remainingSeconds <= 60 then
        return remainingSeconds .. "s", ACTIVE_COOLDOWN_COLOR
    end

    local duration = math.max(1, remainingSeconds)
    local days = math.floor(duration / 86400)
    local hours = math.floor((duration % 86400) / 3600)
    local minutes = math.floor((duration % 3600) / 60)

    if days > 0 then
        return string.format("%dd %02dh %02dmin", days, hours, minutes), ACTIVE_COOLDOWN_COLOR
    end

    return string.format("%02dh %02dmin", hours, minutes), ACTIVE_COOLDOWN_COLOR
end

local function dockWindowIfNeeded()
    if potionCooldownWindow:getParent() then
        return
    end

    local availablePanel = modules.game_interface.findContentPanelAvailable(potionCooldownWindow, potionCooldownWindow:getMinimumHeight())
    if not availablePanel then
        return
    end

    availablePanel:addChild(potionCooldownWindow)
end

local function updateRowCooldownLabel(rowWidget)
    local remainingSeconds = math.max(0, rowWidget.cooldownExpiresAt - os.time())
    local text, color = formatRemainingTime(remainingSeconds)
    rowWidget.potionCooldownLabel:setText(text)
    rowWidget.potionCooldownLabel:setColor(color)
end

local function createRowWidget(entry, container)
    local rowWidget = g_ui.createWidget("PotionCooldownRow", container)

    if entry.itemId and entry.itemId > 0 then
        rowWidget.potionIcon:setItemId(entry.itemId)
    end

    rowWidget.potionName:setText(entry.name or "Unknown Potion")
    rowWidget.cooldownExpiresAt = entry.cooldownExpiresAt
    rowWidget.potionId = entry.potionId

    return rowWidget
end

local ROW_HEIGHT = 34
local ROWS_CONTAINER_BASE_HEIGHT = 8

local function rebuildRows()
    potionCooldownWindow.contentsPanel.potions:destroyChildren()
    rowWidgetsByPotionId = {}

    local container = potionCooldownWindow.contentsPanel.potions
    for _, entry in ipairs(cooldownEntries) do
        local rowWidget = createRowWidget(entry, container)
        updateRowCooldownLabel(rowWidget)
        rowWidgetsByPotionId[entry.potionId] = rowWidget
    end

    container:setHeight(ROWS_CONTAINER_BASE_HEIGHT + (ROW_HEIGHT * #cooldownEntries))
end

local function applyServerState(data)
    cooldownEntries = data.potions or {}
    rebuildRows()
end

local function sendToServer(payload)
    local protocol = g_game.getProtocolGame()
    if not protocol then
        return
    end
    protocol:sendExtendedOpcode(POTION_COOLDOWN_OPCODE, json.encode(payload))
end

local function requestData()
    sendToServer({ action = "request" })
end

local function tickCountdown()
    for _, rowWidget in pairs(rowWidgetsByPotionId) do
        updateRowCooldownLabel(rowWidget)
    end
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= POTION_COOLDOWN_OPCODE then
        return
    end

    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then
        return
    end

    if data.action ~= "data" then
        return
    end

    applyServerState(data)
end

function onWindowOpened()
    dockWindowIfNeeded()

    if potionCooldownButton then
        potionCooldownButton:setOn(true)
    end

    requestData()
end

function show()
    dockWindowIfNeeded()
    potionCooldownWindow:open()

    if potionCooldownButton then
        potionCooldownButton:setOn(true)
    end

    requestData()
end

function onWindowClosed()
    if potionCooldownButton then
        potionCooldownButton:setOn(false)
    end
end

function hide()
    potionCooldownWindow:close()
end

function toggle()
    if potionCooldownWindow:isVisible() then
        return hide()
    end
    show()
end

local function onGameStart()
    local registrationSucceeded = pcall(ProtocolGame.registerExtendedOpcode, POTION_COOLDOWN_OPCODE, onExtendedOpcode)
    isOpcodeRegistered = registrationSucceeded

    if not registrationSucceeded then
        g_logger.error("PotionCooldown: opcode " .. POTION_COOLDOWN_OPCODE .. " is already taken by another module")
    end

    if potionCooldownButton then
        return
    end

    potionCooldownButton = modules.game_mainpanel.addToggleButton(
        "potionCooldownButton",
        tr("Potion Cooldowns"),
        "/images/options/button_potioncooldown",
        toggle,
        false,
        1008
    )
end

local function onGameEnd()
    if isOpcodeRegistered then
        ProtocolGame.unregisterExtendedOpcode(POTION_COOLDOWN_OPCODE)
        isOpcodeRegistered = false
    end

    hide()
    cooldownEntries = {}
    rebuildRows()
end

local UNWANTED_HEADER_BUTTON_IDS = {
    "lockButton",
    "contextMenuButton",
    "newWindowButton",
    "toggleFilterButton"
}

local function hideUnwantedHeaderButtons()
    for _, buttonId in ipairs(UNWANTED_HEADER_BUTTON_IDS) do
        local buttonWidget = potionCooldownWindow:recursiveGetChildById(buttonId)
        if buttonWidget then
            buttonWidget:setVisible(false)
        end
    end
end

function init()
    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })

    potionCooldownWindow = g_ui.loadUI("potioncooldown")
    potionCooldownWindow:setup()
    potionCooldownWindow:hide()

    hideUnwantedHeaderButtons()

    countdownEvent = cycleEvent(tickCountdown, 1000)

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })

    if countdownEvent then
        countdownEvent:cancel()
        countdownEvent = nil
    end

    if potionCooldownButton then
        potionCooldownButton:destroy()
        potionCooldownButton = nil
    end

    if potionCooldownWindow then
        potionCooldownWindow:destroy()
    end
end