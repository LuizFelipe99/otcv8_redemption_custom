RuneShopController = Controller:new()

local RUNESHOP_OPCODE = 11

RuneShopController.runes = {}
RuneShopController.playerBalance = 0

RuneShopController.selectedRuneIndex = 0
RuneShopController.selectedRuneName = "Select a rune"
RuneShopController.selectedRunePrice = 0
RuneShopController.selectedClientId = 0
RuneShopController.selectedQuantity = 100

RuneShopController.isQty100  = true
RuneShopController.isQty300  = false
RuneShopController.isQty500  = false
RuneShopController.isQty1000 = false

RuneShopController.totalPrice = 0
RuneShopController.buyBtnText = "Select a rune"

RuneShopController.currentPage  = 1
RuneShopController.totalPages   = 1
RuneShopController.itemsPerPage = 16
RuneShopController.visibleRunes = {}
RuneShopController.pageLabel    = "1 / 1"

function RuneShopController:buildVisibleRunes()
    local startIndex = (self.currentPage - 1) * self.itemsPerPage + 1
    local endIndex   = math.min(startIndex + self.itemsPerPage - 1, #self.runes)

    self.visibleRunes = {}
    for i = startIndex, endIndex do
        self.visibleRunes[#self.visibleRunes + 1] = self.runes[i]
    end

    self.totalPages = math.ceil(#self.runes / self.itemsPerPage)
    self.pageLabel  = self.currentPage .. " / " .. self.totalPages
end

function RuneShopController:nextPage()
    if self.currentPage >= self.totalPages then return end
    self.currentPage = self.currentPage + 1
    self:buildVisibleRunes()
end

function RuneShopController:prevPage()
    if self.currentPage <= 1 then return end
    self.currentPage = self.currentPage - 1
    self:buildVisibleRunes()
end

function RuneShopController:resetSessionState()
    self.runes             = {}
    self.playerBalance     = 0
    self.currentPage       = 1
    self.totalPages        = 1
    self.visibleRunes      = {}
    self.pageLabel         = "1 / 1"
    self.selectedRuneIndex = 0
    self.selectedRuneName  = "Select a rune"
    self.selectedRunePrice = 0
    self.selectedClientId  = 0
    self.selectedQuantity  = 100
    self.isQty100  = true
    self.isQty300  = false
    self.isQty500  = false
    self.isQty1000 = false
    self.totalPrice        = 0
    self.buyBtnText        = "Select a rune"
end

function RuneShopController:selectRune(index)
    local rune = self.runes[index]
    if not rune then return end

    self.selectedRuneIndex = index
    self.selectedRuneName = rune.itemName
    self.selectedRunePrice = rune.price
    self.selectedClientId = rune.clientId

    self:updateTotal()
end

function RuneShopController:selectQuantity(quantity)
    self.selectedQuantity = quantity
    self.isQty100  = quantity == 100
    self.isQty300  = quantity == 300
    self.isQty500  = quantity == 500
    self.isQty1000 = quantity == 1000
    self:updateTotal()
end

function RuneShopController:updateTotal()
    if self.selectedRuneIndex == 0 then
        self.totalPrice = 0
        self.buyBtnText = "Select a rune"
        return
    end

    self.totalPrice = self.selectedRunePrice * self.selectedQuantity
    self.buyBtnText = "Buy " .. self.selectedQuantity .. " runes"
end

function RuneShopController:buyRune()
    if self.selectedRuneIndex == 0 then return end

    self:sendToServer({
        action = "buy",
        clientId = self.selectedClientId,
        quantity = self.selectedQuantity
    })
end

function RuneShopController:applyServerState(data)
    self.runes        = data.runes         or {}
    self.playerBalance = data.playerBalance or 0
    self.currentPage  = 1

    self:buildVisibleRunes()

    if not self.ui then
        self:show()
    else
        self:hide()
        self:show()
    end
end

function RuneShopController:applyBuyResult(data)
    self.playerBalance = data.newBalance or self.playerBalance

    if self.ui then
        self:hide()
        self:show()
    end
end

function RuneShopController:sendToServer(payload)
    local protocol = g_game.getProtocolGame()
    if not protocol then return end

    protocol:sendExtendedOpcode(RUNESHOP_OPCODE, json.encode(payload))
end

function RuneShopController:requestData()
    self:sendToServer({ action = "request" })
end

local function onExtendedOpcode(protocol, opcode, buffer)
    if opcode ~= RUNESHOP_OPCODE then return end

    local success, data = pcall(function()
        return json.decode(buffer)
    end)

    if not success or not data then return end

    if data.action == "data" then
        RuneShopController:applyServerState(data)

    elseif data.action == "buyResult" then
        RuneShopController:applyBuyResult(data)
    end
end

function RuneShopController:onGameStart()
    ProtocolGame.registerExtendedOpcode(RUNESHOP_OPCODE, onExtendedOpcode)
end

function RuneShopController:onGameEnd()
    ProtocolGame.unregisterExtendedOpcode(RUNESHOP_OPCODE)
    self:hide()
    self:resetSessionState()
end

function RuneShopController:show()
    if not self.ui then
        self:loadHtml('template/html/main_runeshop.html')
    end
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function RuneShopController:hide()
    if self.ui then
        self:unloadHtml()
    end
end

function RuneShopController:toggle()
    if self.ui and self.ui:isVisible() then
        self:hide()
    else
        self:show()
    end
end