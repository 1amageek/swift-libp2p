/// RelayClientShutdownTests - Shutdown lifecycle tests for RelayClient.

import Testing
import Foundation
@testable import P2PCircuitRelay
@testable import P2PCore

@Suite("RelayClient Shutdown Tests")
struct RelayClientShutdownTests {

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async throws {
        let client = RelayClient()
        let events = client.events

        let consumeTask = Task {
            var count = 0
            for await _ in events { count += 1 }
            return count
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch {}

        try await client.shutdown()

        let count = await consumeTask.value
        #expect(count == 0)
    }

    @Test("Shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIsIdempotent() async throws {
        let client = RelayClient()
        try await client.shutdown()
        try await client.shutdown()
        try await client.shutdown()
    }
}
