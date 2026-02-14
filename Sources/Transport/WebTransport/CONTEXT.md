# WebTransport

WebTransport transport for swift-libp2p, enabling browser-based peers.

## Architecture

WebTransport is built on top of QUIC with HTTP/3, providing:
- **Browser compatibility** via the WebTransport Web API
- **Built-in TLS 1.3 security** (inherited from QUIC)
- **Native stream multiplexing** (inherited from QUIC)
- **Certificate hash verification** for self-signed certificates

```
┌──────────────────────────────────────────────────┐
│  WebTransport Session                             │
├──────────────────────────────────────────────────┤
│  HTTP/3 (CONNECT + Extended CONNECT)              │
├──────────────────────────────────────────────────┤
│  QUIC (TLS 1.3 + Stream Multiplexing)            │
├──────────────────────────────────────────────────┤
│  UDP                                              │
└──────────────────────────────────────────────────┘
```

## Current Status

**Implemented over QUIC with WebTransport-compatible address and certificate semantics.**
Current implementation uses a QUIC stream-based session negotiation shim until
native HTTP/3 Extended CONNECT is available in `swift-quic`.

| Component | Status | Notes |
|-----------|--------|-------|
| Protocol constants | Done | Protocol ID, ALPN, cert hash prefix |
| Error types | Done | All WebTransport-specific errors |
| Configuration | Done | Cert rotation, streams, timeouts |
| Certificate generation | Done | 12-day certificates + SHA-256 multihash |
| Address validation | Done | Strict parser for protocol order and certhash |
| Certificate rotation store | Done | Current/next certificates and advertised hashes |
| Listener address rotation | Done | Background refresh of advertised `/certhash` values |
| ALPN verification | Done | Enforces negotiated ALPN `h3` |
| DNS dial resolution | Done | Resolves `dns`/`dns4`/`dns6` hosts before QUIC dial |
| Secured transport | Done | `dialSecured` / `listenSecured` |
| Certificate hash verification | Done | Client verifies remote leaf cert against `/certhash` |
| Stream mapping | Done | QUIC streams wrapped as WebTransport muxed streams |
| Session negotiation | Done | QUIC stream framed hello/ack handshake |
| Listener shutdown | Done | `close()` shuts down endpoint I/O task |

## Files

| File | Purpose |
|------|---------|
| `WebTransportProtocol.swift` | Protocol constants (ID, ALPN, cert limits) |
| `WebTransportError.swift` | Error type definitions |
| `WebTransportConfiguration.swift` | Transport configuration |
| `WebTransportAddress.swift` | Strict multiaddr parser and certhash utilities |
| `WebTransportCertificateStore.swift` | Rotating certificate material (current/next) |
| `WebTransportSessionNegotiator.swift` | Session negotiation frame protocol |
| `WebTransportQUICPeerInfo.swift` | QUIC peer extraction helpers |
| `WebTransportMuxedConnection.swift` | Muxed connection wrapper over QUIC |
| `WebTransportSecuredListener.swift` | Secured listener for incoming WebTransport peers |
| `DeterministicCerts.swift` | Certificate generation and hash verification |
| `WebTransportConnection.swift` | Legacy connection state abstraction |
| `WebTransportTransport.swift` | Secured transport implementation |

## Multiaddr Format

WebTransport addresses extend QUIC addresses:
- `/ip4/<ip>/udp/<port>/quic-v1/webtransport/certhash/<hash>`
- `/ip6/<ip>/udp/<port>/quic-v1/webtransport/certhash/<hash>`
- `/dns|dns4|dns6/<host>/udp/<port>/quic-v1/webtransport/certhash/<hash>` (dial only)

Multiple certhash components may be present for certificate rotation:
- `/ip4/.../udp/.../quic-v1/webtransport/certhash/<current>/certhash/<next>`

## Certificate Rotation

Browsers require self-signed certificates to be valid for at most 14 days.
The default rotation interval is 12 days (2-day buffer for clock skew).

During rotation, the server advertises both current and next certificate
hashes in its multiaddr so that clients can connect during the transition.

## Dependencies

```
WebTransport
├── P2PCore (PeerID, Multiaddr, KeyPair)
├── Crypto (SHA-256 hashing)
└── Synchronization (Mutex)
```

## Future Work

When HTTP/3 support is available in swift-quic:
1. Replace QUIC stream handshake shim with native HTTP/3 Extended CONNECT
2. Add WebTransport datagram support
3. Add browser interop tests (Go/Rust/Web)

## References

- [WebTransport Specification](https://www.w3.org/TR/webtransport/)
- [libp2p WebTransport](https://github.com/libp2p/specs/tree/master/webtransport)
- [RFC 9220: Bootstrapping WebSockets with HTTP/3](https://www.rfc-editor.org/rfc/rfc9220)
- [draft-ietf-webtrans-http3: WebTransport over HTTP/3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
