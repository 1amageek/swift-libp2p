/// KademliaShutdownTests - Shutdown lifecycle tests for KademliaService.

import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

@Suite("KademliaService Shutdown Tests")
struct KademliaShutdownTests {

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service = KademliaService(localPeerID: peer)
        let events = service.events

        let consumeTask = Task {
            var count = 0
            for await _ in events { count += 1 }
            return count
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch {}

        try await service.shutdown()

        let count = await consumeTask.value
        // .stopped event may be yielded before finish
        #expect(count <= 1)
    }

    @Test("Shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIsIdempotent() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service = KademliaService(localPeerID: peer)
        try await service.shutdown()
        try await service.shutdown()
        try await service.shutdown()
    }
}
