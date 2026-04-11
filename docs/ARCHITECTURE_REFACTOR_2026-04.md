# Architecture Refactor Plan (2026-04)

## Goal

swift-libp2p は通信自体は成立している。次の段階では以下を優先する。

1. **統一感のある抽象**
2. **責務の明確な分離**
3. **高速化と安定性を阻害しない API**
4. **Node 利用者にとって理解しやすい構成**

後方互換は要求しない。理想形に寄せる。

---

## 現状の設計上の緊張

### 1. Connection Model は 2 系統ある

- 標準経路: `RawConnection -> SecuredConnection -> MuxedConnection`
- 例外経路: `SecuredTransport -> MuxedConnection`

この例外が `Swarm` まで漏れており、listen/dial/reconnect/inbound accept のすべてに transport 種別分岐がある。

### 2. Service 合成は暗黙的

- `Node` は `services: [any NodeService]` を受け取る
- 実際の役割は runtime downcast で発見する
- `StreamService` / `PeerObserver` / `DiscoveryBehaviour` の追加が call site に見えない

### 3. `NodeContext` が広い

`NodeContext` は便利だが、identity, stream opening, listen addresses, supported protocols, peerStore をまとめて持つ。
これは将来的に integration 層を肥大化させる。

### 4. Discovery ownership がコメント依存

`CompositeDiscovery` は排他的所有を前提にしているが、型レベルでは plain existential array を受け取るだけである。

---

## Target Design

## A. Connection pipeline は維持する

`Raw -> Secure -> Muxed` 自体は維持する。これは libp2p の設計思想として正しい。

ただし **このパイプラインは Integration 層の外へ漏らさない**。

### 新しい境界

`Swarm` は以下だけを扱う:

- `ConnectionDriver`
- `ConnectionListener`
- `IncomingConnectionCandidate`
- `MuxedConnection`

### 意味

- **Transport / Security / Mux** は下位レイヤの責務
- **Swarm** は接続ライフサイクル管理だけに集中する
- QUIC/WebRTC などの native secure transport も、標準 transport も、Swarm から見れば同じ形になる

### 重要な設計判断

- `SecuredTransport` という lower-level optimization は許容する
- ただしそれは `ConnectionDriver` の中で吸収する
- **Swarm は transport 種別で分岐しない**

---

## B. inbound accept は 2 段階に分離する

inbound では次の順序を守る:

1. remote address を観測
2. accept-stage gating / inbound limits を適用
3. 接続を確立（upgrade or native secured）
4. secured-stage gating / per-peer limits / resource reservation
5. pool 登録

このため listener は直ちに `MuxedConnection` を返すのではなく、**`IncomingConnectionCandidate`** を返す。

これにより、

- raw transport は upgrade 前に reject できる
- native secure transport も同じ accept API に乗る
- `Swarm` は accept 段階と secured 段階を明示的に保てる

---

## C. Service model は次段階で明示化する

今回は document-first とするが、最終形は次を目指す。

### 現行

- `services: [any NodeService]`
- runtime capability discovery

### 目標

- `NodeFeatures` または `ServiceRegistry`
- 構成時に role を明示
- protocol handlers / peer observers / discovery behaviours を登録時に確定

例:

```swift
NodeFeatures { builder in
    builder.add(identify) { feature in
        feature.handlesInboundStreams()
        feature.observesPeers()
        feature.requiresIdentityContext()
        feature.requiresListenAddressContext()
        feature.requiresSupportedProtocolsContext()
        feature.requiresStreamOpener()
        feature.activatesOnStart()
    }
    builder.add(mdns) { feature in
        feature.observesPeers()
        feature.participatesInDiscovery()
    }
}
```

これにより startup/shutdown/order を明示しつつ、各サービスが
Node に何を提供し、何を要求するかを registration DSL 上で閉じ込める。
さらに Node 側では registration bag をそのまま保持せず、
role 別 registry に正規化して起動シーケンスを組み立てる。

---

## D. `NodeContext` は role-based interfaces に分割する

最終的には以下のような小さい interface 群に分割する。

- `IdentityContext`
- `AddressContext`
- `ProtocolCatalog`
- `StreamOpener`
- `PeerStoreContext`

サービスは必要なものだけを要求する。

---

## E. Discovery ownership は builder で表現する

`CompositeDiscovery` には将来的に factory / builder ベースの構成を導入する。

例:

```swift
CompositeDiscovery.build(localPeerID: peerID) { builder in
    builder.addMDNS(configuration: .default, weight: 0.8)
    builder.addSWIM(configuration: .default, weight: 1.0)
}
```

これにより composition root を明確にし、child service の生成を
CompositeDiscovery の構成点に閉じ込める。

---

## Refactor Phases

### Phase 1

- `Swarm` 境界に `ConnectionDriver` を導入
- `SecuredTransport` 分岐を `Swarm` から除去
- inbound accept を `IncomingConnectionCandidate` ベースに統一

### Phase 2

- `NodeService` runtime discovery を `ServiceRegistry` に置換
- startup/shutdown ordering を registry に移す

### Phase 3

- `NodeContext` 分割
- 各 service を必要最小 interface へ移行

### Phase 4

- `CompositeDiscovery` ownership を builder/factory へ変更

---

## Success Criteria

1. `Swarm` に transport 種別分岐がない
2. inbound/outbound/reconnect が同じ connection abstraction を使う
3. listener 形状が統一されている
4. サービス合成と lifecycle ordering が明示的
5. integration API の変更が lower-level protocol details に引きずられない
