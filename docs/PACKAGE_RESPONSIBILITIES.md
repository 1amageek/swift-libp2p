# Package Responsibilities

## Design Philosophy: Modular & Composable

ユーザーは必要な技術だけを選択して組み合わせられる。

**重要な原則:**
- P2PCore は最小限に保つ（太ると破壊的変更が増える）
- Protocol定義と実装を分離
- 実装モジュールは Protocol定義モジュールのみに依存

## Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         User Application                              │
├──────────────────────────────────────────────────────────────────────┤
│  P2P (統合層 - Protocol依存のみ、実装依存なし)                       │
├───────────┬──────────┬─────────┬────────────┬────────────────────────┤
│P2PTransport│P2PSecurity│ P2PMux │P2PDiscovery│    P2PProtocols       │
│ (Protocol) │(Protocol)│(Protocol)│(Protocol) │    (Protocol)        │
├───────────┼──────────┼─────────┼────────────┼────────────────────────┤
│   TCP     │  Noise   │  Yamux  │   SWIM     │ Ping    │ Identify   │
│   QUIC    │  TLS     │  Mplex  │   mDNS     │ GossipSub│ Kademlia  │
│  WebRTC   │ Plaintext│         │   CYCLON   │CircuitRelay│ AutoNAT  │
│ WebSocket │          │         │            │ DCUtR    │ Plumtree  │
│  Memory   │          │         │            │          │           │
├───────────┴──────────┴─────────┴────────────┴────────────────────────┤
│   P2PNAT (UPnP, NAT-PMP)  │  P2PCertificate  │  P2PNegotiation     │
├────────────────────────────┴─────────────────┴───────────────────────┤
│                            P2PCore                                    │
│      (最小限の共通抽象: PeerID, Multiaddr, Connection, Varint)        │
└──────────────────────────────────────────────────────────────────────┘

選択例:
├── TCP + Noise + Yamux → Go/Rust互換の標準構成
├── QUIC → 高性能構成（Transport + Security + Mux 統合）
├── WebRTC → ブラウザ互換構成
├── WebSocket + Noise + Yamux → Web環境向け
├── Memory + Plaintext + Yamux → テスト用
└── TCP + Noise + Yamux + GossipSub + Kademlia → フル機能
```

---

## Directory Structure

```
swift-libp2p/
Sources/
├── Core/
│   └── P2PCore/                 # 最小限の共通抽象のみ
│       ├── Identity/            # PeerID, PublicKey, KeyPair
│       ├── Addressing/          # Multiaddr, MultiaddrProtocol
│       ├── Connection/          # RawConnection, SecuredConnection (protocols)
│       ├── Lifecycle/           # ライフサイクル管理
│       ├── Record/              # ピアレコード
│       └── Utilities/           # Varint, Base58, Multihash, HexEncoding
│
├── Transport/
│   ├── P2PTransport/            # Protocol定義 (Transport, Listener)
│   ├── TCP/                     # P2PTransportTCP (SwiftNIO)
│   ├── QUIC/                    # P2PTransportQUIC (swift-quic)
│   │   └── TLS/                 # QUIC TLS 統合
│   ├── WebRTC/                  # P2PTransportWebRTC (swift-webrtc)
│   ├── WebSocket/               # P2PTransportWebSocket (SwiftNIO)
│   └── Memory/                  # P2PTransportMemory (テスト用)
│
├── Security/
│   ├── P2PSecurity/             # Protocol定義 (SecurityUpgrader)
│   ├── Certificate/             # P2PCertificate (libp2p TLS証明書)
│   ├── Noise/                   # P2PSecurityNoise (XX pattern)
│   ├── TLS/                     # P2PSecurityTLS
│   └── Plaintext/               # P2PSecurityPlaintext (テスト用)
│
├── Mux/
│   ├── P2PMux/                  # Protocol定義 (Muxer, MuxedConnection, MuxedStream)
│   ├── Yamux/                   # P2PMuxYamux (/yamux/1.0.0)
│   └── Mplex/                   # P2PMuxMplex (/mplex/6.7.0)
│
├── Negotiation/
│   └── P2PNegotiation/          # multistream-select (/multistream/1.0.0)
│
├── Discovery/
│   ├── P2PDiscovery/            # Protocol定義 (DiscoveryService)
│   ├── SWIM/                    # P2PDiscoverySWIM (メンバーシップ)
│   ├── MDNS/                    # P2PDiscoveryMDNS (LAN探索)
│   └── CYCLON/                  # P2PDiscoveryCYCLON (ピアサンプリング)
│
├── NAT/
│   ├── P2PNAT/                  # NAT Protocol定義
│   ├── UPnP/                    # UPnP ポートマッピング
│   └── NATPMP/                  # NAT-PMP ポートマッピング
│
├── Protocols/
│   ├── P2PProtocols/            # Protocol定義 (ProtocolHandler)
│   ├── Ping/                    # P2PPing (/ipfs/ping/1.0.0)
│   ├── Identify/                # P2PIdentify (/ipfs/id/1.0.0)
│   ├── GossipSub/               # P2PGossipSub (/meshsub/1.1.0, /meshsub/1.2.0)
│   │   ├── Core/                # MessageID, Topic, Message
│   │   ├── Router/              # メッシュルーティング
│   │   ├── Scoring/             # ピアスコアリング
│   │   ├── Heartbeat/           # ハートビート処理
│   │   └── Wire/                # ワイヤフォーマット
│   ├── Kademlia/                # P2PKademlia (/ipfs/kad/1.0.0)
│   │   └── Storage/             # DHT ストレージ
│   ├── CircuitRelay/            # P2PCircuitRelay (/libp2p/circuit/relay/0.2.0/hop, /stop)
│   │   └── Transport/           # RelayTransport
│   ├── DCUtR/                   # P2PDCUtR (/libp2p/dcutr)
│   ├── AutoNAT/                 # P2PAutoNAT (/libp2p/autonat/1.0.0)
│   └── Plumtree/                # P2PPlumtree (Epidemic Broadcast)
│
└── Integration/
    └── P2P/                     # 統合層 (Node, ConnectionUpgrader)
        ├── Connection/          # ConnectionManager, ConnectionUpgrader
        └── Resource/            # ResourceManager, ResourceTrackedStream

Benchmarks/
└── P2PBenchmarks/               # パフォーマンスベンチマーク

Examples/
└── PingPongDemo/                # デモアプリ

Tests/
├── Core/P2PCoreTests/
├── Transport/
│   ├── P2PTransportTests/       # TCP, Memory テスト
│   ├── QUICTests/               # QUIC E2E テスト
│   ├── WebRTCTests/             # WebRTC E2E テスト
│   └── WebSocketTests/          # WebSocket テスト
├── Security/
│   ├── P2PSecurityTests/
│   ├── NoiseTests/              # Noise 統合テスト
│   ├── PlaintextTests/
│   ├── TLSTests/
│   └── CertificateTests/
├── Mux/
│   ├── P2PMuxTests/
│   ├── YamuxTests/              # Yamux 単体・統合テスト
│   └── MplexTests/              # Mplex 単体・統合テスト
├── Negotiation/P2PNegotiationTests/
├── Discovery/
│   ├── P2PDiscoveryTests/
│   └── CYCLONTests/
├── NAT/P2PNATTests/
├── Protocols/
│   ├── PingTests/               # Ping E2E テスト
│   ├── IdentifyTests/           # Identify E2E テスト
│   ├── GossipSubTests/          # GossipSub ルーターテスト
│   ├── KademliaTests/
│   ├── CircuitRelayTests/       # CircuitRelay E2E・統合テスト
│   ├── DCUtRTests/              # DCUtR 統合テスト
│   ├── AutoNATTests/            # AutoNAT 統合テスト
│   └── PlumtreeTests/
├── Integration/P2PTests/        # Node E2E テスト
└── Interop/                     # Go/Rust 相互運用テスト
```

---

## 依存関係グラフ

```
                        ┌─────────────────────────────────────┐
                        │              P2PCore                  │
                        │  (PeerID, Multiaddr, RawConnection,  │
                        │   SecuredConnection, Varint)         │
                        └─────────────────────────────────────┘
                                          ▲
        ┌────────────────────────────────┼────────────────────────────────┐
        │                    │           │           │                    │
┌───────┴────────┐ ┌────────┴────────┐ ┌┴──────────┐ ┌┴──────────┐ ┌────┴───────┐
│  P2PTransport  │ │   P2PSecurity   │ │  P2PMux   │ │P2PDiscovery│ │P2PProtocols│
│ (Transport,    │ │(SecurityUpgrader)│ │(Muxer,    │ │            │ │(Protocol   │
│  Listener)     │ │                 │ │MuxedStream)│ │            │ │ Handler)   │
└───────┬────────┘ └────────┬────────┘ └┬──────────┘ └┬──────────┘ └────┬───────┘
        │                   │           │             │                  │
   ┌────┼────┬────┬────┐   ├────┬────┐ ├────┐    ┌───┼────┬────┐  ┌───┼────┬────┬────┬────┬────┬────┐
   │    │    │    │    │   │    │    │ │    │    │   │    │    │  │   │    │    │    │    │    │    │
   ▼    ▼    ▼    ▼    ▼   ▼    ▼    ▼ ▼    ▼    ▼   ▼    ▼    ▼  ▼   ▼    ▼    ▼    ▼    ▼    ▼    ▼
  TCP  QUIC WebRT WebSo Mem Noise TLS Plntxt Yamux Mplex SWIM mDNS CYCLON Ping Ident GsSub Kad CirRly DCUtR AutoNAT Plmtr
```

### 外部依存関係

| パッケージ | 用途 |
|-----------|------|
| `swift-nio` | TCP, WebSocket, バッファ管理 |
| `swift-crypto` | 暗号プリミティブ (SHA-256, HMAC, ChaChaPoly) |
| `swift-log` | 構造化ロギング |
| `swift-quic` | QUIC トランスポート |
| `swift-tls` | TLS セキュリティ |
| `swift-webrtc` | WebRTC トランスポート |
| `swift-mDNS` | mDNS ディスカバリ |
| `swift-SWIM` | SWIM メンバーシップ |
| `swift-nio-udp` | UDP トランスポート (SWIM用) |
| `swift-certificates` | X.509 証明書 (libp2p TLS) |
| `swift-asn1` | ASN.1 エンコーディング |

---

## Package Details

### P2PCore (必須・最小限)

**責務**: 最小限の共通抽象のみ

| カテゴリ | 型 | 責務 |
|---------|-----|------|
| **Identity** | `PeerID` | ピアの一意識別子（公開鍵由来） |
| | `PublicKey` | 公開鍵の表現 |
| | `PrivateKey` | 秘密鍵の表現 |
| | `KeyPair` | 鍵ペア |
| | `KeyType` | 鍵種別（Ed25519, Secp256k1等） |
| **Addressing** | `Multiaddr` | 自己記述型ネットワークアドレス |
| | `MultiaddrProtocol` | アドレスプロトコルコンポーネント |
| **Connection** | `RawConnection` | 生のネットワーク接続 (protocol) |
| | `SecuredConnection` | 暗号化された接続 (protocol) |
| | `SecurityRole` | initiator / responder |
| **Utilities** | `Varint` | 可変長整数エンコーディング（スタックバッファ最適化） |
| | `Multihash` | 自己記述型ハッシュ |
| | `Base58` | Base58エンコーディング |

**依存関係:**
- `swift-crypto` (暗号プリミティブ)
- `swift-log` (ロギング)
- `swift-nio` (NIOCore, NIOFoundationCompat — ByteBuffer)

**含まないもの:**
- Transport/Security/Mux の Protocol定義（各モジュールへ）
- ネットワーク通信の実装
- 状態管理（ConnectionPool等）

---

### P2PTransport (Protocol定義)

**責務**: Transport 抽象の定義

**依存関係:** P2PCore, P2PMux

---

### P2PTransportTCP (実装)

**責務**: SwiftNIO を使用した TCP 実装

**依存関係:** P2PTransport, swift-nio (NIOCore, NIOPosix)

**パス:** `Sources/Transport/TCP`

---

### P2PTransportQUIC (実装)

**責務**: QUIC トランスポート (Transport + Security + Mux 統合)

QUIC は暗号化と多重化を内蔵するため、SecurityUpgrader と Muxer のネゴシエーションをバイパスする。

**依存関係:** P2PTransport, P2PCore, P2PMux, swift-quic

**パス:** `Sources/Transport/QUIC`

---

### P2PTransportWebRTC (実装)

**責務**: WebRTC トランスポート（ブラウザ互換の P2P 接続）

**依存関係:** P2PTransport, P2PCore, P2PMux, swift-webrtc

**パス:** `Sources/Transport/WebRTC`

---

### P2PTransportWebSocket (実装)

**責務**: WebSocket トランスポート（Web 環境向け）

**依存関係:** P2PTransport, swift-nio (NIOCore, NIOPosix, NIOHTTP1, NIOWebSocket)

**パス:** `Sources/Transport/WebSocket`

---

### P2PTransportMemory (実装)

**責務**: テスト用インメモリ実装

**依存関係:** P2PTransport のみ

**パス:** `Sources/Transport/Memory`

---

### P2PSecurity (Protocol定義)

**責務**: Security 抽象の定義（SecurityUpgrader）

**依存関係:** P2PCore のみ

---

### P2PCertificate

**責務**: libp2p TLS 証明書の生成・検証（X.509 拡張による PeerID 埋め込み）

**依存関係:** P2PCore, swift-certificates, swift-asn1, swift-crypto

**パス:** `Sources/Security/Certificate`

---

### P2PSecurityNoise (実装)

**責務**: Noise Protocol Framework XX パターン（X25519 + ChaChaPoly-1305）

**プロトコルID:** `/noise`

**依存関係:** P2PSecurity, swift-crypto

**パス:** `Sources/Security/Noise`

---

### P2PSecurityTLS (実装)

**責務**: libp2p TLS 1.3 セキュリティ

**プロトコルID:** `/tls/1.0.0`

**依存関係:** P2PSecurity, P2PCertificate, swift-tls

**パス:** `Sources/Security/TLS`

---

### P2PSecurityPlaintext (実装)

**責務**: テスト用の暗号化なし実装

**プロトコルID:** `/plaintext/2.0.0`

**依存関係:** P2PSecurity のみ

**パス:** `Sources/Security/Plaintext`

---

### P2PMux (Protocol定義)

**責務**: Muxer 抽象の定義（Muxer, MuxedConnection, MuxedStream）

**依存関係:** P2PCore のみ

---

### P2PMuxYamux (実装)

**責務**: Yamux multiplexer（ゼロコピー ByteBuffer encode/decode）

**プロトコルID:** `/yamux/1.0.0`

**依存関係:** P2PMux, swift-nio (NIOCore)

**パス:** `Sources/Mux/Yamux`

---

### P2PMuxMplex (実装)

**責務**: Mplex multiplexer

**プロトコルID:** `/mplex/6.7.0`

**依存関係:** P2PMux, swift-nio (NIOCore)

**パス:** `Sources/Mux/Mplex`

---

### P2PNegotiation

**責務**: multistream-select プロトコル

**プロトコルID:** `/multistream/1.0.0`

**依存関係:** P2PCore のみ

---

### P2PDiscovery (Protocol定義)

**責務**: Discovery 抽象の定義

**依存関係:** P2PCore のみ

---

### P2PDiscoverySWIM (実装)

**責務**: SWIM membership protocol（障害検出・ゴシップ）

**依存関係:** P2PDiscovery, swift-SWIM

**パス:** `Sources/Discovery/SWIM`

---

### P2PDiscoveryMDNS (実装)

**責務**: mDNS によるLAN内ピア探索

**依存関係:** P2PDiscovery, swift-mDNS

**パス:** `Sources/Discovery/MDNS`

---

### P2PDiscoveryCYCLON (実装)

**責務**: CYCLON ピアサンプリングプロトコル

**依存関係:** P2PDiscovery, P2PCore

**パス:** `Sources/Discovery/CYCLON`

---

### P2PNAT

**責務**: NAT トラバーサル（UPnP, NAT-PMP ポートマッピング）

**パス:** `Sources/NAT`

---

### P2PProtocols (Protocol定義)

**責務**: アプリケーションプロトコルのハンドラー抽象

**依存関係:** P2PCore, P2PMux

---

### P2PPing (実装)

**責務**: libp2p Ping プロトコル

**プロトコルID:** `/ipfs/ping/1.0.0`

**パス:** `Sources/Protocols/Ping`

---

### P2PIdentify (実装)

**責務**: libp2p Identify プロトコル（ピア情報交換）

**プロトコルID:** `/ipfs/id/1.0.0`

**パス:** `Sources/Protocols/Identify`

---

### P2PGossipSub (実装)

**責務**: GossipSub v1.1/v1.2 Pub/Sub（メッシュネットワーク + ゴシップ伝播）

**プロトコルID:** `/meshsub/1.1.0`, `/meshsub/1.2.0`

**最適化:** MessageID (FNV-1a キャッシュ), Topic (ハッシュキャッシュ)

**パス:** `Sources/Protocols/GossipSub`

---

### P2PKademlia (実装)

**責務**: Kademlia DHT（ピアルーティング・コンテンツ探索）

**プロトコルID:** `/ipfs/kad/1.0.0`

**最適化:** KademliaKey (4xUInt64 スタック格納, XOR距離 9.2x高速化)

**パス:** `Sources/Protocols/Kademlia`

---

### P2PCircuitRelay (実装)

**責務**: Circuit Relay v2（NAT越えのリレー接続）

**プロトコルID:** `/libp2p/circuit/relay/0.2.0/hop`, `/libp2p/circuit/relay/0.2.0/stop`

**パス:** `Sources/Protocols/CircuitRelay`

---

### P2PDCUtR (実装)

**責務**: Direct Connection Upgrade through Relay（リレー経由の直接接続昇格）

**プロトコルID:** `/libp2p/dcutr`

**パス:** `Sources/Protocols/DCUtR`

---

### P2PAutoNAT (実装)

**責務**: AutoNAT（外部到達可能性の自動検出）

**プロトコルID:** `/libp2p/autonat/1.0.0`

**パス:** `Sources/Protocols/AutoNAT`

---

### P2PPlumtree (実装)

**責務**: Plumtree Epidemic Broadcast（効率的なブロードキャスト）

**パス:** `Sources/Protocols/Plumtree`

---

### P2P (統合層)

**責務**: 統合エントリーポイント（Node, ConnectionUpgrader, ResourceManager）

**依存関係:**
- P2PCore
- P2PTransport (Protocol)
- P2PSecurity (Protocol)
- P2PMux (Protocol)
- P2PNegotiation
- P2PDiscovery (Protocol)
- P2PProtocols (Protocol)

**含まないもの:**
- 具体的な実装（TCP, Noise, Yamux等）への依存

---

## rust-libp2p との比較

| 観点 | rust-libp2p | swift-libp2p |
|------|-------------|--------------|
| **Core** | `libp2p-core` | `P2PCore` |
| **Swarm** | `libp2p-swarm` | `P2P` (統合層) |
| **Transport** | `libp2p-tcp`, `libp2p-quic`, `libp2p-webrtc` | `P2PTransportTCP`, `P2PTransportQUIC`, `P2PTransportWebRTC` |
| **Security** | `libp2p-noise`, `libp2p-tls` | `P2PSecurityNoise`, `P2PSecurityTLS` |
| **Muxer** | `libp2p-yamux`, `libp2p-mplex` | `P2PMuxYamux`, `P2PMuxMplex` |
| **Pub/Sub** | `libp2p-gossipsub` | `P2PGossipSub` |
| **DHT** | `libp2p-kad` | `P2PKademlia` |
| **Relay** | `libp2p-relay` | `P2PCircuitRelay` |
| **NAT** | `libp2p-autonat`, `libp2p-dcutr` | `P2PAutoNAT`, `P2PDCUtR` |
| **Protocol分離** | trait + impl crate | Protocol module + impl module |
| **非同期** | async-std/tokio | Swift Concurrency (async/await) |
| **状態管理** | Mutex/RwLock | class + Mutex<T> |

---

## Wire Protocol Compatibility

Go/Rust互換のプロトコルID:

| コンポーネント | プロトコルID |
|---------------|-------------|
| multistream-select | `/multistream/1.0.0` |
| Noise | `/noise` |
| TLS | `/tls/1.0.0` |
| Yamux | `/yamux/1.0.0` |
| Mplex | `/mplex/6.7.0` |
| Identify | `/ipfs/id/1.0.0` |
| Ping | `/ipfs/ping/1.0.0` |
| GossipSub v1.1 | `/meshsub/1.1.0` |
| GossipSub v1.2 | `/meshsub/1.2.0` |
| Kademlia | `/ipfs/kad/1.0.0` |
| Circuit Relay v2 (hop) | `/libp2p/circuit/relay/0.2.0/hop` |
| Circuit Relay v2 (stop) | `/libp2p/circuit/relay/0.2.0/stop` |
| DCUtR | `/libp2p/dcutr` |
| AutoNAT | `/libp2p/autonat/1.0.0` |
