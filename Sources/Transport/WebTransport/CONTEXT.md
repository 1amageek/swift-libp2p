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

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (85/100)
- 対象ターゲット: `P2PTransportWebTransport`
- 実装読解範囲: 14 Swift files / 1810 LOC
- テスト範囲: 1 files / 29 cases / targets 1
- 公開API: types 17 / funcs 21
- 参照網羅率: type 0.59 / func 0.67
- 未参照公開型: 7 件（例: `DeterministicCertificate`, `WebTransportAddressComponents`, `WebTransportCertificateHash`, `WebTransportHost`, `WebTransportMuxedConnection`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 公開型の直接参照テストが薄い

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- API名での直接参照だけでなく、振る舞い検証中心の統合テストを補強する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
