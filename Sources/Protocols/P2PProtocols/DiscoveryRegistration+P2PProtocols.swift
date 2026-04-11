import P2PDiscovery

public extension DiscoveryRegistration where Source: InboundProtocolHandler {
    mutating func handlesInboundStreams() {
        declareInboundProtocolIDs { $0.protocolIDs }
    }
}

public extension DiscoveryRegistration where Source: PeerLifecycleObserver {
    mutating func observesPeers() {
        observesPeerLifecycle()
    }
}

public extension DiscoveryRegistration where Source: ListenAddressContributor {
    mutating func contributesListenAddresses() {
        publishesListenAddresses()
    }
}

public extension DiscoveryRegistration where Source: LocalIdentityConsumer {
    mutating func consumesIdentity() {
        requiresIdentity()
    }
}

public extension DiscoveryRegistration where Source: ListenAddressConsumer {
    mutating func consumesListenAddresses() {
        requiresListenAddresses()
    }
}

public extension DiscoveryRegistration where Source: SupportedProtocolsConsumer {
    mutating func consumesSupportedProtocols() {
        requiresSupportedProtocols()
    }
}

public extension DiscoveryRegistration {
    mutating func activateOnStart() {
        activatesOnRuntimeStart()
    }
}

public extension DiscoveryRegistration where Source: StreamOpeningActivatable {
    mutating func activatesWithStreamOpening() {
        receivesStreamOpening()
        activatesOnRuntimeStart()
    }
}
