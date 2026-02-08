import Testing
@testable import P2PCore

// Test event types
enum TestNodeEvent: Sendable, Equatable {
    case peerConnected(String)
    case peerDisconnected(String)
}

struct TestMetricEvent: Sendable, Equatable {
    let name: String
    let value: Double
}

@Suite("EventBus")
struct EventBusTests {

    @Test("subscribe and receive single event", .timeLimit(.minutes(1)))
    func subscribeAndReceive() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        let stream = bus.subscribe(to: TestNodeEvent.self)
        bus.emit(TestNodeEvent.peerConnected("peer1"))

        var received: TestNodeEvent?
        for await event in stream {
            received = event
            break
        }
        #expect(received == .peerConnected("peer1"))
    }

    @Test("multiple subscribers receive same event", .timeLimit(.minutes(1)))
    func multipleSubscribers() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        let stream1 = bus.subscribe(to: TestNodeEvent.self)
        let stream2 = bus.subscribe(to: TestNodeEvent.self)

        bus.emit(TestNodeEvent.peerConnected("peer1"))

        var r1: TestNodeEvent?
        for await event in stream1 { r1 = event; break }
        var r2: TestNodeEvent?
        for await event in stream2 { r2 = event; break }

        #expect(r1 == .peerConnected("peer1"))
        #expect(r2 == .peerConnected("peer1"))
    }

    @Test("different event types are independent", .timeLimit(.minutes(1)))
    func differentTypes() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        let nodeStream = bus.subscribe(to: TestNodeEvent.self)
        let metricStream = bus.subscribe(to: TestMetricEvent.self)

        bus.emit(TestNodeEvent.peerConnected("peer1"))
        bus.emit(TestMetricEvent(name: "rtt", value: 42.0))

        var nodeEvent: TestNodeEvent?
        for await event in nodeStream { nodeEvent = event; break }

        var metricEvent: TestMetricEvent?
        for await event in metricStream { metricEvent = event; break }

        #expect(nodeEvent == .peerConnected("peer1"))
        #expect(metricEvent == TestMetricEvent(name: "rtt", value: 42.0))
    }

    @Test("emit with no subscribers does not crash")
    func emitNoSubscribers() {
        let bus = EventBus()
        bus.emit(TestNodeEvent.peerConnected("nobody"))
        bus.shutdown()
    }

    @Test("shutdown terminates streams", .timeLimit(.minutes(1)))
    func shutdownTerminatesStreams() async {
        let bus = EventBus()
        let stream = bus.subscribe(to: TestNodeEvent.self)

        bus.emit(TestNodeEvent.peerConnected("peer1"))
        bus.shutdown()

        var count = 0
        for await _ in stream {
            count += 1
        }
        // Stream should terminate after shutdown, count should be 0 or 1
        #expect(count <= 1)
    }

    @Test("subscribe after emit gets no previous events", .timeLimit(.minutes(1)))
    func lateSubscriber() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        bus.emit(TestNodeEvent.peerConnected("peer1"))

        let stream = bus.subscribe(to: TestNodeEvent.self)
        bus.emit(TestNodeEvent.peerDisconnected("peer1"))

        var received: TestNodeEvent?
        for await event in stream { received = event; break }
        #expect(received == .peerDisconnected("peer1"))
    }

    @Test("multiple event sequence", .timeLimit(.minutes(1)))
    func multipleEvents() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        let stream = bus.subscribe(to: TestNodeEvent.self)

        bus.emit(TestNodeEvent.peerConnected("p1"))
        bus.emit(TestNodeEvent.peerConnected("p2"))
        bus.emit(TestNodeEvent.peerDisconnected("p1"))

        var events: [TestNodeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 3 { break }
        }

        #expect(events == [
            .peerConnected("p1"),
            .peerConnected("p2"),
            .peerDisconnected("p1")
        ])
    }

    @Test("concurrent emit is safe", .timeLimit(.minutes(1)))
    func concurrentEmit() async {
        let bus = EventBus()
        defer { bus.shutdown() }

        let stream = bus.subscribe(to: TestMetricEvent.self)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    bus.emit(TestMetricEvent(name: "m\(i)", value: Double(i)))
                }
            }
        }

        // Just verify no crashes; events may be received out of order
        var count = 0
        for await _ in stream {
            count += 1
            if count >= 100 { break }
        }
        #expect(count == 100)
    }

    @Test("shutdown is idempotent")
    func shutdownIdempotent() {
        let bus = EventBus()
        _ = bus.subscribe(to: TestNodeEvent.self)
        bus.shutdown()
        bus.shutdown()
        bus.shutdown()
    }

    @Test("subscribe after shutdown works", .timeLimit(.minutes(1)))
    func subscribeAfterShutdown() async {
        let bus = EventBus()
        let stream1 = bus.subscribe(to: TestNodeEvent.self)
        bus.emit(TestNodeEvent.peerConnected("peer1"))
        bus.shutdown()

        // Drain the first stream
        var count1 = 0
        for await _ in stream1 { count1 += 1 }
        #expect(count1 == 1)

        // Subscribe again after shutdown - should get a fresh broadcaster
        let stream2 = bus.subscribe(to: TestNodeEvent.self)
        bus.emit(TestNodeEvent.peerDisconnected("peer2"))
        bus.shutdown()

        var received: [TestNodeEvent] = []
        for await event in stream2 {
            received.append(event)
        }
        #expect(received == [.peerDisconnected("peer2")])
    }
}
