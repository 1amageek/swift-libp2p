# P2PSecurityNoise

## 概要
Noise Protocol Framework XXパターンの実装。

## 責務
- Noise XXハンドシェイク
- X25519 DH鍵交換
- ChaCha20-Poly1305暗号化
- libp2p公開鍵ペイロード交換

## 依存関係
- `P2PSecurity` (SecurityUpgrader protocol)
- `P2PCore` (KeyPair, PeerID, PublicKey, Varint)
- `swift-crypto` (Curve25519, ChaChaPoly, SHA256, HMAC)

---

## ファイル構成

```
Sources/Security/Noise/
├── NoiseUpgrader.swift       # SecurityUpgrader実装 (エントリポイント)
├── NoiseConnection.swift     # SecuredConnection実装 (暗号化通信)
├── NoiseHandshake.swift      # XXハンドシェイク状態機械
├── NoiseCryptoState.swift    # Noise暗号状態 (SymmetricState, CipherState)
├── NoisePayload.swift        # ハンドシェイクペイロード (protobuf)
└── NoiseError.swift          # エラー定義
```

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `NoiseUpgrader` | ✅ Done | SecurityUpgrader実装 |
| `NoiseConnection` | ✅ Done | SecuredConnection実装 |
| `NoiseHandshake` | ✅ Done | XXハンドシェイク状態機械 |
| `NoiseSymmetricState` | ✅ Done | h, ck, CipherState管理 |
| `NoiseCipherState` | ✅ Done | 暗号化/復号化状態 |
| `NoisePayload` | ✅ Done | ハンドシェイクペイロード |
| `NoiseError` | ✅ Done | エラー定義 |

---

## Wire Protocol

### プロトコル名
```
Noise_XX_25519_ChaChaPoly_SHA256
```

### プロトコルID
```
/noise
```

### Noise XXパターン
```
XX:
  -> e
  <- e, ee, s, es
  -> s, se
```

```
Initiator                       Responder
    |                               |
    |----> e ----------------------->|  Message A
    |<---- e, ee, s, es <-----------|  Message B
    |----> s, se ------------------->|  Message C
    |     (session established)      |
```

---

## ハンドシェイク詳細

### Message A: Initiator → Responder
**Pattern: `-> e`**

1. Generate ephemeral key pair (e)
2. MixHash(e.public)
3. **EncryptAndHash(empty)** ← 重要: Noise 仕様では空ペイロードでも必須
4. Send: e.public (32 bytes, unencrypted)

> **注意**: Noise Protocol 仕様では、`WriteMessage` は常にペイロードに対して
> `EncryptAndHash` を呼び出す必要がある。libp2p-noise は Message A でペイロードを
> 送信しないが、空のペイロードに対する `encryptAndHash(Data())` 呼び出しは必須。
> この呼び出しにより `mixHash(empty)` が実行され、handshakeHash が変化する:
> `SHA256(h || empty) ≠ h`

```
Wire format:
┌────────────────┬────────────────────────────────────┐
│ Length (2 BE)  │ Ephemeral Public Key (32 bytes)    │
│     0x0020     │                                    │
└────────────────┴────────────────────────────────────┘
```

### Message B: Responder → Initiator
**Pattern: `<- e, ee, s, es`**

1. Generate ephemeral key pair (e)
2. MixHash(e.public)
3. MixKey(DH(e, re))           // ee: ephemeral-ephemeral
4. EncryptAndHash(s.public)    // s: static public key
5. MixKey(DH(e, rs))           // es: ephemeral-static (responder ephemeral, initiator static)
6. EncryptAndHash(payload)     // identity_key + identity_sig

```
Wire format:
┌────────────────┬──────────┬───────────────────┬────────────────────┐
│ Length (2 BE)  │ e.pub    │ encrypted s.pub   │ encrypted payload  │
│                │ (32)     │ (32 + 16 tag)     │ (var + 16 tag)     │
└────────────────┴──────────┴───────────────────┴────────────────────┘
```

### Message C: Initiator → Responder
**Pattern: `-> s, se`**

1. EncryptAndHash(s.public)    // s: static public key
2. MixKey(DH(s, re))           // se: static-ephemeral (initiator static, responder ephemeral)
3. EncryptAndHash(payload)     // identity_key + identity_sig

```
Wire format:
┌────────────────┬───────────────────┬────────────────────┐
│ Length (2 BE)  │ encrypted s.pub   │ encrypted payload  │
│                │ (32 + 16 tag)     │ (var + 16 tag)     │
└────────────────┴───────────────────┴────────────────────┘
```

---

## ペイロードフォーマット

### NoiseHandshakePayload (Protobuf)
```protobuf
message NoiseHandshakePayload {
  bytes identity_key = 1;     // libp2p公開鍵（protobuf encoded）
  bytes identity_sig = 2;     // 静的DH公開鍵への署名
  bytes data = 3;             // 追加データ（通常空）
}
```

### 署名フォーマット
```
署名対象: "noise-libp2p-static-key:" + noise_static_public_key (32 bytes)
署名アルゴリズム: Ed25519 (libp2pキーによる)
```

### 署名検証フロー
1. ペイロードから identity_key を取得
2. identity_key から PublicKey をデコード
3. 検証対象データ = `"noise-libp2p-static-key:" + remote_noise_static_pubkey`
4. identity_sig を identity_key で検証
5. PeerID = derive(identity_key)

---

## 暗号化通信フレーム

### フレームフォーマット
```
┌────────────────────┬────────────────────────────────────────────────┐
│ Length (2 bytes)   │ Ciphertext                                     │
│ Big-Endian         │ ChaCha20-Poly1305 encrypted                    │
│                    │ (plaintext + 16-byte auth tag)                 │
└────────────────────┴────────────────────────────────────────────────┘
```

### 制約
- Max frame size: 65535 bytes
- Auth tag size: 16 bytes
- Max plaintext per frame: 65535 - 16 = 65519 bytes

### Nonce構成
```
┌────────────────┬────────────────────────────────┐
│ Zero (4 bytes) │ Counter (8 bytes, LE)          │
└────────────────┴────────────────────────────────┘
```

---

## 暗号状態

### CipherState
```swift
struct NoiseCipherState {
    var key: SymmetricKey?      // 32 bytes, nil until initialized
    var nonce: UInt64 = 0       // Incremented after each encrypt/decrypt

    mutating func encryptWithAD(_ ad: Data, plaintext: Data) throws -> Data
    mutating func decryptWithAD(_ ad: Data, ciphertext: Data) throws -> Data
    func hasKey() -> Bool
}
```

### SymmetricState
```swift
struct NoiseSymmetricState {
    var chainingKey: Data       // ck, 32 bytes
    var handshakeHash: Data     // h, 32 bytes
    var cipherState: NoiseCipherState

    mutating func mixHash(_ data: Data)
    mutating func mixKey(_ inputKeyMaterial: Data)
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data
    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data
    func split() -> (send: NoiseCipherState, recv: NoiseCipherState)
}
```

### HandshakeState
```swift
struct NoiseHandshake: Sendable {
    let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    let localKeyPair: KeyPair
    let isInitiator: Bool
    private let localEphemeralKey: Curve25519.KeyAgreement.PrivateKey
    private var _remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
    private var _remoteEphemeralKey: Curve25519.KeyAgreement.PublicKey?
    private var symmetricState: NoiseSymmetricState

    // Initiator methods
    mutating func writeMessageA() -> Data           // mixHash(e) + encryptAndHash(empty)
    mutating func readMessageB(_ data: Data) throws -> NoisePayload
    mutating func writeMessageC() throws -> Data

    // Responder methods
    mutating func readMessageA(_ data: Data) throws // mixHash(re) + decryptAndHash(empty)
    mutating func writeMessageB() throws -> Data
    mutating func readMessageC(_ data: Data) throws -> NoisePayload

    // Finalization
    mutating func split() -> (send: NoiseCipherState, recv: NoiseCipherState)
}
```

---

## 状態遷移

### Initiator Flow
```
┌──────────────┐    writeA()    ┌──────────────┐    readB()    ┌──────────────┐
│ WaitToWrite  │───────────────▶│ WaitToRead   │──────────────▶│ WaitToWrite  │
│   MessageA   │                │   MessageB   │               │   MessageC   │
└──────────────┘                └──────────────┘               └──────┬───────┘
                                                                      │ writeC()
                                                                      ▼
                                                               ┌──────────────┐
                                                               │  Established │
                                                               └──────────────┘
```

### Responder Flow
```
┌──────────────┐    readA()     ┌──────────────┐    writeB()   ┌──────────────┐
│ WaitToRead   │───────────────▶│ WaitToWrite  │──────────────▶│ WaitToRead   │
│   MessageA   │                │   MessageB   │               │   MessageC   │
└──────────────┘                └──────────────┘               └──────┬───────┘
                                                                      │ readC()
                                                                      ▼
                                                               ┌──────────────┐
                                                               │  Established │
                                                               └──────────────┘
```

---

## API設計

### NoiseUpgrader
```swift
public final class NoiseUpgrader: SecurityUpgrader, Sendable {
    public var protocolID: String { "/noise" }

    public init()

    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection
}
```

### NoiseConnection
```swift
public final class NoiseConnection: SecuredConnection, Sendable {
    public let localPeer: PeerID
    public let remotePeer: PeerID

    public func read() async throws -> Data
    public func write(_ data: Data) async throws
    public func close() async throws
}
```

---

## 暗号スイート

| Component | Algorithm |
|-----------|-----------|
| DH | Curve25519 (X25519) |
| Cipher | ChaCha20-Poly1305 |
| Hash | SHA-256 |
| KDF | HKDF-SHA256 |

---

## swift-crypto API

```swift
import Crypto

// X25519 Key Agreement
let privateKey = Curve25519.KeyAgreement.PrivateKey()
let publicKey = privateKey.publicKey
let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)

// ChaCha20-Poly1305
let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
let plaintext = try ChaChaPoly.open(sealedBox, using: key)

// SHA-256
let hash = SHA256.hash(data: data)

// HKDF (custom expand in NoiseCryptoState)
let derived = NoiseSymmetricState.hkdfExpand(
    chainingKey: ck,
    inputKeyMaterial: input,
    outputLength: 64
)
```

---

## 実装順序

1. `NoiseError.swift` - エラー定義
2. `NoiseCryptoState.swift` - CipherState, SymmetricState
3. `NoisePayload.swift` - ペイロードエンコード/デコード
4. `NoiseHandshake.swift` - XXハンドシェイク状態機械
5. `NoiseConnection.swift` - 暗号化接続
6. `NoiseUpgrader.swift` - エントリポイント

---

## エラー定義

```swift
public enum NoiseError: Error, Sendable {
    case handshakeFailed(String)
    case decryptionFailed
    case invalidPayload
    case invalidSignature
    case peerMismatch(expected: PeerID, actual: PeerID)
    case messageOutOfOrder
    case frameTooLarge(size: Int, max: Int)  // サイズ情報付き
    case connectionClosed
    case invalidKey        // X25519公開鍵が無効
    case nonceOverflow     // ノンスカウンタ満杯（接続を閉じよ）
}
```

## 追加の実装詳細

### CustomHKDFの実装
`NoiseSymmetricState.hkdfExpand()`は、swift-cryptoのHKDFを直接使用せず、
RFC 5869に従う独自実装。出力長の動的制御とlibp2p Noise仕様との完全な一致を目的とする。

### NonceOverflowハンドリング
NoiseCipherStateは64ビットnonceカウンタを使用:
- 各encrypt/decrypt操作後にインクリメント
- UInt64.maxに達すると`NoiseError.nonceOverflow`
- 本番環境では鍵交換またはリキー必須

### expectedPeer検証
expectedPeerが指定された場合:
1. Noise静的鍵からPeerIDを検証
2. `NoiseError.peerMismatch`を投げる（不一致時）
3. 署名検証にも失敗すれば`NoiseError.invalidSignature`

---

## 注意点

1. **Prologue**: libp2p Noiseではprologueは空（multistream-selectは別レイヤー）
2. **Static Key**: Noiseの静的鍵はlibp2pのEd25519鍵とは別に生成（X25519）
3. **署名**: libp2p Ed25519鍵でNoise静的公開鍵に署名してIDを証明
4. **Nonce Reuse**: 絶対にnonceを再利用しない（カウンタで管理）
5. **Split順序**: Initiatorのsend = Responderのrecv（方向に注意）
6. **空ペイロード処理**: Message A でも `encryptAndHash(empty)` / `decryptAndHash(empty)` を呼び出す必要がある（Noise 仕様要件、go-libp2p/rust-libp2p との相互運用に必須）

---

## テスト

```
Tests/Security/NoiseTests/
├── NoiseCryptoStateTests.swift   # 暗号プリミティブ
├── NoisePayloadTests.swift       # ペイロードエンコード/署名
├── NoiseHandshakeTests.swift     # XXハンドシェイク
└── NoiseIntegrationTests.swift   # 統合テスト
```

---

## 参照

- [Noise Protocol Specification](https://noiseprotocol.org/noise.html)
- [libp2p Noise Spec](https://github.com/libp2p/specs/blob/master/noise/README.md)
- [rust-libp2p noise](https://github.com/libp2p/rust-libp2p/tree/master/transports/noise)

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| X25519 small-order keys | `NoiseCryptoState.swift` | ✅ Fixed | CryptoKit doesn't reject small-order public keys; can yield all-zero shared secret, weakening handshake. **Fix**: Added `validateX25519PublicKey()` to check 8 known small-order points + all-zero shared secret check in `noiseKeyAgreement()` |
| Read/write lock contention | `NoiseConnection.swift` | ⬜ | Single `Mutex` guards both send and recv cipher state, serializing read/write. Consider separate locks for send vs recv |

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Max size comment mismatch | `NoiseError.swift` | Comment says `noiseMaxMessageSize` includes length prefix, but code treats it as ciphertext length. Clarify comment |
| Repeated Data allocations | `NoisePayload.swift` | Minor perf: repeated `Data` wrapping for varint decoding. Negligible but could be optimized |
