import Foundation
import Synchronization
import P2PCore
import P2PTransportQUIC

/// Certificate store with current/next material for WebTransport certificate rotation.
public final class WebTransportCertificateStore: Sendable {
    private static let certificateValidityDays = 12

    private struct CertificateEntry: Sendable {
        let material: SwiftQUICTLSProvider.CertificateMaterial
        let hash: Data
        let hashMultibase: String
    }

    private struct State: Sendable {
        var current: CertificateEntry
        var next: CertificateEntry
        var nextRotation: ContinuousClock.Instant
        let rotationInterval: Duration
        let localKeyPair: KeyPair
    }

    private let clock = ContinuousClock()
    private let state: Mutex<State>

    public init(localKeyPair: KeyPair, rotationInterval: Duration) throws {
        let now = clock.now
        let current = try Self.makeEntry(localKeyPair: localKeyPair)
        let next = try Self.makeEntry(localKeyPair: localKeyPair)

        self.state = Mutex(State(
            current: current,
            next: next,
            nextRotation: now.advanced(by: rotationInterval),
            rotationInterval: rotationInterval,
            localKeyPair: localKeyPair
        ))
    }

    /// Returns current certificate material, rotating if the interval has elapsed.
    public func currentMaterial() throws -> SwiftQUICTLSProvider.CertificateMaterial {
        try rotateIfNeeded()
        return state.withLock { $0.current.material }
    }

    /// Returns advertised certificate hashes (current + next).
    public func advertisedHashes() throws -> [Data] {
        try rotateIfNeeded()
        return state.withLock { [$0.current.hash, $0.next.hash] }
    }

    /// Returns advertised certificate hashes as multibase strings.
    public func advertisedHashesMultibase() throws -> [String] {
        try rotateIfNeeded()
        return state.withLock { [$0.current.hashMultibase, $0.next.hashMultibase] }
    }

    private func rotateIfNeeded() throws {
        let now = clock.now
        try state.withLock { s in
            guard now >= s.nextRotation else { return }
            let newNext = try Self.makeEntry(localKeyPair: s.localKeyPair)
            s.current = s.next
            s.next = newNext
            s.nextRotation = now.advanced(by: s.rotationInterval)
        }
    }

    private static func makeEntry(localKeyPair: KeyPair) throws -> CertificateEntry {
        let material = try SwiftQUICTLSProvider.generateCertificateMaterial(
            for: localKeyPair,
            validityDays: certificateValidityDays
        )
        let hash = WebTransportCertificateHash.multihashSHA256(for: material.certificateDER)
        let multibase = encodeBase64URL(hash)

        return CertificateEntry(
            material: material,
            hash: hash,
            hashMultibase: multibase
        )
    }

    private static func encodeBase64URL(_ bytes: Data) -> String {
        let base64 = bytes.base64EncodedString()
        let base64url = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "u" + base64url
    }
}
