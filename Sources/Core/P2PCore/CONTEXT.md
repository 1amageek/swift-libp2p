# P2PCore

## 概要
libp2pスタック全体で使用される最小限の共通抽象を提供する基盤モジュール。

## 責務
- ピアの識別（PeerID, PublicKey, PrivateKey, KeyPair）
- ネットワークアドレッシング（Multiaddr）
- 接続プロトコル定義（RawConnection, SecuredConnection）
- ユーティリティ（Varint, Base58, Multihash）
- 署名付きレコード（Envelope, PeerRecord）

## 依存関係
- `swift-crypto` (暗号プリミティブ)
- `swift-log` (ロギング)

## 主要な型

| 型名 | ファイル | 説明 |
|-----|---------|------|
| `PeerID` | Identity/PeerID.swift | ピアの一意識別子（公開鍵由来） |
| `PublicKey` | Identity/PublicKey.swift | 公開鍵の表現 |
| `PrivateKey` | Identity/PrivateKey.swift | 秘密鍵の表現 |
| `KeyPair` | Identity/KeyPair.swift | 鍵ペア |
| `KeyType` | Identity/KeyType.swift | 鍵種別（Ed25519, ECDSA P-256） |
| `Multiaddr` | Addressing/Multiaddr.swift | 自己記述型ネットワークアドレス |
| `Protocol` | Addressing/Protocol.swift | アドレスプロトコルコンポーネント |
| `RawConnection` | Connection/RawConnection.swift | 生のネットワーク接続 (protocol) |
| `SecuredConnection` | Connection/SecuredConnection.swift | 暗号化された接続 (protocol) |
| `SecurityRole` | Connection/SecuredConnection.swift | initiator / responder |
| `Varint` | Utilities/Varint.swift | 可変長整数エンコーディング |
| `Multihash` | Utilities/Multihash.swift | 自己記述型ハッシュ |
| `Base58` | Utilities/Base58.swift | Base58エンコーディング |
| `Envelope` | Record/Envelope.swift | 署名付きエンベロープ |
| `PeerRecord` | Record/PeerRecord.swift | ピアレコード |
| `SignedRecord` | Record/SignedRecord.swift | 署名付きレコードプロトコル |
| `AddressInfo` | Record/PeerRecord.swift | ピアレコード内のアドレス情報 |

## Wire Protocol
- PeerID: multihash エンコード（Ed25519は identity hash、それ以外は SHA-256）
- Multiaddr: 自己記述型バイナリフォーマット

### CIDv1 Multibase PeerID Parsing
PeerID文字列解析はCIDv1 multibaseプレフィックスをサポート:
- `z...`: Base58btc（multibaseプレフィックス）
- `f...`: Hex（限定サポート）
- `b...`: Base32（限定サポート）
- `Qm...`: レガシーBase58btc（プレフィックスなし）

### Socket Address Support
Multiaddrは`"host:port"`形式のソケットアドレス解析をサポート:
```swift
let addr = try Multiaddr(socketAddress: "192.168.1.1:4001", transport: .tcp)
// IPv6はブラケット表記: "[::1]:4001"
```

## ハッシュアルゴリズム実装状況

| アルゴリズム | コード | 実装状況 | 用途 |
|------------|--------|---------|------|
| Identity | 0x00 | ✅ 実装済 | Ed25519 PeerID生成（≤42バイト） |
| SHA-256 | 0x12 | ✅ 実装済 | 大きな鍵のPeerID生成 |
| SHA-512 | 0x13 | ❌ 未実装 | コード定義のみ |
| SHA3-256 | 0x16 | ❌ 未実装 | コード定義のみ |
| SHA3-512 | 0x14 | ❌ 未実装 | コード定義のみ |
| BLAKE2b-256 | 0xb220 | ❌ 未実装 | コード定義のみ |
| BLAKE2s-256 | 0xb260 | ❌ 未実装 | コード定義のみ |

## 設計判断: モダン暗号のみサポート

本プロジェクトは **Ed25519** と **ECDSA P-256** のみをサポートし、RSA と Secp256k1 は意図的に除外する。

| 鍵タイプ | ステータス | 理由 |
|---------|-----------|------|
| Ed25519 | ✅ サポート | 高速・安全・鍵サイズ小。libp2pの推奨アルゴリズム |
| ECDSA P-256 | ✅ サポート | TLS 1.3 証明書との互換性に必要 |
| RSA | ❌ 非サポート | 鍵サイズが大きく低速。レガシー互換のためだけに存在し、新規実装では不要 |
| Secp256k1 | ❌ 非サポート | Bitcoin/Ethereum用途。libp2pネットワーキングでの実用的需要なし |

コード上は `KeyType` enumに全種別を定義しているが（Protobufワイヤフォーマット互換のため）、RSA/Secp256k1 で鍵生成・署名検証を試みると `unsupportedKeyType` エラーを返す。

## 既知の制限事項

1. **アドレス検証**: IPv4/IPv6の形式検証は行わない（文字列操作のみ）
2. **ハッシュ関数**: SHA-256とidentityのみ。SHA-512/SHA3/BLAKE2は未実装
3. **PeerID公開鍵抽出**: identity hashでエンコードされたPeerIDのみ公開鍵を復元可能。SHA-256でハッシュされたPeerIDからは復元不可（libp2p仕様に準拠）
4. **IPv6表記**: デコード時に展開形式（`0:0:0:0:0:0:0:1`）を使用。圧縮形式（`::1`）は生成されない

## セキュリティに関する注意事項

### Envelope署名検証
Envelopeの署名検証時、ドメイン文字列は検証データに含まれない現在の実装がある。複数のレコードタイプ間でのリプレイアタック対策が必要な場合は、アプリケーション層で追加の防御メカニズムを実装することを検討。

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Domain separation missing | `Record/Envelope.swift` | ✅ N/A | Already implemented correctly: `verify(domain:)` and `record(as:)` both use domain in signature verification |
| Untrusted length DoS | `Utilities/Varint.swift`, multiple files | ✅ Fixed | UInt64→Int conversion without bounds checks. Added `decodeAsInt()`, `toInt()` helpers and bounds checks |
| Multiaddr input DoS | `Addressing/Multiaddr.swift` | ✅ Fixed | No input size limits allowed DoS via maliciously large inputs. Added size (1KB) and component (20) limits |
| Multiaddr parsing heuristic | `Addressing/Multiaddr.swift:38,179` | ⬜ | Hardcoded protocol set omits `p2p-circuit`; can misparse when values match protocol names |
| Invalid IP silent encoding | `Addressing/MultiaddrProtocol.swift:88,120` | ⬜ | Invalid IPs encoded as empty bytes instead of errors; inconsistent round-trips |
| IPv6 simplified parser | `Addressing/MultiaddrProtocol.swift:131` | ⬜ | May reject valid forms or mishandle multiple `::` and IPv4-mapped addresses |

## Fixes Applied

### Multiaddr Input DoS Protection (2026-01-18)

**問題**: Multiaddr解析に入力サイズ制限がなく、悪意のある巨大入力でDoS攻撃が可能

**解決策**:
1. 入力サイズ制限を追加:
   - `multiaddrMaxInputSize = 1024` バイト（文字列/バイナリ）
   - `multiaddrMaxComponents = 20` プロトコルコンポーネント
2. 新しいエラーケースを追加:
   - `MultiaddrError.inputTooLarge(size:max:)`
   - `MultiaddrError.tooManyComponents(count:max:)`
3. `init(protocols:)` を throwing に変更
4. `init(uncheckedProtocols:)` を公開（検証済み入力用）

**修正ファイル**:
- `Addressing/Multiaddr.swift` - 制限とエラーケース追加
- `Transport/TCP/TCPConnection.swift` - uncheckedProtocols使用
- `Transport/TCP/TCPListener.swift` - uncheckedProtocols使用
- `Protocols/CircuitRelay/RelayedConnection.swift` - uncheckedProtocols使用
- `Protocols/CircuitRelay/RelayServer.swift` - uncheckedProtocols使用

**テスト**: `Tests/Core/P2PCoreTests/MultiaddrTests.swift` (6つの新テスト)

### Varint UInt64→Int Overflow (2026-01-18)

**問題**: `Varint.decode()` の結果を `Int()` で変換する際、値が `Int.max` を超えるとクラッシュ

**解決策**:
1. `VarintError.valueExceedsIntMax(UInt64)` エラーケースを追加
2. 安全な変換ヘルパーを追加:
   - `Varint.decodeAsInt(_:)` - 境界チェック付きデコード
   - `Varint.toInt(_:)` - UInt64→Int 安全変換
3. 使用箇所で事前に `length <= UInt64(Int.max)` をチェック

**修正ファイル**:
- `Utilities/Varint.swift` - ヘルパー追加
- `P2PNegotiation/P2PNegotiation.swift`
- `P2PMux/P2PMux.swift`
- `Integration/P2P/ConnectionUpgrader.swift`
- `Integration/P2P/P2P.swift`

**テスト**: `Tests/Core/P2PCoreTests/MultiaddrTests.swift` (VarintTests suite)

### Info (Performance)
| Issue | Location | Description |
|-------|----------|-------------|
| O(n²) Multiaddr.bytes | `Addressing/Multiaddr.swift:81` | Repeated `+` for Data; use `reserveCapacity` + `append` |
| O(n²) Base58.decode | `Utilities/Base58.swift:85` | `insert(_:at:)` at front; use preallocated buffers or reversed accumulation |

## 注意点
- このモジュールは**最小限**に保つこと（太ると破壊的変更が増える）
- Transport/Security/Mux の具体的な実装は含まない
- ネットワーク通信の実装は含まない
- 状態管理（ConnectionPool等）は含まない

## 品質向上TODO

### 中優先度
- [ ] **SHA-512/SHA3/BLAKE2ハッシュファクトリの追加** - Multihashで宣言されているが実装なし
- [ ] **IPv4/IPv6アドレス形式検証** - 現在は文字列操作のみ
- [ ] **ポート範囲検証の明示化** - UInt16で暗黙的だが明示的なエラーがない

### 低優先度
- [ ] **PEM形式のキーインポート/エクスポート** - 外部ツールとの互換性向上
- [ ] **Codable準拠のテスト強化** - JSON/PropertyListラウンドトリップテスト

## 参照
- [PeerID Spec](https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md)
- [Multiaddr Spec](https://github.com/multiformats/multiaddr)
