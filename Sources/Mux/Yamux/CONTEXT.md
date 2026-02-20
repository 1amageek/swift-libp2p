# P2PMuxYamux

## 概要
Yamux (Yet another Multiplexer) の実装。

## 責務
- ストリーム多重化
- フロー制御（ウィンドウ管理）
- Ping/Pong (keep-alive)
- GoAway (graceful shutdown)

## 依存関係
- `P2PMux` (Muxer protocol)

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `YamuxMuxer` | ✅ Done | Muxer実装 |
| `YamuxConnection` | ✅ Done | MuxedConnection実装 |
| `YamuxStream` | ✅ Done | MuxedStream実装 |
| `YamuxFrame` | ✅ Done | フレームエンコード/デコード |
| `YamuxFlags` | ✅ Done | SYN/ACK/FIN/RST フラグ |
| `YamuxError` | ✅ Done | エラー型 |

## Wire Protocol

### プロトコルID
`/yamux/1.0.0`

### フレームフォーマット (12バイトヘッダ)
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version (8) |     Type (8)  |          Flags (16)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Length (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### バージョン
- 常に `0`

### タイプ
| 値 | 名前 | 説明 |
|----|------|------|
| 0 | Data | データフレーム |
| 1 | WindowUpdate | ウィンドウ更新 |
| 2 | Ping | Ping/Pong |
| 3 | GoAway | 接続終了 |

### フラグ
| 値 | 名前 | 説明 |
|----|------|------|
| 0x0001 | SYN | ストリーム開始 |
| 0x0002 | ACK | ストリーム確認 |
| 0x0004 | FIN | 送信終了 |
| 0x0008 | RST | ストリームリセット |

### ウィンドウサイズ
- デフォルト: 256KB
- WindowUpdateで増加

## 実装ノート

### ストリームID
- Initiator: 奇数 (1, 3, 5, ...)
- Responder: 偶数 (2, 4, 6, ...)
- ID 0 は制御用（Ping, GoAway）

### フロー制御
```swift
// 受信ウィンドウが半分以下になったら更新
if recvWindow < initialWindow / 2 {
    sendWindowUpdate(delta: initialWindow - recvWindow)
}
```

### 送信ウィンドウ予約（TOCTOU-safe）
`YamuxStream.write()` はウィンドウ確認と予約をアトミックに行う:
```swift
private enum WindowReserveResult {
    case reserved(Data)  // ウィンドウ予約成功
    case noWindow        // ウィンドウ不足（待機）
    case closed          // ストリーム閉鎖
}

// Mutex内でアトミックに状態確認とウィンドウ減算
let result: WindowReserveResult = state.withLock { ... }
```

### GoAway理由コード
| 値 | 意味 |
|----|------|
| 0 | 正常終了 |
| 1 | プロトコルエラー |
| 2 | 内部エラー |

## 実装ノート - YamuxConnection

### 初期化とstart()メソッド

YamuxConnectionは`start()`メソッドを呼び出してから使用する必要がある。
このメソッドは読み取りループを開始し、フレーム処理を開始する。

```swift
let yamuxConnection = YamuxConnection(...)
yamuxConnection.start()  // 必須
```

`start()`はべき等（複数回呼び出しても安全）。

### ストリームID検証

リモートから受け取ったストリームIDについて、以下のルールを強制:
- Stream ID 0は無効
- Initiator視点でリモートから受け取るストリームは偶数
- Responder視点でリモートから受け取るストリームは奇数

このルール違反時はRSTフレームで応答。

### ウィンドウタイムアウト

送信側が送信ウィンドウ0で待機している場合、最大30秒のタイムアウトでエラー発生（`YamuxError.protocolError`）。

### YamuxStream の protocolID

MuxedStream.protocolIDはmultistream-selectで合意したプロトコルを格納:

```swift
let stream = try await connection.newStream()
stream.protocolID = "/ipfs/id/1.0.0"  // プロトコル合意後に設定
```

## 注意点
- バイトオーダー: Big-Endian
- Keep-alive: 定期的なPingで接続維持
- バックプレッシャー: ウィンドウが0になったら待機

## 参照
- [Yamux Spec](https://github.com/hashicorp/yamux/blob/master/spec.md)

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Unbounded frame length DoS | `YamuxFrame.swift:117-156` | ✅ Fixed | Added `yamuxMaxFrameSize` (16MB) cap. Frames exceeding limit throw `frameTooLarge` error |
| Concurrent read continuation loss | `YamuxStream.swift:10-12,39-59` | ✅ Fixed | Changed to array of continuations with FIFO queue |
| Concurrent window wait loss | `YamuxStream.swift:119-151,339-350` | ✅ Fixed | Changed to array of continuations; all resumed on window update |
| Stream ID reuse not handled | `YamuxConnection.swift:249-283` | ✅ Fixed | SYN for existing stream ID now rejected with RST frame |
| Stream count unlimited | `YamuxConnection.swift` | ✅ Fixed | Added `maxConcurrentStreams` config (default: 1000). Excess streams rejected with RST |
| newStream() leaks on failure | `YamuxConnection.swift:109-125` | ✅ Fixed | Added do-catch to remove stream from map if SYN send fails |
| Unbounded inbound buffering | `YamuxConnection.swift:61-66,345-422` | ✅ Fixed | Bounded AsyncStream with backpressure; RST sent when buffer full |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| sendWindow overflow risk | `YamuxStream.swift:339-343` | ✅ Fixed | Added overflow protection with UInt64 arithmetic and max cap |
| O(n) readBuffer.dropFirst | `YamuxConnection.swift:17-40` | ✅ Fixed | Index-based tracking with periodic compaction |
| O(n²) write copies | `YamuxStream.swift:86-119` | ✅ Fixed | Index-based tracking instead of repeated `Data(prefix)` + `dropFirst` |
| Missing unit tests | - | ✅ Fixed | Added YamuxStreamTests (16 tests) and YamuxConnectionTests (20 tests) |

## Fixes Applied

### Stream Limit and ID Reuse (2026-01-18)

**設計ドキュメント**: `DESIGN_STREAM_LIMITS.md`

**問題**:
1. ストリーム数無制限 - 攻撃者が大量のSYNフレームを送信してメモリを枯渇させる
2. ストリームID再利用 - 既存IDで新しいSYNを受信すると上書き

**解決策**:
1. `YamuxConfiguration.maxConcurrentStreams` を追加（デフォルト: 1000）
2. SYN受信時にアトミックにストリーム数とID再利用をチェック
3. 違反時はRSTフレームで拒否

**テスト追加**:
- YamuxConfigurationTests: デフォルト値、カスタム値
- YamuxErrorTests: maxStreamsExceeded、streamIDReused エラー型

### Concurrent Continuation Support (2026-01-18)

**問題**:
1. `readContinuation` が単一 - 複数の同時readが上書きでハング
2. `windowWaitContinuation` が単一 - 複数の同時writeがウィンドウ待機時に上書き

**解決策**:
1. `readContinuations: [CheckedContinuation<Data, Error>]` に変更
2. `windowWaitContinuations: [CheckedContinuation<Void, Error>]` に変更
3. データ受信時はFIFO（先に待機した方から順に解決）
4. ウィンドウ更新時は全ての待機者を一斉に起床

**修正ファイル**:
- `YamuxStream.swift` - 状態構造体と全メソッドを更新

### newStream Leak Prevention (2026-01-18)

**問題**:
`newStream()` でストリームをマップに追加後、SYN送信が失敗するとストリームがマップに残ったままリーク

**解決策**:
do-catchでSYN送信をラップし、失敗時にストリームをマップから削除

**修正ファイル**:
- `YamuxConnection.swift` - newStream()にエラーハンドリング追加

### sendWindow Overflow Protection (2026-01-18)

**問題**:
`windowUpdate(delta)` で `sendWindow += delta` を実行する際、悪意のある巨大deltaでオーバーフローの可能性

**解決策**:
1. `yamuxMaxWindowSize` 定数を追加（16MB）
2. UInt64で加算してからキャップを適用

```swift
let newWindow = UInt64(state.sendWindow) + UInt64(delta)
state.sendWindow = UInt32(min(newWindow, UInt64(yamuxMaxWindowSize)))
```

**修正ファイル**:
- `YamuxFrame.swift` - `yamuxMaxWindowSize` 定数追加
- `YamuxStream.swift` - `windowUpdate()` にオーバーフロー保護追加

### Inbound Stream Backpressure (2026-01-18)

**問題**:
1. `inboundStreams` の AsyncStream が無制限バッファ
2. ACK送信後に配信するため、バッファ満杯でも拒否できない
3. アプリが消費しない場合、メモリが蓄積（DoSリスク）

**解決策**:
1. `maxPendingInboundStreams` 設定を追加（デフォルト: 100）
2. AsyncStream を `.bufferingOldest(N)` で制限付き作成
3. 配信フローを修正: yield結果を確認してからACK/RST送信
4. バッファ満杯時はRSTで拒否（サイレントドロップなし）

**フロー変更**:
```
Before: ストリーム作成 → ACK送信 → 配信試行
After:  ストリーム作成 → 配信試行 → 成功ならACK / 失敗ならRST
```

**修正ファイル**:
- `YamuxFrame.swift` - `maxPendingInboundStreams` 設定追加
- `YamuxConnection.swift` - AsyncStream作成とhandleDataFrame配信フロー修正

### Unit Tests Addition (2026-01-18)

**追加ファイル**:
- `Tests/Mux/YamuxTests/Mocks/MockSecuredConnection.swift` - テスト用モック
- `Tests/Mux/YamuxTests/YamuxStreamTests.swift` - 16テスト
- `Tests/Mux/YamuxTests/YamuxConnectionTests.swift` - 20テスト

**YamuxStreamTests (16 tests)**:
| テスト | 検証内容 |
|-------|---------|
| readReturnsBufferedData | バッファからの即時読み取り |
| readWaitsForData | 空バッファ時の待機 |
| concurrentReadsQueuedFIFO | 同時read のFIFO順序 |
| readThrowsWhenReset | リセット時の例外 |
| readThrowsWhenRemoteClosed | リモートクローズ時の例外 |
| writeWithAvailableWindow | ウィンドウあり時の書き込み |
| writeThrowsWhenClosed | クローズ時の例外 |
| windowUpdateResumesWaiters | ウィンドウ更新で待機解除 |
| windowOverflowProtection | オーバーフロー保護 |
| dataExceedingWindowRejected | ウィンドウ超過拒否 |
| dataWithinWindowAccepted | ウィンドウ内データ受理 |
| closeWriteSendsFIN | FINフレーム送信 |
| remoteCloseResumesReaders | リモートクローズで待機解除 |
| resetCleansUpAllWaiters | リセットで全待機者解放 |
| protocolIDSetAndGet | プロトコルIDの設定/取得 |
| streamIDPreserved | ストリームIDの保持 |

**YamuxConnectionTests (20 tests)**:
| テスト | 検証内容 |
|-------|---------|
| connectionInitializesWithPeerIDs | ピアIDの初期化 |
| connectionUsesRemoteAddress | リモートアドレスの使用 |
| startIsIdempotent | start()のべき等性 |
| initiatorAssignsOddStreamIDs | イニシエータの奇数ID |
| responderAssignsEvenStreamIDs | レスポンダの偶数ID |
| streamIDsIncrementBy2 | IDの2ずつ増加 |
| newStreamSendsSYN | SYNフレーム送信 |
| newStreamThrowsWhenClosed | クローズ時の例外 |
| newStreamCleansUpOnFailure | 失敗時のクリーンアップ |
| inboundSYNCreatesStream | インバウンドSYNでストリーム作成 |
| invalidStreamIDParityRejected | 不正パリティの拒否 |
| streamIDZeroForDataRejected | ID=0の拒否 |
| maxStreamsLimitEnforced | 最大ストリーム数制限 |
| goAwayClosesConnection | GoAwayで接続終了 |
| pingReceivesPong | Ping/Pong |
| closeSendsGoAway | GoAway送信 |
| closeNotifiesAllStreams | 全ストリームへの通知 |
| finFrameClosesRemoteSide | FINでリモート側クローズ |
| rstFrameTerminatesStream | RSTでストリーム終了 |
| windowUpdateForwardedToStream | ウィンドウ更新転送 |

### initialWindowSize Configuration Fix (2026-01-18)

**問題**:
`YamuxConfiguration.initialWindowSize`が存在するにもかかわらず、`YamuxStream`は`yamuxDefaultWindowSize`をハードコードしていた。設定の流れが途切れていた。

**修正内容**:
1. `YamuxStreamState`に`initialWindowSize`プロパティと`init(initialWindowSize:)`を追加
2. `YamuxStream.init`に`initialWindowSize`引数を追加（デフォルト値で後方互換）
3. `YamuxStream.dataReceived()`内のウィンドウ計算を`state.initialWindowSize`に変更
4. `YamuxConnection.newStream()`と`handleDataFrame()`で`configuration.initialWindowSize`を渡す

**設計原則**:
- 設定値は`YamuxStreamState`内に**のみ**格納
- 全てのウィンドウ計算はロック内で`state.initialWindowSize`を参照
- デフォルト値`yamuxDefaultWindowSize`で既存コード・テストは動作継続

**修正ファイル**:
- `YamuxStream.swift` - YamuxStreamState, init, dataReceived
- `YamuxConnection.swift` - newStream, handleDataFrame

**テスト改善**:
- `windowUpdateResumesWaiters`を小さいウィンドウ（100バイト）でテスト
- 実際にウィンドウ枯渇→ブロック→更新→完了の流れを検証

### Performance Optimization: Read Buffer (2026-01-18)

**問題**:
`readLoop`内で毎フレーム処理後に`readBuffer = Data(readBuffer.dropFirst(bytesRead))`を呼び出し、O(n)のコピーが発生

**解決策**:
1. `readBufferOffset`インデックスを追加して未処理開始位置を追跡
2. `unprocessedBuffer`プロパティでスライス（O(1)）を返す
3. `advanceReadBuffer(by:)`で64KB超過時のみコンパクション

```swift
private struct YamuxConnectionState: Sendable {
    var readBuffer = Data()
    var readBufferOffset = 0

    var unprocessedBuffer: Data {
        readBuffer[readBufferOffset...]  // O(1) slice
    }

    mutating func advanceReadBuffer(by bytesRead: Int) {
        readBufferOffset += bytesRead
        if readBufferOffset > readBufferCompactThreshold {
            readBuffer = Data(readBuffer[readBufferOffset...])
            readBufferOffset = 0
        }
    }
}
```

**効果**:
- 通常フレーム処理: O(n) → O(1)
- 64KB超過時のみO(n)コピー（定数回）

### Performance Optimization: Write Buffer (2026-01-18)

**問題**:
`write()`内でループ毎に:
1. `Data(remaining.prefix(chunkSize))` - O(n)コピー
2. `remaining = remaining.dropFirst(chunk.count)` - Data再作成

大きいペイロードでO(n²)

**解決策**:
1. `var remaining = data` を `var offset = 0` に変更
2. `WindowReserveResult.reserved(Data)` を `.reserved(Int)` に変更
3. 送信時のみ `Data(data[offset..<(offset + chunkSize)])` でスライス

```swift
public func write(_ data: Data) async throws {
    var offset = 0
    let dataCount = data.count

    while offset < dataCount {
        let reserveResult = state.withLock { state in
            let remainingBytes = dataCount - offset
            let chunkSize = min(Int(state.sendWindow), remainingBytes)
            state.sendWindow -= UInt32(chunkSize)
            return .reserved(chunkSize)  // Int only
        }

        switch reserveResult {
        case .reserved(let chunkSize):
            let chunk = Data(data[offset..<(offset + chunkSize)])
            offset += chunkSize
            // send frame...
        }
    }
}
```

**効果**:
- O(n²) → O(n)（送信時の1回コピーのみ）

### Keep-Alive (Ping Timer) Implementation (2026-01-18)

**目的**:
- アイドル接続の維持（NAT binding refresh）
- 死んだ接続の早期検出

**設計**:
go-libp2p / HashiCorp Yamux 互換のデフォルト値:
- `enableKeepAlive`: true
- `keepAliveInterval`: 30秒
- `keepAliveTimeout`: 60秒

**アーキテクチャ**:
```
start()
  │
  ├─► readLoop (既存)
  │
  └─► keepAliveLoop (新規)
        │
        ├─► 定期的に Ping 送信 (interval ごと)
        │
        ├─► handlePing で Pong 受信時に pendingPings から削除
        │
        └─► タイムアウト検出 → 接続クローズ
```

**状態追加**:
```swift
private struct YamuxConnectionState: Sendable {
    // ... existing fields
    var pendingPings: [UInt32: ContinuousClock.Instant] = [:]
    var nextPingID: UInt32 = 1
}
```

**新規メソッド**:
- `keepAliveLoop()`: interval ごとに Ping 送信、タイムアウト検出
- `checkPingTimeout(timeout:)`: pendingPings のタイムアウトチェック
- `sendKeepAlivePing()`: Ping ID 生成・追跡・送信
- `handleKeepAliveTimeout()`: 全ストリームに通知、接続クローズ

**handlePing 拡張**:
```swift
private func handlePing(_ frame: YamuxFrame) async throws {
    if frame.flags.contains(.ack) {
        // Pong 受信 - pendingPings から削除
        state.withLock { state in
            _ = state.pendingPings.removeValue(forKey: frame.length)
        }
        return
    }
    // Ping 受信 → Pong 応答（既存）
    let pong = YamuxFrame.ping(opaque: frame.length, ack: true)
    try await sendFrame(pong)
}
```

**設定検証**:
```swift
public init(...) {
    precondition(keepAliveTimeout >= keepAliveInterval,
        "keepAliveTimeout must be >= keepAliveInterval")
    // ...
}
```

**テスト用設定**:
既存テストは `enableKeepAlive: false` を使用して Ping フレームの干渉を防止:
```swift
static let testConfiguration = YamuxConfiguration(enableKeepAlive: false)
```

**追加テスト (6 tests)**:
| テスト | 検証内容 |
|-------|---------|
| keepAliveDisabledNoTask | enableKeepAlive=false で Task 未起動 |
| keepAliveSendsPing | interval 後に Ping フレーム送信 |
| pongResponseClearsPending | Pong 受信で pendingPings から削除 |
| keepAliveTimeoutClosesConnection | タイムアウトで接続クローズ |
| keepAliveTimeoutNotifiesAllStreams | タイムアウト時に全ストリームに通知 |
| multipleInFlightPings | 複数 Ping が in-flight でも正常動作 |

**修正ファイル**:
- `YamuxFrame.swift`: YamuxError に keepAliveTimeout 追加、YamuxConfiguration に keep-alive 設定追加
- `YamuxConnection.swift`: keepAliveTask, keepAliveLoop, handlePing 拡張, close() 拡張
- `YamuxConnectionTests.swift`: testConfiguration, 6つの Keep-Alive テスト
- `YamuxStreamTests.swift`: testConfiguration

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PMuxYamux`
- 実装読解範囲: 4 Swift files / 1499 LOC
- テスト範囲: 46 files / 424 cases / targets 5
- 公開API: types 4 / funcs 9
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
