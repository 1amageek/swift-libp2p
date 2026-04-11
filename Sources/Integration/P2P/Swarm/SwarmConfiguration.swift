import P2PCore
import P2PRuntime

internal struct SwarmConfiguration: Sendable {
    let localIdentity: LocalIdentity
    let listenAddresses: [Multiaddr]
    let connectionProviders: [any ConnectionProvider]
    let pool: PoolConfiguration
    let idleTimeout: Duration
    let reconnectionPolicy: ReconnectionPolicy
    let maxNegotiatingInboundStreams: Int
    let connectionGater: (any ConnectionGater)?
    let connectionResources: (any ConnectionResourceAccounting)?
    let streamResources: (any StreamResourceAccounting)?
    let streamLifecycle: any StreamLifecycleCoordinator
    let reconnectPlanner: any ReconnectPlanner
    let conflictResolver: any ConnectionConflictResolver
}
