# Phase 1 設計: 基盤強化

> **目的**: テスト基盤の整備と接続の安定性向上
> **期間**: 1-2週間
> **成果物**: Memory Transport, Connection Resilience, Interop Test Infrastructure

---

## 概要

Phase 1は3つのコンポーネントで構成される:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Phase 1                                  │
├─────────────────┬─────────────────────┬─────────────────────────┤
│ Memory Transport│ Connection          │ Interop Test            │
│                 │ Resilience          │ Infrastructure          │
├─────────────────┼─────────────────────┼─────────────────────────┤
│ • MemoryTransport│ • ReconnectionPolicy│ • go-libp2p test       │
│ • MemoryListener│ • ConnectionManager │ • rust-libp2p test     │
│ • MemoryConnection│ • HealthChecker   │ • Wire protocol verify │
│ • MemoryHub     │ • BackoffStrategy   │ • Test vectors         │
└─────────────────┴─────────────────────┴─────────────────────────┘
```

---

## 1. Memory Transport

### 1.1 目的

- **テスト効率化**: ネットワーク不要で高速なユニット/統合テスト
- **決定論的動作**: タイミング依存のテストを安定化
- **障害シミュレーション**: 切断、遅延、エラー注入が可能

### 1.2 アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                         MemoryHub                               │
│  (グローバル接続ルーター - シングルトン or インスタンス)           │
├─────────────────────────────────────────────────────────────────┤
│  listeners: [Multiaddr: MemoryListener]                        │
│  pendingConnections: [Multiaddr: AsyncStream<MemoryConnection>] │
└─────────────────────────────────────────────────────────────────┘
        │                                           │
        ▼                                           ▼
┌─────────────────┐                       ┌─────────────────┐
│ MemoryTransport │                       │ MemoryTransport │
│   (Node A)      │                       │   (Node B)      │
├─────────────────┤                       ├─────────────────┤
│ hub: MemoryHub  │───dial(/memory/B)────▶│ hub: MemoryHub  │
└─────────────────┘                       └─────────────────┘
        │                                           │
        ▼                                           ▼
┌─────────────────┐    AsyncChannel     ┌─────────────────┐
│ MemoryConnection│◄───────────────────▶│ MemoryConnection│
│   (Local End)   │    bidirectional    │   (Remote End)  │
└─────────────────┘                     └─────────────────┘
```

### 1.3 Multiaddr形式

```
/memory/<identifier>

例:
/memory/node-a
/memory/peer-12D3KooW...
/memory/test-server-1
```

### 1.4 API設計

```swift
// Sources/Transport/Memory/MemoryHub.swift

/// メモリトランスポートの接続ルーター
public final class MemoryHub: Sendable {

    /// 共有インスタンス（テスト用）
    public static let shared = MemoryHub()

    /// 新しいハブを作成（隔離テスト用）
    public init()

    /// リスナーを登録
    func register(listener: MemoryListener, at address: Multiaddr)

    /// リスナーを解除
    func unregister(address: Multiaddr)

    /// アドレスに接続（内部で対向リスナーを検索）
    func connect(to address: Multiaddr) async throws -> (local: MemoryConnection, remote: MemoryConnection)

    /// 全接続をリセット（テスト間のクリーンアップ）
    func reset()
}
```

```swift
// Sources/Transport/Memory/MemoryTransport.swift

/// インメモリトランスポート
public final class MemoryTransport: Transport, Sendable {

    /// このトランスポートが使用するハブ
    public let hub: MemoryHub

    /// サポートするプロトコル
    public var protocols: [[String]] {
        [["memory"]]
    }

    /// 共有ハブを使用するトランスポートを作成
    public init() {
        self.hub = .shared
    }

    /// カスタムハブを使用するトランスポートを作成
    public init(hub: MemoryHub) {
        self.hub = hub
    }

    /// アドレスへダイアル
    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        let (local, _) = try await hub.connect(to: address)
        return local
    }

    /// アドレスでリッスン
    public func listen(_ address: Multiaddr) async throws -> any Listener {
        let listener = MemoryListener(address: address, hub: hub)
        hub.register(listener: listener, at: address)
        return listener
    }

    /// ダイアル可能か確認
    public func canDial(_ address: Multiaddr) -> Bool {
        address.protocols.first == .memory
    }

    /// リッスン可能か確認
    public func canListen(_ address: Multiaddr) -> Bool {
        address.protocols.first == .memory
    }
}
```

```swift
// Sources/Transport/Memory/MemoryListener.swift

/// インメモリリスナー
public final class MemoryListener: Listener, Sendable {

    public let localAddress: Multiaddr

    private let hub: MemoryHub
    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var pendingConnections: [MemoryConnection] = []
        var waitingContinuation: CheckedContinuation<any RawConnection, Error>?
        var isClosed = false
    }

    init(address: Multiaddr, hub: MemoryHub)

    /// 次の接続を受け入れ
    public func accept() async throws -> any RawConnection

    /// リスナーを閉じる
    public func close() async throws

    /// 新しい接続を追加（MemoryHubから呼ばれる）
    internal func enqueue(_ connection: MemoryConnection)
}
```

```swift
// Sources/Transport/Memory/MemoryConnection.swift

/// インメモリ接続
public final class MemoryConnection: RawConnection, Sendable {

    public let localAddress: Multiaddr?
    public let remoteAddress: Multiaddr

    private let channel: MemoryChannel
    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var isClosed = false
    }

    init(localAddress: Multiaddr?, remoteAddress: Multiaddr, channel: MemoryChannel)

    /// データを読み取り
    public func read() async throws -> Data

    /// データを書き込み
    public func write(_ data: Data) async throws

    /// 接続を閉じる
    public func close() async throws
}
```

```swift
// Sources/Transport/Memory/MemoryChannel.swift

/// 双方向インメモリチャネル
///
/// 2つのMemoryConnection間でデータを転送する
internal final class MemoryChannel: Sendable {

    private let aToB: AsyncStream<Data>
    private let bToA: AsyncStream<Data>
    private let aToBContinuation: AsyncStream<Data>.Continuation
    private let bToAContinuation: AsyncStream<Data>.Continuation

    /// ペアの接続を作成
    static func makePair(
        localAddress: Multiaddr,
        remoteAddress: Multiaddr
    ) -> (local: MemoryConnection, remote: MemoryConnection)

    /// A側からデータを送信
    func sendFromA(_ data: Data)

    /// B側からデータを送信
    func sendFromB(_ data: Data)

    /// A側でデータを受信
    func receiveAtA() async throws -> Data

    /// B側でデータを受信
    func receiveAtB() async throws -> Data

    /// チャネルを閉じる
    func close()
}
```

### 1.5 障害シミュレーション（オプション）

```swift
/// 障害シミュレーション設定
public struct MemoryFaultConfig: Sendable {
    /// 読み取り遅延
    public var readDelay: Duration?

    /// 書き込み遅延
    public var writeDelay: Duration?

    /// 書き込み後に切断する確率 (0.0-1.0)
    public var disconnectProbability: Double = 0

    /// 次のN回の読み取り後に切断
    public var disconnectAfterReads: Int?

    /// 読み取りエラーを注入
    public var injectReadError: Error?
}
```

### 1.6 Multiaddr拡張

```swift
// Sources/Core/P2PCore/Addressing/MultiaddrProtocol.swift

public enum MultiaddrProtocol: Sendable, Hashable {
    case ip4(String)
    case ip6(String)
    case tcp(UInt16)
    case udp(UInt16)
    case quic
    case p2p(String)
    case memory(String)  // 追加

    // ...
}

// Multiaddr.swift に追加
extension Multiaddr {
    /// メモリアドレスを作成
    public static func memory(id: String) -> Multiaddr {
        Multiaddr(protocols: [.memory(id)])
    }

    /// メモリIDを取得
    public var memoryID: String? {
        for proto in protocols {
            if case .memory(let id) = proto {
                return id
            }
        }
        return nil
    }
}
```

---

## 2. Connection Resilience

### 2.1 目的

- **自動再接続**: 切断時に自動的に再接続を試行
- **バックオフ**: 失敗時に指数バックオフで再試行
- **ヘルスチェック**: 定期的な接続状態の確認
- **グレースフル切断**: 適切な切断処理

### 2.2 アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                           Node                                  │
├─────────────────────────────────────────────────────────────────┤
│  connectionManager: ConnectionManager                           │
│  healthChecker: HealthChecker (optional)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ConnectionManager                           │
├─────────────────────────────────────────────────────────────────┤
│  connections: [PeerID: ManagedConnection]                      │
│  reconnectionPolicy: ReconnectionPolicy                        │
│  backoffStrategy: BackoffStrategy                              │
├─────────────────────────────────────────────────────────────────┤
│  + connect(to: Multiaddr) async throws -> PeerID               │
│  + disconnect(from: PeerID) async                              │
│  + reconnect(peer: PeerID) async throws                        │
│  + enableAutoReconnect(peer: PeerID, address: Multiaddr)       │
│  + disableAutoReconnect(peer: PeerID)                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ManagedConnection                           │
├─────────────────────────────────────────────────────────────────┤
│  peer: PeerID                                                   │
│  connection: MuxedConnection                                    │
│  address: Multiaddr                                             │
│  state: ConnectionState                                         │
│  retryCount: Int                                                │
│  lastConnectedAt: ContinuousClock.Instant?                     │
│  autoReconnect: Bool                                            │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 接続状態マシン

```
                    ┌──────────────┐
                    │  Connecting  │
                    └──────┬───────┘
                           │ success
                           ▼
    ┌─────────┐     ┌──────────────┐
    │  Idle   │◀────│  Connected   │
    └────┬────┘     └──────┬───────┘
         │                 │ error/close
         │ connect         ▼
         │          ┌──────────────┐
         └─────────▶│ Disconnected │
                    └──────┬───────┘
                           │ autoReconnect
                           ▼
                    ┌──────────────┐
                    │ Reconnecting │──────┐
                    └──────┬───────┘      │ max retries
                           │ success      ▼
                           │       ┌──────────────┐
                           └──────▶│    Failed    │
                                   └──────────────┘
```

```swift
/// 接続状態
public enum ConnectionState: Sendable {
    /// 接続中
    case connecting

    /// 接続済み
    case connected

    /// 切断済み（再接続可能）
    case disconnected(reason: DisconnectReason)

    /// 再接続中
    case reconnecting(attempt: Int)

    /// 失敗（再接続上限到達）
    case failed(reason: DisconnectReason)
}

/// 切断理由
public enum DisconnectReason: Sendable {
    /// 正常切断（ローカル）
    case localClose

    /// 正常切断（リモート）
    case remoteClose

    /// エラー
    case error(Error)

    /// タイムアウト
    case timeout

    /// ヘルスチェック失敗
    case healthCheckFailed
}
```

### 2.4 API設計

```swift
// Sources/Integration/P2P/Connection/ReconnectionPolicy.swift

/// 再接続ポリシー
public struct ReconnectionPolicy: Sendable {

    /// 自動再接続を有効にするか
    public var autoReconnect: Bool

    /// 最大再試行回数
    public var maxRetries: Int

    /// 初期バックオフ遅延
    public var initialDelay: Duration

    /// 最大バックオフ遅延
    public var maxDelay: Duration

    /// バックオフ乗数
    public var multiplier: Double

    /// ジッター (0.0-1.0)
    public var jitter: Double

    /// デフォルトポリシー
    public static let `default` = ReconnectionPolicy(
        autoReconnect: true,
        maxRetries: 10,
        initialDelay: .milliseconds(100),
        maxDelay: .minutes(5),
        multiplier: 2.0,
        jitter: 0.1
    )

    /// 再接続なし
    public static let none = ReconnectionPolicy(
        autoReconnect: false,
        maxRetries: 0,
        initialDelay: .zero,
        maxDelay: .zero,
        multiplier: 1.0,
        jitter: 0.0
    )

    /// 積極的な再接続（短い遅延）
    public static let aggressive = ReconnectionPolicy(
        autoReconnect: true,
        maxRetries: 20,
        initialDelay: .milliseconds(50),
        maxDelay: .seconds(30),
        multiplier: 1.5,
        jitter: 0.2
    )

    public init(
        autoReconnect: Bool = true,
        maxRetries: Int = 10,
        initialDelay: Duration = .milliseconds(100),
        maxDelay: Duration = .minutes(5),
        multiplier: Double = 2.0,
        jitter: Double = 0.1
    )
}
```

```swift
// Sources/Integration/P2P/Connection/BackoffStrategy.swift

/// バックオフ戦略
public struct BackoffStrategy: Sendable {

    private let policy: ReconnectionPolicy

    public init(policy: ReconnectionPolicy)

    /// 次の遅延を計算
    ///
    /// - Parameter attempt: 試行回数 (0-indexed)
    /// - Returns: 待機すべき時間、nilの場合は再試行不可
    public func delay(for attempt: Int) -> Duration? {
        guard attempt < policy.maxRetries else {
            return nil
        }

        // 指数バックオフ: initialDelay * (multiplier ^ attempt)
        let baseDelay = policy.initialDelay.components.seconds
            + Double(policy.initialDelay.components.attoseconds) / 1e18
        let exponential = baseDelay * pow(policy.multiplier, Double(attempt))

        // 最大遅延でクランプ
        let maxDelaySeconds = policy.maxDelay.components.seconds
            + Double(policy.maxDelay.components.attoseconds) / 1e18
        let clamped = min(exponential, maxDelaySeconds)

        // ジッター追加
        let jitterRange = clamped * policy.jitter
        let jittered = clamped + Double.random(in: -jitterRange...jitterRange)

        return .nanoseconds(Int64(jittered * 1e9))
    }

    /// リセットすべきか（成功後）
    public func shouldReset(after successDuration: Duration) -> Bool {
        // 30秒以上接続が維持されたらリセット
        successDuration >= .seconds(30)
    }
}
```

```swift
// Sources/Integration/P2P/Connection/ConnectionManager.swift

/// 接続管理イベント
public enum ConnectionManagerEvent: Sendable {
    /// 接続が確立された
    case connected(peer: PeerID, address: Multiaddr)

    /// 接続が切断された
    case disconnected(peer: PeerID, reason: DisconnectReason)

    /// 再接続を開始
    case reconnecting(peer: PeerID, attempt: Int)

    /// 再接続に成功
    case reconnected(peer: PeerID, attempt: Int)

    /// 再接続に失敗（上限到達）
    case reconnectionFailed(peer: PeerID, lastError: Error?)
}

/// 接続マネージャー
///
/// 接続のライフサイクル、再接続、状態管理を担当
public actor ConnectionManager {

    /// 再接続ポリシー
    public let policy: ReconnectionPolicy

    /// イベントストリーム
    public var events: AsyncStream<ConnectionManagerEvent> { get }

    /// 管理中の接続
    private var connections: [PeerID: ManagedConnection] = [:]

    /// バックオフ戦略
    private let backoff: BackoffStrategy

    /// アップグレーダー
    private let upgrader: ConnectionUpgrader

    /// トランスポート
    private let transports: [any Transport]

    /// ローカルキーペア
    private let localKeyPair: KeyPair

    public init(
        policy: ReconnectionPolicy = .default,
        transports: [any Transport],
        upgrader: ConnectionUpgrader,
        localKeyPair: KeyPair
    )

    // MARK: - Public API

    /// ピアに接続
    ///
    /// - Parameters:
    ///   - address: 接続先アドレス
    ///   - autoReconnect: 自動再接続を有効にするか（nilの場合はポリシーに従う）
    /// - Returns: リモートピアID
    public func connect(
        to address: Multiaddr,
        autoReconnect: Bool? = nil
    ) async throws -> PeerID

    /// ピアから切断
    ///
    /// - Parameters:
    ///   - peer: 切断するピア
    ///   - permanently: trueの場合は自動再接続を無効化
    public func disconnect(from peer: PeerID, permanently: Bool = false) async

    /// ピアへの接続を取得
    public func connection(to peer: PeerID) -> MuxedConnection?

    /// 接続状態を取得
    public func state(of peer: PeerID) -> ConnectionState?

    /// 全接続済みピア
    public var connectedPeers: [PeerID] { get }

    /// 接続数
    public var connectionCount: Int { get }

    /// 自動再接続を有効化
    public func enableAutoReconnect(
        for peer: PeerID,
        address: Multiaddr
    )

    /// 自動再接続を無効化
    public func disableAutoReconnect(for peer: PeerID)

    /// 全接続を閉じる
    public func closeAll() async

    // MARK: - Internal

    /// インバウンド接続を追加
    internal func addInbound(_ connection: MuxedConnection) async

    /// 接続切断を処理
    internal func handleDisconnection(
        peer: PeerID,
        reason: DisconnectReason
    ) async
}
```

```swift
// Sources/Integration/P2P/Connection/ManagedConnection.swift

/// 管理対象の接続
internal struct ManagedConnection: Sendable {
    /// ピアID
    let peer: PeerID

    /// 接続先アドレス
    let address: Multiaddr

    /// 実際の接続（nilの場合は切断中）
    var connection: MuxedConnection?

    /// 接続状態
    var state: ConnectionState

    /// 再試行回数
    var retryCount: Int

    /// 最後に接続した時刻
    var lastConnectedAt: ContinuousClock.Instant?

    /// 自動再接続フラグ
    var autoReconnect: Bool

    /// 再接続タスク
    var reconnectTask: Task<Void, Never>?
}
```

### 2.5 ヘルスチェック

```swift
// Sources/Integration/P2P/Connection/HealthChecker.swift

/// ヘルスチェック設定
public struct HealthCheckConfig: Sendable {
    /// チェック間隔
    public var interval: Duration

    /// タイムアウト
    public var timeout: Duration

    /// 失敗許容回数
    public var maxFailures: Int

    public static let `default` = HealthCheckConfig(
        interval: .seconds(30),
        timeout: .seconds(10),
        maxFailures: 3
    )
}

/// ヘルスチェッカー
///
/// PingServiceを使用して接続の生存確認を行う
public actor HealthChecker {

    /// 設定
    public let config: HealthCheckConfig

    /// Pingサービス
    private let pingService: PingService

    /// 接続マネージャー（コールバック用）
    private weak var connectionManager: ConnectionManager?

    /// チェックタスク
    private var checkTasks: [PeerID: Task<Void, Never>] = [:]

    public init(
        config: HealthCheckConfig = .default,
        pingService: PingService
    )

    /// ヘルスチェックを開始
    public func startMonitoring(
        peer: PeerID,
        using opener: any StreamOpener
    )

    /// ヘルスチェックを停止
    public func stopMonitoring(peer: PeerID)

    /// 全モニタリングを停止
    public func stopAll()

    /// 接続マネージャーを設定
    public func setConnectionManager(_ manager: ConnectionManager)
}
```

### 2.6 Node統合

```swift
// NodeConfigurationへの追加
public struct NodeConfiguration: Sendable {
    // ... 既存のプロパティ ...

    /// 再接続ポリシー
    public let reconnectionPolicy: ReconnectionPolicy

    /// ヘルスチェック設定（nilで無効）
    public let healthCheck: HealthCheckConfig?

    public init(
        // ... 既存のパラメータ ...
        reconnectionPolicy: ReconnectionPolicy = .default,
        healthCheck: HealthCheckConfig? = .default
    )
}

// NodeEventへの追加
public enum NodeEvent: Sendable {
    // ... 既存のケース ...

    /// 再接続中
    case reconnecting(peer: PeerID, attempt: Int)

    /// 再接続成功
    case reconnected(peer: PeerID)

    /// 再接続失敗
    case reconnectionFailed(peer: PeerID)
}
```

---

## 3. Go/Rust Interop Test Infrastructure

### 3.1 目的

- **互換性検証**: Go/Rust libp2pとの実際の接続テスト
- **ワイヤプロトコル確認**: エンコーディングの互換性検証
- **回帰テスト**: 継続的な互換性の維持

### 3.2 テスト構成

```
Tests/
└── Interop/
    ├── InteropTestSupport/       # 共通ユーティリティ
    │   ├── GoLibp2pNode.swift    # go-libp2p プロセス管理
    │   ├── RustLibp2pNode.swift  # rust-libp2p プロセス管理
    │   ├── TestVector.swift      # テストベクター定義
    │   └── InteropAssertions.swift
    │
    ├── GoInteropTests/           # go-libp2p テスト
    │   ├── GoTCPNoiseYamuxTests.swift
    │   ├── GoIdentifyTests.swift
    │   └── GoPingTests.swift
    │
    └── RustInteropTests/         # rust-libp2p テスト
        ├── RustTCPNoiseYamuxTests.swift
        ├── RustIdentifyTests.swift
        └── RustPingTests.swift
```

### 3.3 テストプロセス管理

```swift
// Tests/Interop/InteropTestSupport/ExternalNode.swift

/// 外部libp2pノードのプロトコル
public protocol ExternalNode: Sendable {
    /// ノードを起動
    func start() async throws

    /// ノードを停止
    func stop() async

    /// ノードのPeerID
    var peerID: String { get async throws }

    /// リッスンアドレス
    var listenAddresses: [String] { get async throws }
}

/// Go libp2pノード
public final class GoLibp2pNode: ExternalNode, Sendable {

    /// Goバイナリへのパス
    public let binaryPath: String

    /// リッスンアドレス
    public let listenAddress: String

    /// プロセス
    private var process: Process?

    public init(
        binaryPath: String = "/usr/local/bin/go-libp2p-echo",
        listenAddress: String = "/ip4/127.0.0.1/tcp/0"
    )

    public func start() async throws {
        // プロセスを起動し、PeerIDとアドレスをパース
    }

    public func stop() async {
        process?.terminate()
    }
}
```

### 3.4 テストベクター

```swift
// Tests/Interop/InteropTestSupport/TestVector.swift

/// ワイヤプロトコルテストベクター
public struct WireTestVector: Sendable {
    /// テスト名
    public let name: String

    /// 入力データ
    public let input: Data

    /// 期待される出力
    public let expected: Data

    /// 説明
    public let description: String
}

/// 組み込みテストベクター
public enum TestVectors {

    /// multistream-select
    public static let multistreamSelect: [WireTestVector] = [
        WireTestVector(
            name: "protocol_header",
            input: Data(),
            expected: Data([0x13]) + "/multistream/1.0.0\n".data(using: .utf8)!,
            description: "multistream-select header message"
        ),
        // ...
    ]

    /// Identify protobuf
    public static let identifyProtobuf: [WireTestVector] = [
        // ...
    ]

    /// Ping
    public static let ping: [WireTestVector] = [
        WireTestVector(
            name: "ping_payload",
            input: Data(repeating: 0xAB, count: 32),
            expected: Data(repeating: 0xAB, count: 32),
            description: "32-byte ping echo"
        )
    ]
}
```

### 3.5 テスト例

```swift
// Tests/Interop/GoInteropTests/GoTCPNoiseYamuxTests.swift

@Suite("Go libp2p Interop Tests")
struct GoInteropTests {

    @Test("Connect to go-libp2p node via TCP+Noise+Yamux")
    func testBasicConnection() async throws {
        // 1. Goノードを起動
        let goNode = GoLibp2pNode()
        try await goNode.start()
        defer { Task { await goNode.stop() } }

        // 2. Swiftノードを作成
        let keyPair = KeyPair.generateEd25519()
        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            transports: [TCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        ))

        try await node.start()
        defer { Task { await node.stop() } }

        // 3. 接続
        let goAddress = try await goNode.listenAddresses.first!
        let remotePeer = try await node.connect(to: Multiaddr(goAddress))

        // 4. 検証
        #expect(remotePeer.description == (try await goNode.peerID))
    }

    @Test("Identify with go-libp2p node")
    func testIdentify() async throws {
        // ...
    }

    @Test("Ping go-libp2p node")
    func testPing() async throws {
        // ...
    }
}
```

### 3.6 CI/CD統合

```yaml
# .github/workflows/interop-tests.yml (参考)

name: Interoperability Tests

on:
  push:
    branches: [main]
  pull_request:

jobs:
  go-interop:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Build go-libp2p echo server
        run: |
          go install github.com/libp2p/go-libp2p/examples/echo@latest

      - name: Run interop tests
        run: |
          swift test --filter GoInteropTests

  rust-interop:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Build rust-libp2p echo server
        run: |
          cargo install libp2p-echo

      - name: Run interop tests
        run: |
          swift test --filter RustInteropTests
```

---

## 4. ディレクトリ構造

```
Sources/
├── Core/P2PCore/
│   └── Addressing/
│       └── MultiaddrProtocol.swift  # memory プロトコル追加
│
├── Transport/
│   └── Memory/
│       ├── MemoryTransport.swift
│       ├── MemoryListener.swift
│       ├── MemoryConnection.swift
│       ├── MemoryChannel.swift
│       ├── MemoryHub.swift
│       └── CONTEXT.md
│
└── Integration/P2P/
    ├── P2P.swift                    # 更新
    └── Connection/
        ├── ConnectionManager.swift
        ├── ManagedConnection.swift
        ├── ReconnectionPolicy.swift
        ├── BackoffStrategy.swift
        ├── HealthChecker.swift
        └── CONTEXT.md

Tests/
├── Transport/
│   └── MemoryTransportTests/
│       └── MemoryTransportTests.swift
│
├── Integration/
│   └── ConnectionResilienceTests/
│       ├── ReconnectionTests.swift
│       ├── BackoffTests.swift
│       └── HealthCheckTests.swift
│
└── Interop/
    ├── InteropTestSupport/
    ├── GoInteropTests/
    └── RustInteropTests/
```

---

## 5. 実装順序

### Week 1

| Day | タスク | 成果物 |
|-----|--------|--------|
| 1 | Multiaddr memory プロトコル追加 | MultiaddrProtocol.swift |
| 2 | MemoryChannel, MemoryConnection | MemoryChannel.swift, MemoryConnection.swift |
| 3 | MemoryHub, MemoryListener | MemoryHub.swift, MemoryListener.swift |
| 4 | MemoryTransport, テスト | MemoryTransport.swift, MemoryTransportTests.swift |
| 5 | ReconnectionPolicy, BackoffStrategy | ReconnectionPolicy.swift, BackoffStrategy.swift |

### Week 2

| Day | タスク | 成果物 |
|-----|--------|--------|
| 1 | ConnectionManager基本実装 | ConnectionManager.swift |
| 2 | 再接続ロジック、状態管理 | ConnectionManager.swift続き |
| 3 | HealthChecker | HealthChecker.swift |
| 4 | Node統合、テスト | P2P.swift更新、ConnectionResilienceTests |
| 5 | Interopテスト基盤 | InteropTestSupport/, GoInteropTests/ |

---

## 6. テスト戦略

### Memory Transport テスト

```swift
@Suite("Memory Transport Tests")
struct MemoryTransportTests {

    @Test("Basic dial and listen")
    func testBasicConnection() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(Multiaddr.memory(id: "server"))

        async let accept = listener.accept()
        let conn = try await transport.dial(Multiaddr.memory(id: "server"))
        let serverConn = try await accept

        // Write from client, read from server
        try await conn.write(Data("hello".utf8))
        let received = try await serverConn.read()

        #expect(String(decoding: received, as: UTF8.self) == "hello")
    }

    @Test("Bidirectional communication")
    func testBidirectional() async throws { ... }

    @Test("Multiple connections to same address")
    func testMultipleConnections() async throws { ... }

    @Test("Connection close propagates")
    func testCloseProgagation() async throws { ... }
}
```

### Connection Resilience テスト

```swift
@Suite("Connection Resilience Tests")
struct ConnectionResilienceTests {

    @Test("Auto reconnect after disconnect")
    func testAutoReconnect() async throws {
        let hub = MemoryHub()

        // Server node
        let serverNode = Node(configuration: NodeConfiguration(
            transports: [MemoryTransport(hub: hub)],
            listenAddresses: [.memory(id: "server")]
        ))
        try await serverNode.start()

        // Client node with auto-reconnect
        let clientNode = Node(configuration: NodeConfiguration(
            transports: [MemoryTransport(hub: hub)],
            reconnectionPolicy: .default
        ))
        try await clientNode.start()

        // Connect
        let peer = try await clientNode.connect(to: .memory(id: "server"))

        // Simulate disconnect
        await serverNode.disconnect(from: clientNode.peerID)

        // Wait for reconnection
        try await Task.sleep(for: .seconds(1))

        // Verify reconnected
        #expect(await clientNode.connection(to: peer) != nil)
    }

    @Test("Exponential backoff delays")
    func testBackoffDelays() async throws { ... }

    @Test("Max retries stops reconnection")
    func testMaxRetries() async throws { ... }

    @Test("Health check detects dead connection")
    func testHealthCheck() async throws { ... }
}
```

---

## 7. エラーハンドリング

```swift
/// 接続管理エラー
public enum ConnectionManagerError: Error, Sendable {
    /// 接続中にエラー
    case connectionFailed(underlying: Error)

    /// 再接続上限に到達
    case maxRetriesExceeded(peer: PeerID, attempts: Int)

    /// 既に接続済み
    case alreadyConnected(peer: PeerID)

    /// 接続が見つからない
    case notConnected(peer: PeerID)

    /// 無効なアドレス
    case invalidAddress(Multiaddr)
}
```

---

## 8. 設計上の考慮点

### 8.1 スレッドセーフティ

- `MemoryHub`: Mutex<T>で状態を保護
- `ConnectionManager`: actor で直列化
- `HealthChecker`: actor で直列化

### 8.2 リソース管理

- 接続は自動的にクリーンアップ
- タスクはキャンセル可能
- メモリリークを防ぐため weak 参照を適切に使用

### 8.3 テスト容易性

- MemoryTransportは決定論的
- 障害注入が可能
- タイミングに依存しないテストが書ける

### 8.4 拡張性

- ReconnectionPolicyはカスタマイズ可能
- HealthCheckerは任意で有効化
- 将来のトランスポート追加が容易

---

## 9. 成功基準

### Memory Transport

- [ ] MemoryTransport が Transport プロトコルを実装
- [ ] 双方向通信が動作
- [ ] 複数接続のサポート
- [ ] 正しいクローズ処理
- [ ] 全ユニットテストがパス

### Connection Resilience

- [ ] 切断後の自動再接続
- [ ] 指数バックオフの動作
- [ ] 最大再試行後の停止
- [ ] ヘルスチェックによる死活監視
- [ ] イベントストリームでの通知

### Interop Tests

- [ ] go-libp2p との TCP+Noise+Yamux 接続
- [ ] Identify プロトコルの交換
- [ ] Ping の往復
- [ ] (オプション) rust-libp2p との同様のテスト
