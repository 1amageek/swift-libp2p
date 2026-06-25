// QUICConnectionParameters.swift
// The connection-parameter template the `Node` facade uses to build a
// `QUICConnectionEngineConfiguration` for each dial / accept. It carries the QUIC
// transport-parameter limits and the per-connection idle/ack/path timeouts; the
// per-connection connection IDs are supplied through the injected `ConnectionIDPlan`
// seam so the facade never spells `ConnectionID.random` directly (Embedded-clean:
// the CSPRNG that mints CIDs is the same crypto seam the node already carries).
//
// WHY A SEAM: on the QUIC path a SERVER derives its Initial-packet keys from the
// dialer's *original destination connection ID* (RFC 9001 §5.2). The minimal node's
// `QUICEngineClient` facade needs that value at construction — it has no
// inbound-packet-peek primitive to learn it after the first Initial arrives. The
// `ConnectionIDPlan` is therefore the single place where the dial side's chosen DCID
// is made available to the listen side; a deployment that demuxes arbitrary unknown
// dialers needs a server-accept primitive that this slice does not yet expose (noted
// as out-of-scope, never silently mis-handled).
//
// Embedded-clean: `[UInt8]`/`UInt64` currency, no `any`, no Foundation, typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task
import QUICConnectionCore        // TransportParametersCore
import QUICConnectionEngineCore  // QUICConnectionEngineConfiguration / QUICEngineRole
import QUICWire                  // ConnectionID / QUICVersion
import P2PCrypto                 // DefaultCryptoProvider

/// The connection IDs a single QUIC connection needs, minted per dial / accept.
///
/// `localConnectionID` is this side's source CID; `peerConnectionID` is the CID this
/// side addresses its first packets to; `originalDestinationConnectionID` is the
/// dialer's first-chosen DCID, from which BOTH peers derive matching Initial keys.
/// On a dial, `local`/`peer`/`originalDestination` are all this dialer's own choice
/// (`peer == originalDestination`); on an accept, `originalDestination` MUST equal
/// the dialer's chosen DCID (see file header).
public struct ConnectionIDs: Sendable {

    public let localConnectionID: ConnectionID
    public let peerConnectionID: ConnectionID
    public let originalDestinationConnectionID: ConnectionID

    public init(
        localConnectionID: ConnectionID,
        peerConnectionID: ConnectionID,
        originalDestinationConnectionID: ConnectionID
    ) {
        self.localConnectionID = localConnectionID
        self.peerConnectionID = peerConnectionID
        self.originalDestinationConnectionID = originalDestinationConnectionID
    }
}

/// Supplies the per-connection ``ConnectionIDs`` for a dial / accept.
///
/// Monomorphic (no `any`): the node is generic over the concrete plan. A live node
/// mints fresh random CIDs from the crypto seam on dial and learns the dialer's DCID
/// from a server-demux primitive on accept; the 2-node loopback test injects a plan
/// that hands both sides matching CIDs deterministically.
public protocol ConnectionIDPlan: Sendable {

    /// CIDs for a new outbound (dial) connection: the dialer freely chooses all
    /// three (`peer == originalDestination`, its own random first DCID).
    ///
    /// - Throws: ``NodeError/quicFeatureUnsupported`` if CIDs cannot be minted.
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs

    /// CIDs for an accepted (listen) connection. `originalDestination` MUST be the
    /// dialer's chosen DCID so the server's Initial keys match (see file header).
    ///
    /// - Throws: ``NodeError/quicFeatureUnsupported`` if CIDs cannot be supplied.
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs
}

/// The QUIC transport-parameter + timeout template shared by every connection the
/// node builds. The connection IDs come from the injected ``ConnectionIDPlan``.
public struct QUICConnectionParameters: Sendable {

    /// The local QUIC transport parameters (stream/flow limits) advertised on every
    /// connection.
    public let transportParameters: TransportParametersCore

    /// The QUIC version negotiated (v1).
    public let version: QUICVersion

    /// The maximum datagram size in bytes.
    public let maxDatagramSize: Int

    /// The connection idle-timeout in nanoseconds.
    public let idleTimeoutNanos: UInt64

    /// The max-ack-delay in nanoseconds.
    public let maxAckDelayNanos: UInt64

    /// The path-validation timeout in nanoseconds.
    public let pathValidationTimeoutNanos: UInt64

    public init(
        transportParameters: TransportParametersCore,
        version: QUICVersion = .v1,
        maxDatagramSize: Int = 1200,
        idleTimeoutNanos: UInt64 = 30_000_000_000,
        maxAckDelayNanos: UInt64 = 25_000_000,
        pathValidationTimeoutNanos: UInt64 = 3_000_000_000
    ) {
        self.transportParameters = transportParameters
        self.version = version
        self.maxDatagramSize = maxDatagramSize
        self.idleTimeoutNanos = idleTimeoutNanos
        self.maxAckDelayNanos = maxAckDelayNanos
        self.pathValidationTimeoutNanos = pathValidationTimeoutNanos
    }

    /// A sane default template for the minimal node: 1 MiB connection data, 256 KiB
    /// per-stream, 100 bidi/uni streams — enough for ping + identify + a few app
    /// streams without an unbounded buffer.
    public static func defaultParameters() -> QUICConnectionParameters {
        var tp = TransportParametersCore()
        tp.initialMaxData = 1_000_000
        tp.initialMaxStreamDataBidiLocal = 256 * 1024
        tp.initialMaxStreamDataBidiRemote = 256 * 1024
        tp.initialMaxStreamDataUni = 256 * 1024
        tp.initialMaxStreamsBidi = 100
        tp.initialMaxStreamsUni = 100
        return QUICConnectionParameters(transportParameters: tp)
    }

    /// Assembles a ``QUICConnectionEngineConfiguration`` for `role` from this
    /// template and the supplied `connectionIDs`.
    func configuration(
        role: QUICEngineRole,
        connectionIDs: ConnectionIDs
    ) -> QUICConnectionEngineConfiguration<DefaultCryptoProvider> {
        QUICConnectionEngineConfiguration<DefaultCryptoProvider>(
            role: role,
            version: version,
            localConnectionID: connectionIDs.localConnectionID,
            initialPeerConnectionID: connectionIDs.peerConnectionID,
            originalDestinationConnectionID: connectionIDs.originalDestinationConnectionID,
            localTransportParameters: transportParameters,
            maxDatagramSize: maxDatagramSize,
            idleTimeoutNanos: idleTimeoutNanos,
            maxAckDelayNanos: maxAckDelayNanos,
            pathValidationTimeoutNanos: pathValidationTimeoutNanos
        )
    }
}
