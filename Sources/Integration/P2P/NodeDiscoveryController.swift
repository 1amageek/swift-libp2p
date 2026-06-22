import P2PCore
import P2PDiscovery

internal actor NodeDiscoveryController {
    private let configuration: DiscoveryConfiguration
    private let localPeerID: PeerID
    private let peerStore: any PeerStore
    private let addressBook: any AddressBook
    private let pool: ConnectionPool
    private let dialBackoff: DialBackoff
    private let connect: @Sendable (Multiaddr) async throws -> PeerID

    private var tasks: [Task<Void, Never>] = []

    init(
        configuration: DiscoveryConfiguration,
        localPeerID: PeerID,
        peerStore: any PeerStore,
        addressBook: any AddressBook,
        pool: ConnectionPool,
        dialBackoff: DialBackoff,
        connect: @escaping @Sendable (Multiaddr) async throws -> PeerID
    ) {
        self.configuration = configuration
        self.localPeerID = localPeerID
        self.peerStore = peerStore
        self.addressBook = addressBook
        self.pool = pool
        self.dialBackoff = dialBackoff
        self.connect = connect
    }

    func start(sources: [any DiscoveryService]) {
        guard tasks.isEmpty else { return }

        for source in sources {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(source: source)
            }
            tasks.append(task)
        }
    }

    func shutdown() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    private func run(source: any DiscoveryService) async {
        let peers = await source.knownPeers()
        for peer in peers {
            guard !Task.isCancelled else { return }
            guard peer != localPeerID else { continue }
            await tryAutoConnect(to: peer, hints: [])
        }

        for await observation in source.observations {
            guard !Task.isCancelled else { return }
            guard observation.subject != localPeerID else { continue }
            guard pool.connectionCount < configuration.maxAutoConnectPeers else { continue }

            switch observation.kind {
            case .announcement, .reachable:
                await peerStore.addObservation(observation)
                await tryAutoConnect(
                    to: observation.subject,
                    hints: observation.hints
                )
            case .unreachable:
                break
            }
        }
    }

    private func tryAutoConnect(
        to peer: PeerID,
        hints: [Multiaddr]
    ) async {
        guard !dialBackoff.shouldBackOff(from: peer) else { return }
        guard !pool.isConnected(to: peer) else { return }
        guard !pool.hasReconnecting(for: peer) else { return }
        guard !pool.hasPendingDial(to: peer) else { return }

        // Filter discovery hints before auto-dialing: loopback, link-local, and
        // unspecified addresses are not safe auto-dial targets and could be used
        // to redirect the node. Only globally dialable hints are persisted/dialed.
        let dialableHints = hints.filter { $0.isGloballyDialableHint }
        if !dialableHints.isEmpty {
            await peerStore.addAddresses(dialableHints, for: peer)
        }

        guard let address = await addressBook.bestAddress(for: peer) else {
            return
        }

        do {
            _ = try await connect(address)
            await addressBook.recordSuccess(address: address, for: peer)
        } catch {
            dialBackoff.recordFailure(for: peer)
            await addressBook.recordFailure(address: address, for: peer)
        }
    }
}
