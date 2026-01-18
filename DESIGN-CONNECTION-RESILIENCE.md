# Connection Resilience 設計書

> **目的**: 接続の安定性向上、自動再接続、リソース管理
> **参考**: go-libp2p (ConnManager, BackoffConnector), rust-libp2p (ConnectionPool, ConnectionHandler)

---

## 1. 設計概要

### 1.1 Go/Rust からの学び

| 概念 | go-libp2p | rust-libp2p | swift-libp2p (本設計) |
|-----|-----------|-------------|----------------------|
| 接続プール | ConnManager | ConnectionPool | ConnectionPool |
| 接続状態 | 暗黙的 | PoolEvent | ConnectionState enum |
| バックオフ | BackoffConnector (指数) | dial_concurrency | BackoffStrategy (指数+ジッター) |
| 接続制限 | High/Low Watermarks | ConnectionCounters | ConnectionLimits (High/Low) |
| アイドルタイムアウト | Grace Period | idle_connection_timeout | idleTimeout |
| ヘルスチェック | 外部 (Ping) | connection_keep_alive | HealthMonitor (PingService注入) |
| 接続ゲート | ConnectionGater (5段階) | NetworkBehaviour | ConnectionGater (3段階) |

### 1.2 責務境界の明確化

```
┌─────────────────────────────────────────────────────────────────┐
│                        Node (actor)                             │
│  【責務】公開API提供、イベント発行                                │
│  【操作】connect, disconnect, newStream, tag, protect           │
│  【原則】状態は持たない。全てPoolに委譲する。                      │
├─────────────────────────────────────────────────────────────────┤
│                ConnectionPool (internal, class + Mutex)         │
│  【責務】唯一の接続状態管理者                                    │
│  【操作】add, remove, get, trim, reconnect scheduling           │
│  【原則】Node以外からアクセスされない。internal修飾子で保護。      │
├─────────────────────────────────────────────────────────────────┤
│  BackoffStrategy  │ ConnectionLimits │ HealthMonitor (actor)    │
│  (struct, 純粋)   │ (struct, 設定)    │ PingService注入          │
└───────────────────┴──────────────────┴──────────────────────────┘
```

**責務境界の原則:**

| コンポーネント | 責務 | 状態所有 | アクセス範囲 |
|--------------|------|---------|-------------|
| **Node** | 公開API、イベント発行 | なし | public |
| **ConnectionPool** | 接続状態管理、トリミング | 全接続状態 | internal (Node専用) |
| **HealthMonitor** | 死活監視タスク管理 | 監視タスク | internal |

**なぜ ConnectionPool は class + Mutex なのか:**

1. **internal限定**: Node actorからのみアクセスされるため、外部並列呼び出しは発生しない
2. **Node actor内で直列化済み**: Node自体がactorなので、Pool へのアクセスは自動的に直列化される
3. **高頻度操作の最適化**: actor hop のオーバーヘッドを避け、細粒度ロックで効率化

```swift
// Node (actor) 内でのPoolアクセス - 自動的に直列化される
public actor Node {
    // internal - 外部からアクセス不可
    private let pool: ConnectionPool

    public func connect(to address: Multiaddr) async throws -> PeerID {
        // この時点でNode actorにより直列化されている
        // Poolへのアクセスは安全
        ...
    }
}
```

---

## 2. 接続状態マシン

### 2.1 状態定義

```swift
/// 接続の状態
public enum ConnectionState: Sendable {
    /// 接続試行中
    case connecting

    /// 接続確立済み
    case connected

    /// 切断済み (再接続可能)
    case disconnected(reason: DisconnectReason)

    /// 再接続試行中
    case reconnecting(attempt: Int, nextAttempt: ContinuousClock.Instant)

    /// 完全に失敗 (再接続上限到達またはポリシーで無効)
    case failed(reason: DisconnectReason)
}

/// 切断理由
///
/// - Note: Equatableを実装するため、エラーはコードで識別する
public enum DisconnectReason: Sendable, Equatable {
    /// ローカル側から切断
    case localClose

    /// リモート側から切断
    case remoteClose

    /// タイムアウト
    case timeout

    /// アイドルタイムアウト
    case idleTimeout

    /// ヘルスチェック失敗
    case healthCheckFailed

    /// 接続制限による切断
    case connectionLimitExceeded

    /// 接続がゲートされた
    case gated(stage: GateStage)

    /// エラー (コードで識別)
    case error(code: DisconnectErrorCode, message: String)

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        switch (lhs, rhs) {
        case (.localClose, .localClose),
             (.remoteClose, .remoteClose),
             (.timeout, .timeout),
             (.idleTimeout, .idleTimeout),
             (.healthCheckFailed, .healthCheckFailed),
             (.connectionLimitExceeded, .connectionLimitExceeded):
            return true
        case (.gated(let l), .gated(let r)):
            return l == r
        case (.error(let lCode, _), .error(let rCode, _)):
            return lCode == rCode  // メッセージは比較しない
        default:
            return false
        }
    }
}

/// 切断エラーコード
public enum DisconnectErrorCode: Sendable, Equatable {
    case transportError
    case securityError
    case muxerError
    case protocolError
    case internalError
    case unknown
}

/// ゲートのステージ
public enum GateStage: Sendable, Equatable {
    case dial
    case accept
    case secured
}
```

### 2.2 状態遷移図

```
                         ┌───────────────┐
                         │     Idle      │ (接続情報なし)
                         └───────┬───────┘
                                 │ dial()
                                 ▼
                         ┌───────────────┐
              ┌─────────▶│  Connecting   │
              │          └───────┬───────┘
              │                  │ success
              │                  ▼
              │          ┌───────────────┐
              │   ┌──────│   Connected   │◀─────────────┐
              │   │      └───────┬───────┘              │
              │   │              │ disconnect/error     │
              │   │              ▼                      │
              │   │      ┌───────────────┐              │
              │   │      │ Disconnected  │              │
              │   │      └───────┬───────┘              │
              │   │              │                      │
              │   │   autoReconnect?                    │
              │   │     /         \                     │
              │   │   yes          no                   │
              │   │    │            │                   │
              │   │    ▼            ▼                   │
              │   │ ┌──────────┐  ┌────────┐           │
              │   │ │Reconnect-│  │ Failed │           │
              │   │ │  ing     │  └────────┘           │
              │   │ └────┬─────┘                       │
              │   │      │                             │
              │   │  success ──────────────────────────┘
              │   │      │
              │   │  failure (retry < max)
              │   │      │
              │   └──────┴──▶ (loop with backoff)
              │
              │   failure (retry >= max)
              │          │
              │          ▼
              │   ┌───────────────┐
              └───│    Failed     │
                  └───────────────┘
```

---

## 3. コンポーネント設計

### 3.1 ConnectionPool

接続のライフサイクルを管理する中核コンポーネント。
**Node actorからのみアクセスされる内部実装。**

```swift
/// 接続プール
///
/// 全接続の状態を管理し、制限を適用する。
///
/// - Important: このクラスはNode actor内でのみ使用される内部実装。
///   外部から直接アクセスしてはならない。Node actorにより直列化が保証される。
internal final class ConnectionPool: Sendable {

    /// プール設定
    struct Configuration: Sendable {
        var limits: ConnectionLimits
        var reconnectionPolicy: ReconnectionPolicy
        var idleTimeout: Duration
        var gater: (any ConnectionGater)?
    }

    /// 管理対象の接続情報
    struct ManagedConnection: Sendable {
        let id: ConnectionID
        let peer: PeerID
        let address: Multiaddr
        let direction: ConnectionDirection
        var connection: MuxedConnection?
        var state: ConnectionState
        var retryCount: Int
        var lastActivity: ContinuousClock.Instant
        var connectedAt: ContinuousClock.Instant?
        var tags: Set<String>
        var isProtected: Bool
    }

    private let state: Mutex<PoolState>

    private struct PoolState: Sendable {
        var connections: [ConnectionID: ManagedConnection]
        var peerConnections: [PeerID: Set<ConnectionID>]

        /// 同一peerへの同時dial防止用
        /// - Key: PeerID
        /// - Value: 進行中のdialタスク
        ///
        /// ## 同時dial時の挙動
        /// 既にdial中のpeerに対してconnect()が呼ばれた場合:
        /// - 既存のTaskに合流 (await) して同じ結果を返す
        /// - 新規dialは開始しない
        var pendingDials: [PeerID: Task<PeerID, any Error>]
    }

    // MARK: - Lifecycle Management

    /// 接続を追加
    ///
    /// - Returns: 新しいConnectionID
    func add(_ connection: MuxedConnection,
             for peer: PeerID,
             address: Multiaddr,
             direction: ConnectionDirection) -> ConnectionID

    /// 接続を削除
    func remove(_ id: ConnectionID) -> ManagedConnection?

    /// 状態を更新
    func updateState(_ id: ConnectionID, to state: ConnectionState)

    // MARK: - Query

    /// ピアへの接続を取得 (最初の1つ)
    func connection(to peer: PeerID) -> MuxedConnection?

    /// ピアへの全接続を取得
    func connections(to peer: PeerID) -> [MuxedConnection]

    /// 接続状態を取得
    func state(of peer: PeerID) -> ConnectionState?

    /// 全接続済みピア
    var connectedPeers: [PeerID] { get }

    /// 接続数
    var connectionCount: Int { get }

    // MARK: - Tagging & Protection

    /// タグを追加 (トリム優先度に影響)
    func tag(_ peer: PeerID, with tag: String)

    /// タグを削除
    func untag(_ peer: PeerID, tag: String)

    /// 接続を保護 (トリム対象外)
    func protect(_ peer: PeerID)

    /// 保護を解除
    func unprotect(_ peer: PeerID)

    // MARK: - Trimming

    /// 制限を超過している場合に接続をトリム
    ///
    /// - Returns: トリムされた接続のリスト
    func trimIfNeeded() -> [ManagedConnection]

    // MARK: - Reconnection

    /// 自動再接続を有効化
    func enableAutoReconnect(for peer: PeerID, address: Multiaddr)

    /// 自動再接続を無効化
    func disableAutoReconnect(for peer: PeerID)

    // MARK: - Pending Dials

    /// 同一peerへのdialが進行中か確認
    func hasPendingDial(to peer: PeerID) -> Bool

    /// 進行中のdialタスクを取得 (合流用)
    func pendingDial(to peer: PeerID) -> Task<PeerID, any Error>?

    /// dialタスクを登録
    func registerPendingDial(_ task: Task<PeerID, any Error>, for peer: PeerID)

    /// dialタスクを削除
    func removePendingDial(for peer: PeerID)

    // MARK: - Activity Tracking

    /// アクティビティを記録
    func recordActivity(_ id: ConnectionID)

    /// アイドル接続を取得
    func idleConnections(threshold: Duration) -> [ManagedConnection]
}
```

### 3.2 ConnectionLimits

```swift
/// 接続制限設定
public struct ConnectionLimits: Sendable {

    /// High watermark - この数を超えたらトリミング開始
    public var highWatermark: Int

    /// Low watermark - トリミングの目標値
    public var lowWatermark: Int

    /// ピアあたりの最大接続数
    public var maxConnectionsPerPeer: Int

    /// インバウンド接続の最大数
    public var maxInbound: Int?

    /// アウトバウンド接続の最大数
    public var maxOutbound: Int?

    /// 新規接続の猶予期間 (この間はトリム対象外)
    public var gracePeriod: Duration

    /// デフォルト設定
    public static let `default` = ConnectionLimits(
        highWatermark: 100,
        lowWatermark: 80,
        maxConnectionsPerPeer: 2,
        maxInbound: nil,
        maxOutbound: nil,
        gracePeriod: .seconds(30)
    )

    /// 開発/テスト用の緩い設定
    public static let development = ConnectionLimits(
        highWatermark: 50,
        lowWatermark: 40,
        maxConnectionsPerPeer: 3,
        maxInbound: nil,
        maxOutbound: nil,
        gracePeriod: .seconds(10)
    )

    public init(
        highWatermark: Int = 100,
        lowWatermark: Int = 80,
        maxConnectionsPerPeer: Int = 2,
        maxInbound: Int? = nil,
        maxOutbound: Int? = nil,
        gracePeriod: Duration = .seconds(30)
    ) {
        precondition(lowWatermark <= highWatermark, "lowWatermark must be <= highWatermark")
        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
        self.maxConnectionsPerPeer = maxConnectionsPerPeer
        self.maxInbound = maxInbound
        self.maxOutbound = maxOutbound
        self.gracePeriod = gracePeriod
    }
}
```

### 3.3 BackoffStrategy

```swift
/// バックオフ戦略
///
/// 再接続時の待機時間を計算する純粋関数型の構造体。
///
/// - Note: Duration計算時にDouble経由で軽微な精度損失が発生するが、
///   再接続のタイミング用途では許容範囲内。
public struct BackoffStrategy: Sendable {

    /// バックオフの種類
    public enum Kind: Sendable {
        /// 指数バックオフ: base * multiplier^attempt
        case exponential(base: Duration, multiplier: Double, max: Duration)

        /// 固定間隔
        case constant(Duration)

        /// 線形増加: base + (increment * attempt)
        case linear(base: Duration, increment: Duration, max: Duration)
    }

    /// バックオフの種類
    public let kind: Kind

    /// ジッター (0.0-1.0) - ランダムな変動を加える
    public let jitter: Double

    /// デフォルト (指数バックオフ)
    public static let `default` = BackoffStrategy(
        kind: .exponential(
            base: .milliseconds(100),
            multiplier: 2.0,
            max: .minutes(5)
        ),
        jitter: 0.1
    )

    /// 積極的な再接続 (短い間隔)
    public static let aggressive = BackoffStrategy(
        kind: .exponential(
            base: .milliseconds(50),
            multiplier: 1.5,
            max: .seconds(30)
        ),
        jitter: 0.2
    )

    public init(kind: Kind, jitter: Double = 0.1) {
        precondition(jitter >= 0 && jitter <= 1, "jitter must be in range 0.0...1.0")
        self.kind = kind
        self.jitter = jitter
    }

    /// 次の待機時間を計算
    ///
    /// - Parameter attempt: 試行回数 (0から開始)
    /// - Returns: 待機すべき時間
    ///
    /// - Note: Double経由の計算により軽微な精度損失あり (ミリ秒単位で許容)
    public func delay(for attempt: Int) -> Duration {
        let baseDelay: Duration

        switch kind {
        case .exponential(let base, let multiplier, let max):
            let calculated = base.scaled(by: pow(multiplier, Double(attempt)))
            baseDelay = min(calculated, max)

        case .constant(let duration):
            baseDelay = duration

        case .linear(let base, let increment, let max):
            let calculated = base + increment.scaled(by: Double(attempt))
            baseDelay = min(calculated, max)
        }

        // ジッターを適用
        guard jitter > 0 else { return baseDelay }

        let jitterRange = baseDelay.asSeconds * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)
        return baseDelay.adding(seconds: randomJitter)
    }
}

// MARK: - Duration Extensions

extension Duration {
    /// 秒数としての値 (軽微な精度損失あり)
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// スケーリング
    func scaled(by factor: Double) -> Duration {
        .seconds(asSeconds * factor)
    }

    /// 秒数を加算
    func adding(seconds: Double) -> Duration {
        .seconds(asSeconds + seconds)
    }
}

extension Duration {
    static func min(_ a: Duration, _ b: Duration) -> Duration {
        a < b ? a : b
    }
}
```

### 3.4 ReconnectionPolicy

```swift
/// 再接続ポリシー
public struct ReconnectionPolicy: Sendable {

    /// 自動再接続を有効にするか
    public var enabled: Bool

    /// 最大再試行回数
    public var maxRetries: Int

    /// バックオフ戦略
    public var backoff: BackoffStrategy

    /// 成功後にリトライカウントをリセットする閾値
    /// (この時間以上接続が維持されたらカウントリセット)
    public var resetThreshold: Duration

    /// 再接続を無効化
    public static let disabled = ReconnectionPolicy(
        enabled: false,
        maxRetries: 0,
        backoff: .default,
        resetThreshold: .seconds(30)
    )

    /// デフォルト
    public static let `default` = ReconnectionPolicy(
        enabled: true,
        maxRetries: 10,
        backoff: .default,
        resetThreshold: .seconds(30)
    )

    /// 積極的 (頻繁に再試行)
    public static let aggressive = ReconnectionPolicy(
        enabled: true,
        maxRetries: 20,
        backoff: .aggressive,
        resetThreshold: .seconds(15)
    )

    public init(
        enabled: Bool = true,
        maxRetries: Int = 10,
        backoff: BackoffStrategy = .default,
        resetThreshold: Duration = .seconds(30)
    ) {
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.backoff = backoff
        self.resetThreshold = resetThreshold
    }
}
```

### 3.5 ConnectionGater

```swift
/// 接続ゲーター
///
/// 接続の確立を制御するためのプロトコル。
///
/// ## ゲーティングポイント
///
/// 1. **interceptDial**: ダイアル開始前
/// 2. **interceptAccept**: インバウンド接続受信時 (upgrade前)
/// 3. **interceptSecured**: セキュリティハンドシェイク後
///
/// - Note: muxer選択後のゲーティングは提供しない。
///   セキュリティ確立後にピアIDが判明するため、interceptSecuredで十分な制御が可能。
///   muxer選択はセキュリティ後に行われ、この時点で拒否するユースケースは稀。
public protocol ConnectionGater: Sendable {

    /// ダイアル前に呼ばれる
    ///
    /// - Parameters:
    ///   - peer: 接続先ピア (アドレスに含まれる場合)
    ///   - address: 接続先アドレス
    /// - Returns: 接続を許可する場合はtrue
    func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool

    /// インバウンド接続受信時に呼ばれる (upgrade前)
    ///
    /// - Parameter address: 接続元アドレス
    /// - Returns: 接続を許可する場合はtrue
    func interceptAccept(address: Multiaddr) -> Bool

    /// セキュリティハンドシェイク後に呼ばれる
    ///
    /// ピアIDが認証された後の最終チェック。
    /// この後muxer選択が行われるが、追加のゲーティングは不要
    /// (ピアベースのポリシーはここで適用可能)。
    ///
    /// - Parameters:
    ///   - peer: 認証されたピア
    ///   - direction: 接続方向
    /// - Returns: 接続を許可する場合はtrue
    func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool
}

/// 接続方向
public enum ConnectionDirection: Sendable, Equatable {
    case inbound
    case outbound
}

/// デフォルトのゲーター (全て許可)
public struct AllowAllGater: ConnectionGater {
    public init() {}

    public func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool { true }
    public func interceptAccept(address: Multiaddr) -> Bool { true }
    public func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool { true }
}

/// ブロックリストベースのゲーター
public final class BlocklistGater: ConnectionGater, Sendable {
    private let blockedPeers: Mutex<Set<PeerID>>
    private let blockedAddresses: Mutex<Set<String>>

    public init() {
        self.blockedPeers = Mutex([])
        self.blockedAddresses = Mutex([])
    }

    public func block(peer: PeerID) {
        blockedPeers.withLock { $0.insert(peer) }
    }

    public func unblock(peer: PeerID) {
        blockedPeers.withLock { $0.remove(peer) }
    }

    public func block(address: String) {
        blockedAddresses.withLock { $0.insert(address) }
    }

    public func unblock(address: String) {
        blockedAddresses.withLock { $0.remove(address) }
    }

    public func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool {
        if let peer = peer {
            if blockedPeers.withLock({ $0.contains(peer) }) {
                return false
            }
        }
        return !blockedAddresses.withLock { $0.contains(address.description) }
    }

    public func interceptAccept(address: Multiaddr) -> Bool {
        !blockedAddresses.withLock { $0.contains(address.description) }
    }

    public func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool {
        !blockedPeers.withLock { $0.contains(peer) }
    }
}
```

### 3.6 HealthMonitor

```swift
/// ヘルスモニター
///
/// PingServiceを使用して接続の生存確認を行う。
public actor HealthMonitor {

    /// 設定
    public struct Configuration: Sendable {
        /// チェック間隔
        public var interval: Duration

        /// Pingタイムアウト
        public var timeout: Duration

        /// 連続失敗の許容回数
        public var maxFailures: Int

        /// デフォルト
        public static let `default` = Configuration(
            interval: .seconds(30),
            timeout: .seconds(10),
            maxFailures: 3
        )
    }

    /// PingService への参照を提供するプロトコル
    public protocol PingProvider: Sendable {
        /// ピアにpingを送信し、RTTを返す
        func ping(_ peer: PeerID) async throws -> Duration
    }

    private let configuration: Configuration
    private let pingProvider: any PingProvider
    private var monitoringTasks: [PeerID: Task<Void, Never>] = [:]
    private var failureCounts: [PeerID: Int] = [:]

    /// 失敗時のコールバック
    public var onHealthCheckFailed: (@Sendable (PeerID) async -> Void)?

    public init(
        configuration: Configuration = .default,
        pingProvider: any PingProvider
    ) {
        self.configuration = configuration
        self.pingProvider = pingProvider
    }

    /// ピアの監視を開始
    public func startMonitoring(peer: PeerID) {
        guard monitoringTasks[peer] == nil else { return }

        let task = Task { [weak self, configuration, pingProvider] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: configuration.interval)

                    // Ping with timeout
                    _ = try await withThrowingTaskGroup(of: Duration.self) { group in
                        group.addTask {
                            try await pingProvider.ping(peer)
                        }
                        group.addTask {
                            try await Task.sleep(for: configuration.timeout)
                            throw HealthCheckError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }

                    // 成功したらカウントリセット
                    await self?.resetFailureCount(for: peer)

                } catch is CancellationError {
                    break
                } catch {
                    await self?.recordFailure(for: peer)
                }
            }
        }

        monitoringTasks[peer] = task
    }

    /// ピアの監視を停止
    public func stopMonitoring(peer: PeerID) {
        monitoringTasks[peer]?.cancel()
        monitoringTasks[peer] = nil
        failureCounts[peer] = nil
    }

    /// 全監視を停止
    public func stopAll() {
        for task in monitoringTasks.values {
            task.cancel()
        }
        monitoringTasks.removeAll()
        failureCounts.removeAll()
    }

    private func resetFailureCount(for peer: PeerID) {
        failureCounts[peer] = 0
    }

    private func recordFailure(for peer: PeerID) async {
        let count = (failureCounts[peer] ?? 0) + 1
        failureCounts[peer] = count

        if count >= configuration.maxFailures {
            failureCounts[peer] = 0
            await onHealthCheckFailed?(peer)
        }
    }
}

enum HealthCheckError: Error {
    case timeout
}
```

---

## 4. イベントシステム

### 4.1 ConnectionEvent

```swift
/// 接続関連のイベント
public enum ConnectionEvent: Sendable {
    /// 接続が確立された
    case connected(peer: PeerID, address: Multiaddr, direction: ConnectionDirection)

    /// 接続が切断された
    case disconnected(peer: PeerID, reason: DisconnectReason)

    /// 再接続を開始
    case reconnecting(peer: PeerID, attempt: Int, nextDelay: Duration)

    /// 再接続に成功
    case reconnected(peer: PeerID, attempt: Int)

    /// 再接続に失敗 (上限到達)
    case reconnectionFailed(peer: PeerID, attempts: Int)

    /// 接続がトリムされた (制限超過のため)
    case trimmed(peer: PeerID, reason: String)

    /// ヘルスチェック失敗
    case healthCheckFailed(peer: PeerID)

    /// 接続がゲートされた (拒否された)
    case gated(peer: PeerID?, address: Multiaddr, stage: GateStage)
}
```

---

## 5. 統合設計

### 5.1 NodeConfiguration の更新

```swift
public struct NodeConfiguration: Sendable {
    // 既存のプロパティ...
    public let keyPair: KeyPair
    public let listenAddresses: [Multiaddr]
    public let transports: [any Transport]
    public let security: [any SecurityUpgrader]
    public let muxers: [any Muxer]

    /// 接続プール設定
    public let pool: PoolConfiguration

    /// ヘルスチェック設定 (nil で無効)
    public let healthCheck: HealthMonitor.Configuration?

    /// プール設定
    public struct PoolConfiguration: Sendable {
        public var limits: ConnectionLimits
        public var reconnectionPolicy: ReconnectionPolicy
        public var idleTimeout: Duration
        public var gater: (any ConnectionGater)?

        public init(
            limits: ConnectionLimits = .default,
            reconnectionPolicy: ReconnectionPolicy = .default,
            idleTimeout: Duration = .seconds(60),
            gater: (any ConnectionGater)? = nil
        ) {
            self.limits = limits
            self.reconnectionPolicy = reconnectionPolicy
            self.idleTimeout = idleTimeout
            self.gater = gater
        }
    }

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        transports: [any Transport] = [],
        security: [any SecurityUpgrader] = [],
        muxers: [any Muxer] = [],
        pool: PoolConfiguration = .init(),
        healthCheck: HealthMonitor.Configuration? = .default
    ) {
        self.keyPair = keyPair
        self.listenAddresses = listenAddresses
        self.transports = transports
        self.security = security
        self.muxers = muxers
        self.pool = pool
        self.healthCheck = healthCheck
    }
}
```

### 5.2 Node の更新

```swift
/// P2P ネットワークノード
///
/// ## 責務
/// - 公開APIの提供 (connect, disconnect, newStream など)
/// - イベントの発行
/// - ユーザーからのリクエストを内部コンポーネントに委譲
///
/// ## 状態管理
/// Node自身は状態を持たない。全ての接続状態はConnectionPoolが管理する。
public actor Node {
    public let configuration: NodeConfiguration

    // 内部コンポーネント (全てinternal)
    private let pool: ConnectionPool
    private let upgrader: ConnectionUpgrader
    private let healthMonitor: HealthMonitor?

    // Protocol handlers
    private var handlers: [String: ProtocolHandler] = [:]

    // Listeners
    private var listeners: [any Listener] = []

    // Background tasks
    private var idleCheckTask: Task<Void, Never>?
    private var trimTask: Task<Void, Never>?

    // State
    private var isRunning = false

    // Events
    private var eventContinuation: AsyncStream<NodeEvent>.Continuation?
    private var _events: AsyncStream<NodeEvent>?

    // MARK: - Public API (状態は全てPoolに委譲)

    /// ピアに接続
    ///
    /// ## 同時dial時の挙動
    /// 同一ピアへのconnect()が同時に呼ばれた場合、
    /// 最初のdialに合流し、同じ結果を返す。
    @discardableResult
    public func connect(to address: Multiaddr) async throws -> PeerID {
        // 1. Gating check (dial)
        if let gater = configuration.pool.gater {
            if !gater.interceptDial(peer: address.peerID, address: address) {
                emit(.gated(peer: address.peerID, address: address, stage: .dial))
                throw NodeError.connectionGated(stage: .dial)
            }
        }

        // 2. Check for pending dial (合流)
        if let peerID = address.peerID, let pendingTask = pool.pendingDial(to: peerID) {
            return try await pendingTask.value
        }

        // 3. Start new dial
        let dialTask = Task { [weak self] () throws -> PeerID in
            guard let self = self else { throw NodeError.nodeNotRunning }
            return try await self.performDial(to: address)
        }

        // Register pending dial if peer ID is known
        if let peerID = address.peerID {
            pool.registerPendingDial(dialTask, for: peerID)
        }

        defer {
            if let peerID = address.peerID {
                pool.removePendingDial(for: peerID)
            }
        }

        return try await dialTask.value
    }

    /// ピアから切断
    public func disconnect(from peer: PeerID) async {
        // Poolから接続を取得して閉じる
        guard let managed = pool.remove(forPeer: peer) else { return }
        try? await managed.connection?.close()
        emit(.disconnected(peer: peer, reason: .localClose))
    }

    /// 新しいストリームを開く
    public func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        guard let connection = pool.connection(to: peer) else {
            throw NodeError.notConnected(peer)
        }
        // ... negotiate stream ...
    }

    /// 接続状態を取得
    public func connectionState(of peer: PeerID) -> ConnectionState? {
        pool.state(of: peer)
    }

    /// タグ付け
    public func tag(_ peer: PeerID, with tag: String) {
        pool.tag(peer, with: tag)
    }

    /// タグ削除
    public func untag(_ peer: PeerID, tag: String) {
        pool.untag(peer, tag: tag)
    }

    /// 保護 (トリム対象外)
    public func protect(_ peer: PeerID) {
        pool.protect(peer)
    }

    /// 保護解除
    public func unprotect(_ peer: PeerID) {
        pool.unprotect(peer)
    }

    /// 接続済みピア
    public var connectedPeers: [PeerID] {
        pool.connectedPeers
    }

    /// 接続数
    public var connectionCount: Int {
        pool.connectionCount
    }
}
```

---

## 6. 動作フロー

### 6.1 ダイアル時のゲーティングと同時dial処理

```
connect(address)
    │
    ▼
┌─────────────────────────┐
│ gater.interceptDial()   │──▶ false ──▶ emit(.gated) + throw
└─────────────────────────┘
    │ true
    ▼
┌─────────────────────────┐
│ pendingDial exists?     │──▶ yes ──▶ await existing task (合流)
└─────────────────────────┘
    │ no
    ▼
register pendingDial
    │
    ▼
transport.dial(address)
    │
    ▼
security upgrade
    │
    ▼
┌─────────────────────────┐
│ gater.interceptSecured()│──▶ false ──▶ close & throw
└─────────────────────────┘
    │ true
    ▼
muxer upgrade
    │
    ▼
pool.add(connection)
    │
    ▼
remove pendingDial
    │
    ▼
emit(.connected)
```

### 6.2 再接続フロー

```
connection closed (error/remote)
    │
    ▼
pool.updateState(.disconnected)
emit(.disconnected)
    │
    ▼
reconnectionPolicy.enabled?
    │
    ├── false ──▶ pool.updateState(.failed)
    │
    └── true
         │
         ▼
    retryCount < maxRetries?
         │
         ├── false ──▶ pool.updateState(.failed)
         │              emit(.reconnectionFailed)
         │
         └── true
              │
              ▼
         delay = backoff.delay(retryCount)
         pool.updateState(.reconnecting)
         emit(.reconnecting)
              │
              ▼
         Task.sleep(delay)
              │
              ▼
         dial(savedAddress)
              │
              ├── success ──▶ pool.updateState(.connected)
              │               emit(.reconnected)
              │               retryCount = 0
              │
              └── failure ──▶ retryCount += 1
                              (loop)
```

### 6.3 トリミングフロー

```
定期チェック または 新規接続追加時
    │
    ▼
connectionCount > highWatermark?
    │
    ├── false ──▶ (何もしない)
    │
    └── true
         │
         ▼
    対象接続を選択:
    1. gracePeriod内の接続は除外
    2. protectedな接続は除外
    3. 優先度が低い順にソート:
       - タグ数が少ない
       - 最終アクティビティが古い
       - アウトバウンドよりインバウンド優先
         │
         ▼
    (connectionCount - lowWatermark) 個の接続を閉じる
         │
         ▼
    emit(.trimmed) for each
```

---

## 7. ディレクトリ構造

```
Sources/Integration/P2P/
├── P2P.swift                    # Node (更新)
├── ConnectionUpgrader.swift     # (既存)
└── Connection/
    ├── CONTEXT.md
    ├── ConnectionPool.swift      # 接続プール (internal)
    ├── ConnectionState.swift     # 状態定義
    ├── ConnectionLimits.swift    # 制限設定
    ├── ConnectionGater.swift     # ゲーター
    ├── BackoffStrategy.swift     # バックオフ
    ├── ReconnectionPolicy.swift  # 再接続ポリシー
    ├── HealthMonitor.swift       # ヘルスチェック
    └── ConnectionEvent.swift     # イベント定義
```

---

## 8. 設計判断のまとめ

### 回答: Open Questions

**Q: pendingDials は「同一 peer の同時 dial を防ぐ」ため？ connect() の API は待機/合流/失敗のどれ？**

A: **合流 (await existing task)**
- 同一peerへの同時dialを検出した場合、新規dialは開始せず、既存のTaskをawaitする
- 結果は同じPeerIDを返す (成功時) または同じエラーをthrow (失敗時)
- これによりリソースの無駄を防ぎ、一貫した結果を保証する

### 設計判断サマリー

| 判断ポイント | 決定 | 理由 |
|-------------|------|------|
| ConnectionPool の可視性 | `internal` | Node actor 内でのみ使用、外部アクセス不要 |
| Node vs Pool 責務 | Node=API, Pool=状態 | 明確な責務分離、二重管理を防止 |
| Gating 段階 | 3段階 (dial/accept/secured) | muxer後は稀なケース、secured後で十分 |
| DisconnectReason 比較 | errorCode で比較 | String比較の不安定性を回避 |
| HealthMonitor 注入 | PingProvider protocol | 疎結合、テスト容易 |
| 同時dial | 既存Taskに合流 | リソース効率、一貫性 |
| Duration 精度 | 軽微な損失許容 | 再接続用途では問題なし |

---

## 9. 参考リンク

- [libp2p specs - connections](https://github.com/libp2p/specs/blob/master/connections/README.md)
- [go-libp2p ConnManager](https://pkg.go.dev/github.com/libp2p/go-libp2p-core/connmgr)
- [rust-libp2p ConnectionPool](https://docs.rs/libp2p-swarm/latest/libp2p_swarm/struct.Pool.html)
