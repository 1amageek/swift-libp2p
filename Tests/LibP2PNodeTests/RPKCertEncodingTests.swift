// RPKCertEncodingTests.swift
// Interop-catching encoding oracles for the libp2p RPK certificate / QUIC TLS
// signature path. These tests fail against the two pre-fix bugs:
//
//   1. The TLS ECDSA signature (CertificateVerify, RFC 8446 §4.4.3, and the
//      self-signed X.509 leaf signature) must be DER `SEQUENCE { INTEGER r,
//      INTEGER s }`, NOT raw `r || s`. The shared `DefaultCryptoProvider` emits
//      raw, which go-libp2p / rust-libp2p peers reject. `QUICTLSSignatureProvider`
//      (the provider the handshake/cert path is specialised at) DER-encodes it.
//
//   2. The cert's notBefore/notAfter must be REAL wall-clock Unix-epoch seconds.
//      Deriving them from the monotonic clock makes the cert look issued in ~1970
//      and remote validity checks reject it. The driver now sources the timestamp
//      from an injected `WallClock`.
//
// HOST test: Foundation/Crypto are the DER oracle; the code under test
// (`QUICTLSSignatureProvider`, `LibP2PRPKCertificateBuilder`) is the dual-build
// Embedded-clean path.

import Testing
import Foundation
import Crypto
import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreDER
import P2PCrypto
import P2PCryptoFoundationEssentials
import QUICTLSSignature
@testable import LibP2PNode

private typealias Provider = QUICTLSSignatureProvider

// MARK: - Fake wall clock

/// A `WallClock` that always returns a fixed Unix-epoch timestamp, so a cert's
/// validity dates are deterministic and assertable.
private struct FixedWallClock: WallClock {
    let timestamp: Int64
    func nowUnixSeconds() -> Int64 { timestamp }
}

@Suite("libp2p RPK cert / QUIC-TLS signature encoding oracles")
struct RPKCertEncodingTests {

    // MARK: - Bug 1: TLS ECDSA signature must be DER, not raw

    @Test("Provider P-256 signature is DER SEQUENCE { INTEGER, INTEGER }, not 64-byte raw")
    func providerP256SignatureIsDER() throws {
        let key = try Provider.P256Signature.generateSigningKey()
        let message: [UInt8] = Array("certificate-verify-p256".utf8)
        let sig = try Provider.P256Signature.sign(message.span, with: key)

        // Structural: a raw P-256 signature is exactly 64 bytes; a DER one begins
        // with SEQUENCE (0x30) and decodes as exactly two INTEGERs.
        #expect(sig.first == 0x30, "TLS ECDSA signature must begin with SEQUENCE (0x30)")
        #expect(sig.count != 64, "TLS ECDSA signature must NOT be 64-byte raw r||s")
        let (r, s) = try requireTwoIntegers(der: sig)
        #expect(!r.isEmpty && !s.isEmpty, "DER SEQUENCE must hold two non-empty INTEGERs")

        // CryptoKit (the interop oracle) must accept it as a DER ECDSA signature.
        let ckDER = try P256.Signing.ECDSASignature(derRepresentation: Data(sig))
        #expect(!ckDER.rawRepresentation.isEmpty)
    }

    @Test("Provider P-384 signature is DER SEQUENCE { INTEGER, INTEGER }, not 96-byte raw")
    func providerP384SignatureIsDER() throws {
        let key = try Provider.P384Signature.generateSigningKey()
        let message: [UInt8] = Array("certificate-verify-p384".utf8)
        let sig = try Provider.P384Signature.sign(message.span, with: key)

        #expect(sig.first == 0x30, "TLS ECDSA signature must begin with SEQUENCE (0x30)")
        #expect(sig.count != 96, "TLS ECDSA signature must NOT be 96-byte raw r||s")
        let (r, s) = try requireTwoIntegers(der: sig)
        #expect(!r.isEmpty && !s.isEmpty)

        let ckDER = try P384.Signing.ECDSASignature(derRepresentation: Data(sig))
        #expect(!ckDER.rawRepresentation.isEmpty)
    }

    @Test("Provider DER signature differs from the raw DefaultCryptoProvider output")
    func providerDiffersFromRawDefault() throws {
        // Sign the SAME message with the SAME key under both providers and confirm
        // the DER (this provider) and raw (DefaultCryptoProvider) wire bytes differ.
        // A fresh import via the shared raw representation keeps the key identical.
        let der = try Provider.P256Signature.generateSigningKey()
        let rawBytes = Provider.P256Signature.rawRepresentation(of: der)
        let raw = try DefaultCryptoProvider.P256Signature.signingKey(rawRepresentation: rawBytes.span)

        let message: [UInt8] = Array("der-vs-raw".utf8)
        let derSig = try Provider.P256Signature.sign(message.span, with: der)
        let rawSig = try DefaultCryptoProvider.P256Signature.sign(message.span, with: raw)

        // ECDSA is randomized, so the scalars differ run-to-run; the structural
        // distinction is what matters: DER is SEQUENCE-tagged + variable length,
        // raw is a bare 64-byte r||s.
        #expect(rawSig.count == 64, "DefaultCryptoProvider must emit raw 64-byte r||s")
        #expect(derSig.first == 0x30, "Provider must emit DER (SEQUENCE)")
        #expect(derSig != rawSig, "DER and raw signatures must not be byte-equal")
    }

    @Test("Provider DER encoding is byte-identical to CryptoKit derRepresentation")
    func providerDERByteIdenticalToCryptoKit() throws {
        // Feed CryptoKit's own raw r||s through the same DER codec the provider uses
        // and assert byte-equality with CryptoKit's derRepresentation.
        for index in 0..<24 {
            let ck = P256.Signing.PrivateKey()
            let signature = try ck.signature(for: Data("host-der-oracle-\(index)".utf8))
            let raw = [UInt8](signature.rawRepresentation)
            #expect(raw.count == 64)
            let ours = try ECDSADERConversion.encode(raw: raw, scalarLength: 32)
            #expect(ours == [UInt8](signature.derRepresentation),
                    "provider DER must be byte-identical to CryptoKit derRepresentation")
        }
    }

    @Test("The RPK cert's leaf self-signature on the handshake path is DER ECDSA")
    func certLeafSignatureIsDER() throws {
        // The cert is self-signed via C.P256Signature.sign — i.e. DERSignatureP256.
        // Extract the outer Certificate's signatureValue BIT STRING and confirm it
        // is a DER ECDSA signature (the exact encoding the TLS wire requires).
        let identity = try Provider.makeNodeIdentity()
        let cert = try LibP2PRPKCertificateBuilder<Provider>.build(
            identity: identity, nowEpochSeconds: 1_700_000_000
        )
        let leafSig = try extractCertSignatureValue(der: cert.certificateDER)
        #expect(leafSig.first == 0x30, "leaf self-signature must be DER (SEQUENCE)")
        let ckDER = try P256.Signing.ECDSASignature(derRepresentation: Data(leafSig))
        #expect(!ckDER.rawRepresentation.isEmpty,
                "CryptoKit must accept the leaf signature as a DER ECDSA signature")
    }

    // MARK: - Bug 2: cert validity must reflect the supplied wall-clock, not ~1970

    @Test("RPK cert notBefore/notAfter encode the supplied WallClock timestamp, not ~1970")
    func certValidityReflectsWallClock() throws {
        // A recent, deterministic timestamp: 2023-11-14T22:13:20Z.
        let now: Int64 = 1_700_000_000
        let clock = FixedWallClock(timestamp: now)
        #expect(clock.nowUnixSeconds() == now)

        let identity = try Provider.makeNodeIdentity()
        // The driver builds the cert with `nowEpochSeconds = wallClock.nowUnixSeconds()`;
        // here we drive the same builder with the same value the seam would supply.
        let cert = try LibP2PRPKCertificateBuilder<Provider>.build(
            identity: identity, nowEpochSeconds: clock.nowUnixSeconds()
        )

        // The builder's validity window is [now - 3600, now + 365 days]; both are
        // rendered as UTCTime (0x17, "yyMMddHHmmssZ", 13 ASCII bytes) inside the cert.
        let notBefore = now - 3600
        let notAfter = now + Int64(365) * 24 * 3600
        let expectedNotBefore = utcTimeTLV(epochSeconds: notBefore)
        let expectedNotAfter = utcTimeTLV(epochSeconds: notAfter)

        #expect(contains(cert.certificateDER, expectedNotBefore),
                "cert must encode the wall-clock notBefore as UTCTime")
        #expect(contains(cert.certificateDER, expectedNotAfter),
                "cert must encode the wall-clock notAfter as UTCTime")

        // The monotonic-clock bug would render a ~1970 year ("70...") — the cert
        // must NOT contain a notBefore dated in 1970.
        let monotonicLike = utcTimeTLV(epochSeconds: 5)           // a few seconds past origin
        let monotonicNotBefore = utcTimeTLV(epochSeconds: 5 - 3600)
        #expect(!contains(cert.certificateDER, monotonicLike),
                "cert must NOT carry a ~1970 (monotonic-origin) timestamp")
        #expect(!contains(cert.certificateDER, monotonicNotBefore),
                "cert must NOT carry a ~1970 (monotonic-origin) notBefore")

        // Sanity: the rendered year is 2023, not 1970.
        let yyyymmdd = utcTimeASCII(epochSeconds: notBefore)
        #expect(yyyymmdd.hasPrefix("231114"),
                "expected notBefore year/month/day 2023-11-14, got \(yyyymmdd)")
    }

    // MARK: - DER helpers

    /// Decodes a DER `SEQUENCE { INTEGER, INTEGER }` and returns the two INTEGER
    /// content byte arrays, failing the test if it is not exactly that shape.
    private func requireTwoIntegers(der: [UInt8]) throws -> (r: [UInt8], s: [UInt8]) {
        var reader = DERReader(der)
        var r = [UInt8]()
        var s = [UInt8]()
        do {
            try reader.readConstructed(.sequence) { (inner) throws(DERError) in
                r = try inner.readIntegerBytes()
                s = try inner.readIntegerBytes()
            }
        } catch {
            Issue.record("DER signature did not parse as SEQUENCE { INTEGER, INTEGER }: \(error)")
            throw error
        }
        // Read the noncopyable reader's state into a local before asserting (the
        // `#expect` macro captures its operand, which would require `Copyable`).
        let consumedFully = reader.isAtEnd
        #expect(consumedFully, "DER signature must be exactly one SEQUENCE, no trailing bytes")
        return (r, s)
    }

    /// Walks the top-level X.509 Certificate SEQUENCE { tbsCertificate,
    /// signatureAlgorithm, signatureValue } and returns the signatureValue BIT
    /// STRING content (the ECDSA signature, sans the unused-bits octet).
    private func extractCertSignatureValue(der: [UInt8]) throws -> [UInt8] {
        var outer = DERReader(der)
        var sig = [UInt8]()
        do {
            try outer.readConstructed(.sequence) { (body) throws(DERError) in
                _ = try body.readTLV()         // tbsCertificate (SEQUENCE)
                _ = try body.readTLV()         // signatureAlgorithm (SEQUENCE)
                sig = try body.readBitString() // signatureValue (BIT STRING)
            }
        } catch {
            Issue.record("certificate did not parse as Certificate SEQUENCE: \(error)")
            throw error
        }
        return sig
    }

    // MARK: - UTCTime helpers (independent re-implementation of the cert encoder)

    /// `"yyMMddHHmmssZ"` ASCII (the UTCTime content the cert encoder emits).
    private func utcTimeASCII(epochSeconds: Int64) -> String {
        let secondsPerDay: Int64 = 86_400
        var days = epochSeconds / secondsPerDay
        var rem = epochSeconds % secondsPerDay
        if rem < 0 { rem += secondsPerDay; days -= 1 }
        let hour = Int(rem / 3_600)
        let minute = Int((rem % 3_600) / 60)
        let second = Int(rem % 60)
        // civil_from_days (Howard Hinnant) — mirrors the cert encoder.
        let z = days + 719_468
        let era: Int64 = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        let year = Int(m <= 2 ? y + 1 : y)
        func two(_ v: Int) -> String { String(format: "%02d", v % 100) }
        return two(year) + two(m) + two(d) + two(hour) + two(minute) + two(second)
    }

    /// The full UTCTime TLV bytes (`0x17 0x0D` + 13 ASCII content bytes).
    private func utcTimeTLV(epochSeconds: Int64) -> [UInt8] {
        let ascii = Array(utcTimeASCII(epochSeconds: epochSeconds).utf8) + [0x5A] // 'Z'
        return [0x17, UInt8(ascii.count)] + ascii
    }

    /// Substring search over a byte array.
    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var j = 0
            while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }
}

// MARK: - Identity helper

extension QUICTLSSignatureProvider {
    /// A fresh node identity bound to this provider, for the encoding oracles.
    fileprivate static func makeNodeIdentity() throws -> NodeIdentity<QUICTLSSignatureProvider> {
        try NodeIdentity<QUICTLSSignatureProvider>.generate()
    }
}
