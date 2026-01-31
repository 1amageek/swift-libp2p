# P2PTransportWebSocket

## 概要
NIOWebSocket + NIOHTTP1 を使用した WebSocket トランスポート実装。
`Transport` プロトコル（TCP と同様）を実装し、`RawConnection` を返す。
標準の libp2p アップグレードパイプライン（Security → Mux）で使用可能。

## Multiaddr 形式
- `/ip4/<host>/tcp/<port>/ws` (code 477)
- `/ip6/<host>/tcp/<port>/ws`
- TLS なし（`.wss` code 478 は将来追加可能）

## ファイル構成

| ファイル | 責務 |
|---------|------|
| `WebSocketTransport.swift` | Transport プロトコル実装（dial/listen/canDial/canListen） |
| `WebSocketListener.swift` | Listener 実装 + ConnectionCallback（遅延バインディング） |
| `WebSocketConnection.swift` | RawConnection + WebSocketFrameHandler + SocketAddress 変換 |

## 設計決定

### Transport vs SecuredTransport
- `Transport` を実装（TCP と同様）
- `SecuredTransport` ではない（QUIC/WebRTC とは異なる）
- WebSocket は暗号化を提供しないため、Security 層でのアップグレードが必要

### クライアント: Typed API
- `NIOTypedWebSocketClientUpgrader<UpgradeResult>` 使用
- `configureUpgradableHTTPClientPipeline` でHTTPアップグレードを設定
- アップグレード結果を `WebSocketUpgradeResult` enum で返す

### サーバー: Non-typed API
- `NIOWebSocketServerUpgrader` 使用
- `configureHTTPServerPipeline(withServerUpgrade:)` でHTTPアップグレードを設定
- TCP の `childChannelInitializer` + `ConnectionCallback` パターンを踏襲

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
- `WebSocketListener`: `Mutex<ListenerState>` で pending connections/waiters を保護
- `ConnectionCallback`: `Mutex<CallbackState>` で遅延バインディングを保護
- `WebSocketFrameHandler`: `Mutex<HandlerState>` でバッファリングを保護

## DoS 対策
- `wsMaxReadBufferSize` (1MB): read buffer 上限
- `wsMaxFrameSize` (1MB): WebSocket フレームサイズ上限

## テスト

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
