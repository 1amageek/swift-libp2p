/// InteropHarnessProtocol
///
/// Common protocol for libp2p interoperability test harnesses.
/// Each harness manages a Docker container running a libp2p implementation.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor InteropHarnessLeaseManager {
    static let shared = InteropHarnessLeaseManager(maxConcurrentHarnesses: 2)

    private let maxConcurrentHarnesses: Int
    private var activeLeases: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentHarnesses: Int) {
        self.maxConcurrentHarnesses = maxConcurrentHarnesses
    }

    func acquire() async -> UUID {
        while activeLeases.count >= maxConcurrentHarnesses {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        let leaseID = UUID()
        activeLeases.insert(leaseID)
        return leaseID
    }

    func release(_ leaseID: UUID) {
        guard activeLeases.remove(leaseID) != nil else {
            return
        }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}

func acquireInteropHarnessLease() async -> UUID {
    await InteropHarnessLeaseManager.shared.acquire()
}

func releaseInteropHarnessLease(_ leaseID: UUID) async {
    await InteropHarnessLeaseManager.shared.release(leaseID)
}

/// Information about a running libp2p test node
public struct InteropNodeInfo: Sendable {
    /// The multiaddr to connect to (e.g., /ip4/127.0.0.1/udp/4001/quic-v1/p2p/12D3KooW...)
    public let address: String

    /// The PeerID of the node (e.g., 12D3KooW...)
    public let peerID: String

    /// The transport protocol (e.g., "quic-v1", "tcp")
    public let transport: String

    /// The security protocol (e.g., "tls", "noise")
    public let security: String

    /// The muxer protocol if applicable (e.g., "yamux")
    public let muxer: String?

    public init(
        address: String,
        peerID: String,
        transport: String = "quic-v1",
        security: String = "tls",
        muxer: String? = nil
    ) {
        self.address = address
        self.peerID = peerID
        self.transport = transport
        self.security = security
        self.muxer = muxer
    }
}

/// Common errors for test harnesses
public enum InteropHarnessError: Error, Sendable {
    /// Docker is not available or not running
    case dockerNotAvailable

    /// Failed to build Docker image
    case dockerBuildFailed(String)

    /// Failed to start Docker container
    case containerStartFailed(String)

    /// Node did not become ready in time
    case nodeNotReady(String)

    /// Failed to parse node output
    case parseError(String)
}

/// Protocol for libp2p test harnesses
public protocol InteropHarness: Sendable {
    /// The type of node info returned
    associatedtype NodeInfoType: Sendable

    /// Information about the running node
    var nodeInfo: NodeInfoType { get }

    /// Stops the container
    func stop() async throws
}

/// Docker image configuration for harnesses
public struct DockerImageConfig: Sendable {
    /// The image name (e.g., "go-libp2p-test")
    public let imageName: String

    /// The Dockerfile path relative to Tests/Interop/ (e.g., "Dockerfiles/Dockerfile.go")
    public let dockerfile: String

    /// Container port to expose
    public let containerPort: UInt16

    /// Protocol type (udp or tcp)
    public let portProtocol: String

    public init(
        imageName: String,
        dockerfile: String,
        containerPort: UInt16 = 4001,
        portProtocol: String = "udp"
    ) {
        self.imageName = imageName
        self.dockerfile = dockerfile
        self.containerPort = containerPort
        self.portProtocol = portProtocol
    }
}

/// Predefined Docker configurations
public extension DockerImageConfig {
    /// go-libp2p QUIC configuration
    static let goQuic = DockerImageConfig(
        imageName: "go-libp2p-test",
        dockerfile: "Dockerfiles/Dockerfile.go"
    )

    /// go-libp2p TCP + Noise configuration
    static let goTCPNoise = DockerImageConfig(
        imageName: "go-libp2p-tcp-test",
        dockerfile: "Dockerfiles/Dockerfile.tcp.go",
        portProtocol: "tcp"
    )

    /// go-libp2p TCP + Noise + Yamux configuration
    static let goYamux = DockerImageConfig(
        imageName: "go-libp2p-yamux-test",
        dockerfile: "Dockerfiles/Dockerfile.yamux.go",
        portProtocol: "tcp"
    )

    /// go-libp2p GossipSub configuration
    static let goGossipSub = DockerImageConfig(
        imageName: "go-libp2p-gossipsub-test",
        dockerfile: "Dockerfiles/Dockerfile.gossipsub.go"
    )

    /// go-libp2p Kademlia configuration
    static let goKademlia = DockerImageConfig(
        imageName: "go-libp2p-kad-test",
        dockerfile: "Dockerfiles/Dockerfile.kad.go"
    )

    /// go-libp2p Circuit Relay configuration
    static let goRelay = DockerImageConfig(
        imageName: "go-libp2p-relay-test",
        dockerfile: "Dockerfiles/Dockerfile.relay.go"
    )

    /// rust-libp2p QUIC configuration
    static let rustQuic = DockerImageConfig(
        imageName: "rust-libp2p-test",
        dockerfile: "Dockerfiles/Dockerfile.rust"
    )
}

enum InteropProcessError: Error, Sendable {
    case timedOut(command: String, timeoutSeconds: TimeInterval)
}

private let interopProcessTimeoutSeconds: TimeInterval = 15
private let interopProcessPollIntervalSeconds: TimeInterval = 0.05
private let interopProcessTerminateGraceSeconds: TimeInterval = 1

@discardableResult
func runProcessWithTimeout(
    _ process: Process,
    timeoutSeconds: TimeInterval = interopProcessTimeoutSeconds
) throws -> Int32 {
    try process.run()
    try waitForProcessExit(process, timeoutSeconds: timeoutSeconds)
    return process.terminationStatus
}

func waitForProcessExit(
    _ process: Process,
    timeoutSeconds: TimeInterval = interopProcessTimeoutSeconds
) throws {
    let command = processCommandDescription(process)
    let deadline = Date().addingTimeInterval(timeoutSeconds)

    while process.isRunning {
        if Date() >= deadline {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(interopProcessTerminateGraceSeconds)
            while process.isRunning && Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }

            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }

            throw InteropProcessError.timedOut(command: command, timeoutSeconds: timeoutSeconds)
        }

        Thread.sleep(forTimeInterval: interopProcessPollIntervalSeconds)
    }
}

private func processCommandDescription(_ process: Process) -> String {
    let executable = process.executableURL?.path ?? "<unknown>"
    let arguments = process.arguments ?? []
    return ([executable] + arguments).joined(separator: " ")
}
