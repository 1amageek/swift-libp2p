import Testing
import Foundation
@testable import P2PNegotiation

@Suite("Multistream-Select Edge Case Tests")
struct NegotiationEdgeCaseTests {

    // MARK: - Decode Edge Cases

    @Test("Decode rejects invalid UTF-8 sequences")
    func decodeInvalidUtf8() throws {
        // Build a varint-length-prefixed message with invalid UTF-8
        let invalidUtf8: [UInt8] = [0x04, 0xFF, 0xFE, 0x0A, 0x0A] // length=4, invalid bytes + newline
        let data = Data(invalidUtf8)
        #expect(throws: NegotiationError.invalidUtf8) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    @Test("Decode rejects message without trailing newline")
    func decodeNoNewline() throws {
        let message: [UInt8] = [0x04, 0x74, 0x65, 0x73, 0x74] // length=4, "test" (no newline)
        let data = Data(message)
        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    @Test("Decode rejects empty message (zero length)")
    func decodeZeroLength() throws {
        let data = Data([0x00]) // varint 0
        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    @Test("Decode rejects message exceeding max size")
    func decodeOversizedMessage() throws {
        // Encode a length that exceeds maxMessageSize (64KB)
        let hugeLength: UInt64 = 70_000
        var data = Data()
        var value = hugeLength
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        // Add enough dummy bytes to reach the declared length
        data.append(Data(repeating: 0x41, count: Int(hugeLength)))

        do {
            _ = try MultistreamSelect.decode(data)
            Issue.record("Expected messageTooLarge error but decode succeeded")
        } catch let error as NegotiationError {
            switch error {
            case .messageTooLarge(let size, let max):
                #expect(size == Int(hugeLength))
                #expect(max == MultistreamSelect.maxMessageSize)
            default:
                Issue.record("Expected messageTooLarge but got \(error)")
            }
        }
    }

    @Test("Decode handles truncated data (length > available)")
    func decodeTruncatedData() throws {
        let data = Data([0x0A, 0x74, 0x65, 0x73, 0x74]) // length=10, only 4 bytes
        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    @Test("Decode correctly returns consumed byte count")
    func decodeConsumedBytes() throws {
        // "test\n" = 5 bytes, varint 0x05 = 1 byte, total consumed = 6
        let encoded = MultistreamSelect.encode("test")
        let extraData = Data([0xDE, 0xAD])
        let combined = encoded + extraData

        let (decoded, consumed) = try MultistreamSelect.decode(combined)
        #expect(decoded == "test")
        #expect(consumed == encoded.count)
        #expect(combined.count - consumed == 2) // extraData preserved
    }

    // MARK: - Coalesced Read Tests

    @Test("Negotiate handles coalesced header+response in single read")
    func negotiateCoalescedRead() async throws {
        // Server sends header + protocol response in one TCP segment
        let headerEncoded = MultistreamSelect.encode(MultistreamSelect.protocolID)
        let protoEncoded = MultistreamSelect.encode("/test/1.0.0")
        let coalescedResponse = headerEncoded + protoEncoded

        var writeCount = 0
        var readCalled = false

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/test/1.0.0"],
            read: {
                if !readCalled {
                    readCalled = true
                    return coalescedResponse
                }
                throw NegotiationError.invalidMessage
            },
            write: { _ in writeCount += 1 }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(writeCount == 2) // header + protocol
    }

    @Test("Handle processes coalesced header+protocol in single read (V1Lazy client)")
    func handleCoalescedLazyClient() async throws {
        // V1Lazy client sends header + protocol in one write
        let headerEncoded = MultistreamSelect.encode(MultistreamSelect.protocolID)
        let protoEncoded = MultistreamSelect.encode("/test/1.0.0")
        let coalescedRequest = headerEncoded + protoEncoded

        var readCalled = false
        var writtenData: [Data] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/test/1.0.0"],
            read: {
                if !readCalled {
                    readCalled = true
                    return coalescedRequest
                }
                throw NegotiationError.invalidMessage
            },
            write: { data in writtenData.append(data) }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(writtenData.count == 2) // header response + protocol confirmation
    }

    // MARK: - V1Lazy Edge Cases

    @Test("V1Lazy fallback to second protocol on rejection")
    func v1LazyFallback() async throws {
        var readIndex = 0
        let responses: [Data] = [
            MultistreamSelect.encode(MultistreamSelect.protocolID) + MultistreamSelect.encode("na"),
            MultistreamSelect.encode("/proto/2.0.0")
        ]

        let result = try await MultistreamSelect.negotiateLazy(
            protocols: ["/proto/1.0.0", "/proto/2.0.0"],
            read: {
                guard readIndex < responses.count else { throw NegotiationError.invalidMessage }
                let data = responses[readIndex]
                readIndex += 1
                return data
            },
            write: { _ in }
        )

        #expect(result.protocolID == "/proto/2.0.0")
    }

    @Test("V1Lazy with empty protocol list throws noAgreement")
    func v1LazyEmptyProtocols() async throws {
        await #expect(throws: NegotiationError.noAgreement) {
            _ = try await MultistreamSelect.negotiateLazy(
                protocols: [],
                read: { Data() },
                write: { _ in }
            )
        }
    }

    @Test("V1Lazy all protocols rejected throws noAgreement")
    func v1LazyAllRejected() async throws {
        var readIndex = 0
        let responses: [Data] = [
            MultistreamSelect.encode(MultistreamSelect.protocolID) + MultistreamSelect.encode("na"),
            MultistreamSelect.encode("na")
        ]

        await #expect(throws: NegotiationError.noAgreement) {
            _ = try await MultistreamSelect.negotiateLazy(
                protocols: ["/a/1.0.0", "/b/1.0.0"],
                read: {
                    guard readIndex < responses.count else { throw NegotiationError.invalidMessage }
                    let data = responses[readIndex]
                    readIndex += 1
                    return data
                },
                write: { _ in }
            )
        }
    }

    // MARK: - Handle Edge Cases

    @Test("Handle responder rejects unsupported then accepts supported")
    func handleRejectThenAccept() async throws {
        var readIndex = 0
        let requests: [Data] = [
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("/unsupported/1.0.0"),
            MultistreamSelect.encode("/supported/1.0.0")
        ]

        var writtenData: [Data] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/supported/1.0.0"],
            read: {
                guard readIndex < requests.count else { throw NegotiationError.invalidMessage }
                let data = requests[readIndex]
                readIndex += 1
                return data
            },
            write: { data in writtenData.append(data) }
        )

        #expect(result.protocolID == "/supported/1.0.0")
        // Expect: header response, "na" for unsupported, confirmed for supported
        #expect(writtenData.count == 3)
    }

    @Test("Handle ls command returns all supported protocols")
    func handleLsCommand() async throws {
        var readIndex = 0
        let requests: [Data] = [
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("ls"),
            MultistreamSelect.encode("/proto/a")
        ]

        var writtenData: [Data] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/proto/a", "/proto/b"],
            read: {
                guard readIndex < requests.count else { throw NegotiationError.invalidMessage }
                let data = requests[readIndex]
                readIndex += 1
                return data
            },
            write: { data in writtenData.append(data) }
        )

        #expect(result.protocolID == "/proto/a")
        #expect(writtenData.count == 3) // header, ls response, confirmation
    }

    @Test("Handle enforces max negotiation attempts limit")
    func handleMaxAttempts() async throws {
        var readIndex = 0

        await #expect(throws: NegotiationError.tooManyAttempts) {
            _ = try await MultistreamSelect.handle(
                supported: ["/real/1.0.0"],
                read: {
                    if readIndex == 0 {
                        readIndex += 1
                        return MultistreamSelect.encode(MultistreamSelect.protocolID)
                    }
                    readIndex += 1
                    return MultistreamSelect.encode("/fake/\(readIndex)")
                },
                write: { _ in }
            )
        }

        // Should have tried maxNegotiationAttempts (1000) + 1 header
        #expect(readIndex > 1000)
    }

    @Test("Negotiate with wrong header protocol throws protocolMismatch")
    func negotiateWrongHeader() async throws {
        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/test/1.0.0"],
                read: { MultistreamSelect.encode("/wrong/header") },
                write: { _ in }
            )
        }
    }

    @Test("Handle with wrong header protocol throws protocolMismatch")
    func handleWrongHeader() async throws {
        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.handle(
                supported: ["/test/1.0.0"],
                read: { MultistreamSelect.encode("/wrong/header") },
                write: { _ in }
            )
        }
    }

    // MARK: - Remainder / Buffer Preservation

    @Test("Negotiate preserves remainder data after negotiation")
    func negotiatePreservesRemainder() async throws {
        let headerEncoded = MultistreamSelect.encode(MultistreamSelect.protocolID)
        let protoEncoded = MultistreamSelect.encode("/test/1.0.0")
        let extraBytes = Data([0x01, 0x02, 0x03])
        let response = headerEncoded + protoEncoded + extraBytes

        var readCalled = false
        let result = try await MultistreamSelect.negotiate(
            protocols: ["/test/1.0.0"],
            read: {
                if !readCalled {
                    readCalled = true
                    return response
                }
                throw NegotiationError.invalidMessage
            },
            write: { _ in }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(result.remainder == extraBytes)
    }

    // MARK: - Encode/Decode Roundtrip

    @Test("Encode/decode roundtrip for various protocol IDs")
    func encodeDecodeRoundtrip() throws {
        let protocols = [
            "/multistream/1.0.0",
            "/ipfs/ping/1.0.0",
            "/yamux/1.0.0",
            "/noise",
            "/libp2p/circuit/relay/0.2.0/hop",
            "na"
        ]

        for proto in protocols {
            let encoded = MultistreamSelect.encode(proto)
            let (decoded, consumed) = try MultistreamSelect.decode(encoded)
            #expect(decoded == proto, "Roundtrip failed for: \(proto)")
            #expect(consumed == encoded.count)
        }
    }
}
