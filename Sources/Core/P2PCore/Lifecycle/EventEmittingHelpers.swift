/// EventEmittingHelpers - Helper functions for EventEmitting protocol

/// Executes a body with an event emitter, ensuring shutdown is called on exit.
///
/// This helper automatically calls `shutdown()` when the scope exits,
/// whether normally or due to an error.
///
/// ## Example
///
/// ```swift
/// try await withEventEmitter(myService) { service in
///     for await event in service.events {
///         // Process events
///         if case .completed = event { break }
///     }
/// }
/// // shutdown() is automatically called here
/// ```
///
/// - Parameters:
///   - emitter: The event emitter to use
///   - body: The closure to execute with the emitter
/// - Returns: The result of the body closure
/// - Throws: Any error thrown by the body closure
@inlinable
public func withEventEmitter<E: EventEmitting, T>(
    _ emitter: E,
    body: (E) async throws -> T
) async rethrows -> T {
    do {
        let result = try await body(emitter)
        await emitter.shutdown()
        return result
    } catch {
        await emitter.shutdown()
        throw error
    }
}
