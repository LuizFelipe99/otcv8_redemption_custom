local ITEM_TOOLTIP_OPCODE = 21
local REQUEST_DELAY_MS = 300
local INVENTORY_POSITION_X = 0xFFFF
local CONTENT_WIDTH = 282
local INFO_VALUE_MARGIN = 90
local NAME_WIDTH = 242
local MOUSE_OFFSET = 14
local SCREEN_EDGE_MARGIN = 6
local REQUIREMENT_MET_COLOR = '#8a8a8a'
local REQUIREMENT_UNMET_COLOR = '#e05a4a'
local ELEMENT_ICON_PATH = '/game_cyclopedia/images/bestiary/icons/monster-icon-%s-resist'
local ELEMENT_STYLES = {
    physical = { name = 'Physical', color = '#b8b6ad' },
    energy = { name = 'Energy', color = '#5aa2ec' },
    earth = { name = 'Earth', color = '#7fbf3a' },
    fire = { name = 'Fire', color = '#ec6a3c' },
    ice = { name = 'Ice', color = '#95c8f2' },
    holy = { name = 'Holy', color = '#f2b23f' },
    death = { name = 'Death', color = '#9a93ec' }
}
local HIDDEN_FIELD_LABELS = {
    ['Weight'] = true,
    ['Total Weight'] = true,
    ['Tradeable'] = true,
    ['Tradeable In Market'] = true,
    ['Weapon Type'] = true,
    ['Body Position'] = true
}
local PREFIXED_BONUS_LABELS = {
    ['Magic Level'] = true,
    ['Speed'] = true,
    ['Cleave'] = true,
    ['Magic Shield Capacity'] = true,
    ['Perfect Shot'] = true,
    ['Damage Reflection'] = true
}
local PROTECTION_ELEMENTS = {
    physical = true, energy = true, earth = true, fire = true, ice = true, holy = true,
    death = true, lifedrain = true, manadrain = true, drown = true, healing = true
}
local VOCATION_CHECKS = {
    { word = 'knight', check = 'isKnight' },
    { word = 'paladin', check = 'isPaladin' },
    { word = 'sorcerer', check = 'isSorcerer' },
    { word = 'druid', check = 'isDruid' },
    { word = 'monk', check = 'isMonk' }
}

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

local function trim(text)
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function capitalizeFirstLetter(text)
    return (text:gsub('^%l', string.upper))
end

local function titleCase(text)
    return (text:gsub("(%a)([%w']*)", function(firstLetter, rest)
        return firstLetter:upper() .. rest
    end))
end

local function stripOuterParentheses(text)
    local inner = text:match('^%((.*)%)%.?$')
    return inner or (text:gsub('%.$', ''))
end

local function splitTopLevelList(text)
    local parts = {}
    local depth = 0
    local currentPart = ''
    for character in text:gmatch('.') do
        if character == '(' then
            depth = depth + 1
        elseif character == ')' then
            depth = depth - 1
        end

        if character == ',' and depth == 0 then
            table.insert(parts, trim(currentPart))
            currentPart = ''
        else
            currentPart = currentPart .. character
        end
    end
    if trim(currentPart):len() > 0 then
        table.insert(parts, trim(currentPart))
    end
    return parts
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

local function createTooltipModel()
    return { mainStats = {}, bonuses = {}, infos = {}, requirement = {} }
end

local function addBonus(model, text)
    table.insert(model.bonuses, capitalizeFirstLetter(trim(text)))
end

local function addInfo(model, label, value)
    table.insert(model.infos, { label = label, value = value })
end

local function addAttackStats(model, attackValue)
    local baseAttack = attackValue:match('^(%d+)')
    if not baseAttack then
        for _, part in ipairs(splitTopLevelList(attackValue)) do
            local hitChance = part:match('^chance to hit (%+%d+%%)$')
            local range = part:match('^(%d+) fields$')
            if hitChance then
                addBonus(model, 'Hit Chance ' .. hitChance)
            elseif range then
                addInfo(model, 'Range', range .. ' fields')
            else
                addBonus(model, titleCase(part))
            end
        end
        return
    end

    table.insert(model.mainStats, 'Atk ' .. baseAttack)
    local elementDamage, elementName = attackValue:match('%+%s*(%d+)%s+(%a+)')
    if elementDamage then
        addBonus(model, titleCase(elementName) .. ' Damage +' .. elementDamage)
    end
end

local function addDefenseStats(model, defenseValue)
    local baseDefense, extraDefense = defenseValue:match('^(%d+)%s*([%+%-]%d+)$')
    if baseDefense then
        table.insert(model.mainStats, 'Def ' .. baseDefense)
        addBonus(model, 'Extra Defence ' .. extraDefense)
        return
    end
    table.insert(model.mainStats, 'Def ' .. defenseValue)
end

local function addProtectionList(model, prefix, value)
    for _, part in ipairs(splitTopLevelList(value)) do
        addBonus(model, prefix .. ' ' .. titleCase(part))
    end
end

local function formatAugments(value)
    return table.concat(splitTopLevelList(stripOuterParentheses(value)), '\n')
end

local function parseRequirementSentence(model, sentence)
    sentence = sentence:gsub('%.$', '')
    model.requirement.professions = sentence:match('^(.-) of ') or sentence:match('^(.-) and magic level') or sentence
    model.requirement.level = tonumber(sentence:match('of level (%d+)'))
    model.requirement.magicLevel = tonumber(sentence:match('magic level (%d+)'))
    if model.requirement.professions:find('level %d') then
        model.requirement.professions = nil
    end
end

local function applyServerField(model, label, value)
    if HIDDEN_FIELD_LABELS[label] then
        return
    end

    if label == 'Attack' then
        addAttackStats(model, value)
    elseif label == 'Defence' then
        addDefenseStats(model, value)
    elseif label == 'Armor' then
        table.insert(model.mainStats, 'Arm ' .. value)
    elseif label == 'HitChance' then
        addBonus(model, 'Hit Chance +' .. value .. '%')
    elseif label == 'Protection' or label == 'Field Protection' then
        addProtectionList(model, label, value)
    elseif label == 'Skill Boost' then
        for _, part in ipairs(splitTopLevelList(value)) do
            addBonus(model, titleCase(part))
        end
    elseif label == 'Effect' then
        addBonus(model, value)
    elseif PREFIXED_BONUS_LABELS[label] or label:find(' Magic Level$') then
        addBonus(model, label .. ' ' .. value)
    elseif label == 'Required Level' then
        model.requirement.level = tonumber(value)
    elseif label == 'Required Magic Level' then
        model.requirement.magicLevel = tonumber(value)
    elseif label == 'Professions' then
        model.requirement.professions = value
    elseif label == 'Required' then
        model.requirement.premium = true
    elseif label == 'Classification' then
        model.classification = value
    elseif label == 'Tier' then
        model.tier = value
    elseif label == 'Augments' then
        addInfo(model, label, formatAugments(value))
    elseif label:find('^Imbuement Slot') then
        addInfo(model, label:gsub('Imbuement Slot', 'Imbuement'), capitalizeFirstLetter(value))
    else
        addInfo(model, label, value)
    end
end

local function buildModelFromFields(fields)
    local model = createTooltipModel()
    for _, field in ipairs(fields) do
        if type(field.label) == 'string' and field.value ~= nil then
            applyServerField(model, field.label, tostring(field.value))
        end
    end
    return model
end

local function applyDescriptionAttribute(model, attribute, isProtectionList)
    local colonLabel, colonValue = attribute:match('^(%a+):%s*(.+)$')
    if colonLabel == 'Arm' then
        table.insert(model.mainStats, 'Arm ' .. colonValue)
        return false
    end
    if colonLabel == 'Atk' then
        addAttackStats(model, colonValue)
        return false
    end
    if colonLabel == 'Def' then
        addDefenseStats(model, colonValue)
        return false
    end
    if colonLabel then
        addInfo(model, colonLabel, colonValue)
        return false
    end

    local protectedElement = attribute:match('^protection (.+)$')
    if protectedElement then
        addBonus(model, 'Protection ' .. titleCase(protectedElement))
        return true
    end

    local elementName = attribute:match('^(%a+) [%+%-]%d+%%$')
    if isProtectionList and elementName and PROTECTION_ELEMENTS[elementName] then
        addBonus(model, 'Protection ' .. titleCase(attribute))
        return true
    end

    addBonus(model, titleCase(attribute))
    return false
end

local function applyDescriptionLine(model, line)
    local wieldedBy = line:match('^Wielded by:%s*(.+)$')
    if wieldedBy then
        parseRequirementSentence(model, wieldedBy)
        return
    end

    local classification, tier = line:match('^Classification:%s*(%S+)%s+Tier:%s*(.+)$')
    if classification then
        model.classification = classification
        model.tier = tier:gsub('%.$', '')
        return
    end

    local label, value = line:match('^([^:]+):%s*(.+)$')
    if label == 'Augments' then
        addInfo(model, label, formatAugments(value))
        return
    end
    if label and label:len() <= 24 then
        addInfo(model, label, stripOuterParentheses(value))
        return
    end

    addInfo(model, '', line)
end

local function buildModelFromDescription(description)
    local model = createTooltipModel()
    local isFirstLine = true
    for line in (description .. '\n'):gmatch('(.-)\n') do
        if line:len() > 0 then
            local attributeList = isFirstLine and line:match('^.-%s%((.*)%)%.?$')
            if attributeList then
                local isProtectionList = false
                for _, attribute in ipairs(splitTopLevelList(attributeList)) do
                    isProtectionList = applyDescriptionAttribute(model, attribute, isProtectionList)
                end
            elseif isFirstLine and line:find('[%(%.]%s') then
                addInfo(model, '', line)
            elseif not isFirstLine then
                applyDescriptionLine(model, line)
            end
            isFirstLine = false
        end
    end
    return model
end

local function buildTooltipModel(tooltipData)
    local model = tooltipData.fields and buildModelFromFields(tooltipData.fields) or buildModelFromDescription(tooltipData.description or '')
    if model.tier then
        local tierText = model.classification and (model.tier .. ' (Classification ' .. model.classification .. ')') or model.tier
        addInfo(model, 'Tier', tierText)
    end
    return model
end

local function playerMatchesProfessions(player, professions)
    if not professions or professions:lower():find('players') then
        return true
    end

    local lowerProfessions = professions:lower()
    for _, vocationCheck in ipairs(VOCATION_CHECKS) do
        if lowerProfessions:find(vocationCheck.word) and player[vocationCheck.check](player) then
            return true
        end
    end
    return false
end

local function isRequirementMet(requirement)
    local player = g_game.getLocalPlayer()
    if not player then
        return true
    end
    if requirement.level and player:getLevel() < requirement.level then
        return false
    end
    if requirement.magicLevel and player:getMagicLevel() < requirement.magicLevel then
        return false
    end
    return playerMatchesProfessions(player, requirement.professions)
end

local function describeRequirement(requirement)
    local levelText = requirement.level and ('level ' .. requirement.level .. ' or higher') or nil
    local magicLevelText = requirement.magicLevel and ('magic level ' .. requirement.magicLevel .. ' or higher') or nil
    local conditions = {}
    if levelText then
        table.insert(conditions, levelText)
    end
    if magicLevelText then
        table.insert(conditions, magicLevelText)
    end

    local conditionText = table.concat(conditions, ' and ')
    if requirement.professions then
        if conditionText:len() == 0 then
            return 'Only for ' .. requirement.professions
        end
        return capitalizeFirstLetter(requirement.professions) .. ' of ' .. conditionText
    end
    if conditionText:len() == 0 then
        return nil
    end
    return 'Requires ' .. conditionText
end

local function applyHeader(item, tooltipData, model)
    local header = tooltipPanel.header
    header.itemIcon:setItemId(item:getId())
    header.itemIcon:setItemCount(item:getCount())
    setWrappedText(header.itemName, tooltipData.name or '', NAME_WIDTH)

    local elementStyle = ELEMENT_STYLES[tooltipData.element or '']
    local mainStatsText = table.concat(model.mainStats, '   ')
    local hasMainStats = mainStatsText:len() > 0
    header.elementIcon:setVisible(elementStyle ~= nil)
    header.elementName:setVisible(elementStyle ~= nil)
    header.mainStats:setVisible(hasMainStats)
    header.mainStats:setText(mainStatsText)

    header.itemName:breakAnchors()
    header.itemName:addAnchor(AnchorLeft, 'itemIcon', AnchorRight)
    if not elementStyle and not hasMainStats then
        header.itemName:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
        return
    end
    header.itemName:addAnchor(AnchorTop, 'itemIcon', AnchorTop)

    header.mainStats:breakAnchors()
    header.mainStats:addAnchor(AnchorVerticalCenter, 'elementIcon', AnchorVerticalCenter)
    if not elementStyle then
        header.mainStats:addAnchor(AnchorLeft, 'itemIcon', AnchorRight)
        return
    end

    header.mainStats:addAnchor(AnchorLeft, 'elementName', AnchorRight)
    header.elementIcon:setImageSource(string.format(ELEMENT_ICON_PATH, tooltipData.element))
    header.elementName:setText(elementStyle.name)
    header.elementName:setColor(elementStyle.color)
end

local function fillBonusList(bonuses)
    tooltipPanel.bonusList:destroyChildren()
    for _, bonus in ipairs(bonuses) do
        local bonusLabel = g_ui.createWidget('ItemTooltipBonusText', tooltipPanel.bonusList)
        setWrappedText(bonusLabel, bonus, CONTENT_WIDTH)
    end
end

local function fillInfoList(infos)
    tooltipPanel.infoList:destroyChildren()
    for _, info in ipairs(infos) do
        local infoRow = g_ui.createWidget('ItemTooltipInfoRow', tooltipPanel.infoList)
        local hasLabel = info.label:len() > 0
        infoRow.infoLabel:setText(info.label)
        infoRow.infoValue:setMarginLeft(hasLabel and INFO_VALUE_MARGIN or 0)
        setWrappedText(infoRow.infoValue, info.value, hasLabel and (CONTENT_WIDTH - INFO_VALUE_MARGIN) or CONTENT_WIDTH)
        infoRow:setHeight(math.max(infoRow.infoLabel:getHeight(), infoRow.infoValue:getHeight()))
    end
end

local function applyRequirement(requirement)
    local requirementText = describeRequirement(requirement)
    tooltipPanel.requirementSeparator:setVisible(requirementText ~= nil)
    tooltipPanel.requirementText:setVisible(requirementText ~= nil)
    if not requirementText then
        return
    end

    setWrappedText(tooltipPanel.requirementText, requirementText, CONTENT_WIDTH)
    tooltipPanel.requirementText:setColor(isRequirementMet(requirement) and REQUIREMENT_MET_COLOR or REQUIREMENT_UNMET_COLOR)
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
    local model = buildTooltipModel(tooltipData)
    applyHeader(item, tooltipData, model)

    fillBonusList(model.bonuses)
    tooltipPanel.bonusSeparator:setVisible(#model.bonuses > 0)
    tooltipPanel.bonusList:setVisible(#model.bonuses > 0)

    fillInfoList(model.infos)
    tooltipPanel.infoSeparator:setVisible(#model.infos > 0)
    tooltipPanel.infoList:setVisible(#model.infos > 0)

    applyRequirement(model.requirement)

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
