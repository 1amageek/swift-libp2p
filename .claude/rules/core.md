---
paths:
  - "Sources/Core/**/*"
  - "Tests/Core/**/*"
---

# Core Layer Rules

**Before modifying any file in this directory, read:**
`Sources/Core/P2PCore/CONTEXT.md`

## 実装原則
- 最小限の共通抽象のみ
- Transport/Security/Muxの具体的実装は含まない
- Wire Protocol互換性を維持
