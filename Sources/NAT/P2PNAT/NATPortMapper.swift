/// NATPortMapper - Unified NAT port mapping service
///
/// Facade that delegates to protocol-specific handlers (UPnP, NAT-PMP).
/// Manages lifecycle, caching, renewal, and event emission.
import Foundation
import P2PCore
import Synchronization

/// Internal state for NATPortMapper.
private struct NATPortMapperState: Sendable {
    var discoveredGateway: NATGatewayType?
    var externalAddress: String?
    var activeMappings: [UInt16: PortMapping] = [:]
    var renewalTasks: [UInt16: Task<Void, Never>] = [:]
    var isShutdown = false
}

/// Event state for NATPortMapper.
private struct NATPortMapperEventState: Sendable {
    var stream: AsyncStream<NATPortMapperEvent>?
    var continuation: AsyncStream<NATPortMapperEvent>.Continuation?
}

/// NAT port mapping service.
///
/// Discovers NAT gateways and creates port mappings to enable
/// inbound connections through NAT. Supports UPnP IGD and NAT-PMP.
public final class NATPortMapper: EventEmitting, Sendable {

    public let configuration: NATPortMapperConfiguration

    private let state: Mutex<NATPortMapperState>
    private let eventState: Mutex<NATPortMapperEventState>
    private let handlers: [any NATProtocolHandler]

    /// Creates a new NATPortMapper.
    public init(configuration: NATPortMapperConfiguration = .default) {
        self.configuration = configuration
        self.state = Mutex(NATPortMapperState())
        self.eventState = Mutex(NATPortMapperEventState())

        var handlers: [any NATProtocolHandler] = []
        if configuration.tryUPnP { handlers.append(UPnPHandler()) }
        if configuration.tryNATPMP { handlers.append(NATPMPHandler()) }
        self.handlers = handlers
    }

    /// Stream of events from this mapper.
    public var events: AsyncStream<NATPortMapperEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<NATPortMapperEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Public API

    /// Discovers a NAT gateway.
    ///
    /// Tries handlers in order (UPnP first, then NAT-PMP by default).
    public func discoverGateway() async throws -> NATGatewayType {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Check cache
        if let existing = state.withLock({ $0.discoveredGateway }) {
            return existing
        }

        // Try each handler in order, preserving last error
        var lastError: Error?
        for handler in handlers {
            do {
                let gateway = try await handler.discoverGateway(configuration: configuration)
                state.withLock { $0.discoveredGateway = gateway }
                emit(.gatewayDiscovered(type: gateway))
                return gateway
            } catch {
                lastError = error
            }
        }

        throw (lastError as? NATPortMapperError) ?? .noGatewayFound
    }

    /// Gets the external IP address.
    public func discoverExternalAddress() async throws -> String {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Check cache
        if let cached = state.withLock({ $0.externalAddress }) {
            return cached
        }

        let gateway = try await discoverGateway()
        let handler = try handlerForGateway(gateway)
        let address = try await handler.getExternalAddress(gateway: gateway, configuration: configuration)

        state.withLock { $0.externalAddress = address }
        emit(.externalAddressDiscovered(address: address))
        return address
    }

    /// Requests a port mapping.
    public func requestMapping(
        internalPort: UInt16,
        externalPort: UInt16? = nil,
        protocol: NATTransportProtocol,
        duration: Duration? = nil
    ) async throws -> PortMapping {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        let extPort = externalPort ?? internalPort
        let leaseDuration = duration ?? configuration.defaultLeaseDuration

        let mapping = try await performMapping(
            internalPort: internalPort,
            externalPort: extPort,
            protocol: `protocol`,
            duration: leaseDuration
        )

        emit(.portMappingCreated(mapping: mapping))
        return mapping
    }

    /// Releases a port mapping.
    public func releaseMapping(_ mapping: PortMapping) async throws {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Cancel renewal task
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.renewalTasks.removeValue(forKey: mapping.internalPort)
            _ = state.activeMappings.removeValue(forKey: mapping.internalPort)
            return t
        }
        task?.cancel()

        let handler = try handlerForGateway(mapping.gatewayType)
        try await handler.releaseMapping(mapping, configuration: configuration)
    }

    /// Shuts down the mapper and cancels all renewal tasks.
    public func shutdown() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            guard !state.isShutdown else { return [] }
            state.isShutdown = true
            let t = Array(state.renewalTasks.values)
            state.activeMappings.removeAll()
            state.renewalTasks.removeAll()
            return t
        }

        for task in tasks {
            task.cancel()
        }

        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Private

    /// Performs the actual port mapping request without emitting events.
    ///
    /// Separated from `requestMapping` so that renewal can reuse this
    /// without emitting `.portMappingCreated`.
    private func performMapping(
        internalPort: UInt16,
        externalPort: UInt16,
        protocol: NATTransportProtocol,
        duration: Duration
    ) async throws -> PortMapping {
        let gateway = try await discoverGateway()
        let handler = try handlerForGateway(gateway)
        let externalAddress = try await discoverExternalAddress()

        let mapping = try await handler.requestMapping(
            gateway: gateway,
            internalPort: internalPort,
            externalPort: externalPort,
            protocol: `protocol`,
            duration: duration,
            externalAddress: externalAddress,
            configuration: configuration
        )

        state.withLock { $0.activeMappings[internalPort] = mapping }

        if configuration.autoRenew {
            scheduleRenewal(for: mapping)
        }

        return mapping
    }

    private func emit(_ event: NATPortMapperEvent) {
        eventState.withLock { state in
            _ = state.continuation?.yield(event)
        }
    }

    private func handlerForGateway(_ gateway: NATGatewayType) throws -> any NATProtocolHandler {
        switch gateway {
        case .upnp:
            guard let handler = handlers.first(where: { $0 is UPnPHandler }) else {
                throw NATPortMapperError.noGatewayFound
            }
            return handler
        case .natpmp:
            guard let handler = handlers.first(where: { $0 is NATPMPHandler }) else {
                throw NATPortMapperError.noGatewayFound
            }
            return handler
        }
    }

    private func scheduleRenewal(for mapping: PortMapping) {
        let renewalTime = mapping.expiration - configuration.renewalBuffer
        let port = mapping.internalPort

        // Cancel any existing renewal for this port before creating a new one
        let existing = state.withLock { $0.renewalTasks.removeValue(forKey: port) }
        existing?.cancel()

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                try await Task.sleep(until: renewalTime, clock: .continuous)
            } catch {
                return // Cancelled
            }

            guard !Task.isCancelled else { return }

            // Verify this port is still actively mapped before renewing
            let isActive = self.state.withLock { state -> Bool in
                guard !state.isShutdown else { return false }
                return state.activeMappings[port] != nil
            }
            guard isActive else { return }

            do {
                let renewed = try await self.performMapping(
                    internalPort: mapping.internalPort,
                    externalPort: mapping.externalPort,
                    protocol: mapping.protocol,
                    duration: self.configuration.defaultLeaseDuration
                )
                self.emit(.portMappingRenewed(mapping: renewed))
            } catch {
                self.emit(.portMappingFailed(
                    internalPort: mapping.internalPort,
                    error: .mappingFailed("Renewal failed: \(error)")
                ))
                self.emit(.portMappingExpired(mapping: mapping))
            }
        }

        state.withLock { $0.renewalTasks[port] = task }
    }
}
