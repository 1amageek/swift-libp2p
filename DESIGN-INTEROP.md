# 相互運用基盤 設計書

## 概要

Go/Rust libp2pとの相互運用性を実現するための基盤設計。

### 実装対象

| プロトコル | Protocol ID | 優先度 |
|-----------|-------------|--------|
| Identify | `/ipfs/id/1.0.0` | P0 |
| Identify Push | `/ipfs/id/push/1.0.0` | P1 |
| Ping | `/ipfs/ping/1.0.0` | P0 |

### 設計原則

1. **仕様準拠**: libp2p specs完全準拠（wire protocol互換）
2. **既存アーキテクチャ統合**: Node actor + handler パターンを活用
3. **Sendable準拠**: Swift 6 concurrency安全
4. **テスト可能性**: Mock可能な設計

---

## ディレクトリ構造

```
Sources/
├── Protocols/
│   ├── P2PProtocols/           # Protocol定義のみ
│   │   ├── ProtocolService.swift
│   │   └── ProtocolError.swift
│   │
│   ├── Identify/               # P2PIdentify
│   │   ├── IdentifyService.swift
│   │   ├── IdentifyInfo.swift
│   │   ├── IdentifyProtobuf.swift
│   │   └── CONTEXT.md
│   │
│   └── Ping/                   # P2PPing
│       ├── PingService.swift
│       ├── PingResult.swift
│       └── CONTEXT.md
│
Tests/
└── Protocols/
    ├── IdentifyTests/
    │   ├── IdentifyProtobufTests.swift
    │   ├── IdentifyServiceTests.swift
    │   └── IdentifyInteropTests.swift
    │
    └── PingTests/
        ├── PingServiceTests.swift
        └── PingInteropTests.swift
```

---

## Part 1: Protocol Service 基盤

### 1.1 ProtocolService Protocol

```swift
// Sources/Protocols/P2PProtocols/ProtocolService.swift

/// A protocol service that can be attached to a Node.
public protocol ProtocolService: Sendable {
    /// The protocol IDs this service handles.
    var protocolIDs: [String] { get }

    /// Called when the service is attached to a node.
    func attach(to node: Node) async

    /// Called when the service is detached from a node.
    func detach() async
}
```

### 1.2 Node拡張

```swift
// P2P.swift への追加

extension Node {
    /// Attaches a protocol service to this node.
    public func attach(_ service: any ProtocolService) async {
        await service.attach(to: self)
    }
}
```

---

## Part 2: Identify Protocol

### 2.1 Wire Protocol仕様

```
Protocol ID: /ipfs/id/1.0.0
Protocol ID (Push): /ipfs/id/push/1.0.0

Flow (Query):
  Initiator              Responder
      |---- stream open ---->|
      |<--- Identify msg ----|
      |---- stream close --->|

Flow (Push):
  Sender                 Receiver
      |---- stream open ---->|
      |---- Identify msg --->|
      |---- stream close --->|
```

### 2.2 Protobuf Message

```protobuf
// libp2p Identify message (field numbers preserved for compatibility)
message Identify {
  optional bytes publicKey = 1;
  repeated bytes listenAddrs = 2;
  repeated string protocols = 3;
  optional bytes observedAddr = 4;
  optional string protocolVersion = 5;
  optional string agentVersion = 6;
  optional bytes signedPeerRecord = 8;
}
```

### 2.3 IdentifyInfo

```swift
// Sources/Protocols/Identify/IdentifyInfo.swift

import Foundation
import P2PCore

/// Information exchanged during Identify protocol.
public struct IdentifyInfo: Sendable, Equatable {
    /// The peer's public key.
    public let publicKey: PublicKey?

    /// Addresses the peer is listening on.
    public let listenAddresses: [Multiaddr]

    /// Protocols the peer supports.
    public let protocols: [String]

    /// The address we were observed at by this peer.
    public let observedAddress: Multiaddr?

    /// Protocol version (e.g., "ipfs/0.1.0").
    public let protocolVersion: String?

    /// Agent version (e.g., "swift-libp2p/0.1.0").
    public let agentVersion: String?

    /// Signed peer record (optional, for authenticated addresses).
    public let signedPeerRecord: Envelope?

    public init(
        publicKey: PublicKey? = nil,
        listenAddresses: [Multiaddr] = [],
        protocols: [String] = [],
        observedAddress: Multiaddr? = nil,
        protocolVersion: String? = nil,
        agentVersion: String? = nil,
        signedPeerRecord: Envelope? = nil
    ) {
        self.publicKey = publicKey
        self.listenAddresses = listenAddresses
        self.protocols = protocols
        self.observedAddress = observedAddress
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.signedPeerRecord = signedPeerRecord
    }
}
```

### 2.4 Protobuf Encoding/Decoding

```swift
// Sources/Protocols/Identify/IdentifyProtobuf.swift

import Foundation
import P2PCore

/// Protobuf encoding/decoding for Identify messages.
///
/// Field numbers (must match libp2p spec):
/// - 1: publicKey (bytes)
/// - 2: listenAddrs (repeated bytes)
/// - 3: protocols (repeated string)
/// - 4: observedAddr (bytes)
/// - 5: protocolVersion (string)
/// - 6: agentVersion (string)
/// - 8: signedPeerRecord (bytes)
enum IdentifyProtobuf {

    /// Encodes IdentifyInfo to protobuf wire format.
    static func encode(_ info: IdentifyInfo) -> Data {
        var result = Data()

        // Field 1: publicKey (optional bytes)
        if let publicKey = info.publicKey {
            let bytes = publicKey.protobufEncoded
            result.append(0x0A) // field 1, wire type 2 (length-delimited)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 2: listenAddrs (repeated bytes)
        for addr in info.listenAddresses {
            let bytes = addr.bytes
            result.append(0x12) // field 2, wire type 2
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 3: protocols (repeated string)
        for proto in info.protocols {
            let bytes = Data(proto.utf8)
            result.append(0x1A) // field 3, wire type 2
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 4: observedAddr (optional bytes)
        if let observed = info.observedAddress {
            let bytes = observed.bytes
            result.append(0x22) // field 4, wire type 2
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 5: protocolVersion (optional string)
        if let version = info.protocolVersion {
            let bytes = Data(version.utf8)
            result.append(0x2A) // field 5, wire type 2
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 6: agentVersion (optional string)
        if let agent = info.agentVersion {
            let bytes = Data(agent.utf8)
            result.append(0x32) // field 6, wire type 2
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 8: signedPeerRecord (optional bytes)
        if let envelope = info.signedPeerRecord {
            if let bytes = try? envelope.marshal() {
                result.append(0x42) // field 8, wire type 2
                result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
                result.append(bytes)
            }
        }

        return result
    }

    /// Decodes IdentifyInfo from protobuf wire format.
    static func decode(_ data: Data) throws -> IdentifyInfo {
        var publicKey: PublicKey?
        var listenAddresses: [Multiaddr] = []
        var protocols: [String] = []
        var observedAddress: Multiaddr?
        var protocolVersion: String?
        var agentVersion: String?
        var signedPeerRecord: Envelope?

        var offset = data.startIndex

        while offset < data.endIndex {
            // Read field tag
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            // All our fields are length-delimited (wire type 2)
            guard wireType == 2 else {
                throw IdentifyError.invalidProtobuf("Unexpected wire type \(wireType)")
            }

            // Read field length
            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes

            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw IdentifyError.invalidProtobuf("Field truncated")
            }

            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // publicKey
                publicKey = try? PublicKey(protobufEncoded: fieldData)

            case 2: // listenAddrs
                if let addr = try? Multiaddr(bytes: fieldData) {
                    listenAddresses.append(addr)
                }

            case 3: // protocols
                if let proto = String(data: fieldData, encoding: .utf8) {
                    protocols.append(proto)
                }

            case 4: // observedAddr
                observedAddress = try? Multiaddr(bytes: fieldData)

            case 5: // protocolVersion
                protocolVersion = String(data: fieldData, encoding: .utf8)

            case 6: // agentVersion
                agentVersion = String(data: fieldData, encoding: .utf8)

            case 8: // signedPeerRecord
                signedPeerRecord = try? Envelope.unmarshal(fieldData)

            default:
                // Skip unknown fields
                break
            }
        }

        return IdentifyInfo(
            publicKey: publicKey,
            listenAddresses: listenAddresses,
            protocols: protocols,
            observedAddress: observedAddress,
            protocolVersion: protocolVersion,
            agentVersion: agentVersion,
            signedPeerRecord: signedPeerRecord
        )
    }
}
```

### 2.5 IdentifyService

```swift
// Sources/Protocols/Identify/IdentifyService.swift

import Foundation
import P2PCore
import P2PMux
import Synchronization

/// Protocol IDs for Identify.
public enum IdentifyProtocolID {
    public static let identify = "/ipfs/id/1.0.0"
    public static let push = "/ipfs/id/push/1.0.0"
}

/// Configuration for IdentifyService.
public struct IdentifyConfiguration: Sendable {
    /// The protocol version to advertise.
    public var protocolVersion: String

    /// The agent version to advertise.
    public var agentVersion: String

    /// Whether to automatically identify peers on connection.
    public var identifyOnConnect: Bool

    /// Whether to send push updates when local info changes.
    public var pushUpdates: Bool

    public init(
        protocolVersion: String = "ipfs/0.1.0",
        agentVersion: String = "swift-libp2p/0.1.0",
        identifyOnConnect: Bool = true,
        pushUpdates: Bool = true
    ) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.identifyOnConnect = identifyOnConnect
        self.pushUpdates = pushUpdates
    }
}

/// Events emitted by IdentifyService.
public enum IdentifyEvent: Sendable {
    /// Received identification from a peer.
    case received(peer: PeerID, info: IdentifyInfo)

    /// Sent our identification to a peer.
    case sent(peer: PeerID)

    /// Received a push update from a peer.
    case pushReceived(peer: PeerID, info: IdentifyInfo)

    /// Error during identification.
    case error(peer: PeerID?, IdentifyError)
}

/// Errors for Identify protocol.
public enum IdentifyError: Error, Sendable {
    case invalidProtobuf(String)
    case streamError(String)
    case timeout
    case notConnected
}

/// Service for the Identify protocol.
///
/// Handles both `/ipfs/id/1.0.0` (query) and `/ipfs/id/push/1.0.0` (push).
public actor IdentifyService: ProtocolService {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [IdentifyProtocolID.identify, IdentifyProtocolID.push]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: IdentifyConfiguration

    /// Peer information cache.
    private var peerInfo: [PeerID: IdentifyInfo] = [:]

    /// Reference to the attached node.
    private weak var node: Node?

    /// Event stream continuation.
    private var eventContinuation: AsyncStream<IdentifyEvent>.Continuation?
    private var _events: AsyncStream<IdentifyEvent>?

    /// Event stream for monitoring identify events.
    public var events: AsyncStream<IdentifyEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<IdentifyEvent>.makeStream()
        self._events = stream
        self.eventContinuation = continuation
        return stream
    }

    // MARK: - Initialization

    public init(configuration: IdentifyConfiguration = .init()) {
        self.configuration = configuration
    }

    // MARK: - ProtocolService

    public func attach(to node: Node) async {
        self.node = node

        // Register protocol handlers
        await node.handle(IdentifyProtocolID.identify) { [weak self] stream in
            await self?.handleIdentifyRequest(stream: stream)
        }

        await node.handle(IdentifyProtocolID.push) { [weak self] stream in
            await self?.handleIdentifyPush(stream: stream)
        }
    }

    public func detach() async {
        self.node = nil
        eventContinuation?.finish()
    }

    // MARK: - Public API

    /// Identifies a connected peer.
    ///
    /// Opens a stream and requests the peer's identification info.
    ///
    /// - Parameter peer: The peer to identify
    /// - Returns: The peer's identification info
    public func identify(_ peer: PeerID) async throws -> IdentifyInfo {
        guard let node = self.node else {
            throw IdentifyError.notConnected
        }

        // Open identify stream
        let stream = try await node.newStream(to: peer, protocol: IdentifyProtocolID.identify)

        defer {
            Task { try? await stream.close() }
        }

        // Read the identify response
        let data = try await readAll(from: stream)
        let info = try IdentifyProtobuf.decode(data)

        // Cache the info
        peerInfo[peer] = info

        // Emit event
        emit(.received(peer: peer, info: info))

        return info
    }

    /// Pushes our identification info to a peer.
    ///
    /// - Parameter peer: The peer to push to
    public func push(to peer: PeerID) async throws {
        guard let node = self.node else {
            throw IdentifyError.notConnected
        }

        // Open push stream
        let stream = try await node.newStream(to: peer, protocol: IdentifyProtocolID.push)

        defer {
            Task { try? await stream.close() }
        }

        // Build and send our info
        let info = await buildLocalInfo(observedAddress: nil)
        let data = IdentifyProtobuf.encode(info)
        try await stream.write(data)

        emit(.sent(peer: peer))
    }

    /// Returns cached info for a peer.
    public func cachedInfo(for peer: PeerID) -> IdentifyInfo? {
        peerInfo[peer]
    }

    /// Returns all cached peer info.
    public var allCachedInfo: [PeerID: IdentifyInfo] {
        peerInfo
    }

    // MARK: - Protocol Handlers

    /// Handles an incoming identify request.
    private func handleIdentifyRequest(stream: MuxedStream) async {
        do {
            // Get the remote peer's address for observedAddr
            let observedAddress = stream.connection?.remoteAddress

            // Build our info
            let info = await buildLocalInfo(observedAddress: observedAddress)

            // Encode and send
            let data = IdentifyProtobuf.encode(info)
            try await stream.write(data)

            // Close our side
            try await stream.close()

            if let remotePeer = stream.connection?.remotePeer {
                emit(.sent(peer: remotePeer))
            }
        } catch {
            if let remotePeer = stream.connection?.remotePeer {
                emit(.error(peer: remotePeer, .streamError(error.localizedDescription)))
            }
            try? await stream.close()
        }
    }

    /// Handles an incoming identify push.
    private func handleIdentifyPush(stream: MuxedStream) async {
        do {
            // Read the push data
            let data = try await readAll(from: stream)
            let info = try IdentifyProtobuf.decode(data)

            // Update cache
            if let remotePeer = stream.connection?.remotePeer {
                peerInfo[remotePeer] = info
                emit(.pushReceived(peer: remotePeer, info: info))
            }

            try? await stream.close()
        } catch {
            if let remotePeer = stream.connection?.remotePeer {
                emit(.error(peer: remotePeer, .streamError(error.localizedDescription)))
            }
            try? await stream.close()
        }
    }

    // MARK: - Helpers

    /// Builds the local node's identify info.
    private func buildLocalInfo(observedAddress: Multiaddr?) async -> IdentifyInfo {
        guard let node = self.node else {
            return IdentifyInfo()
        }

        // Get listen addresses from node configuration
        let listenAddresses = await node.configuration.listenAddresses

        // Get supported protocols
        let protocols = await node.supportedProtocols

        // Get public key
        let publicKey = await node.configuration.keyPair.publicKey

        // TODO: Create signed peer record if configured

        return IdentifyInfo(
            publicKey: publicKey,
            listenAddresses: listenAddresses,
            protocols: protocols,
            observedAddress: observedAddress,
            protocolVersion: configuration.protocolVersion,
            agentVersion: configuration.agentVersion,
            signedPeerRecord: nil
        )
    }

    /// Reads all data from a stream until EOF.
    private func readAll(from stream: MuxedStream, maxSize: Int = 64 * 1024) async throws -> Data {
        var buffer = Data()

        while buffer.count < maxSize {
            do {
                let chunk = try await stream.read()
                if chunk.isEmpty {
                    break // EOF
                }
                buffer.append(chunk)
            } catch {
                // Stream closed or error - return what we have
                break
            }
        }

        return buffer
    }

    private func emit(_ event: IdentifyEvent) {
        eventContinuation?.yield(event)
    }
}
```

---

## Part 3: Ping Protocol

### 3.1 Wire Protocol仕様

```
Protocol ID: /ipfs/ping/1.0.0

Message Format:
  - 32 bytes of random data

Flow:
  Initiator              Responder
      |---- 32 bytes ------->|
      |<---- 32 bytes -------|
      (echo: same 32 bytes)

RTT = time between send and receive
```

### 3.2 PingResult

```swift
// Sources/Protocols/Ping/PingResult.swift

import Foundation
import P2PCore

/// Result of a ping operation.
public struct PingResult: Sendable {
    /// The peer that was pinged.
    public let peer: PeerID

    /// Round-trip time.
    public let rtt: Duration

    /// Timestamp of the ping.
    public let timestamp: ContinuousClock.Instant

    public init(peer: PeerID, rtt: Duration, timestamp: ContinuousClock.Instant = .now) {
        self.peer = peer
        self.rtt = rtt
        self.timestamp = timestamp
    }
}

/// Events emitted by PingService.
public enum PingEvent: Sendable {
    /// A ping succeeded.
    case success(PingResult)

    /// A ping failed.
    case failure(peer: PeerID, error: PingError)
}

/// Errors for Ping protocol.
public enum PingError: Error, Sendable {
    /// The peer did not respond in time.
    case timeout

    /// The response did not match the request.
    case mismatch

    /// Stream error.
    case streamError(String)

    /// Not connected to peer.
    case notConnected

    /// Protocol not supported by peer.
    case unsupported
}
```

### 3.3 PingService

```swift
// Sources/Protocols/Ping/PingService.swift

import Foundation
import P2PCore
import P2PMux
import Synchronization

/// Protocol ID for Ping.
public enum PingProtocolID {
    public static let ping = "/ipfs/ping/1.0.0"
}

/// Ping payload size (must be 32 bytes per spec).
private let pingPayloadSize = 32

/// Configuration for PingService.
public struct PingConfiguration: Sendable {
    /// Timeout for ping responses.
    public var timeout: Duration

    /// Interval between automatic pings (nil = disabled).
    public var interval: Duration?

    public init(
        timeout: Duration = .seconds(30),
        interval: Duration? = nil
    ) {
        self.timeout = timeout
        self.interval = interval
    }
}

/// Service for the Ping protocol.
///
/// Provides connection liveness checking and RTT measurement.
public actor PingService: ProtocolService {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [PingProtocolID.ping]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: PingConfiguration

    /// Reference to the attached node.
    private weak var node: Node?

    /// Event stream continuation.
    private var eventContinuation: AsyncStream<PingEvent>.Continuation?
    private var _events: AsyncStream<PingEvent>?

    /// Event stream for monitoring ping events.
    public var events: AsyncStream<PingEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<PingEvent>.makeStream()
        self._events = stream
        self.eventContinuation = continuation
        return stream
    }

    // MARK: - Initialization

    public init(configuration: PingConfiguration = .init()) {
        self.configuration = configuration
    }

    // MARK: - ProtocolService

    public func attach(to node: Node) async {
        self.node = node

        // Register ping handler
        await node.handle(PingProtocolID.ping) { [weak self] stream in
            await self?.handlePing(stream: stream)
        }
    }

    public func detach() async {
        self.node = nil
        eventContinuation?.finish()
    }

    // MARK: - Public API

    /// Pings a peer and measures RTT.
    ///
    /// - Parameter peer: The peer to ping
    /// - Returns: The ping result with RTT
    @discardableResult
    public func ping(_ peer: PeerID) async throws -> PingResult {
        guard let node = self.node else {
            throw PingError.notConnected
        }

        // Generate random payload
        var payload = Data(count: pingPayloadSize)
        for i in 0..<pingPayloadSize {
            payload[i] = UInt8.random(in: 0...255)
        }

        // Open ping stream
        let stream: MuxedStream
        do {
            stream = try await node.newStream(to: peer, protocol: PingProtocolID.ping)
        } catch {
            throw PingError.unsupported
        }

        defer {
            Task { try? await stream.close() }
        }

        // Record start time
        let startTime = ContinuousClock.now

        // Send payload
        try await stream.write(payload)

        // Read response with timeout
        let response = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await stream.read()
            }

            group.addTask {
                try await Task.sleep(for: self.configuration.timeout)
                throw PingError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        // Calculate RTT
        let endTime = ContinuousClock.now
        let rtt = endTime - startTime

        // Verify response matches payload
        guard response == payload else {
            throw PingError.mismatch
        }

        let result = PingResult(peer: peer, rtt: rtt)
        emit(.success(result))

        return result
    }

    /// Pings a peer multiple times and returns statistics.
    ///
    /// - Parameters:
    ///   - peer: The peer to ping
    ///   - count: Number of pings to send
    ///   - interval: Interval between pings
    /// - Returns: Array of ping results
    public func pingMultiple(
        _ peer: PeerID,
        count: Int = 3,
        interval: Duration = .milliseconds(100)
    ) async throws -> [PingResult] {
        var results: [PingResult] = []

        for i in 0..<count {
            if i > 0 {
                try await Task.sleep(for: interval)
            }

            do {
                let result = try await ping(peer)
                results.append(result)
            } catch {
                emit(.failure(peer: peer, error: error as? PingError ?? .streamError("\(error)")))
            }
        }

        return results
    }

    // MARK: - Protocol Handler

    /// Handles an incoming ping request (echo back).
    private func handlePing(stream: MuxedStream) async {
        do {
            // Read payload
            let payload = try await stream.read()

            // Validate size
            guard payload.count == pingPayloadSize else {
                try? await stream.close()
                return
            }

            // Echo back
            try await stream.write(payload)

            // Keep stream open for more pings (peer will close when done)
            while true {
                do {
                    let nextPayload = try await stream.read()
                    if nextPayload.isEmpty {
                        break // EOF
                    }
                    if nextPayload.count == pingPayloadSize {
                        try await stream.write(nextPayload)
                    }
                } catch {
                    break
                }
            }
        } catch {
            // Stream closed or error
        }

        try? await stream.close()
    }

    private func emit(_ event: PingEvent) {
        eventContinuation?.yield(event)
    }
}
```

---

## Part 4: MuxedStream拡張

MuxedStreamにconnection参照を追加（Identify/Pingで必要）:

```swift
// P2PMux/MuxedStream.swift への追加

public protocol MuxedStream: Sendable {
    // 既存のメソッド...

    /// The connection this stream belongs to (optional).
    var connection: MuxedConnection? { get }
}
```

```swift
// MuxedConnection protocol への追加

public protocol MuxedConnection: Sendable {
    // 既存...

    /// Remote peer ID.
    var remotePeer: PeerID { get }

    /// Remote address.
    var remoteAddress: Multiaddr { get }
}
```

---

## Part 5: 相互運用テスト設計

### 5.1 テストインフラ

```swift
// Tests/Protocols/InteropTestHelper.swift

import Foundation
import P2PCore

/// Helper for interoperability testing.
enum InteropTestHelper {

    /// Spawns a go-libp2p test node.
    static func spawnGoNode(
        listenAddress: String = "/ip4/127.0.0.1/tcp/0"
    ) async throws -> (process: Process, address: Multiaddr, peerID: PeerID) {
        // Implementation: Start go-libp2p-test binary
        // Parse output for listen address and peer ID
        fatalError("TODO: Implement go-libp2p test harness")
    }

    /// Spawns a rust-libp2p test node.
    static func spawnRustNode(
        listenAddress: String = "/ip4/127.0.0.1/tcp/0"
    ) async throws -> (process: Process, address: Multiaddr, peerID: PeerID) {
        // Implementation: Start rust-libp2p test binary
        fatalError("TODO: Implement rust-libp2p test harness")
    }
}
```

### 5.2 Identifyテスト

```swift
// Tests/Protocols/IdentifyTests/IdentifyInteropTests.swift

import Testing
import Foundation
@testable import P2PIdentify
@testable import P2P

@Suite("Identify Interop Tests")
struct IdentifyInteropTests {

    @Test("Identify with go-libp2p node")
    func testIdentifyWithGo() async throws {
        // 1. Start go-libp2p node
        // 2. Connect from swift-libp2p
        // 3. Run identify
        // 4. Verify received info
        // 5. Verify go received our info
    }

    @Test("Identify with rust-libp2p node")
    func testIdentifyWithRust() async throws {
        // Similar to above
    }

    @Test("Identify Push to go-libp2p node")
    func testIdentifyPushToGo() async throws {
        // Test push functionality
    }

    @Test("Protobuf wire format matches spec")
    func testProtobufFormat() throws {
        // Test with known test vectors
        let info = IdentifyInfo(
            publicKey: nil,
            listenAddresses: [try Multiaddr("/ip4/127.0.0.1/tcp/4001")],
            protocols: ["/ipfs/ping/1.0.0"],
            observedAddress: try Multiaddr("/ip4/1.2.3.4/tcp/5678"),
            protocolVersion: "ipfs/0.1.0",
            agentVersion: "swift-libp2p/0.1.0"
        )

        let encoded = IdentifyProtobuf.encode(info)
        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.listenAddresses == info.listenAddresses)
        #expect(decoded.protocols == info.protocols)
        #expect(decoded.protocolVersion == info.protocolVersion)
        #expect(decoded.agentVersion == info.agentVersion)
    }
}
```

### 5.3 Pingテスト

```swift
// Tests/Protocols/PingTests/PingInteropTests.swift

import Testing
import Foundation
@testable import P2PPing
@testable import P2P

@Suite("Ping Interop Tests")
struct PingInteropTests {

    @Test("Ping go-libp2p node")
    func testPingGo() async throws {
        // 1. Start go-libp2p node
        // 2. Connect from swift-libp2p
        // 3. Ping
        // 4. Verify RTT is reasonable
    }

    @Test("Ping rust-libp2p node")
    func testPingRust() async throws {
        // Similar
    }

    @Test("Handle ping from go-libp2p")
    func testHandlePingFromGo() async throws {
        // 1. Start swift-libp2p listener
        // 2. Have go node connect and ping us
        // 3. Verify we responded correctly
    }

    @Test("Ping payload is 32 bytes")
    func testPayloadSize() async throws {
        // Verify spec compliance
    }

    @Test("Ping timeout handling")
    func testTimeout() async throws {
        // Verify timeout works correctly
    }
}
```

---

## Part 6: Package.swift 更新

```swift
// Package.swift への追加

// Targets
.target(
    name: "P2PProtocols",
    dependencies: ["P2PCore", "P2PMux"],
    path: "Sources/Protocols/P2PProtocols"
),
.target(
    name: "P2PIdentify",
    dependencies: ["P2PProtocols", "P2P"],
    path: "Sources/Protocols/Identify"
),
.target(
    name: "P2PPing",
    dependencies: ["P2PProtocols", "P2P"],
    path: "Sources/Protocols/Ping"
),

// Test Targets
.testTarget(
    name: "P2PIdentifyTests",
    dependencies: ["P2PIdentify", "P2PTransportMemory"],
    path: "Tests/Protocols/IdentifyTests"
),
.testTarget(
    name: "P2PPingTests",
    dependencies: ["P2PPing", "P2PTransportMemory"],
    path: "Tests/Protocols/PingTests"
),
```

---

## Part 7: 使用例

```swift
// Example usage

import P2P
import P2PIdentify
import P2PPing
import P2PTransportTCP
import P2PSecurityNoise
import P2PMuxYamux

// Create node
let config = NodeConfiguration(
    keyPair: .generateEd25519(),
    listenAddresses: [try Multiaddr("/ip4/0.0.0.0/tcp/4001")],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()]
)

let node = Node(configuration: config)

// Create services
let identifyService = IdentifyService(configuration: .init(
    agentVersion: "my-app/1.0.0"
))
let pingService = PingService()

// Attach services
await node.attach(identifyService)
await node.attach(pingService)

// Start node
try await node.start()

// Connect to peer
let remotePeer = try await node.connect(to: remoteAddress)

// Identify peer
let info = try await identifyService.identify(remotePeer)
print("Peer protocols: \(info.protocols)")
print("Peer agent: \(info.agentVersion ?? "unknown")")

// Ping peer
let result = try await pingService.ping(remotePeer)
print("RTT: \(result.rtt)")

// Listen for events
Task {
    for await event in identifyService.events {
        switch event {
        case .received(let peer, let info):
            print("Identified \(peer): \(info.agentVersion ?? "")")
        case .pushReceived(let peer, let info):
            print("Push from \(peer): \(info.protocols)")
        default:
            break
        }
    }
}
```

---

## 実装順序

```
Week 1: 基盤
├── Day 1-2: P2PProtocols モジュール
├── Day 3-4: MuxedStream/Connection 拡張
└── Day 5: Node.attach() 実装

Week 2: Identify
├── Day 1-2: IdentifyProtobuf (encode/decode + tests)
├── Day 3-4: IdentifyService
└── Day 5: ユニットテスト

Week 3: Ping + 統合
├── Day 1-2: PingService
├── Day 3: Pingテスト
├── Day 4-5: 統合テスト + バグ修正

Week 4: 相互運用テスト
├── Day 1-2: Go-libp2p テストハーネス
├── Day 3-4: Rust-libp2p テストハーネス
└── Day 5: 相互運用テスト実行 + 修正
```

---

## 依存関係グラフ

```
P2PCore
    ↑
P2PMux ←──────────────────┐
    ↑                     │
P2PProtocols              │
    ↑                     │
    ├── P2PIdentify ──────┤
    │       ↑             │
    └── P2PPing ──────────┘
            ↑
           P2P
```

---

## 注意事項

1. **Protobufフィールド番号**: 必ずlibp2p仕様と一致させる（特にfield 7が欠番）
2. **observedAddr**: NATトラバーサルに重要、正確に実装
3. **Pingペイロード**: 必ず32バイト（仕様準拠）
4. **タイムアウト**: 適切なデフォルト値（Ping: 30s, Identify: 60s）
5. **エラーハンドリング**: 不正なメッセージでクラッシュしない
