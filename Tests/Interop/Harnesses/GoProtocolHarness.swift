/// GoProtocolHarness
///
/// Manages go-libp2p Docker containers for protocol-level interoperability testing.
/// Supports GossipSub, Kademlia, and Circuit Relay protocols.

import Foundation

/// Harness for go-libp2p protocol nodes
public final class GoProtocolHarness: Sendable {
    public struct NodeInfo: Sendable {
        public let address: String
        public let peerID: String
        public let protocolID: String
    }

    private let containerName: String
    private let port: UInt16
    private let leaseID: UUID
    public let nodeInfo: NodeInfo

    /// Container stdin pipe for sending commands
    private let stdinPipe: Pipe?

    private init(containerName: String, port: UInt16, leaseID: UUID, nodeInfo: NodeInfo, stdinPipe: Pipe?) {
        self.containerName = containerName
        self.port = port
        self.leaseID = leaseID
        self.nodeInfo = nodeInfo
        self.stdinPipe = stdinPipe
    }

    /// Protocol configuration
    public enum ProtocolType: Sendable {
        case gossipsub(defaultTopic: String?)
        case kademlia(mode: String)
        case relay(mode: String)

        var dockerfile: String {
            switch self {
            case .gossipsub:
                return "Dockerfiles/Dockerfile.gossipsub.go"
            case .kademlia:
                return "Dockerfiles/Dockerfile.kad.go"
            case .relay:
                return "Dockerfiles/Dockerfile.relay.go"
            }
        }

        var imageName: String {
            switch self {
            case .gossipsub:
                return "go-libp2p-gossipsub-test"
            case .kademlia:
                return "go-libp2p-kad-test"
            case .relay:
                return "go-libp2p-relay-test"
            }
        }

        var protocolName: String {
            switch self {
            case .gossipsub:
                return "/meshsub/1.1.0"
            case .kademlia:
                return "/ipfs/kad/1.0.0"
            case .relay:
                return "/libp2p/circuit/relay/0.2.0/hop"
            }
        }

        var envVars: [String] {
            switch self {
            case .gossipsub(let defaultTopic):
                if let topic = defaultTopic {
                    return ["-e", "DEFAULT_TOPIC=\(topic)"]
                }
                return []
            case .kademlia(let mode):
                return ["-e", "DHT_MODE=\(mode)"]
            case .relay(let mode):
                return ["-e", "RELAY_MODE=\(mode)"]
            }
        }
    }

    /// Starts a go-libp2p protocol test node in Docker
    public static func start(
        protocol protocolType: ProtocolType,
        port: UInt16 = 0
    ) async throws -> GoProtocolHarness {
        let leaseID = await acquireInteropHarnessLease()
        var shouldReleaseLease = true

        defer {
            if shouldReleaseLease {
                Task { await releaseInteropHarnessLease(leaseID) }
            }
        }

        let actualPort = port == 0 ? UInt16.random(in: 10000..<60000) : port
        let containerName = "\(protocolType.imageName)-\(actualPort)"

        // Check if Docker image exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["docker", "images", "-q", protocolType.imageName]

        let checkPipe = Pipe()
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = Pipe()

        try runProcessWithTimeout(checkProcess)

        let imageExists = checkPipe.fileHandleForReading.readDataToEndOfFile().count > 0

        // Build Docker image only if it doesn't exist
        if !imageExists {
            let buildProcess = Process()
            buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            buildProcess.arguments = [
                "docker", "build",
                "-t", protocolType.imageName,
                "-f", protocolType.dockerfile,
                "."
            ]
            buildProcess.currentDirectoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Harnesses/
                .deletingLastPathComponent()  // Interop/

            try runProcessWithTimeout(buildProcess)

            guard buildProcess.terminationStatus == 0 else {
                throw ProtocolHarnessError.dockerBuildFailed
            }
        }

        // Remove existing container if any
        let rmProcess = Process()
        rmProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        rmProcess.arguments = ["docker", "rm", "-f", containerName]
        do {
            try runProcessWithTimeout(rmProcess)
        } catch {
            // Best effort cleanup only.
        }

        // Build run arguments
        var runArgs = [
            "docker", "run",
            "--rm",
            "-d",
            "--name", containerName,
            "-p", "\(actualPort):4001/udp",
            "-e", "LISTEN_PORT=4001",
        ]
        runArgs.append(contentsOf: protocolType.envVars)
        runArgs.append(protocolType.imageName)

        // Start container
        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        runProcess.arguments = runArgs

        try runProcessWithTimeout(runProcess)

        guard runProcess.terminationStatus == 0 else {
            throw ProtocolHarnessError.dockerRunFailed
        }

        // Wait for node to be ready
        var attempts = 0
        var nodeInfo: NodeInfo?

        while attempts < 120 {
            try await Task.sleep(for: .milliseconds(500))

            let logsProcess = Process()
            logsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            logsProcess.arguments = ["docker", "logs", containerName]

            let pipe = Pipe()
            logsProcess.standardOutput = pipe
            logsProcess.standardError = pipe

            try runProcessWithTimeout(logsProcess)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") }) {

                if let peerIdMatch = listenLine.range(of: "12D3KooW[a-zA-Z0-9]+", options: .regularExpression) {
                    let peerID = String(listenLine[peerIdMatch])
                    let address = "/ip4/127.0.0.1/udp/\(actualPort)/quic-v1/p2p/\(peerID)"

                    nodeInfo = NodeInfo(
                        address: address,
                        peerID: peerID,
                        protocolID: protocolType.protocolName
                    )
                    print("\(protocolType.imageName) node ready: \(address)")
                    break
                }
            }

            attempts += 1
        }

        guard let info = nodeInfo else {
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            stopProcess.arguments = ["docker", "stop", containerName]
            do {
                try runProcessWithTimeout(stopProcess)
            } catch {
                // Best effort cleanup only.
            }

            throw ProtocolHarnessError.nodeNotReady
        }

        shouldReleaseLease = false
        return GoProtocolHarness(
            containerName: containerName,
            port: actualPort,
            leaseID: leaseID,
            nodeInfo: info,
            stdinPipe: nil
        )
    }

    /// Sends a command to the container (for interactive protocols like GossipSub)
    public func sendCommand(_ command: String) async throws {
        let execProcess = Process()
        execProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        execProcess.arguments = ["docker", "exec", "-i", containerName, "sh", "-c", "echo '\(command)'"]

        try runProcessWithTimeout(execProcess)
    }

    /// Gets container logs
    public func getLogs() async throws -> String {
        let logsProcess = Process()
        logsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        logsProcess.arguments = ["docker", "logs", containerName]

        let pipe = Pipe()
        logsProcess.standardOutput = pipe
        logsProcess.standardError = pipe

        try runProcessWithTimeout(logsProcess)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stops the container
    public func stop() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "stop", containerName]

        do {
            try runProcessWithTimeout(process)
        } catch {
            await releaseInteropHarnessLease(leaseID)
            throw error
        }
        await releaseInteropHarnessLease(leaseID)
    }

    deinit {
        let leaseID = self.leaseID
        Task {
            await releaseInteropHarnessLease(leaseID)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "stop", containerName]
        do {
            try process.run()
        } catch {
            // Best effort cleanup only.
        }
    }
}

public enum ProtocolHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
    case commandFailed(String)
}
