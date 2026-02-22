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
/// 2. `shutdown()` must call `channel.finish()`
///
/// ## Recommended Pattern
///
/// Use `EventChannel<Element>` to manage stream lifecycle:
///
/// ```swift
/// public final class MyService: EventEmitting, Sendable {
///     private let channel = EventChannel<MyEvent>()
///
///     public var events: AsyncStream<MyEvent> { channel.stream }
///
///     private func emit(_ event: MyEvent) { channel.yield(event) }
///
///     public func shutdown() async {
///         channel.finish()
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
    /// This method must call `channel.finish()` to signal stream completion.
    /// This method must be idempotent - safe to call multiple times.
    func shutdown() async
}
