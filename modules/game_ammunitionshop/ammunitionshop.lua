AmmunitionShopController = Controller:new()

local AmmunitionShop_OPCODE = 12

AmmunitionShopController.runes = {}
AmmunitionShopController.playerBalance = 0

AmmunitionShopController.selectedRuneIndex = 0
AmmunitionShopController.selectedRuneName = "Select a rune"
AmmunitionShopController.selectedRunePrice = 0
AmmunitionShopController.selectedClientId = 0
AmmunitionShopController.selectedQuantity = 100

AmmunitionShopController.isQty1  = true
AmmunitionShopController.isQty100  = false
AmmunitionShopController.isQty300  = false
AmmunitionShopController.isQty500  = false
AmmunitionShopController.isQty1000 = false

AmmunitionShopController.totalPrice = 0
AmmunitionShopController.buyBtnText = "Select a rune"

AmmunitionShopController.currentPage  = 1
AmmunitionShopController.totalPages   = 1
AmmunitionShopController.itemsPerPage = 16
AmmunitionShopController.visibleRunes = {}
AmmunitionShopController.pageLabel    = "1 / 1"

function AmmunitionShopController:buildVisibleRunes()
    local startIndex = (self.currentPage - 1) * self.itemsPerPage + 1
    local endIndex   = math.min(startIndex + self.itemsPerPage - 1, #self.runes)

    self.visibleRunes = {}
    for i = startIndex, endIndex do
        self.visibleRunes[#self.visibleRunes + 1] = self.runes[i]
    end

    self.totalPages = math.ceil(#self.runes / self.itemsPerPage)
    self.pageLabel  = self.currentPage .. " / " .. self.totalPages
end

function AmmunitionShopController:nextPage()
    if self.currentPage >= self.totalPages then return end
    self.currentPage = self.currentPage + 1
    self:buildVisibleRunes()
end

function AmmunitionShopController:prevPage()
    if self.currentPage <= 1 then return end
    self.currentPage = self.currentPage - 1
    self:buildVisibleRunes()
end

function AmmunitionShopController:resetSessionState()
    self.runes             = {}
    self.playerBalance     = 0
    self.currentPage       = 1
    self.totalPages        = 1
    self.visibleRunes      = {}
    self.pageLabel         = "1 / 1"
    self.selectedRuneIndex = 0
    self.selectedRuneName  = "Select ammunition"
    self.selectedRunePrice = 0
    self.selectedClientId  = 0
    self.selectedQuantity  = 100
    self.isQty1  = true
    self.isQty100  = false
    self.isQty300  = false
    self.isQty500  = false
    self.isQty1000 = false
    self.totalPrice        = 0
    self.buyBtnText        = "Select ammunition"
end

function AmmunitionShopController:selectRune(index)
    local rune = self.runes[index]
    if not rune then return end

    self.selectedRuneIndex = index
    self.selectedRuneName = rune.itemName
    self.selectedRunePrice = rune.price
    self.selectedClientId = rune.clientId

    self:updateTotal()
end

function AmmunitionShopController:selectQuantity(quantity)
    self.selectedQuantity = quantity
    self.isQty1    = quantity == 1
    self.isQty100  = quantity == 100
    self.isQty300  = quantity == 300
    self.isQty500  = quantity == 500
    self.isQty1000 = quantity == 1000
    self:updateTotal()
end

function AmmunitionShopController:updateTotal()
    if self.selectedRuneIndex == 0 then
        self.totalPrice = 0
        self.buyBtnText = "Select ammunition"
        return
    end

    self.totalPrice = self.selectedRunePrice * self.selectedQuantity
    self.buyBtnText = "Buy " .. self.selectedQuantity .. " ammunition"
end

function AmmunitionShopController:buyRune()
    if self.selectedRuneIndex == 0 then return end

    self:sendToServer({
        action = "buy",
        clientId = self.selectedClientId,
        quantity = self.selectedQuantity
    })
end

function AmmunitionShopController:applyServerState(data)
    self.runes = data.ammunitions or {}
    self.playerBalance = data.playerBalance or 0
    self.currentPage = 1

    self:buildVisibleRunes()

    if not self.ui then
        self:show()
    else
        self:hide()
        self:show()
    end
end

function AmmunitionShopController:applyBuyResult(data)
    self.playerBalance = data.newBalance or self.playerBalance

    if self.ui then
        self:hide()
        self:show()
    end
end

function AmmunitionShopController:sendToServer(payload)
    local protocol = g_game.getProtocolGame()
    if not protocol then return end

    protocol:sendExtendedOpcode(AmmunitionShop_OPCODE, json.encode(payload))
end

function AmmunitionShopController:requestData()
    self:sendToServer({ action = "request" })
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= AmmunitionShop_OPCODE then return end


    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then
        return
    end


    if data.action == "data" then
        AmmunitionShopController:applyServerState(data)
    elseif data.action == "buyResult" then
        AmmunitionShopController:applyBuyResult(data)
    end
end

function AmmunitionShopController:onGameStart()
    ProtocolGame.registerExtendedOpcode(AmmunitionShop_OPCODE, onExtendedOpcode)
end

function AmmunitionShopController:onGameEnd()
    ProtocolGame.unregisterExtendedOpcode(AmmunitionShop_OPCODE)
    self:hide()
    self:resetSessionState()
end

function AmmunitionShopController:show()
    if not self.ui then
        self:loadHtml('template/html/main_ammunitionshop.html')
    end
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function AmmunitionShopController:hide()
    if self.ui then
        self:unloadHtml()
    end
end

function AmmunitionShopController:toggle()
    if self.ui and self.ui:isVisible() then
        self:hide()
    else
        self:show()
    end
end