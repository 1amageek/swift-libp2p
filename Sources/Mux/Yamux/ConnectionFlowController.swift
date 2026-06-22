/// ConnectionFlowController - Connection-level (session) flow control for Yamux.
///
/// The per-stream `FlowController` bounds how much a single stream may buffer,
/// but the aggregate across all streams (up to `maxConcurrentStreams` streams,
/// each with its own window) can far exceed the session read buffer. Without a
/// shared budget, a peer can pin memory by spreading data across many streams.
///
/// This controller maintains a single receive window shared by every stream on
/// the connection. Inbound data consumes from it; consumed or discarded bytes
/// return to it via a stream-ID-0 window update (the Yamux session window). The
/// budget is the real backpressure signal to the peer for aggregate in-flight
/// data, mirroring the per-stream OnRead model at the connection level.
import Foundation
import Synchronization

/// Connection-level receive flow controller.
///
/// Thread-safe via `Mutex`. All accounting is in bytes against a fixed maximum
/// (`maxReceiveWindow`); unlike the per-stream controller this window does not
/// auto-tune, because it is a hard aggregate cap, not a throughput optimizer.
final class ConnectionFlowController: Sendable {
    private struct State: Sendable {
        /// Remaining connection receive window (bytes the peer is allowed to
        /// send across all streams before a window update is required).
        var receiveWindow: UInt32
        /// Bytes received but not yet consumed or discarded by the application.
        var bufferedBytes: UInt32
    }

    /// Hard upper bound on the aggregate receive window.
    let maxReceiveWindow: UInt32

    private let state: Mutex<State>

    init(maxReceiveWindow: UInt32) {
        self.maxReceiveWindow = maxReceiveWindow
        self.state = Mutex(State(receiveWindow: maxReceiveWindow, bufferedBytes: 0))
    }

    /// Called when data is received from the network for any stream.
    ///
    /// - Returns: `true` if the data fits within the remaining connection
    ///   window, `false` if it would exceed the granted budget (a protocol
    ///   violation by the peer).
    func dataReceived(count: UInt32) -> Bool {
        state.withLock { state in
            guard count <= state.receiveWindow else {
                return false
            }
            state.receiveWindow -= count
            state.bufferedBytes += count
            return true
        }
    }

    /// Called when the application consumes data from a stream's buffer.
    ///
    /// Uses the same half-window threshold as the per-stream controller to
    /// avoid sending a window update for every read.
    ///
    /// - Returns: The delta for a stream-0 window update if one should be sent.
    func dataConsumed(count: UInt32) -> UInt32? {
        state.withLock { state -> UInt32? in
            guard count <= state.bufferedBytes else { return nil }
            state.bufferedBytes -= count

            // Bytes freed (received-and-then-consumed) relative to the max.
            let totalReceived = maxReceiveWindow - state.receiveWindow
            let freed = totalReceived > state.bufferedBytes
                ? totalReceived - state.bufferedBytes
                : 0

            // Send an update once at least half the window has been freed.
            guard freed >= maxReceiveWindow / 2 else { return nil }

            let delta = maxReceiveWindow - state.receiveWindow
            guard delta > 0 else { return nil }
            state.receiveWindow = maxReceiveWindow
            return delta
        }
    }

    /// Called when received data is discarded without delivery (read side
    /// closed). Returns the discarded bytes to the window immediately so a
    /// half-closed stream cannot drain the shared budget.
    ///
    /// - Returns: The delta for a stream-0 window update, or `nil`.
    func dataDiscarded(count: UInt32) -> UInt32? {
        state.withLock { state in
            guard count <= state.bufferedBytes else { return nil }
            state.bufferedBytes -= count
            let restored = min(count, maxReceiveWindow - state.receiveWindow)
            guard restored > 0 else { return nil }
            state.receiveWindow += restored
            return restored
        }
    }

    /// Current remaining receive window (for testing/diagnostics).
    var receiveWindow: UInt32 {
        state.withLock { $0.receiveWindow }
    }
}
