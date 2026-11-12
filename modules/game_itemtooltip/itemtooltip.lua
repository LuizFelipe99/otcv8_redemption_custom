local ITEM_TOOLTIP_OPCODE = 21
local REQUEST_DELAY_MS = 300
local INVENTORY_POSITION_X = 0xFFFF
local MAX_TOOLTIP_LINE_LENGTH = 60

local originalItemHoverChange
local pendingRequestEvent
local hoveredItemWidget
local isOpcodeRegistered = false

local function cancelPendingRequest()
    if not pendingRequestEvent then
        return
    end

    removeEvent(pendingRequestEvent)
    pendingRequestEvent = nil
end

local function wrapLine(line)
    local wrappedLines = {}
    local currentLine = ''
    for word in line:gmatch('%S+') do
        if currentLine:len() > 0 and currentLine:len() + 1 + word:len() > MAX_TOOLTIP_LINE_LENGTH then
            table.insert(wrappedLines, currentLine)
            currentLine = word
        elseif currentLine:len() > 0 then
            currentLine = currentLine .. ' ' .. word
        else
            currentLine = word
        end
    end
    table.insert(wrappedLines, currentLine)
    return table.concat(wrappedLines, '\n')
end

local function wrapDescription(description)
    local wrappedLines = {}
    for line in (description .. '\n'):gmatch('(.-)\n') do
        table.insert(wrappedLines, wrapLine(line))
    end
    return table.concat(wrappedLines, '\n')
end

local function isCarriedItem(item)
    local position = item:getPosition()
    return position ~= nil and position.x == INVENTORY_POSITION_X
end

local function getEligibleItem(widget)
    local item = widget:getItem()
    if not item or not isCarriedItem(item) then
        return nil
    end
    return item
end

local function requestItemTooltip(item)
    local protocolGame = g_game.getProtocolGame()
    if not protocolGame then
        return
    end

    local position = item:getPosition()
    protocolGame:sendExtendedOpcode(ITEM_TOOLTIP_OPCODE, json.encode({
        x = position.x,
        y = position.y,
        z = position.z,
        itemId = item:getId()
    }))
end

local function onItemHoverChange(widget, hovered)
    if originalItemHoverChange then
        originalItemHoverChange(widget, hovered)
    else
        UIWidget.onHoverChange(widget, hovered)
    end
    cancelPendingRequest()

    if not hovered then
        if hoveredItemWidget == widget then
            hoveredItemWidget = nil
        end
        return
    end

    if not isOpcodeRegistered then
        return
    end

    local item = getEligibleItem(widget)
    if not item then
        return
    end

    hoveredItemWidget = widget
    if item:getTooltip():len() > 0 then
        return
    end

    pendingRequestEvent = scheduleEvent(function()
        pendingRequestEvent = nil
        if hoveredItemWidget ~= widget or widget:getItem() ~= item then
            return
        end
        requestItemTooltip(item)
    end, REQUEST_DELAY_MS)
end

local function matchesTooltipResponse(item, response)
    if item:getId() ~= response.itemId then
        return false
    end

    local position = item:getPosition()
    return position.x == response.x and position.y == response.y and position.z == response.z
end

local function onExtendedOpcode(protocol, opcode, buffer)
    local decoded, response = pcall(json.decode, buffer)
    if not decoded or type(response) ~= 'table' or type(response.description) ~= 'string' then
        return
    end

    local widget = hoveredItemWidget
    if not widget or widget:isDestroyed() then
        return
    end

    local item = widget:getItem()
    if not item or not matchesTooltipResponse(item, response) then
        return
    end

    local tooltip = wrapDescription(response.description)
    item:setTooltip(tooltip)
    widget:setTooltip(tooltip)
    if widget:isHovered() then
        g_tooltip.display(tooltip)
    end
end

local function onGameStart()
    isOpcodeRegistered = pcall(ProtocolGame.registerExtendedOpcode, ITEM_TOOLTIP_OPCODE, onExtendedOpcode)
    if not isOpcodeRegistered then
        g_logger.error('ItemTooltip: opcode ' .. ITEM_TOOLTIP_OPCODE .. ' is already taken by another module')
    end
end

local function onGameEnd()
    cancelPendingRequest()
    hoveredItemWidget = nil
    if not isOpcodeRegistered then
        return
    end

    ProtocolGame.unregisterExtendedOpcode(ITEM_TOOLTIP_OPCODE)
    isOpcodeRegistered = false
end

function init()
    originalItemHoverChange = UIItem.onHoverChange
    UIItem.onHoverChange = onItemHoverChange

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

    onGameEnd()
    if originalItemHoverChange then
        UIItem.onHoverChange = originalItemHoverChange
        originalItemHoverChange = nil
    end
end
