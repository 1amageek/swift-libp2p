import Foundation
import Synchronization
import NIOUDPTransport
import NIOCore
import P2PDiscoveryBeacon

/// WiFi beacon transport adapter using UDP multicast.
///
/// Broadcasts and receives beacon payloads over a local WiFi network
/// without requiring any OS-specific APIs. Uses standard UDP multicast
/// via SwiftNIO.
///
/// Usage:
/// ```swift
/// let adapter = WiFiBeaconAdapter(configuration: .init())
/// try await adapter.startBeacon(payload)
///
/// for await discovery in adapter.discoveries {
///     beaconDiscovery.processDiscovery(discovery)
/// }
///
/// await adapter.shutdown()
/// ```
public final class WiFiBeaconAdapter: TransportAdapter, Sendable {

    // MARK: - TransportAdapter Properties

    public let mediumID: String = "wifi-direct"

    public let characteristics: MediumCharacteristics = .wifiDirect

    // MARK: - Private State

    private let configuration: WiFiBeaconConfiguration

    private struct AdapterState: Sendable {
        var udpTransport: NIOUDPTransport?
        var beaconPayload: Data?
        var transmitTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var discoveryStream: AsyncStream<RawDiscovery>?
        var discoveryContinuation: AsyncStream<RawDiscovery>.Continuation?
        var boundPort: Int?
        var localAddress: SocketAddress?
        var isShutdown: Bool = false
    }

    private let state: Mutex<AdapterState>

    // MARK: - Initialization

    public init(configuration: WiFiBeaconConfiguration = WiFiBeaconConfiguration()) {
        self.configuration = configuration
        self.state = Mutex(AdapterState())
    }

    // MARK: - TransportAdapter Protocol

    /// A stream of raw discoveries received from WiFi multicast.
    /// Returns the same stream on every call (single consumer pattern).
    /// After shutdown, returns an already-finished stream.
    public var discoveries: AsyncStream<RawDiscovery> {
        state.withLock { s in
            if let existing = s.discoveryStream { return existing }
            // Fix #2: After shutdown, return an immediately-finished stream
            if s.isShutdown {
                let (stream, continuation) = AsyncStream<RawDiscovery>.makeStream()
                continuation.finish()
                return stream
            }
            let (stream, continuation) = AsyncStream<RawDiscovery>.makeStream()
            s.discoveryStream = stream
            s.discoveryContinuation = continuation
            return stream
        }
    }

    /// Starts broadcasting the given beacon payload via UDP multicast.
    /// Also starts the receive loop if not already running.
    /// Throws `TransportAdapterError.mediumNotAvailable` if called after shutdown.
    public func startBeacon(_ payload: Data) async throws {
        guard payload.count <= characteristics.maxBeaconSize else {
            throw TransportAdapterError.beaconTooLarge(
                size: payload.count,
                max: characteristics.maxBeaconSize
            )
        }

        // Ensure the discovery stream exists
        _ = discoveries

        enum StartAction {
            case createTransport
            case restartTransmit
            case rejected
        }

        let action: StartAction = state.withLock { s in
            // Fix #3: Reject after shutdown
            guard !s.isShutdown else { return .rejected }
            s.beaconPayload = payload
            if s.udpTransport == nil {
                return .createTransport
            } else {
                return .restartTransmit
            }
        }

        switch action {
        case .rejected:
            throw TransportAdapterError.mediumNotAvailable

        case .createTransport:
            let config = UDPConfiguration.multicast(port: configuration.port)
            let transport = NIOUDPTransport(configuration: config)

            do {
                try await transport.start()
            } catch {
                throw WiFiBeaconError.bindFailed(underlying: error)
            }

            // Resolve actual bound port (important when configured port is 0)
            let localAddr = await transport.localAddress
            let boundPort: Int = localAddr?.port ?? configuration.port

            do {
                try await transport.joinMulticastGroup(
                    configuration.multicastGroup,
                    on: configuration.networkInterface
                )
            } catch {
                await transport.stop()
                throw WiFiBeaconError.bindFailed(underlying: error)
            }

            let receiveTask = Task { [weak self] in
                guard let self else { return }
                await self.receiveLoop(transport: transport)
            }

            let transmitTask = Task { [weak self] in
                guard let self else { return }
                await self.transmitLoop(transport: transport)
            }

            // Fix #3: Check isShutdown again after async work to handle TOCTOU race
            let shutdownDuringSetup = state.withLock { s -> Bool in
                if s.isShutdown {
                    return true
                }
                s.udpTransport = transport
                s.receiveTask = receiveTask
                s.transmitTask = transmitTask
                s.boundPort = boundPort
                s.localAddress = localAddr
                return false
            }

            if shutdownDuringSetup {
                receiveTask.cancel()
                transmitTask.cancel()
                do {
                    try await transport.leaveMulticastGroup(
                        configuration.multicastGroup,
                        on: configuration.networkInterface
                    )
                } catch {
                    // Best effort
                }
                await transport.stop()
            }

        case .restartTransmit:
            let oldTransmitTask = state.withLock { s -> Task<Void, Never>? in
                let old = s.transmitTask
                s.transmitTask = nil
                return old
            }
            oldTransmitTask?.cancel()

            let transport = state.withLock { $0.udpTransport }
            if let transport {
                let transmitTask = Task { [weak self] in
                    guard let self else { return }
                    await self.transmitLoop(transport: transport)
                }
                state.withLock { $0.transmitTask = transmitTask }
            }
        }
    }

    /// Stops broadcasting beacons but keeps receiving.
    public func stopBeacon() async {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.beaconPayload = nil
            let t = s.transmitTask
            s.transmitTask = nil
            return t
        }
        task?.cancel()
    }

    /// Shuts down the adapter, releasing all resources.
    public func shutdown() async {
        let (transport, receiveTask, transmitTask, continuation) = state.withLock { s in
            let result = (s.udpTransport, s.receiveTask, s.transmitTask, s.discoveryContinuation)
            s.udpTransport = nil
            s.receiveTask = nil
            s.transmitTask = nil
            s.beaconPayload = nil
            s.discoveryContinuation = nil
            s.discoveryStream = nil
            s.localAddress = nil
            s.boundPort = nil
            s.isShutdown = true
            return result
        }

        transmitTask?.cancel()
        receiveTask?.cancel()

        if let transport {
            do {
                try await transport.leaveMulticastGroup(
                    configuration.multicastGroup,
                    on: configuration.networkInterface
                )
            } catch {
                // Best effort
            }
            await transport.stop()
        }

        continuation?.finish()
    }

    // Fix #5: deinit also stops the transport via detached Task
    deinit {
        let (continuation, transmitTask, receiveTask, transport) = state.withLock { s in
            let result = (s.discoveryContinuation, s.transmitTask, s.receiveTask, s.udpTransport)
            s.discoveryContinuation = nil
            s.discoveryStream = nil
            s.udpTransport = nil
            s.isShutdown = true
            return result
        }
        transmitTask?.cancel()
        receiveTask?.cancel()
        continuation?.finish()
        if let transport {
            Task { await transport.stop() }
        }
    }

    // MARK: - Private Methods

    private func receiveLoop(transport: NIOUDPTransport) async {
        for await datagram in transport.incomingDatagrams {
            guard !Task.isCancelled else { break }

            // Fix #1: Filter self-beacons when loopback is disabled.
            // NIOUDPTransport always sets IP_MULTICAST_LOOP=1, so we filter here.
            if !configuration.loopback {
                let localAddr = state.withLock { $0.localAddress }
                if let localAddr, isSameHost(datagram.remoteAddress, localAddr) {
                    continue
                }
            }

            guard let frame = WiFiBeaconFrame.decode(from: datagram.data) else {
                continue
            }

            guard let sourceAddress = makeOpaqueAddress(from: datagram.remoteAddress) else {
                continue
            }

            let discovery = RawDiscovery(
                payload: frame.payload,
                sourceAddress: sourceAddress,
                timestamp: .now,
                rssi: nil,
                mediumID: mediumID,
                physicalFingerprint: nil
            )

            state.withLock { _ = $0.discoveryContinuation?.yield(discovery) }
        }
    }

    private func transmitLoop(transport: NIOUDPTransport) async {
        while !Task.isCancelled {
            let (payload, port) = state.withLock { ($0.beaconPayload, $0.boundPort) }
            guard let payload else { break }
            let targetPort = port ?? configuration.port

            let frame = WiFiBeaconFrame(payload: payload)
            let encoded = frame.encode()

            do {
                try await transport.sendMulticast(
                    encoded,
                    to: configuration.multicastGroup,
                    port: targetPort
                )
            } catch {
                // Transient network errors should not kill the loop
            }

            do {
                try await Task.sleep(for: configuration.transmitInterval)
            } catch {
                break  // Cancelled
            }
        }
    }

    /// Compares two SocketAddresses by IP only (ignoring port).
    private func isSameHost(_ a: SocketAddress, _ b: SocketAddress) -> Bool {
        switch (a, b) {
        case (.v4(let addrA), .v4(let addrB)):
            var sinA = addrA.address
            var sinB = addrB.address
            return withUnsafeBytes(of: &sinA.sin_addr) { bytesA in
                withUnsafeBytes(of: &sinB.sin_addr) { bytesB in
                    bytesA.elementsEqual(bytesB)
                }
            }
        case (.v6(let addrA), .v6(let addrB)):
            var sin6A = addrA.address
            var sin6B = addrB.address
            return withUnsafeBytes(of: &sin6A.sin6_addr) { bytesA in
                withUnsafeBytes(of: &sin6B.sin6_addr) { bytesB in
                    bytesA.elementsEqual(bytesB)
                }
            }
        default:
            return false
        }
    }

    /// Extracts an OpaqueAddress from a NIO SocketAddress.
    private func makeOpaqueAddress(from remote: SocketAddress) -> OpaqueAddress? {
        switch remote {
        case .v4(let addr):
            var raw = Data()
            var sin = addr.address
            withUnsafeBytes(of: &sin.sin_addr) { raw.append(contentsOf: $0) }
            let port = UInt16(bigEndian: sin.sin_port)
            raw.append(UInt8(port >> 8))
            raw.append(UInt8(port & 0xFF))
            return OpaqueAddress(mediumID: mediumID, raw: raw)
        case .v6(let addr):
            var raw = Data()
            var sin6 = addr.address
            withUnsafeBytes(of: &sin6.sin6_addr) { raw.append(contentsOf: $0) }
            let port = UInt16(bigEndian: sin6.sin6_port)
            raw.append(UInt8(port >> 8))
            raw.append(UInt8(port & 0xFF))
            return OpaqueAddress(mediumID: mediumID, raw: raw)
        default:
            return nil
        }
    }
}
