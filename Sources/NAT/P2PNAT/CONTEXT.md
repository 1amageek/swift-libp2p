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

## Known Issues

- `shutdown()` はゲートウェイ上のマッピングを解放しない（リース期限で自然消滅）
- ゲートウェイキャッシュに TTL がない（ネットワーク変更時はインスタンスを再作成）
- `getDefaultGateway()` は macOS 専用（`/usr/sbin/netstat` に依存）
