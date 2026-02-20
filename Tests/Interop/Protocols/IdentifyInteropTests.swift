import Foundation
import NIOCore
import Testing
@testable import P2PCore
@testable import P2PIdentify
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PTransportQUIC

@Suite("Identify Interop Tests", .serialized)
struct IdentifyInteropTests {
    @Test("Identify go-libp2p over QUIC", .timeLimit(.minutes(2)))
    func identifyGoLibp2p() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { stopGoHarness(harness) }

        let info = try await fetchIdentifyInfo(address: harness.nodeInfo.address, preparePushHandler: false)
        #expect(info.protocolVersion != nil)
        #expect(info.publicKey != nil)
        #expect(info.protocols.isEmpty == false)
    }

    @Test("Identify rust-libp2p over QUIC", .timeLimit(.minutes(2)))
    func identifyRustLibp2p() async throws {
        let harness = try await RustLibp2pHarness.start()
        defer { stopRustHarness(harness) }

        let info = try await fetchIdentifyInfo(address: harness.nodeInfo.address, preparePushHandler: true)
        #expect(info.protocolVersion != nil)
        #expect(info.publicKey != nil)
        #expect(info.protocols.isEmpty == false)
    }

    private func fetchIdentifyInfo(
        address: String,
        preparePushHandler: Bool
    ) async throws -> IdentifyInfo {
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()
        let connection = try await transport.dialSecured(
            Multiaddr(address),
            localKeyPair: keyPair
        )
        defer { closeConnection(connection) }

        let pushTask: Task<Void, Never>?
        if preparePushHandler {
            pushTask = Task {
                do {
                    let pushStream = try await connection.acceptStream()
                    let _ = try await MultistreamSelect.handle(
                        supported: [LibP2PProtocol.identifyPush, LibP2PProtocol.identify],
                        read: { Data(buffer: try await pushStream.read()) },
                        write: { data in
                            try await pushStream.write(ByteBuffer(bytes: data))
                        }
                    )
                    let _ = try await pushStream.read()
                    try await pushStream.close()
                } catch {
                }
            }
        } else {
            pushTask = nil
        }
        defer { pushTask?.cancel() }

        let stream = try await connection.newStream()
        defer { closeStream(stream) }

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.identify],
            read: { Data(buffer: try await stream.read()) },
            write: { data in
                try await stream.write(ByteBuffer(bytes: data))
            }
        )
        #expect(negotiationResult.protocolID == LibP2PProtocol.identify)

        let bytes: Data
        if negotiationResult.remainder.isEmpty {
            let data = try await stream.read()
            bytes = Data(buffer: data)
        } else {
            bytes = negotiationResult.remainder
        }

        let (_, prefixBytes) = try Varint.decode(bytes)
        let protobufData = bytes.dropFirst(prefixBytes)
        return try IdentifyProtobuf.decode(Data(protobufData))
    }
}

private func stopGoHarness(_ harness: GoLibp2pHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
        }
    }
}

private func stopRustHarness(_ harness: RustLibp2pHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
        }
    }
}

private func closeStream(_ stream: MuxedStream) {
    Task {
        do {
            try await stream.close()
        } catch {
        }
    }
}

private func closeConnection(_ connection: any MuxedConnection) {
    Task {
        do {
            try await connection.close()
        } catch {
        }
    }
}
