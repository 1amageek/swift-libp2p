---
paths:
  - "Sources/Transport/**/*"
  - "Tests/Transport/**/*"
---

# Transport Layer Rules

**Before modifying any file in this directory, read the CONTEXT.md files:**

1. `Sources/Transport/CONTEXT.md` - Transport層の概要
2. 該当するサブディレクトリの`CONTEXT.md`:
   - TCP: `Sources/Transport/TCP/CONTEXT.md`
   - Memory: `Sources/Transport/Memory/CONTEXT.md`

## 実装原則
- P2PTransportはprotocol定義のみ（NIO依存なし）
- 実装ターゲットはP2PTransportに依存
- RawConnectionを返す

## Concurrency Model
- **async/await を全面採用**（EventLoopFuture は使わない）
- NIOAsyncChannel 等の async/await 対応APIを使用
- Channel状態管理が必要な場合のみ class + mutex
