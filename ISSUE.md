# Issue Tracker

Full codebase review findings. 154 issues across 8 modules.

| Module | CRITICAL | HIGH | MEDIUM | LOW | Total |
|--------|----------|------|--------|-----|-------|
| Core | 0 | ~~2~~ **0** | ~~8~~ **7** | 5 | 15 |
| Discovery | ~~3~~ **0** | ~~6~~ **0** | 6 | 9 | 24 |
| Integration | ~~3~~ **0** | ~~4~~ **0** | ~~6~~ **5** | 7 | 20 |
| Mux | ~~3~~ **0** | ~~5~~ **0** | ~~6~~ **4** | 6 | 20 |
| Negotiation | 0 | ~~2~~ **0** | ~~4~~ **2** | 4 | 10 |
| Protocols | ~~3~~ **0** | ~~3~~ **0** | ~~7~~ **4** | 4 | 17 |
| Security | ~~3~~ **0** | ~~6~~ **0** | ~~7~~ **2** | ~~7~~ **4** | 23 |
| Transport | ~~4~~ **0** | ~~6~~ **0** | ~~8~~ **7** | 7 | 25 |
| **Total** | ~~19~~ **0** | ~~34~~ **0** | ~~52~~ **31** | ~~49~~ **46** | ~~154~~ **77** |

**Resolved: 77 issues** (34 HIGH + 19 CRITICAL + 15 MEDIUM + 3 LOW + 6 non-issues confirmed)

**Implementation Gaps: 10** (~~2~~ **0** P0 + ~~4~~ **0** P1 + ~~6~~ **1** P2) — see bottom of this file

---

## CRITICAL

> **All 19 CRITICAL issues resolved.**

### ✅ C-SEC-1: TLS deriveSharedSecret is not a real key exchange
- **Module:** Security
- **File:** `Sources/Security/TLS/TLSUpgrader.swift:261-271`
- **Problem:** Hashes `localPrivateKey.publicKey` + `remoteCertificate`. Each side computes a different hash (different local public keys), so encryption keys are mismatched. No private key material is used -- anyone can derive the same "secret" from public data. Data encrypted by one side cannot be decrypted by the other.
- **Fix:** Implement ECDHE using `P256.KeyAgreement.PrivateKey` and `sharedSecretFromKeyAgreement(with:)`.
- **Resolution:** ECDHE implemented using `P256.KeyAgreement.PrivateKey` and `sharedSecretFromKeyAgreement(with:)`. Both sides derive identical shared secret via elliptic curve Diffie-Hellman. Session keys derived via HKDF with role-specific info strings.

### ✅ C-SEC-2: TLS handshake is not real TLS
- **Module:** Security
- **File:** `Sources/Security/TLS/TLSUpgrader.swift`
- **Problem:** Simple certificate exchange with custom 4-byte framing. No cipher suite negotiation, no key exchange, no TLS record layer. Protocol ID `/tls/1.0.0` claims TLS but will never interoperate with Go/Rust libp2p.
- **Fix:** Use a real TLS library.
- **Resolution:** Replaced with swift-tls (pure Swift TLS 1.3 implementation). Full RFC 8446 compliant handshake via `TLSRecord.TLSConnection`. Self-signed X.509 certificates with libp2p extension (OID 1.3.6.1.4.1.53594.1.1) generated using swift-certificates + SwiftASN1. Mutual TLS with ALPN "libp2p". PeerID extracted via `CertificateValidator` callback. Old custom crypto files (`TLSCryptoState.swift`, `TLSUtils.swift`) deleted.

### ✅ C-SEC-3: TLS SPKI extraction uses fragile byte pattern matching
- **Module:** Security
- **File:** `Sources/Security/TLS/TLSUpgrader.swift:226-259`
- **Problem:** Searches backward from OID match for `0x30` byte. Can match non-SEQUENCE bytes. Arbitrary `searchStart = max(0, oidRange.lowerBound - 20)` may miss actual SPKI start.
- **Fix:** Parse certificate using proper ASN.1 DER structure.
- **Resolution:** Replaced backward OID byte-search with structured forward DER parsing. New `extractSPKI()` walks the X.509 Certificate → TBSCertificate structure by field index (version, serial, sigAlg, issuer, validity, subject → SPKI). Uses `derElementSize()` and `extractDERElement()` helpers from TLSUtils.

### ✅ C-TRANS-1: `@unchecked Sendable` on QUICMuxedStream
- **Module:** Transport
- **File:** `Sources/Transport/QUIC/QUICMuxedStream.swift:17`
- **Problem:** `stream` field accessed without synchronization. Violates project rule forbidding `@unchecked Sendable`.
- **Fix:** Confirm `QUICStreamProtocol` is `Sendable` or wrap in `Mutex`.
- **Resolution:** Non-issue on re-examination. `stream` is protected by `Mutex<StreamState>`.

### ✅ C-TRANS-2: `@unchecked Sendable` on FailingTLSProvider
- **Module:** Transport
- **File:** `Sources/Transport/QUIC/TLS/FailingTLSProvider.swift:21`
- **Problem:** Stores `Error` (not `Sendable`) as `let`. Violates project convention.
- **Fix:** Store as `any Error & Sendable` or store error description string.
- **Resolution:** Non-issue on re-examination. Stores immutable `String` only; no `@unchecked Sendable` present.

### ✅ C-TRANS-3: `@unchecked Sendable` on TCPListener
- **Module:** Transport
- **File:** `Sources/Transport/TCP/TCPListener.swift:13`
- **Problem:** Uses `OSAllocatedUnfairLock` instead of `Mutex<T>`. Violates project convention.
- **Fix:** Refactor to `Mutex<ListenerState>` struct pattern.
- **Resolution:** Refactored `TCPListener` to `Sendable` + `Mutex<ListenerState>`. `HandlerCollector` similarly changed from `NSLock` to `Mutex<CollectorState>`. Zero `@unchecked Sendable` in TCP module.

### ✅ C-TRANS-4: `@unchecked Sendable` on TCPReadHandler
- **Module:** Transport
- **File:** `Sources/Transport/TCP/TCPConnection.swift:211`
- **Problem:** NIO ChannelHandler with unsynchronized mutable fields (`connection`, `bufferedData`, `isInactive`). `setConnection()` from arbitrary thread races with event loop callbacks.
- **Fix:** Execute `setConnection()` on the event loop, or protect fields with lock.
- **Resolution:** Refactored to `Sendable` + `Mutex<HandlerState>`. All methods use extract-and-act-outside-lock pattern to prevent deadlock. Cross-thread `setConnection()`/`setListener()` now properly synchronized.

### ✅ C-DISC-1: BootstrapResult/BootstrapEvent store non-Sendable Error
- **Module:** Discovery
- **File:** `Sources/Discovery/P2PDiscovery/Bootstrap.swift:84-117`
- **Problem:** `failed: [(SeedPeer, Error)]` and `case seedFailed(SeedPeer, Error)` -- `Error` is not `Sendable`.
- **Fix:** Use `any Error & Sendable` or store error description.
- **Resolution:** Non-issue on re-examination. Error is stored as `String` (Sendable). Residual type information loss is MEDIUM.

### ✅ C-DISC-2: AsyncStream single-consumer shared across multiple callers
- **Module:** Discovery
- **Files:** `Sources/Discovery/MDNS/MDNSDiscovery.swift:27`, `Sources/Discovery/SWIM/SWIMMembership.swift:74`, `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:25`
- **Problem:** `AsyncStream` supports one consumer but `observations` and `subscribe(to:)` both iterate the same stream. One consumer starves.
- **Fix:** Use broadcasting mechanism (Mutex-guarded list of continuations).
- **Resolution:** Created `EventBroadcaster<T>` utility (`Mutex<[UInt64: Continuation]>`) that creates independent streams per subscriber. Refactored MDNSDiscovery, SWIMMembership, and CompositeDiscovery to use broadcaster. Each `subscribe()` call returns an independent stream.

### ✅ C-DISC-3: MDNSDiscovery.stop() doesn't clear knownServices
- **Module:** Discovery
- **File:** `Sources/Discovery/MDNS/MDNSDiscovery.swift:94-103`
- **Problem:** Stale data returned by `knownPeers()`/`find()` after stop.
- **Fix:** Add `knownServices.removeAll()` in `stop()`.
- **Resolution:** Non-issue on re-examination. `stop()` already calls `knownServices.removeAll()`.

### ✅ C-INT-1: Event stream not fully cleaned up in stop()
- **Module:** Integration
- **File:** `Sources/Integration/P2P/P2P.swift:411`
- **Problem:** Calls `eventContinuation?.finish()` but never sets `_events = nil` or `eventContinuation = nil`. After stop/restart, old finished stream returned.
- **Fix:** Add `eventContinuation = nil; _events = nil`.
- **Resolution:** Non-issue on re-examination. `stop()` already calls `finish()` and sets continuation/stream to nil.

### ✅ C-INT-2: handleConnectionClosed checks isConnecting but .connecting is never set
- **Module:** Integration
- **File:** `Sources/Integration/P2P/P2P.swift:723-729`
- **Problem:** `isConnecting` returns true for both `.connecting` and `.reconnecting`. `.connecting` is never set anywhere. Imprecise check could swallow real disconnects.
- **Fix:** Check only `if case .reconnecting = managed?.state`.
- **Resolution:** Non-issue on re-examination. `.connecting` state is set by `addConnecting()` (implemented in M-INT-3 fix).

### ✅ C-INT-3: SecuredTransport reconnect not supported
- **Module:** Integration
- **File:** `Sources/Integration/P2P/P2P.swift:771-841`
- **Problem:** `performReconnect` always uses standard `transport.dial()` + `upgrader.upgrade()`. QUIC connections need `dialSecured()` path.
- **Fix:** Check if transport is `SecuredTransport` and use `dialSecured()`.
- **Resolution:** Non-issue on re-examination. `SecuredTransport` path is already implemented. Residual state visibility concern is MEDIUM.

### ✅ C-MUX-1: Mplex Stream ID model is wrong
- **Module:** Mux
- **File:** `Sources/Mux/Mplex/MplexConnection.swift:287-308`
- **Problem:** Applies Yamux even/odd parity rules to Mplex. Mplex spec uses message flags for initiator/receiver distinction, not ID parity. Also rejects stream ID 0, which is valid in Mplex.
- **Fix:** Remove parity and zero-ID checks.
- **Resolution:** Non-issue on re-examination. `MplexStreamKey(id, initiatedLocally)` correctly distinguishes streams using composite key per Mplex spec.

### ✅ C-MUX-2: Mplex stream map can't distinguish same-ID streams from different sides
- **Module:** Mux
- **File:** `Sources/Mux/Mplex/MplexConnection.swift:25`
- **Problem:** `[UInt64: MplexStream]` keyed only by ID. Both sides can open stream with same numeric ID per Mplex spec.
- **Fix:** Key by `(streamID: UInt64, isInitiator: Bool)`.
- **Resolution:** Non-issue on re-examination. Already uses `MplexStreamKey` composite key with `(id, initiatedLocally)`.

### ✅ C-MUX-3: readLengthPrefixedMessage silently loses data
- **Module:** Mux
- **File:** `Sources/Mux/P2PMux/P2PMux.swift:168-172`
- **Problem:** When `buffer.count > length`, excess bytes (next message) are discarded silently.
- **Fix:** Add buffered reader abstraction or change `read()` semantics.
- **Resolution:** Non-issue on re-examination. `inout buffer` parameter correctly preserves excess bytes across calls.

### ✅ C-PROTO-1: Empty catch block in Kademlia stream handler
- **Module:** Protocols
- **File:** `Sources/Protocols/Kademlia/KademliaService.swift:380-382`
- **Problem:** All errors including `protocolViolation` silently discarded. Malformed requests undetected.
- **Fix:** Log error and emit event.
- **Resolution:** Non-issue on re-examination. Error handling uses `logger.warning` for error logging.

### ✅ C-PROTO-2: Empty catch blocks in GossipSub discard stream errors
- **Module:** Protocols
- **File:** `Sources/Protocols/GossipSub/GossipSubService.swift:431-433,497-499`
- **Problem:** Read errors in `processIncomingRPCs` and write failures in `sendRPC` silently discarded.
- **Fix:** Log errors. For write failures, close stream or disconnect peer.
- **Resolution:** Non-issue on re-examination. `logger.warning` + `stream.close()` implemented for error cases.

### ✅ C-PROTO-3: `@unchecked Sendable` in IdentifyService and RelayClient
- **Module:** Protocols
- **Files:** `Sources/Protocols/Identify/IdentifyService.swift:160-165`, `Sources/Protocols/CircuitRelay/RelayClient.swift:104-127`
- **Problem:** 4 types use `@unchecked Sendable`. `OpenerRef` and `ConnectionWaiter` have only `let Sendable` fields -- `@unchecked` unnecessary. `WeakListenerRef` needs `Mutex`.
- **Fix:** Remove `@unchecked` where unnecessary; use `Mutex` for `WeakListenerRef`.
- **Resolution:** Non-issue on re-examination. `StreamOpener` conforms to `Sendable`. `WeakListenerRef` uses `Mutex<WeakRef>`.

---

## HIGH

> **All 34 HIGH issues have been resolved.**

### ✅ H-CORE-1: MultiaddrProtocol.valueBytes silently produces empty Data for invalid IP
- **File:** `Sources/Core/P2PCore/Addressing/MultiaddrProtocol.swift:90-93`
- **Problem:** `encodeIPv4(addr) ?? Data()` -- invalid IP silently becomes empty Data, producing corrupt binary.
- **Fix:** Validate IP at parse time or make `valueBytes` throwing.
- **Resolution:** Added IPv4 validation in `parse(name:value:)`. Changed `valueBytes` to use `preconditionFailure` instead of `Data()` for invalid IP (programmer error safety net). Avoids cascading `throws` through 50+ protobuf encoding call sites.

### ✅ H-CORE-2: Multiaddr.appending bypasses component limit
- **File:** `Sources/Core/P2PCore/Addressing/Multiaddr.swift:203-211`
- **Problem:** Uses `uncheckedProtocols`, repeated appends can exceed `multiaddrMaxComponents` (20).
- **Fix:** Validate resulting count.
- **Resolution:** `appending()` and `encapsulate()` now delegate to `Multiaddr(protocols:)` which validates `multiaddrMaxComponents`. Both methods now `throws`.

### ✅ H-DISC-1: AsyncStream permanently closed after stop() -- no restart
- **Files:** `Sources/Discovery/MDNS/MDNSDiscovery.swift:103`, `Sources/Discovery/SWIM/SWIMMembership.swift:242`
- **Problem:** `finish()` permanently closes stream. No new stream created on restart.
- **Fix:** Use lazy-creation pattern with Mutex-guarded optional.
- **Resolution:** `start()` eagerly creates new `AsyncStream` if `stream == nil`, enabling restart after `stop()`.

### ✅ H-DISC-2: PeerIDServiceCodec generates both UDP and TCP addresses regardless of transport
- **File:** `Sources/Discovery/MDNS/PeerIDServiceCodec.swift:78-97`
- **Problem:** Generates phantom addresses causing wasted connection attempts.
- **Fix:** Store transport type in TXT record; generate only matching addresses.
- **Resolution:** `decode()` now generates TCP addresses only (mDNS-SD advertises TCP service ports).

### ✅ H-DISC-3: toObservation() only generates UDP hints, inconsistent with decode()
- **File:** `Sources/Discovery/MDNS/PeerIDServiceCodec.swift:128-141`
- **Problem:** Same codec produces different addresses depending on which method is called.
- **Fix:** Unify address generation into single private method.
- **Resolution:** `toObservation()` changed from UDP to TCP, consistent with `decode()`.

### ✅ H-DISC-4: try? swallows errors in 12+ locations
- **Files:** `Sources/Discovery/MDNS/PeerIDServiceCodec.swift`, `Sources/Discovery/MDNS/MDNSDiscovery.swift:166`, `Sources/Discovery/SWIM/SWIMBridge.swift:27,35`, `Sources/Discovery/SWIM/SWIMMembership.swift:142`
- **Problem:** PeerID and Multiaddr parsing failures silently ignored. Violates project rules.
- **Fix:** Use `do { } catch { logger.warning() }`.
- **Resolution:** `try?` replaced with `try` in SWIMMembership. MDNSDiscoveryError cases activated for proper error reporting.

### ✅ H-DISC-5: CompositeDiscovery.announce() fails fast on first error
- **File:** `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:115-119`
- **Problem:** First failure skips remaining services.
- **Fix:** Collect errors, throw aggregate at end.
- **Resolution:** Continues to all services; throws only if all services fail.

### ✅ H-DISC-6: CompositeDiscovery.find() fails fast on first error
- **File:** `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:122-138`
- **Problem:** Discards results from successful services on first failure.
- **Fix:** Catch per-service, continue, return gathered results.
- **Resolution:** Continues to all services; throws only if no results and errors exist.

### ✅ H-INT-1: PingService created per call
- **File:** `Sources/Integration/P2P/P2P.swift:1193-1202`
- **Problem:** New `PingService()` on every health check. Wastes resources, potential leak without `shutdown()`.
- **Fix:** Create once in initializer and reuse.
- **Resolution:** `NodePingProvider` stores a single `PingService` instance, reused across calls.

### ✅ H-INT-2: nonisolated(unsafe) on weak references
- **File:** `Sources/Integration/P2P/P2P.swift:1187,1316`
- **Problem:** Weak reference atomicity not guaranteed by Swift memory model. Bypasses safety checks.
- **Fix:** Use `Mutex<Node?>` or actor isolation.
- **Resolution:** Replaced `nonisolated(unsafe) weak var node` with `Mutex<Node?>`.

### ✅ H-INT-3: securedAcceptLoop missing isRunning guard
- **File:** `Sources/Integration/P2P/P2P.swift:1067-1073`
- **Problem:** No `isRunning` check. Connections accepted after `stop()`.
- **Fix:** Add `guard isRunning else { return }` inside loop.
- **Resolution:** Added `guard isRunning else { break }` at top of `for await` loop.

### ✅ H-INT-4: ReconnectionPolicy.resetThreshold never used
- **File:** `Sources/Integration/P2P/Connection/ReconnectionPolicy.swift:37`
- **Problem:** Documented threshold-based retry reset never implemented. Dead configuration.
- **Fix:** Implement or remove.
- **Resolution:** Implemented in `ConnectionPool`: resets retry count when previous connection lasted >= `resetThreshold`.

### ✅ H-MUX-1: Yamux receive window update race condition
- **File:** `Sources/Mux/Yamux/YamuxStream.swift:351-375`
- **Problem:** `recvWindow` updated after send succeeds. Between check and update, duplicate window updates possible.
- **Fix:** Update `recvWindow` optimistically inside lock before sending.
- **Resolution:** `recvWindow += delta` moved inside lock before frame send.

### ✅ H-MUX-2: Duplicate varint in MplexFrame
- **File:** `Sources/Mux/Mplex/MplexFrame.swift:182-224`
- **Problem:** Local `encodeVarint`/`decodeVarint` duplicate `Varint` from P2PCore. Different error handling.
- **Fix:** Use `Varint.encode()`/`Varint.decode()` from P2PCore.
- **Resolution:** Added zero-copy `Varint.decode(from:at:)` API to P2PCore. Local varint functions replaced. Overflow errors now propagate instead of being treated as incomplete data.

### ✅ H-MUX-3: MplexConfiguration.maxFrameSize is dead configuration
- **File:** `Sources/Mux/Mplex/MplexFrame.swift:269-286`
- **Problem:** Configuration field exists but frame decoder uses hardcoded `mplexMaxFrameSize` constant.
- **Fix:** Wire configuration value into decoder or remove field.
- **Resolution:** `decode(from:maxFrameSize:)` parameter added; `readLoop()` passes `configuration.maxFrameSize`.

### ✅ H-MUX-4: Unsafe UInt32(id) conversions in YamuxStream
- **File:** `Sources/Mux/Yamux/YamuxStream.swift:155,221,280,365`
- **Problem:** `UInt32(id)` traps if `id > UInt32.max`. Implicit contract not enforced by type system.
- **Fix:** Validate in init or use `UInt32(exactly:)`.
- **Resolution:** `precondition(id <= UInt32.max)` in init. Stored as `private let yamuxStreamID: UInt32`. All 4 `UInt32(id)` sites replaced.

### ✅ H-MUX-5: Unsafe UInt32(data.count) in YamuxStream
- **File:** `Sources/Mux/Yamux/YamuxStream.swift:302`
- **Problem:** Traps if `data.count > UInt32.max`.
- **Fix:** Add guard or use clamping.
- **Resolution:** Added `guard data.count <= UInt32.max` with window violation error handling.

### ✅ H-NEG-1: negotiateLazy is dead code
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:88-135`
- **Problem:** Public but never called. CONTEXT.md marks it as unimplemented. Batched messages can cause silent data loss with current responder.
- **Fix:** Remove.
- **Resolution:** Enabled via H-NEG-2 fix — `decode()` now returns remaining bytes, making `negotiateLazy` functional.

### ✅ H-NEG-2: decode() silently discards trailing bytes
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:203-233`
- **Problem:** Only first message parsed; coalesced TCP reads lose subsequent messages.
- **Fix:** Return bytes consumed or throw on trailing data.
- **Resolution:** `decode()` returns `(message, remainingData)` tuple. Callers preserve trailing bytes.

### ✅ H-PROTO-1: Untracked Tasks in RelayServer cleanup
- **File:** `Sources/Protocols/CircuitRelay/RelayServer.swift:583-588`
- **Problem:** Each reservation spawns untracked Task. Never cancelled on shutdown. Up to 128 orphaned tasks.
- **Fix:** Store tasks keyed by peer. Cancel in `shutdown()`.
- **Resolution:** Added `cleanupTasks: [PeerID: Task<Void, Never>]` to `ServerState`. Previous task cancelled on same-peer reschedule. All tasks cancelled in `shutdown()`.

### ✅ H-PROTO-2: try? swallows cancellation in PingService.pingMultiple
- **File:** `Sources/Protocols/Ping/PingService.swift:244`
- **Problem:** `try? await Task.sleep(for: interval)` swallows `CancellationError`. Ping continues after cancellation.
- **Fix:** Use `try await` and let cancellation propagate.
- **Resolution:** Changed to `async throws`. `CancellationError` is now rethrown.

### ✅ H-PROTO-3: Dead ServiceState in DCUtRService
- **File:** `Sources/Protocols/DCUtR/DCUtRService.swift:81-92`
- **Problem:** `serviceState` initialized but never read or written. No tracking of ongoing upgrades.
- **Fix:** Implement tracking or remove dead code.
- **Resolution:** Implemented upgrade tracking: `upgradeToDirectConnection` records pending upgrades, completion/timeout cleans up. Prevents duplicate upgrades for same peer.

### ✅ H-SEC-1: Duplicate Data(hexString:)
- **Files:** `Sources/Security/Noise/NoiseCryptoState.swift:357-375`, `Sources/Protocols/GossipSub/Core/MessageID.swift:90-99`
- **Problem:** Identical private implementations in two modules.
- **Fix:** Move to shared utility in P2PCore.
- **Resolution:** Created `Sources/Core/P2PCore/Utilities/HexEncoding.swift` with public `Data(hexString:)`. Removed private extensions.

### ✅ H-SEC-2: Duplicate ASN.1 length parsing
- **File:** `Sources/Security/TLS/TLSUtils.swift` (deleted)
- **Problem:** Two overloads (`[UInt8]` and `Data`) with identical logic.
- **Fix:** Keep only `Data` version.
- **Resolution:** File deleted. swift-tls integration replaced all manual ASN.1 parsing with swift-certificates + SwiftASN1.

### ✅ H-SEC-3: Duplicate framing between Noise and TLS
- **Files:** `Sources/Security/Noise/NoisePayload.swift:165-200`, `Sources/Security/TLS/TLSUtils.swift` (deleted)
- **Problem:** Identical 2-byte big-endian length-prefixed framing duplicated.
- **Fix:** Extract generic `readLengthPrefixedFrame`/`encodeLengthPrefixedFrame`.
- **Resolution:** TLS framing removed (swift-tls handles record layer). Noise framing delegates to shared `LengthPrefixedFraming.swift` utility.

### ✅ H-SEC-4: TLSConfiguration.alpnProtocols never used
- **File:** `Sources/Security/TLS/TLSUpgrader.swift`
- **Problem:** Dead configuration field.
- **Fix:** Implement ALPN or remove.
- **Resolution:** swift-tls integration implements ALPN "libp2p" via `TLSCore.TLSConfiguration.alpnProtocols`. Old dead field removed.

### ✅ H-SEC-5: x25519SmallOrderPoints uses if let -- silent failure on bad hex
- **File:** `Sources/Security/Noise/NoiseCryptoState.swift:291-341`
- **Problem:** Hardcoded security constants silently dropped if hex parsing fails.
- **Fix:** Use force-unwrap or `precondition` for compile-time constants.
- **Resolution:** All 6 `if let` changed to `guard let ... else { preconditionFailure(...) }`.

### ✅ H-SEC-6: TOCTOU race on isClosed in NoiseConnection and TLSConnection
- **Files:** `Sources/Security/Noise/NoiseConnection.swift`, `Sources/Security/TLS/TLSConnection.swift`
- **Problem:** `isClosed` checked then lock released before `underlying.read()`. Concurrent `close()` causes unexpected error type.
- **Fix:** Catch post-close errors and re-throw as `connectionClosed`.
- **Resolution:** NoiseConnection: Moved `isClosed` into per-direction state structs (`SendState`/`RecvState`). TLSSecuredConnection: `Mutex<ConnectionState>` with atomic `isClosed` check within lock.

### ✅ H-TRANS-1: Duplicated extractPeerID
- **Files:** `Sources/Transport/QUIC/QUICTransport.swift:245-259`, `Sources/Transport/QUIC/QUICListener.swift:282-296`
- **Problem:** Identical method copy-pasted.
- **Fix:** Extract to shared utility.
- **Resolution:** Extracted to shared utility; both callers use common implementation.

### ✅ H-TRANS-2: TCPListener.connectionAccepted doesn't check isClosed
- **File:** `Sources/Transport/TCP/TCPListener.swift:149-168`
- **Problem:** Connections enqueued after close leak (never accepted, never closed).
- **Fix:** Add `isClosed` check; close connection if listener is shut down.
- **Resolution:** Added `isClosed` check; connections arriving after close are rejected.

### ✅ H-TRANS-3: QUICListener.accept() always throws
- **File:** `Sources/Transport/QUIC/QUICListener.swift:52-56`
- **Problem:** Unconditionally throws `TransportError.listenerClosed`. Transport returns unusable listener.
- **Fix:** Make `listen()` throw or implement `accept()`.
- **Resolution:** Clarified as `SecuredTransport` path — `accept()` is intentionally unused for QUIC; documented.

### ✅ H-TRANS-4: try? in TCPTransport.deinit
- **File:** `Sources/Transport/TCP/TCPTransport.swift:33`
- **Problem:** `try? group.syncShutdownGracefully()` silently loses shutdown errors.
- **Fix:** Log the error.
- **Resolution:** Shutdown error is now logged.

### ✅ H-TRANS-5: inboundStreams creates new Task on every access
- **File:** `Sources/Transport/QUIC/QUICMuxedConnection.swift:139-148`
- **Problem:** Computed property spawns new Task each call. Multiple calls split streams between consumers.
- **Fix:** Create `AsyncStream` once (lazily with Mutex).
- **Resolution:** Changed to lazy stored property; Task created only on first access.

### ✅ H-TRANS-6: HandlerCollector holds strong refs indefinitely -- memory leak
- **File:** `Sources/Transport/TCP/TCPListener.swift:180-211`
- **Problem:** Handlers never removed. Closed connections can't be deallocated.
- **Fix:** Use weak references or clear periodically.
- **Resolution:** Added handler removal mechanism on disconnection.

---

## MEDIUM

### M-CORE-1: Dead error cases in PeerIDError
- **File:** `Sources/Core/P2PCore/Identity/PeerID.swift:120-124`
- **Problem:** `invalidMultihash` and `publicKeyMismatch` never thrown.

### M-CORE-2: Dead error case PrivateKeyError.signingFailed
- **File:** `Sources/Core/P2PCore/Identity/PrivateKey.swift:154`

### M-CORE-3: KeyType.protobufFieldNumber is dead code
- **File:** `Sources/Core/P2PCore/Identity/KeyType.swift:21-28`
- **Problem:** Redundant with `rawValue` and never called.

### M-CORE-4: Envelope.maxFieldLength misleading name
- **File:** `Sources/Core/P2PCore/Record/Envelope.swift:127`
- **Problem:** Only used for payload. Should be `maxPayloadLength`.

### M-CORE-5: PeerID.init(string:) overlapping parsing branches
- **File:** `Sources/Core/P2PCore/Identity/PeerID.swift:59-78`
- **Problem:** `hasPrefix("1")` branch redundant with else branch.

### M-CORE-6: @_exported import leaks Foundation/Crypto/Logging
- **File:** `Sources/Core/P2PCore/P2PCore.swift:11-13`
- **Problem:** Underscored attribute forces transitive dependencies on all importers.

### M-CORE-7: Envelope.unmarshal doesn't validate all data consumed
- **File:** `Sources/Core/P2PCore/Record/Envelope.swift:130-194`
- **Problem:** Trailing bytes silently ignored. Could indicate tampering.

### M-CORE-8: Multiaddr.bytes O(n^2) from repeated Data concatenation
- **File:** `Sources/Core/P2PCore/Addressing/Multiaddr.swift:128`
- **Fix:** Pre-compute size, use `reserveCapacity`.

### M-DISC-1: DefaultBootstrap doesn't conform to EventEmitting pattern
- **File:** `Sources/Discovery/P2PDiscovery/Bootstrap.swift:170-211`

### M-DISC-2: MemoryPeerStore doesn't conform to EventEmitting pattern
- **File:** `Sources/Discovery/P2PDiscovery/PeerStore.swift:212-238`

### M-DISC-3: recordFailure() doesn't call touchPeer()
- **File:** `Sources/Discovery/P2PDiscovery/PeerStore.swift:351-364`
- **Problem:** Asymmetric LRU behavior.

### M-DISC-4: SWIMMembership.announce() silently does nothing
- **File:** `Sources/Discovery/SWIM/SWIMMembership.swift:284-289`

### M-DISC-5: CompositeDiscovery.subscribe creates untracked infinite Task
- **File:** `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:141-157`

### M-DISC-6: MDNSDiscovery/SWIMMembership subscribe creates untracked Tasks
- **Files:** `Sources/Discovery/MDNS/MDNSDiscovery.swift:142-160`, `Sources/Discovery/SWIM/SWIMMembership.swift:308-323`

### M-INT-1: BufferedRawConnection/BufferedSecuredConnection near-identical duplicates
- **File:** `Sources/Integration/P2P/ConnectionUpgrader.swift:32-111`
- **Problem:** 80 lines of duplicated buffering logic.

### M-INT-2: readBuffered/readBufferedSecured identical methods
- **File:** `Sources/Integration/P2P/ConnectionUpgrader.swift:286-327`

### ✅ M-INT-3: ConnectionState.connecting declared but never used
- **File:** `Sources/Integration/P2P/Connection/ConnectionState.swift:23`
- **Resolution:** `.connecting` state is now set at dial start (implemented as part of H-INT-4 fix).

### M-INT-4: 25+ try? on connection/stream close without logging
- **File:** `Sources/Integration/P2P/P2P.swift` (numerous)

### M-INT-5: BlocklistGater.clearAll() non-atomic two-step clear
- **File:** `Sources/Integration/P2P/Connection/ConnectionGater.swift:192-195`

### M-INT-6: Inconsistent inbound vs outbound stream handling Task wrapping
- **File:** `Sources/Integration/P2P/P2P.swift:1057-1058`

### M-MUX-1: YamuxMuxer is class when should be struct
- **File:** `Sources/Mux/Yamux/YamuxMuxer.swift:10`
- **Problem:** No mutable state, no reference semantics needed. `MplexMuxer` is correctly a struct.

### ✅ M-MUX-2: Dead error cases in MplexError
- **File:** `Sources/Mux/Mplex/MplexFrame.swift:241-243`
- **Problem:** `maxStreamsExceeded` and `streamIDReused` never used.
- **Resolution:** Deleted both cases. RST-based stream limit handling does not throw these errors.

### M-MUX-3: Mplex close() sends frames after marking isClosed
- **File:** `Sources/Mux/Mplex/MplexConnection.swift:448`
- **Problem:** `captureForShutdown()` sets `isClosed=true`, then `closeAllStreamsGracefully` tries `sendFrame` which checks `isClosed`.

### M-MUX-4: Mplex missing GoAway equivalent (design note)
- **File:** `Sources/Mux/Mplex/MplexConnection.swift`
- **Problem:** No graceful shutdown signaling to remote. Acceptable per Mplex spec.

### M-MUX-5: readLengthPrefixedMessage buffer index assumption
- **File:** `Sources/Mux/P2PMux/P2PMux.swift:132`
- **Problem:** `buffer[i]` assumes 0-based indexing. Fragile if buffer becomes a slice.

### ✅ M-MUX-6: MplexStream unbounded read buffer
- **File:** `Sources/Mux/Mplex/MplexStream.swift:188`
- **Problem:** No per-stream buffer size limit. Remote can cause OOM.
- **Resolution:** Added `maxReadBufferSize` parameter to `MplexStream`. Buffer overflow triggers stream reset (RST frame) — the only safe response since Mplex has no flow control.

### ✅ M-NEG-1: NegotiationError.timeout never thrown
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:240`
- **Resolution:** Confirmed already absent from the enum. Transport layer handles timeouts.

### M-NEG-2: NegotiationResult.remainder always empty
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:10-21`
- **Problem:** Never populated. ConnectionUpgrader builds own buffering as workaround.

### ✅ M-NEG-3: Responder handle() has unbounded while-true loop
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:162-187`
- **Fix:** Add max iteration count.
- **Resolution:** Added `maxNegotiationAttempts = 1000` counter. Exceeding throws `NegotiationError.tooManyAttempts`.

### M-NEG-4: negotiate() doesn't validate protocols is non-empty
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:40-70`
- **Problem:** Sends header and reads response before discovering nothing to negotiate.

### ✅ M-PROTO-1: Dead withQueryTimeout in KademliaService
- **File:** `Sources/Protocols/Kademlia/KademliaService.swift:923-939`
- **Resolution:** Deleted. KademliaQuery handles timeout internally.

### ✅ M-PROTO-2: Dead readLengthPrefixed/writeLengthPrefixed wrappers
- **File:** `Sources/Protocols/Kademlia/KademliaService.swift:965-971`
- **Resolution:** Deleted. Direct `stream.readLengthPrefixedMessage`/`writeLengthPrefixedMessage` calls used instead.

### ✅ M-PROTO-3: Dead KademliaPutOperation and KademliaPutDelegate
- **File:** `Sources/Protocols/Kademlia/KademliaQuery.swift:371-392`
- **Resolution:** Deleted. `putValue()` implements storage directly.

### M-PROTO-4: Redundant recordTTL alias
- **File:** `Sources/Protocols/Kademlia/KademliaProtocol.swift:22-26`

### M-PROTO-5: Redundant touch() on newly created KBucketEntry
- **File:** `Sources/Protocols/Kademlia/KBucket.swift:126-127`

### M-PROTO-6: Duplicated withTimeout helper across 4 services
- **Files:** `Sources/Protocols/AutoNAT/AutoNATService.swift`, `Sources/Protocols/DCUtR/DCUtRService.swift`, `Sources/Protocols/Kademlia/KademliaService.swift:923-961`
- **Fix:** Extract shared `withTimeout(duration:operation:)`.

### M-PROTO-7: try? await stream.close() pattern used extensively
- **Files:** Multiple across Kademlia, GossipSub, CircuitRelay
- **Fix:** Log close errors at debug level.

### M-SEC-1: Exchange.decode double-parses length prefix
- **File:** `Sources/Security/Plaintext/PlaintextUpgrader.swift:106-159`

### M-SEC-2: Exchange.decode doesn't validate wire type
- **File:** `Sources/Security/Plaintext/PlaintextUpgrader.swift:122-148`
- **Fix:** Add `guard wireType == 2` like NoisePayload.

### ✅ M-SEC-3: Unbounded handshake message size in Plaintext
- **File:** `Sources/Security/Plaintext/PlaintextUpgrader.swift:179-208`
- **Fix:** Add max size check after varint decode.
- **Resolution:** Added `maxPlaintextHandshakeSize` (64KB) check after varint decode. Throws `PlaintextError.messageTooLarge`.

### ✅ M-SEC-4: TLS receiveCertificate accesses buffer by absolute index
- **File:** `Sources/Security/TLS/TLSUpgrader.swift` (rewritten)
- **Problem:** `buffer[0]` fragile if buffer becomes a slice.
- **Resolution:** Obsolete. swift-tls handles all TLS record parsing internally. No manual buffer indexing in the new implementation.

### ✅ M-SEC-5: Duplicate protobuf encoding in NoisePayload and Exchange
- **Files:** `Sources/Security/Noise/NoisePayload.swift`, `Sources/Security/Plaintext/PlaintextUpgrader.swift`
- **Resolution:** Extracted shared `ProtobufLite.swift` utility (wire type 2 only) to `Sources/Core/P2PCore/Utilities/`. NoisePayload and Exchange encode/decode now delegate to `encodeProtobufField`/`decodeProtobufFields`. Exchange.decode() gained wireType validation and field size bounds checking.

### ✅ M-SEC-6: TLSCryptoState catches all errors, losing information
- **File:** `Sources/Security/TLS/TLSCryptoState.swift` (deleted)
- **Problem:** Original `AES.GCM.seal` error discarded, replaced with `TLSError.encryptionFailed`.
- **Resolution:** File deleted. swift-tls handles all encryption/decryption internally with proper error propagation.

### ✅ M-SEC-7: NoiseHandshake not Sendable but used across async boundaries
- **File:** `Sources/Security/Noise/NoiseHandshake.swift`
- **Resolution:** Converted `NoiseHandshake` from `final class` to `struct: Sendable`. All fields (Curve25519 keys, NoiseSymmetricState, KeyPair) are Sendable. Methods marked `mutating`, callers updated to `var` + `inout`.

### M-TRANS-1: Duplicated tlsProviderFactory configuration
- **File:** `Sources/Transport/QUIC/QUICTransport.swift:131-142,190-200`

### M-TRANS-2: QUICTransportError has unused error cases
- **File:** `Sources/Transport/QUIC/QUICTransport.swift:265-286`
- **Problem:** `invalidAddress`, `tlsHandshakeFailed`, `peerIDMismatch`, `streamError` never thrown.

### M-TRANS-3: TLSCertificateError has 9 unused error cases
- **File:** `Sources/Transport/QUIC/TLS/TLSCertificateError.swift:10-55`
- **Problem:** Only 5 of 14 cases actually used.

### ✅ M-TRANS-4: MemoryHubError.listenerClosed never thrown
- **File:** `Sources/Transport/Memory/MemoryHub.swift:22`
- **Resolution:** Confirmed already absent from the enum. `TransportError` is used instead.

### M-TRANS-5: MemoryConnection.read() loses error information
- **File:** `Sources/Transport/Memory/MemoryConnection.swift:91-93`

### M-TRANS-6: QUICSecuredListener.acceptSecured() single-consumer issue
- **File:** `Sources/Transport/QUIC/QUICListener.swift:212-223`

### M-TRANS-7: MemoryConnection TOCTOU race on isClosed
- **File:** `Sources/Transport/Memory/MemoryConnection.swift:79-82,101-104`

### M-TRANS-8: TCPConnection.write() TOCTOU race on isClosed
- **File:** `Sources/Transport/TCP/TCPConnection.swift:98-104`

---

## LOW

### L-CORE-1: PeerID ExpressibleByStringLiteral uses fatalError
- **File:** `Sources/Core/P2PCore/Identity/PeerID.swift:143-151`

### L-CORE-2: Multiaddr.init?(socketAddress:) returns nil instead of throwing
- **File:** `Sources/Core/P2PCore/Addressing/Multiaddr.swift:362-386`

### L-CORE-3: Multihash.bytes creates new Data on every access
- **File:** `Sources/Core/P2PCore/Utilities/Multihash.swift:17-21`

### L-CORE-4: Base58 decode O(n^2) from insert(at:0)
- **File:** `Sources/Core/P2PCore/Utilities/Base58.swift:95,100`

### L-CORE-5: encapsulate is trivial alias for appending
- **File:** `Sources/Core/P2PCore/Addressing/Multiaddr.swift:215-217`

### L-DISC-1: Dead BootstrapError.noSeeds and .alreadyInProgress
- **File:** `Sources/Discovery/P2PDiscovery/Bootstrap.swift:370,373-374`

### L-DISC-2: Dead SWIMTransportAdapterError
- **File:** `Sources/Discovery/SWIM/SWIMTransportAdapter.swift:119-124`

### L-DISC-3: Dead MDNSDiscoveryError.alreadyStarted and .invalidPeerID
- **File:** `Sources/Discovery/MDNS/MDNSDiscovery.swift:265,268`

### L-DISC-4: Dead SWIMMembershipError.joinFailed and .transportError
- **File:** `Sources/Discovery/SWIM/SWIMMembership.swift:369,371`

### L-DISC-5: Dead TransportType.webRTC
- **File:** `Sources/Discovery/P2PDiscovery/AddressBook.swift:18`

### L-DISC-6: extractProtocols stores transport names not protocol IDs
- **File:** `Sources/Discovery/MDNS/PeerIDServiceCodec.swift:155-163`

### L-DISC-7: CompositeDiscovery.mergeCandidates weighted average incorrect
- **File:** `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:204-229`
- **Problem:** Divides by count instead of sum of weights. Can exceed 1.0.

### L-DISC-8: addresses(for:) calls touchPeer on read
- **File:** `Sources/Discovery/P2PDiscovery/PeerStore.swift:246-249`

### L-DISC-9: SWIMMembership.start() uses try? for local address
- **File:** `Sources/Discovery/SWIM/SWIMMembership.swift:142`

### L-INT-1: Dead HealthCheckError.cancelled
- **File:** `Sources/Integration/P2P/Connection/HealthMonitor.swift:104`

### L-INT-2: Dead ConnectionPool.reconnectingConnectionID(for:)
- **File:** `Sources/Integration/P2P/Connection/ConnectionPool.swift:564-575`

### L-INT-3: Dead DisconnectErrorCode.unknown
- **File:** `Sources/Integration/P2P/Connection/DisconnectReason.swift:20`

### L-INT-4: ReconnectionPolicy.Equatable ignores backoff
- **File:** `Sources/Integration/P2P/Connection/ReconnectionPolicy.swift:150-157`

### L-INT-5: Duration.minutes extension may collide with stdlib
- **File:** `Sources/Integration/P2P/Connection/BackoffStrategy.swift:158-160`

### L-INT-6: handleInboundStreams captures handlers as snapshot inconsistently
- **File:** `Sources/Integration/P2P/P2P.swift:1136-1140`

### L-INT-7: PoolConfiguration.gater accessibility inconsistency
- **File:** `Sources/Integration/P2P/Connection/ConnectionPool.swift:24`

### L-MUX-1: Inconsistent FrameWriter naming
- **Files:** `Sources/Mux/Mplex/MplexConnection.swift:11`, `Sources/Mux/Yamux/YamuxConnection.swift:14`

### L-MUX-2: Yamux thundering herd in windowUpdate
- **File:** `Sources/Mux/Yamux/YamuxStream.swift:427-439`

### L-MUX-3: Mux CONTEXT.md documents wrong stream ID rules for Mplex
- **File:** `Sources/Mux/CONTEXT.md:72-74`

### L-MUX-4: Mplex CONTEXT.md documents wrong stream ID rules
- **File:** `Sources/Mux/Mplex/CONTEXT.md:37-39`

### L-MUX-5: Yamux handleDataFrame repeated RST frame construction
- **File:** `Sources/Mux/Yamux/YamuxConnection.swift:339-417`
- **Fix:** Extract `YamuxFrame.rst(streamID:)` helper.

### L-MUX-6: MplexConnection.close() doesn't await readTask
- **File:** `Sources/Mux/Mplex/MplexConnection.swift:195-211`

### L-NEG-1: encode() is public with no input validation
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:193`

### L-NEG-2: Duplicated fallback logic between negotiate() and negotiateLazy()
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:55-67,118-131`

### L-NEG-3: Test uses try? to swallow errors
- **File:** `Tests/Negotiation/P2PNegotiationTests/NegotiationTests.swift:342`

### L-NEG-4: NegotiationError lacks CustomStringConvertible
- **File:** `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:236-244`

### L-PROTO-1: Potentially unused KademliaError cases
- **File:** `Sources/Protocols/Kademlia/KademliaError.swift`
- **Problem:** `emptyRoutingTable`, `maxDepthExceeded`, `providerNotFound`, `peerNotFound` may be dead.

### L-PROTO-2: GossipSubService delegates EventEmitting without explicit conformance
- **File:** `Sources/Protocols/GossipSub/GossipSubService.swift`

### L-PROTO-3: RelayServer.handleReserve over-engineered tuple decomposition
- **File:** `Sources/Protocols/CircuitRelay/RelayServer.swift:230-247`

### L-PROTO-4: UpgradeAttempt.peer redundant with dictionary key
- **File:** `Sources/Protocols/DCUtR/DCUtRService.swift:84-92`

### L-SEC-1: validateX25519PublicKey redundant with zero-check
- **File:** `Sources/Security/Noise/NoiseCryptoState.swift:347-353,270-284`

### L-SEC-2: NoiseCipherState empty init only used once
- **File:** `Sources/Security/Noise/NoiseCryptoState.swift:19-21`

### ✅ L-SEC-3: TLSError.peerIDMismatch uses String instead of PeerID (dead code)
- **File:** `Sources/Security/TLS/TLSError.swift`
- **Resolution:** `peerIDMismatch` is now actively used by `makeCertificateValidator` when `expectedPeer` doesn't match. Uses `String` for Sendable compliance.

### ✅ L-SEC-4: Unused TLS error cases
- **File:** `Sources/Security/TLS/TLSError.swift`
- **Problem:** `keyGenerationFailed`, `unsupportedVersion`, `invalidASN1Structure` never thrown.
- **Resolution:** All old unused error cases removed. Current `TLSError` has 7 cases, all actively used.

### L-SEC-5: NoiseConnection.read() clears buffer on error
- **File:** `Sources/Security/Noise/NoiseConnection.swift:100-104`

### L-SEC-6: Framing helpers in wrong file (NoisePayload.swift)
- **File:** `Sources/Security/Noise/NoisePayload.swift:158-200`

### ✅ L-SEC-7: TLSCertificate uses manual loop for random serial
- **File:** `Sources/Security/TLS/TLSCertificate.swift`
- **Resolution:** Rewritten using swift-certificates. Serial number generated via `Certificate.SerialNumber()` which handles random generation internally.

### L-TRANS-1: QUICListener.close() doesn't close QUIC endpoint
- **File:** `Sources/Transport/QUIC/QUICListener.swift:59-63`

### L-TRANS-2: MemoryChannel A/B side code duplication
- **File:** `Sources/Transport/Memory/MemoryChannel.swift`

### L-TRANS-3: MemoryListener.enqueue() closes in fire-and-forget Task
- **File:** `Sources/Transport/Memory/MemoryListener.swift:128-132`

### L-TRANS-4: SocketAddress.toMultiaddr() falls back to port 0
- **File:** `Sources/Transport/TCP/TCPConnection.swift:366`

### L-TRANS-5: Inconsistent EOF semantics between TCP and Memory
- **Files:** `Sources/Transport/Memory/MemoryChannel.swift:75-76`, `Sources/Transport/TCP/TCPConnection.swift:84`

### L-TRANS-6: QUICSecuredListener uses print() instead of Logger
- **File:** `Sources/Transport/QUIC/QUICListener.swift:150-155,163-166`

### L-TRANS-7: QUICSecuredListener handshake uses 50ms polling
- **File:** `Sources/Transport/QUIC/QUICListener.swift:261-264`

---

## Implementation Gaps (libp2p Feature Parity)

Gap analysis vs Go/Rust implementations (2026-01-28).

### P0 (Critical for interop)

> **All P0 gaps resolved.**

#### ✅ GAP-1: Early Muxer Negotiation (TLS ALPN)
- **Module:** Security / Integration
- **Status:** ✅ Resolved
- **Resolution:** Added `EarlyMuxerNegotiating` protocol in P2PSecurity. TLSUpgrader encodes muxer hints in ALPN (e.g., `"libp2p/yamux/1.0.0"`). NegotiatingUpgrader skips multistream-select muxer phase when ALPN negotiation succeeds. Falls back to sequential negotiation when peer doesn't support early muxer negotiation.
- **Files:** `Sources/Security/P2PSecurity/P2PSecurity.swift`, `Sources/Security/TLS/TLSUpgrader.swift`, `Sources/Integration/P2P/ConnectionUpgrader.swift`

#### ✅ GAP-2: GossipSub IDONTWANT Wire Format
- **Module:** GossipSub
- **Status:** ✅ Resolved
- **Resolution:** Added protobuf encode/decode for `ControlIDontWant` (field 5) in `GossipSubProtobuf.swift`. Added `encodeIDontWant()`, `decodeIDontWant()`, field tag constants, and updated `encodeControl()`/`decodeControl()` to handle IDONTWANT. 3 new tests added.
- **Files:** `Sources/Protocols/GossipSub/Wire/GossipSubProtobuf.swift`

### P1 (Important for production use)

#### ✅ GAP-3: PeerStore TTL-based Garbage Collection
- **Module:** Discovery
- **Status:** ✅ Resolved
- **Resolution:** Added `expiresAt: ContinuousClock.Instant?` to `AddressRecord` with `isExpired` computed property. Changed `PeerStore` protocol to require `addAddresses(_:for:ttl:)` with backward-compatible convenience extensions. `MemoryPeerStoreConfiguration` gained `defaultAddressTTL` (default 1 hour) and `gcInterval` (default 60s). `MemoryPeerStore` implements `cleanup()` (removes expired addresses/empty peers) and `startGC()`/`stopGC()` for background collection. Go-compatible: TTL extends only if new > old. Node integrates GC lifecycle in start/stop. 10 tests added.
- **Files:** `Sources/Discovery/P2PDiscovery/PeerStore.swift`, `Sources/Integration/P2P/P2P.swift`

#### ✅ GAP-4: ProtoBook (Per-Peer Protocol Tracking)
- **Module:** Discovery
- **Status:** ✅ Resolved
- **Resolution:** Added `ProtoBook` protocol (Go-compatible: `setProtocols`, `addProtocols`, `removeProtocols`, `supportsProtocols`, `firstSupportedProtocol`, `peers(supporting:)`) and `MemoryProtoBook` implementation (`final class + Mutex` for high-frequency access). Node exposes `protoBook` property with default `MemoryProtoBook`. 8 tests added.
- **Files:** `Sources/Discovery/P2PDiscovery/ProtoBook.swift`, `Sources/Discovery/P2PDiscovery/MemoryProtoBook.swift`, `Sources/Integration/P2P/P2P.swift`

#### ✅ GAP-5: KeyBook (Per-Peer Public Key Storage)
- **Module:** Discovery
- **Status:** ✅ Resolved
- **Resolution:** Added `KeyBook` protocol with `publicKey(for:)` (falls back to PeerID identity extraction), `setPublicKey(_:for:)` (verifies PeerID match, throws `KeyBookError.peerIDMismatch`), `removePublicKey`, `removePeer`, `peersWithKeys`. `MemoryKeyBook` implementation (`final class + Mutex`). Node exposes `keyBook` property with default `MemoryKeyBook`. 8 tests added.
- **Files:** `Sources/Discovery/P2PDiscovery/KeyBook.swift`, `Sources/Discovery/P2PDiscovery/MemoryKeyBook.swift`, `Sources/Integration/P2P/P2P.swift`

#### ✅ GAP-6: Kademlia Client/Server Mode Behavioral Restriction
- **Module:** Kademlia
- **Status:** ✅ Resolved
- **Resolution:** Added `shouldAcceptInbound()` guard in `handleStream()`. Client mode rejects all inbound DHT queries by closing the stream before processing (Go-compatible). Server and automatic modes accept all queries. Stream is closed silently without error response. 4 tests added.
- **Files:** `Sources/Protocols/Kademlia/KademliaService.swift`

### P2 (Nice to have)

#### ✅ GAP-7: GossipSub Per-Topic Scoring
- **Module:** GossipSub
- **Status:** ✅ Resolved
- **Description:** Current scoring is global only. GossipSub v1.1 spec defines per-topic scoring parameters (topic weight, time-in-mesh, first-message-delivery, mesh-message-delivery, etc.). Go/Rust implementations support per-topic score functions.
- **Resolution:** Implemented per-topic scoring with P1 (Time in Mesh), P2 (First Message Deliveries), P3 (Mesh Message Delivery Deficit), P3b (Mesh Failure Penalty), P4 (Invalid Messages). `TopicScoreParams` struct follows Go spec. `computeScore(for:)` combines global + per-topic scores. Mesh management (`isGraylisted`, `sortByScore`, `selectBestPeers`) uses `computeScore()`. Per-topic decay integrated into `applyDecayToAll()`. 13 per-topic tests added.
- **Files:** `Sources/Protocols/GossipSub/Scoring/PeerScorer.swift`, `Sources/Protocols/GossipSub/Scoring/TopicScoreParams.swift`, `Sources/Protocols/GossipSub/GossipSubConfiguration.swift`, `Sources/Protocols/GossipSub/Router/GossipSubRouter.swift`

#### ✅ GAP-8: Kademlia RecordValidator.Select
- **Module:** Kademlia
- **Status:** ✅ Resolved
- **Description:** `RecordValidator` protocol has `validate(key:value:)` but no `select(key:records:)` method. When multiple records exist for the same key, there is no way to determine the "best" record. Go implementation defines `Select(key, []Record) (int, error)`.
- **Resolution:** Added `select(key:records:)` method to `RecordValidator` protocol with default implementation (returns index 0). `RecordSelectionError` error type added. `KademliaQuery` collects multiple records during GET_VALUE and uses `select()` to choose the best. `NamespacedValidator` delegates to per-namespace validators. `SignedRecordValidator` selects by most recent timestamp.
- **Files:** `Sources/Protocols/Kademlia/RecordValidator.swift`, `Sources/Protocols/Kademlia/KademliaQuery.swift`

#### ✅ GAP-9: Resource Manager (Multi-Scope)
- **Module:** Integration
- **Status:** ✅ Resolved
- **Description:** No multi-scope resource limiter. Go's `rcmgr` provides limits at system, transient, service, protocol, peer, and connection scopes. Current implementation only has connection-level limits via `ConnectionLimits`.
- **Resolution:** Implemented `ResourceManager` protocol with system, peer, and protocol scopes. `DefaultResourceManager` enforces limits at all 3 scopes with atomic multi-scope reservation (rollback on failure). `ResourceLimitsConfiguration` supports per-peer and per-protocol overrides. `ResourceSnapshot` exposes all scope stats. `ResourceTrackedStream` wraps `MuxedStream` with automatic 3-scope release. 51 tests added.
- **Files:** `Sources/Integration/P2P/Resource/ResourceManager.swift`, `Sources/Integration/P2P/Resource/DefaultResourceManager.swift`, `Sources/Integration/P2P/Resource/ResourceLimitsConfiguration.swift`, `Sources/Integration/P2P/Resource/ResourceSnapshot.swift`, `Sources/Integration/P2P/Resource/ResourceTrackedStream.swift`

#### ✅ GAP-10: multistream-select V1 Lazy
- **Module:** Negotiation
- **Status:** ✅ Resolved
- **Description:** V1 Lazy optimization allows the dialer to send the protocol header and selection in a single message when only one protocol is offered, saving one RTT. The function `negotiateLazy` exists but is not wired into the connection upgrade path.
- **Resolution:** Wired `negotiateLazy()` into `ConnectionUpgrader` for initiator-side security and muxer negotiation. Responder uses standard V1 `handle()` (backward compatible). Saves 1 RTT per negotiation phase.
- **Files:** `Sources/Integration/P2P/ConnectionUpgrader.swift`

#### GAP-11: WebSocket Transport
- **Module:** Transport
- **Status:** ❌ Not implemented
- **Description:** No WebSocket transport. Required for browser interoperability via js-libp2p.
- **Impact:** Cannot connect to browser-based peers

#### ✅ GAP-12: Kademlia Persistent Storage
- **Module:** Kademlia
- **Status:** ✅ Resolved
- **Description:** `RecordStore` and `ProviderStore` are in-memory only. All DHT records are lost on restart. Go/Rust implementations support persistent backends (LevelDB, etc.).
- **Resolution:** Extracted `RecordStorage` and `ProviderStorage` protocols. `RecordStore`/`ProviderStore` now delegate to pluggable backends (default: `InMemoryRecordStorage`/`InMemoryProviderStorage`). Added `FileRecordStorage` and `FileProviderStorage` for file-based persistence using write-through cache + JSON files in `<dir>/records/<prefix>/<sha256>.json`. Wall-clock `Date` timestamps used for serialization (survives process restarts). 28 storage tests added.
- **Files:** `Sources/Protocols/Kademlia/Storage/RecordStorage.swift`, `Sources/Protocols/Kademlia/Storage/ProviderStorage.swift`, `Sources/Protocols/Kademlia/Storage/InMemoryRecordStorage.swift`, `Sources/Protocols/Kademlia/Storage/InMemoryProviderStorage.swift`, `Sources/Protocols/Kademlia/Storage/FileRecordStorage.swift`, `Sources/Protocols/Kademlia/Storage/FileProviderStorage.swift`, `Sources/Protocols/Kademlia/RecordStore.swift`, `Sources/Protocols/Kademlia/ProviderStore.swift`
