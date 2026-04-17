/// NodeLifecycleBenchmarks - Benchmarks for DSL resolution and Node lifecycle
import Testing
import Foundation
@testable import P2P
@testable import P2PCore
@testable import P2PIdentify
@testable import P2PTransportMemory
@testable import P2PMuxYamux
@testable import P2PSecurityPlaintext

@Suite("Node Lifecycle Benchmarks", .serialized)
struct NodeLifecycleBenchmarks {

    @Test("Node DSL resolves trivial component")
    func resolveTrivialComponent() {
        benchmark("Node.init { Ping() }", iterations: 50_000) {
            let node = Node(
                listenAddresses: [],
                transports: [],
                security: [PlaintextUpgrader()],
                muxers: [YamuxMuxer()],
                healthCheck: nil
            ) {
                Ping()
            }
            blackHole(node)
        }
    }

    @Test("Node DSL resolves several services and discoveries")
    func resolveCompositeComponent() {
        benchmark("Node.init { Ping; Identify; CYCLON; MDNS }", iterations: 20_000) {
            let node = Node(
                listenAddresses: [],
                transports: [],
                security: [PlaintextUpgrader()],
                muxers: [YamuxMuxer()],
                healthCheck: nil
            ) {
                Ping()
                Identify()
                CYCLON()
                MDNS()
            }
            blackHole(node)
        }
    }

    @Test("Node DSL re-wraps a built-in discovery primitive")
    func rewrapDiscoveryPrimitive() {
        let inner = MDNS().weight(2.0)
        benchmark("MDNS(discoveryPrimitive: inner)", iterations: 100_000) {
            blackHole(MDNS(discoveryPrimitive: inner.discoveryPrimitive))
        }
    }

    @Test("Node start/shutdown roundtrip (memory transport)")
    func startShutdownRoundtrip() async throws {
        try await benchmark("Node.start + shutdown", iterations: 200) {
            let hub = MemoryHub()
            let node = Node(
                listenAddresses: [Multiaddr.memory(id: "benchmark-node")],
                transports: [MemoryTransport(hub: hub)],
                security: [PlaintextUpgrader()],
                muxers: [YamuxMuxer()],
                healthCheck: nil
            ) {
                Ping()
            }
            try await node.start()
            try await node.shutdown()
            hub.reset()
        }
    }

    @Test("Concurrent Node.start coalescing overhead")
    func concurrentStartCoalescing() async throws {
        try await benchmark("Node.start x16 (coalesced)", iterations: 200) {
            let hub = MemoryHub()
            let node = Node(
                listenAddresses: [Multiaddr.memory(id: "benchmark-node-coalesce")],
                transports: [MemoryTransport(hub: hub)],
                security: [PlaintextUpgrader()],
                muxers: [YamuxMuxer()],
                healthCheck: nil
            ) {
                Ping()
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask { try await node.start() }
                }
                try await group.waitForAll()
            }
            try await node.shutdown()
            hub.reset()
        }
    }
}
