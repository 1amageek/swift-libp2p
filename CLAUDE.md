# swift-libp2p AI Guidelines

> AI向けの開発ガイドライン。人間向けドキュメントは README.md と CONTRIBUTING.md を参照。

## ディレクトリ読み取りルール

**重要**: ディレクトリ配下のコードを読む際は、必ず先にそのディレクトリの`CONTEXT.md`を読むこと。

例:
- `Sources/Transport/` を読む前に → `Sources/Transport/CONTEXT.md`
- `Sources/Security/Noise/` を読む前に → `Sources/Security/Noise/CONTEXT.md`

---

## 核心ルール

### 1. Actor vs Class + Mutex

| 基準 | Actor | Class + Mutex |
|-----|-------|---------------|
| 操作頻度 | 低頻度 | 高頻度 |
| 処理時間 | 重い（I/O等） | 軽い |
| 用途 | ユーザー向けAPI | 内部実装 |

**迷ったら** → Class + Mutex（後からActorに変更は難しい）

### 2. EventEmitting パターン

`AsyncStream<Event>` を公開するサービスは `EventEmitting` プロトコルに準拠すること。

#### プロトコル準拠

```swift
public final class MyService: EventEmitting, Sendable {
    // ...
}
```

#### パターンA（必須）

イベント状態と業務状態を分離する:

```swift
// イベント状態（専用）
private let eventState: Mutex<EventState>

private struct EventState: Sendable {
    var stream: AsyncStream<MyEvent>?
    var continuation: AsyncStream<MyEvent>.Continuation?
}

// 業務状態（分離）
private let serviceState: Mutex<ServiceState>

private struct ServiceState: Sendable {
    // 業務ロジック用の状態
}
```

#### 必須メソッド

```swift
// events プロパティ
public var events: AsyncStream<MyEvent> {
    eventState.withLock { state in
        if let existing = state.stream { return existing }
        let (stream, continuation) = AsyncStream<MyEvent>.makeStream()
        state.stream = stream
        state.continuation = continuation
        return stream
    }
}

// emit メソッド（private）
private func emit(_ event: MyEvent) {
    eventState.withLock { state in
        state.continuation?.yield(event)
    }
}

// shutdown メソッド（EventEmitting 準拠）
public func shutdown() {
    eventState.withLock { state in
        state.continuation?.finish()  // 必須！
        state.continuation = nil
        state.stream = nil            // 必須！
    }
}
```

#### なぜこのパターンか

1. **スレッドセーフティ**: イベントと業務ロジックの独立ロックで競合回避
2. **SOLID原則**: 単一責任に準拠
3. **リソースリーク防止**: `shutdown()` で確実に AsyncStream を終了
4. **テスト容易性**: 状態分離でモック化が容易

**注意**: `continuation.finish()` と `stream = nil` の両方が必須。どちらかが欠けると `for await` がハングする。

### 3. エラーハンドリング

```swift
// BAD: エラーを握りつぶす
let addr = try? channel.localAddress?.toMultiaddr()

// GOOD: エラーを伝播
let addr = try channel.localAddress?.toMultiaddr()
```

### 4. Sendable

`@unchecked Sendable` は使わない。`Mutex<T>` で解決する。

---

## テスト実行

**必須**: タイムアウトを設定する

```bash
swift test --filter TargetName 2>&1 &
PID=$!; sleep 30; kill $PID 2>/dev/null || wait $PID
```

**ハング時**: AsyncStream、Task、continuation の未完了を疑う。
