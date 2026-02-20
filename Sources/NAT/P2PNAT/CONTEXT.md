# P2PNAT 実装

## 概要

NAT 穴あけのためのポートマッピングサービス。
UPnP IGD と NAT-PMP の両方をサポートし、AutoNAT と統合。

## アーキテクチャ

```
NATPortMapper (facade, EventEmitting)
├── NATProtocolHandler (protocol)
│   ├── UPnPHandler (UPnP IGD)
│   │   ├── SSDP 発見 (UDPSocket)
│   │   ├── デバイス記述取得 (HTTP)
│   │   └── SOAP リクエスト
│   └── NATPMPHandler (NAT-PMP)
│       └── UDP リクエスト (UDPSocket)
├── UDPSocket (~Copyable, RAII)
├── NetworkUtils (gateway, local IP, XML)
└── 公開型
    ├── NATTransportProtocol
    ├── NATGatewayType
    ├── PortMapping
    ├── NATPortMapperEvent
    ├── NATPortMapperError
    └── NATPortMapperConfiguration
```

## ファイル構成

| ファイル | 責務 |
|---------|------|
| `NATPortMapper.swift` | Facade (~270行): ライフサイクル、キャッシュ、イベント、performMapping |
| `NATProtocolHandler.swift` | プロトコルハンドラのインターフェース |
| `UPnPHandler.swift` | UPnP IGD 実装 |
| `NATPMPHandler.swift` | NAT-PMP (RFC 6886) 実装 |
| `UDPSocket.swift` | RAII UDPソケット + fd_setヘルパー |
| `NetworkUtils.swift` | gateway取得, ローカルIP, XML抽出 |
| `NATTransportProtocol.swift` | TCP/UDP enum |
| `NATGatewayType.swift` | ゲートウェイ種別 |
| `PortMapping.swift` | マッピング結果 |
| `NATPortMapperEvent.swift` | イベント定義 |
| `NATPortMapperError.swift` | エラー定義 |
| `NATPortMapperConfiguration.swift` | 設定 |

## プロトコル詳細

### UPnP IGD (Internet Gateway Device)
1. SSDP 発見: UDP マルチキャスト 239.255.255.250:1900
2. デバイス記述取得: HTTP GET
3. ポートマッピング: SOAP AddPortMapping

### NAT-PMP (RFC 6886)
1. ゲートウェイ発見: デフォルトゲートウェイ IP
2. 外部アドレス取得: Opcode 0
3. ポートマッピング: Opcode 1 (UDP) / 2 (TCP)

## 使用パターン

```swift
let mapper = NATPortMapper()
_ = try await mapper.discoverGateway()
let mapping = try await mapper.requestMapping(
    internalPort: 4001,
    protocol: .tcp
)
let addr = try mapping.multiaddr()
```

## 設計原則

1. **EventEmitting**: `NATPortMapper` は `EventEmitting` プロトコルに準拠
2. **自動更新**: 期限前に自動更新
3. **フォールバック**: UPnP → NAT-PMP の順で試行（handler順序）
4. **単一責任**: 各ファイルが1つの責務を持つ
5. **重複排除**: `UDPSocket` と `extractXMLTagValue()` で共通コードを統合

## テスト

```
Tests/NAT/P2PNATTests/
└── NATPortMapperTests.swift  # 41テスト
    ├── NATPortMapper Tests (config, PortMapping, GatewayType, lifecycle, errors)
    ├── PortMapping Tests (init, equatable, multiaddr)
    ├── NATPortMapperConfiguration Tests (defaults, custom, all fields)
    ├── NATPortMapperEvent Tests (全eventケースの構築・パターンマッチ)
    ├── NATPortMapperError Tests (全errorケースの構築)
    ├── NATTransportProtocol Tests (rawValue)
    └── NetworkUtils Tests (XML tag extraction, service block extraction, UDP socket)
```

**合計: 41テスト** (2026-02-06時点。ネットワークI/O不要のユニットテストに限定)

## Known Issues

- `shutdown()` はゲートウェイ上のマッピングを解放しない（リース期限で自然消滅）
- ゲートウェイキャッシュに TTL がない（ネットワーク変更時はインスタンスを再作成）
- `getDefaultGateway()` は macOS 専用（`/usr/sbin/netstat` に依存）

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (94/100)
- 対象ターゲット: `P2PNAT`
- 実装読解範囲: 14 Swift files / 1463 LOC
- テスト範囲: 3 files / 64 cases / targets 1
- 公開API: types 10 / funcs 7
- 参照網羅率: type 1.0 / func 0.57
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 公開関数の直接参照テストが薄い

### 重点アクション
- API名での直接参照だけでなく、振る舞い検証中心の統合テストを補強する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
