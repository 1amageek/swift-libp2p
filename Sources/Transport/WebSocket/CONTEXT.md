# P2PTransportWebSocket

## 概要
NIOWebSocket + NIOHTTP1 を使用した WebSocket トランスポート実装。
`Transport` プロトコル（TCP と同様）を実装し、`RawConnection` を返す。
標準の libp2p アップグレードパイプライン（Security → Mux）で使用可能。

## Multiaddr 形式
- `/ip4/<host>/tcp/<port>/ws` (code 477)
- `/ip6/<host>/tcp/<port>/ws`
- `/dns|dns4|dns6/<host>/tcp/<port>/ws`（dialのみ）
- `/ip4|ip6|dns|dns4|dns6/<host>/tcp/<port>/wss` (code 478, secure)
- `.../p2p/<peer>` サフィックスは dial 時のみ許可（listen は拒否）

### WSS の制約
- `dial(.wss(...))` はクライアント TLS 構成が `.fullVerification` の場合のみ許可
- `dial(.wss(...))` は DNS ホスト名のみ許可（IP リテラルは拒否）
- `listen(.wss(...))` はサーバー TLS 構成を明示的に渡した場合のみ許可
- `canListen(.wss(...))` は server TLS 設定がない場合 `false`

## ファイル構成

| ファイル | 責務 |
|---------|------|
| `WebSocketTransport.swift` | Transport プロトコル実装（dial/listen/canDial/canListen） |
| `WebSocketListener.swift` | Listener 実装（NIOAsyncChannel + typed upgrade pipeline） |
| `WebSocketConnection.swift` | RawConnection + WebSocketFrameHandler + SocketAddress 変換 |

## 設計決定

### Transport vs SecuredTransport
- `Transport` を実装（TCP と同様）
- `SecuredTransport` ではない（QUIC/WebRTC とは異なる）
- `ws` は暗号化を提供しないため、Security 層でのアップグレードが必要
- `wss` はトランスポートレベル TLS を提供するが、libp2p の Security 層（Noise/TLS）とは独立

### クライアント: Typed API
- `NIOTypedWebSocketClientUpgrader<UpgradeResult>` 使用
- `configureUpgradableHTTPClientPipeline` でHTTPアップグレードを設定
- アップグレード結果を `WebSocketUpgradeResult` enum で返す

### サーバー: Typed API + NIOAsyncChannel
- `NIOTypedWebSocketServerUpgrader<WebSocketUpgradeResult>` 使用
- `syncOperations.configureUpgradableHTTPServerPipeline(configuration:)` でHTTPアップグレードを設定
- `ServerBootstrap.bind(host:port:childChannelInitializer:)` async → `NIOAsyncChannel` で接続を受信
- 背景 Task が `executeThenClose` 内で inbound stream をイテレート → `connectionAccepted()` で配信
- `close()` は Task cancel → `executeThenClose` 終了 → server channel 自動 close

### フレーム形式
- 全データは Binary opcode で送信
- クライアントは RFC 6455 に従いフレームをマスク
- Ping は自動的に Pong で応答
- Close フレームは RFC 6455 に従い close response を送信後、チャネルを閉じる

## NIO パイプライン（アップグレード後）

```
[WebSocketFrameEncoder]               ← NIO upgrader が追加
[ByteToMessageHandler<WebSocketFrameDecoder>] ← NIO upgrader が追加
[WebSocketProtocolErrorHandler]        ← NIO upgrader が追加（automaticErrorHandling）
[WebSocketFrameHandler]                ← upgradePipelineHandler で追加
```

## 並行処理モデル
- **Class + Mutex**: TCP と同一パターン
- `WebSocketConnection`: `Mutex<WebSocketConnectionState>` で read buffer/waiters を保護
- `WebSocketListener`: `Mutex<ListenerState>` で pending connections/waiters を保護 + `Mutex<Task?>` で accept task を管理
- `WebSocketFrameHandler`: `Mutex<HandlerState>` でバッファリングを保護

## DoS 対策
- `wsMaxReadBufferSize` (1MB): read buffer 上限
- `wsMaxFrameSize` (1MB): WebSocket フレームサイズ上限

## テスト (40件)

### 既存テスト (25件)

| テスト | 説明 |
|-------|------|
| testBasicConnection | dial + listen + accept、アドレスに `/ws` 含有を確認 |
| testBidirectionalCommunication | クライアント → サーバー、サーバー → クライアント |
| testMultipleMessages | 5 連続メッセージ |
| testLargeMessage | 64KB 転送 |
| testMultipleConnections | 3 同時接続 |
| testConcurrentDialAndAccept | 5 並行 dial+accept |
| testCloseConnection | 片側 close、もう片側の read がエラー |
| testWriteAfterClose | close 後の write がエラー |
| testListenerClose | pending accept が `listenerClosed` エラー |
| testBufferedDataBeforeClose | close 前のデータが読み取り可能 |
| testCanDialWS | WS は true、TCP のみは false |
| testCanListenWS | WS は true、非 WS は false |
| testProtocolsProperty | `[["ip4", "tcp", "ws"], ["ip6", "tcp", "ws"]]` |
| testUnsupportedAddress | 非 WS アドレスでエラー |
| testWSMultiaddrFactory | `Multiaddr.ws(host:port:)` の検証 |

### 追加テスト (15件, 2026-02-16)

| テスト | 方式 | 説明 |
|-------|------|------|
| testWSBufferOverflowSilentlyDropsFrames | 統合 | 1MB超でサイレントdrop（TCP との設計差異） |
| testCloseFrameHandshake | 統合 | クライアント起点 close frame |
| testServerInitiatedCloseFrameHandshake | 統合 | サーバー起点 close frame |
| testPingPongAutoResponse | EmbeddedChannel | サーバーモード ping→pong |
| testPingPongClientSideMasked | EmbeddedChannel | クライアントモード ping→pong (masked) |
| testTextFrameDeliveredAsData | EmbeddedChannel | text opcode がデータとして配信 |
| testClientWriteMasksFrames | EmbeddedChannel | クライアント書込みにマスクあり |
| testServerWriteDoesNotMaskFrames | EmbeddedChannel | サーバー書込みにマスクなし |
| testWSIdempotentClose | 統合 | close() 二重呼出し安全性 |
| testWSConcurrentReadsFIFO | 統合 | 3並行 read の FIFO 順序保証 |
| testWSIPv6Connection | 統合 | IPv6 アドレスでの接続 |
| testWSHandlerBuffersDataBeforeConnectionSet | EmbeddedChannel | connection設定前のバッファリング |
| testWSListenerCloseCleansPendingConnections | 統合 | listener close 時のリソース解放 |
| testWSErrorCaughtClosesConnection | EmbeddedChannel | パイプラインエラー伝播 |
| testWSReadReturnsBufferThenErrorOnClose | 統合 | close後のバッファ優先読み取り |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16, Updated)

- 総合評価: **A-** (84/100)
- 対象ターゲット: `P2PTransportWebSocket`
- 実装読解範囲: 3 Swift files / 1077 LOC
- テスト範囲: 40 cases (25既存 + 15追加: EmbeddedChannel 6件 + 統合テスト 9件)
- 公開API: types 5 / funcs 8
- 参照網羅率: type 0.8 / func 1.0
- 未参照公開型: 1 件（`WebSocketTLSConfiguration` — WSS テストは別途必要）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=4(クライアント側のみ, HTTP upgrade固有), DispatchQueue=0
- 評価所見: RFC 6455準拠テスト（ping/pong, masking, close frame）を網羅 / サーバー側 NIO Typed API 移行完了 / ConnectionCallback 削除済み

### 重点アクション
- TransportError型の標準化（WS固有エラーとTransportErrorの統一）

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
