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
