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

    private static func runDockerCommand(
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + arguments
        process.currentDirectoryURL = currentDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try runProcessWithTimeout(process)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
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
        let interopDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Harnesses/
            .deletingLastPathComponent()  // Interop/

        // Check if Docker image exists
        let imageCheck = try runDockerCommand(["images", "-q", imageName])
        let imageExists = !imageCheck.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Build Docker image only if it doesn't exist
        if !imageExists {
            let buildResult = try runDockerCommand(
                [
                    "build",
                "-t", imageName,
                "-f", dockerfile,
                "."
                ],
                currentDirectory: interopDirectoryURL
            )

            guard buildResult.status == 0 else {
                throw WSSHarnessError.dockerBuildFailed
            }
        }

        // Remove existing container if any
        do {
            _ = try runDockerCommand(["rm", "-f", containerName])
        } catch {
            // Best effort cleanup only.
        }

        // Start container (WSS uses tcp port mapping)
        let runResult = try runDockerCommand([
            "run",
            "--rm",
            "-d",
            "--name", containerName,
        ] + interopHarnessRunLabelArguments() + [
            "-p", "\(actualPort):4001/tcp",
            "-e", "LISTEN_PORT=4001",
            imageName
        ])

        guard runResult.status == 0 else {
            throw WSSHarnessError.dockerRunFailed
        }

        // Wait for node to be ready and get peer ID
        var attempts = 0
        var nodeInfo: NodeInfo?

        while attempts < 120 {
            try await Task.sleep(for: .milliseconds(500))

            let inspectResult = try runDockerCommand([
                "inspect",
                "-f",
                "{{.State.Running}} {{.State.ExitCode}}",
                containerName,
            ])

            guard inspectResult.status == 0 else {
                throw WSSHarnessError.nodeExited(inspectResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let inspectOutput = inspectResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if inspectOutput.hasPrefix("false") {
                let logsResult = try runDockerCommand(["logs", containerName])
                let logs = logsResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = logs.isEmpty ? inspectOutput : logs
                throw WSSHarnessError.nodeExited(message)
            }

            let logsResult = try runDockerCommand(["logs", containerName])
            let output = logsResult.output

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
            discardProcessOutput(stopProcess)
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
            discardProcessOutput(stopProcess)
            do {
                try runProcessWithTimeout(stopProcess)
            } catch {
                // Best effort cleanup only.
            }
            throw WSSHarnessError.certificateReadFailed
        }

        // Give the WSS listener a short grace period after the first Listen log.
        // Some go-libp2p websocket listeners emit the address before the accept
        // loop is consistently ready under container cold-start pressure.
        try await Task.sleep(for: .milliseconds(300))

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
        let result = try runDockerCommand(["exec", containerName, "cat", filePath])

        guard result.status == 0 else {
            throw WSSHarnessError.certificateReadFailed
        }

        let pem = result.output
        guard pem.contains("BEGIN CERTIFICATE"),
              pem.contains("END CERTIFICATE") else {
            throw WSSHarnessError.certificateReadFailed
        }

        return pem
    }

    /// Stops the container
    public func stop() async throws {
        do {
            _ = try Self.runDockerCommand(["rm", "-f", containerName])
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
        do {
            _ = try Self.runDockerCommand(["rm", "-f", containerName])
        } catch {
            // Best effort cleanup only.
        }
    }
}

public enum WSSHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
    case nodeExited(String)
    case certificateReadFailed
}
