/// RustLibp2pHarness - Manages a rust-libp2p test node via Docker
///
/// This harness starts a rust-libp2p node in a Docker container and exposes
/// its QUIC endpoint for Swift interoperability testing.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - The rust-libp2p-test image must be available (see Tests/Interop/Dockerfile)

import Foundation

/// Manages a rust-libp2p test node via Docker
public final class RustLibp2pHarness: Sendable {

    // MARK: - Types

    /// Information about the running rust-libp2p node
    public struct NodeInfo: Sendable {
        /// The multiaddr to connect to (e.g., /ip4/127.0.0.1/udp/4001/quic-v1)
        public let address: String

        /// The PeerID of the node (e.g., 12D3KooW...)
        public let peerID: String
    }

    /// Errors from the harness
    public enum HarnessError: Error, Sendable {
        case dockerNotAvailable
        case containerStartFailed(String)
        case parseError(String)
    }

    // MARK: - Properties

    /// The Docker container ID
    private let containerId: String

    /// Node information
    public let nodeInfo: NodeInfo

    // MARK: - Initialization

    private init(containerId: String, nodeInfo: NodeInfo) {
        self.containerId = containerId
        self.nodeInfo = nodeInfo
    }

    // MARK: - Lifecycle

    /// Starts a rust-libp2p test node and returns the harness
    /// - Parameter port: The UDP port to listen on (0 for random)
    /// - Returns: A harness managing the running node
    public static func start(port: UInt16 = 0) async throws -> RustLibp2pHarness {
        let hostPort = port == 0 ? UInt16.random(in: 10000...60000) : port
        let containerName = "rust-libp2p-test-\(hostPort)"

        // Build Docker image if needed
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        buildProcess.arguments = [
            "docker", "build",
            "-t", "rust-libp2p-test",
            "-f", "Dockerfile",
            "."
        ]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            throw HarnessError.containerStartFailed("Docker build failed")
        }

        // Remove existing container if any
        let rmProcess = Process()
        rmProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        rmProcess.arguments = ["docker", "rm", "-f", containerName]
        try? rmProcess.run()
        rmProcess.waitUntilExit()

        // Start container
        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        runProcess.arguments = [
            "docker", "run",
            "--rm",
            "-d",
            "--name", containerName,
            "-p", "\(hostPort):4001/udp",
            "-e", "LISTEN_PORT=4001",
            "rust-libp2p-test"
        ]

        try runProcess.run()
        runProcess.waitUntilExit()

        guard runProcess.terminationStatus == 0 else {
            throw HarnessError.containerStartFailed("Docker run failed")
        }

        // Wait for node to be ready and get peer ID
        var attempts = 0
        var nodeInfo: NodeInfo?

        while attempts < 30 {
            try await Task.sleep(for: .milliseconds(500))

            let logsProcess = Process()
            logsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            logsProcess.arguments = ["docker", "logs", containerName]

            let pipe = Pipe()
            logsProcess.standardOutput = pipe
            logsProcess.standardError = pipe

            try logsProcess.run()
            logsProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Look for "Listen: " line
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") }) {

                // Extract peer ID from the line using regex
                if let peerIdMatch = listenLine.range(of: "12D3KooW[a-zA-Z0-9]+", options: .regularExpression) {
                    let peerID = String(listenLine[peerIdMatch])

                    // Build address with actual exposed port
                    let address = "/ip4/127.0.0.1/udp/\(hostPort)/quic-v1/p2p/\(peerID)"

                    nodeInfo = NodeInfo(address: address, peerID: peerID)
                    print("rust-libp2p node ready: \(address)")
                    break
                }
            }

            attempts += 1
        }

        guard let info = nodeInfo else {
            throw HarnessError.parseError("Could not start rust-libp2p node after 30 attempts")
        }

        return RustLibp2pHarness(containerId: containerName, nodeInfo: info)
    }

    /// Stops and removes the container
    public func stop() async throws {
        let stopProcess = Process()
        stopProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stopProcess.arguments = ["docker", "stop", containerId]
        try? stopProcess.run()
        stopProcess.waitUntilExit()

        let rmProcess = Process()
        rmProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        rmProcess.arguments = ["docker", "rm", "-f", containerId]
        try? rmProcess.run()
        rmProcess.waitUntilExit()
    }
}
