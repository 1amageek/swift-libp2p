/// GoLibp2pHarness
///
/// Manages a go-libp2p Docker container for interoperability testing

import Foundation

public final class GoLibp2pHarness: Sendable {
    public struct NodeInfo: Sendable {
        public let address: String
        public let peerID: String
    }

    private let containerName: String
    private let port: UInt16
    public let nodeInfo: NodeInfo

    private init(containerName: String, port: UInt16, nodeInfo: NodeInfo) {
        self.containerName = containerName
        self.port = port
        self.nodeInfo = nodeInfo
    }

    /// Starts a go-libp2p test node in Docker
    /// - Parameter port: Port to expose (0 for random)
    /// - Returns: A harness managing the container
    public static func start(port: UInt16 = 0) async throws -> GoLibp2pHarness {
        let actualPort = port == 0 ? UInt16.random(in: 10000..<60000) : port
        let containerName = "go-libp2p-test-\(actualPort)"

        // Check if Docker image exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["docker", "images", "-q", "go-libp2p-test"]

        let checkPipe = Pipe()
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = Pipe()

        try checkProcess.run()
        checkProcess.waitUntilExit()

        let imageExists = checkPipe.fileHandleForReading.readDataToEndOfFile().count > 0

        // Build Docker image only if it doesn't exist
        if !imageExists {
            let buildProcess = Process()
            buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            buildProcess.arguments = [
                "docker", "build",
                "-t", "go-libp2p-test",
                "-f", "Dockerfiles/Dockerfile.go",
                "."
            ]
            // Go up from Harnesses/ to Interop/
            buildProcess.currentDirectoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Harnesses/
                .deletingLastPathComponent()  // Interop/

            try buildProcess.run()
            buildProcess.waitUntilExit()

            guard buildProcess.terminationStatus == 0 else {
                throw TestHarnessError.dockerBuildFailed
            }
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
            "-p", "\(actualPort):4001/udp",
            "-e", "LISTEN_PORT=4001",
            "go-libp2p-test"
        ]

        try runProcess.run()
        runProcess.waitUntilExit()

        guard runProcess.terminationStatus == 0 else {
            throw TestHarnessError.dockerRunFailed
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

            try logsProcess.run()
            logsProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Look for "Listen: " line
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") }) {

                // Extract multiaddr
                let parts = listenLine.components(separatedBy: "Listen: ")
                if parts.count >= 2 {
                    let multiaddr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

                    // Extract peer ID from multiaddr
                    if let peerIDComponent = multiaddr.components(separatedBy: "/p2p/").last {
                        let peerID = peerIDComponent.trimmingCharacters(in: .whitespacesAndNewlines)

                        // Build address with actual exposed port
                        let address = "/ip4/127.0.0.1/udp/\(actualPort)/quic-v1/p2p/\(peerID)"

                        nodeInfo = NodeInfo(address: address, peerID: peerID)
                        print("go-libp2p node ready: \(address)")
                        break
                    }
                }
            }

            attempts += 1
        }

        guard let info = nodeInfo else {
            // Cleanup on failure
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            stopProcess.arguments = ["docker", "stop", containerName]
            try? stopProcess.run()
            stopProcess.waitUntilExit()

            throw TestHarnessError.nodeNotReady
        }

        return GoLibp2pHarness(containerName: containerName, port: actualPort, nodeInfo: info)
    }

    /// Stops the container
    public func stop() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "stop", containerName]

        try process.run()
        process.waitUntilExit()
    }

    deinit {
        // Best effort cleanup
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "stop", containerName]
        try? process.run()
        process.waitUntilExit()
    }
}

public enum TestHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
}
