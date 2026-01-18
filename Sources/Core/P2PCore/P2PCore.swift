/// P2PCore - Foundation types for swift-libp2p
///
/// This module provides core types used throughout the libp2p stack:
/// - Identity: PeerID, PublicKey, PrivateKey, KeyPair
/// - Addressing: Multiaddr
/// - Records: SignedEnvelope, PeerRecord
/// - Utilities: Varint, Base58, Multihash

// MARK: - Re-exports

@_exported import Foundation
@_exported import Crypto
@_exported import Logging
