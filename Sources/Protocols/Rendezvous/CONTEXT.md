# Rendezvous — CONTEXT
Scope/role: Rendezvous (`P2PRendezvous`). Namespace-based peer discovery without a full
DHT: peers register under named namespaces at a rendezvous point and others query them.

`RendezvousService` is the client (register/discover with local caching);
`RendezvousPoint` is the server (per-namespace registration store with cookie-based
paginated discovery). The server's job is bounded resource accounting.

## Contracts (the load-bearing rules)
- Both client and server are `class + Mutex` with separate Mutex instances for event state
  vs service/point state; events are emitted outside locks to avoid deadlock.
- Both conform to EventEmitting (single consumer); `shutdown() async` terminates the event
  stream. Keep the EventEmitting pattern.

## Invariants (must hold; tests guard them)
- The server enforces limits and rejects over-limit registration: per-peer
  (`maxRegistrationsPerPeer`, 100), per-namespace (`maxRegistrationsPerNamespace`, 1000),
  total namespaces (`maxNamespaces`, 10000). Expired registrations are cleaned periodically.
- Discovery is cookie-paginated: a response carries a cookie; the next query passes it back;
  a `nil` cookie ends pagination.
- Client registrations auto-refresh before expiry (`autoRefresh`, `refreshBuffer` 5m;
  `defaultTTL` 2h).

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr, EventEmitting), `P2PProtocols` (ProtocolService).

## Wire protocol notes
- Protocol ID `/rendezvous/1.0.0`. Message types: Register(0), RegisterResponse(1),
  Unregister(2), Discover(3), DiscoverResponse(4).

## Build
- Host: `swift build`. Tests: `swift test --filter Rendezvous` (with a timeout).

Last reviewed: 2026-06-25
