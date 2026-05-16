--!strict

local Types = require(script.Parent.Types)

type DomainModule = Types.DomainModule
type FallbackEvent = Types.FallbackEvent
type FallbackListener = Types.FallbackListener

local UNASSIGNED_ID = 0

local DEFINITION = {
	Name = "Plots",
	Gamepasses = {
		VIP = UNASSIGNED_ID,
		PaidTreadmill = UNASSIGNED_ID,
	},
	Products = {
		PlotStarterCash = UNASSIGNED_ID,
		PlotBuilderCash = UNASSIGNED_ID,
	},
}

local ownedGamepassesByPlayer: { [Player]: { [string]: boolean } } = {}
local processedProductsByPlayer: { [Player]: { [string]: boolean } } = {}
local fallbackListeners: { [number]: FallbackListener } = {}
local fallbackOrder: { number } = {}
local fallbackIdCounter = 0

local Plots: DomainModule = {
	Definition = DEFINITION,

	Init = function(player: Player)
		local ownership: { [string]: boolean } = {}
		for key in pairs(DEFINITION.Gamepasses) do
			ownership[key] = false
		end

		ownedGamepassesByPlayer[player] = ownership

		local processed: { [string]: boolean } = {}
		for key in pairs(DEFINITION.Products) do
			processed[key] = false
		end

		processedProductsByPlayer[player] = processed
	end,

	Cleanup = function(player: Player)
		ownedGamepassesByPlayer[player] = nil
		processedProductsByPlayer[player] = nil
	end,

	GetGamepassOwnership = function(player: Player, key: string): boolean
		local ownership = ownedGamepassesByPlayer[player]
		if ownership == nil then
			return false
		end

		return ownership[key] == true
	end,

	SetGamepassOwnership = function(player: Player, key: string, owned: boolean)
		local ownership = ownedGamepassesByPlayer[player]
		if ownership == nil then
			return
		end

		if DEFINITION.Gamepasses[key] ~= nil then
			ownership[key] = owned
		end
	end,

	GetProductPurchaseState = function(player: Player, key: string): boolean
		local processed = processedProductsByPlayer[player]
		if processed == nil then
			return false
		end

		return processed[key] == true
	end,

	SetProductPurchaseState = function(player: Player, key: string, processed: boolean)
		local state = processedProductsByPlayer[player]
		if state == nil then
			return
		end

		if DEFINITION.Products[key] ~= nil then
			state[key] = processed
		end
	end,

	DispatchFallback = function(event: FallbackEvent): Enum.ProductPurchaseDecision?
		for _, listenerId in ipairs(fallbackOrder) do
			local listener = fallbackListeners[listenerId]
			if listener == nil then
				continue
			end

			local decision = listener(event)
			if decision ~= nil then
				return decision
			end
		end

		return nil
	end,

	RegisterFallback = function(listener: FallbackListener): (() -> ())
		fallbackIdCounter += 1
		local listenerId = fallbackIdCounter
		fallbackListeners[listenerId] = listener
		table.insert(fallbackOrder, listenerId)

		return function()
			fallbackListeners[listenerId] = nil
			for index, value in ipairs(fallbackOrder) do
				if value == listenerId then
					table.remove(fallbackOrder, index)
					break
				end
			end
		end
	end,
}

return table.freeze(Plots)
