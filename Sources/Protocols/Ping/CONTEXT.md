# P2PPing

## 概要
libp2p Pingプロトコルの実装。

## 責務
- 接続のヘルスチェック
- RTT（Round-Trip Time）測定
- NAT keepalive

## Protocol ID
- `/ipfs/ping/1.0.0`

## 依存関係
- `P2PCore` (PeerID)
- `P2PMux` (MuxedStream)
- `P2PProtocols` (ProtocolService)

---

## ファイル構成

```
Sources/Protocols/Ping/
├── PingService.swift    # メインサービス実装
├── PingResult.swift     # 結果・イベント・エラー型
└── CONTEXT.md
```

## 主要な型

| 型名 | 説明 |
|-----|------|
| `PingService` | プロトコルサービス実装 |
| `PingResult` | Ping結果（RTT含む） |
| `PingConfiguration` | サービス設定 |
| `PingEvent` | イベント通知 |
| `PingError` | エラー型 |

---

## Wire Protocol

### Message Format

```
┌────────────────────────────────────────┐
│ 32 bytes of random data                │
└────────────────────────────────────────┘
```

### Message Flow

```
Initiator              Responder
    |---- 32 bytes ------->|
    |<---- 32 bytes -------|
    (echo: same 32 bytes)
```

RTT = time(receive response) - time(send request)

---

## API

### Handler登録

```swift
let pingService = PingService(configuration: .init(
    timeout: .seconds(30)
))

await pingService.registerHandler(node: node)
```

### 単一Ping

```swift
let result = try await pingService.ping(remotePeer, using: node)
print("RTT: \(result.rtt)")  // e.g., "2.5ms"
```

### 複数Ping + 統計

```swift
let results = await pingService.pingMultiple(
    remotePeer,
    using: node,
    count: 5,
    interval: .milliseconds(100)
)

if let stats = PingService.statistics(from: results) {
    print("Min: \(stats.min)")
    print("Max: \(stats.max)")
    print("Avg: \(stats.avg)")
}
```

---

## 仕様準拠

- ペイロードサイズ: 32バイト（仕様準拠）
- レスポンス: 受信したペイロードをそのままエコーバック
- タイムアウト: 設定可能（デフォルト30秒）

---

## 実装詳細

### PingStreamReader
`MuxedStream.read()`は32バイト以上を返す場合がある。
`PingStreamReader`は内部バッファリングで正確に32バイトを抽出:

```swift
class PingStreamReader {
    private let buffer: Mutex<Data>

    func readExact(_ count: Int) async throws -> Data
    // 必要に応じてストリームから追加読み取り
    // バッファから正確にcountバイトを返す
}
```

### 統計計算
`PingService.statistics(from:)`はナノ秒精度で計算:
- min: 最小RTT
- max: 最大RTT
- avg: 平均RTT

## テスト

```
Tests/Protocols/PingTests/
├── PingServiceTests.swift    # サービステスト
└── PingInteropTests.swift    # Go/Rust相互運用
```

### 実装状況
| ファイル | ステータス | 説明 |
|---------|----------|------|
| PingServiceTests | ✅ 実装済み | 単一/複数Ping、統計テスト |
| PingInteropTests | ⏳ 計画中 | Go/Rust相互運用（未実装）|

## 品質向上TODO

### 高優先度
- [ ] **PingServiceテストの追加** - 単一Ping、複数Ping、統計計算テスト
- [ ] **Go/Rust相互運用テスト** - 実際のノードとの32バイトエコー検証

### 中優先度
- [ ] **タイムアウト動作テスト** - 30秒デフォルトタイムアウトの検証
- [ ] **不正ペイロード処理テスト** - 32バイト以外のレスポンス処理
- [ ] **並行Pingテスト** - 同一ピアへの複数同時Ping

### 低優先度
- [ ] **Ping統計の永続化** - 履歴RTTの保存と傾向分析
- [ ] **適応タイムアウト** - 過去のRTTに基づくタイムアウト調整
