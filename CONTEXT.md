# swift-libp2p Codex Review 修正ロードマップ

このドキュメントは、Codex Reviewで指摘された問題の修正手順と進捗を管理します。

## 修正ステータス凡例

- ⬜ 未着手
- 🔄 作業中
- ✅ 完了
- ⏭️ スキップ（理由付き）

---

## Phase 1: Critical（重大問題）

最優先で修正すべきセキュリティ上の重大な問題。

### 1.1 ✅ P2PKademlia - リモートクラッシュ脆弱性

**ファイル**: `Sources/Protocols/Kademlia/KademliaKey.swift`

**問題**: 不正な形式のKademliaKeyを受信するとクラッシュする可能性

**修正状況**: ✅ 修正済み（実装済み + テスト追加済み）

**設計ドキュメント**: `Sources/Protocols/Kademlia/DESIGN_KEY_VALIDATION.md`

**実装内容**:
1. `KademliaKey.init(validating:)` で32バイト検証（lines 30-41）
2. `KademliaKeyError.invalidLength(actual:expected:)` エラー型（lines 8-11）
3. `handleMessage(.findNode)` で検証付きイニシャライザを使用（lines 283-287）
4. GET_VALUE/GET_PROVIDERS は `KademliaKey(hashing:)` を使用（任意長OK）

**追加テスト**:
- 正常系: 32バイト入力の受け入れ
- 異常系: 短い/長い/空の入力の拒否
- 境界条件: 31バイト、33バイトの拒否
- エラー情報: actual/expected値の検証
- プロトコル検証: FIND_NODE不正キー拒否

**テストファイル**: `Tests/Protocols/KademliaTests/KademliaTests.swift`

---

## Phase 2: High Priority Warnings（高優先度警告）

DoS攻撃やセキュリティに直結する問題。

### 2.1 ✅ P2PMuxYamux - ストリームID DoS

**ファイル**: `Sources/Mux/Yamux/YamuxConnection.swift`

**問題**: 攻撃者が大量のストリームIDを作成してメモリを枯渇させる

**修正状況**: ✅ 修正済み（実装済み + テスト追加済み）

**設計ドキュメント**: `Sources/Mux/Yamux/DESIGN_STREAM_LIMITS.md`

**実装内容**:
1. `YamuxConfiguration` 構造体を追加（`maxConcurrentStreams`, `initialWindowSize`）
2. `YamuxMuxer` に configuration パラメータを追加
3. `YamuxConnection.handleDataFrame()` でSYN受信時にアトミックチェック:
   - ストリームID再利用の検出
   - ストリーム数上限の検証
4. 違反時は RST フレームで拒否

**追加テスト**:
- YamuxConfigurationTests: デフォルト値、カスタム値、境界値
- YamuxErrorTests: maxStreamsExceeded、streamIDReused エラー型
- フレームサイズ制限テスト: frameTooLarge

**テストファイル**: `Tests/Mux/YamuxTests/YamuxFrameTests.swift`

---

### 2.2 ✅ P2PCore - UInt64→Int オーバーフロー

**ファイル**: `Sources/Core/P2PCore/Utilities/Varint.swift`

**問題**: varint デコード結果が Int.max を超える場合の処理不足

**修正状況**: ✅ 修正済み（実装済み + テスト追加済み）

**実装内容**:
1. `VarintError.valueExceedsIntMax(UInt64)` エラーケースを追加
2. `Varint.decodeAsInt(_:)` - 安全な Int 変換付きデコード
3. `Varint.decodeAsIntWithRemainder(_:)` - remainder 付きバージョン
4. `Varint.toInt(_:)` - UInt64 → Int 安全変換ヘルパー
5. 以下のファイルで境界チェックを追加:
   - `P2PNegotiation.swift` - decode()
   - `P2PMux.swift` - readLengthPrefixedMessage()
   - `ConnectionUpgrader.swift` - extractMessage()
   - `P2P.swift` - readLengthPrefixedMessage()

**追加テスト**:
- decodeAsInt 正常系・異常系
- toInt 正常系・異常系
- valueExceedsIntMax エラー値検証
- decodeAsIntWithRemainder

**テストファイル**: `Tests/Core/P2PCoreTests/MultiaddrTests.swift` (VarintTests suite)

---

### 2.3 ✅ P2PSecurityNoise - X25519 小鍵検証

**ファイル**: `Sources/Security/Noise/NoiseCryptoState.swift`, `Sources/Security/Noise/NoiseHandshake.swift`

**問題**: all-zero 等の小次数鍵（small-order keys）を検証していない

**修正状況**: ✅ 修正済み（実装済み + テスト追加済み）

**実装内容**:
1. `validateX25519PublicKey()` 関数で8つの小次数ポイントをチェック
2. `noiseKeyAgreement()` でall-zero共有秘密を拒否
3. `NoiseHandshake` の全メッセージ処理で検証を呼び出し:
   - `readMessageA()`: リモート一時鍵を検証
   - `readMessageB()`: リモート一時鍵とリモート静的鍵を検証
   - `readMessageC()`: リモート静的鍵を検証
4. 検出時は `NoiseError.invalidKey` をスロー

**小次数ポイント一覧** (little-endian, 32バイト):
- `0000...0000` (order 1 - 中立元)
- `0100...0000` (order 4)
- `ecff...ff7f` (order 8)
- `e0eb...b800` (order 8)
- `5f9c...1157` (order 8)
- `edff...ff7f` (order 2)
- `daff...ffff` (order 8, twist)
- `dbff...ffff` (order 8, twist)

**参考**: https://cr.yp.to/ecdh.html#validate

**テストファイル**: `Tests/Security/NoiseTests/NoiseCryptoStateTests.swift`
- 11件の小次数ポイント検証テスト追加
- 全71件のNoiseテストがパス

---

### 2.4 ✅ P2PCore - Multiaddr 解析 DoS

**ファイル**: `Sources/Core/P2PCore/Addressing/Multiaddr.swift`

**問題**: 大きな入力でメモリ過剰消費

**修正状況**: ✅ 修正済み

**実装内容**:
1. `multiaddrMaxInputSize = 1024` バイト（文字列/バイナリ）
2. `multiaddrMaxComponents = 20` プロトコルコンポーネント
3. `MultiaddrError.inputTooLarge(size:max:)` エラー
4. `MultiaddrError.tooManyComponents(count:max:)` エラー

**テスト**: `Tests/Core/P2PCoreTests/MultiaddrTests.swift`

---

### 2.5 ✅ P2PGossipSub - 署名検証不足

**ファイル**: `Sources/Protocols/GossipSub/GossipSubRouter.swift`

**問題**: StrictSign モード時の署名検証が未実装

**修正状況**: ✅ 修正済み

**実装内容**:
1. `GossipSubConfiguration.validateSignatures` (デフォルト: true)
2. `GossipSubConfiguration.strictSignatureVerification` (デフォルト: true)
3. `GossipSubMessage.verifySignature()` でメッセージ署名を検証
4. 無効な署名のメッセージは破棄し、ピアにペナルティを適用
5. `peerScorer.recordInvalidMessage(from:)` でスコア減点

**テスト**: `Tests/Protocols/GossipSubTests/GossipSubRouterTests.swift`

---

## Phase 3: Medium Priority Warnings（中優先度警告）

機能性やロバスト性に関する問題。

### 3.1 ✅ P2PMuxYamux - GoAway ハンドリング

**ファイル**: `Sources/Mux/Yamux/YamuxConnection.swift`

**問題**: GoAway 受信時に既存ストリームの終了処理が不足

**修正状況**: ✅ 修正済み

**実装内容**:
1. `handleGoAway()` でGoAway受信時の処理を実装
2. `isGoAwayReceived` フラグで新規ストリーム作成を禁止
3. 待機中の `pendingAccepts` を全てエラーで resume
4. `inboundContinuation.finish()` でinboundストリームを終了
5. 既存ストリームは自然に終了するまで継続（仕様通り）

**テスト**: `Tests/Mux/YamuxTests/YamuxConnectionTests.swift` - `goAwayClosesConnection`, `closeSendsGoAway`

---

### 3.2 ✅ P2PMuxYamux - receiveLoop 終了時リーク

**ファイル**: `Sources/Mux/Yamux/YamuxConnection.swift`

**問題**: receiveLoop 終了時に待機中の continuation が解放されない

**修正状況**: ✅ 修正済み

**実装内容**:
1. `abruptShutdown(error:)` で全continuation終了
2. `captureForShutdown()` で状態をアトミックにキャプチャ
3. `notifyContinuations(error:)` でpendingAcceptsをエラーresume
4. `resetAllStreams()` で全ストリームをリセット

**テスト**: `Tests/Mux/YamuxTests/YamuxConnectionTests.swift` - `closeNotifiesAllStreams`

---

### 3.3 ✅ P2PMuxYamux - ウィンドウサイズ検証

**ファイル**: `Sources/Mux/Yamux/YamuxStream.swift`

**問題**: ウィンドウサイズ更新時のオーバーフロー可能性

**修正状況**: ✅ 修正済み

**実装内容**:
1. `yamuxMaxWindowSize` 定数を追加（16MB）
2. `windowUpdate(delta:)` でUInt64算術を使用
3. `min(newWindow, yamuxMaxWindowSize)` でキャップ適用
4. オーバーフローを防止しつつ最大ウィンドウサイズを制限

**テスト**: `Tests/Mux/YamuxTests/YamuxStreamTests.swift` - `windowOverflowProtection`

---

### 3.4 ✅ P2PTransportTCP - デッドロック可能性

**ファイル**: `Sources/Transport/TCP/TCPListener.swift`

**問題**: inboundConnections の close() でハングする可能性

**修正状況**: ✅ 修正済み

**実装内容**:
1. `close()` で待機中の `acceptWaiters` を全てエラーresume
2. `pendingConnections` を全てクローズ
3. ロック外でresume実行（デッドロック回避）
4. `isClosed` フラグで二重close防止

**テスト**: `Tests/Transport/P2PTransportTests/TCPTransportTests.swift`

---

### 3.5 ✅ P2PTransportTCP - NestedMutex ロック

**ファイル**: `Sources/Transport/TCP/TCPListener.swift`

**問題**: state.withLock 内でのタスク起動による競合

**修正状況**: ✅ 修正済み

**実装内容**:
1. ロック内で結果を取得し、ロック外でresume実行
2. `connectionAccepted()` と `accept()` でロック外resume
3. `close()` でwaiterを先に取得してからresume

**テスト**: `Tests/Transport/P2PTransportTests/TCPTransportTests.swift`

---

### 3.6 ✅ P2PSecurityNoise - ロック競合

**ファイル**: `Sources/Security/Noise/NoiseConnection.swift`

**問題**: 高頻度 read/write での性能低下

**修正状況**: ✅ 修正済み

**実装内容**:
1. 単一 `Mutex<NoiseConnectionState>` を3つの分離されたロックに変更:
   - `sendState: Mutex<SendState>` - 送信暗号状態（write専用）
   - `recvState: Mutex<RecvState>` - 受信暗号状態+バッファ（read専用）
   - `sharedState: Mutex<SharedState>` - クローズフラグ（軽量、両方からアクセス）
2. `read()` と `write()` が独立して動作し、全二重通信でのロック競合を排除
3. ネットワーク I/O はロック外で実行

**テスト**: `Tests/Security/NoiseTests/NoiseIntegrationTests.swift` (71テスト全パス)

---

### 3.7 ✅ P2PNegotiation - 再帰的バッファリング

**ファイル**: `Sources/Negotiation/P2PNegotiation/MultistreamSelect.swift`

**問題**: 大きなプロトコルリストでスタック溢れ

**修正状況**: ✅ 修正済み

**実装内容**:
1. `maxProtocolCount = 100` 制限
2. `NegotiationError.tooManyProtocols` エラー
3. 反復的処理で再帰を回避

**テスト**: `Tests/Negotiation/P2PNegotiationTests/MultistreamSelectTests.swift`

---

### 3.8 ⏭️ P2PNegotiation - タイムアウト不足

**ファイル**: `Sources/Negotiation/P2PNegotiation/MultistreamSelect.swift`

**問題**: ネゴシエーションの無限待機

**ステータス**: ⏭️ 仕様準拠でスキップ

**理由**:
libp2p仕様（multistream-select）およびrust-libp2p/go-libp2p実装に準拠し、タイムアウトはトランスポート層で処理。ネゴシエーション層ではタイムアウトを設定せず、接続タイムアウトに委譲。

**コメント**: `P2PNegotiation.swift:75-76` に理由を記載

---

### 3.9 ✅ P2PKademlia - ルーティングテーブル無制限

**ファイル**: `Sources/Protocols/Kademlia/KademliaRoutingTable.swift`

**問題**: メモリ枯渇の可能性

**修正状況**: ✅ 修正済み

**実装内容**:
1. `KBucket` に `maxSize = 20` を設定（libp2p仕様の k 値）
2. `add()` でバケット満杯時は新規追加を拒否（LRU eviction）
3. `update()` で既存ピアの最終確認時刻を更新

**テスト**: `Tests/Protocols/KademliaTests/KademliaTests.swift`

---

### 3.10 ✅ P2PAutoNAT - IPv6 正規化

**ファイル**: `Sources/Protocols/AutoNAT/AutoNATService.swift`

**問題**: IPv6 アドレス比較の不一致

**修正状況**: ✅ 修正済み

**実装内容**:
1. `normalizeIPv6()` 関数で IPv6 アドレスを正規化
2. `::1` と `0:0:0:0:0:0:0:1` を同一アドレスとして比較
3. `NATState.updateReachability()` で正規化後に比較

**テスト**: `Tests/Protocols/AutoNATTests/AutoNATTests.swift`

---

### 3.11 ✅ P2PIdentify - readAll 切り捨て

**ファイル**: `Sources/Protocols/Identify/IdentifyService.swift`

**問題**: 大きな識別データの無言切り捨て

**修正状況**: ✅ 修正済み

**実装内容**:
1. `readAllData()` で `maxSize: 64 * 1024` (64KB) 上限を設定
2. 上限超過時は読み取りを停止
3. Identify メッセージの読み取りでサイズ制限を適用

**テスト**: `Tests/Protocols/IdentifyTests/IdentifyTests.swift`

---

### 3.12 ✅ P2PCircuitRelay - RelayListener リーク

**ファイル**: `Sources/Protocols/CircuitRelay/Transport/RelayListener.swift`

**問題**: shutdown 時の continuation 未処理

**修正状況**: ✅ 修正済み

**実装内容**:
1. `close()` で `continuation.finish()` を呼び出し
2. `acceptWaiter` をエラーでresume
3. `queuedConnections` を全てクローズ
4. `isClosed` フラグで二重close防止

**テスト**: `Tests/Protocols/CircuitRelayTests/CircuitRelayIntegrationTests.swift`

---

### 3.13 ✅ P2P Integration - Dictionary 同時変更

**ファイル**: `Sources/Integration/P2P/Connection/ConnectionPool.swift`

**問題**: ConnectionPool のレース条件

**修正状況**: ✅ 修正済み

**実装内容**:
1. `Mutex<PoolState>` で全ての状態を保護
2. `PoolState` 構造体で辞書操作をカプセル化
3. Node actor と連携したスレッドセーフ設計

**テスト**: `Tests/Integration/P2PTests/P2PTests.swift`

---

### 3.14 ✅ P2P Integration - 接続数無制限

**ファイル**: `Sources/Integration/P2P/Connection/ConnectionLimits.swift`

**問題**: リソース枯渇 DoS

**修正状況**: ✅ 修正済み

**実装内容**:
1. `ConnectionLimits` 構造体で制限を設定
   - `highWatermark`: 100（トリミング開始）
   - `lowWatermark`: 80（トリミング目標）
   - `maxConnectionsPerPeer`: 2
   - `maxInbound` / `maxOutbound`: オプション制限
2. `ConnectionPool.trimExcessConnections()` で自動トリミング
3. `gracePeriod` で新規接続を保護

**テスト**: `Tests/Integration/P2PTests/P2PTests.swift`

---

## Phase 4: 完了済み

以下の問題は修正済みです。

### ✅ P2PNegotiation - ls フォーマット修正
- 各行の長さプレフィックスを追加

### ✅ P2PNegotiation - UTF-8 検証追加
- 不正バイト列のハンドリング

### ✅ P2PGossipSub - MessageID SHA-256 化
- Swift Hasher から SHA-256 に変更
- ノード間で一貫した MessageID を生成

### ✅ P2PKademlia - クエリタイムアウト追加
- TaskGroup でタイムアウト制御
- デフォルト 30 秒

### ✅ P2PDCUtR - タイムアウトとリトライ追加
- hole punch にタイムアウト設定
- maxAttempts でリトライ制御

### ✅ P2PDiscoverySWIM - advertisedHost 自動検出
- bindHost と advertisedHost の分離
- 0.0.0.0 バインド時の自動検出

---

## 修正の進め方

各問題を修正する際は、以下の手順に従ってください：

1. **問題の理解**: 該当ファイルと CONTEXT.md を読む
2. **修正実装**: 上記の手順に従って修正
3. **テスト追加**: 修正を検証するテストを追加
4. **ビルド確認**: `swift build` で全体ビルド
5. **テスト実行**: `swift test --filter <TargetName>` で該当テスト実行
6. **ステータス更新**: このドキュメントの ⬜ を ✅ に変更

---

## 参考リンク

- [libp2p specs](https://github.com/libp2p/specs)
- [rust-libp2p](https://github.com/libp2p/rust-libp2p)
- [Yamux spec](https://github.com/hashicorp/yamux/blob/master/spec.md)
- [Noise Protocol](https://noiseprotocol.org/noise.html)
- [X25519 validation](https://cr.yp.to/ecdh.html#validate)
