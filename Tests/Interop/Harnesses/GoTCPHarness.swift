/// GoTCPHarness
///
/// Manages a go-libp2p Docker container with TCP + Noise for interoperability testing

import Foundation

private actor GoTCPHarnessImageBuildCache {
    static let shared = GoTCPHarnessImageBuildCache()

    private var rebuiltImages: Set<String> = []

    /// Force one rebuild per image per test process to avoid stale local images.
    func shouldRebuildImage(named imageName: String) -> Bool {
        if rebuiltImages.contains(imageName) {
            return false
        }
        rebuiltImages.insert(imageName)
        return true
    }
}

/// Harness for go-libp2p TCP + Noise node
public final class GoTCPHarness: Sendable {
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

    /// Starts a go-libp2p TCP + Noise test node in Docker
    /// - Parameters:
    ///   - port: Port to expose (0 for random)
    ///   - dockerfile: Dockerfile to use (default: Dockerfile.tcp.go)
    ///   - imageName: Docker image name (default: go-libp2p-tcp-test)
    /// - Returns: A harness managing the container
    public static func start(
        port: UInt16 = 0,
        dockerfile: String = "Dockerfiles/Dockerfile.tcp.go",
        imageName: String = "go-libp2p-tcp-test"
    ) async throws -> GoTCPHarness {
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

        // Build Docker image if missing, or once per process to avoid stale local images.
        let shouldRebuildCachedImage = await GoTCPHarnessImageBuildCache.shared.shouldRebuildImage(named: imageName)
        if !imageExists || shouldRebuildCachedImage {
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
                print("[GoTCPHarness] docker build failed for \(imageName):\n\(buildResult.output)")
                throw TCPHarnessError.dockerBuildFailed
            }
        }

        // Remove existing container if any
        do {
            _ = try runDockerCommand(["rm", "-f", containerName])
        } catch {
            // Best effort cleanup only.
        }

        // Start container (TCP uses tcp port mapping)
        let runResult = try runDockerCommand([
            "run",
            "-d",
            "--name", containerName,
            "-p", "\(actualPort):4001/tcp",
            "-e", "LISTEN_PORT=4001",
            imageName
        ])

        guard runResult.status == 0 else {
            print("[GoTCPHarness] docker run failed for \(containerName):\n\(runResult.output)")
            throw TCPHarnessError.dockerRunFailed
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
                throw TCPHarnessError.nodeExited(inspectResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let inspectOutput = inspectResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if inspectOutput.hasPrefix("false") {
                let logsResult = try runDockerCommand(["logs", containerName])
                let logs = logsResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = logs.isEmpty ? inspectOutput : logs
                throw TCPHarnessError.nodeExited(message)
            }

            let logsResult = try runDockerCommand(["logs", containerName])
            let output = logsResult.output

            // Look for "Listen: " line
            if let listenLine = output.components(separatedBy: "\n")
                .first(where: { $0.contains("Listen: ") }) {

                // Extract peer ID from the line
                if let peerIdMatch = listenLine.range(
                    of: "(12D3KooW[a-zA-Z0-9]+|Qm[a-zA-Z0-9]+)",
                    options: .regularExpression
                ) {
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
                    print("go-libp2p TCP node ready: \(address)")
                    break
                }
            }

            attempts += 1
        }

        guard let info = nodeInfo else {
            let logsResult = try runDockerCommand(["logs", containerName])
            let logs = logsResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !logs.isEmpty {
                print("[GoTCPHarness] node not ready. Last logs from \(containerName):\n\(logs)")
            }

            // Cleanup on failure
            do {
                _ = try runDockerCommand(["rm", "-f", containerName])
            } catch {
                // Best effort cleanup only.
            }

            throw TCPHarnessError.nodeNotReady
        }

        shouldReleaseLease = false
        return GoTCPHarness(containerName: containerName, port: actualPort, leaseID: leaseID, nodeInfo: info)
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

    /// Reads current container logs for diagnostics.
    public func logs() async -> String {
        do {
            let result = try Self.runDockerCommand(["logs", containerName])
            return result.output
        } catch {
            return "Failed to read logs: \(error)"
        }
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

public enum TCPHarnessError: Error {
    case dockerBuildFailed
    case dockerRunFailed
    case nodeNotReady
    case nodeExited(String)
}
