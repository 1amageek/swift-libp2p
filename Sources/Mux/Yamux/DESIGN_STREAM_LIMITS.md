# Yamux Stream Limit Design

## 問題

### 1. ストリーム数無制限
攻撃者が大量のSYNフレームを送信することで、`streams` Dictionaryが無制限に成長し、メモリ枯渇を引き起こす可能性がある。

### 2. ストリームID再利用
既存のストリームIDで新しいSYNを受信した場合、既存のストリームを上書きしてしまう。

## 解決策

### 1. YamuxConfiguration の追加

```swift
public struct YamuxConfiguration: Sendable {
    /// Maximum number of concurrent streams per connection.
    /// Default: 1000
    public var maxConcurrentStreams: Int

    /// Initial window size for new streams.
    /// Default: 256KB
    public var initialWindowSize: UInt32
}
```

### 2. 上限チェックの追加

SYN フレーム受信時:
1. 現在のストリーム数をチェック
2. 上限に達していたら:
   - RST フレームを送信して新規ストリームを拒否
   - ログに警告を出力
3. 上限に達していなければ通常処理

### 3. ストリームID再利用の防止

SYN フレーム受信時:
1. 同じストリームIDがすでに存在するかチェック
2. 存在する場合:
   - RST フレームを送信
   - 新規ストリームを作成しない

## 実装詳細

### YamuxConfiguration

```swift
public struct YamuxConfiguration: Sendable {
    public var maxConcurrentStreams: Int
    public var initialWindowSize: UInt32

    public init(
        maxConcurrentStreams: Int = 1000,
        initialWindowSize: UInt32 = 256 * 1024
    ) {
        self.maxConcurrentStreams = maxConcurrentStreams
        self.initialWindowSize = initialWindowSize
    }

    public static let `default` = YamuxConfiguration()
}
```

### YamuxError の拡張

```swift
enum YamuxError: Error, Sendable {
    // ... existing cases ...
    case maxStreamsExceeded(current: Int, max: Int)
    case streamIDReused(UInt32)
}
```

### handleDataFrame の変更

```swift
if frame.flags.contains(.syn) {
    // 1. Check stream ID reuse
    let existingStream = state.withLock { $0.streams[streamID] }
    if existingStream != nil {
        // Protocol violation: stream ID reuse
        try? await sendFrame(YamuxFrame(type: .data, flags: .rst, streamID: frame.streamID, length: 0, data: nil))
        return
    }

    // 2. Check stream limit
    let currentCount = state.withLock { $0.streams.count }
    if currentCount >= configuration.maxConcurrentStreams {
        // Limit exceeded: reject with RST
        try? await sendFrame(YamuxFrame(type: .data, flags: .rst, streamID: frame.streamID, length: 0, data: nil))
        return
    }

    // ... rest of SYN handling ...
}
```

## テスト計画

1. **基本テスト**: 設定値が正しくデフォルト設定されることを確認
2. **上限テスト**: maxConcurrentStreams を超えるストリーム作成が拒否されることを確認
3. **ID再利用テスト**: 既存IDでのSYNがRSTで拒否されることを確認
4. **正常系テスト**: 上限内でのストリーム作成が正常に動作することを確認

## 互換性

- デフォルト値（1000ストリーム）は十分に大きく、通常の使用に影響しない
- 既存のAPIは維持され、設定を指定しない場合はデフォルト値が使用される
- Go/Rust libp2p との相互運用性に影響なし
