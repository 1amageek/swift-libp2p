# P2PCore

libp2p スタック全体で使用される基盤モジュール。

## 主要コンポーネント

- **PeerID** - ピアの一意識別子（公開鍵由来）
- **Multiaddr** - 自己記述型ネットワークアドレス
- **Varint** - 可変長整数エンコーディング
- **RawConnection / SecuredConnection** - 接続プロトコル定義

## Varint

[unsigned-varint](https://github.com/multiformats/unsigned-varint) 仕様に準拠した可変長整数の encode/decode。

### 最適化

スタック上の固定サイズタプルバッファ（最大10バイト）を使用し、ヒープアロケーションを回避する。

```swift
// ゼロアロケーション版（ホットパス向け）
let count = Varint.encode(value, into: buffer)

// Data 返却版（汎用）
let data = Varint.encode(value)
```

### ベンチマーク

環境: Apple Silicon, macOS, Debug build

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| `encode(0)` 1バイト出力 | 3,794 | 10,000,000 |
| `encode(300)` 2バイト出力 | 3,804 | 10,000,000 |
| `encode(UInt64.max)` 10バイト出力 | 3,895 | 10,000,000 |
| `encode(into:)` ゼロアロケーション | 876 | 10,000,000 |
| `decode` 1バイト値 | 918 | 10,000,000 |
| `decode(from:at:)` UnsafeRawBufferPointer | 928 | 10,000,000 |
| round-trip 10値 | 33,356 | 1,000,000 |

#### ベースライン比較

| 操作 | 最適化後 | ベースライン ([UInt8] append) | 高速化 |
|------|------:|------:|------:|
| encode | 876 ns | 3,424 ns | **3.9x** |

`encode()` の Data 返却版はスタック→Data コピーを含むため約 3,800 ns。ホットパスでは `encode(into:)` を使うことで 876 ns に短縮できる。

```bash
swift test --filter P2PBenchmarks/VarintBenchmarks
```
