# P2PRendezvous

## Overview

Rendezvous protocol implementation for namespace-based peer discovery.

Peers register themselves under named namespaces at a rendezvous point, and other peers can discover them by querying the same namespace. This enables lightweight, topic-based peer discovery without a full DHT.

## Protocol ID

- `/rendezvous/1.0.0`

## Dependencies

- `P2PCore` (PeerID, Multiaddr, EventEmitting)
- `P2PProtocols` (ProtocolService)

---

## File Structure

```
Sources/Protocols/Rendezvous/
├── RendezvousProtocol.swift     # Protocol constants
├── RendezvousMessages.swift     # Wire protocol message types
├── RendezvousError.swift        # Error types
├── RendezvousService.swift      # Client service (register/discover)
├── RendezvousPoint.swift        # Server-side rendezvous point
└── CONTEXT.md
```

## Key Types

| Type | Description |
|------|-------------|
| `RendezvousProtocol` | Protocol constants (ID, limits, defaults) |
| `RendezvousMessageType` | Wire protocol message type enum |
| `RendezvousRegistration` | A peer's registration entry |
| `RendezvousStatus` | Response status codes |
| `RendezvousError` | Error types for all operations |
| `RendezvousService` | Client service for registering/discovering |
| `RendezvousPoint` | Server-side rendezvous point |

---

## Architecture

### Client (RendezvousService)

- Manages local registration state
- Provides discovery with local caching
- Emits events via EventEmitting pattern (single consumer)
- Configuration: default TTL, auto-refresh, refresh buffer

### Server (RendezvousPoint)

- Stores registrations per namespace
- Supports cookie-based paginated discovery
- Enforces limits: per-peer, per-namespace, total namespaces
- Periodic expired registration cleanup
- Emits events via EventEmitting pattern (single consumer)

## Wire Protocol

### Message Types

| Type | Code | Direction | Description |
|------|------|-----------|-------------|
| Register | 0 | Client -> Server | Register under namespace |
| RegisterResponse | 1 | Server -> Client | Registration result |
| Unregister | 2 | Client -> Server | Remove registration |
| Discover | 3 | Client -> Server | Query namespace |
| DiscoverResponse | 4 | Server -> Client | Query results |

### Registration Flow

```
Client                    RendezvousPoint
   |-- Register(ns, ttl) ------>|
   |<-- RegisterResponse(ok) ---|
   |                            | (stores registration)
   |                            |
   |-- Discover(ns) ----------->|
   |<-- DiscoverResponse(peers) |
```

### Cookie-Based Pagination

```
Client                    RendezvousPoint
   |-- Discover(ns) ----------->|
   |<-- Response(peers, cookie) |
   |                            |
   |-- Discover(ns, cookie) --->|
   |<-- Response(more, cookie2) |
   |                            |
   |-- Discover(ns, cookie2) -->|
   |<-- Response(rest, nil) ----|
```

## Concurrency Model

- **Class + Mutex** for both RendezvousService and RendezvousPoint
- Separate Mutex instances for event state and service/point state
- Events emitted outside of locks to prevent deadlocks

## Lifecycle

- `shutdown()` - Terminates event stream (EventEmitting protocol)

## Configuration

### RendezvousService.Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `defaultTTL` | 2 hours | Default TTL for registrations |
| `autoRefresh` | true | Auto-refresh before expiry |
| `refreshBuffer` | 5 minutes | Buffer before expiry |

### RendezvousPoint.Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxRegistrationsPerPeer` | 100 | Max registrations per peer |
| `maxRegistrationsPerNamespace` | 1000 | Max registrations per namespace |
| `maxNamespaces` | 10000 | Max namespaces tracked |

## Tests

```
Tests/Protocols/RendezvousTests/
└── RendezvousTests.swift    # Comprehensive tests
```

## References

- [Rendezvous Spec](https://github.com/libp2p/specs/blob/master/rendezvous/README.md)
- [go-libp2p-rendezvous](https://github.com/libp2p/go-libp2p-rendezvous)
