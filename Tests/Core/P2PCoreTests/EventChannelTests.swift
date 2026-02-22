import Testing
import Foundation
@testable import P2PCore

@Suite("EventChannel Tests")
struct EventChannelTests {

    enum TestEvent: Sendable, Equatable {
        case ping
        case pong
        case data(Int)
    }

    // MARK: - Basic

    @Test("yield + consume delivers events in order", .timeLimit(.minutes(1)))
    func yieldAndConsume() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream

        channel.yield(.ping)
        channel.yield(.pong)
        channel.yield(.data(42))
        channel.finish()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received == [.ping, .pong, .data(42)])
    }

    @Test("Multiple events preserve order", .timeLimit(.minutes(1)))
    func multipleEventsOrder() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream

        for i in 0..<100 {
            channel.yield(.data(i))
        }
        channel.finish()

        var received: [Int] = []
        for await event in stream {
            if case .data(let n) = event {
                received.append(n)
            }
        }
        #expect(received == Array(0..<100))
    }

    // MARK: - finish timing: all patterns

    @Test("finish → stream → for await: stream obtained after finish terminates immediately", .timeLimit(.minutes(1)))
    func finishBeforeStreamAccess() async {
        let channel = EventChannel<TestEvent>()
        channel.finish()

        let stream = channel.stream
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("stream → finish → for await: finish before consume terminates stream", .timeLimit(.minutes(1)))
    func finishBeforeConsume() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream

        channel.yield(.ping)
        channel.finish()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received == [.ping])
    }

    @Test("stream → for await → finish: finish during consume terminates loop", .timeLimit(.minutes(1)))
    func finishDuringConsume() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream

        // Start consuming in a separate task
        let collected = Task<[TestEvent], Never> {
            var events: [TestEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        // Yield some events, then finish
        channel.yield(.ping)
        channel.yield(.pong)
        // Give the consumer time to start
        try? await Task.sleep(for: .milliseconds(50))
        channel.finish()

        let received = await collected.value
        #expect(received.contains(.ping))
        #expect(received.contains(.pong))
    }

    @Test("stream → for await (no yield) → finish: empty stream terminates", .timeLimit(.minutes(1)))
    func finishEmptyStream() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream

        let collected = Task<Int, Never> {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        // Give consumer time to start awaiting
        try? await Task.sleep(for: .milliseconds(50))
        channel.finish()

        let count = await collected.value
        #expect(count == 0)
    }

    // MARK: - Idempotency

    @Test("finish is idempotent — multiple calls do not crash")
    func finishIdempotent() {
        let channel = EventChannel<TestEvent>()
        channel.finish()
        channel.finish()
        channel.finish()
    }

    @Test("yield after finish is a no-op", .timeLimit(.minutes(1)))
    func yieldAfterFinish() async {
        let channel = EventChannel<TestEvent>()
        channel.yield(.ping)
        channel.finish()

        // These should be silently dropped
        channel.yield(.pong)
        channel.yield(.data(1))

        let stream = channel.stream
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0) // stream obtained after finish → immediate termination
    }

    @Test("stream after finish returns immediately-terminating stream", .timeLimit(.minutes(1)))
    func streamAfterFinish() async {
        let channel = EventChannel<TestEvent>()
        let firstStream = channel.stream
        channel.finish()

        // Access stream again after finish
        let secondStream = channel.stream
        var count = 0
        for await _ in secondStream {
            count += 1
        }
        #expect(count == 0)

        // First stream should also be terminated
        var firstCount = 0
        for await _ in firstStream {
            firstCount += 1
        }
        #expect(firstCount == 0)
    }

    // MARK: - Caching

    @Test("stream returns the same instance on repeated calls", .timeLimit(.minutes(1)))
    func streamCaching() async {
        let channel = EventChannel<TestEvent>()
        let stream1 = channel.stream
        let stream2 = channel.stream

        channel.yield(.ping)
        channel.finish()

        // Both variables reference the same stream — consuming one consumes both
        var received: [TestEvent] = []
        for await event in stream1 {
            received.append(event)
        }
        #expect(received == [.ping])
    }

    // MARK: - Concurrency

    @Test("concurrent yields do not crash", .timeLimit(.minutes(1)))
    func concurrentYields() async {
        let channel = EventChannel<TestEvent>()
        _ = channel.stream

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    channel.yield(.data(i))
                }
            }
        }

        channel.finish()
    }

    @Test("yield and finish concurrently do not crash", .timeLimit(.minutes(1)))
    func yieldAndFinishConcurrently() async {
        let channel = EventChannel<TestEvent>()
        _ = channel.stream

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    channel.yield(.data(i))
                }
            }
            group.addTask {
                channel.finish()
            }
        }
    }

    @Test("stream and finish concurrently do not hang", .timeLimit(.minutes(1)))
    func streamAndFinishConcurrently() async {
        let channel = EventChannel<TestEvent>()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let stream = channel.stream
                for await _ in stream { }
            }
            group.addTask {
                // Small delay to let the other task start
                try? await Task.sleep(for: .milliseconds(10))
                channel.finish()
            }
        }
    }

    // MARK: - finish + async hop pattern

    @Test("stream → finish → await yield → for await: finish before consume with async hop", .timeLimit(.minutes(1)))
    func finishWithAsyncHop() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream
        channel.finish()

        // Simulate async hop (like await service.shutdown())
        await Task.yield()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    @Test("stream → finish (no yield) → for await: immediate consume after finish", .timeLimit(.minutes(1)))
    func finishNoYieldThenConsume() async {
        let channel = EventChannel<TestEvent>()
        let stream = channel.stream
        channel.finish()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    // MARK: - Buffering Policy

    @Test("custom bufferingPolicy is applied", .timeLimit(.minutes(1)))
    func customBufferingPolicy() async {
        let channel = EventChannel<TestEvent>(bufferingPolicy: .bufferingNewest(2))
        let stream = channel.stream

        // Yield more events than the buffer can hold
        channel.yield(.data(1))
        channel.yield(.data(2))
        channel.yield(.data(3))
        channel.yield(.data(4))
        channel.finish()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        // With bufferingNewest(2), only the last 2 events should be kept
        #expect(received.count <= 2)
    }
}
