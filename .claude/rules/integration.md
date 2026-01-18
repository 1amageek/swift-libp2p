---
paths:
  - "Sources/Integration/**/*"
  - "Tests/Integration/**/*"
---

# Integration Layer Rules

**Before modifying any file in this directory, read:**
`Sources/Integration/P2P/CONTEXT.md`

## 実装原則
- Protocol依存のみ（実装依存なし）
- **Node は Actor**: 最外層のユーザー向けAPI、外部ピアとの通信を管理
- Transport/Security/Muxerはユーザーが注入

## Concurrency Model
- `Node`, `Swarm`, `Behaviour` 等の外部通信管理 → Actor
- 内部のConnectionPool、NIO統合層 → class + mutex
