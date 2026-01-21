/// GoLibp2pHarness - Manages a go-libp2p test node via Docker
///
/// This harness starts a go-libp2p node in a Docker container and exposes
/// its QUIC endpoint for Swift interoperability testing.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - The go-libp2p-test image must be available (see Tests/Interop/Dockerfile)

import Foundation

/// Manages a go-libp2p test node via Docker
public final class GoLibp2pHarness: Sendable {

    // MARK: - Types

    /// Information about the running go-libp2p node
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

    /// Starts a go-libp2p test node and returns the harness
    /// - Parameter port: The UDP port to listen on (0 for random)
    /// - Returns: A harness managing the running node
    public static func start(port: UInt16 = 0) async throws -> GoLibp2pHarness {
        // Check Docker availability
        guard await isDockerAvailable() else {
            throw HarnessError.dockerNotAvailable
        }

        // Build the test image if needed
        try await buildImageIfNeeded()

        // Start the container
        let hostPort = port == 0 ? UInt16.random(in: 10000...60000) : port

        let startResult = try await runCommand(
            "docker", "run", "-d",
            "-p", "\(hostPort):4001/udp",
            "-e", "LISTEN_PORT=4001",
            "go-libp2p-test:latest"
        )

        let containerId = startResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerId.isEmpty else {
            throw HarnessError.containerStartFailed("Empty container ID")
        }

        // Wait for the node to be ready and get its info
        let nodeInfo = try await waitForNodeReady(containerId: containerId, hostPort: hostPort)

        return GoLibp2pHarness(containerId: containerId, nodeInfo: nodeInfo)
    }

    /// Stops and removes the container
    public func stop() async throws {
        _ = try? await Self.runCommand("docker", "stop", containerId)
        _ = try? await Self.runCommand("docker", "rm", "-f", containerId)
    }

    // MARK: - Private Helpers

    /// Checks if Docker is available
    private static func isDockerAvailable() async -> Bool {
        do {
            _ = try await runCommand("docker", "info")
            return true
        } catch {
            return false
        }
    }

    /// Builds the go-libp2p test image if not present
    private static func buildImageIfNeeded() async throws {
        // Check if image exists
        let checkResult = try? await runCommand("docker", "images", "-q", "go-libp2p-test:latest")
        if let result = checkResult, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return // Image exists
        }

        // Build the image
        let dockerfilePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Dockerfile")
            .path

        _ = try await runCommand(
            "docker", "build",
            "-t", "go-libp2p-test:latest",
            "-f", dockerfilePath,
            URL(fileURLWithPath: dockerfilePath).deletingLastPathComponent().path
        )
    }

    /// Waits for the node to be ready and returns its info
    private static func waitForNodeReady(containerId: String, hostPort: UInt16) async throws -> NodeInfo {
        // Wait a bit for the node to start
        try await Task.sleep(for: .seconds(2))

        // Get the logs to find the peer ID and listen address
        let logs = try await runCommand("docker", "logs", containerId)

        // Parse PeerID from logs (format: "PeerID: 12D3KooW...")
        guard let peerIdMatch = logs.range(of: "PeerID: ([a-zA-Z0-9]+)", options: .regularExpression) else {
            throw HarnessError.parseError("Could not find PeerID in logs: \(logs)")
        }

        let peerIdLine = String(logs[peerIdMatch])
        let peerID = String(peerIdLine.dropFirst("PeerID: ".count))

        let address = "/ip4/127.0.0.1/udp/\(hostPort)/quic-v1"

        return NodeInfo(address: address, peerID: peerID)
    }

    /// Runs a command and returns its output
    @discardableResult
    private static func runCommand(_ args: String...) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: HarnessError.containerStartFailed(output))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
