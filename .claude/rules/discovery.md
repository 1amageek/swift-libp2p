---
paths:
  - "Sources/Discovery/**/*"
  - "Tests/Discovery/**/*"
---

# Discovery Layer Rules

**Before modifying any file in this directory, read:**
`Sources/Discovery/CONTEXT.md`

## 実装原則
- 観察ベースの発見モデル
- スコアリングによる候補ランク付け
- ゴシップベースの情報伝播

## Concurrency Model
- Discovery サービス（SWIM, CYCLON等）は外部ピアと通信するため **Actor** を使用
- 例: `actor SWIMMembership: MembershipService { ... }`
