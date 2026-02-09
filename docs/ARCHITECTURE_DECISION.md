# Architecture Decision: libp2p 思想に基づくモジュール分類

> 2026-02-09 決定。libp2p の思想調査 (go-libp2p, rust-libp2p, specs, 2025 Annual Report) に基づく。

## 背景

swift-libp2p は自律ロボット間通信基盤として開発中。最終目標は:

```
[4] swift-p2p-fleet        — 協調実行（将来）
[3] swift-p2p-task         — タスク交渉（将来）
[2] swift-p2p-capability   — 能力交換（将来）
[1] 通信基盤               — 発見 + メッセージング
```

swift-p2p-discovery のモジュール群を swift-libp2p に吸収した際、「全てが libp2p の思想に沿っているか」を検証する必要が生じた。

## 調査対象

- [libp2p specs](https://github.com/libp2p/specs) — 公式仕様
- [go-libp2p](https://github.com/libp2p/go-libp2p) — Go リファレンス実装
- [rust-libp2p](https://github.com/libp2p/rust-libp2p) — Rust 実装
- [libp2p 2025 Annual Report](https://libp2p.io/reports/annual-reports/2025/) — 方向性

## libp2p の設計思想

### 3 つの核心原則

1. **Identity, not Location** — PeerID は永続的、アドレスは変わる。接続先は「場所」ではなく「誰か」
2. **Transport Agnosticism** — いかなるトランスポートにも依存しない。Multiaddr は自己記述的で拡張可能
3. **Connection Upgrade** — Raw → Secure → Muxed のパイプラインでどのトランスポートも統一的に扱う

### Connection Model

libp2p の全プロトコルは以下の Connection Model に載る:

```
1. ピアを発見する       (Discovery)
2. アドレスに接続する    (Transport.dial → RawConnection)
3. 暗号化する           (Security upgrade)
4. 多重化する           (Mux upgrade)
5. プロトコルをネゴする   (multistream-select)
6. ストリームで通信する   (MuxedStream)
```

Transport が要求する抽象:
- `dial(Multiaddr) → RawConnection`（双方向ストリーム確立）
- `listen(Multiaddr) → Listener`（接続受付）

この抽象に**載るかどうか**が「libp2p に属するか」の判断基準。

### 2025 年次レポートの方向性

- "Agent-to-agent communication and trustless transport for autonomous systems"
- "Heterogeneous network operation under adversarial conditions"
- QUIC/WebRTC/WebTransport の強化
- BLE/LoRa/DTN への言及はなし

## 正規 libp2p プロトコル一覧 (go/rust 共通)

### Core（自動起動）

| プロトコル | Protocol ID | 目的 |
|-----------|-------------|------|
| Identify | `/ipfs/id/1.0.0` | ピア情報交換 |
| Identify/Push | `/ipfs/id/push/1.0.0` | プッシュ更新 |
| Ping | `/ipfs/ping/1.0.0` | 接続確認 |

### Standard（opt-in）

| プロトコル | 目的 |
|-----------|------|
| Kademlia DHT | ピア/コンテンツルーティング |
| GossipSub | Pub/Sub メッセージング |
| Circuit Relay v2 | 1 ホップリレー |
| DCUtR | ホールパンチング |
| AutoNAT | NAT 検出 |
| Rendezvous | namespace ベース発見 |
| mDNS | LAN ピア発見 |

### go-libp2p にはないもの

SWIM, CYCLON, Plumtree, Beacon, MeshRelay, Propagation — いずれも公式 specs に存在しない。

## 分類基準と判断

### 判断軸: Connection Model に載るか

| 判断軸 | 質問 |
|--------|------|
| **Transport** | `dial/listen` で双方向接続を確立できるか？ |
| **Discovery** | ピアの存在とアドレスを知る機構か？ |
| **Protocol** | 確立済みの MuxedStream 上で動作するか？ |

### 各モジュールの判断

#### libp2p の思想に沿うもの → swift-libp2p に残す

| モジュール | 分類 | 理由 |
|-----------|------|------|
| **Beacon (P2PDiscoveryBeacon)** | Discovery | mDNS の物理版。BLE アドバタイジングでピアを発見し Multiaddr を返す。Connection Model のステップ 1 に該当 |
| **SWIM** | Discovery + Membership | IP 上で MuxedStream を使用。メンバーシップ + 障害検出は mDNS にない機能を補完 |
| **CYCLON** | Discovery | IP 上で MuxedStream を使用。ランダムピアサンプリングは DHT と補完関係 |
| **Plumtree** | Broadcast Protocol | IP 上で MuxedStream を使用。GossipSub の学術的基盤、epidemic broadcast tree |

**判断根拠**: これらは全て Connection Model に載る。IP ストリーム上で動作するか（SWIM/CYCLON/Plumtree）、Discovery として機能する（Beacon）。BLE/WiFi Direct は双方向接続が可能であり、libp2p の Transport 抽象に載る。

#### 思想と緊張するもの → swift-p2p-mesh に分離

| モジュール | 問題 | 理由 |
|-----------|------|------|
| **MeshRelay** | Circuit Relay v2 との緊張 | libp2p は v1→v2 でマルチホップリレーを**意図的に削除**した（リソース制御の困難さ）。MeshRelay はそれを復活させる設計 |
| **Propagation** | Connection Model の外 | Spray&Wait + PRoPHET は DTN (Delay-Tolerant Networking) の技術。「接続を確立してストリームで通信」ではなく「遭遇時に store-and-forward」という根本的に異なるモデル |

**判断根拠**:

- **MeshRelay**: マルチホップリレーは「接続できる」前提だが、経路が複雑で Circuit Relay v2 が意図的に排除した設計を含む。Transport Agnosticism の思想とは矛盾しないが、libp2p コミュニティの設計判断と緊張する。
- **Propagation**: 「接続できない」前提の DTN プロトコル。libp2p の Connection Model の**外側**にある。接続を確立せずにメッセージを運ぶ store-and-forward は、libp2p の `dial → upgrade → stream` パイプラインとは根本的に異なる。

**重要: これらは不要ではない**。自律ロボットが IP インフラのない環境（倉庫、屋外、災害現場）で通信するために**必須**。libp2p に入れるべきではないだけで、アーキテクチャのどこかに存在しなければならない。

## 決定: アーキテクチャ分離

```
[4] swift-p2p-fleet          — 協調実行（将来）
[3] swift-p2p-task           — タスク交渉（将来）
[2] swift-p2p-capability     — 能力交換（将来）
[1a] swift-libp2p            — IP 通信基盤（Connection Model）
[1b] swift-p2p-mesh          — 非 IP/断続通信基盤（DTN Model）
```

### [1a] swift-libp2p — Connection Model

IP ネットワーク上の接続ベース通信。libp2p 思想準拠。

```
swift-libp2p/
  Core/           P2PCore (PeerID, Multiaddr, Envelope, PeerRecord)
  Transport/      TCP, QUIC, WebSocket, WebRTC, WebTransport, Memory
  Security/       Noise, TLS, Plaintext, Pnet
  Mux/            Yamux, Mplex
  Negotiation/    multistream-select
  Protocols/
    ├── Identify, Ping                    ← Core（自動起動）
    ├── Kademlia, GossipSub               ← Routing + PubSub
    ├── CircuitRelay, DCUtR, AutoNAT      ← NAT 穴あけ
    ├── Rendezvous, HTTP                  ← 発見 + HTTP
    └── Plumtree                          ← Epidemic Broadcast（IP 上）
  Discovery/
    ├── mDNS                              ← LAN 発見
    ├── SWIM, CYCLON                      ← メンバーシップ（IP 上）
    ├── Beacon (P2PDiscoveryBeacon)        ← 物理近接発見（mDNS の物理版）
    └── CompositeDiscovery                ← 統合
  NAT/            UPnP, NAT-PMP
  Integration/    Node (Host/Swarm 相当)
```

### [1b] swift-p2p-mesh — DTN Model

断続的接続環境のメッシュ通信。swift-libp2p に依存。

```
swift-p2p-mesh/
  Sources/
    P2PMeshRelay/        ← マルチホップ転送、物理メディア間ブリッジ
    P2PPropagation/      ← Spray&Wait + PRoPHET、store-and-forward
  Tests/
    P2PMeshRelayTests/
    P2PPropagationTests/
  Package.swift          ← swift-libp2p (P2PCore, P2PProtocols, P2PMux) に依存
```

### 上位層からの利用

[2]-[4] の上位層は環境に応じて使い分ける:

- IP インフラあり → [1a] swift-libp2p（GossipSub, Kademlia, Circuit Relay）
- IP インフラなし → [1b] swift-p2p-mesh（MeshRelay, Propagation）
- 混在環境 → 両方（Beacon で発見、状況に応じてルーティング）

## BLE/WiFi Direct Transport について

BLE GATT と WiFi Direct は双方向接続を確立でき、libp2p の Transport 抽象（`dial/listen`）に載る。将来的に swift-libp2p に Transport 実装を追加可能:

```
Transport/
  ├── BLE/        ← BLE GATT 接続（将来）
  └── WiFiDirect/ ← WiFi Direct 接続（将来）
```

Beacon (Discovery) で発見 → BLE Transport で接続 → Security upgrade → Mux upgrade → Stream、という libp2p 標準フローが成立する。

MultiaddrProtocol に追加した BLE(0x01B0)/WiFi(0x01B1) コードはこの将来の Transport のために有用。LoRa(0x01B2)/NFC(0x01B3) は Transport 適性が低いため、Beacon の Discovery メタデータとしてのみ使用。

## go/rust との相互運用性

| レイヤー | 相互運用可能 | 備考 |
|---------|------------|------|
| Core (PeerID, Multiaddr) | YES | 同一仕様 |
| Transport (TCP, QUIC) | YES | 同一プロトコル |
| Security (Noise, TLS) | YES | 同一ハンドシェイク |
| Mux (Yamux) | YES | 同一プロトコル |
| Identify, Ping, Kademlia | YES | 同一 Protocol ID |
| GossipSub | YES | 同一 Protocol ID |
| Circuit Relay, DCUtR, AutoNAT | YES | 同一仕様 |
| SWIM, CYCLON, Plumtree | NO | 非正規（Swift 独自） |
| Beacon | NO | 非正規（物理発見、go/rust に対応なし） |
| MeshRelay, Propagation | N/A | swift-p2p-mesh に分離 |

## 参考文献

- [libp2p specs](https://github.com/libp2p/specs)
- [go-libp2p](https://github.com/libp2p/go-libp2p) — Host + Swarm パターン
- [rust-libp2p](https://github.com/libp2p/rust-libp2p) — Swarm + NetworkBehaviour パターン
- [libp2p 2025 Annual Report](https://libp2p.io/reports/annual-reports/2025/)
- [RFC 6693](https://www.rfc-editor.org/rfc/rfc6693) — PRoPHET Protocol (Propagation の基盤)
- Spyropoulos et al. 2005 — Binary Spray and Wait (Propagation の基盤)
