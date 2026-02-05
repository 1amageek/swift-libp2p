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
