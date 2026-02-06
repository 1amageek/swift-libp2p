/// GoWebSocketHarness
///
/// Manages a go-libp2p Docker container with WebSocket + Noise for interoperability testing

import Foundation

/// Harness for go-libp2p WebSocket + Noise node
public final class GoWebSocketHarness: Sendable {
    public struct NodeInfo: Sendable {
        public let address: String
        public let peerID: String
        public let transport: String
        public let security: String
        public let muxer: String
    }

    private let containerName: String
    private let port: UInt16
    public let nodeInfo: NodeInfo

    private init(containerName: String, port: UInt16, nodeInfo: NodeInfo) {
        self.containerName = containerName
        self.port = port
        self.nodeInfo = nodeInfo
    }

    /// Starts a go-libp2p WebSocket + Noise test node in Docker
    /// - Parameters:
    ///   - port: Port to expose (0 for random)
    ///   - dockerfile: Dockerfile to use (default: Dockerfile.ws.go)
    ///   - imageName: Docker image name (default: go-libp2p-ws-test)
    /// - Returns: A harness managing the container
    public static func start(
        port: UInt16 = 0,
        dockerfile: String = "Dockerfiles/Dockerfile.ws.go",
        imageName: String = "go-libp2p-ws-test"
    ) async throws -> GoWebSocketHarness {
        let actualPort = port == 0 ? UInt16.random(in: 10000..<60000) : port
        let containerName = "\(imageName)-\(actualPort)"

        // Check if Docker image exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["docker", "images", "-q", imageName]

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
                "-t", imageName,
                "-f", dockerfile,
                "."
            ]
            // Go up from Harnesses/ to Interop/
            buildProcess.currentDirectoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Harnesses/
                .deletingLastPathComponent()  // Interop/

            try buildProcess.run()
            buildProcess.waitUntilExit()

            guard buildProcess.terminationStatus == 0 else {
                throw WebSocketHarnessError.dockerBuildFailed
            }
        }

        // Remove existing container if any
        let rmProcess = Process()
        rmProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        rmProcess.arguments = ["docker", "rm", "-f", containerName]
        try? rmProcess.run()
        rmProcess.waitUntilExit()

        // Start container (WebSocket uses tcp port mapping)
        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        runProcess.arguments = [
            "docker", "run",
            "--rm",
            "-d",
            "--name", containerName,
            "-p", "\(actualPort):4001/tcp",
            "-e", "LISTEN_PORT=4001",
            imageName
        ]

        try runProcess.run()
        runProcess.waitUntilExit()

        guard runProcess.terminationStatus == 0 else {
            throw WebSocketHarnessError.dockerRunFailed
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

            // Look for "Listen: " line with /ws
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") && $0.contains("/ws") }) {

                // Extract peer ID from the line
                if let peerIdMatch = listenLine.range(of: "12D3KooW[a-zA-Z0-9]+", options: .regularExpression) {
                    let peerID = String(listenLine[peerIdMatch])

                    // Build WebSocket address with actual exposed port
                    let address = "/ip4/127.0.0.1/tcp/\(actualPort)/ws/p2p/\(peerID)"

                    nodeInfo = NodeInfo(
                        address: address,
                        peerID: peerID,
                        transport: "ws",
                        security: "noise",
                        muxer: "yamux"
                    )
                    print("go-libp2p WebSocket node ready: \(address)")
                    break
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

            throw WebSocketHarnessError.nodeNotReady
        }

        return GoWebSocketHarness(containerName: containerName, port: actualPort, nodeInfo: info)
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

public enum WebSocketHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
}
