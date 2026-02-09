# swift-libp2p AI Guidelines

> AI向けの開発ガイドライン。人間向けドキュメントは README.md と CONTRIBUTING.md を参照。

## Project Vision

**最終目標**: 自律ロボットが互いを発見し、能力を交換し、協調タスクを交渉・実行できる世界を実現する。

```
[1] 物理的に発見する     ← swift-libp2p (Discovery + Physical Transports)
[2] 能力を交換する       ← swift-p2p-capability（将来）
[3] タスクを交渉する     ← swift-p2p-task（将来）
[4] 協調実行する         ← swift-p2p-fleet（将来）
```

**swift-libp2p の責務**: ステップ[1]の全てと、[2]-[4]の通信基盤。IP通信（TCP/QUIC/WebSocket）に加え、物理メディア（BLE/WiFi Direct/LoRa）も Transport として統一管理する。Swarm が全 Transport を抽象化し、上位層は通信手段を意識しない。

### パッケージ構成

```
Desktop/
├── swift-libp2p/             # 統一P2P基盤（物理メディア含む）
│   ├── Swarm: 全Transport統一管理（go-libp2p swarm 相当）
│   ├── Transport: TCP, QUIC, WS, BLE, WiFi Direct, LoRa
│   ├── Discovery: mDNS, SWIM, CYCLON, Beacon（物理発見）
│   ├── Protocol: GossipSub, Kademlia, Propagation（Spray and Wait）
│   └── Security, Mux, NAT...
│
├── swift-p2p-capability/     # [2] 能力記述・照合・交換
├── swift-p2p-task/           # [3] タスク記述・交渉・合意
├── swift-p2p-fleet/          # [4] 協調実行・状態同期・障害復旧
│
├── swift-quic/               # QUIC transport（別repo）
├── swift-tls/                # TLS（別repo）
└── swift-webrtc/             # WebRTC（別repo）
```

### swift-p2p-discovery からの吸収マッピング

swift-p2p-discovery の6層アーキテクチャは swift-libp2p の既存アーキテクチャに全てマッピングされる:

| Discovery 層 | swift-libp2p での配置先 | 備考 |
|---|---|---|
| L0 Medium (TransportAdapter) | `Transport/P2PTransportBLE/` 等 | TCP/QUIC と同列の Transport 実装 |
| L1 Encoding (Beacon format) | `Discovery/P2PDiscoveryBeacon/` | mDNS/SWIM と同列の Discovery 実装 |
| L2 Coordination (Trickle) | `Discovery/P2PDiscoveryBeacon/` | Beacon Discovery の内部ロジック |
| L3 Aggregation (Presence) | `Discovery/P2PDiscoveryBeacon/` | PeerStore 拡張としても機能 |
| L4 Relay (Mesh routing) | `Protocols/P2PMeshRelay/` | 新概念: 物理メディア間ブリッジ・メッシュルーティング。CircuitRelay とは別の Protocol |
| L5 Propagation (Spray) | `Protocols/P2PPropagation/` | GossipSub と同列の Protocol 実装 |

### 設計上の重要判断

- **Swarm = 統一接続管理**: go-libp2p の swarm と同じ概念。IP Transport と Physical Transport の両方を管理する
- **BLE/WiFi/LoRa は Transport**: TCP/QUIC と同じ Transport protocol に準拠させる
- **Beacon Discovery は DiscoveryService**: mDNS/SWIM と同じ DiscoveryService protocol に準拠させる
- **Spray and Wait は Protocol**: GossipSub と同じ Protocol パターンで実装する
- **Physical Mesh Relay は新概念 Protocol**: CircuitRelay（IP中継）とは別の Protocol。物理メディア間ブリッジ（BLE↔WiFi↔LoRa）、動的メッシュルーティング、DTN store-and-forward を担当
- **上位層 [2][3][4] は Swarm 経由で通信**: BLE か TCP かを意識しない
- **libp2p 拡張は設計思想に沿う**: libp2p は Transport/Discovery/Protocol の拡張を前提に設計。BLE/WiFi Direct は specs ロードマップの "Visionary" カテゴリに存在

### 参照ドキュメント（swift-p2p-discovery）

物理発見の詳細仕様は swift-p2p-discovery リポジトリの以下を参照:

- `docs/LAYERED_DISCOVERY.md` (v3.1) — 6層アーキテクチャの実装仕様
- `docs/ARCHITECTURE.md` (v2.1) — 概念設計・将来のアイデア蓄積
- `docs/REQUIREMENTS.md` — ユースケースと要件定義

---

## ディレクトリ読み取りルール

**重要**: ディレクトリ配下のコードを読む際は、必ず先にそのディレクトリの`CONTEXT.md`を読むこと。

例:
- `Sources/Transport/` を読む前に → `Sources/Transport/CONTEXT.md`
- `Sources/Security/Noise/` を読む前に → `Sources/Security/Noise/CONTEXT.md`

---

## 核心ルール

### 1. Actor vs Class + Mutex

| 基準 | Actor | Class + Mutex |
|-----|-------|---------------|
| 操作頻度 | 低頻度 | 高頻度 |
| 処理時間 | 重い（I/O等） | 軽い |
| 用途 | ユーザー向けAPI | 内部実装 |

**迷ったら** → Class + Mutex（後からActorに変更は難しい）

### 2. イベントパターン

`AsyncStream<Event>` を公開する型には2つのパターンがある。**同一モジュール内では必ず同一パターンを使うこと。**

#### パターン選択基準

パターンは**プロトコルの性質**で決定する。同じレイヤー内でも性質が異なれば異なるパターンを使う。

| 基準 | EventEmitting（単一消費者） | EventBroadcaster（多消費者） |
|-----|--------------------------|---------------------------|
| 消費者数 | 1つの `for await` ループ | 複数の独立した `for await` ループ |
| `events` の意味 | 同じストリームを返す | 呼出しごとに新しいストリームを返す |
| プロトコル準拠 | `EventEmitting` | なし（プロトコル不要） |

**重要**: 2つのパターンは排他的。1つの型が両方に準拠してはならない。

#### プロトコル性質による分類

##### 1. リクエスト/レスポンス型 → EventEmitting

- **判断基準**: 単一機能、トピック/チャンネル概念なし、全イベントを1消費者が処理
- **イベント特性**: サービス全体の状態変化（接続、切断、エラー等）
- **実装例**: Ping, Identify, AutoNAT, DCUtR, Kademlia, RelayClient, RelayServer

##### 2. Pub/Sub型 → EventBroadcaster

- **判断基準**: 複数トピック、トピック別サブスクリプション、トピックごとに独立した消費者
- **イベント特性**: トピックごとのメッセージ配信（`subscribe(to: Topic)`）
- **実装例**: GossipSub, Plumtree

##### 3. Discovery型 → EventBroadcaster

- **判断基準**: ピア観察、ピア別フィルタ、異なる消費者が異なるピアを監視
- **イベント特性**: ピアごとの観察イベント（`subscribe(to: PeerID)`）
- **実装例**: SWIM, mDNS, CYCLON, CompositeDiscovery

##### 判断フロー

```
1. Discovery層のDiscoveryServiceか？
   YES → EventBroadcaster

2. Protocols層で複数トピック/チャンネルを持つか？
   YES → EventBroadcaster (Pub/Sub型)
   NO  → EventEmitting (リクエスト/レスポンス型)
```

#### パターンA: EventEmitting（単一消費者）

```swift
public final class MyService: EventEmitting, Sendable {
    // イベント状態（専用）
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<MyEvent>?
        var continuation: AsyncStream<MyEvent>.Continuation?
    }

    // 業務状態（分離）
    private let serviceState: Mutex<ServiceState>

    // events: 同じストリームを返す（単一消費者）
    public var events: AsyncStream<MyEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<MyEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    private func emit(_ event: MyEvent) {
        eventState.withLock { $0.continuation?.yield(event) }
    }

    // EventEmitting 準拠
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()  // 必須！
            state.continuation = nil
            state.stream = nil            // 必須！
        }
    }
}
```

**注意**: `continuation.finish()` と `stream = nil` の両方が必須。どちらかが欠けると `for await` がハングする。

#### パターンB: EventBroadcaster（多消費者）

```swift
public final class MyService: Sendable {
    private let broadcaster = EventBroadcaster<MyEvent>()

    // events: 呼出しごとに新しいストリームを返す（多消費者）
    public var events: AsyncStream<MyEvent> {
        broadcaster.subscribe()
    }

    private func emit(_ event: MyEvent) {
        broadcaster.emit(event)
    }

    // ライフサイクル終了
    public func shutdown() {
        broadcaster.shutdown()
    }

    deinit {
        broadcaster.shutdown()  // idempotent
    }
}
```

actor で使う場合は `nonisolated let` で宣言する:

```swift
public actor MyActor {
    private nonisolated let broadcaster = EventBroadcaster<MyEvent>()

    public nonisolated var events: AsyncStream<MyEvent> {
        broadcaster.subscribe()
    }
}
```

#### Mutex 内でのイベント発行禁止

Mutex ロック内から直接 `emit()` を呼ばない。ロック内でイベントを収集し、ロック外で発行する:

```swift
// BAD: ネストロックの危険
func doWork() {
    state.withLock { s in
        // ... 状態変更 ...
        broadcaster.emit(.changed)  // ← broadcaster 内部にも Mutex がある
    }
}

// GOOD: ロック外で発行
func doWork() {
    let pendingEvents = state.withLock { s -> [MyEvent] in
        // ... 状態変更 ...
        return [.changed]
    }
    for event in pendingEvents {
        broadcaster.emit(event)
    }
}
```

### 3. 同一モジュール統一原則

同一モジュール内の型は以下を統一すること:

- **並行処理モデル**: Actor か Class+Mutex か（ルール1の基準で判定）
- **イベントパターン**: EventEmitting か EventBroadcaster か（ルール2の基準で判定）
- **ライフサイクルメソッド**: レイヤーごとに統一（下記参照）

新しい型を追加する際は、まずそのモジュール内の既存の型を確認し、同じパターンに従うこと。

#### ライフサイクルメソッド統一

| レイヤー | メソッド | シグネチャ | 理由 |
|---------|---------|-----------|------|
| Protocols層 | `shutdown()` | `func shutdown()` | EventEmittingプロトコル準拠 |
| Discovery層 | `stop()` | `func stop() async` | 非同期リソース（トランスポート/ブラウザ）のクリーンアップ |
| Transport/Mux/Security層 | `close()` | `func close() async throws` | I/O完了待ち |

**Discovery層の統一ルール**:
- すべてのDiscoveryServiceは `func stop() async` を実装
- 理由: 内部で非同期リソース（`await transport.stop()`, `await browser.stop()`）を停止する必要がある
- `deinit` では `await` 不可のため、`stop()` で明示的に停止

**実装状況** (2026-02-03更新):
- ✅ `SWIMMembership` - `func stop() async` 実装済み
- ✅ `MDNSDiscovery` - `func stop() async` 実装済み
- ✅ `CYCLONDiscovery` - `func stop() async` 実装済み
- ✅ `CompositeDiscovery` - `func stop() async` 実装済み（内部サービスも停止）

**CompositeDiscoveryの重要な制約**:
- CompositeDiscoveryは提供されたサービスの所有権を取得する
- 各サービスインスタンスは1つのCompositeDiscoveryのみが使用すること
- CompositeDiscoveryに追加後は、サービスを直接使用しないこと
- `stop()`は必ず呼び出すこと（内部サービスも停止される）

### 4. エラーハンドリング

```swift
// BAD: エラーを握りつぶす
let addr = try? channel.localAddress?.toMultiaddr()

// GOOD: エラーを伝播
let addr = try channel.localAddress?.toMultiaddr()
```

### 5. Sendable

`@unchecked Sendable` は使わない。`Mutex<T>` で解決する。

---

## テスト実行

**必須**: タイムアウトを設定する

```bash
swift test --filter TargetName 2>&1 &
PID=$!; sleep 30; kill $PID 2>/dev/null || wait $PID
```

**ハング時**: AsyncStream、Task、continuation の未完了を疑う。
