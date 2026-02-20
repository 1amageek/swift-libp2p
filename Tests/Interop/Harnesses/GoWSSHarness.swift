/// GoWSSHarness
///
/// Manages a go-libp2p Docker container with WSS (TLS + WebSocket) + Noise for interoperability testing

import Foundation

/// Harness for go-libp2p WSS + Noise node
public final class GoWSSHarness: Sendable {
    public struct NodeInfo: Sendable {
        public let address: String
        public let peerID: String
        public let transport: String
        public let security: String
        public let muxer: String
        public let serverHostname: String
    }

    private let containerName: String
    private let port: UInt16
    private let leaseID: UUID
    public let nodeInfo: NodeInfo
    public let serverCertificatePEM: String

    private init(
        containerName: String,
        port: UInt16,
        leaseID: UUID,
        nodeInfo: NodeInfo,
        serverCertificatePEM: String
    ) {
        self.containerName = containerName
        self.port = port
        self.leaseID = leaseID
        self.nodeInfo = nodeInfo
        self.serverCertificatePEM = serverCertificatePEM
    }

    /// Starts a go-libp2p WSS + Noise test node in Docker
    /// - Parameters:
    ///   - port: Port to expose (0 for random)
    ///   - dockerfile: Dockerfile to use (default: Dockerfile.wss.go)
    ///   - imageName: Docker image name (default: go-libp2p-wss-test)
    /// - Returns: A harness managing the container
    public static func start(
        port: UInt16 = 0,
        dockerfile: String = "Dockerfiles/Dockerfile.wss.go",
        imageName: String = "go-libp2p-wss-test"
    ) async throws -> GoWSSHarness {
        let leaseID = await acquireInteropHarnessLease()
        var shouldReleaseLease = true

        defer {
            if shouldReleaseLease {
                Task { await releaseInteropHarnessLease(leaseID) }
            }
        }

        let actualPort = port == 0 ? UInt16.random(in: 10000..<60000) : port
        let containerName = "\(imageName)-\(actualPort)"

        // Check if Docker image exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["docker", "images", "-q", imageName]

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
                "-t", imageName,
                "-f", dockerfile,
                "."
            ]
            // Go up from Harnesses/ to Interop/
            buildProcess.currentDirectoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Harnesses/
                .deletingLastPathComponent()  // Interop/

            try runProcessWithTimeout(buildProcess)

            guard buildProcess.terminationStatus == 0 else {
                throw WSSHarnessError.dockerBuildFailed
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

        // Start container (WSS uses tcp port mapping)
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

        try runProcessWithTimeout(runProcess)

        guard runProcess.terminationStatus == 0 else {
            throw WSSHarnessError.dockerRunFailed
        }

        // Wait for node to be ready and get peer ID
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

            // Look for "Listen: " line with /wss or /tls/ws (go-libp2p outputs /tls/ws format)
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") && ($0.contains("/wss") || $0.contains("/tls/ws")) }) {

                // Extract peer ID from the line
                if let peerIdMatch = listenLine.range(of: "12D3KooW[a-zA-Z0-9]+", options: .regularExpression) {
                    let peerID = String(listenLine[peerIdMatch])

                    // Build WSS address with actual exposed port
                    // Use dns4 localhost so client can perform hostname verification.
                    let address = "/dns4/localhost/tcp/\(actualPort)/wss/p2p/\(peerID)"

                    nodeInfo = NodeInfo(
                        address: address,
                        peerID: peerID,
                        transport: "wss",
                        security: "noise",
                        muxer: "yamux",
                        serverHostname: "localhost"
                    )
                    print("go-libp2p WSS node ready: \(address)")
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
            do {
                try runProcessWithTimeout(stopProcess)
            } catch {
                // Best effort cleanup only.
            }

            throw WSSHarnessError.nodeNotReady
        }

        let certificatePEM: String
        do {
            certificatePEM = try readContainerFile(containerName: containerName, filePath: "/cert.pem")
        } catch {
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            stopProcess.arguments = ["docker", "stop", containerName]
            do {
                try runProcessWithTimeout(stopProcess)
            } catch {
                // Best effort cleanup only.
            }
            throw WSSHarnessError.certificateReadFailed
        }

        shouldReleaseLease = false
        return GoWSSHarness(
            containerName: containerName,
            port: actualPort,
            leaseID: leaseID,
            nodeInfo: info,
            serverCertificatePEM: certificatePEM
        )
    }

    private static func readContainerFile(containerName: String, filePath: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", containerName, "cat", filePath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try runProcessWithTimeout(process)

        guard process.terminationStatus == 0 else {
            throw WSSHarnessError.certificateReadFailed
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let pem = String(data: data, encoding: .utf8),
              pem.contains("BEGIN CERTIFICATE"),
              pem.contains("END CERTIFICATE") else {
            throw WSSHarnessError.certificateReadFailed
        }

        return pem
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

        // Best effort cleanup
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

public enum WSSHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
    case certificateReadFailed
}
