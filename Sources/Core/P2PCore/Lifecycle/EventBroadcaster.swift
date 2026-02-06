/// EventBroadcaster - Multi-consumer event broadcasting via independent AsyncStreams
///
/// Unlike the single-consumer EventEmitting pattern (which caches one AsyncStream),
/// EventBroadcaster creates an independent stream for each subscriber.
/// This allows multiple consumers to receive the same events concurrently.

import Synchronization

/// A thread-safe multi-consumer event broadcaster.
///
/// Each call to `subscribe()` returns an independent `AsyncStream<T>`.
/// Events emitted via `emit(_:)` are delivered to all active subscribers.
///
/// ## Usage
///
/// ```swift
/// let broadcaster = EventBroadcaster<MyEvent>()
///
/// // Multiple independent subscribers
/// let stream1 = broadcaster.subscribe()
/// let stream2 = broadcaster.subscribe()
///
/// // Both receive the event
/// broadcaster.emit(.someEvent)
///
/// // Cleanup
/// broadcaster.shutdown()
/// ```
///
/// ## Thread Safety
///
/// All methods are thread-safe via `Mutex<BroadcastState>`.
/// Subscribers are automatically removed when their stream is terminated.
public final class EventBroadcaster<T: Sendable>: Sendable {

    private let state: Mutex<BroadcastState>

    private struct Entry: Sendable {
        let id: UInt64
        let continuation: AsyncStream<T>.Continuation
    }

    private struct BroadcastState: Sendable {
        var entries: [Entry] = []
        var nextID: UInt64 = 0
    }

    public init() {
        self.state = Mutex(BroadcastState())
    }

    deinit {
        let entries = state.withLock { s in
            let e = s.entries
            s.entries.removeAll()
            return e
        }
        for entry in entries { entry.continuation.finish() }
    }

    /// Creates a new independent stream for this subscriber.
    ///
    /// Each call returns a separate stream that independently receives all
    /// future events. The subscription is automatically cleaned up when
    /// the stream is terminated (e.g., by cancelling the consuming Task).
    public func subscribe() -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream()
        let id = state.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            s.entries.append(Entry(id: id, continuation: continuation))
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { s in
                s.entries.removeAll(where: { $0.id == id })
            }
        }
        return stream
    }

    /// Emits an event to all active subscribers.
    ///
    /// Events are delivered to each subscriber's stream independently.
    /// If no subscribers are registered, the event is silently dropped.
    public func emit(_ event: T) {
        let entries = state.withLock { $0.entries }
        for entry in entries {
            entry.continuation.yield(event)
        }
    }

    /// Terminates all subscriber streams and releases resources.
    ///
    /// After shutdown, existing subscribers' `for await` loops will complete.
    /// New subscribers can still call `subscribe()` after shutdown.
    /// This method is idempotent.
    public func shutdown() {
        let entries = state.withLock { s -> [Entry] in
            let e = s.entries
            s.entries.removeAll()
            return e
        }
        for entry in entries {
            entry.continuation.finish()
        }
    }
}
