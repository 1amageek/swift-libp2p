import P2PCore
import P2PPing

/// Internal adapter to make Node work with HealthMonitor.
internal actor NodePingProvider: PingProvider {
    private weak var runtime: NodeRuntime?
    private let pingService: PingService

    init(runtime: NodeRuntime) {
        self.runtime = runtime
        self.pingService = PingService()
    }

    func ping(_ peer: PeerID) async throws -> Duration {
        guard let runtime else {
            throw NodeError.nodeNotRunning
        }
        let result = try await pingService.ping(peer, using: runtime)
        return result.rtt
    }
}
