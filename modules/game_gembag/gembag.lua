gemBagWindow = nil
gemBagButton = nil
gemBagSlots = {}

local gemBagOpcode = 18
local gemBagSlotCount = 9

local function isValidGemItem(item)
	if not item then
		return false
	end

	return true
end

local function getSlotWidgetByIndex(slotIndex)
	return gemBagSlots[slotIndex]
end

local function sendGemBagAction(payload)
	local protocol = g_game.getProtocolGame()
	if not protocol then
		return
	end

	protocol:sendExtendedOpcode(gemBagOpcode, json.encode(payload))
end

local function requestSocketGem(slotIndex, itemId)
	sendGemBagAction({
		action = "socket",
		slotIndex = slotIndex,
		itemId = itemId
	})
end

local function requestUnsocketGem(slotIndex)
	sendGemBagAction({
		action = "unsocket",
		slotIndex = slotIndex
	})
end

local function updateSlotVisual(slotIndex, itemId)
	local slotWidget = getSlotWidgetByIndex(slotIndex)
	if not slotWidget then
		return
	end

	if itemId == 0 then
		slotWidget:setItemId(0)
		return
	end

	slotWidget:setItemId(itemId)
end

local function onGemBagOpcode(protocol, opcode, buffer)
	if opcode ~= gemBagOpcode then
		return
	end

	local state = json.decode(buffer)
	if not state or not state.slots then
		return
	end

    for slotIndex = 0, gemBagSlotCount - 1 do
        updateSlotVisual(slotIndex, state.slots[slotIndex + 1] or 0)
    end
end

local function onGemSlotClick(slotIndex)
	local slotWidget = getSlotWidgetByIndex(slotIndex)
	if not slotWidget then
		return
	end

	if slotWidget:getItemId() == 0 then
		return
	end

	requestUnsocketGem(slotIndex)
end

function toggle()
	if gemBagWindow:isVisible() then
		gemBagWindow:hide()
		return
	end

	gemBagWindow:show()
	gemBagWindow:raise()
	gemBagWindow:focus()
end

local function createGemSlotDropHandler(slotIndex)
	return function(widget, droppedWidget, mousePosition)
		if not droppedWidget or not droppedWidget.currentDragThing then
			return false
		end

		local item = droppedWidget.currentDragThing
		requestSocketGem(slotIndex, item:getId())
		return true
	end
end

local function onGameEnd()
	ProtocolGame.unregisterExtendedOpcode(gemBagOpcode)
	gemBagWindow:hide()
end

local function onGameStart()
	ProtocolGame.registerExtendedOpcode(gemBagOpcode, onGemBagOpcode)
end

function init()
	gemBagWindow = g_ui.displayUI('gembag')
	gemBagWindow:hide()

	local helmetSlotIcon = gemBagWindow:recursiveGetChildById('helmetSlotIcon')
	if helmetSlotIcon then
		helmetSlotIcon:setItemId(60938)
	end

	local bodySlotIcon = gemBagWindow:recursiveGetChildById('bodySlotIcon')
	if bodySlotIcon then
		bodySlotIcon:setItemId(60939)
	end

	local weaponSlotIcon = gemBagWindow:recursiveGetChildById('weaponSlotIcon')
	if weaponSlotIcon then
		weaponSlotIcon:setItemId(60941)
	end

    for slotIndex = 0, gemBagSlotCount - 1 do
        local slotWidget = gemBagWindow:recursiveGetChildById('gemSlot' .. slotIndex)
        gemBagSlots[slotIndex] = slotWidget

        slotWidget.onDrop = createGemSlotDropHandler(slotIndex)

        slotWidget.onDragEnter = function(widget, mousePosition)
            UIDragIcon:raise()
            return false
        end

        slotWidget.onMouseRelease = function(widget, mousePosition, mouseButton)
            if mouseButton == MouseRightButton then
                onGemSlotClick(slotIndex)
            end
        end
    end

	gemBagButton = modules.client_topmenu.addRightGameToggleButton('gemBagButton', tr('Gem Bag'), '/images/topbuttons/gembag', toggle)
	gemBagButton:setOn(false)

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

	gemBagButton:destroy()
	gemBagWindow:destroy()
end