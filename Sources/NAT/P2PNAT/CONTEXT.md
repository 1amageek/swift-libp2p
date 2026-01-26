# P2PNAT 実装

## 概要

NAT 穴あけのためのポートマッピングサービス。
UPnP IGD と NAT-PMP の両方をサポートし、AutoNAT と統合。

## アーキテクチャ

```
NATPortMapper (統合サービス)
├── UPnPClient (UPnP IGD プロトコル)
│   ├── UPnPDiscovery (SSDP 発見)
│   └── UPnPSOAP (SOAP リクエスト)
└── NATPMPClient (NAT-PMP プロトコル)
    └── NATPMPMessage (メッセージ構造体)
```

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
```

## 設計原則

1. **EventEmitting**: マッピングイベントを公開
2. **自動更新**: 期限前に自動更新
3. **フォールバック**: UPnP → NAT-PMP の順で試行

## Known Issues

### HIGH: UDP ソケット操作の重複

同一パターンのソケット操作が3箇所で重複している。

**場所**:
- `NATPortMapper.swift:639-670` (`getExternalAddressNATPMP`)
- `NATPortMapper.swift:697-740` (`requestMappingNATPMP`)
- `NATPortMapper.swift:418-450` (`discoverUPnPGateway`)

**対応**: ヘルパー関数を抽出

```swift
private func sendUDPRequest(
    to address: String,
    port: UInt16,
    data: [UInt8],
    expectedResponseSize: Int,
    timeout: Int = 3
) async throws -> [UInt8]
```

### HIGH: discoverGateway() でエラーを握りつぶしている

**場所**: `NATPortMapper.swift:200-215`

```swift
// BAD
if let gateway = try? await discoverUPnPGateway() { ... }
if let gateway = try? await discoverNATPMPGateway() { ... }
```

**対応**: エラーを保持し、両方失敗した場合に最後のエラーを throw

### MEDIUM: XML 抽出ロジックの重複

**場所**:
- `NATPortMapper.swift:503-510` (`extractControlURL`)
- `NATPortMapper.swift:530-537` (`getExternalAddressUPnP`)

**対応**: `extractXMLTag(named:from:)` ヘルパーを抽出

### MEDIUM: タイムアウトのハードコード

**場所**:
- `NATPortMapper.swift:665` - `timeval(tv_sec: 3, ...)`
- `NATPortMapper.swift:734` - 同上

**対応**: `configuration.discoveryTimeout` を使用

### LOW: PortMapping.multiaddr で try? 使用

**場所**: `NATPortMapper.swift:49-56`

```swift
public var multiaddr: Multiaddr? {
    return try? Multiaddr("/ip4/\(externalAddress)/tcp/\(externalPort)")
}
```

**対応**: `func multiaddr() throws -> Multiaddr` に変更

### HIGH: 単一責任原則違反

`NATPortMapper` が876行で3つの責務を持つ。

**対応**: プロトコルハンドラを分離

```
NATPortMapper (facade)
├── UPnPPortMapper
└── NATPMPPortMapper
```
