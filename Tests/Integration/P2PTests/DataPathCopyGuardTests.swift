import Foundation
import Testing

@Suite("Data Path Copy Guard Tests")
struct DataPathCopyGuardTests {
    @Test("Runtime-facing payload paths do not add new Data/ByteBuffer bridge copies")
    func payloadPathsAvoidBridgeCopies() throws {
        let root = try packageRoot()
        let scanRoots = [
            "Sources/Runtime",
            "Sources/Integration/P2P/Swarm",
            "Sources/Security",
            "Sources/Mux",
        ]

        let bannedPatterns = [
            "Data(buffer:",
            "ByteBuffer(bytes:",
        ]

        var allowances = allowedOccurrences
        var violations: [String] = []

        for scanRoot in scanRoots {
            let baseURL = root.appendingPathComponent(scanRoot)
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: nil
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }

                let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)

                for (index, line) in lines.enumerated() {
                    let lineNumber = index + 1
                    let lineString = String(line)
                    guard bannedPatterns.contains(where: lineString.contains) else { continue }

                    if consumeAllowance(path: relativePath, line: lineString, allowances: &allowances) {
                        continue
                    }

                    violations.append("\(relativePath):\(lineNumber): \(lineString.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            Disallowed payload-path bridge copies:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        throw GuardError.packageRootNotFound
    }

    private func consumeAllowance(path: String, line: String, allowances: inout [AllowedOccurrence]) -> Bool {
        guard let index = allowances.firstIndex(where: { allowance in
            allowance.path == path && line.contains(allowance.snippet) && allowance.remainingCount > 0
        }) else {
            return false
        }

        allowances[index].remainingCount -= 1
        return true
    }
}

private struct AllowedOccurrence: Sendable {
    let path: String
    let snippet: String
    var remainingCount: Int
    let reason: String
}

private let allowedOccurrences: [AllowedOccurrence] = [
    AllowedOccurrence(
        path: "Sources/Security/Noise/NoiseConnection.swift",
        snippet: "ByteBuffer(bytes: plaintext)",
        remainingCount: 1,
        reason: "CryptoKit ChaChaPoly.open currently returns Data."
    ),
    AllowedOccurrence(
        path: "Sources/Security/Plaintext/PlaintextUpgrader.swift",
        snippet: "Data(buffer: buffer)",
        remainingCount: 1,
        reason: "Plaintext exchange protobuf decode is control-plane only."
    ),
    AllowedOccurrence(
        path: "Sources/Mux/Mplex/MplexFrame.swift",
        snippet: "ByteBuffer(bytes: data)",
        remainingCount: 2,
        reason: "Legacy Data convenience APIs remain isolated in MplexFrame."
    ),
    AllowedOccurrence(
        path: "Sources/Mux/Mplex/MplexFrame.swift",
        snippet: "Data(buffer: buffer)",
        remainingCount: 1,
        reason: "Legacy Data convenience encoder remains isolated in MplexFrame."
    ),
    AllowedOccurrence(
        path: "Sources/Mux/Mplex/MplexFrame.swift",
        snippet: "ByteBuffer(bytes: buffer)",
        remainingCount: 1,
        reason: "Legacy Data convenience decoder remains isolated in MplexFrame."
    ),
]

private enum GuardError: Error {
    case packageRootNotFound
}
