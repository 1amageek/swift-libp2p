/// EventBus - Type-safe event pub/sub system
///
/// Allows components to subscribe to specific event types and receive
/// events of that type via independent AsyncStreams. Each event type
/// is dispatched through its own EventBroadcaster, ensuring type safety
/// and isolation between different event channels.
///
/// ## Usage
///
/// ```swift
/// let bus = EventBus()
///
/// // Subscribe to specific event types
/// let nodeEvents = bus.subscribe(to: NodeEvent.self)
/// let metricEvents = bus.subscribe(to: MetricEvent.self)
///
/// // Emit events (delivered to all subscribers of that type)
/// bus.emit(NodeEvent.peerConnected("peer1"))
/// bus.emit(MetricEvent(name: "rtt", value: 42.0))
///
/// // Cleanup
/// bus.shutdown()
/// ```
///
/// ## Thread Safety
///
/// All methods are thread-safe via `Mutex`. EventBus uses Class + Mutex
/// (not Actor) for high-frequency access patterns.
///
/// ## Multi-Consumer
///
/// Each call to `subscribe(to:)` returns an independent `AsyncStream`.
/// Multiple subscribers to the same event type each receive all events.

import Synchronization

// Internal protocol to allow calling shutdown on type-erased EventBroadcaster instances.
// EventBroadcaster<T> is generic, so we cannot store heterogeneous broadcasters
// in a dictionary without type erasure. This protocol provides the shutdown hook.
internal protocol ShutdownableBroadcaster: Sendable {
    func shutdownBroadcaster()
}

extension EventBroadcaster: ShutdownableBroadcaster {
    internal func shutdownBroadcaster() {
        shutdown()
    }
}

public final class EventBus: Sendable {

    // ObjectIdentifier(E.Type) -> EventBroadcaster<E> (stored as ShutdownableBroadcaster)
    private let state: Mutex<[ObjectIdentifier: any ShutdownableBroadcaster]>

    public init() {
        self.state = Mutex([:])
    }

    /// Subscribe to events of a specific type.
    ///
    /// Each call returns an independent `AsyncStream<E>`. Multiple subscribers
    /// to the same event type each receive all emitted events independently.
    ///
    /// - Parameter eventType: The event type to subscribe to.
    /// - Returns: An `AsyncStream` that yields events of the specified type.
    public func subscribe<E: Sendable>(to eventType: E.Type) -> AsyncStream<E> {
        let broadcaster: EventBroadcaster<E> = state.withLock { dict in
            let key = ObjectIdentifier(eventType)
            if let existing = dict[key] as? EventBroadcaster<E> {
                return existing
            }
            let new = EventBroadcaster<E>()
            dict[key] = new
            return new
        }
        return broadcaster.subscribe()
    }

    /// Emit an event to all subscribers of that event type.
    ///
    /// If no subscribers exist for the event type, the event is silently dropped.
    /// The broadcaster lookup and event emission happen outside the lock to avoid
    /// nested lock acquisition (EventBroadcaster.emit also acquires its own lock).
    ///
    /// - Parameter event: The event to emit.
    public func emit<E: Sendable>(_ event: E) {
        let key = ObjectIdentifier(E.self)
        let broadcaster: EventBroadcaster<E>? = state.withLock { dict in
            dict[key] as? EventBroadcaster<E>
        }
        broadcaster?.emit(event)
    }

    /// Shutdown all broadcasters, terminating all active subscriber streams.
    ///
    /// After shutdown:
    /// - All existing `for await` loops on subscribed streams will complete.
    /// - The internal broadcaster registry is cleared.
    /// - New subscriptions can still be created (a fresh broadcaster will be allocated).
    ///
    /// This method is idempotent - safe to call multiple times.
    public func shutdown() {
        // Collect all broadcasters under the lock, then shut them down outside
        // to avoid nested lock acquisition (Mutex inside EventBroadcaster).
        let all = state.withLock { dict -> [any ShutdownableBroadcaster] in
            let result = Array(dict.values)
            dict.removeAll()
            return result
        }
        for broadcaster in all {
            broadcaster.shutdownBroadcaster()
        }
    }
}
