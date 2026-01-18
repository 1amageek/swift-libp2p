# Mux Layer

## 概要
ストリーム多重化層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Mux/
├── P2PMux/           # Protocol定義のみ
├── Yamux/            # P2PMuxYamux
└── Mplex/            # P2PMuxMplex（将来実装）
```

## 設計原則
- **Protocol定義と実装の分離**: P2PMuxはprotocolのみ
- **SecuredConnection → MuxedConnection**: 多重化アップグレード
- **双方向ストリーム**: 同一接続上で複数の論理ストリーム

## サブモジュール

| ターゲット | 責務 | 依存関係 |
|-----------|------|----------|
| `P2PMux` | Muxer/MuxedConnection/MuxedStreamプロトコル | P2PCore |
| `P2PMuxYamux` | Yamux multiplexer実装 | P2PMux |
| `P2PMuxMplex` | Mplex multiplexer実装（将来） | P2PMux |

## 主要なプロトコル

```swift
public protocol Muxer: Sendable {
    var protocolID: String { get }
    func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection
}

public protocol MuxedConnection: Sendable {
    var localPeer: PeerID { get }
    var remotePeer: PeerID { get }
    func newStream() async throws -> MuxedStream
    func acceptStream() async throws -> MuxedStream
    var inboundStreams: AsyncStream<MuxedStream> { get }
    func close() async throws
}

public protocol MuxedStream: Sendable {
    var id: UInt64 { get }
    var protocolID: String? { get }
    func read() async throws -> Data
    func write(_ data: Data) async throws
    func closeWrite() async throws
    func close() async throws
    func reset() async throws
}
```

## 接続フロー
```
SecuredConnection
    ↓ multistream-select (/yamux/1.0.0)
    ↓ Muxer.multiplex()
MuxedConnection
    ↓ newStream() / acceptStream()
MuxedStream (各アプリケーションプロトコル用)
```

## Wire Protocol IDs
- `/yamux/1.0.0` - Yamux
- `/mplex/6.7.0` - Mplex

## ストリームID規則
- Initiator: 奇数 (1, 3, 5, ...)
- Responder: 偶数 (2, 4, 6, ...)

## Length-Prefixed Message Utilities

`MuxedStream`プロトコルには、length-prefixedメッセージ用の便利な拡張が含まれる:

```swift
extension MuxedStream {
    public func readLengthPrefixedMessage(maxSize: UInt64 = 64 * 1024) async throws -> Data
    public func writeLengthPrefixedMessage(_ data: Data) async throws
}
```

これらのメソッドは、libp2p標準のVarintエンコーディングを使用して長さプレフィックスを自動的に処理する。

### StreamMessageError
- `streamClosed` - 読み取り中にストリームが閉じられた
- `messageTooLarge(UInt64)` - メッセージがmaxSizeを超過
- `emptyMessage` - 空のメッセージを受信

## MuxedConnection追加プロパティ

```swift
public protocol MuxedConnection: Sendable {
    var localPeer: PeerID { get }
    var remotePeer: PeerID { get }
    var localAddress: Multiaddr? { get }   // ローカルアドレス
    var remoteAddress: Multiaddr { get }    // リモートアドレス
    func newStream() async throws -> MuxedStream
    func acceptStream() async throws -> MuxedStream
    var inboundStreams: AsyncStream<MuxedStream> { get }
    func close() async throws
}
```

## Yamux実装詳細

### フロー制御
- **デフォルトウィンドウサイズ**: 256KB (256 * 1024バイト)
- **ウィンドウ更新タイミング**: 受信ウィンドウが半分以下（128KB）になったら更新送信
- **ウィンドウ更新戦略**: Fire-and-forget（送信成功後にローカルウィンドウ更新）

### 書き込み待機
- 送信ウィンドウが0の場合、WindowUpdateフレーム受信を待機
- **タイムアウト**: 30秒（ハードコード）
- アトミックなウィンドウ予約でTOCTOU競合を防止

### フレームフォーマット
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version (8) |     Type (8)  |          Flags (16)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Length (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- Version: 常に0
- Type: Data(0), WindowUpdate(1), Ping(2), GoAway(3)
- Flags: SYN(0x0001), ACK(0x0002), FIN(0x0004), RST(0x0008)

## テスト実装状況

| テスト | ステータス | 説明 |
|-------|----------|------|
| MuxTests | ⚠️ プレースホルダー | 1テストのみ |
| YamuxFrameTests | ✅ 実装済み | フレームエンコード/デコードの基本検証 |
| YamuxConnection/Stream Tests | ❌ なし | フロー制御、RST/FIN、タイムアウトが未検証 |

**クリティカル**: YamuxConnection/YamuxStreamのユニットテスト追加を強く推奨

## 品質向上TODO

### 高優先度
- [ ] **Yamuxフレームエンコード/デコードテスト** - バイトオーダー、バージョン検証
- [ ] **Yamuxフロー制御テスト** - ウィンドウ予約、更新、タイムアウト
- [ ] **Mplex実装** - rust-libp2p/go-libp2pとの互換性向上
- [ ] **Yamuxストレステスト** - 大量ストリーム同時オープンテスト

### 中優先度
- [ ] **Keep-alive設定の公開** - YamuxConfigurationへの追加
- [ ] **ストリーム統計の追加** - 送受信バイト数、エラー数等
- [ ] **GoAway理由の詳細化** - アプリケーション固有の理由コード対応

### 低優先度
- [ ] **ストリーム優先度** - 重要なストリームの優先処理
- [ ] **フロー制御のチューニングオプション** - ウィンドウサイズの動的調整
