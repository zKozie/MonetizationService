--!strict

--[[
	MonetizationService - Production-Ready Plugin Module
	
	A scalable, modular monetization system for Roblox games that handles
	gamepasses and developer products through domain-specific modules.
	
	ARCHITECTURE:
	- Orchestrator (this script) discovers and coordinates domain modules
	- Domain modules (e.g., Plots, Treadmill) manage purchase state as CRUD containers
	- External scripts register fallback listeners to handle business logic
	- Clean separation: Orchestrator routes, Domains store state, External scripts reward
	
	USAGE:
	1. Create a domain module in desync/MonetizationService/ with a Definition and CRUD methods
	2. External scripts call domain.RegisterFallback(listener) to handle purchases
	3. Listener receives FallbackEvent and returns ProductPurchaseDecision
	4. Orchestrator automatically discovers and connects all modules at startup
	
	EXAMPLE DOMAIN LISTENER:
		```lua
		local MonetizationService = ... -- get reference to domain
		local LeaderstatService = ...
		
		MonetizationService.RegisterFallback(function(event)
			if event.Kind == "Product" and event.Key == "PlotStarterCash" then
				LeaderstatService.AddMoney(event.Player, 250)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end)
		```
]]\n\nlocal MarketplaceService = game:GetService(\"MarketplaceService\")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(script.Types)

type DomainDefinition = Types.DomainDefinition
type DomainModule = Types.DomainModule
type FallbackEvent = Types.FallbackEvent
type ReceiptInfo = Types.ReceiptInfo

type Route = {
	DomainName: string,
	Domain: DomainModule,
	Key: string,
}

local IS_STUDIO = RunService:IsStudio()

--[[ STATE: Domain Registry ]]
local domainsByName: { [string]: DomainModule } = {}

--[[ STATE: Purchase Routing Tables (O(1) lookup by ID) ]]
--| Maps gamepass ID -> Route (for PromptGamePassPurchaseFinished handler)
local gamepassRoutes: { [number]: Route } = {}
--| Maps product ID -> Route (for ProcessReceipt handler)
local productRoutes: { [number]: Route } = {}

--[[ STATE: Idempotency Tracking ]]
--| Tracks processed product receipts by PurchaseId to prevent duplicate grants
--| Set to true when a receipt is successfully processed
local processedReceipts: { [string]: true } = {}

--[[
	debugLog(message: string)
	@desc Studio-only logging for monitoring service initialization and events.
	       Disabled in production to reduce console spam.
]]
local function debugLog(message: string)
	if IS_STUDIO then
		print(`[MonetizationService] {message}`)
	end
end

local function registerDomain(domain: DomainModule)
	local definition: DomainDefinition = domain.Definition
	assert(definition.Name ~= "", "[MonetizationService] Domain name is required")
	assert(domainsByName[definition.Name] == nil, `[MonetizationService] Duplicate domain: {definition.Name}`)

	domainsByName[definition.Name] = domain

	--| Register gamepass -> domain mapping
	for key, gamepassId in pairs(definition.Gamepasses) do
		if gamepassId <= 0 then
			--| Skip unassigned/placeholder IDs
			continue
		end

		assert(gamepassRoutes[gamepassId] == nil, `[MonetizationService] Duplicate gamepass id: {gamepassId}`)
		gamepassRoutes[gamepassId] = {
			DomainName = definition.Name,
			Domain = domain,
			Key = key,
		}
	end

	--| Register product -> domain mapping
	for key, productId in pairs(definition.Products) do
		if productId <= 0 then
			--| Skip unassigned/placeholder IDs
			continue
		end

		assert(productRoutes[productId] == nil, `[MonetizationService] Duplicate product id: {productId}`)
		productRoutes[productId] = {
			DomainName = definition.Name,
			Domain = domain,
			Key = key,
		}
	end
end

--[[
	DOMAIN DISCOVERY & REGISTRATION
	
	Scans all child modules for domain definitions and registers them.
	Domains are discovered by checking for a .Definition field.
	This enables zero-config setup: just add a domain module and it's registered.
]]
for _, child in script:GetChildren() do
	--| Only process ModuleScripts
	if not child:IsA("ModuleScript") then
		continue
	end

	--| Skip the Types module itself
	if child.Name == "Types" then
		continue
	end

	local childModule = require(child) :: any
	--| Module must be a table
	if type(childModule) ~= "table" then
		continue
	end

	--| Module must have a Definition field to be a valid domain
	if childModule.Definition == nil then
		continue
	end

	local domain = childModule :: DomainModule
	registerDomain(domain)
end

--[[
	PLAYER LIFECYCLE MANAGEMENT
	
	Each domain initializes and cleans up per-player state.
]]

--[[
	bindPlayer(player: Player)
	@desc Initialize purchase state for all domains when player joins.
	       Called on: Players.PlayerAdded and for pre-existing players at startup
]]
local function bindPlayer(player: Player)
	for _, domain in pairs(domainsByName) do
		domain.Init(player)
	end
end

--[[
	cleanupPlayer(player: Player)
	@desc Clean up purchase state for all domains when player leaves.
	       Called on: Players.PlayerRemoving
]]
local function cleanupPlayer(player: Player)
	for _, domain in pairs(domainsByName) do
		domain.Cleanup(player)
	end
end

--[[
	FALLBACK DISPATCH
	
	When a purchase cannot be handled directly by domain state, dispatch to
	fallback listeners registered by external scripts (e.g., LeaderstatService,
	InventoryService) to decide the purchase outcome.
]]

--[[
	dispatchDomainFallback(route: Route, event: FallbackEvent)
	@desc Trigger fallback listeners for a domain.
	@return ProductPurchaseDecision if handled, nil to continue
]]
local function dispatchDomainFallback(route: Route, event: FallbackEvent): Enum.ProductPurchaseDecision?
	return route.Domain.DispatchFallback(event)
end

--[[
	GAMEPASS PURCHASE HANDLER
	
	Called when MarketplaceService.PromptGamePassPurchaseFinished fires.
	Routes the gamepass to the appropriate domain and updates ownership state.
]]

--[[
	onPromptGamepassPurchaseFinished(player: Player, gamepassId: number, wasPurchased: boolean)
	@desc Handle gamepass purchase completion.
	       - Update domain state if purchase succeeded
	       - Dispatch fallback event for external scripts to handle rewards
	@param wasPurchased true if purchase was successful
]]
local function onPromptGamepassPurchaseFinished(player: Player, gamepassId: number, wasPurchased: boolean)
	--| Ignore cancelled/failed purchases
	if not wasPurchased then
		return
	end

	--| Look up which domain handles this gamepass
	local route = gamepassRoutes[gamepassId]
	if route == nil then
		warn(`[MonetizationService] Unknown gamepass id {gamepassId}`)
		return
	end

	--| Update domain state
	route.Domain.SetGamepassOwnership(player, route.Key, true)
	debugLog(`Set {route.DomainName}.{route.Key} for {player.Name}`)

	--| Dispatch to external listeners (e.g., grant rewards, update UI)
	dispatchDomainFallback(route, {
		Kind = "Gamepass",
		DomainName = route.DomainName,
		Key = route.Key,
		Player = player,
		Id = gamepassId,
		ReceiptInfo = nil,
	})
end

--[[
	PRODUCT RECEIPT HANDLER (CRITICAL)
	
	Called when a developer product purchase is completed.
	Must be implemented correctly per Roblox documentation.
	
	FLOW:
	1. Check idempotency: if receipt already processed, return PurchaseGranted
	2. Route receipt to appropriate domain
	3. If player is offline: defer to fallback listeners
	4. If player is online: update state, mark processed, dispatch fallback
	5. Return decision (must not yield indefinitely)
	
	IDEMPOTENCY:
	Same receipt (same PurchaseId) may be delivered multiple times across
	different servers. processedReceipts table ensures we don't double-grant.
]]

--[[
	onProcessReceipt(receiptInfo: ReceiptInfo)
	@desc Process a developer product purchase receipt from MarketplaceService.
	       Roblox calls this callback when a product purchase completes.
	@return ProductPurchaseDecision: PurchaseGranted, NotProcessedYet, or from fallback
]]
local function onProcessReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	--[[ IDEMPOTENCY CHECK ]]
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if processedReceipts[purchaseId] == true then
		--| Receipt already processed; return success to prevent redelivery
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[ ROUTE LOOKUP ]]
	local route = productRoutes[receiptInfo.ProductId]
	if route == nil then
		--| Unknown product; mark processed and return success to clear receipt
		warn(`[MonetizationService] Unknown product id {receiptInfo.ProductId}`)
		processedReceipts[purchaseId] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[ PLAYER LOOKUP ]]
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		--| Player has left; let fallback listeners decide (e.g., save for later)
		local decision = dispatchDomainFallback(route, {
			Kind = "Product",
			DomainName = route.DomainName,
			Key = route.Key,
			Player = nil,
			Id = receiptInfo.ProductId,
			ReceiptInfo = receiptInfo,
		})
		if decision ~= nil then
			if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
				processedReceipts[purchaseId] = true
			end
			return decision
		end
		--| No fallback handled it; defer for retry when player rejoins
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	--[[ UPDATE STATE & MARK PROCESSED ]]
	route.Domain.SetProductPurchaseState(player, route.Key, true)
	processedReceipts[purchaseId] = true
	debugLog(`Processed {route.DomainName}.{route.Key} for {player.Name}`)

	--[[ DISPATCH TO EXTERNAL HANDLERS ]]
	--| Fallback listeners (e.g., LeaderstatService) handle awarding rewards
	local decision = dispatchDomainFallback(route, {
		Kind = "Product",
		DomainName = route.DomainName,
		Key = route.Key,
		Player = player,
		Id = receiptInfo.ProductId,
		ReceiptInfo = receiptInfo,
	})
	if decision ~= nil then
		return decision
	end

	--| No fallback listeners; still mark as granted (state was set above)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[
	EVENT CONNECTIONS
	
	Wire up MarketplaceService callbacks and player lifecycle events.
]]
Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(cleanupPlayer)
MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPromptGamepassPurchaseFinished)
--| CRITICAL: ProcessReceipt must be set once and only once per server
MarketplaceService.ProcessReceipt = onProcessReceipt

--[[
	BIND PLAYERS FOR EXISTING PLAYERS AT STARTUP
	
	If the server restarts, players already in-game need their state initialized.
	Use task.spawn to avoid blocking startup.
]]
for _, player in Players:GetPlayers() do
	task.spawn(bindPlayer, player)
end

--[[ STARTUP LOG ]]
debugLog(`Registered {tostring(#script:GetChildren())} monetization module(s)`)
