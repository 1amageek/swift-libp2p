# CircuitRelay — CONTEXT
Scope/role: Circuit Relay v2 client + server (`P2PCircuitRelay`). Lets NAT'd peers receive
connections via a public relay. Read this before changing reservation/limit enforcement
or the relayed-connection wrapper.

A peer makes a reservation on a relay to receive inbound connections; other peers connect
through the relay to reach it. The relay server is the resource-control surface
(reservation and circuit limits), and the relay transport plugs `/p2p-circuit` addresses
into the normal dial path.

## Contracts (the load-bearing rules)
- `RelayTransport` / `RelayListener` integrate as a normal Transport+Listener for
  `/p2p-circuit` addresses. Inbound relayed connections are delivered through the listener
  registry: `RelayListener.init` registers itself with the client; the client's
  `handleStop()` routes the STOP connection to `listener.enqueue()`. Keep this delivery
  path — do not bypass the listener.
- `RelayedConnection` carries a single stream (no multiplexing of its own); the muxer
  upgrade runs on top of it like any secured connection.

## Invariants (must hold; tests guard them)
- The relay server enforces reservation and circuit limits (`maxReservations`,
  `maxCircuitsPerPeer`) and rejects over-limit RESERVE/CONNECT with a STATUS error. Do not
  weaken these to silent acceptance.
- Per-circuit data limits are enforced (in 8KB batches; small limits may slightly
  overshoot — a known coarseness, not a bypass).
- Reservation auto-renew (`autoRenewReservations`, default on) reschedules before expiry
  and surfaces `reservationExpired`/`reservationRenewed`/`reservationRenewalFailed`.

## Dependencies & seams
- `P2PCore`, `P2PMux` (MuxedStream), `P2PProtocols`, `P2PTransport` (Transport, Listener).
- Server local addresses are supplied by an injected `getLocalAddresses` closure.

## Wire protocol notes
- Protocol IDs: `/libp2p/circuit/relay/0.2.0/hop` (client↔relay),
  `/libp2p/circuit/relay/0.2.0/stop` (relay→target). Messages are length-prefixed protobuf.
- Hop: `RESERVE`/`CONNECT`/`STATUS` with `peer`, `reservation`, `limit`, `status`.
  Stop: `CONNECT`/`STATUS`. Relayed multiaddr:
  `/ip4/.../tcp/.../p2p/{relay}/p2p-circuit/p2p/{target}`.
- go-libp2p RESERVE/CONNECT/STATUS wire interop verified; rust ongoing.

## Build
- Host: `swift build`. Tests: `swift test --filter CircuitRelay` (with a timeout).

Last reviewed: 2026-06-25
