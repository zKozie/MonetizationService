--!strict

--[[
	MonetizationService Type Definitions

	This module defines the contract for the MonetizationService plugin system.
	It enables modular handling of gamepasses and developer products through
	domain-specific modules that act as pure CRUD state containers.

	Each domain module (e.g., Plots, Treadmill) registers itself and handles
	its own purchase state while delegating business logic to external fallback
	listeners. This architecture supports scalable monetization across multiple
	feature domains without tight coupling.
]]

--[[
	ReceiptInfo
	@desc Table structure passed to ProcessReceipt callback from MarketplaceService.
	       Contains all metadata about a developer product purchase.
	       Reference: MarketplaceService:ProcessReceipt
]]
export type ReceiptInfo = {
	--| Unique identifier for this specific purchase (idempotency key)
	PurchaseId: string,
	--| Player.UserId of the buyer
	PlayerId: number,
	--| Place ID where the purchase was initiated
	PlaceIdWherePurchased: number,
	--| Developer product ID that was purchased
	ProductId: number,
	--| Amount of Robux spent
	CurrencySpent: number,
	--| Type of currency (typically Enum.CurrencyType.Robux)
	CurrencyType: any,
	--| How the purchase was initiated (e.g., Enum.ProductPurchaseChannel)
	ProductPurchaseChannel: any,
}

--[[
	DomainDefinition
	@desc Metadata for a monetization domain. Domains are logical groupings of
	       gamepasses and products. Example: "Plots" domain manages plot-related
	       purchases, "Treadmill" domain manages treadmill upgrades, etc.
]]
export type DomainDefinition = {
	--| Unique domain name; used for fallback dispatch and logging
	Name: string,
	--| Map of {"key" -> gamepassId} for all gamepasses this domain manages
	--| Use key=0 to skip registration (useful for placeholder/future gamepasses)
	Gamepasses: { [string]: number },
	--| Map of {"key" -> productId} for all products this domain manages
	--| Use key=0 to skip registration (useful for placeholder/future products)
	Products: { [string]: number },
}

--[[
	FallbackEvent
	@desc Event passed to fallback listeners when a purchase is not directly
	       handled by the domain module. External scripts register listeners to
	       process the fallback and decide whether to accept or defer the purchase.
]]
export type FallbackEvent = {
	--| "Gamepass" or "Product" (identifies purchase type)
	Kind: "Gamepass" | "Product",
	--| Name of the domain that routed this purchase
	DomainName: string?,
	--| Key within the domain's Gamepasses/Products map
	Key: string?,
	--| Player instance (nil if player left server before receipt arrived)
	Player: Player?,
	--| Gamepass ID or Product ID
	Id: number,
	--| Full receipt info (only populated for product purchases)
	ReceiptInfo: ReceiptInfo?,
}

--[[
	FallbackListener
	@desc Callback registered by external scripts to handle fallback purchase events.
	       Listeners are called in FIFO order until one returns a ProductPurchaseDecision.
	       Return nil to defer to the next listener.
	@return nil to continue to next listener, or ProductPurchaseDecision to resolve
]]
export type FallbackListener = (event: FallbackEvent) -> Enum.ProductPurchaseDecision?

--[[
	DomainModule
	@desc Contract that all domain modules must implement. Domains are pure CRUD
	       containers for purchase state. Business logic lives in fallback listeners
	       registered by external scripts (e.g., LeaderstatService, InventoryService).

	       This design separates state management from business logic, enabling
	       flexible, composable monetization systems.
]]
export type DomainModule = {
	--| Static definition of this domain's gamepasses and products
	Definition: DomainDefinition,

	--| Initialize purchase state for a new player
	--| Called when: player joins server
	Init: (player: Player) -> (),

	--| Clean up purchase state when player leaves
	--| Called when: player leaves server
	Cleanup: (player: Player) -> (),

	--| Get gamepass ownership state for a player
	--| @param key gamepass key from Definition.Gamepasses
	--| @return true if player owns this gamepass
	GetGamepassOwnership: (player: Player, key: string) -> boolean,

	--| Set gamepass ownership state
	--| @param owned true to mark owned, false to mark not owned
	SetGamepassOwnership: (player: Player, key: string, owned: boolean) -> (),

	--| Get product purchase processing state
	--| @param key product key from Definition.Products
	--| @return true if this purchase has been processed
	GetProductPurchaseState: (player: Player, key: string) -> boolean,

	--| Mark a product purchase as processed
	--| Used for idempotency; once marked true, future receipts are skipped
	--| @param processed true to mark as processed
	SetProductPurchaseState: (player: Player, key: string, processed: boolean) -> (),

	--| Dispatch a fallback event to all registered listeners
	--| Called when a purchase cannot be handled directly by the domain
	--| @return nil if no listener handled it, otherwise ProductPurchaseDecision
	DispatchFallback: (event: FallbackEvent) -> Enum.ProductPurchaseDecision?,

	--| Register a fallback listener for this domain
	--| @param listener callback to invoke on fallback events
	--| @return cleanup function to unregister the listener
	RegisterFallback: (listener: FallbackListener) -> (() -> ()),
}

return nil
