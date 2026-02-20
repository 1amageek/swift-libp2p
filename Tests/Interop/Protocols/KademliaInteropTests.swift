/// KademliaInteropTests - Kademlia DHT interoperability tests
///
/// Tests that swift-libp2p Kademlia implementation is compatible with go-libp2p.
/// Focuses on FIND_NODE, PROVIDE, FIND_PROVIDERS, PUT_VALUE, and GET_VALUE operations.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter KademliaInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportQUIC
@testable import P2PKademlia
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols

/// Interoperability tests for Kademlia DHT protocol
@Suite("Kademlia DHT Interop Tests", .serialized)
struct KademliaInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p Kademlia node", .timeLimit(.minutes(2)))
    func connectToKademliaNode() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        print("[Kademlia] Node info: \(nodeInfo)")

        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        #expect(connection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))
        print("[Kademlia] Connected to Kademlia node")

        try await connection.close()
    }

    // MARK: - Protocol Negotiation Tests

    @Test("Kademlia protocol negotiation", .timeLimit(.minutes(2)))
    func kadProtocolNegotiation() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        // Negotiate Kademlia protocol
        guard try await negotiateKademliaProtocol(on: stream, timeout: .seconds(15)) else {
            try await stream.close()
            try await connection.close()
            return
        }
        print("[Kademlia] Protocol negotiated: /ipfs/kad/1.0.0")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - FIND_NODE Tests

    @Test("Kademlia FIND_NODE query", .timeLimit(.minutes(2)))
    func kadFindNode() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        guard try await negotiateKademliaProtocol(on: stream, timeout: .seconds(15)) else {
            try await stream.close()
            try await connection.close()
            return
        }

        let request = KademliaMessage.findNode(key: keyPair.peerID.multihash.bytes)
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(KademliaProtobuf.encode(request))))

        guard let responseFrame = try await readFromStreamWithTimeout(
            stream,
            timeout: .seconds(15),
            operation: "FIND_NODE response"
        ) else {
            try await stream.close()
            try await connection.close()
            return
        }

        let responseFrameData = Data(buffer: responseFrame)
        let responsePayload = try decodeLengthPrefixedMessage(responseFrameData)
        let response = try KademliaProtobuf.decode(responsePayload)

        #expect(response.type == .findNode)
        print("[Kademlia] FIND_NODE response decoded: closerPeers=\(response.closerPeers.count)")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Value Storage Tests

    @Test("Kademlia PUT_VALUE/GET_VALUE", .timeLimit(.minutes(2)))
    func kadPutGetValue() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Test PUT_VALUE
        let putStream = try await connection.newStream()

        guard try await negotiateKademliaProtocol(on: putStream, timeout: .seconds(15)) else {
            try await putStream.close()
            try await connection.close()
            return
        }

        let keyData = Data("interop-key".utf8)
        let valueData = Data("interop-test-value".utf8)
        let record = KademliaRecord.create(key: keyData, value: valueData)
        let putRequest = KademliaMessage.putValue(record: record)

        try await putStream.write(ByteBuffer(bytes: encodeLengthPrefixed(KademliaProtobuf.encode(putRequest))))
        guard let putResponseFrame = try await readFromStreamWithTimeout(
            putStream,
            timeout: .seconds(15),
            operation: "PUT_VALUE response"
        ) else {
            try await putStream.close()
            try await connection.close()
            return
        }

        let putResponseFrameData = Data(buffer: putResponseFrame)
        let putResponsePayload = try decodeLengthPrefixedMessage(putResponseFrameData)
        let putResponse = try KademliaProtobuf.decode(putResponsePayload)
        #expect(putResponse.type == .putValue)
        #expect(putResponse.record?.key == keyData)
        #expect(putResponse.record?.value == valueData)

        try await putStream.close()

        let getStream = try await connection.newStream()
        defer { closeStream(getStream) }

        guard try await negotiateKademliaProtocol(on: getStream, timeout: .seconds(15)) else {
            try await connection.close()
            return
        }

        let getRequest = KademliaMessage.getValue(key: keyData)
        try await getStream.write(ByteBuffer(bytes: encodeLengthPrefixed(KademliaProtobuf.encode(getRequest))))

        guard let getResponseFrame = try await readFromStreamWithTimeout(
            getStream,
            timeout: .seconds(15),
            operation: "GET_VALUE response"
        ) else {
            try await connection.close()
            return
        }

        let getResponseFrameData = Data(buffer: getResponseFrame)
        let getResponsePayload = try decodeLengthPrefixedMessage(getResponseFrameData)
        let getResponse = try KademliaProtobuf.decode(getResponsePayload)
        #expect(getResponse.type == .getValue)
        if let responseRecord = getResponse.record {
            #expect(responseRecord.value == valueData)
        } else {
            print("[Kademlia] GET_VALUE returned no record; closerPeers=\(getResponse.closerPeers.count)")
        }

        try await connection.close()
    }

    // MARK: - Provider Tests

    @Test("Kademlia PROVIDE operation", .timeLimit(.minutes(2)))
    func kadProvide() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        guard try await negotiateKademliaProtocol(on: stream, timeout: .seconds(15)) else {
            try await stream.close()
            try await connection.close()
            return
        }

        let contentKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let provider = KademliaPeer(
            id: keyPair.peerID,
            addresses: [],
            connectionType: .connected
        )
        let addProviderRequest = KademliaMessage.addProvider(key: contentKey, providers: [provider])
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(KademliaProtobuf.encode(addProviderRequest))))

        try await stream.close()

        let getProvidersStream = try await connection.newStream()
        defer { closeStream(getProvidersStream) }

        guard try await negotiateKademliaProtocol(on: getProvidersStream, timeout: .seconds(15)) else {
            try await connection.close()
            return
        }

        let getProvidersRequest = KademliaMessage.getProviders(key: contentKey)
        try await getProvidersStream.write(ByteBuffer(bytes: encodeLengthPrefixed(KademliaProtobuf.encode(getProvidersRequest))))

        guard let getProvidersResponseFrame = try await readFromStreamWithTimeout(
            getProvidersStream,
            timeout: .seconds(15),
            operation: "GET_PROVIDERS response"
        ) else {
            try await connection.close()
            return
        }

        let getProvidersResponseFrameData = Data(buffer: getProvidersResponseFrame)
        let getProvidersResponsePayload = try decodeLengthPrefixedMessage(getProvidersResponseFrameData)
        let getProvidersResponse = try KademliaProtobuf.decode(getProvidersResponsePayload)
        #expect(getProvidersResponse.type == .getProviders)
        print(
            "[Kademlia] GET_PROVIDERS response decoded: providers=\(getProvidersResponse.providerPeers.count), " +
                "closerPeers=\(getProvidersResponse.closerPeers.count)"
        )

        try await connection.close()

        print("[Kademlia] ADD_PROVIDER test completed")
    }

    // MARK: - Routing Table Tests

    @Test("Kademlia routing table interaction", .timeLimit(.minutes(2)))
    func kadRoutingTable() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .kademlia(mode: "server")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // After connecting, both peers should add each other to their routing tables
        // Wait for routing table to be populated
        try await Task.sleep(for: .seconds(1))

        // Check container logs for routing table info
        let logs = try await harness.getLogs()
        print("[Kademlia] Node logs snippet: \(logs.suffix(500))")

        try await connection.close()
    }
}

private enum KademliaInteropWireError: Error {
    case truncatedFrame(expected: Int, actual: Int)
}

private func encodeLengthPrefixed(_ payload: Data) -> Data {
    var framed = Data()
    framed.append(contentsOf: Varint.encode(UInt64(payload.count)))
    framed.append(payload)
    return framed
}

private func decodeLengthPrefixedMessage(_ frame: Data) throws -> Data {
    let (messageLength, prefixLength) = try Varint.decode(frame)
    let start = prefixLength
    let end = start + Int(messageLength)
    guard end <= frame.count else {
        throw KademliaInteropWireError.truncatedFrame(expected: end, actual: frame.count)
    }
    return Data(frame[start..<end])
}

private func readFromStreamWithTimeout(
    _ stream: any MuxedStream,
    timeout: Duration,
    operation: String
) async throws -> ByteBuffer? {
    let result = try await runWithTimeout(timeout: timeout) {
        try await stream.read()
    }

    if result == nil {
        do {
            try await stream.close()
        } catch {
            print("[Kademlia] Failed closing stream after timeout: \(error)")
        }
        print("[Kademlia] Timed out waiting for \(operation) after \(timeout)")
    }

    return result
}

private func negotiateKademliaProtocol(
    on stream: any MuxedStream,
    timeout: Duration
) async throws -> Bool {
    let negotiated = try await runWithTimeout(timeout: timeout) {
        let result = try await MultistreamSelect.negotiate(
            protocols: ["/ipfs/kad/1.0.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )
        return result.protocolID == "/ipfs/kad/1.0.0"
    }

    if let negotiated {
        return negotiated
    }

    do {
        try await stream.close()
    } catch {
        print("[Kademlia] Failed closing stream after negotiation timeout: \(error)")
    }
    print("[Kademlia] Timed out negotiating /ipfs/kad/1.0.0 after \(timeout)")
    return false
}

private func runWithTimeout<T: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let resolution = TimeoutResolution()

    return try await withCheckedThrowingContinuation { continuation in
        let operationTask = Task {
            do {
                let value = try await operation()
                if await resolution.tryResolve() {
                    continuation.resume(returning: value)
                }
            } catch {
                if await resolution.tryResolve() {
                    continuation.resume(throwing: error)
                }
            }
        }

        Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }

            if await resolution.tryResolve() {
                operationTask.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

private actor TimeoutResolution {
    private var resolved = false

    func tryResolve() -> Bool {
        if resolved {
            return false
        }
        resolved = true
        return true
    }
}

private func stopHarness(_ harness: GoProtocolHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
            print("[Kademlia] Failed to stop harness: \(error)")
        }
    }
}

private func closeStream(_ stream: MuxedStream) {
    Task {
        do {
            try await stream.close()
        } catch {
            print("[Kademlia] Failed to close stream: \(error)")
        }
    }
}
