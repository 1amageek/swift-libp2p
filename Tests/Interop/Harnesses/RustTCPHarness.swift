/// RustTCPHarness
///
/// Manages a rust-libp2p Docker container with TCP + Noise for interoperability testing

import Foundation

/// Harness for rust-libp2p TCP + Noise node
public final class RustTCPHarness: Sendable {
    public struct NodeInfo: Sendable {
        public let address: String
        public let peerID: String
        public let transport: String
        public let security: String
        public let muxer: String
    }

    private let containerName: String
    private let port: UInt16
    private let leaseID: UUID
    public let nodeInfo: NodeInfo

    private init(containerName: String, port: UInt16, leaseID: UUID, nodeInfo: NodeInfo) {
        self.containerName = containerName
        self.port = port
        self.leaseID = leaseID
        self.nodeInfo = nodeInfo
    }

    /// Starts a rust-libp2p TCP + Noise test node in Docker
    /// - Parameters:
    ///   - port: Port to expose (0 for random)
    ///   - dockerfile: Dockerfile to use (default: Dockerfiles/Dockerfile.tcp.rust)
    ///   - imageName: Docker image name (default: rust-libp2p-tcp-test)
    /// - Returns: A harness managing the container
    public static func start(
        port: UInt16 = 0,
        dockerfile: String = "Dockerfiles/Dockerfile.tcp.rust",
        imageName: String = "rust-libp2p-tcp-test"
    ) async throws -> RustTCPHarness {
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
            print("[RustTCPHarness] Building Docker image \(imageName)...")
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

            let buildPipe = Pipe()
            buildProcess.standardOutput = buildPipe
            buildProcess.standardError = buildPipe

            try runProcessWithTimeout(buildProcess)

            guard buildProcess.terminationStatus == 0 else {
                let output = String(data: buildPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw RustTCPHarnessError.dockerBuildFailed(output)
            }
            print("[RustTCPHarness] Docker image built successfully")
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

        // Start container (TCP uses tcp port mapping)
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
            throw RustTCPHarnessError.dockerRunFailed
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

            // Look for "Listen: " line
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") }) {

                // Extract peer ID from the line
                if let peerIdMatch = listenLine.range(of: "12D3KooW[a-zA-Z0-9]+", options: .regularExpression) {
                    let peerID = String(listenLine[peerIdMatch])

                    // Build TCP address with actual exposed port
                    let address = "/ip4/127.0.0.1/tcp/\(actualPort)/p2p/\(peerID)"

                    nodeInfo = NodeInfo(
                        address: address,
                        peerID: peerID,
                        transport: "tcp",
                        security: "noise",
                        muxer: "yamux"
                    )
                    print("[RustTCPHarness] rust-libp2p TCP node ready: \(address)")
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

            throw RustTCPHarnessError.nodeNotReady
        }

        shouldReleaseLease = false
        return RustTCPHarness(containerName: containerName, port: actualPort, leaseID: leaseID, nodeInfo: info)
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

public enum RustTCPHarnessError: Error {
    case dockerBuildFailed(String)
    case dockerRunFailed
    case nodeNotReady
}
