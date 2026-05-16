# MonetizationService

A scalable, modular monetization system for Roblox games. Handles gamepasses and developer products through auto-discovered domain modules. Designed to be dropped into any project as a Git submodule — add it once, extend it with game-specific domains.

---

## Architecture

**Three-layer design for clean separation of concerns:**

- **Orchestrator** (`init.server.luau`) — Discovers domains, routes purchases by ID, manages player lifecycle, handles Roblox callbacks
- **Domains** (e.g., `Plots`, `Treadmill`) — Pure CRUD state containers. Update purchase state only.
- **External Listeners** — External scripts register fallback callbacks to handle business logic (e.g., grant rewards, update UI)

This pattern ensures:
- Domains are reusable across multiple games
- Business logic stays outside the monetization system
- Zero coupling between reward systems and purchase routing

---

## Requirements

No external dependencies. Uses only Roblox core services:
- `MarketplaceService` — gamepass and product purchase callbacks
- `Players` — player join/leave lifecycle
- `RunService` — studio detection for logging

---

## Structure

```
MonetizationService/
├── init.server.luau     → orchestrator (place in ServerScriptService)
├── Types.luau           → shared type definitions
└── [Domain Modules]/    → Plots, Treadmill, etc. (auto-discovered as children)
    ├── Definition       → metadata (gamepasses, products)
    ├── Init(player)     → initialize player state
    ├── Cleanup(player)  → clean up on player leave
    ├── Get/SetGamepassOwnership(player, key, owned)
    ├── Get/SetProductPurchaseState(player, key, processed)
    └── RegisterFallback(listener) → external script integration
```

---

## Adding to a Project

### 1 — Add as a submodule

```bash
git submodule add https://github.com/koze/MonetizationService.git modules/MonetizationService
```

### 2 — Point Rojo at it

In your game's `default.project.json`:

```json
"ServerScriptService": {
  "$path": "modules/MonetizationService"
}
```

Rojo places `init.server.luau` directly into `ServerScriptService`.

### 3 — Create a domain module

Add a `ModuleScript` as a child of `MonetizationService` in `ServerScriptService`. The orchestrator auto-discovers it.

---

## Creating a Domain Module

Every domain must export a table with a `Definition` field and CRUD methods. Here's a minimal example:

```lua
--!strict

local Types = require(script.Parent.Types)

type DomainDefinition = Types.DomainDefinition
type DomainModule = Types.DomainModule
type FallbackEvent = Types.FallbackEvent

--[[
    Plots Domain Module
    Handles plot-related gamepasses and products.
]]

local Plots = {} :: DomainModule

--| Required: metadata (gamepass IDs, product IDs)
Plots.Definition = {
    Name = "Plots",
    Gamepasses = {
        ["PlotSlot2"] = 123456,   -- 2nd plot slot
        ["PlotSlot3"] = 123457,   -- 3rd plot slot
    },
    Products = {
        ["PlotClearFast"] = 987654,  -- instant clear (dev product)
    },
} :: DomainDefinition

--| Per-player state
local playerData: { [Player]: { [string]: boolean } } = {}

--| Required: initialize player state when they join
function Plots.Init(player: Player)
    playerData[player] = {
        PlotSlot2 = false,
        PlotSlot3 = false,
        PlotClearFast = false,
    }
end

--| Required: clean up on player leave (prevents memory leaks)
function Plots.Cleanup(player: Player)
    playerData[player] = nil
end

--| Required: get gamepass ownership
function Plots.GetGamepassOwnership(player: Player, key: string): boolean
    local data = playerData[player]
    if not data then return false end
    return data[key] == true
end

--| Required: set gamepass ownership
function Plots.SetGamepassOwnership(player: Player, key: string, owned: boolean)
    local data = playerData[player]
    if not data then return end
    data[key] = owned
end

--| Required: get product purchase state
function Plots.GetProductPurchaseState(player: Player, key: string): boolean
    local data = playerData[player]
    if not data then return false end
    return data[key] == true
end

--| Required: set product purchase state
function Plots.SetProductPurchaseState(player: Player, key: string, processed: boolean)
    local data = playerData[player]
    if not data then return end
    data[key] = processed
end

--| Fallback listeners (registered by external scripts)
local fallbackListeners: { (event: FallbackEvent) -> Enum.ProductPurchaseDecision? } = {}

--| Required: dispatch to fallback listeners
function Plots.DispatchFallback(event: FallbackEvent): Enum.ProductPurchaseDecision?
    for _, listener in ipairs(fallbackListeners) do
        local decision = listener(event)
        if decision ~= nil then
            return decision
        end
    end
    return nil
end

--| Required: register a fallback listener
function Plots.RegisterFallback(listener): () -> ()
    table.insert(fallbackListeners, listener)
    -- Return cleanup function
    return function()
        local idx = table.find(fallbackListeners, listener)
        if idx then
            table.remove(fallbackListeners, idx)
        end
    end
end

return Plots
```

---

## Integrating with External Services

External scripts (e.g., `LeaderstatService`, `InventoryService`) register fallback listeners to handle rewards:

```lua
local MonetizationService = require(game:GetService("ServerScriptService"):WaitForChild("MonetizationService"))
local Plots = MonetizationService -- or get via a reference system
local LeaderstatService = require(game:GetService("ServerScriptService").LeaderstatService)

--| Register a listener
Plots.RegisterFallback(function(event: FallbackEvent)
    --| Only handle products
    if event.Kind ~= "Product" then
        return nil
    end
    
    --| Check which product was purchased
    if event.Key == "PlotClearFast" then
        --| Award the benefit (e.g., clear player's plot instantly)
        if event.Player then
            LeaderstatService.ClearPlotInstant(event.Player)
        end
        return Enum.ProductPurchaseDecision.PurchaseGranted
    end
    
    return nil  -- Let another listener handle it
end)
```

---

## Purchase Flow

### Gamepass

```
1. Player clicks "Buy Gamepass" → MarketplaceService.PromptGamePassPurchaseFinished fires
2. Orchestrator routes by gamepass ID → finds domain
3. Domain.SetGamepassOwnership(player, key, true) → state updated
4. Domain.DispatchFallback(event) → external listeners invoked
5. Listener (e.g., LeaderstatService) grants rewards
6. Return ProductPurchaseDecision
```

### Developer Product

```
1. Player purchases product → MarketplaceService.ProcessReceipt callback fires
2. Orchestrator checks idempotency (processedReceipts table)
3. Orchestrator routes by product ID → finds domain
4. If player offline: defer to listeners or return NotProcessedYet
5. If player online:
   - Domain.SetProductPurchaseState(player, key, true)
   - Mark receipt as processed
   - Domain.DispatchFallback(event)
6. Listeners award rewards
7. Return ProductPurchaseDecision.PurchaseGranted
```

---

## Domain Rules

- **Definition.Name** must be unique. Never rename after shipping — orphans existing domain data.
- **All CRUD methods required** — Init, Cleanup, Get/SetGamepassOwnership, Get/SetProductPurchaseState, DispatchFallback, RegisterFallback.
- **Cleanup must release all per-player state** — missing or empty cleanup causes memory leaks.
- **State is domain-local** — no cross-domain dependencies. Each domain owns its data.
- **No blocking operations** — don't use loops or waits in callbacks. Dispatch quickly.

---

## Idempotency & Offline Handling

**Gamepasses** are idempotent by design — owning a gamepass multiple times = owning once.

**Developer Products** need explicit idempotency handling:
- Roblox may deliver the same receipt across multiple servers
- `processedReceipts` table keys on `PurchaseId` string
- Once processed, future deliveries return `PurchaseGranted` immediately

**Offline Players**:
- If player leaves before their product receipt arrives, orchestrator dispatches to fallback listeners
- Listeners can decide: grant now, save for later, or defer (`NotProcessedYet` for retry)
- Example: save purchase in a queue, grant when player rejoins

---

## Logging

Studio only (production disabled). Monitor service startup and events:

```
[MonetizationService] Set Plots.PlotSlot2 for PlayerName
[MonetizationService] Processed Plots.PlotClearFast for PlayerName
[MonetizationService] Registered 2 monetization module(s)
```

---

## License

MIT — free to use, modify, and redistribute.
