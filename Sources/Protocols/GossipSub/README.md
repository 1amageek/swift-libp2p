# P2PGossipSub

GossipSub v1.1/v1.2 Pub/Sub プロトコルの実装。メッシュネットワークを維持し、ゴシッププロトコルによる効率的なメッセージ伝播を提供する。

## プロトコル

- `/meshsub/1.1.0` - GossipSub v1.1
- `/meshsub/1.2.0` - GossipSub v1.2 (IDONTWANT)

## MessageID

メッセージの一意識別子。重複排除と IHAVE/IWANT ゴシップ操作に使用される。

### 最適化

初期化時に FNV-1a ハッシュを事前計算し、Dictionary/Set 操作を O(1) に最適化。等値比較ではハッシュ不一致時に早期リターンする。

```swift
let id = MessageID(bytes: data)
// hash(into:) は事前計算済みの整数を1回 combine するだけ
// == はハッシュ不一致で即 false を返す
```

### ベンチマーク

環境: Apple Silicon, macOS, Debug build

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| `init(bytes:)` 20B FNV-1a 計算 | 1,010 | 5,000,000 |
| `hash(into:)` キャッシュ済み O(1) | 532 | 10,000,000 |
| `==` 同一値 (ハッシュ一致 + bytes比較) | 640 | 10,000,000 |
| `==` 異なる値 (ハッシュ不一致→早期リターン) | 979 | 10,000,000 |
| Set insert 1,000件 | 175,255 | 10,000 |
| Set contains (1,000件) | 890 | 5,000,000 |
| `computeFromHash` SHA-256 | 7,847 | 100,000 |

#### ベースライン比較

| 操作 | 最適化後 | ベースライン (Data.hash) | 備考 |
|------|------:|------:|------|
| `hash(into:)` | 532 ns | 529 ns | 同等速度 |

ハッシュ速度自体は同等だが、FNV-1a の事前計算により Set/Dictionary 操作が安定して高速に動作する。

---

## Topic

トピック識別子。Pub/Sub のメッセージチャネルを表す。

### 最適化

初期化時に `Hasher` でハッシュ値を事前計算。異なるトピックとの `==` 比較ではハッシュ不一致で文字列比較をスキップする。GossipSub ではトピックマッチングの大半が不一致であるため、この早期リターンの実用効果が大きい。

```swift
let topic = Topic("blocks")
// hash(into:) は事前計算済みの整数を combine するだけ
// == はハッシュ不一致で即 false（文字列比較なし）
```

### ベンチマーク

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| `init` 短い文字列 ("blocks") | 917 | 5,000,000 |
| `init` 長い文字列 (46文字) | 994 | 5,000,000 |
| `hash(into:)` キャッシュ済み O(1) | 961 | 10,000,000 |
| Dictionary lookup (50エントリ) | 939 | 5,000,000 |
| `==` 同一値 | 331 | 10,000,000 |
| `==` 異なる値 (早期リターン) | 95 | 10,000,000 |

#### ベースライン比較

| 操作 | 最適化後 | ベースライン (String.hash) | 備考 |
|------|------:|------:|------|
| `hash(into:)` | 961 ns | 833 ns | キャッシュ整数 combine |

`==` 異なる値は **95 ns** で完了。ハッシュ値の不一致だけで判定が終わる。

```bash
swift test --filter P2PBenchmarks/MessageIDBenchmarks
swift test --filter P2PBenchmarks/TopicBenchmarks
```
