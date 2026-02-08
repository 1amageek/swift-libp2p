/// BandwidthReporter - Tracks bandwidth usage across the node
///
/// Records bytes in/out per peer and per protocol, with rolling rate calculation.

import Synchronization

/// Bandwidth statistics.
public struct BandwidthStats: Sendable, Equatable {
    /// Total bytes received.
    public var totalBytesIn: UInt64
    /// Total bytes sent.
    public var totalBytesOut: UInt64
    /// Current inbound rate (bytes/sec).
    public var rateIn: Double
    /// Current outbound rate (bytes/sec).
    public var rateOut: Double

    public init(
        totalBytesIn: UInt64 = 0,
        totalBytesOut: UInt64 = 0,
        rateIn: Double = 0,
        rateOut: Double = 0
    ) {
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.rateIn = rateIn
        self.rateOut = rateOut
    }
}

/// Tracks bandwidth usage across the node.
///
/// Thread-safe via `Mutex`. Designed for high-frequency recording from
/// multiple streams simultaneously.
public final class BandwidthReporter: Sendable {

    private let state: Mutex<ReporterState>

    private struct ReporterState: Sendable {
        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0
        var byPeer: [PeerID: PeerBandwidth] = [:]
        var byProtocol: [String: ProtocolBandwidth] = [:]

        // For rate calculation
        var lastRateCalcTime: ContinuousClock.Instant = .now
        var lastBytesIn: UInt64 = 0
        var lastBytesOut: UInt64 = 0
    }

    private struct PeerBandwidth: Sendable {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
    }

    private struct ProtocolBandwidth: Sendable {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
    }

    public init() {
        self.state = Mutex(ReporterState())
    }

    /// Records inbound bytes.
    ///
    /// Negative values are silently ignored (bytes must be positive).
    ///
    /// - Parameters:
    ///   - bytes: Number of bytes received. Must be positive; negative values are ignored.
    ///   - protocol: Optional protocol identifier for per-protocol tracking.
    ///   - peer: Optional peer identifier for per-peer tracking.
    public func recordInbound(bytes: Int, protocol: String? = nil, peer: PeerID? = nil) {
        guard bytes > 0 else { return }
        let count = UInt64(bytes)
        state.withLock { s in
            s.totalBytesIn += count
            if let peer {
                s.byPeer[peer, default: PeerBandwidth()].bytesIn += count
            }
            if let proto = `protocol` {
                s.byProtocol[proto, default: ProtocolBandwidth()].bytesIn += count
            }
        }
    }

    /// Records outbound bytes.
    ///
    /// Negative values are silently ignored (bytes must be positive).
    ///
    /// - Parameters:
    ///   - bytes: Number of bytes sent. Must be positive; negative values are ignored.
    ///   - protocol: Optional protocol identifier for per-protocol tracking.
    ///   - peer: Optional peer identifier for per-peer tracking.
    public func recordOutbound(bytes: Int, protocol: String? = nil, peer: PeerID? = nil) {
        guard bytes > 0 else { return }
        let count = UInt64(bytes)
        state.withLock { s in
            s.totalBytesOut += count
            if let peer {
                s.byPeer[peer, default: PeerBandwidth()].bytesOut += count
            }
            if let proto = `protocol` {
                s.byProtocol[proto, default: ProtocolBandwidth()].bytesOut += count
            }
        }
    }

    /// Returns aggregate bandwidth stats with rate calculation.
    ///
    /// Rate is computed as bytes transferred since the last call to `stats()`,
    /// divided by the elapsed time. The first call returns zero rates.
    public func stats() -> BandwidthStats {
        state.withLock { s in
            let now = ContinuousClock.now
            let elapsed = now - s.lastRateCalcTime
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18

            let rateIn: Double
            let rateOut: Double

            if seconds > 0.001 {
                rateIn = Double(s.totalBytesIn - s.lastBytesIn) / seconds
                rateOut = Double(s.totalBytesOut - s.lastBytesOut) / seconds
                s.lastRateCalcTime = now
                s.lastBytesIn = s.totalBytesIn
                s.lastBytesOut = s.totalBytesOut
            } else {
                rateIn = 0
                rateOut = 0
            }

            return BandwidthStats(
                totalBytesIn: s.totalBytesIn,
                totalBytesOut: s.totalBytesOut,
                rateIn: rateIn,
                rateOut: rateOut
            )
        }
    }

    /// Returns per-peer bandwidth stats.
    ///
    /// Rate fields are zero in per-peer stats (only totals are tracked per peer).
    public func statsByPeer() -> [PeerID: BandwidthStats] {
        state.withLock { s in
            s.byPeer.mapValues { pb in
                BandwidthStats(totalBytesIn: pb.bytesIn, totalBytesOut: pb.bytesOut)
            }
        }
    }

    /// Returns per-protocol bandwidth stats.
    ///
    /// Rate fields are zero in per-protocol stats (only totals are tracked per protocol).
    public func statsByProtocol() -> [String: BandwidthStats] {
        state.withLock { s in
            s.byProtocol.mapValues { pb in
                BandwidthStats(totalBytesIn: pb.bytesIn, totalBytesOut: pb.bytesOut)
            }
        }
    }

    /// Resets all counters.
    public func reset() {
        state.withLock { s in
            s = ReporterState()
        }
    }
}
