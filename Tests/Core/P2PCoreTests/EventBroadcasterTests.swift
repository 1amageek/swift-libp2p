import Testing
import Foundation
@testable import P2PCore

@Suite("EventBroadcaster Tests")
struct EventBroadcasterTests {

    enum TestEvent: Sendable, Equatable {
        case ping
        case pong
        case data(Int)
    }

    @Test("Single subscriber receives events", .timeLimit(.minutes(1)))
    func singleSubscriber() async throws {
        let broadcaster = EventBroadcaster<TestEvent>()
        let stream = broadcaster.subscribe()

        broadcaster.emit(.ping)
        broadcaster.emit(.pong)
        broadcaster.shutdown()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received == [.ping, .pong])
    }

    @Test("Multiple subscribers each receive all events", .timeLimit(.minutes(1)))
    func multipleSubscribers() async throws {
        let broadcaster = EventBroadcaster<TestEvent>()
        let stream1 = broadcaster.subscribe()
        let stream2 = broadcaster.subscribe()

        broadcaster.emit(.ping)
        broadcaster.emit(.data(42))
        broadcaster.shutdown()

        var received1: [TestEvent] = []
        for await event in stream1 {
            received1.append(event)
        }

        var received2: [TestEvent] = []
        for await event in stream2 {
            received2.append(event)
        }

        #expect(received1 == [.ping, .data(42)])
        #expect(received2 == [.ping, .data(42)])
    }

    @Test("Emit with no subscribers does not crash")
    func emitNoSubscribers() {
        let broadcaster = EventBroadcaster<TestEvent>()
        broadcaster.emit(.ping)
        broadcaster.emit(.pong)
        broadcaster.shutdown()
    }

    @Test("Shutdown is idempotent")
    func shutdownIdempotent() {
        let broadcaster = EventBroadcaster<TestEvent>()
        _ = broadcaster.subscribe()
        broadcaster.shutdown()
        broadcaster.shutdown()
        broadcaster.shutdown()
    }

    @Test("Subscriber after shutdown finishes immediately", .timeLimit(.minutes(1)))
    func subscribeAfterShutdown() async throws {
        let broadcaster = EventBroadcaster<TestEvent>()
        broadcaster.emit(.ping)
        broadcaster.shutdown()

        // Subscribe after shutdown
        let stream = broadcaster.subscribe()
        broadcaster.emit(.pong)
        broadcaster.shutdown()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received.isEmpty)
    }

    @Test("Shutdown finishes active streams", .timeLimit(.minutes(1)))
    func shutdownFinishesStreams() async throws {
        let broadcaster = EventBroadcaster<TestEvent>()
        let stream = broadcaster.subscribe()

        broadcaster.emit(.ping)
        broadcaster.shutdown()

        var count = 0
        for await _ in stream {
            count += 1
        }
        // Stream should complete after shutdown
        #expect(count == 1)
    }

    @Test("Buffering policy bounds retained events", .timeLimit(.minutes(1)))
    func bufferingPolicyBoundsRetainedEvents() async throws {
        let broadcaster = EventBroadcaster<TestEvent>(bufferingPolicy: .bufferingNewest(1))
        let stream = broadcaster.subscribe()

        broadcaster.emit(.ping)
        broadcaster.emit(.data(42))
        broadcaster.shutdown()

        var received: [TestEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received == [.data(42)])
    }
}
