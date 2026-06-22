/// PnetConnectionProtector - Bridges PnetProtector to the runtime upgrade pipeline.
///
/// `PnetProtector.protect(_:)` already has the exact shape required by
/// `ConnectionProtector` (a `RawConnection -> RawConnection` transform applied
/// before security negotiation), so this is a structural conformance. Wiring it
/// in causes a configured PSK to run on every dialed/accepted connection before
/// security, and to fail closed if the handshake fails (no unprotected
/// fallback).

import P2PCore
import P2PRuntime
import P2PPnet

extension PnetProtector: ConnectionProtector {}
