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
