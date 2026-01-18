---
paths:
  - "Sources/Security/**/*"
  - "Tests/Security/**/*"
---

# Security Layer Rules

**Before modifying any file in this directory, read the CONTEXT.md files:**

1. `Sources/Security/CONTEXT.md` - Security層の概要
2. 該当するサブディレクトリの`CONTEXT.md`:
   - Noise: `Sources/Security/Noise/CONTEXT.md`
   - Plaintext: `Sources/Security/Plaintext/CONTEXT.md`

## 実装原則
- P2PSecurityはprotocol定義のみ
- RawConnection → SecuredConnection への変換
- PeerID検証を含む相互認証
