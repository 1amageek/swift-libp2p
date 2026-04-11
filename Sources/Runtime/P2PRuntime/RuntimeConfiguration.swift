import P2PCore

public struct RuntimeConfiguration: Sendable {
    public let keyPair: KeyPair
    public let listenAddresses: [Multiaddr]
    public let connectionProviders: [any ConnectionProvider]
    public let pool: PoolConfiguration
    public let maxNegotiatingInboundStreams: Int

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        connectionProviders: [any ConnectionProvider] = [],
        pool: PoolConfiguration = .init(),
        maxNegotiatingInboundStreams: Int = 128
    ) {
        self.keyPair = keyPair
        self.listenAddresses = listenAddresses
        self.connectionProviders = connectionProviders
        self.pool = pool
        self.maxNegotiatingInboundStreams = maxNegotiatingInboundStreams
    }
}
