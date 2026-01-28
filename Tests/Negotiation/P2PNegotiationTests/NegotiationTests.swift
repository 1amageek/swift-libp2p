import Testing
import Foundation
@testable import P2PNegotiation
import P2PCore

@Suite("Multistream-Select Tests")
struct MultistreamSelectTests {

    // MARK: - Encode/Decode Tests

    @Test("Encode adds length prefix and newline")
    func encodeBasic() throws {
        let encoded = MultistreamSelect.encode("/noise")
        // Should be: varint(7) + "/noise\n"
        // 7 = length of "/noise\n"
        #expect(encoded[0] == 7) // varint encoding of 7
        #expect(String(decoding: encoded.dropFirst(1), as: UTF8.self) == "/noise\n")
    }

    @Test("Encode multistream protocol ID")
    func encodeMultistreamProtocol() throws {
        let encoded = MultistreamSelect.encode("/multistream/1.0.0")
        // Length of "/multistream/1.0.0\n" = 19
        #expect(encoded[0] == 19)
        #expect(String(decoding: encoded.dropFirst(1), as: UTF8.self) == "/multistream/1.0.0\n")
    }

    @Test("Decode valid message")
    func decodeBasic() throws {
        let encoded = MultistreamSelect.encode("/noise")
        let (decoded, consumed) = try MultistreamSelect.decode(encoded)
        #expect(decoded == "/noise")
        #expect(consumed == encoded.count)
    }

    @Test("Encode/Decode round trip")
    func encodeDecodeRoundTrip() throws {
        let protocols = [
            "/multistream/1.0.0",
            "/noise",
            "/yamux/1.0.0",
            "/ipfs/id/1.0.0",
            "/ipfs/ping/1.0.0",
            "na"
        ]
        for proto in protocols {
            let encoded = MultistreamSelect.encode(proto)
            let (decoded, consumed) = try MultistreamSelect.decode(encoded)
            #expect(decoded == proto, "Round trip failed for: \(proto)")
            #expect(consumed == encoded.count)
        }
    }

    @Test("Decode empty protocol")
    func decodeEmptyProtocol() throws {
        let encoded = MultistreamSelect.encode("")
        let (decoded, _) = try MultistreamSelect.decode(encoded)
        #expect(decoded == "")
    }

    @Test("Decode message without newline throws error")
    func decodeWithoutNewline() throws {
        // Manually create invalid message (no newline)
        var data = Data([5]) // varint length = 5
        data.append(Data("/test".utf8)) // no newline

        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    @Test("Decode truncated message throws error")
    func decodeTruncatedMessage() throws {
        // Create message claiming length 10 but only containing 5 bytes
        var data = Data([10]) // varint length = 10
        data.append(Data("/test".utf8)) // only 5 bytes

        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(data)
        }
    }

    // MARK: - Initiator Negotiation Tests

    @Test("Initiator negotiation succeeds with first protocol")
    func initiatorSuccessFirstProtocol() async throws {
        let mockChannel = MockChannel()

        // Setup responder responses
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")

        // Verify what was written
        let written = mockChannel.writtenData
        #expect(written.count == 2)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
    }

    @Test("Initiator negotiation falls back to second protocol")
    func initiatorFallbackToSecondProtocol() async throws {
        let mockChannel = MockChannel()

        // Setup responder responses
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("na")) // First protocol rejected
        mockChannel.queueRead(MultistreamSelect.encode("/yamux/1.0.0")) // Second accepted

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/yamux/1.0.0")

        // Verify all protocols were tried
        let written = mockChannel.writtenData
        #expect(written.count == 3)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
        #expect(try MultistreamSelect.decode(written[2]).0 == "/yamux/1.0.0")
    }

    @Test("Initiator negotiation fails with no agreement")
    func initiatorNoAgreement() async throws {
        let mockChannel = MockChannel()

        // All protocols rejected
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("na"))
        mockChannel.queueRead(MultistreamSelect.encode("na"))

        await #expect(throws: NegotiationError.noAgreement) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/noise", "/yamux/1.0.0"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    @Test("Initiator negotiation fails on multistream header mismatch")
    func initiatorHeaderMismatch() async throws {
        let mockChannel = MockChannel()

        // Wrong multistream header
        mockChannel.queueRead(MultistreamSelect.encode("/wrong/1.0.0"))

        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    @Test("Initiator negotiation fails on unexpected response")
    func initiatorUnexpectedResponse() async throws {
        let mockChannel = MockChannel()

        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/unexpected-protocol"))

        await #expect(throws: NegotiationError.self) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    // MARK: - Responder Negotiation Tests

    @Test("Responder negotiation succeeds with supported protocol")
    func responderSuccessWithSupportedProtocol() async throws {
        let mockChannel = MockChannel()

        // Setup initiator requests
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")

        // Verify responses
        let written = mockChannel.writtenData
        #expect(written.count == 2)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
    }

    @Test("Responder sends 'na' for unsupported protocol then accepts supported")
    func responderRejectsUnsupportedThenAccepts() async throws {
        let mockChannel = MockChannel()

        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/unknown"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")

        // Verify "na" was sent for unknown protocol
        let written = mockChannel.writtenData
        #expect(written.count == 3)
        #expect(try MultistreamSelect.decode(written[1]).0 == "na")
        #expect(try MultistreamSelect.decode(written[2]).0 == "/noise")
    }

    @Test("Responder fails on multistream header mismatch")
    func responderHeaderMismatch() async throws {
        let mockChannel = MockChannel()

        mockChannel.queueRead(MultistreamSelect.encode("/wrong/1.0.0"))

        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.handle(
                supported: ["/noise"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    // MARK: - List (ls) Command Tests

    @Test("Responder handles ls command with correct wire format")
    func responderHandlesLsCommand() async throws {
        let mockChannel = MockChannel()

        // Setup: multistream header, then ls command, then actual protocol
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("ls"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")

        // Verify ls response format
        let written = mockChannel.writtenData
        #expect(written.count == 3)  // multistream header, ls response, protocol ack

        // Verify ls response wire format
        let lsResponse = written[1]

        // Parse outer length prefix
        let (outerLength, outerLengthBytes) = try Varint.decode(lsResponse)
        let inner = lsResponse.dropFirst(outerLengthBytes)

        // Inner should contain: <len>/noise\n<len>/yamux/1.0.0\n\n
        #expect(inner.count == Int(outerLength))

        // Parse first protocol
        let (proto1Len, proto1LenBytes) = try Varint.decode(Data(inner))
        let proto1Data = inner.dropFirst(proto1LenBytes).prefix(Int(proto1Len))
        let proto1 = String(decoding: proto1Data, as: UTF8.self)
        #expect(proto1 == "/noise\n")

        // Parse second protocol
        let afterProto1 = inner.dropFirst(proto1LenBytes + Int(proto1Len))
        let (proto2Len, proto2LenBytes) = try Varint.decode(Data(afterProto1))
        let proto2Data = afterProto1.dropFirst(proto2LenBytes).prefix(Int(proto2Len))
        let proto2 = String(decoding: proto2Data, as: UTF8.self)
        #expect(proto2 == "/yamux/1.0.0\n")

        // Verify final newline
        let afterProto2 = afterProto1.dropFirst(proto2LenBytes + Int(proto2Len))
        #expect(afterProto2.count == 1)
        #expect(afterProto2.first == UInt8(ascii: "\n"))
    }

    @Test("Responder ls response for single protocol")
    func responderLsSingleProtocol() async throws {
        let mockChannel = MockChannel()

        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("ls"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")

        let written = mockChannel.writtenData
        let lsResponse = written[1]

        // Parse and verify format
        let (outerLength, outerLengthBytes) = try Varint.decode(lsResponse)
        let inner = lsResponse.dropFirst(outerLengthBytes)
        #expect(inner.count == Int(outerLength))

        // Should contain: <len>/noise\n\n
        let (protoLen, protoLenBytes) = try Varint.decode(Data(inner))
        let protoData = inner.dropFirst(protoLenBytes).prefix(Int(protoLen))
        let proto = String(decoding: protoData, as: UTF8.self)
        #expect(proto == "/noise\n")

        // Final newline
        let remaining = inner.dropFirst(protoLenBytes + Int(protoLen))
        #expect(remaining.count == 1)
        #expect(remaining.first == UInt8(ascii: "\n"))
    }

    @Test("Responder ls response for empty protocol list")
    func responderLsEmptyProtocols() async throws {
        let mockChannel = MockChannel()

        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("ls"))
        // Connection will hang waiting for a valid protocol, so we simulate close
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        // Handle with empty supported list - ls will return just final newline
        _ = try? await MultistreamSelect.handle(
            supported: [],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        let written = mockChannel.writtenData
        // At least multistream header and ls response
        #expect(written.count >= 2)

        let lsResponse = written[1]
        // Empty list: outer length(1) + single newline
        let (outerLength, _) = try Varint.decode(lsResponse)
        #expect(outerLength == 1)  // Just the final newline
    }

    // MARK: - Protocol ID Constant Tests

    @Test("Protocol ID is correct")
    func protocolIDConstant() {
        #expect(MultistreamSelect.protocolID == "/multistream/1.0.0")
    }

    // MARK: - NegotiationResult Tests

    @Test("NegotiationResult stores protocol ID")
    func negotiationResultStoresProtocol() {
        let result = NegotiationResult(protocolID: "/noise")
        #expect(result.protocolID == "/noise")
        #expect(result.remainder.isEmpty)
    }

    @Test("NegotiationResult with remainder")
    func negotiationResultWithRemainder() {
        let remainder = Data([1, 2, 3, 4])
        let result = NegotiationResult(protocolID: "/noise", remainder: remainder)
        #expect(result.protocolID == "/noise")
        #expect(result.remainder == remainder)
    }

    // MARK: - NegotiationError Tests

    @Test("NegotiationError is Equatable")
    func negotiationErrorEquatable() {
        #expect(NegotiationError.protocolMismatch == NegotiationError.protocolMismatch)
        #expect(NegotiationError.noAgreement == NegotiationError.noAgreement)
        #expect(NegotiationError.invalidMessage == NegotiationError.invalidMessage)
        #expect(NegotiationError.unexpectedResponse("foo") == NegotiationError.unexpectedResponse("foo"))
        #expect(NegotiationError.unexpectedResponse("foo") != NegotiationError.unexpectedResponse("bar"))
    }

    // MARK: - Trailing Bytes / Coalesced Read Tests

    @Test("Decode returns correct bytes consumed with trailing data")
    func decodeWithTrailingData() throws {
        let msg1 = MultistreamSelect.encode("/noise")
        let msg2 = MultistreamSelect.encode("/yamux/1.0.0")
        let combined = msg1 + msg2

        let (decoded, consumed) = try MultistreamSelect.decode(combined)
        #expect(decoded == "/noise")
        #expect(consumed == msg1.count)

        // Remaining data can be decoded as second message
        let remaining = Data(combined.dropFirst(consumed))
        let (decoded2, consumed2) = try MultistreamSelect.decode(remaining)
        #expect(decoded2 == "/yamux/1.0.0")
        #expect(consumed2 == msg2.count)
    }

    @Test("Responder handles V1Lazy coalesced header + protocol")
    func responderHandlesCoalescedLazy() async throws {
        let mockChannel = MockChannel()

        // V1Lazy: initiator sends header + protocol in one batch
        let batch = MultistreamSelect.encode("/multistream/1.0.0")
                  + MultistreamSelect.encode("/noise")
        mockChannel.queueRead(batch)

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
    }
}

// MARK: - Mock Channel

import Synchronization

/// A mock channel for testing negotiation flows.
final class MockChannel: Sendable {
    private struct State: Sendable {
        var readQueue: [Data] = []
        var writtenData: [Data] = []
    }
    private let state = Mutex<State>(State())

    func queueRead(_ data: Data) {
        state.withLock { $0.readQueue.append(data) }
    }

    func read() async throws -> Data {
        try state.withLock { state in
            guard !state.readQueue.isEmpty else {
                throw MockChannelError.noMoreData
            }
            return state.readQueue.removeFirst()
        }
    }

    func write(_ data: Data) async throws {
        state.withLock { $0.writtenData.append(data) }
    }

    var writtenData: [Data] {
        state.withLock { $0.writtenData }
    }
}

enum MockChannelError: Error {
    case noMoreData
}
