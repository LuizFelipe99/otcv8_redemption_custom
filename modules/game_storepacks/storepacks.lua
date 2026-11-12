local STORE_PACKS_OPCODE = 22
local BANNER_PATH = '/game_storepacks/images/%s'
local VISIBLE_ITEM_SLOTS = 12
local GLOW_PULSE_INTERVAL_MS = 60
local GLOW_PULSE_PERIOD_MS = 1800
local BUTTON_ROW_HEIGHT = 22
local SPECIALS_PER_ROW = 2
local CARD_STRIDE = 219

local storePacksWindow
local packsButton
local packsButtonGlow
local glowPulseEvent
local isOpcodeRegistered = false
local transferableBalance = 0
local packs = {}

local function sendToServer(payload)
    local protocolGame = g_game.getProtocolGame()
    if not protocolGame then
        return
    end
    protocolGame:sendExtendedOpcode(STORE_PACKS_OPCODE, json.encode(payload))
end

local function formatCoins(amount)
    local formatted = tostring(amount)
    while true do
        local replaced, count = formatted:gsub('^(%d+)(%d%d%d)', '%1.%2')
        formatted = replaced
        if count == 0 then
            return formatted
        end
    end
end

local function canAfford(pack)
    return transferableBalance >= pack.price
end

local function confirmPurchase(pack)
    local confirmBox
    local function buy()
        confirmBox:destroy()
        sendToServer({ action = 'buy', packId = pack.id })
    end
    local function cancel()
        confirmBox:destroy()
    end
    local message = tr('Do you want to buy the %s for %s transferable Tibia Coins?\nThe items will be sent to your store inbox.', pack.name, formatCoins(pack.price))
    confirmBox = displayGeneralBox(tr('Confirm purchase'), message, {
        { text = tr('Buy'), callback = buy },
        { text = tr('Cancel'), callback = cancel },
        anchor = AnchorHorizontalCenter
    }, buy, cancel)
end

local function fillPackItems(card, pack)
    card.itemGrid:destroyChildren()
    for _, packItem in ipairs(pack.items or {}) do
        local itemSlot = g_ui.createWidget('StorePackItemSlot', card.itemGrid)
        itemSlot:setItemId(packItem.clientId)
        itemSlot:setItemCount(packItem.count)
        itemSlot:setDisplayCount(packItem.count)
        itemSlot:setTooltip(packItem.count .. 'x ' .. (packItem.name or ''))
    end
    card.itemGridScrollBar:setVisible(#(pack.items or {}) > VISIBLE_ITEM_SLOTS)
end

local function refreshBuyButton(card, pack)
    local affordable = canAfford(pack)
    card.buyButton:setEnabled(affordable)
    card.buyButton:setText(affordable and tr('Buy now') or tr('Not enough coins'))
end

local function refreshBalance()
    storePacksWindow.balanceLabel:setText(tr('Transferable Tibia Coins') .. ': ' .. formatCoins(transferableBalance))
    for _, card in ipairs(storePacksWindow.cardsPanel:getChildren()) do
        refreshBuyButton(card, card.pack)
    end
end

local function buildCards()
    storePacksWindow.cardsPanel:destroyChildren()
    for cardIndex, pack in ipairs(packs) do
        local card = g_ui.createWidget('StorePackCard', storePacksWindow.cardsPanel)
        card:addAnchor(AnchorTop, 'parent', AnchorTop)
        card:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        card:setMarginLeft((cardIndex - 1) * CARD_STRIDE)
        card.pack = pack
        card.banner:setImageSource(string.format(BANNER_PATH, pack.banner))
        card.packName:setText(pack.name)
        card.price:setText(formatCoins(pack.price) .. ' ' .. tr('Tibia Coins'))
        fillPackItems(card, pack)
        card.buyButton.onClick = function()
            confirmPurchase(pack)
        end
    end
    refreshBalance()
end

function show()
    sendToServer({ action = 'request' })
end

function hide()
    storePacksWindow:hide()
end

function toggle()
    if storePacksWindow:isVisible() then
        return hide()
    end
    show()
end

local function onPacksReceived(data)
    packs = data.packs or {}
    transferableBalance = tonumber(data.balance) or 0
    buildCards()
    storePacksWindow:show()
    storePacksWindow:raise()
    storePacksWindow:focus()
end

local function onPurchaseResult(data)
    transferableBalance = tonumber(data.balance) or transferableBalance
    if storePacksWindow:isVisible() then
        refreshBalance()
    end
    if not data.message then
        return
    end
    if data.success then
        displayInfoBox(tr('Purchase complete'), data.message)
        return
    end
    displayErrorBox(tr('Purchase failed'), data.message)
end

local function onExtendedOpcode(protocol, opcode, buffer)
    local decoded, data = pcall(json.decode, buffer)
    if not decoded or type(data) ~= 'table' then
        return
    end

    if data.action == 'packs' then
        onPacksReceived(data)
    elseif data.action == 'purchaseResult' then
        onPurchaseResult(data)
    end
end

local function pulseGlow()
    if not packsButtonGlow or packsButtonGlow:isDestroyed() then
        return
    end
    local phase = (g_clock.millis() % GLOW_PULSE_PERIOD_MS) / GLOW_PULSE_PERIOD_MS
    packsButtonGlow:setOpacity(0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi)))
end

local function countVisibleSpecials(specialsPanel)
    local visibleCount = 0
    for _, child in ipairs(specialsPanel:getChildren()) do
        if child:isVisible() then
            visibleCount = visibleCount + 1
        end
    end
    return visibleCount
end

local function placePacksButton()
    if not packsButton then
        return
    end
    local specialsPanel = packsButton:getParent().specials
    local occupiedRows = math.ceil(countVisibleSpecials(specialsPanel) / SPECIALS_PER_ROW)
    packsButton:setMarginTop(occupiedRows * BUTTON_ROW_HEIGHT)
end

local function createPacksButton()
    local mainPanel = modules.game_mainpanel.optionsController.ui
    if not mainPanel or packsButton then
        return
    end
    local onPanel = mainPanel.onPanel
    packsButtonGlow = g_ui.createWidget('StorePacksGlow', onPanel)
    packsButton = g_ui.createWidget('StorePacksButton', onPanel)
    packsButton:setId('storePacksButton')
    packsButton:setTooltip(tr('Packs'))
    packsButton:addAnchor(AnchorTop, 'specials', AnchorTop)
    packsButton:addAnchor(AnchorLeft, 'specials', AnchorLeft)
    packsButton.onClick = toggle

    packsButtonGlow:addAnchor(AnchorTop, 'storePacksButton', AnchorTop)
    packsButtonGlow:addAnchor(AnchorBottom, 'storePacksButton', AnchorBottom)
    packsButtonGlow:addAnchor(AnchorLeft, 'storePacksButton', AnchorLeft)
    packsButtonGlow:addAnchor(AnchorRight, 'storePacksButton', AnchorRight)
    packsButtonGlow:setMargin(-3)

    placePacksButton()
    glowPulseEvent = cycleEvent(pulseGlow, GLOW_PULSE_INTERVAL_MS)
end

local function destroyPacksButton()
    if glowPulseEvent then
        removeEvent(glowPulseEvent)
        glowPulseEvent = nil
    end
    if packsButtonGlow then
        packsButtonGlow:destroy()
        packsButtonGlow = nil
    end
    if packsButton then
        packsButton:destroy()
        packsButton = nil
    end
end

local function onGameStart()
    isOpcodeRegistered = pcall(ProtocolGame.registerExtendedOpcode, STORE_PACKS_OPCODE, onExtendedOpcode)
    if not isOpcodeRegistered then
        g_logger.error('StorePacks: opcode ' .. STORE_PACKS_OPCODE .. ' is already taken by another module')
    end
    createPacksButton()
    scheduleEvent(placePacksButton, 300)
end

local function onGameEnd()
    hide()
    destroyPacksButton()
    if not isOpcodeRegistered then
        return
    end
    ProtocolGame.unregisterExtendedOpcode(STORE_PACKS_OPCODE)
    isOpcodeRegistered = false
end

function init()
    storePacksWindow = g_ui.displayUI('storepacks')
    storePacksWindow:hide()

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
    if storePacksWindow then
        storePacksWindow:destroy()
        storePacksWindow = nil
    end
end
