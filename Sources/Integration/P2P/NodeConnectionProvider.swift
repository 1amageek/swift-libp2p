import P2PCore
import P2PDiscovery

/// Internal adapter to make Node work with Bootstrap.
internal actor NodeConnectionProvider: BootstrapConnectionProvider {
    private weak var runtime: NodeRuntime?

    init(runtime: NodeRuntime) {
        self.runtime = runtime
    }

    func connect(to address: Multiaddr) async throws -> PeerID {
        guard let runtime else {
            throw NodeError.nodeNotRunning
        }
        return try await runtime.dial(to: address)
    }

    func connectedPeerCount() async -> Int {
        guard let runtime else { return 0 }
        return runtime.connectionCount
    }

    func connectedPeers() async -> Set<PeerID> {
        guard let runtime else { return [] }
        return Set(runtime.connectedPeers)
    }
}
