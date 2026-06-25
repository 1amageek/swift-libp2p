# Interoperability Tests

swift-libp2pとgo-libp2p/rust-libp2p間の相互運用テスト。

## 前提条件

- Docker Engine with Docker Compose
- Swift 6.2+

## テストカバレッジ

### 検証済み (Phase 1 - Transport Layer)

| 機能 | プロトコルID | go-libp2p | rust-libp2p |
|------|-------------|-----------|-------------|
| QUIC Transport | - | ✅ | ✅ |
| TLS 1.3 Security | - | ✅ | ✅ |
| TCP Transport | - | ✅ | ✅ |
| WebSocket Transport | - | ✅ | - |
| Noise Security | `/noise` | ✅ | ✅ |
| Yamux Mux | `/yamux/1.0.0` | ✅ | - |
| multistream-select | `/multistream/1.0.0` | ✅ | ✅ |
| Identify | `/ipfs/id/1.0.0` | ✅ | ✅ |
| Ping | `/ipfs/ping/1.0.0` | ✅ | ✅ |

### 検証対象 (Phase 2 - Protocol Layer)

| 機能 | プロトコルID | go-libp2p | rust-libp2p |
|------|-------------|-----------|-------------|
| GossipSub | `/meshsub/1.1.0` | ✅ | - |
| Kademlia DHT | `/ipfs/kad/1.0.0` | ✅ | - |
| Circuit Relay v2 | `/libp2p/circuit/relay/0.2.0/hop` | ✅ | - |

注: 上記の `✅` は **go-libp2p 単一ノード相互運用**（wire互換・基本往復）を示す。複数ノードトポロジ/大規模シナリオは継続対応。
注: Circuit Relay は traversal の選択肢の1つとして扱う（常時必須経路ではない）。

## テスト実行

### 正しい実行手順（必須）

Interopテストは `scripts/interop-test.sh` を唯一の入口として実行します。このスクリプトが Docker Engine / Docker Compose の前提確認、Compose profile に基づく image build、Swift test のタイムアウト実行、失敗時のログ収集を担当します。

```bash
# Docker / Compose 前提確認
scripts/interop-test.sh preflight

# リリース前の最小必須確認
scripts/interop-test.sh smoke

# Transport を触った場合
scripts/interop-test.sh transport

# Protocol を触った場合
scripts/interop-test.sh protocol

# リリース候補確認
scripts/interop-test.sh full
```

`scripts/production-gate.sh` はデフォルトで `scripts/interop-test.sh smoke` を実行します。Docker を使えない環境でローカルの非リリース確認だけ行う場合のみ `--skip-interop` を明示します。

```bash
scripts/production-gate.sh
scripts/production-gate.sh --interop-mode full
scripts/production-gate.sh --skip-interop
```

重要:
- `swift test --filter Interop` を直接常用しない。環境確認とログ収集が抜けるため。
- `docker run` を手で実行しない。image build と topology は `docker-compose.interop.yml` に集約する。
- 失敗時は `.test-artifacts/interop/...` の `docker-info.txt`, `compose.log`, `docker-ps.txt` を根拠に原因を切り分ける。

### Focused Debug

```bash
# 1) 前処理（同期シャットダウン混入チェック）
scripts/check-sync-shutdown-in-deinit.sh Sources/Transport Tests/Interop/Harnesses

# 2) 単一ケース（30秒上限）
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang \
scripts/swift-test-timeout.sh 30 --disable-sandbox --filter "RustInteropTests/identifyGo"

# 3) スイート（初回ビルド120秒 + 以降30秒, 3回再実行）
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang \
scripts/swift-test-hang-guard.sh --repeats 3 --timeout 30 --build-timeout 120 -- \
--disable-sandbox --filter "RustInteropTests"
```

重要:
- 複数の hang-guard 実行を並列に走らせない
- タイムアウト/失敗時は `.test-artifacts/hang-guard/...` のログを根拠に原因を切り分ける

### Phase 1: Transport Layer Tests

```bash
# TCP Transport
swift test --filter TCPInteropTests

# WebSocket Transport
swift test --filter WebSocketInteropTests

# Noise Security
swift test --filter NoiseInteropTests

# Yamux Mux
swift test --filter YamuxInteropTests
```

### Phase 2: Protocol Layer Tests

```bash
# Ping
swift test --filter PingInteropTests

# Identify
swift test --filter IdentifyInteropTests

# GossipSub
swift test --filter GossipSubInteropTests

# Kademlia DHT
swift test --filter KademliaInteropTests

# Circuit Relay
swift test --filter CircuitRelayInteropTests
```

### Phase 3: Integration Tests

```bash
# Full Stack Tests
swift test --filter FullStackInteropTests
```

### 既存テスト

```bash
# go-libp2p QUIC Tests
swift test --filter GoLibp2pInteropTests

# rust-libp2p QUIC Tests
swift test --filter RustInteropTests

# All Interop Tests
swift test --filter Interop
```

## ファイル構成

```
Tests/Interop/
├── README.md                    # このファイル
├── KNOWN_ISSUES.md              # 既知の問題と解決策
├── docker-compose.interop.yml   # マルチノードテスト用
│
├── Dockerfiles/                 # Docker設定
│   ├── Dockerfile.go           # go-libp2p QUIC
│   ├── Dockerfile.rust         # rust-libp2p QUIC
│   ├── Dockerfile.tcp.go       # go-libp2p TCP+Noise
│   ├── Dockerfile.ws.go        # go-libp2p WebSocket+Noise
│   ├── Dockerfile.noise.go     # go-libp2p Noise専用
│   ├── Dockerfile.yamux.go     # go-libp2p Yamux
│   ├── Dockerfile.gossipsub.go # go-libp2p GossipSub
│   ├── Dockerfile.kad.go       # go-libp2p Kademlia
│   └── Dockerfile.relay.go     # go-libp2p Circuit Relay
│
├── Harnesses/                   # テストハーネス
│   ├── InteropHarnessProtocol.swift  # 共通プロトコル
│   ├── GoLibp2pHarness.swift        # go-libp2p QUIC
│   ├── RustLibp2pHarness.swift      # rust-libp2p QUIC
│   ├── GoTCPHarness.swift           # go-libp2p TCP
│   ├── GoWebSocketHarness.swift     # go-libp2p WebSocket
│   └── GoProtocolHarness.swift      # go-libp2p Protocol tests
│
├── Transport/                   # Transport Layer Tests
│   ├── TCPInteropTests.swift
│   └── WebSocketInteropTests.swift
│
├── Security/                    # Security Layer Tests
│   └── NoiseInteropTests.swift
│
├── Mux/                         # Mux Layer Tests
│   └── YamuxInteropTests.swift
│
├── Protocols/                   # Protocol Layer Tests
│   ├── PingInteropTests.swift
│   ├── IdentifyInteropTests.swift
│   ├── GossipSubInteropTests.swift
│   ├── KademliaInteropTests.swift
│   └── CircuitRelayInteropTests.swift
│
├── Integration/                 # Integration Tests
│   └── FullStackInteropTests.swift
│
└── Existing/                    # 既存テスト
    ├── GoLibp2pInteropTests.swift
    └── RustInteropTests.swift
```

## Dockerイメージ

### Transport Layer

| イメージ | トランスポート | セキュリティ | マルチプレクサ |
|---------|--------------|------------|--------------|
| go-libp2p-test | QUIC | TLS 1.3 | QUIC native |
| rust-libp2p-test | QUIC | TLS 1.3 | QUIC native |
| go-libp2p-tcp-test | TCP | Noise | Yamux |
| go-libp2p-ws-test | WebSocket | Noise | Yamux |
| go-libp2p-noise-test | TCP | Noise | Yamux |
| go-libp2p-yamux-test | TCP | Noise | Yamux |

### Protocol Layer

| イメージ | プロトコル | 機能 |
|---------|----------|------|
| go-libp2p-gossipsub-test | GossipSub | Pub/Subメッセージング |
| go-libp2p-kad-test | Kademlia | DHT検索 |
| go-libp2p-relay-test | Circuit Relay v2 | NAT越え |

## マルチノードテスト

```bash
# Docker Compose topology起動
scripts/interop-test.sh up --keep-running

# Transport profile を起動する場合
scripts/interop-test.sh up --profile transport --keep-running

# テスト実行
swift test --filter TopologyInteropTests

# 終了
scripts/interop-test.sh down
```

## トラブルシューティング

### Dockerが起動していない

```
ERROR: Cannot connect to the Docker daemon
```

→ Docker Engine を起動してください。macOS では OrbStack / Docker Desktop など、Docker Engine 互換のruntimeを使用できます。

### テストがタイムアウト

1. Dockerコンテナが正常に起動しているか確認
2. `docker ps` でコンテナ状態を確認
3. `docker logs <container>` でログを確認

### Dockerイメージの再ビルド

```bash
# 特定イメージを削除して再ビルド
docker rmi go-libp2p-tcp-test
swift test --filter TCPInteropTests

# 全イメージを削除
docker rmi go-libp2p-test rust-libp2p-test go-libp2p-tcp-test go-libp2p-noise-test go-libp2p-yamux-test
```

## 実装の違い

### プロトコルネゴシエーション後のデータ送信

| 実装 | 動作 |
|------|------|
| go-libp2p | プロトコル確認とレスポンスを同じパケットで送信 |
| rust-libp2p | プロトコル確認とレスポンスを別々のパケットで送信 |

この違いにより、`MultistreamSelect.negotiate()`の`remainder`を適切に処理する必要があります。
詳細は [KNOWN_ISSUES.md](KNOWN_ISSUES.md) を参照。

### TCP vs QUIC

| 特性 | TCP + Noise + Yamux | QUIC |
|------|-------------------|------|
| 接続確立 | 3段階（TCP→Noise→Yamux） | 1段階 |
| セキュリティ | Noise XX | TLS 1.3 |
| ストリーム多重化 | Yamux | QUIC native |
| NAT越え | 難しい | 容易（UDP） |

## 関連ドキュメント

- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) - 既知の問題と解決策
- [libp2p specs](https://github.com/libp2p/specs) - libp2p仕様
- [go-libp2p](https://github.com/libp2p/go-libp2p) - Go実装
- [rust-libp2p](https://github.com/libp2p/rust-libp2p) - Rust実装
