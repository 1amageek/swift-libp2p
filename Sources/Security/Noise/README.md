# P2PSecurityNoise

Noise Protocol Framework XX パターンの実装。X25519 鍵交換と ChaChaPoly-1305 暗号化を提供する。

## プロトコル

`/noise`

## NoiseCipherState / NoiseSymmetricState

Noise プロトコルの暗号化状態管理。ハンドシェイクおよびトランスポート暗号化の基盤。

### 最適化

- **スタックノンス**: 12バイトのノンスを固定サイズタプルでスタック上に構築し、ヒープアロケーションを回避
- **事前アロケーション**: ciphertext + tag の出力バッファを `Data(capacity:)` で一括確保
- **PRK 再利用**: HKDF の PRK を `SymmetricKey` に変換して HMAC イテレーション間で再利用

### ベンチマーク

環境: Apple Silicon, macOS, Debug build

#### CipherState (ChaChaPoly-1305)

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| encrypt 32B | 9,335 | 500,000 |
| encrypt 256B | 12,632 | 500,000 |
| decrypt 256B | 13,432 | 500,000 |
| roundtrip 1KB (encrypt + decrypt) | 25,484 | 100,000 |
| 100回連続 encrypt (64B) | 1,236,300 | 10,000 |

100回連続 encrypt は 12,363 ns/回で、単発 encrypt と同等。ノンスインクリメントによるオーバーヘッドなし。

#### SymmetricState (ハンドシェイク)

| 操作 | ns/op | イテレーション |
|------|------:|----------:|
| mixHash (SHA-256) | 4,808 | 500,000 |
| mixKey (HKDF-SHA256) | 27,788 | 100,000 |
| split (2x CipherState 導出) | 24,004 | 100,000 |

### 実用上の指標

- Noise メッセージ（256B）の encrypt/decrypt は約 **13 us**
- ハンドシェイク中の mixKey/split は約 **25 us** だが、接続確立時に数回のみ呼ばれるため許容範囲
- 1KB roundtrip (encrypt + decrypt) は約 **25 us** — 十分な throughput

```bash
swift test --filter P2PBenchmarks/NoiseCryptoBenchmarks
```
