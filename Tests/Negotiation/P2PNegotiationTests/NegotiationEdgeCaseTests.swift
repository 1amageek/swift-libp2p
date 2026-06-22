import Testing
@testable import P2PNegotiation
import P2PCore

@Suite("Multistream-Select Edge Case Tests")
struct NegotiationEdgeCaseTests {

    @Test("Decode rejects invalid UTF-8 sequences")
    func decodeInvalidUtf8() throws {
        let invalid = buffer([0x04, 0xFF, 0xFE, 0x0A, 0x0A])
        #expect(throws: NegotiationError.invalidUtf8) {
            _ = try MultistreamSelect.decode(invalid)
        }
    }

    @Test("Decode rejects message without trailing newline")
    func decodeNoNewline() throws {
        let message = buffer([0x04, 0x74, 0x65, 0x73, 0x74])
        #expect(throws: NegotiationError.invalidMessage) {
            _ = try MultistreamSelect.decode(message)
        }
    }

    @Test("Decode rejects oversized message")
    func decodeOversizedMessage() throws {
        let hugeLength: UInt64 = 70_000
        var bytes: [UInt8] = []
        var value = hugeLength
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        bytes.append(contentsOf: Array(repeating: 0x41, count: Int(hugeLength)))

        do {
            _ = try MultistreamSelect.decode(buffer(bytes))
            Issue.record("Expected messageTooLarge error")
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

    @Test("Decode correctly returns consumed bytes with trailing data")
    func decodeConsumedBytes() throws {
        let encoded = MultistreamSelect.encode("test")
        let combined = combine(encoded, buffer([0xDE, 0xAD]))

        let (decoded, consumed) = try MultistreamSelect.decode(combined)
        #expect(decoded == "test")
        #expect(consumed == encoded.readableBytes)
        #expect(combined.readableBytes - consumed == 2)
    }

    @Test("Negotiate handles coalesced header and response in a single read")
    func negotiateCoalescedRead() async throws {
        let response = combine(
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("/test/1.0.0")
        )

        var readCalled = false
        var writeCount = 0

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/test/1.0.0"],
            read: {
                guard !readCalled else { throw NegotiationError.invalidMessage }
                readCalled = true
                return response
            },
            write: { _ in writeCount += 1 }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(writeCount == 2)
    }

    @Test("Negotiate handles fragmented reads")
    func negotiateFragmentedReads() async throws {
        let header = MultistreamSelect.encode(MultistreamSelect.protocolID)
        let proto = MultistreamSelect.encode("/test/1.0.0")
        let combinedResponse = combine(header, proto)
        let fragments = [
            slice(combinedResponse, 0, 2),
            slice(combinedResponse, 2, 4),
            slice(combinedResponse, 6, combinedResponse.readableBytes - 6)
        ]

        var readIndex = 0
        var writeCount = 0

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/test/1.0.0"],
            read: {
                guard readIndex < fragments.count else { throw NegotiationError.invalidMessage }
                defer { readIndex += 1 }
                return fragments[readIndex]
            },
            write: { _ in writeCount += 1 }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(writeCount == 2)
        #expect(readIndex == fragments.count)
    }

    @Test("Handle processes coalesced V1Lazy client request")
    func handleCoalescedLazyClient() async throws {
        let request = combine(
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("/test/1.0.0")
        )
        var readCalled = false
        var writes: [ByteBuffer] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/test/1.0.0"],
            read: {
                guard !readCalled else { throw NegotiationError.invalidMessage }
                readCalled = true
                return request
            },
            write: { writes.append($0) }
        )

        #expect(result.protocolID == "/test/1.0.0")
        #expect(writes.count == 2)
    }

    @Test("V1Lazy falls back to second protocol on rejection")
    func v1LazyFallback() async throws {
        let responses = [
            combine(
                MultistreamSelect.encode(MultistreamSelect.protocolID),
                MultistreamSelect.encode("na")
            ),
            MultistreamSelect.encode("/proto/2.0.0")
        ]

        var readIndex = 0
        let result = try await MultistreamSelect.negotiateLazy(
            protocols: ["/proto/1.0.0", "/proto/2.0.0"],
            read: {
                guard readIndex < responses.count else { throw NegotiationError.invalidMessage }
                defer { readIndex += 1 }
                return responses[readIndex]
            },
            write: { _ in }
        )

        #expect(result.protocolID == "/proto/2.0.0")
    }

    @Test("V1Lazy batches header and first protocol in one write")
    func v1LazyBatchedFirstWrite() async throws {
        var writes: [ByteBuffer] = []
        var readCalled = false

        let result = try await MultistreamSelect.negotiateLazy(
            protocols: ["/proto/1.0.0"],
            read: {
                guard !readCalled else { throw NegotiationError.invalidMessage }
                readCalled = true
                return combine(
                    MultistreamSelect.encode(MultistreamSelect.protocolID),
                    MultistreamSelect.encode("/proto/1.0.0")
                )
            },
            write: { writes.append($0) }
        )

        #expect(result.protocolID == "/proto/1.0.0")
        #expect(writes.count == 1)

        let (first, firstConsumed) = try MultistreamSelect.decode(writes[0])
        #expect(first == MultistreamSelect.protocolID)
        let secondBuffer = dropped(writes[0], firstConsumed)
        let (second, secondConsumed) = try MultistreamSelect.decode(secondBuffer)
        #expect(second == "/proto/1.0.0")
        #expect(firstConsumed + secondConsumed == writes[0].readableBytes)
    }

    @Test("Handle reject then accept")
    func handleRejectThenAccept() async throws {
        let requests = [
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("/unsupported/1.0.0"),
            MultistreamSelect.encode("/supported/1.0.0")
        ]

        var readIndex = 0
        var writes: [ByteBuffer] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/supported/1.0.0"],
            read: {
                guard readIndex < requests.count else { throw NegotiationError.invalidMessage }
                defer { readIndex += 1 }
                return requests[readIndex]
            },
            write: { writes.append($0) }
        )

        #expect(result.protocolID == "/supported/1.0.0")
        #expect(writes.count == 3)
        #expect(try MultistreamSelect.decode(writes[1]).0 == "na")
        #expect(try MultistreamSelect.decode(writes[2]).0 == "/supported/1.0.0")
    }

    @Test("Handle ls command returns newline-delimited protocols")
    func handleLsCommand() async throws {
        let requests = [
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("ls"),
            MultistreamSelect.encode("/proto/a")
        ]

        var readIndex = 0
        var writes: [ByteBuffer] = []

        let result = try await MultistreamSelect.handle(
            supported: ["/proto/a", "/proto/b"],
            read: {
                guard readIndex < requests.count else { throw NegotiationError.invalidMessage }
                defer { readIndex += 1 }
                return requests[readIndex]
            },
            write: { writes.append($0) }
        )

        #expect(result.protocolID == "/proto/a")
        #expect(writes.count == 3)

        let lsResponse = writes[1]
        let (length, lengthBytes) = try decodeVarint(lsResponse)
        let payload = dropped(lsResponse, lengthBytes)
        #expect(payload.readableBytes == Int(length))
        #expect(String(decoding: payload.readableBytesView, as: UTF8.self) == "/proto/a\n/proto/b\n\n")
    }

    @Test("Handle enforces maximum negotiation attempts")
    func handleMaxAttempts() async throws {
        var readIndex = 0
        await #expect(throws: NegotiationError.tooManyAttempts) {
            _ = try await MultistreamSelect.handle(
                supported: ["/supported"],
                read: {
                    if readIndex == 0 {
                        readIndex += 1
                        return MultistreamSelect.encode(MultistreamSelect.protocolID)
                    }
                    readIndex += 1
                    return MultistreamSelect.encode("/unsupported")
                },
                write: { _ in }
            )
        }
    }

    @Test("Negotiate wrong header throws protocolMismatch")
    func negotiateWrongHeader() async throws {
        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/test"],
                read: { MultistreamSelect.encode("/wrong/header") },
                write: { _ in }
            )
        }
    }

    @Test("Handle wrong header throws protocolMismatch")
    func handleWrongHeader() async throws {
        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.handle(
                supported: ["/test"],
                read: { MultistreamSelect.encode("/wrong/header") },
                write: { _ in }
            )
        }
    }

    @Test("Negotiate preserves trailing remainder")
    func negotiatePreservesRemainder() async throws {
        let extraBytes = buffer([0x01, 0x02, 0x03])
        let response = combine(
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("/test/1.0.0"),
            extraBytes
        )

        var readCalled = false
        let result = try await MultistreamSelect.negotiate(
            protocols: ["/test/1.0.0"],
            read: {
                guard !readCalled else { throw NegotiationError.invalidMessage }
                readCalled = true
                return response
            },
            write: { _ in }
        )

        #expect(equalBytes(result.remainderBuffer, extraBytes))
    }

    // MARK: - Negotiation-Phase Budget / Deadline (Finding 3)

    @Test("Handle caps the number of ls responses (pre-auth amplification)")
    func handleLsResponseBudget() async throws {
        // A peer that repeatedly requests `ls` would force the responder to
        // serialize the full protocol list each time (output amplification).
        // The maxListResponses budget must stop this.
        var readIndex = 0
        var lsResponsesWritten = 0
        let limits = MultistreamSelect.HandleLimits(maxListResponses: 3)

        await #expect(throws: NegotiationError.negotiationBudgetExceeded) {
            _ = try await MultistreamSelect.handle(
                supported: ["/proto/a", "/proto/b", "/proto/c"],
                limits: limits,
                read: {
                    if readIndex == 0 {
                        readIndex += 1
                        return MultistreamSelect.encode(MultistreamSelect.protocolID)
                    }
                    readIndex += 1
                    return MultistreamSelect.encode("ls")  // endless ls requests
                },
                write: { written in
                    // Count ls-list responses (they are larger than a header/na).
                    if let (decoded, _) = try? MultistreamSelect.decode(written),
                       decoded.contains("/proto/a") {
                        lsResponsesWritten += 1
                    }
                }
            )
        }

        // The responder served at most the budgeted number of ls replies.
        #expect(lsResponsesWritten <= limits.maxListResponses)
    }

    @Test("Handle caps total received bytes during negotiation")
    func handleReceivedByteBudget() async throws {
        // A peer dribbling unbounded junk (here: oversized unsupported protocol
        // names) must be cut off by the received-byte budget.
        let limits = MultistreamSelect.HandleLimits(maxReceivedBytes: 256)
        var readIndex = 0
        // A long but individually valid (<= maxMessageSize) protocol name.
        let longProto = "/" + String(repeating: "x", count: 200)

        await #expect(throws: NegotiationError.negotiationBudgetExceeded) {
            _ = try await MultistreamSelect.handle(
                supported: ["/supported"],
                limits: limits,
                read: {
                    if readIndex == 0 {
                        readIndex += 1
                        return MultistreamSelect.encode(MultistreamSelect.protocolID)
                    }
                    readIndex += 1
                    return MultistreamSelect.encode(longProto)
                },
                write: { _ in }
            )
        }
    }

    @Test("Handle enforces a wall-clock negotiation deadline")
    func handleDeadline() async throws {
        // A peer that makes slow incremental progress must be cut off by the
        // deadline. We use a tiny deadline and a read that returns the header,
        // then delays past the deadline before the next fragment.
        let limits = MultistreamSelect.HandleLimits(deadline: .milliseconds(50))
        var readIndex = 0

        await #expect(throws: NegotiationError.negotiationTimeout) {
            _ = try await MultistreamSelect.handle(
                supported: ["/supported"],
                limits: limits,
                read: {
                    if readIndex == 0 {
                        readIndex += 1
                        return MultistreamSelect.encode(MultistreamSelect.protocolID)
                    }
                    // Sleep past the deadline before returning the next chunk.
                    try await Task.sleep(for: .milliseconds(120))
                    readIndex += 1
                    return MultistreamSelect.encode("/unsupported")
                },
                write: { _ in }
            )
        }
    }

    @Test("Handle still succeeds within budgets and deadline")
    func handleSucceedsWithinBudgets() async throws {
        // Sanity: normal negotiation (header + one ls + accept) succeeds with
        // the default limits applied.
        let requests = [
            MultistreamSelect.encode(MultistreamSelect.protocolID),
            MultistreamSelect.encode("ls"),
            MultistreamSelect.encode("/proto/a"),
        ]
        var readIndex = 0
        let result = try await MultistreamSelect.handle(
            supported: ["/proto/a", "/proto/b"],
            read: {
                guard readIndex < requests.count else { throw NegotiationError.invalidMessage }
                defer { readIndex += 1 }
                return requests[readIndex]
            },
            write: { _ in }
        )
        #expect(result.protocolID == "/proto/a")
    }
}

private func slice(_ buffer: ByteBuffer, _ offset: Int, _ length: Int) -> ByteBuffer {
    var copy = buffer
    copy.moveReaderIndex(forwardBy: offset)
    guard let slice = copy.readSlice(length: length) else {
        return ByteBuffer()
    }
    return slice
}
