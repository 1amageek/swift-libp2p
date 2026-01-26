/// MplexMuxerTests - Tests for MplexMuxer
import Foundation
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PMuxMplex

@Suite("MplexMuxer Tests", .serialized)
struct MplexMuxerTests {

    // MARK: - Test Helpers

    func createMockConnection() -> MockSecuredConnection {
        MockSecuredConnection()
    }

    // MARK: - Protocol ID Tests

    @Test("Protocol ID is correct")
    func protocolIDIsCorrect() async throws {
        let muxer = MplexMuxer()
        #expect(muxer.protocolID == "/mplex/6.7.0")
    }

    // MARK: - Multiplex Tests

    @Test("Multiplex creates MplexConnection")
    func multiplexCreatesConnection() async throws {
        let muxer = MplexMuxer()
        let mock = createMockConnection()

        let connection = try await muxer.multiplex(mock, isInitiator: true)

        #expect(connection is MplexConnection)
        #expect(connection.localPeer == mock.localPeer)
        #expect(connection.remotePeer == mock.remotePeer)

        try await connection.close()
    }

    @Test("Multiplex starts connection")
    func multiplexStartsConnection() async throws {
        let muxer = MplexMuxer()
        let mock = createMockConnection()

        let connection = try await muxer.multiplex(mock, isInitiator: true)

        // Connection should be started - newStream should work
        let stream = try await connection.newStream()
        #expect(stream.id == 1)

        try await connection.close()
    }

    @Test("Multiplex passes isInitiator correctly")
    func multiplexPassesIsInitiator() async throws {
        let muxer = MplexMuxer()

        // Test as initiator
        let mockInitiator = createMockConnection()
        let initiatorConnection = try await muxer.multiplex(mockInitiator, isInitiator: true)
        let initiatorStream = try await initiatorConnection.newStream()
        #expect(initiatorStream.id % 2 == 1) // Odd ID for initiator

        // Test as responder
        let mockResponder = createMockConnection()
        let responderConnection = try await muxer.multiplex(mockResponder, isInitiator: false)
        let responderStream = try await responderConnection.newStream()
        #expect(responderStream.id % 2 == 0) // Even ID for responder

        try await initiatorConnection.close()
        try await responderConnection.close()
    }

    @Test("Multiplex passes configuration")
    func multiplexPassesConfiguration() async throws {
        let config = MplexConfiguration(maxConcurrentStreams: 5)
        let muxer = MplexMuxer(configuration: config)
        let mock = createMockConnection()

        let connection = try await muxer.multiplex(mock, isInitiator: true)

        // Create streams up to limit
        for _ in 0..<5 {
            _ = try await connection.newStream()
        }

        // Verify connection works with the custom configuration
        #expect(connection.localPeer == mock.localPeer)

        try await connection.close()
    }
}
