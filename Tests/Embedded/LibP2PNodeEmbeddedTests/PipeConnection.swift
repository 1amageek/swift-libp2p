// PipeConnection.swift
// Host-only test support: a pair of in-memory `EmbeddedRawConnection`s wired back
// to back, so a dialer and a listener exchange `[UInt8]` in-process. This lets the
// Embedded data path (Noise → Yamux → multistream-select) round-trip without any
// real transport. Host test target — Foundation / Mutex are fine here.

import Foundation
import Synchronization
import LibP2PNodeEmbedded

/// One end of an in-memory byte pipe conforming to `EmbeddedRawConnection`.
///
/// Writes go to the peer's inbound queue; reads drain this end's inbound queue,
/// suspending until bytes arrive (or the pipe closes → empty / closed error).
final class PipeConnection: EmbeddedRawConnection, Sendable {

    private struct State {
        var inbound: [[UInt8]] = []
        var readWaiter: CheckedContinuation<[UInt8], Never>?
        var closed = false
    }

    private let state = Mutex(State())
    // The peer end; set once after both ends are created.
    private let peer = Mutex<PipeConnection?>(nil)

    init() {}

    /// Wires two fresh ends together.
    static func makePair() -> (PipeConnection, PipeConnection) {
        let a = PipeConnection()
        let b = PipeConnection()
        a.peer.withLock { $0 = b }
        b.peer.withLock { $0 = a }
        return (a, b)
    }

    /// Delivers bytes from the peer into this end's inbound queue.
    private func deliver(_ bytes: [UInt8]) {
        let waiter: CheckedContinuation<[UInt8], Never>? = state.withLock { s in
            if let w = s.readWaiter {
                s.readWaiter = nil
                return w
            }
            s.inbound.append(bytes)
            return nil
        }
        waiter?.resume(returning: bytes)
    }

    func read() async throws(EmbeddedNodeError) -> [UInt8] {
        // Fast path: buffered or closed.
        enum Fast { case bytes([UInt8]); case eof; case park }
        let fast: Fast = state.withLock { s in
            if !s.inbound.isEmpty {
                return .bytes(s.inbound.removeFirst())
            }
            if s.closed {
                return .eof
            }
            return .park
        }
        switch fast {
        case .bytes(let b): return b
        case .eof: return []
        case .park:
            break
        }
        let result: [UInt8] = await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            let immediate: [UInt8]?? = state.withLock { s in
                if !s.inbound.isEmpty {
                    return .some(s.inbound.removeFirst())
                }
                if s.closed {
                    return .some(nil)   // closed → wake with empty
                }
                s.readWaiter = cont
                return nil
            }
            if let immediate {
                cont.resume(returning: immediate ?? [])
            }
        }
        return result
    }

    func write(_ data: [UInt8]) async throws(EmbeddedNodeError) {
        let isClosed = state.withLock { $0.closed }
        if isClosed { throw .connectionClosed }
        guard let peerEnd = peer.withLock({ $0 }) else {
            throw .transportFailure
        }
        peerEnd.deliver(data)
    }

    func close() async {
        let waiter: CheckedContinuation<[UInt8], Never>? = state.withLock { s in
            s.closed = true
            let w = s.readWaiter
            s.readWaiter = nil
            return w
        }
        waiter?.resume(returning: [])
    }
}
