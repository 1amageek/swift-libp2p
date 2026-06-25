# Connection — CONTEXT
Scope/role: connection-resilience components inside the `P2P` integration layer — pool,
reconnection, limits, gating, health monitoring. Read this before touching `ConnectionPool`
locking or the activity-tracking contract.

These types manage the lifecycle of established connections: the central `ConnectionPool`
plus the gater, limits, backoff/reconnection policy, and ping-based health monitor. The
load-bearing parts are the pool's internal-only access discipline and its atomic
activity-tracking.

## Contracts (the load-bearing rules)
- `ConnectionPool` is `internal` and accessed ONLY by the `Node` actor, which serializes all
  access. Keep it internal — there must be no external parallel access. (Node = public API,
  Pool = state.)
- All mutable pool state lives behind `Mutex<PoolState>` and is touched via `withLock`.
  Never call an async function inside `withLock`.
- **Activity tracking is atomic.** `ConnectionPool.connection(to:)` retrieves the connection
  AND records `lastActivity` in a single `withLock` — callers must not record activity
  separately (avoids TOCTOU and missed updates).

## Invariants (must hold; tests guard them)
- Connection state follows the state machine
  (Idle → Connecting → Connected → Disconnected → Reconnecting → … / Failed); trim/gate
  decisions are surfaced as `ConnectionEvent`s (`trimmedWithContext` carries structured
  `ConnectionTrimmedContext`; `trimConstrained` reports under-trim).

## Dependencies & seams
- Within `P2P`: `ConnectionID`/`ConnectionDirection`/`DisconnectReason` →
  `ConnectionState`; `BackoffStrategy` → `ReconnectionPolicy`; `ConnectionLimits`;
  `ConnectionGater` (protocol); `PingProvider` → `HealthMonitor` (actor) — all feeding
  `ConnectionPool`, owned by `Node`.

## Build
- Host: `swift build`. Tests: `swift test --filter ConnectionPool` (with a timeout).

Last reviewed: 2026-06-25
