local ITEM_TOOLTIP_OPCODE = 21
local REQUEST_DELAY_MS = 300
local INVENTORY_POSITION_X = 0xFFFF
local VALUE_COLUMN_MARGIN = 124
local LABEL_COLUMN_WIDTH = 118
local CONTENT_WIDTH = 302
local NAME_WIDTH = 258
local MOUSE_OFFSET = 14
local SCREEN_EDGE_MARGIN = 6

local originalItemHoverChange
local pendingRequestEvent
local hoveredItemWidget
local tooltipPanel
local isOpcodeRegistered = false

local function cancelPendingRequest()
    if not pendingRequestEvent then
        return
    end

    removeEvent(pendingRequestEvent)
    pendingRequestEvent = nil
end

local function measureTextWidth(label, text)
    label:setText(text)
    return label:getTextSize().width
end

local function wrapParagraph(label, paragraph, maxWidth)
    local wrappedLines = {}
    local currentLine = ''
    for word in paragraph:gmatch('%S+') do
        local candidateLine = currentLine:len() > 0 and (currentLine .. ' ' .. word) or word
        if currentLine:len() > 0 and measureTextWidth(label, candidateLine) > maxWidth then
            table.insert(wrappedLines, currentLine)
            currentLine = word
        else
            currentLine = candidateLine
        end
    end
    table.insert(wrappedLines, currentLine)
    return wrappedLines
end

local function setWrappedText(label, text, maxWidth)
    local wrappedLines = {}
    for paragraph in (text .. '\n'):gmatch('(.-)\n') do
        for _, line in ipairs(wrapParagraph(label, paragraph, maxWidth)) do
            table.insert(wrappedLines, line)
        end
    end
    label:setText(table.concat(wrappedLines, '\n'))
end

local function capitalizeFirstLetter(text)
    return (text:gsub('^%l', string.upper))
end

local function splitAttributeList(attributeList)
    local attributes = {}
    local depth = 0
    local currentAttribute = ''
    for character in attributeList:gmatch('.') do
        if character == '(' then
            depth = depth + 1
        elseif character == ')' then
            depth = depth - 1
        end

        if character == ',' and depth == 0 then
            table.insert(attributes, currentAttribute)
            currentAttribute = ''
        else
            currentAttribute = currentAttribute .. character
        end
    end
    table.insert(attributes, currentAttribute)
    return attributes
end

local function buildAttributeField(attribute)
    attribute = attribute:match('^%s*(.-)%s*$')
    local colonLabel, colonValue = attribute:match('^([^:]+):%s*(.+)$')
    if colonLabel then
        return { label = capitalizeFirstLetter(colonLabel), value = colonValue }
    end

    local label, value = attribute:match('^(.-)%s+([%+%-]?%d[%d%.]*%%?)$')
    if label and label:len() > 0 then
        return { label = capitalizeFirstLetter(label), value = value }
    end

    return { label = '', value = capitalizeFirstLetter(attribute) }
end

local function buildLineFields(line)
    local fields = {}
    local classification, tier = line:match('^Classification:%s*(%S+)%s+Tier:%s*(.+)$')
    if classification then
        table.insert(fields, { label = 'Classification', value = classification })
        table.insert(fields, { label = 'Tier', value = (tier:gsub('%.$', '')) })
        return fields
    end

    local label, value = line:match('^([^:]+):%s*(.+)$')
    if label and label:len() <= 24 then
        table.insert(fields, { label = label, value = (value:gsub('%.$', '')) })
        return fields
    end

    table.insert(fields, { label = '', value = line })
    return fields
end

local function buildFallbackFields(description)
    local fields = {}
    local isFirstLine = true
    for line in (description .. '\n'):gmatch('(.-)\n') do
        if line:len() > 0 then
            local attributeList = isFirstLine and line:match('^.-%s%((.*)%)%.?$')
            if attributeList then
                for _, attribute in ipairs(splitAttributeList(attributeList)) do
                    table.insert(fields, buildAttributeField(attribute))
                end
            elseif isFirstLine and line:find('[%(%.]%s') then
                table.insert(fields, { label = '', value = line })
            elseif not isFirstLine then
                for _, field in ipairs(buildLineFields(line)) do
                    table.insert(fields, field)
                end
            end
            isFirstLine = false
        end
    end
    return fields
end

local function addFieldRow(field)
    local fieldRow = g_ui.createWidget('ItemTooltipFieldRow', tooltipPanel.fieldRows)
    local hasLabel = type(field.label) == 'string' and field.label:len() > 0
    local value = tostring(field.value or '')

    if hasLabel then
        setWrappedText(fieldRow.fieldLabel, field.label, LABEL_COLUMN_WIDTH)
    else
        fieldRow.fieldLabel:setText('')
    end
    fieldRow.fieldValue:setMarginLeft(hasLabel and VALUE_COLUMN_MARGIN or 0)
    setWrappedText(fieldRow.fieldValue, value, hasLabel and (CONTENT_WIDTH - VALUE_COLUMN_MARGIN) or CONTENT_WIDTH)
    fieldRow:setHeight(math.max(fieldRow.fieldLabel:getHeight(), fieldRow.fieldValue:getHeight()))
end

local function moveTooltipToMouse()
    if not tooltipPanel or not tooltipPanel:isVisible() then
        return
    end

    local mousePosition = g_window.getMousePosition()
    local windowSize = g_window.getSize()
    local panelSize = tooltipPanel:getSize()
    local position = { x = mousePosition.x + MOUSE_OFFSET, y = mousePosition.y + MOUSE_OFFSET }

    if position.x + panelSize.width > windowSize.width - SCREEN_EDGE_MARGIN then
        position.x = mousePosition.x - panelSize.width - MOUSE_OFFSET
    end
    if position.y + panelSize.height > windowSize.height - SCREEN_EDGE_MARGIN then
        position.y = math.max(SCREEN_EDGE_MARGIN, windowSize.height - panelSize.height - SCREEN_EDGE_MARGIN)
    end

    tooltipPanel:setPosition(position)
end

local function hideTooltip()
    if not tooltipPanel or not tooltipPanel:isVisible() then
        return
    end

    tooltipPanel:hide()
    disconnect(rootWidget, { onMouseMove = moveTooltipToMouse })
end

local function showTooltip(item, tooltipData)
    tooltipPanel.header.itemIcon:setItemId(item:getId())
    tooltipPanel.header.itemIcon:setItemCount(item:getCount())
    setWrappedText(tooltipPanel.header.itemName, tooltipData.name or '', NAME_WIDTH)

    tooltipPanel.fieldRows:destroyChildren()
    local fields = tooltipData.fields or buildFallbackFields(tooltipData.description or '')
    for _, field in ipairs(fields) do
        addFieldRow(field)
    end
    tooltipPanel.separator:setVisible(#fields > 0)
    tooltipPanel.fieldRows:setVisible(#fields > 0)

    local wasVisible = tooltipPanel:isVisible()
    tooltipPanel:show()
    tooltipPanel:raise()
    tooltipPanel:getLayout():update()
    moveTooltipToMouse()
    if not wasVisible then
        connect(rootWidget, { onMouseMove = moveTooltipToMouse })
    end
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
            hideTooltip()
        end
        return
    end

    if not isOpcodeRegistered or g_ui.getDraggingWidget() then
        return
    end

    local item = getEligibleItem(widget)
    if not item then
        return
    end

    hoveredItemWidget = widget
    if item.itemTooltipData then
        showTooltip(item, item.itemTooltipData)
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
    if not decoded or type(response) ~= 'table' then
        return
    end

    local widget = hoveredItemWidget
    if not widget or widget:isDestroyed() or not widget:isHovered() then
        return
    end

    local item = widget:getItem()
    if not item or not matchesTooltipResponse(item, response) then
        return
    end

    item.itemTooltipData = response
    showTooltip(item, response)
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
    hideTooltip()
    if not isOpcodeRegistered then
        return
    end

    ProtocolGame.unregisterExtendedOpcode(ITEM_TOOLTIP_OPCODE)
    isOpcodeRegistered = false
end

function init()
    g_ui.importStyle('itemtooltip')
    tooltipPanel = g_ui.createWidget('ItemTooltipPanel', rootWidget)
    tooltipPanel:hide()

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

    if tooltipPanel then
        tooltipPanel:destroy()
        tooltipPanel = nil
    end
end
