/// MplexAcceptCancellationTests - Regression tests for `acceptStream()` cancellation safety.
///
/// The original `acceptStream()` parked its continuation in `pendingAccepts`
/// with no `withTaskCancellationHandler`. A task cancelled while parked (with the
/// connection still open) was never resumed: the caller hung forever and the
/// continuation leaked. These tests pin the fix — a cancelled-while-parked
/// acceptor throws `CancellationError` promptly (distinct from a real stream and
/// from `connectionClosed`), its slot is removed, and a still-waiting acceptor
/// receives the next inbound stream in its place.
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PMuxMplex

@Suite("MplexAccept Cancellation Tests", .serialized)
struct MplexAcceptCancellationTests {

    private func createTestConnection(
        isInitiator: Bool = true,
        configuration: MplexConfiguration = MplexConfiguration()
    ) -> (MplexConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = MplexConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: isInitiator,
            configuration: configuration
        )
        return (connection, mock)
    }

    /// Awaits `operation` but fails (rather than hanging) if it does not finish
    /// within `timeout`. Used so a regression (the never-resume hang) surfaces as
    /// a prompt failure instead of stalling until the suite-level time limit.
    private func withDeadline<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () async -> Void = {},
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await onTimeout()
                throw DeadlineError.timedOut
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private enum DeadlineError: Error { case timedOut }

    private func waitForPendingAccepts(
        _ expectedCount: Int,
        in connection: MplexConnection,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while connection.pendingAcceptCountForTesting < expectedCount {
            if start.duration(to: clock.now) >= timeout {
                throw DeadlineError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func closeForDeadline(_ connection: MplexConnection) async {
        do {
            try await connection.close()
        } catch {
            Issue.record("deadline cleanup failed: \(error)")
        }
    }

    /// A task cancelled while parked in `acceptStream()` (connection still open)
    /// throws `CancellationError` promptly and frees its slot, while a second,
    /// still-parked acceptor receives the next inbound stream — proving the
    /// cancelled waiter was removed and a real stream is never mis-delivered to it.
    @Test("Cancelled accept throws promptly, freeing the slot for a still-waiting acceptor", .timeLimit(.minutes(1)))
    func cancelledAcceptThrowsAndFreesSlot() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // First acceptor: this is the one we cancel while parked.
        let cancelledAccept = Task { () -> MuxedStream in
            try await connection.acceptStream()
        }

        // Second acceptor: parked behind the first, must receive the inbound
        // stream after the first is cancelled (FIFO ordering by waiter id).
        let survivingAccept = Task { () -> MuxedStream in
            try await connection.acceptStream()
        }

        try await waitForPendingAccepts(2, in: connection)

        // Cancel the first acceptor, then immediately inject a stream. The
        // cancellation handler must have removed the first waiter before
        // `cancel()` returns, otherwise this stream can be mis-delivered to the
        // cancelled task.
        cancelledAccept.cancel()
        mock.injectInbound(MplexFrame.newStream(id: 10).encode())

        await #expect(throws: CancellationError.self) {
            _ = try await self.withDeadline(.seconds(5), onTimeout: {
                await Self.closeForDeadline(connection)
            }) {
                try await cancelledAccept.value
            }
        }

        // The connection is still open (the cancel did not close it).
        #expect(mock.wasClosed == false)

        let delivered = try await withDeadline(.seconds(5), onTimeout: {
            await Self.closeForDeadline(connection)
        }) {
            try await survivingAccept.value
        }
        #expect(delivered.id == 10)

        try await connection.close()
    }

    /// A task already cancelled before it reaches the parking point still throws
    /// `CancellationError` rather than registering a waiter that would later be
    /// resumed in place of a real acceptor (the `Task.isCancelled` fast path).
    @Test("Already-cancelled accept throws without registering a waiter", .timeLimit(.minutes(1)))
    func alreadyCancelledAcceptThrows() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let preCancelled = Task { () -> MuxedStream in
            // Cancel ourselves before touching the connection so the fast path
            // inside the continuation runs.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.acceptStream()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await self.withDeadline(.seconds(5), onTimeout: {
                await Self.closeForDeadline(connection)
            }) {
                try await preCancelled.value
            }
        }

        // A real acceptor that parks afterward must still receive an inbound
        // stream — the fast-path waiter did not consume it.
        let realAccept = Task { () -> MuxedStream in
            try await connection.acceptStream()
        }
        try await waitForPendingAccepts(1, in: connection)

        mock.injectInbound(MplexFrame.newStream(id: 10).encode())

        let delivered = try await withDeadline(.seconds(5), onTimeout: {
            await Self.closeForDeadline(connection)
        }) {
            try await realAccept.value
        }
        #expect(delivered.id == 10)

        try await connection.close()
    }

    /// Closing the connection while an accept is parked still resumes the parked
    /// acceptor with `connectionClosed` — the id-keyed drain on shutdown is
    /// intact and is distinguishable from a cancellation.
    @Test("Close resumes a parked accept with connectionClosed (shutdown drain intact)", .timeLimit(.minutes(1)))
    func closeResumesParkedAcceptWithConnectionClosed() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let parkedAccept = Task { () -> MuxedStream in
            try await connection.acceptStream()
        }
        try await waitForPendingAccepts(1, in: connection)

        try await connection.close()

        do {
            _ = try await withDeadline(.seconds(5), onTimeout: {
                await Self.closeForDeadline(connection)
            }) {
                try await parkedAccept.value
            }
            Issue.record("parked accept should not return a stream after close")
        } catch let error as MplexError {
            // Distinguishable from CancellationError: a clean close reports
            // connectionClosed, not cancellation.
            switch error {
            case .connectionClosed:
                break
            default:
                Issue.record("expected MplexError.connectionClosed, got \(error)")
            }
        } catch {
            Issue.record("expected MplexError.connectionClosed, got \(error)")
        }
    }
}
