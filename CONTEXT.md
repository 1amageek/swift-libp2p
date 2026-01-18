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

### 2.4 ⬜ P2PCore - Multiaddr 解析 DoS

**ファイル**: `Sources/Core/P2PCore/Addressing/Multiaddr.swift`

**問題**: 大きな入力でメモリ過剰消費

**修正手順**:
1. 入力サイズ上限を設定（例: 1KB）
2. コンポーネント数上限を設定（例: 20）
3. 上限超過時は明示的なエラーをスロー

**テスト**: `Tests/Core/P2PCoreTests/MultiaddrTests.swift`

---

### 2.5 ⬜ P2PGossipSub - 署名検証不足

**ファイル**: `Sources/Protocols/GossipSub/GossipSubRouter.swift`

**問題**: StrictSign モード時の署名検証が未実装

**修正手順**:
1. メッセージ受信時に `signature` フィールドを検証
2. `from` フィールドの PeerID から公開鍵を取得
3. 署名が無効な場合はメッセージを破棄
4. イベントを発火してアプリケーションに通知

**テスト**: `Tests/Protocols/GossipSubTests/SignatureValidationTests.swift`

---

## Phase 3: Medium Priority Warnings（中優先度警告）

機能性やロバスト性に関する問題。

### 3.1 ⬜ P2PMuxYamux - GoAway ハンドリング

**ファイル**: `Sources/Mux/Yamux/YamuxSession.swift`

**問題**: GoAway 受信時に既存ストリームの終了処理が不足

**修正手順**:
1. GoAway 受信時に全ストリームに EOF を通知
2. 新規ストリーム作成を禁止
3. 待機中の continuation をすべて resume

**テスト**: `Tests/Mux/YamuxTests/YamuxGoAwayTests.swift`

---

### 3.2 ⬜ P2PMuxYamux - receiveLoop 終了時リーク

**ファイル**: `Sources/Mux/Yamux/YamuxSession.swift`

**問題**: receiveLoop 終了時に待機中の continuation が解放されない

**修正手順**:
1. receiveLoop 終了時に全 continuation をエラーで resume
2. streamQueues のクリーンアップ処理を追加

**テスト**: `Tests/Mux/YamuxTests/YamuxCleanupTests.swift`

---

### 3.3 ⬜ P2PMuxYamux - ウィンドウサイズ検証

**ファイル**: `Sources/Mux/Yamux/YamuxSession.swift`

**問題**: ウィンドウサイズ更新時のオーバーフロー可能性

**修正手順**:
1. ウィンドウ更新時に `UInt32.max` を超えないかチェック
2. オーバーフロー時は接続を RST で閉じる

**テスト**: `Tests/Mux/YamuxTests/YamuxWindowTests.swift`

---

### 3.4 ⬜ P2PTransportTCP - デッドロック可能性

**ファイル**: `Sources/Transport/TCP/TCPTransport.swift`

**問題**: inboundConnections の close() でハングする可能性

**修正手順**:
1. AsyncStream 終了時のクリーンアップ処理を確認
2. continuation.finish() の呼び出しを保証
3. タイムアウト付きシャットダウンの検討

**テスト**: `Tests/Transport/TCPTests/TCPTransportShutdownTests.swift`

---

### 3.5 ⬜ P2PTransportTCP - NestedMutex ロック

**ファイル**: `Sources/Transport/TCP/TCPTransport.swift`

**問題**: state.withLock 内でのタスク起動による競合

**修正手順**:
1. ロック内でのタスク起動を避ける
2. 必要なデータをロック内で取得し、ロック外でタスク起動

**テスト**: `Tests/Transport/TCPTests/TCPConcurrencyTests.swift`

---

### 3.6 ⬜ P2PSecurityNoise - ロック競合

**ファイル**: `Sources/Security/Noise/NoiseSecuredConnection.swift`

**問題**: 高頻度 read/write での性能低下

**修正手順**:
1. read と write で別々のロックを使用
2. または、ロックフリーの設計を検討

**テスト**: パフォーマンステスト

---

### 3.7 ⬜ P2PNegotiation - 再帰的バッファリング

**ファイル**: `Sources/Negotiation/P2PNegotiation/MultistreamSelect.swift`

**問題**: 大きなプロトコルリストでスタック溢れ

**修正手順**:
1. プロトコルリスト数に上限を設定（例: 100）
2. 再帰を反復に変更

**テスト**: `Tests/Negotiation/P2PNegotiationTests/LargeProtocolListTests.swift`

---

### 3.8 ⬜ P2PNegotiation - タイムアウト不足

**ファイル**: `Sources/Negotiation/P2PNegotiation/MultistreamSelect.swift`

**問題**: ネゴシエーションの無限待機

**修正手順**:
1. ネゴシエーション全体にタイムアウトを設定（デフォルト: 30秒）
2. 設定可能なパラメータとして公開

**テスト**: `Tests/Negotiation/P2PNegotiationTests/TimeoutTests.swift`

---

### 3.9 ⬜ P2PKademlia - ルーティングテーブル無制限

**ファイル**: `Sources/Protocols/Kademlia/KademliaRoutingTable.swift`

**問題**: メモリ枯渇の可能性

**修正手順**:
1. k-bucket サイズを k=20 に制限（仕様通り）
2. バケット溢れ時の eviction ポリシーを実装

**テスト**: `Tests/Protocols/KademliaTests/RoutingTableTests.swift`

---

### 3.10 ⬜ P2PAutoNAT - IPv6 正規化

**ファイル**: `Sources/Protocols/AutoNAT/AutoNATService.swift`

**問題**: IPv6 アドレス比較の不一致

**修正手順**:
1. IPv6 アドレスを正規化してから比較
2. `::1` と `0:0:0:0:0:0:0:1` を同一視

**テスト**: `Tests/Protocols/AutoNATTests/IPv6NormalizationTests.swift`

---

### 3.11 ⬜ P2PIdentify - readAll 切り捨て

**ファイル**: `Sources/Protocols/Identify/IdentifyService.swift`

**問題**: 大きな識別データの無言切り捨て

**修正手順**:
1. 読み取りサイズ上限を明示（例: 64KB）
2. 上限超過時はエラーまたは警告ログ

**テスト**: `Tests/Protocols/IdentifyTests/LargePayloadTests.swift`

---

### 3.12 ⬜ P2PCircuitRelay - RelayListener リーク

**ファイル**: `Sources/Protocols/CircuitRelay/RelayListener.swift`

**問題**: shutdown 時の continuation 未処理

**修正手順**:
1. shutdown() で全 continuation を finish/resume
2. AsyncStream の適切な終了を保証

**テスト**: `Tests/Protocols/CircuitRelayTests/RelayListenerShutdownTests.swift`

---

### 3.13 ⬜ P2P Integration - Dictionary 同時変更

**ファイル**: `Sources/Integration/P2P/Connection/ConnectionManager.swift`

**問題**: ConnectionManager のレース条件

**修正手順**:
1. Dictionary 操作を Mutex で保護
2. または actor に変更

**テスト**: `Tests/Integration/P2PTests/ConnectionManagerConcurrencyTests.swift`

---

### 3.14 ⬜ P2P Integration - 接続数無制限

**ファイル**: `Sources/Integration/P2P/Connection/ConnectionManager.swift`

**問題**: リソース枯渇 DoS

**修正手順**:
1. 最大接続数を設定可能に（デフォルト: 100）
2. 上限超過時は古い接続を閉じるか新規を拒否

**テスト**: `Tests/Integration/P2PTests/ConnectionLimitTests.swift`

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
