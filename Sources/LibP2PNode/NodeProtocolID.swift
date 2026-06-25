// NodeProtocolID.swift
// The protocol-id constants for the minimal node's application protocols, used as
// the multistream-select tokens. Embedded-clean: plain `String` constants, no
// Foundation, no `any`. Named by responsibility (no Embedded/Byte qualifier).

/// The multistream-select protocol-id tokens for the node's application protocols.
///
/// These are the exact wire strings negotiated over multistream-select before the
/// matching protocol handler runs on a ``MuxedStream``.
public enum NodeProtocolID {

    /// libp2p ping (`/ipfs/ping/1.0.0`): a 32-byte echo round-trip.
    public static let ping = "/ipfs/ping/1.0.0"

    /// libp2p identify (`/ipfs/id/1.0.0`): a one-shot Identify protobuf exchange.
    public static let identify = "/ipfs/id/1.0.0"
}
