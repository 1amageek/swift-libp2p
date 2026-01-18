---
paths:
  - "Sources/Mux/**/*"
  - "Tests/Mux/**/*"
---

# Mux Layer Rules

**Before modifying any file in this directory, read the CONTEXT.md files:**

1. `Sources/Mux/CONTEXT.md` - Mux層の概要
2. 該当するサブディレクトリの`CONTEXT.md`:
   - Yamux: `Sources/Mux/Yamux/CONTEXT.md`

## 実装原則
- P2PMuxはprotocol定義のみ
- SecuredConnection → MuxedConnection への変換
- ストリームID: Initiator=奇数, Responder=偶数
