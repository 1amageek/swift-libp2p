# P2PKademlia

Kademlia DHT の実装。ピアルーティングとコンテンツ探索を提供する。

## プロトコル

`/ipfs/kad/1.0.0`

## KademliaKey

256ビットの鍵。XOR 距離メトリクスにより Kademlia の k-bucket ルーティングを行う。

### 最適化

32バイトの鍵を `Data` ではなく 4 つの `UInt64`（w0〜w3）としてスタック上に保持する。XOR distance、比較、leadingZeroBits の計算がすべてスタック完結でヒープアロケーション不要。

```swift
// 4xUInt64 XOR — ヒープアロケーションなし
let dist = keyA.distance(to: keyB)

// ハードウェア命令による高速計算
let zeros = dist.leadingZeroBits
```

### ベンチマーク

環境: Apple Silicon, macOS, Debug build

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| `init(bytes:)` 32B → 4xUInt64 | 250 | 1,000,000 |
| `init(hashing:)` SHA-256 + 変換 | 3,326 | 100,000 |
| `distance(to:)` 4xUInt64 XOR | 328 | 10,000,000 |
| `leadingZeroBits` | 179 | 10,000,000 |
| `<` 比較 (最大4整数) | 123 | 10,000,000 |
| `isCloser(to:than:)` 2x distance + 比較 | 168 | 5,000,000 |
| `hash(into:)` 4xUInt64 combine | 162 | 10,000,000 |
| Dictionary lookup (100エントリ) | 8,700 | 1,000,000 |

#### ベースライン比較

| 操作 | 最適化後 | ベースライン (Data) | 高速化 |
|------|------:|------:|------:|
| XOR distance | 328 ns | 3,011 ns | **9.2x** |
| leadingZeroBits | 179 ns | 245 ns | **1.4x** |

```bash
swift test --filter P2PBenchmarks/KademliaKeyBenchmarks
```
