# Interop Tests Known Issues

## 概要

このドキュメントはswift-libp2pとgo-libp2p/rust-libp2p間の相互運用テストで発見された問題を記録します。

---

## Issue #1: go-libp2p Identifyテストのタイムアウト

### ステータス
**解決済み** - 2026-02-05

### 影響を受けたテスト
- `GoLibp2pInteropTests/identifyGo`
- `GoLibp2pInteropTests/verifyGoPeerID`

### 症状
テストが120秒でタイムアウトしていた。接続とプロトコルネゴシエーションは成功するが、Identifyレスポンスの読み取りでハングしていた。

### 根本原因
**go-libp2pとrust-libp2pのパケット送信動作の違い**

#### go-libp2pの動作
プロトコル確認とIdentifyレスポンスを**同じパケットで送信**する:
```
[GO] Read 413 bytes: 0F 2F 69 70 66 73 2F 69 64 2F 31 2E 30 2E 30 0A 8B 03 0A 24 08 01 12 20 ...
                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^
                     Protocol confirmation: /ipfs/id/1.0.0\n          Identify protobuf
```

#### rust-libp2pの動作
プロトコル確認とIdentifyレスポンスを**別々のパケットで送信**する。

### 解決策

`MultistreamSelect.negotiate()`はすでに`NegotiationResult.remainder`で余分に読み取ったデータを返していた。テストコードがこれを使用していなかったため、修正した。

**修正前:**
```swift
let negotiationResult = try await MultistreamSelect.negotiate(...)

// Wait for identify response
try await Task.sleep(for: .seconds(1))
let data = try await stream.read()  // ← ブロック！データはすでに読み取られている
let bytes = Data(buffer: data)
```

**修正後:**
```swift
let negotiationResult = try await MultistreamSelect.negotiate(...)

// Use remainder from negotiation if available (go-libp2p sends protocol confirmation
// and identify response in the same packet), otherwise read from stream
let bytes: Data
if !negotiationResult.remainder.isEmpty {
    bytes = negotiationResult.remainder
} else {
    try await Task.sleep(for: .seconds(1))
    let data = try await stream.read()
    bytes = Data(buffer: data)
}
```

### 修正されたファイル
- `Tests/Interop/GoLibp2pInteropTests.swift`

---

## Issue #2: TCP + Noise ハンドシェイク失敗

### ステータス
**解決済み** - 2026-02-05

### 影響を受けたテスト
- `TCPInteropTests/connectToGoViaTCP`
- `TCPInteropTests/tcpWithYamuxMuxing`
- `TCPInteropTests/identifyGoViaTCP`
- `TCPInteropTests/pingGoViaTCP`
- `NoiseInteropTests/*` (全テスト)
- `YamuxInteropTests/*` (全テスト)

### 症状
TCP接続は正常に確立されるが、Noiseハンドシェイク中に`authenticationFailure`エラーが発生。

```
[TCP] Raw connection established
[TCP] Security protocol negotiated: /noise
authenticationFailure  ← ChaCha20-Poly1305 認証タグ検証失敗
```

### 根本原因
**Noise プロトコル仕様に対する理解の誤り**

Noise Protocol Framework の仕様では、`WriteMessage` / `ReadMessage` は**常に**ペイロードに対して `EncryptAndHash` / `DecryptAndHash` を呼び出す必要がある。ペイロードが空であっても、この呼び出しは必須である。

Message A では libp2p-noise はペイロードを送信しないが、空のペイロードに対する `encryptAndHash(empty)` / `decryptAndHash(empty)` の呼び出しが必要だった。この呼び出しにより `mixHash(empty)` が実行され、handshakeHash が変化する:

```
SHA256(h || empty) ≠ h
```

Swift 実装ではこの呼び出しが欠落していたため、後続の Message B の復号で handshakeHash が go-libp2p / rust-libp2p と一致せず、認証タグ検証に失敗していた。

### 解決策

`NoiseHandshake.swift` の Message A 処理に空ペイロードの暗号化/復号呼び出しを追加:

**writeMessageA() (Initiator):**
```swift
mutating func writeMessageA() -> Data {
    let ephemeralPub = Data(localEphemeralKey.publicKey.rawRepresentation)
    symmetricState.mixHash(ephemeralPub)

    // Per Noise spec, WriteMessage always calls EncryptAndHash on the payload.
    // For message A, there's no payload (empty), but we still need to call
    // encryptAndHash(empty) which does mixHash(empty ciphertext).
    _ = try? symmetricState.encryptAndHash(Data())  // ← 追加

    return ephemeralPub
}
```

**readMessageA() (Responder):**
```swift
mutating func readMessageA(_ message: Data) throws {
    // ... ephemeral key parsing ...
    symmetricState.mixHash(remoteEphemeralData)

    // Per Noise spec, ReadMessage always calls DecryptAndHash on remaining bytes.
    // For message A, the remaining bytes are empty (no payload), but we still need
    // to call decryptAndHash(empty) which does mixHash(empty ciphertext).
    let remainingBytes = Data(message.dropFirst(noisePublicKeySize))
    _ = try symmetricState.decryptAndHash(remainingBytes)  // ← 追加
}
```

### 修正されたファイル
- `Sources/Security/Noise/NoiseHandshake.swift` - Message A での空ペイロード処理を追加

### 検証結果
- go-libp2p TCP + Noise: ✅ パス
- rust-libp2p TCP + Noise: ✅ パス
- Swift 同士 Noise ハンドシェイク: ✅ パス (16テスト)

### 学んだ教訓
1. Noise Protocol 仕様を正確に理解することが重要
2. `WriteMessage` / `ReadMessage` は常にペイロード（空でも）を処理する
3. 公式テストベクトル（cacophony）を使用した検証が有効

---

## テスト結果サマリー (2026-02-05)

### QUIC Transport (TLS 1.3)

| 実装 | テスト | 結果 |
|------|--------|------|
| rust-libp2p | Connect | ✅ |
| rust-libp2p | Identify | ✅ |
| rust-libp2p | Verify PeerID | ✅ |
| rust-libp2p | Ping | ✅ |
| rust-libp2p | Multiple Pings | ✅ |
| rust-libp2p | Bidirectional | ✅ |
| rust-libp2p | Send Raw Data | ✅ |
| go-libp2p | Connect | ✅ |
| go-libp2p | Identify | ✅ |
| go-libp2p | Verify PeerID | ✅ |
| go-libp2p | Ping | ✅ |
| go-libp2p | Multiple Pings | ✅ |
| go-libp2p | Bidirectional | ✅ |
| go-libp2p | Send Raw Data | ✅ |

**QUIC: 全14テスト成功**

### TCP Transport (Noise)

| 実装 | テスト | 結果 |
|------|--------|------|
| go-libp2p | Connect via TCP | ✅ |
| go-libp2p | TCP + Yamux | ✅ |
| go-libp2p | Identify via TCP | ✅ |
| go-libp2p | Ping via TCP | ✅ |
| rust-libp2p | Connect via TCP | ✅ |

**TCP: 全テスト成功** (Issue #2 解決済み)

### WebSocket Transport (Noise)

| 実装 | テスト | 結果 |
|------|--------|------|
| go-libp2p | Connect via WebSocket | ✅ |
| go-libp2p | WebSocket + Yamux | ✅ |
| go-libp2p | Identify via WebSocket | ✅ |
| go-libp2p | Ping via WebSocket | ✅ |

**WebSocket: 全4テスト成功** (Issue #3 解決済み)

---

## Issue #3: WebSocket アップグレード失敗

### ステータス
**解決済み** - 2026-02-05

### 影響を受けたテスト
- `WebSocketInteropTests/connectToGoViaWS`
- `WebSocketInteropTests/wsWithYamuxMuxing`
- `WebSocketInteropTests/identifyGoViaWS`
- `WebSocketInteropTests/pingGoViaWS`

### 症状
WebSocket 接続で `upgradeFailed` エラーが発生。go-libp2p ノードは正常に起動しているが、HTTP → WebSocket アップグレードが完了しない。

```
[WS] Node info: ...
upgradeFailed  ← HTTP アップグレード失敗
```

### 根本原因
**HTTP/1.1 の Host ヘッダー欠落**

Swift NIO の WebSocket クライアント実装で、HTTP リクエストに `Host` ヘッダーが含まれていなかった。HTTP/1.1 では `Host` ヘッダーは必須であり、go-libp2p の WebSocket サーバー（gorilla/websocket ベース）はこれを要求する。

### 解決策

`WebSocketTransport.swift` の `dial()` メソッドで、HTTP リクエストに `Host` ヘッダーを追加:

**修正前:**
```swift
var headers = HTTPHeaders()
headers.add(name: "Content-Length", value: "0")

let requestHead = HTTPRequestHead(
    version: .http1_1,
    method: .GET,
    uri: "/",
    headers: headers
)
```

**修正後:**
```swift
var headers = HTTPHeaders()
headers.add(name: "Host", value: "\(host):\(port)")
headers.add(name: "Content-Length", value: "0")

let requestHead = HTTPRequestHead(
    version: .http1_1,
    method: .GET,
    uri: "/",
    headers: headers
)
```

### 修正されたファイル
- `Sources/Transport/WebSocket/WebSocketTransport.swift` - Host ヘッダーを追加

### 検証結果
- go-libp2p WebSocket + Noise + Yamux: ✅ 全4テストパス
- Swift WebSocket 単体テスト: ✅ 全15テストパス（既存テストに影響なし）

### 学んだ教訓
1. HTTP/1.1 では `Host` ヘッダーは必須（RFC 7230）
2. 外部実装との相互運用テストで暗黙の仮定が明らかになる

---

## 機能追加: WSS (Secure WebSocket) サポート

### ステータス
**実装完了** - 2026-02-05

### 概要
`WebSocketTransport` に WSS（TLS + WebSocket）サポートを追加。swift-nio-ssl を使用した標準的な WSS 実装。

### サポートする Multiaddr フォーマット
- `/ip4/<host>/tcp/<port>/ws` - 非セキュア WebSocket
- `/ip4/<host>/tcp/<port>/wss` - セキュア WebSocket (TLS)
- `/ip4/<host>/tcp/<port>/tls/ws` - TLS + WebSocket（代替フォーマット）

### 実装詳細

#### アーキテクチャ
標準 WSS スタック: `TCP → TLS → HTTP → WebSocket`

NIO パイプライン:
```
[NIOSSLClientHandler] → [HTTP Client Upgrade] → [WebSocket Frame Handler]
```

#### 主な変更点

**Package.swift:**
```swift
.target(
    name: "P2PTransportWebSocket",
    dependencies: [
        // ... existing dependencies ...
        .product(name: "NIOSSL", package: "swift-nio-ssl"),  // 追加
    ],
)
```

**WebSocketTransport.swift:**
```swift
public var protocols: [[String]] {
    [
        ["ip4", "tcp", "ws"],
        ["ip6", "tcp", "ws"],
        ["ip4", "tcp", "wss"],       // 追加
        ["ip6", "tcp", "wss"],       // 追加
        ["ip4", "tcp", "tls", "ws"], // 追加
        ["ip6", "tcp", "tls", "ws"], // 追加
    ]
}

private func dialSecure(host: String, port: UInt16, address: Multiaddr) async throws -> any RawConnection {
    // TLS 設定
    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    tlsConfig.certificateVerification = .none  // Interop テスト用
    let sslContext = try NIOSSLContext(configuration: tlsConfig)

    // TLS ハンドラを先に追加、その後 WebSocket アップグレード
    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
    try channel.pipeline.syncOperations.addHandler(sslHandler)
    // ... WebSocket upgrade ...
}
```

### 検証結果
- Swift WebSocket 単体テスト: ✅ 全15テストパス
- go-libp2p WebSocket Interop: ✅ 全4テストパス

### 制限事項
- WSS Listener は未実装（サーバー証明書設定が必要）
- 証明書検証は無効化（Interop テスト用）

### 関連ファイル
- `Sources/Transport/WebSocket/WebSocketTransport.swift` - WSS dial 実装
- `Package.swift` - NIOSSL 依存追加

---

## Issue #4: WSS SNI エラー（IP アドレス接続時）

### ステータス
**解決済み** - 2026-02-06

### 症状
WSS 接続時に以下のエラーが発生:
```
NIOSSLExtraError.cannotUseIPAddressInSNI: IP addresses cannot validly be used for Server Name Indication, got 127.0.0.1
```

### 根本原因
TLS の SNI（Server Name Indication）拡張は IP アドレスをサポートしていない（RFC 6066）。`NIOSSLClientHandler` に IP アドレスを `serverHostname` として渡すとエラーになる。

### 解決策
接続先が IP アドレスかどうかを判定し、IP アドレスの場合は `serverHostname: nil` を設定:

```swift
// Check if host is an IP address (SNI doesn't work with IP addresses)
let isIPAddress = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }

if isIPAddress {
    sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
} else {
    sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
}
```

### 修正されたファイル
- `Sources/Transport/WebSocket/WebSocketTransport.swift` - IP アドレス検出と SNI 無効化

---

## Issue #5: `/tls/ws` Multiaddr 非対応

### ステータス
**設計上の制約** - 2026-02-06

### 概要
`/tls/ws` 形式の Multiaddr は swift-libp2p ではサポートされない。

### 根本原因
Multiaddr ライブラリに `tls` プロトコルが定義されていないため、`/ip4/127.0.0.1/tcp/443/tls/ws` を解析しようとすると `unknownProtocolName("tls")` エラーが発生する。

### 影響
- go-libp2p は WSS アドレスを `/tls/ws` 形式で出力する
- swift-libp2p は `/wss` 形式のみをサポート
- `GoWSSHarness` は go-libp2p の `/tls/ws` 出力を検出し、Swift 用に `/wss` 形式に変換する

### 解決策
`WebSocketTransport` から到達不能なコード（`/tls/ws` 関連）を削除:

**削除前:**
```swift
public var protocols: [[String]] {
    [
        ["ip4", "tcp", "ws"],
        ["ip4", "tcp", "wss"],
        ["ip4", "tcp", "tls", "ws"],  // ← 到達不能
    ]
}
```

**削除後:**
```swift
public var protocols: [[String]] {
    [
        ["ip4", "tcp", "ws"],
        ["ip4", "tcp", "wss"],
    ]
}
```

### 将来の対応
Multiaddr ライブラリに `tls` プロトコルが追加された場合、`/tls/ws` サポートを再検討する。

---

## テスト結果サマリー (2026-02-06 更新)

### WebSocket Transport (Noise)

| 実装 | テスト | 結果 |
|------|--------|------|
| go-libp2p | Connect via WebSocket | ✅ |
| go-libp2p | WebSocket + Yamux | ✅ |
| go-libp2p | Identify via WebSocket | ✅ |
| go-libp2p | Ping via WebSocket | ✅ |

**WebSocket: 全4テスト成功**

### WSS Transport (TLS + WebSocket + Noise)

| 実装 | テスト | 結果 |
|------|--------|------|
| go-libp2p | Connect via WSS | ✅ |
| go-libp2p | WSS + Yamux | ✅ |
| go-libp2p | Identify via WSS | ✅ |
| go-libp2p | Ping via WSS | ✅ |

**WSS: 全4テスト成功** (Issue #4 解決済み)

### WebSocket 単体テスト

| カテゴリ | テスト数 | 結果 |
|---------|---------|------|
| WS 基本機能 | 15 | ✅ |
| WSS 機能 | 5 | ✅ |

**単体テスト: 全20テスト成功**
