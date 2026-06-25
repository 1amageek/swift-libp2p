# DCUtR — CONTEXT
Scope/role: Direct Connection Upgrade through Relay (`P2PDCUtR`). Upgrades a relayed
connection to a direct one via coordinated simultaneous dial (hole punching).

After a Circuit Relay connection exists, DCUtR exchanges observable addresses over the
relayed stream, measures RTT, and times a simultaneous dial so both sides open at once.
The timing seam is the load-bearing part.

## Contracts (the load-bearing rules)
- The dialer is injected (`dialer` closure); local addresses come from
  `getLocalAddresses`. The service coordinates timing but does not own the swarm.
- Timing: initiator sends CONNECT (its addrs), responder replies CONNECT (its addrs),
  initiator measures RTT, sends SYNC, waits RTT/2, then both dial simultaneously. Keep this
  ordering — it is what makes simultaneous-open succeed.

## Invariants (must hold; tests guard them)
- Reads are bounded by a timeout (`readMessage()` wraps reads with
  `withTimeout(configuration.timeout)`); never read unbounded.
- `upgradeToDirectConnection()` retries up to `maxAttempts` with exponential backoff and
  stops; it does not loop forever.

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr, Varint), `P2PMux` (MuxedStream), `P2PProtocols`.
- Works on top of Circuit Relay: success closes the relay path, failure keeps using it.

## Wire protocol notes
- Protocol ID `/libp2p/dcutr`. Length-prefixed protobuf `HolePunch { Type type = 1;
  repeated bytes ObsAddrs = 2; }` with `CONNECT = 100`, `SYNC = 300`.

## Build
- Host: `swift build`. Tests: `swift test --filter DCUtR` (with a timeout).

Last reviewed: 2026-06-25
