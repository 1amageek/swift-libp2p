# P2PMuxYamux

Yamux (Yet another Multiplexer) の実装。単一の接続上で複数のストリームを多重化する。

## プロトコル

`/yamux/1.0.0`

## YamuxFrame

12バイト固定ヘッダ + 可変長ペイロードのフレーム。`ByteBuffer` を使用したゼロコピーの encode/decode を提供する。

### フレームフォーマット

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version (8) |     Type (8)  |          Flags (16)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Length (32)                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 最適化

- `encode()`: `reserveCapacity` によるヘッダ+ペイロードの一括アロケーション
- `decode()`: `readSlice` によるゼロコピーペイロード読み取り。ペイロードサイズに依存しない一定時間
- 部分読み取り時のリーダインデックス復元

### ベンチマーク

環境: Apple Silicon, macOS, Debug build

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| encode ヘッダのみ (windowUpdate) | 9,767 | 5,000,000 |
| encode 1KB | 16,083 | 1,000,000 |
| encode 64KB | 18,391 | 500,000 |
| encode windowUpdate | 9,991 | 5,000,000 |
| encode ping | 8,460 | 5,000,000 |
| decode ヘッダのみ | 8,362 | 5,000,000 |
| decode 1KB | 18,622 | 1,000,000 |
| decode 64KB | 17,235 | 500,000 |
| roundtrip 1KB | 33,085 | 1,000,000 |
| decode 10フレーム連続 | 84,867 | 500,000 |

### 分析

- ヘッダ encode/decode は約 8-10 us で安定
- ペイロード 1KB → 64KB でも encode は 16 → 18 us と微増（`writeBuffer` が効率的）
- decode 64KB (17 us) が decode 1KB (19 us) より速い — `readSlice` のゼロコピーによりペイロードサイズに依存しない
- 10フレーム連続 decode: 84,867 ns (= 約 8,487 ns/フレーム) — 単一 decode と同等

```bash
swift test --filter P2PBenchmarks/YamuxFrameBenchmarks
```
