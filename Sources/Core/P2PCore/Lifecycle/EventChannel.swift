/// EventChannel - Single-consumer event channel with safe shutdown semantics
///
/// Replaces the manual `Mutex<EventState>` + `AsyncStream.makeStream()` pattern
/// used by EventEmitting conformers. Fixes two bugs in the original pattern:
///
/// 1. **finish-before-consume**: `continuation.finish()` is called outside the lock
///    to avoid interference between Mutex and AsyncStream internals.
/// 2. **events-after-shutdown**: An `isFinished` flag ensures that accessing `stream`
///    after `finish()` returns an immediately-terminating stream instead of hanging.

import Synchronization

/// A thread-safe single-consumer event channel.
///
/// Each access to `stream` returns the **same** cached `AsyncStream<Element>`.
/// After `finish()` is called, any subsequent `stream` access returns an
/// immediately-terminating stream.
///
/// ## Usage
///
/// ```swift
/// private let channel = EventChannel<MyEvent>()
///
/// public var events: AsyncStream<MyEvent> { channel.stream }
///
/// private func emit(_ event: MyEvent) { channel.yield(event) }
///
/// public func shutdown() async { channel.finish() }
/// ```
public final class EventChannel<Element: Sendable>: Sendable {

    private let state: Mutex<ChannelState>
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    private struct ChannelState: Sendable {
        var stream: AsyncStream<Element>?
        var continuation: AsyncStream<Element>.Continuation?
        var isFinished: Bool = false
    }

    /// Creates a new event channel.
    ///
    /// - Parameter bufferingPolicy: The buffering policy for the underlying AsyncStream.
    ///   Defaults to `.unbounded`.
    public init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
        self.state = Mutex(ChannelState())
    }

    // Internal result types for lock-free stream creation
    private enum StreamLookup: Sendable {
        case cached(AsyncStream<Element>)
        case finished
        case needsCreation
    }

    private enum StoreAction: Sendable {
        case stored
        case discard(AsyncStream<Element>)
        case finishImmediately
    }

    /// The event stream (single consumer).
    ///
    /// Returns the same cached stream on repeated calls. After `finish()` has been
    /// called, returns an immediately-terminating stream.
    public var stream: AsyncStream<Element> {
        // Fast path: check for cached stream or finished state
        let lookup: StreamLookup = state.withLock { s in
            if let existing = s.stream { return .cached(existing) }
            if s.isFinished { return .finished }
            return .needsCreation
        }

        switch lookup {
        case .cached(let existing):
            return existing

        case .finished:
            let (stream, continuation) = AsyncStream<Element>.makeStream()
            continuation.finish()
            return stream

        case .needsCreation:
            // Create new stream outside the lock to avoid holding lock during allocation
            let (newStream, newContinuation) = AsyncStream<Element>.makeStream(
                bufferingPolicy: bufferingPolicy
            )

            // Re-lock and store, handling race with concurrent finish() or stream creation
            let action: StoreAction = state.withLock { s in
                // Another caller may have created a stream while we were outside the lock
                if let existing = s.stream {
                    return .discard(existing)
                }
                // finish() was called while we were creating the stream
                if s.isFinished {
                    return .finishImmediately
                }
                s.stream = newStream
                s.continuation = newContinuation
                return .stored
            }

            switch action {
            case .stored:
                return newStream

            case .discard(let existing):
                // Another concurrent caller won the race — discard ours
                newContinuation.finish()
                return existing

            case .finishImmediately:
                // finish() was called between our creation and re-lock
                newContinuation.finish()
                return newStream
            }
        }
    }

    /// Emits an event to the consumer.
    ///
    /// If no stream has been created yet or `finish()` has been called,
    /// the event is silently dropped.
    @discardableResult
    public func yield(_ event: Element) -> AsyncStream<Element>.Continuation.YieldResult? {
        let continuation = state.withLock { $0.continuation }
        return continuation?.yield(event)
    }

    /// Terminates the event stream.
    ///
    /// After this call:
    /// - Any active `for await` loop on the stream will complete
    /// - Future calls to `stream` return an immediately-terminating stream
    /// - Future calls to `yield(_:)` are no-ops
    ///
    /// This method is idempotent — safe to call multiple times.
    public func finish() {
        let continuation = state.withLock { s -> AsyncStream<Element>.Continuation? in
            if s.isFinished { return nil }
            s.isFinished = true
            let cont = s.continuation
            s.continuation = nil
            s.stream = nil
            return cont
        }
        // Call finish() outside the lock to avoid Mutex/AsyncStream interaction
        continuation?.finish()
    }
}
