/// Quick debug test for isolating server->client data flow
import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
import QUIC

@Suite("Quick Debug")
struct QuickDebugTest {

    @Test("Server write reaches client", .timeLimit(.minutes(1)))
    func serverWriteReachesClient() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server: accept connection, accept stream, write data
        let serverTask = Task { () -> String in
            do {
                for await connection in listener.connections {
                    print("[S] Got connection")
                    let stream = try await connection.acceptStream()
                    print("[S] Got stream, writing...")
                    try await stream.write(Data("FROM_SERVER".utf8))
                    print("[S] Wrote data, closing write...")
                    try await stream.closeWrite()
                    print("[S] Done")
                    return "ok"
                }
                return "no connection"
            } catch {
                print("[S] Error: \(error)")
                return "error: \(error)"
            }
        }

        // Client: connect, open stream, trigger server, read
        print("[C] Connecting...")
        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[C] Connected, opening stream...")

        let clientStream = try await clientConn.newStream()
        print("[C] Stream opened, writing trigger...")

        // Write to trigger server to see the stream
        try await clientStream.write(Data("trigger".utf8))
        print("[C] Trigger sent, reading response...")

        // Read server's response
        let response = try await clientStream.read()
        print("[C] Got response: \(String(data: response, encoding: .utf8) ?? "?")")

        #expect(response == Data("FROM_SERVER".utf8))

        _ = await serverTask.value
        try await listener.close()
    }
}
