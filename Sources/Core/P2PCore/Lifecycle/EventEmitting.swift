/// EventEmitting - Protocol for components that expose event streams
///
/// This protocol ensures that all components exposing AsyncStream events
/// implement proper shutdown semantics to prevent stream hangs.

/// Protocol for components that expose event streams.
///
/// Classes conforming to this protocol must implement the `shutdown()` method
/// to properly terminate internal AsyncStreams.
///
/// ## Implementation Requirements
///
/// 1. `shutdown()` must be idempotent (safe to call multiple times)
/// 2. `shutdown()` must call `continuation.finish()`
/// 3. `shutdown()` must set `continuation` and `stream` to `nil`
///
/// ## Recommended Pattern
///
/// ```swift
/// public final class MyService: EventEmitting, Sendable {
///     private let eventState = Mutex<EventState>(EventState())
///
///     private struct EventState: Sendable {
///         var stream: AsyncStream<MyEvent>?
///         var continuation: AsyncStream<MyEvent>.Continuation?
///     }
///
///     public var events: AsyncStream<MyEvent> {
///         eventState.withLock { state in
///             if let existing = state.stream { return existing }
///             let (stream, continuation) = AsyncStream<MyEvent>.makeStream()
///             state.stream = stream
///             state.continuation = continuation
///             return stream
///         }
///     }
///
///     public func shutdown() {
///         eventState.withLock { state in
///             state.continuation?.finish()
///             state.continuation = nil
///             state.stream = nil
///         }
///     }
/// }
/// ```
///
/// ## Why This Matters
///
/// Without proper `shutdown()` implementation:
/// - `for await event in service.events` will hang forever
/// - Tests will timeout waiting for stream completion
/// - Resources won't be released properly
public protocol EventEmitting: Sendable {
    /// Terminates the event stream and releases resources.
    ///
    /// This method must:
    /// - Call `continuation.finish()` to signal stream completion
    /// - Set `continuation` to `nil` to prevent further emissions
    /// - Set `stream` to `nil` to allow re-creation if needed
    ///
    /// This method must be idempotent - safe to call multiple times.
    func shutdown()
}
