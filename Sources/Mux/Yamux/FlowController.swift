/// FlowController - Per-stream flow control with auto-tuning support (B1/B2).
///
/// Implements OnRead mode: window updates are sent when the application reads data,
/// not when data is received. This provides proper backpressure when the consumer
/// is slow.
///
/// Auto-tuning: if the window is consumed within 2x RTT, double it to allow
/// the sender to fully utilize available bandwidth.
import Foundation
import Synchronization

/// Per-stream flow controller with auto-tuning support.
final class FlowController: Sendable {
    private struct State: Sendable {
        /// Current max receive window for this stream.
        var maxReceiveWindow: UInt32
        /// Current receive window (bytes the sender is allowed to send).
        var receiveWindow: UInt32
        /// Buffered but unconsumed bytes.
        var bufferedBytes: UInt32
        /// When the last window update was sent.
        var lastWindowUpdate: ContinuousClock.Instant?
    }

    private let state: Mutex<State>
    private let rtt: RTTEstimator
    private let connectionWindowLimit: UInt32
    private let autoTuneEnabled: Bool

    init(
        initialWindowSize: UInt32,
        rtt: RTTEstimator,
        connectionWindowLimit: UInt32,
        autoTuneEnabled: Bool = true
    ) {
        self.state = Mutex(State(
            maxReceiveWindow: initialWindowSize,
            receiveWindow: initialWindowSize,
            bufferedBytes: 0,
            lastWindowUpdate: nil
        ))
        self.rtt = rtt
        self.connectionWindowLimit = connectionWindowLimit
        self.autoTuneEnabled = autoTuneEnabled
    }

    /// Called when data is received from the network.
    /// Returns false if the receive window was violated.
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

    /// Called when received data is discarded without being delivered to the
    /// application (e.g. the read side was closed via `closeRead()`).
    ///
    /// The bytes were counted against the receive window by `dataReceived`,
    /// but since they are dropped they will never be consumed by `dataConsumed`.
    /// To avoid permanently shrinking the window (which would stall the peer
    /// on a half-closed stream), immediately return the window for the
    /// discarded bytes.
    ///
    /// - Returns: The delta for a window update that restores the discarded
    ///   bytes, or `nil` if there is nothing to restore.
    func dataDiscarded(count: UInt32) -> UInt32? {
        state.withLock { state in
            guard count <= state.bufferedBytes else { return nil }
            state.bufferedBytes -= count
            // Restore exactly the discarded bytes to the receive window.
            // Cap at maxReceiveWindow to preserve the invariant
            // receiveWindow <= maxReceiveWindow.
            let restored = min(count, state.maxReceiveWindow - state.receiveWindow)
            guard restored > 0 else { return nil }
            state.receiveWindow += restored
            return restored
        }
    }

    /// Called when the read side is being closed and any outstanding receive
    /// window must be returned to the peer in a single update.
    ///
    /// This covers bytes that were received but neither consumed nor discarded
    /// individually (e.g. data still sitting in the stream's read buffer when
    /// `closeRead()` clears it). Returning the window prevents a peer that
    /// keeps writing to a half-closed stream from driving the window to zero.
    ///
    /// - Returns: A tuple of:
    ///   - `streamDelta`: the per-stream window-update delta (or `nil` if the
    ///     per-stream window is already full), and
    ///   - `outstandingBytes`: the number of received-but-unconsumed bytes that
    ///     were still counted against the connection budget for this stream.
    func windowForClose() -> (streamDelta: UInt32?, outstandingBytes: UInt32) {
        state.withLock { state in
            // Bytes still held by this stream's buffer = outstanding against
            // the connection budget (received but neither consumed nor
            // discarded yet).
            let outstanding = state.bufferedBytes
            state.bufferedBytes = 0
            let delta = state.maxReceiveWindow - state.receiveWindow
            if delta > 0 {
                state.receiveWindow = state.maxReceiveWindow
                return (delta, outstanding)
            }
            return (nil, outstanding)
        }
    }

    /// Called when the application reads data from the buffer (OnRead mode).
    /// Returns the delta for a window update if one should be sent.
    func dataConsumed(count: UInt32) -> UInt32? {
        state.withLock { state in
            guard count <= state.bufferedBytes else { return nil }
            state.bufferedBytes -= count

            let totalReceived = state.maxReceiveWindow - state.receiveWindow
            let unconsumed = state.bufferedBytes
            let consumed: UInt32
            if totalReceived > unconsumed {
                consumed = totalReceived - unconsumed
            } else {
                consumed = 0
            }

            // Only send update if we've consumed at least half the window
            guard consumed >= state.maxReceiveWindow / 2 else {
                return nil
            }

            // Auto-tune: if window was consumed within 2x RTT, double it
            if autoTuneEnabled, let lastUpdate = state.lastWindowUpdate {
                let elapsed = ContinuousClock.now - lastUpdate
                let currentRTT = rtt.currentRTT
                if let currentRTT, elapsed < currentRTT * 2 {
                    let doubled = UInt64(state.maxReceiveWindow) * 2
                    let newMax = UInt32(min(doubled, UInt64(connectionWindowLimit)))
                    if newMax > state.maxReceiveWindow {
                        state.maxReceiveWindow = newMax
                    }
                }
            }

            let delta = state.maxReceiveWindow - state.receiveWindow
            state.receiveWindow = state.maxReceiveWindow
            state.lastWindowUpdate = .now

            return delta
        }
    }

    /// Drains and returns the bytes still outstanding against the connection
    /// budget for this stream (received but neither consumed nor discarded).
    ///
    /// Used when the stream is abruptly terminated (RST) so the shared
    /// connection window does not leak the dropped buffer. Does not emit a
    /// per-stream window update — the stream is gone.
    ///
    /// - Returns: The outstanding byte count, which the caller returns to the
    ///   connection-level controller.
    func drainOutstanding() -> UInt32 {
        state.withLock { state in
            let outstanding = state.bufferedBytes
            state.bufferedBytes = 0
            return outstanding
        }
    }

    /// Current receive window value.
    var receiveWindow: UInt32 {
        state.withLock { $0.receiveWindow }
    }

    /// Current max receive window (may grow with auto-tuning).
    var maxReceiveWindow: UInt32 {
        state.withLock { $0.maxReceiveWindow }
    }
}

/// Estimates RTT using Yamux Ping/Pong frames.
final class RTTEstimator: Sendable {
    private struct State: Sendable {
        var pendingPings: [UInt32: ContinuousClock.Instant] = [:]
        var currentRTT: Duration?
    }

    private let _state: Mutex<State>

    init() {
        self._state = Mutex(State())
    }

    var currentRTT: Duration? {
        _state.withLock { $0.currentRTT }
    }

    func pingSent(id: UInt32) {
        _state.withLock { $0.pendingPings[id] = .now }
    }

    func pongReceived(id: UInt32) {
        _state.withLock { state in
            guard let sentAt = state.pendingPings.removeValue(forKey: id) else { return }
            // rust-libp2p uses simple last-value, not EWMA
            state.currentRTT = ContinuousClock.now - sentAt
        }
    }

    func clear() {
        _state.withLock { state in
            state.pendingPings.removeAll()
            state.currentRTT = nil
        }
    }
}
