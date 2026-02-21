/// NodeE2ETests - End-to-end integration tests for Node communication
///
/// Tests the full stack: MemoryTransport + Plaintext + Yamux + Node

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2P
@testable import P2PCore
@testable import P2PTransport
@testable import P2PTransportMemory
@testable import P2PSecurity
@testable import P2PSecurityPlaintext
@testable import P2PMux
@testable import P2PMuxYamux
@testable import P2PPing

@Suite("Node E2E Tests", .serialized)
struct NodeE2ETests {

    // MARK: - Helper Methods

    /// Creates a fully configured node for testing.
    private func makeNode(
        name: String,
        hub: MemoryHub,
        keyPair: KeyPair = .generateEd25519(),
        listenAddress: Multiaddr? = nil,
        pool: PoolConfiguration = .init(
            limits: .development,
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        ),
        healthCheck: HealthMonitorConfiguration? = nil,
        services: [any NodeService] = []
    ) -> Node {
        var listenAddresses: [Multiaddr] = []
        if let addr = listenAddress {
            listenAddresses.append(addr)
        }

        let config = NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: healthCheck,
            services: services
        )
        return Node(configuration: config)
    }

    // MARK: - Basic Connection Tests

    @Test("Two nodes can connect via MemoryTransport")
    func testBasicNodeConnection() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server1")

        // Create server and client nodes
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        // Start server
        try await server.start()

        let serverPeerID = await server.peerID

        // Connect client to server
        try await client.start()
        let connectedPeer = try await client.connect(to: serverAddr)

        #expect(connectedPeer == serverPeerID)

        // Verify connection state
        let clientConnCount = await client.connectionCount
        #expect(clientConnCount == 1)
        let clientPeers = await client.connectedPeers
        #expect(clientPeers.contains(serverPeerID))

        // Wait a bit for server to register the connection
        try await Task.sleep(for: .milliseconds(50))
        let clientPeerID = await client.peerID
        let serverPeers = await server.connectedPeers
        #expect(serverPeers.contains(clientPeerID))

        // Cleanup
        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Node connect with PeerID in address")
    func testConnectWithPeerID() async throws {
        let hub = MemoryHub()
        let serverKeyPair = KeyPair.generateEd25519()
        let serverAddr = Multiaddr.memory(id: "server2")

        let server = makeNode(name: "server", hub: hub, keyPair: serverKeyPair, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        // Create address with peer ID
        let addrWithPeerID = try Multiaddr("\(serverAddr)/p2p/\(serverKeyPair.peerID)")

        let connectedPeer = try await client.connect(to: addrWithPeerID)
        #expect(connectedPeer == serverKeyPair.peerID)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Connection emits events")
    func testConnectionEvents() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server3")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        // Collect events using Mutex for thread safety
        let clientEvents = Mutex<[NodeEvent]>([])
        let serverPeerID = await server.peerID

        let eventTask = Task { @Sendable in
            for await event in await client.events {
                clientEvents.withLock { $0.append(event) }
                let count = clientEvents.withLock { $0.count }
                if count >= 1 {
                    break
                }
            }
        }

        _ = try await client.connect(to: serverAddr)

        // Wait for event
        try await Task.sleep(for: .milliseconds(100))
        eventTask.cancel()

        // Verify peerConnected event
        let events = clientEvents.withLock { $0 }
        let hasConnectedEvent = events.contains { event in
            if case .peerConnected(let peer) = event {
                return peer == serverPeerID
            }
            return false
        }
        #expect(hasConnectedEvent)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Protocol Handler Tests

    @Test("Custom protocol handler receives streams")
    func testCustomProtocolHandler() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server4")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        // Track received messages
        let receivedMessages = Mutex<[String]>([])

        // Register custom protocol handler on server
        await server.handle("/test/echo/1.0.0") { context in
            do {
                // Read message
                let data = try await context.stream.read()
                let message = String(buffer: data)
                receivedMessages.withLock { $0.append(message) }

                // Echo back
                try await context.stream.write(data)
                try await context.stream.close()
            } catch {
                // Stream closed
            }
        }

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        // Open stream and send message
        let stream = try await client.newStream(to: serverPeerID, protocol: "/test/echo/1.0.0")
        let testMessage = "Hello, libp2p!"
        try await stream.write(ByteBuffer(string: testMessage))

        // Read echo response
        let response = try await stream.read()
        let responseString = String(buffer: response)

        #expect(responseString == testMessage)

        // Verify server received the message
        try await Task.sleep(for: .milliseconds(50))
        let messages = receivedMessages.withLock { $0 }
        #expect(messages.contains(testMessage))

        try await stream.close()
        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Multiple protocol handlers can be registered")
    func testMultipleProtocolHandlers() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server5")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        let echoCount = Mutex(0)
        let reverseCount = Mutex(0)

        // Register echo handler
        await server.handle("/test/echo/1.0.0") { context in
            echoCount.withLock { $0 += 1 }
            do {
                let data = try await context.stream.read()
                try await context.stream.write(data)
            } catch {
                // Connection closed or stream failed.
            }
            do {
                try await context.stream.close()
            } catch {
                // Ignore close failures in test handler cleanup.
            }
        }

        // Register reverse handler
        await server.handle("/test/reverse/1.0.0") { context in
            reverseCount.withLock { $0 += 1 }
            do {
                let data = try await context.stream.read()
                let reversedBytes = Array(Data(buffer: data).reversed())
                try await context.stream.write(ByteBuffer(bytes: reversedBytes))
            } catch {
                // Connection closed or stream failed.
            }
            do {
                try await context.stream.close()
            } catch {
                // Ignore close failures in test handler cleanup.
            }
        }

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        // Test echo
        let echoStream = try await client.newStream(to: serverPeerID, protocol: "/test/echo/1.0.0")
        try await echoStream.write(ByteBuffer(string: "test"))
        let echoResponse = try await echoStream.read()
        #expect(String(buffer: echoResponse) == "test")
        try await echoStream.close()

        // Test reverse
        let reverseStream = try await client.newStream(to: serverPeerID, protocol: "/test/reverse/1.0.0")
        try await reverseStream.write(ByteBuffer(string: "hello"))
        let reverseResponse = try await reverseStream.read()
        #expect(String(buffer: reverseResponse) == "olleh")
        try await reverseStream.close()

        try await Task.sleep(for: .milliseconds(50))
        #expect(echoCount.withLock { $0 } == 1)
        #expect(reverseCount.withLock { $0 } == 1)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Ping Protocol Tests

    @Test("Ping protocol works end-to-end")
    func testPingProtocol() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server6")

        let pingService = PingService()
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr, services: [pingService])
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        // Ping the server
        let result = try await pingService.ping(serverPeerID, using: client)

        #expect(result.peer == serverPeerID)
        #expect(result.rtt > .zero)
        #expect(result.rtt < .seconds(5)) // Should be fast with MemoryTransport

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Multiple pings return statistics")
    func testMultiplePings() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server7")

        let pingService = PingService()
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr, services: [pingService])
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        // Send multiple pings
        let results = try await pingService.pingMultiple(
            serverPeerID,
            using: client,
            count: 3,
            interval: .milliseconds(10)
        )

        #expect(results.count == 3)

        // Get statistics
        let stats = PingService.statistics(from: results)
        #expect(stats != nil)
        if let stats = stats {
            #expect(stats.min <= stats.avg)
            #expect(stats.avg <= stats.max)
        }

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Multi-Peer Tests

    @Test("Multiple clients can connect to same server")
    func testMultipleClients() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server8")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client1 = makeNode(name: "client1", hub: hub)
        let client2 = makeNode(name: "client2", hub: hub)
        let client3 = makeNode(name: "client3", hub: hub)

        try await server.start()
        try await client1.start()
        try await client2.start()
        try await client3.start()

        let serverPeerID = await server.peerID

        // All clients connect
        let peer1 = try await client1.connect(to: serverAddr)
        let peer2 = try await client2.connect(to: serverAddr)
        let peer3 = try await client3.connect(to: serverAddr)

        #expect(peer1 == serverPeerID)
        #expect(peer2 == serverPeerID)
        #expect(peer3 == serverPeerID)

        // Wait for server to register connections
        try await Task.sleep(for: .milliseconds(100))

        // Server should have 3 connections
        let serverConnCount = await server.connectionCount
        #expect(serverConnCount == 3)

        await client1.shutdown()
        await client2.shutdown()
        await client3.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Trim emits structured context event", .timeLimit(.minutes(1)))
    func testTrimEmitsStructuredContextEvent() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server-trim-context")

        let serverPool = PoolConfiguration(
            limits: ConnectionLimits(
                highWatermark: 1,
                lowWatermark: 1,
                maxConnectionsPerPeer: 2,
                maxInbound: nil,
                maxOutbound: nil,
                gracePeriod: .zero
            ),
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(2)
        )
        let server = makeNode(
            name: "server-trim-context",
            hub: hub,
            listenAddress: serverAddr,
            pool: serverPool
        )
        let client1 = makeNode(name: "client-trim-context-1", hub: hub)
        let client2 = makeNode(name: "client-trim-context-2", hub: hub)

        let trimmedContexts = Mutex<[ConnectionTrimmedContext]>([])
        let eventTask = Task { @Sendable in
            for await event in await server.events {
                guard case .connection(let connectionEvent) = event else { continue }
                guard case .trimmedWithContext(peer: _, context: let context) = connectionEvent else { continue }
                trimmedContexts.withLock { $0.append(context) }
                break
            }
        }

        try await server.start()
        try await client1.start()
        try await client2.start()

        _ = try await client1.connect(to: serverAddr)
        _ = try await client2.connect(to: serverAddr)

        var observed = false
        for _ in 0..<60 {
            observed = trimmedContexts.withLock { !$0.isEmpty }
            if observed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        eventTask.cancel()

        #expect(observed)
        let contexts = trimmedContexts.withLock { $0 }
        #expect(!contexts.isEmpty)
        if let context = contexts.first {
            #expect(context.rank != nil)
            #expect(context.tagCount == 0)
            #expect(context.direction == .inbound)
            #expect(context.idleDuration >= .zero)
        }

        await client1.shutdown()
        await client2.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Trim constrained emits summary event", .timeLimit(.minutes(1)))
    func testTrimConstrainedEvent() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server-trim-constrained")

        let serverPool = PoolConfiguration(
            limits: ConnectionLimits(
                highWatermark: 1,
                lowWatermark: 1,
                maxConnectionsPerPeer: 2,
                maxInbound: nil,
                maxOutbound: nil,
                gracePeriod: .seconds(60)
            ),
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(2)
        )
        let server = makeNode(
            name: "server-trim-constrained",
            hub: hub,
            listenAddress: serverAddr,
            pool: serverPool
        )
        let client1 = makeNode(name: "client-trim-constrained-1", hub: hub)
        let client2 = makeNode(name: "client-trim-constrained-2", hub: hub)

        let constrainedEvents = Mutex<[(target: Int, selected: Int, trimmable: Int, active: Int)]>([])
        let eventTask = Task { @Sendable in
            for await event in await server.events {
                guard case .connection(let connectionEvent) = event else { continue }
                guard case .trimConstrained(
                    target: let target,
                    selected: let selected,
                    trimmable: let trimmable,
                    active: let active
                ) = connectionEvent else { continue }
                constrainedEvents.withLock { $0.append((target, selected, trimmable, active)) }
                break
            }
        }

        try await server.start()
        try await client1.start()
        try await client2.start()

        _ = try await client1.connect(to: serverAddr)
        _ = try await client2.connect(to: serverAddr)

        var observed = false
        for _ in 0..<60 {
            observed = constrainedEvents.withLock { !$0.isEmpty }
            if observed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        eventTask.cancel()

        #expect(observed)
        let events = constrainedEvents.withLock { $0 }
        #expect(!events.isEmpty)
        if let event = events.first {
            #expect(event.target == 1)
            #expect(event.selected == 0)
            #expect(event.trimmable == 0)
            #expect(event.active >= 2)
        }

        await client1.shutdown()
        await client2.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Peer-to-peer mesh topology")
    func testMeshTopology() async throws {
        let hub = MemoryHub()

        // Create 3 nodes that will form a mesh
        let node1Addr = Multiaddr.memory(id: "node1")
        let node2Addr = Multiaddr.memory(id: "node2")
        let node3Addr = Multiaddr.memory(id: "node3")

        let node1 = makeNode(name: "node1", hub: hub, listenAddress: node1Addr)
        let node2 = makeNode(name: "node2", hub: hub, listenAddress: node2Addr)
        let node3 = makeNode(name: "node3", hub: hub, listenAddress: node3Addr)

        try await node1.start()
        try await node2.start()
        try await node3.start()

        let peer1 = await node1.peerID
        let peer2 = await node2.peerID
        let peer3 = await node3.peerID

        // Create mesh: 1-2, 2-3, 1-3
        _ = try await node1.connect(to: node2Addr)
        _ = try await node2.connect(to: node3Addr)
        _ = try await node1.connect(to: node3Addr)

        try await Task.sleep(for: .milliseconds(100))

        // Verify connections
        let node1Peers = await node1.connectedPeers
        let node2Peers = await node2.connectedPeers
        let node3Peers = await node3.connectedPeers

        #expect(node1Peers.contains(peer2))
        #expect(node1Peers.contains(peer3))
        #expect(node2Peers.contains(peer1))
        #expect(node2Peers.contains(peer3))
        #expect(node3Peers.contains(peer1))
        #expect(node3Peers.contains(peer2))

        await node1.shutdown()
        await node2.shutdown()
        await node3.shutdown()
        hub.reset()
    }

    // MARK: - Disconnect Tests

    @Test("Disconnect removes peer from connected list")
    func testDisconnect() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server9")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        var connCount = await client.connectionCount
        var connPeers = await client.connectedPeers
        #expect(connCount == 1)
        #expect(connPeers.contains(serverPeerID))

        // Disconnect
        await client.disconnect(from: serverPeerID)

        connCount = await client.connectionCount
        connPeers = await client.connectedPeers
        #expect(connCount == 0)
        #expect(!connPeers.contains(serverPeerID))

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Disconnect emits peerDisconnected event")
    func testDisconnectEvent() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server10")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        let disconnectReceived = Mutex(false)
        let eventTask = Task { @Sendable in
            for await event in await client.events {
                if case .peerDisconnected(let peer) = event, peer == serverPeerID {
                    disconnectReceived.withLock { $0 = true }
                    break
                }
            }
        }

        // Give time for event listener to start
        try await Task.sleep(for: .milliseconds(50))

        await client.disconnect(from: serverPeerID)

        try await Task.sleep(for: .milliseconds(100))
        eventTask.cancel()

        let wasReceived = disconnectReceived.withLock { $0 }
        #expect(wasReceived)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Connection Gating Tests

    @Test("ConnectionGater blocks dial")
    func testGaterBlocksDial() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server11")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)

        // Create client with gater that blocks all dials
        let gater = BlocklistGater()
        gater.block(address: "server11") // Block by address substring

        let clientConfig = NodeConfiguration(
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(gater: gater),
            healthCheck: nil
        )
        let client = Node(configuration: clientConfig)

        try await server.start()
        try await client.start()

        // Should fail due to gating
        await #expect(throws: NodeError.self) {
            _ = try await client.connect(to: serverAddr)
        }

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("ConnectionGater blocks by PeerID after secured")
    func testGaterBlocksByPeerID() async throws {
        let hub = MemoryHub()
        let serverKeyPair = KeyPair.generateEd25519()
        let serverAddr = Multiaddr.memory(id: "server12")

        let server = makeNode(name: "server", hub: hub, keyPair: serverKeyPair, listenAddress: serverAddr)

        // Create client with gater that blocks the server's PeerID
        let gater = BlocklistGater()
        gater.block(peer: serverKeyPair.peerID)

        let clientConfig = NodeConfiguration(
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(gater: gater),
            healthCheck: nil
        )
        let client = Node(configuration: clientConfig)

        try await server.start()
        try await client.start()

        // Should fail due to gating after secured stage
        await #expect(throws: NodeError.self) {
            _ = try await client.connect(to: serverAddr)
        }

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Connection Limits Tests

    @Test("Connection limits enforce maxConnectionsPerPeer")
    func testMaxConnectionsPerPeer() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server13")

        // Client enforces maxConnectionsPerPeer = 1 and dials the same peer twice.
        let clientPool = PoolConfiguration(
            limits: ConnectionLimits(maxConnectionsPerPeer: 1),
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        )
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub, pool: clientPool)

        try await server.start()
        try await client.start()
        let serverPeerID = await server.peerID
        let addrWithPeerID = try Multiaddr("\(serverAddr)/p2p/\(serverPeerID)")

        // First connection should succeed
        _ = try await client.connect(to: addrWithPeerID)
        let clientConnCount = await client.connectionCount
        #expect(clientConnCount == 1)

        // Second connection to same peer should be rejected by per-peer limit.
        do {
            _ = try await client.connect(to: addrWithPeerID)
            Issue.record("Expected second connect to fail with connectionLimitReached")
        } catch NodeError.connectionLimitReached {
            // Expected path.
        } catch {
            Issue.record("Expected NodeError.connectionLimitReached, got \(error)")
        }

        // Existing connection must remain healthy and singular.
        let finalClientConnCount = await client.connectionCount
        #expect(finalClientConnCount == 1)

        var serverSettledToSingleConnection = false
        for _ in 0..<20 {
            if await server.connectionCount == 1 {
                serverSettledToSingleConnection = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(serverSettledToSingleConnection)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Bidirectional Stream Tests

    @Test("Streams support bidirectional communication")
    func testBidirectionalStream() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server14")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        // Server handler that has a conversation
        await server.handle("/test/chat/1.0.0") { context in
            do {
                // Read greeting
                let greeting = try await context.stream.read()
                let greetingStr = String(buffer: greeting)

                // Send response
                try await context.stream.write(ByteBuffer(string: "Hello, \(greetingStr)!"))

                // Read follow-up
                let followUp = try await context.stream.read()
                let followUpStr = String(buffer: followUp)

                // Send final response
                try await context.stream.write(ByteBuffer(string: "Goodbye, \(followUpStr)!"))

                try await context.stream.close()
            } catch {
                do {
                    try await context.stream.close()
                } catch {
                    // Ignore close failures in test handler cleanup.
                }
            }
        }

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        let stream = try await client.newStream(to: serverPeerID, protocol: "/test/chat/1.0.0")

        // Send greeting
        try await stream.write(ByteBuffer(string: "Alice"))

        // Read response
        let response1 = try await stream.read()
        #expect(String(buffer: response1) == "Hello, Alice!")

        // Send follow-up
        try await stream.write(ByteBuffer(string: "Bob"))

        // Read final response
        let response2 = try await stream.read()
        #expect(String(buffer: response2) == "Goodbye, Bob!")

        try await stream.close()
        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Concurrent Operations Tests

    @Test("Multiple concurrent streams to same peer")
    func testConcurrentStreams() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "server15")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        let requestCount = Mutex(0)

        // Simple echo handler
        await server.handle("/test/concurrent/1.0.0") { context in
            requestCount.withLock { $0 += 1 }
            do {
                let data = try await context.stream.read()
                try await context.stream.write(data)
            } catch {
                // Connection closed or stream failed.
            }
            do {
                try await context.stream.close()
            } catch {
                // Ignore close failures in test handler cleanup.
            }
        }

        try await server.start()
        try await client.start()

        let serverPeerID = await server.peerID
        _ = try await client.connect(to: serverAddr)

        // Open 5 streams concurrently
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let stream = try await client.newStream(to: serverPeerID, protocol: "/test/concurrent/1.0.0")
                    let message = "Message \(i)"
                    try await stream.write(ByteBuffer(string: message))
                    let response = try await stream.read()
                    try await stream.close()
                    return String(buffer: response)
                }
            }

            var responses: [String] = []
            for try await response in group {
                responses.append(response)
            }

            #expect(responses.count == 5)
            for i in 0..<5 {
                #expect(responses.contains("Message \(i)"))
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(requestCount.withLock { $0 } == 5)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Simultaneous Connect Resolution

    @Test("Simultaneous connect resolves to single connection", .timeLimit(.minutes(1)))
    func testSimultaneousConnectResolution() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "simul-server")
        let clientAddr = Multiaddr.memory(id: "simul-client")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub, listenAddress: clientAddr)

        try await server.start()
        try await client.start()

        // Both dial each other simultaneously
        async let serverDial: PeerID = server.connect(to: clientAddr)
        async let clientDial: PeerID = client.connect(to: serverAddr)

        let serverResult = try await serverDial
        let clientResult = try await clientDial
        let serverPeerID = await server.peerID
        let clientPeerID = await client.peerID

        #expect(serverResult == clientPeerID)
        #expect(clientResult == serverPeerID)

        // Wait for resolution
        try await Task.sleep(for: .milliseconds(100))

        // After resolution, each node should have exactly 1 connection to the other
        let serverConnCount = await server.connectionCount
        let clientConnCount = await client.connectionCount
        #expect(serverConnCount == 1)
        #expect(clientConnCount == 1)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("peerConnected emits only once for simultaneous connect", .timeLimit(.minutes(1)))
    func testPeerConnectedEmitsOnce() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "event-server")
        let clientAddr = Multiaddr.memory(id: "event-client")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub, listenAddress: clientAddr)

        try await server.start()
        try await client.start()

        // Collect events from client
        let peerConnectedCount = Mutex(0)
        let eventTask = Task {
            for await event in await client.events {
                if case .peerConnected = event {
                    peerConnectedCount.withLock { $0 += 1 }
                }
            }
        }

        // Both dial each other simultaneously
        async let serverDial: PeerID = server.connect(to: clientAddr)
        async let clientDial: PeerID = client.connect(to: serverAddr)
        _ = try await (serverDial, clientDial)

        // Wait for events to propagate
        try await Task.sleep(for: .milliseconds(200))

        // Should have received exactly 1 peerConnected event (not 2)
        let count = peerConnectedCount.withLock { $0 }
        #expect(count == 1)

        eventTask.cancel()
        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("peerDisconnected emits only after last connection closes", .timeLimit(.minutes(1)))
    func testPeerDisconnectedEmitsOnLastClose() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "disc-server")

        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub)

        try await server.start()
        try await client.start()

        // Collect disconnect events
        let disconnectedCount = Mutex(0)
        let eventTask = Task {
            for await event in await client.events {
                if case .peerDisconnected = event {
                    disconnectedCount.withLock { $0 += 1 }
                }
            }
        }

        // Connect
        let serverPeerID = try await client.connect(to: serverAddr)
        try await Task.sleep(for: .milliseconds(50))

        // Disconnect
        await client.disconnect(from: serverPeerID)
        try await Task.sleep(for: .milliseconds(100))

        // Should have exactly 1 disconnect event
        let count = disconnectedCount.withLock { $0 }
        #expect(count == 1)

        eventTask.cancel()
        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    // MARK: - Address Resolution Tests

    @Test("resolveUnspecifiedAddresses expands 0.0.0.0 to interface IPs", .timeLimit(.minutes(1)))
    func resolveUnspecifiedAddresses() throws {
        let addr = try Multiaddr("/ip4/0.0.0.0/tcp/52371")
        let resolved = Node.resolveUnspecifiedAddresses([addr])

        // Should have at least one address (127.0.0.1)
        #expect(!resolved.isEmpty)

        // No resolved address should contain 0.0.0.0
        for r in resolved {
            #expect(r.ipAddress != "0.0.0.0")
        }

        // All resolved addresses should keep the same port
        for r in resolved {
            #expect(r.tcpPort == 52371)
        }

        // Should contain loopback
        let hasLoopback = resolved.contains { $0.ipAddress == "127.0.0.1" }
        #expect(hasLoopback)
    }

    @Test("resolveUnspecifiedAddresses keeps specific addresses as-is", .timeLimit(.minutes(1)))
    func resolveSpecificAddresses() throws {
        let addr = try Multiaddr("/ip4/192.168.1.100/tcp/9000")
        let resolved = Node.resolveUnspecifiedAddresses([addr])

        #expect(resolved.count == 1)
        #expect(resolved[0].ipAddress == "192.168.1.100")
        #expect(resolved[0].tcpPort == 9000)
    }

    @Test("Node advertises resolved addresses after start", .timeLimit(.minutes(1)))
    func nodeAdvertisesResolvedAddresses() async throws {
        let hub = MemoryHub()
        let server = makeNode(name: "addr-server", hub: hub,
                              listenAddress: .memory(id: "addr-test"))

        try await server.start()

        // Memory transport addresses don't have unspecified IPs,
        // so advertisedAddresses should contain the bound address
        let advertised = server.advertisedAddresses
        #expect(!advertised.isEmpty)

        await server.shutdown()
        hub.reset()
    }
}
