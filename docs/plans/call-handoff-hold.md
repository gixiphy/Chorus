# 計畫：來電接手時暫停 Podcast，原耳機回來再自動播放（call-handoff hold）

- 基線 commit：`82c8f1aad608bd001f308c2d31758c98f4a408be`（main，1.16.1 build 142）
- 回滾點：同一個 commit。實作全部 `git revert` 或 `git reset` 回這個 commit，就回到今天的行為
- 決策：主 checkout 的 `docs/decisions.md`「D-2026-10-27 — 來電接手時 Podcast 不要進 Screen Output」，**以 16:24 修訂版為準**（暫停／恢復播放）。16:16 的「只靠 tap 靜音」方案已被否決。worktree 裡的 `docs/decisions.md` 是舊副本，沒有這一條
- 診斷：`~/Downloads/Chorus-diagnostics-3138DD9E-A70F-43A8-868D-07A97102AAF4/chorus.log`
- 風險等級：L2（改一條會出聲的音訊路由，並新增對其他 App 的播放控制）
- 撰寫：Claude，2026-10-27。只有計畫，沒有改產品程式或測試
- 實作者權限：本機 commit。不 push、不開 PR、不合併、不跑 `scripts/release.sh`

---

## 0. 事實（已對過 log、程式與本機系統）

### 0.1 log（台北時間，build 142，2026-10-27）

```
14:40:04.880 per-app session 的裝置重新配置：com.apple.podcasts → 收掉、1s 後重建
14:40:04.881 per-app session 收掉：com.apple.podcasts（原本 → 94-16-25-48-CC-A9:output）
14:40:05.854 per-app session 建立：com.apple.podcasts → 94-16-25-48-CC-A9:output
14:40:05.856 AU 鏈建立：…（2/2 格，24000 Hz）              ← 整份 log 唯一一次不是 48000
14:40:07.985 per-app session 的裝置重新配置 → 收掉
14:40:08.717 per-app session 建立：→ 94-16-25-48-CC-A9:output
14:40:08.718 AU 鏈建立：…（48000 Hz）                       ← 先回到 48000
14:40:19.648 per-app session 收掉：（原本 → 94-16-25-48-CC-A9:output）
14:40:19.764 per-app session 建立：→ ChorusAudioDevice_UID  ← 問題本身
14:40:19.766 音訊裝置清單變更：移除 ["94-16-25-48-CC-A9:output"]
14:40:19.766 預設輸出：94-16-… → Chorus Screen Output<ChorusAudioDevice_UID>
14:45:42.947 per-app session 建立：→ F8-D3-F0-59-73-BD:output（憲有的AirPods4，另一個 UID）
```

- 「AU 鏈建立」共 92 行：91 行 48000 Hz，1 行 24000 Hz（`grep -o "格，[0-9]* Hz" | sort | uniq -c`）。
- 13:58:05 同一個 UID 消失時沒有 24000 Hz。session 退回 `ChorusAudioDevice_UID`，14:00:23 原機回來又接回，系統預設也同時切回它。這條一般拔除要維持現況。
- **順序**：14:40:19.648 session 先被收掉重建，AudioDeviceManager 的「裝置清單變更」在 118 ms 之後才記。觸發 TapEngine 的是 backend 的預設輸出 listener（`defaultOutputChanged`），不是 `audioDevicesChanged`。對帳當下 `94-16…` 是否還在 `outputDeviceUIDs()` 裡，log 判斷不出來（**未確認**）。計畫要同時處理兩種順序：先消失再換預設，以及先換預設、裝置還列著（§2.4 的延後跟隨）。
- 從 log 看不出 Podcast 的設定是「跟隨預設」還是「指定 94-16…」，因為 `App 設定` 是 info 等級，沒有進診斷。計畫兩種都處理。

### 0.2 本機系統（2026-10-27，macOS 27.0.1）

- `/System/Applications/Podcasts.app`：**沒有** `.sdef`，Info.plist 也**沒有** `NSAppleScriptEnabled` 或 `OSAScriptingDefinition`。Podcasts 不能用 Apple Events／AppleScript 控制（已驗證）。
- `/System/Applications/Music.app` 可以用 AppleScript 控制（`com.apple.Music.sdef`）。本計畫不針對 Music 另做路徑，見 §8。
- Chorus 沒有 MediaRemote 或 Now Playing 客戶端。`Chorus/MediaKeys/MediaKeyInterceptor.swift` 已經用輔助使用權限攔截媒體鍵，但只接手音量鍵與亮度鍵，`NX_KEYTYPE_PLAY`（16）走 `default: return false` 放行。
- `Chorus/Support/Chorus.entitlements`：未沙箱，沒有 `com.apple.security.automation.apple-events`。

### 0.3 程式現況（基線 commit）

| 位置 | 現況 |
|---|---|
| `Chorus/Audio/Taps/TapEngine.swift:506-608` `reconcileSessions` | 指定的裝置不在時，改用 `backend.defaultOutputDeviceUID()`，設定不動，設 notice。跟隨預設時用預設輸出。實際 UID 和目標不同，就 `stopSession` 再建 |
| `TapEngine.swift:574-579` | `onDeviceReconfigured` 立刻 `stopSession`，再 `scheduleRebuild(after: rebuildDelay)`（正式值 1.5 s）。回呼不帶取樣率 |
| `TapEngine.swift:615-622` `stopSession` | 會一併清掉 `sessionOutputUIDs`。所以從重新配置到重建之間，引擎不知道這個 App 原本建在哪 |
| `TapEngine.swift:405-407` | 全域 tap 的排除清單是 `sessions.keys ∪ excludedApps` |
| `TapEngine.swift:709-724` `defaultOutputChanged` | active 時直接 `reconcileSessions()` |
| `Chorus/Audio/Taps/TapBackend.swift:44` | `var onDeviceReconfigured: (@MainActor () -> Void)?` |
| `Chorus/Audio/Taps/CoreAudioTapBackend.swift:162-180` | 正式 per-app 用 `muteBehavior = .mutedWhenTapped`。收掉 tap 之後來源解除靜音，聲音走系統預設 |
| `CoreAudioTapBackend.swift:605-615` | rate listener 掛在 aggregate 的 `kAudioDevicePropertyNominalSampleRate`，只清快取、呼叫回呼 |
| `CoreAudioTapBackend.swift:763-772` `deviceSampleRate()` | 懶讀 aggregate 的名義取樣率，讀不到就退回 `EQSettings.referenceSampleRate`。log 裡的「24000 Hz」就是這個值（`AUEffectChain.swift:367`） |
| `Chorus/Audio/Taps/AudioProcessRegistry.swift` | `Entry.isAudible`＝`kAudioProcessPropertyIsRunningOutput`；`isGroupAudible(bundleID:)`；`anyOtherProcessAudible`（排除自己與 driver 宿主）；`refresh()` 在 `isFake` 時不做事；`injectFake` 會觸發 `onProcessesChanged` |
| `Chorus/Audio/VirtualAudioDriver.swift:17` | 虛擬裝置 UID `ChorusAudioDevice_UID` |
| `Chorus/App/AppState.swift:170-180` | `--fake-taps` 用 `FakeTapBackend`；`TapEngine(backend:registry:settings:)` |
| `Tests/ChorusAppTests/TapEngineTests.swift` | 56 個 `@Test`，全部走 FakeTapBackend，用 `TapEngine(backend:registry:settings:)` 建引擎 |

---

## 1. 假設與理由

| # | 假設 | 理由與證據 | 不成立時 |
|---|---|---|---|
| A1 | 用 aggregate 的名義取樣率判斷「語音頻段」，它等於 main sub-device（耳機）的名義取樣率 | log 的 24000 Hz 就是從 aggregate 讀到的（`deviceSampleRate()` → `AUEffectChain` log），這是唯一已驗證的來源 | 改讀 sub-device。只需要動 `CoreAudioTapSession` 讀值那一處，型別與引擎不變 |
| A2 | 語音頻段的定義是名義取樣率**恰好**為 8000、16000 或 24000 Hz | brief 指定。HFP CVSD 是 8 kHz、mSBC 是 16 kHz、AirPods 新版語音是 24 kHz。整份 log 只有這一次不是 48000 | 只改 `NominalSampleRate.isTelephonyBand` 一處 |
| A3 | 視窗是 60 秒，從**最後一次**觀察到語音頻段起算，含 60.000 s。之後即使觀察到 48000 也**不清除**紀錄 | brief 行為 1 與 3。14:40 的事件從 24000 到裝置消失約 14 s | 只改 `TelephonyRateMemory.window` |
| A4 | 「先換預設、裝置還列著」時，延後跟隨的寬限是 3 秒 | log 中預設輸出變更與裝置清單變更相差 118 ms。而且寬限只在該 UID 有語音紀錄時才生效 | 只改 `handoffSettleDelay` |
| A5 | 用 `muteBehavior = .muted` 的 process tap，**不建 aggregate、不開 IOProc**，就能讓來源在系統端靜音，而且不輸出到任何裝置 | Apple 對 `CATapMuteBehavior.muted` 的定義是「被 tap 擷取並靜音」，不像 `.mutedWhenTapped` 要有讀取者才會靜音。**未確認**：本機沒有實測過沒有讀取者的 `.muted` tap | 改用 §2.2 的 fallback B。B 也失敗，就停在「可以驗證但不發布」並 escalate |
| A6 | 播放控制的正式實作是**公開 API**：用 `NSEvent.otherEvent(with: .systemDefined, … subtype: 8, data1: NX_KEYTYPE_PLAY…)` 產生事件，再用 `CGEvent.post(tap: .cghidEventTap)` 送出，相當於按一下鍵盤的播放／暫停鍵 | Podcasts 不能用 Apple Events 控制（§0.2）。媒體鍵是唯一不靠私有 API、又能控制 Podcasts 的公開途徑 | 見 A7–A9 的限制。實機 V-P1 不通過時，正式版改接 `NullPlaybackController`，並 escalate |
| A7 | 媒體鍵是**切換**，而且作用對象是系統的 Now Playing App，不是指定的 bundle。要用 CoreAudio 的「是否正在發聲」（`isGroupAudible`、其他 App 是否發聲）來把關，並在送出後驗證，才能把誤按的機率壓低 | 公開 API 沒有辦法查詢 Now Playing 是誰。正在發聲的 App 幾乎就是最近開始播放的那一個 | 把關不到的殘留風險寫在 §7 |
| A8 | 送事件需要「輔助使用」或「傳送事件」權限，用 `CGPreflightPostEventAccess()` 檢查。**不跳**授權提示，**不新增** UI 或文案。沒有權限時回 `.unsupported`，退化成「靜音 hold、不暫停、回來不代按播放」 | 要求不改選單文案與 `Localizable.xcstrings`。開了媒體鍵接管的使用者已經授權過輔助使用 | — |
| A9 | MediaRemote（`MRMediaRemoteSendCommand`）是私有 API，**不採用**。據報 macOS 15.4 之後已限制第三方存取，本機 macOS 27 沒有測過（**未確認**） | brief 要求優先用公開、可測的接縫，不能把私有 API 當成唯一做法 | 要採用，必須另開任務並取得 Fi 核准；它可以實作同一個 `PlaybackControlling` 接縫 |
| A10 | 「App 正在播放」用 `kAudioProcessPropertyIsRunningOutput`（`isAudible`）近似。暫停後有些 App 會讓 IO 多跑幾秒，所以驗證延遲設為 2 秒，驗證不過就當作暫停失敗：保持靜音、回來不代按播放 | 這是唯一公開的訊號。驗證不過時偏向保守，留給使用者自己按播放 | 調整 `playbackVerifyDelay` |
| A11 | hold 只存在記憶體。App 重啟或停用 taps 時 hold 消失，回到今天的行為 | 決策沒有要求跨重啟。寫進 SettingsStore 會多一份可能不同步的路由狀態 | 另開任務 |
| A12 | 原 UID 回來時，不管那一刻系統預設是誰，都先把 playthrough 建回原 UID。恢復後回到一般規則 | 決策要求同一副耳機回來後恢復。14:00:23 的 log 顯示原機回來時系統預設也同時切回它 | — |
| A13 | hold 期間不新增任何 UI 文字或 notice。指定路由的 App 在選單上會顯示既有的橘字「指定的輸出裝置不在，暫時走系統預設」，意思不完全準確 | 要求不改選單文案與 `Localizable.xcstrings` | 列為後續 UI 任務 |

---

## 2. 設計

### 2.0 總覽

偵測條件：某個輸出 UID 在過去 60 秒內出現過語音取樣率，接著從輸出清單消失。條件成立時，對**當時 session 建在該 UID 上**的每個 App 依序做：

1. **先靜音**：建立 silencer（`.muted` 的 process tap，不寫回任何輸出），再收掉 playthrough。這保證 Podcast 的聲音在暫停送出之前、以及暫停失敗時，都不會進入 Screen Output 或任何輸出。
2. **再暫停**：等 `pauseSettleDelay`（1 秒）。如果目標 App 還在發聲，而且沒有別的 App 在發聲，就透過 `PlaybackControlling` 送出暫停，2 秒後驗證。驗證通過才算「Chorus 暫停的」。
3. **等原 UID**：期間對帳一律維持 silencer，不建 playthrough。系統預設換到任何裝置都不結束等待。
4. **回來**：先在原 UID 建好 playthrough，再收 silencer。路由能走回原 UID 之後，只有「Chorus 暫停而且驗證過」的情況才代按播放，播放前再檢查一次目標沒在發聲、也沒有別的 App 在發聲。
5. **使用者介入**：等待期間使用者明確指定路由、reset、排除或停用，都結束等待並收掉 silencer，**不**代按播放。

silencer 在整段等待期間都保留，作為暫停失敗或使用者在別處按了播放時的安全網。

### 2.1 型別化的取樣率與純邏輯（ChorusCore，要求 10）

HAL 的取樣率只在 `CoreAudioTapSession` 讀一次，之後都用 `NominalSampleRate` 傳遞，引擎不碰 HAL 取樣率。

新檔 `Packages/ChorusCore/Sources/ChorusCore/CallHandoff.swift`：

```swift
/// 輸出裝置的名義取樣率。只在擁有它的邊界（CoreAudioTapSession）讀一次 HAL，
/// 之後以這個型別傳遞——引擎與測試都不碰 CoreAudio。
public struct NominalSampleRate: Sendable, Hashable {
    public let hertz: Double
    /// 非有限值或 ≤ 0 → nil（HAL 讀失敗不能被當成任何頻段）。
    public init?(hertz: Double)
    /// 藍牙通話（HFP）的語音頻段：恰好 8000、16000、24000 Hz。
    public var isTelephonyBand: Bool { get }
}

/// 每個輸出 UID「最後一次觀察到語音頻段」的時間。
/// 之後回到 48000 不清除——14:40 的實況是先回 48 kHz、14 秒後裝置才消失。
public struct TelephonyRateMemory<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public static var window: Duration { .seconds(60) }
    public init()
    /// 非語音頻段的觀察只拿來修剪過期項目，不會清除既有紀錄。
    public mutating func record(_ rate: NominalSampleRate, outputUID: String, at now: Instant)
    /// 過去 60 秒內（含 60.000 s）是否觀察過語音頻段。
    public func isRecentTelephony(outputUID: String, at now: Instant) -> Bool
    public func lastTelephony(outputUID: String) -> Instant?
}

/// 一個 per-app session 在這一輪對帳要走哪條路。純函式，引擎只負責執行。
public enum CallHandoffDecision: Sendable, Equatable {
    case normal                          // 今天的規則
    case enterHold(outputUID: String)    // 原 UID 消失且有語音紀錄
    case stayHeld(outputUID: String)     // 等待中，原 UID 還沒回來
    case resume(outputUID: String)       // 等待中，原 UID 回來了
    case deferFollow(outputUID: String)  // 跟隨預設、原 UID 還列著、有語音紀錄、預設已換 → 先留在原 UID
}

public enum CallHandoffPolicy {
    public static func decide(
        heldUID: String?,           // 目前在等哪個 UID（nil＝沒有 hold）
        homeUID: String?,           // 上次可聽見的 playthrough 建在哪
        followsDefault: Bool,       // entry.outputDeviceUID == nil
        defaultUID: String?,
        available: Set<String>,
        homeTelephonyRecent: Bool,  // 呼叫端用 TelephonyRateMemory 算好傳進來
        deferralExpired: Bool       // 呼叫端用延後期限算好傳進來
    ) -> CallHandoffDecision
}
```

`decide` 的規則依序判斷，先符合的先贏：

1. `heldUID != nil`：`available` 含它就回 `.resume(held)`，否則回 `.stayHeld(held)`。等待中不看預設，也不看語音紀錄是否過期（要求：另一個 UID 成為預設不結束等待；hold 沒有逾時）。
2. `homeUID != nil`、`available` 不含它、`homeTelephonyRecent` → `.enterHold(home)`。
3. `followsDefault`、`homeUID != nil`、`available` 含它、`homeTelephonyRecent`、`defaultUID != homeUID`、`!deferralExpired` → `.deferFollow(home)`。
4. 其他情況 → `.normal`。

同一個檔案再放播放控制的純邏輯：

```swift
public enum PlaybackCommand: Sendable, Equatable { case pause, play }

/// 播放控制接縫的回報。不丟錯——失敗是預期內的狀態，呼叫端要能據此保守處理。
public enum PlaybackCommandOutcome: Sendable, Equatable {
    case sent                // 已送出（不代表對方真的照做；要另外驗證）
    case unsupported         // 沒有可用的控制方式（例如沒有傳送事件的權限）
    case failed(String)      // 嘗試了但失敗
}

/// 一次來電接手中，「暫停」走到哪一步。只有 .confirmed 才可以在回來後代按播放。
public enum HandoffPauseState: Sendable, Equatable {
    case pending             // 剛進 hold，等 pauseSettleDelay 再判斷
    case userAlreadyPaused   // 判斷時目標沒在發聲：不送暫停，回來也不播
    case skippedOtherAudible // 有別的 App 在發聲：媒體鍵可能打錯對象，不送
    case unsupported
    case requested           // 已送出，等驗證
    case confirmed           // 驗證時目標已不發聲
    case failed              // 送出失敗，或驗證時仍在發聲
}

public enum HandoffPlaybackPolicy {
    /// pending 時呼叫。回傳 nil＝應該送暫停；非 nil＝不送，直接進入該狀態。
    public static func pauseGate(targetAudible: Bool, otherAudible: Bool) -> HandoffPauseState?
    //   !targetAudible → .userAlreadyPaused；otherAudible → .skippedOtherAudible；否則 nil
    public static func afterPauseSent(_ outcome: PlaybackCommandOutcome) -> HandoffPauseState
    //   .sent → .requested；.unsupported → .unsupported；.failed → .failed
    public static func verify(_ state: HandoffPauseState, targetAudible: Bool) -> HandoffPauseState
    //   .requested → targetAudible ? .failed : .confirmed；其他原樣
    public static func shouldAutoPlay(_ state: HandoffPauseState, targetAudible: Bool, otherAudible: Bool) -> Bool
    //   state == .confirmed && !targetAudible && !otherAudible
}
```

### 2.2 不出聲的 silencer（安全網）

等待期間 App 必須無聲，以下做法都**不算**完成：

- 建 playthrough 到 Screen Output，但 gain 設成 0。
- 直接收掉 tap。來源會解除靜音，聲音走系統預設。
- 建到內建喇叭或其他輸出。

`TapBackend.swift` 新增：

```swift
/// 來電接手等待期間讓一個 App 完全無聲：tap 住它但不寫回任何輸出。
/// stop() 冪等；擁有者（TapEngine）負責收。
@MainActor
protocol TapSilencer: AnyObject {
    func stop()
}

// TapBackend 新增
/// 只靜音、不寫回。**不得**建 aggregate 到任何輸出裝置——等待期間的定義
/// 就是「這段音訊哪裡都不去」（D-2026-10-27）。
func startSilencer(bundleID: String, memberBundleIDs: [String]) throws -> any TapSilencer
```

`CoreAudioTapBackend` 的主方案 A：

```swift
func startSilencer(bundleID: String, memberBundleIDs: [String]) throws -> any TapSilencer {
    try rejectSelfTap(bundleID: bundleID, memberBundleIDs: memberBundleIDs)
    let description = CATapDescription(stereoMixdownOfProcesses: [])
    description.bundleIDs = memberBundleIDs.isEmpty ? [bundleID] : memberBundleIDs
    description.isProcessRestoreEnabled = true
    description.name = "Chorus call-handoff hold (\(bundleID))"
    description.isPrivate = true
    description.muteBehavior = .muted // 不靠讀取者：tap 在就靜音
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = OperationMetrics.shared.measure("audio.tap.create") {
        AudioHardwareCreateProcessTap(description, &tapID)
    }
    guard status == noErr else { throw TapBackendError.createTapFailed(status) }
    return CoreAudioTapSilencer(tapID: tapID) // stop()：AudioHardwareDestroyProcessTap，冪等
}
```

`CoreAudioTapSilencer` 宣告為 `@MainActor private final class`，放在 `CoreAudioTapBackend.swift` 檔尾。`stop()` 用 `audio.tap.destroy` 量測。

**fallback B**：只有在實機 V-H2 證實方案 A 沒有靜音時才做。同一個 tap 改用 `.mutedWhenTapped`，放進 private aggregate。aggregate 的 `kAudioAggregateDeviceTapListKey` 只放這個 tap，**不放** `kAudioAggregateDeviceSubDeviceListKey` 與 `kAudioAggregateDeviceMainSubDeviceKey`。IOProc 只把回呼計數加一，不寫 `outOutputData`。如果 B 也沒有靜音或建立失敗，就停在「可以驗證但不發布」並 escalate，不要自行改用別的做法。

### 2.3 播放控制接縫

新目錄 `Chorus/Audio/Playback/`。`project.yml` 的 `sources: - path: Chorus` 會遞迴納入，不用改 `project.yml`，只要跑 `xcodegen generate`。

`PlaybackControlling.swift`：

```swift
import ChorusCore

/// 對其他 App 的播放控制（來電接手，D-2026-10-27）。可假的接縫——
/// 測試用 FakePlaybackController，不啟動真的 Podcasts、不送真的媒體鍵。
/// 呼叫端（TapEngine）負責用 CoreAudio 的發聲狀態把關與驗證；實作只負責送。
@MainActor
protocol PlaybackControlling: AnyObject {
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome
}

/// 沒有播放控制：一律 .unsupported。--fake-taps 與未注入時用它。
@MainActor
final class NullPlaybackController: PlaybackControlling {
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome { .unsupported }
}
```

`MediaKeyPlaybackController.swift`（正式版用，公開 API）：

```swift
import AppKit
import ChorusCore
import CoreGraphics

/// 以系統播放／暫停媒體鍵（NX_KEYTYPE_PLAY）控制 Now Playing App。
///
/// **限制**（引擎端負責把關）：這是切換鍵，作用在系統的 Now Playing App，
/// 不是 `bundleID`——bundleID 只用來寫 log。沒有傳送事件權限時回 .unsupported，
/// 不跳授權提示（不新增 UI）。
@MainActor
final class MediaKeyPlaybackController: PlaybackControlling {
    private static let keyPlay: Int32 = 16 // NX_KEYTYPE_PLAY（IOKit/hidsystem/ev_keymap.h）
    private let log = ChorusLog(category: "playback")

    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome {
        guard CGPreflightPostEventAccess() else { return .unsupported }
        for isDown in [true, false] {
            let data1 = Int((Self.keyPlay << 16) | ((isDown ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            ), let cgEvent = event.cgEvent else {
                return .failed("無法建立媒體鍵事件")
            }
            cgEvent.post(tap: .cghidEventTap)
        }
        log.notice("媒體鍵 \(command == .pause ? "暫停" : "播放")：目標 \(bundleID)")
        return .sent
    }
}
```

- `MediaKeyInterceptor` 對鍵碼 16 放行（`route` 的 `default: return false`），不會攔到自己送的事件。這一點不用改它。
- 不加 entitlement，不改 Info.plist。媒體鍵不是 Apple Events，不需要 `com.apple.security.automation.apple-events`。

`FakePlaybackController.swift`（`#if DEBUG`，和 `FakeTapBackend` 同一個模式）：

```swift
@MainActor
final class FakePlaybackController: PlaybackControlling {
    private(set) var commands: [(command: PlaybackCommand, bundleID: String)] = []
    var nextOutcome: PlaybackCommandOutcome = .sent
    /// 可選：送出時順手改 registry 的發聲狀態，模擬「對方真的停了／開始播了」。
    var onSend: ((PlaybackCommand, String) -> Void)?
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome {
        commands.append((command, bundleID))
        onSend?(command, bundleID)
        return nextOutcome
    }
}
```

`AudioProcessRegistry.swift` 新增一個查詢：

```swift
/// 除了這個 App（含歸它的 helper）、Chorus 自己與 driver 宿主之外，
/// 還有沒有別的來源在發聲。媒體鍵作用在 Now Playing App——別人也在播時
/// 不能確定按下去會打到誰（來電接手，D-2026-10-27）。
func isOtherAppAudible(than bundleID: String) -> Bool
```

實作方式和 `anyOtherProcessAudible` 一樣，再多排除 `rootBundleID(of:) == bundleID` 的行程。

### 2.4 引擎（`TapEngine.swift`）

**init**：改成 `init(backend:registry:settings:playback: (any PlaybackControlling)? = nil)`，存成 `playback ?? NullPlaybackController()`。舊測試的三參數呼叫照樣能編譯。

**新增的 `@ObservationIgnored` 狀態**：

```swift
@ObservationIgnored private let playback: any PlaybackControlling
/// 每個輸出 UID 最後一次出現語音取樣率的時間（D-2026-10-27）。
@ObservationIgnored private var telephonyRates = TelephonyRateMemory<ContinuousClock.Instant>()
/// 每個 App 上次「可聽見的 playthrough」建在哪個 UID。stopSession 不清它——
/// 從重新配置收掉到延遲重建之間，裝置可能剛好消失，hold 要知道原本在哪。
@ObservationIgnored private var homeOutputUIDs: [String: String] = [:]
@ObservationIgnored private var holds: [String: CallHandoffHold] = [:]
/// 「跟隨預設、原 UID 還列著」的延後期限。
@ObservationIgnored private var followDeferrals: [String: ContinuousClock.Instant] = [:]
@ObservationIgnored private var handoffRecheckTask: Task<Void, Never>?
@ObservationIgnored private var handoffPlaybackTask: Task<Void, Never>?
/// 測試注入時間；正式就是 ContinuousClock。
@ObservationIgnored var currentInstant: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
@ObservationIgnored var handoffSettleDelay: Duration = .seconds(3)   // 假設 A4
@ObservationIgnored var pauseSettleDelay: Duration = .seconds(1)
@ObservationIgnored var playbackVerifyDelay: Duration = .seconds(2)  // 假設 A10
```

`CallHandoffHold` 是 `TapEngine.swift` 內的 `private struct`：

```swift
private struct CallHandoffHold {
    let outputUID: String
    var silencer: (any TapSilencer)?   // nil＝建立失敗，等重試
    var pause: HandoffPauseState = .pending
}
```

**新增 internal 讀取器**，給測試使用，這次不接 UI：

```swift
func heldOutputUID(bundleID: String) -> String? { holds[bundleID]?.outputUID }
func handoffPauseState(bundleID: String) -> HandoffPauseState? { holds[bundleID]?.pause }
```

`activeOutputUID(bundleID:)` 與 `tappedBundles` 的語意不變。等待期間沒有 playthrough session，所以 `activeOutputUID` 回 nil，`tappedBundles` 不含這個 App。

#### 2.4.1 對帳（`reconcileSessions`）

在 `let available = Set(backend.outputDeviceUIDs())` 之後加 `let now = currentInstant()`。`defaultOutputDeviceUID()` 每輪最多讀一次。

**「不在 desired 的 App」那一段**原本是 `for bundleID in Array(sessions.keys) where !desired.contains`，改成走 `sessions.keys ∪ holds.keys ∪ homeOutputUIDs.keys ∪ followDeferrals.keys`。每個不在 desired 的 App：`stopSession`、`endHold(bundleID)?.stop()`，並清掉 `homeOutputUIDs` 與 `followDeferrals`。這一段涵蓋 reset、排除、調整歸零三種情況，都是使用者動作，所以**不代按播放**。

**每個 desired App**：先算 `members`，也就是把現有第 552 行往前移，再呼叫：

```swift
let decision = CallHandoffPolicy.decide(
    heldUID: holds[bundleID]?.outputUID,
    homeUID: homeOutputUIDs[bundleID],
    followsDefault: entry.outputDeviceUID == nil,
    defaultUID: defaultUID,
    available: available,
    homeTelephonyRecent: homeOutputUIDs[bundleID].map {
        telephonyRates.isRecentTelephony(outputUID: $0, at: now)
    } ?? false,
    deferralExpired: followDeferrals[bundleID].map { now >= $0 } ?? false
)
```

依 decision 執行：

| decision | 動作 |
|---|---|
| `.enterHold(uid)` | ① 先 `startSilencer`，② 再 `stopSession(bundleID)`（先建後拆），③ `holds[bundleID] = .init(outputUID: uid, silencer: s, pause: .pending)`，④ 清 `followDeferrals[bundleID]`，⑤ `scheduleHandoffPlaybackTick(after: pauseSettleDelay)`，⑥ log notice，⑦ `continue`，不建 playthrough、不 push。silencer 丟錯時：照樣建立 hold 記錄（silencer 為 nil），照樣 `stopSession`，log error，`hadSessionFailure = true`，`scheduleRetry()`。暫停流程照常進行。**不准**退回去建 playthrough |
| `.stayHeld(uid)` | 確保沒有 playthrough：`sessions[bundleID] != nil` 就 `stopSession`（正常不會發生，這是防呆）。silencer 為 nil 就重試 `startSilencer`，失敗的處理同上。然後 `continue`。**不呼叫** `startPlaythroughSession`，不設 notice，不送任何播放指令 |
| `.resume(uid)` | 令 `outputUID = uid`，略過一般路由計算，走下面既有的建 session 區塊。建立成功後，呼叫 `finishHoldAndMaybePlay(bundleID)`（§2.4.2）。建立失敗時，hold、silencer 與 pause 狀態都原樣保留，走既有的 catch（notice、`scheduleRetry`），下一輪仍是 `.resume`。**沒有建好路由就不播放** |
| `.deferFollow(uid)` | 令 `outputUID = uid`，也就是留在原 UID：現有 session 還在就不動，被重新配置收掉了就在原 UID 重建。如果 `followDeferrals[bundleID]` 是 nil，就設成 `now + handoffSettleDelay`，並 `scheduleHandoffRecheck(after: handoffSettleDelay)` |
| `.normal` | 清掉 `followDeferrals[bundleID]`，走今天的路由計算（第 529-541 行原樣保留） |

**建 session 成功時**（在現有第 567 行旁邊）：
- `homeOutputUIDs[bundleID] = outputUID`
- `if let rate = session.nominalSampleRate { telephonyRates.record(rate, outputUID: outputUID, at: currentInstant()) }`。14:40:05 的 24000 Hz 就是靠這一筆記下的。

**per-app `onDeviceReconfigured`**（第 574 行）簽名改成 `{ [weak self] rate in`。在 `stopSession` 之前，用 `self.sessionOutputUIDs[bundleID]` 與 `rate` 記錄 `telephonyRates`。其他行為不變：立刻收掉，`rebuildDelay` 之後重建。

**全域 session**：
- 建立成功與 `onDeviceReconfigured` 時，用 `globalOutputUID` 記錄取樣率。只記錄，全域 session 本身的行為不變。
- 排除清單（第 405-407 行）改成 `Set(sessions.keys).union(holds.keys).union(settings.excludedApps)`。**這一處必須改**：預設輸出變成 Screen Output，裝置級處理也跟著到 Screen Output 時，如果沒有排除 hold 中的 App，全域 tap（`.mutedWhenTapped`）會把 Podcast 寫進 Screen Output。

**probe 的 `onDeviceReconfigured`**：只把簽名改成 `{ [weak self] _ in`。

**`scheduleHandoffRecheck(after:)`**：取消舊的 `handoffRecheckTask`，`Task.sleep(for:)` 之後呼叫 `reconcileSessions()`。不要共用 `rebuildTask`：它有「連續事件互相取消」的契約（第 454-468 行），共用的話重建與延後檢查會互相吃掉。

#### 2.4.2 暫停與恢復播放

```swift
/// 來電接手的播放步驟。internal——測試直接呼叫，不等計時器（同 healthTick）。
func handoffPlaybackTick() {
    registry.refresh()
    var next: Duration?
    for bundleID in holds.keys.sorted() {
        guard var hold = holds[bundleID] else { continue }
        let targetAudible = registry.isGroupAudible(bundleID: bundleID)
        switch hold.pause {
        case .pending:
            if let skip = HandoffPlaybackPolicy.pauseGate(
                targetAudible: targetAudible,
                otherAudible: registry.isOtherAppAudible(than: bundleID)
            ) {
                hold.pause = skip
            } else {
                hold.pause = HandoffPlaybackPolicy.afterPauseSent(playback.send(.pause, bundleID: bundleID))
                if hold.pause == .requested { next = playbackVerifyDelay }
            }
        case .requested:
            hold.pause = HandoffPlaybackPolicy.verify(.requested, targetAudible: targetAudible)
        default:
            break
        }
        holds[bundleID] = hold
        // log：每次狀態改變記一行 notice
    }
    if let next { scheduleHandoffPlaybackTick(after: next) }
}
```

`scheduleHandoffPlaybackTick(after:)`：取消舊的 `handoffPlaybackTask`，sleep 之後呼叫 `handoffPlaybackTick()`。

`finishHoldAndMaybePlay(_ bundleID:)` 只在 `.resume` 成功建好 playthrough 之後呼叫：

```swift
guard var hold = holds.removeValue(forKey: bundleID) else { return }
hold.silencer?.stop()                          // 先建後拆：playthrough 已在原 UID
registry.refresh()
let targetAudible = registry.isGroupAudible(bundleID: bundleID)
if hold.pause == .requested {                  // 驗證還沒跑到就回來了：就地驗證
    hold.pause = HandoffPlaybackPolicy.verify(.requested, targetAudible: targetAudible)
}
if HandoffPlaybackPolicy.shouldAutoPlay(
    hold.pause, targetAudible: targetAudible,
    otherAudible: registry.isOtherAppAudible(than: bundleID)
) {
    let outcome = playback.send(.play, bundleID: bundleID)
    // log notice（含 outcome）
} else {
    // log notice：不代按播放（原因＝hold.pause 或「有人在播」）
}
```

- `.pending` 狀態時就回來（1 秒內）：沒有送過暫停，所以 `shouldAutoPlay` 為 false，不送任何指令。silencer 收掉後聲音照常從原 UID 出來，因為 App 從頭到尾沒被暫停。
- 只有 `.confirmed` 才會送 `.play`。`userAlreadyPaused`、`skippedOtherAudible`、`unsupported`、`failed` 都不播。

#### 2.4.3 使用者介入

`setOutputDevice(_:bundleID:)` 改成：

```swift
func setOutputDevice(_ uid: String?, bundleID: String) {
    // 來電接手等待中，使用者明確選了路由 → 結束等待、照新路由走，不代按播放
    //（D-2026-10-27）。silencer 等新 session 建好才收（先建後拆）；新路由不需要
    // tap 時，來源回到原生路徑。
    let silencer = endHold(bundleID)
    homeOutputUIDs.removeValue(forKey: bundleID)
    followDeferrals.removeValue(forKey: bundleID)
    if silencer != nil { log.notice("來電接手等待結束：\(bundleID) 使用者改路由 → \(uid ?? "預設")，不代按播放") }
    update(bundleID: bundleID) { $0.outputDeviceUID = uid }
    silencer?.stop()
}
```

`endHold(_:) -> (any TapSilencer)?` 是私有 helper：移除 `holds[bundleID]`，丟掉 pause 狀態，回傳 silencer 讓呼叫端決定什麼時候 `stop()`。這個 helper **不送任何播放指令**。

- 只要呼叫就結束等待，不論新值和舊值是否相同。呼叫端只有選單（`AppVolumeSection.swift:186,195`）與 TestHooks，兩者都是明確動作。
- 清掉 `homeOutputUIDs`，避免下一輪因為舊 UID 的語音紀錄又進入 hold。
- `setGain`、`setMuted`、EQ、效果**不結束**等待：走 `update` → `sessions[bundleID] == nil` → 全量對帳 → `.stayHeld`。設定照存，恢復時套用。
- `reset` 與 `setExcluded(true)`：App 離開 desired，由 §2.4.1 的清理段結束等待。
- `shutdownSessions()`（停用 taps、重新探測）：收掉全部 silencer，清空 `holds`、`homeOutputUIDs`、`followDeferrals`，取消 `handoffRecheckTask` 與 `handoffPlaybackTask`，並重設 `telephonyRates = .init()`。不送播放指令。

### 2.5 AppState 接線

`Chorus/App/AppState.swift:180` 改成：

```swift
// --fake-taps（E2E）不送真的媒體鍵
let playback: any PlaybackControlling = instance.fakeTaps ? NullPlaybackController() : MediaKeyPlaybackController()
tapEngine = TapEngine(backend: tapBackend, registry: tapRegistry, settings: settings, playback: playback)
```

`instance.fakeTaps` 只在 `#if DEBUG` 區塊裡用到。實作時，Release 分支直接用 `MediaKeyPlaybackController()`，要和既有的 `#if DEBUG … #else … #endif` 結構對齊。

### 2.6 不動的東西

以下都不改：

- 系統預設輸出
- 虛擬裝置的轉送目標（`AudioDeviceManager.updateVirtualTarget`）
- Lid Guard 與 keep-awake
- `Localizable.xcstrings`、選單文案、任何 `Text(...)`
- `AppAudioSetting` 與 `SettingsStore` 的 schema
- entitlements 與 Info.plist
- `MediaKeyInterceptor`

等待路徑中，引擎**不寫** `settings.appAudio`。

### 2.7 log

這些是診斷用的 log，不是 UI 文字，不進 xcstrings。

- 記到語音頻段：`notice("輸出 \(uid) 名義取樣率 \(Int(rate.hertz)) Hz（語音頻段）")`
- 進入 hold：`notice("來電接手：\(bundleID) 原本 → \(uid)，\(秒數)s 前出現語音取樣率；先靜音、準備暫停，等原裝置回來")`
- silencer 失敗：`error("來電接手 silencer 失敗：\(bundleID) \(error)")`
- 暫停狀態每次改變：`notice("來電接手暫停：\(bundleID) \(舊狀態) → \(新狀態)")`
- 延後跟隨第一次發生：`notice("預設輸出換了，但 \(uid) 還在且剛出現語音取樣率：\(bundleID) 先留 \(秒數)s")`
- 恢復：`notice("來電接手結束：\(bundleID) 原裝置 \(uid) 回來，接回；播放：\(已送出／不代按（原因）)")`

---

## 3. 檔案

| 檔案 | 動作 | 內容 |
|---|---|---|
| `Packages/ChorusCore/Sources/ChorusCore/CallHandoff.swift` | 新增 | §2.1 全部型別 |
| `Packages/ChorusCore/Tests/ChorusCoreTests/CallHandoffTests.swift` | 新增 | §5.1 |
| `Chorus/Audio/Taps/TapBackend.swift` | 修改 | `TapSession.nominalSampleRate`；`onDeviceReconfigured` 改成 `(@MainActor (NominalSampleRate?) -> Void)?`；新增 `TapSilencer` 與 `TapBackend.startSilencer` |
| `Chorus/Audio/Taps/CoreAudioTapBackend.swift` | 修改 | `CoreAudioTapSession` 在 init 讀一次名義取樣率，存成 `nominalSampleRate`，同時當作 `cachedSampleRate` 的初值。listener 讀一次，更新兩者後傳給回呼。`deviceSampleRate()` 給 DSP 用的 48000 fallback 不變。新增 `startSilencer` 與 `CoreAudioTapSilencer` |
| `Chorus/Audio/Taps/FakeTapBackend.swift` | 修改 | 見下方 |
| `Chorus/Audio/Taps/AudioProcessRegistry.swift` | 修改 | `isOtherAppAudible(than:)`（§2.3） |
| `Chorus/Audio/Taps/TapEngine.swift` | 修改 | §2.4 |
| `Chorus/Audio/Playback/PlaybackControlling.swift` | 新增 | 協定與 `NullPlaybackController` |
| `Chorus/Audio/Playback/MediaKeyPlaybackController.swift` | 新增 | §2.3 |
| `Chorus/Audio/Playback/FakePlaybackController.swift` | 新增 | `#if DEBUG` |
| `Chorus/App/AppState.swift` | 修改 | §2.5 一處 |
| `Tests/ChorusAppTests/CallHandoffHoldTests.swift` | 新增 | §5.2。用自己的 `makeEngine` helper，不改 `TapEngineTests.swift` |

`FakeTapBackend` 只新增成員，既有成員的簽名與行為不變：

```swift
/// 每個輸出 UID 的名義取樣率（沒設＝48000）。session 建立時帶上。
var nominalRates: [String: NominalSampleRate] = [:]
/// 依序記錄的事件：「silencer+:<bundle>」「silencer-:<bundle>」「play:<bundle>@<uid>」「stop:<bundle>」。
/// 驗證先建後拆用。
private(set) var events: [String] = []
private(set) var startedSilencers: [String] = []
private(set) var liveSilencers: [String: FakeTapSilencer] = [:]
/// > 0 時，下一次 startSilencer 丟錯並遞減。
var silencerFailuresRemaining = 0
/// 對這些 UID 的 startPlaythroughSession 丟錯（模擬恢復失敗）。
var failingPlaythroughOutputs: Set<String> = []
```

- `startPlaythroughSession`：
  - `failingPlaythroughOutputs` 含目標 UID 時，丟 `TapBackendError.createAggregateFailed(-1)`。丟錯之前**不改** `startedSessions` 與 `startedOutputs`。
  - 成功時附加 `events`，把 `nominalRates[uid] ?? NominalSampleRate(hertz: 48_000)` 傳給 `FakeTapSession`，`label` 設為 bundleID。
- `FakeTapSession`：
  - `init` 新增參數 `nominalSampleRate: NominalSampleRate? = NominalSampleRate(hertz: 48_000)` 與 `label: String? = nil`，新增屬性 `let nominalSampleRate`。
  - `stop()` 第一次被呼叫、而且 `label != nil` 時，附加 `stop:<label>`。
  - `simulateDeviceReconfigured()` 改成 `simulateDeviceReconfigured(to rate: NominalSampleRate? = nil)`。原本無參數的呼叫照樣能編譯，舊測試不用改。
- `FakeTapSilencer`：有 `stopped` 屬性。`stop()` 冪等，第一次呼叫時附加 `events`。

新增 `Chorus/Audio/Playback/*` 與 `CallHandoffHoldTests.swift` 之後要跑 `xcodegen generate`，`*.xcodeproj` 不提交。ChorusCore 的新檔由 SPM 自動納入。

**不准碰**：
- `Tests/ChorusAppTests/TapEngineTests.swift`：56 個舊測試一行都不改
- `Chorus/Resources/*.xcstrings`
- `Chorus/UI/**`
- `Chorus/MediaKeys/**`
- `Chorus/Audio/AudioDeviceManager.swift`、`Chorus/Audio/VirtualAudioDriver.swift`
- `Chorus/Support/*.entitlements`、`Chorus/Support/Info.plist`、`project.yml`
- keep-awake 與 Lid Guard 相關檔案
- `docs/` 底下的其他檔案

---

## 4. 步驟（TDD，每步一個本機 commit）

每步的 commit 第一行都照 repo 慣例：英文 Conventional Commit，同一行後面接中文。

1. **ChorusCore 型別與政策（先紅後綠）**
   - 先寫 `CallHandoffTests.swift`（§5.1），跑 `swift test`，確認紅。
   - 再寫 `CallHandoff.swift`，跑到綠。
   - commit：`feat: Add call-handoff rate memory and playback policy 功能：新增來電接手取樣率記憶與播放判斷`
2. **backend 接縫（純重構）**
   - 改 `TapBackend.swift`、`FakeTapBackend.swift`、`CoreAudioTapBackend.swift`。`TapEngine.swift` 的三個 `onDeviceReconfigured` closure 只改簽名。
   - 全部 App 測試必須綠，56 個舊 TapEngine 測試行為不變。
   - commit：`refactor: Carry typed nominal sample rate through tap sessions 重構：tap session 改傳型別化名義取樣率`
3. **播放控制接縫**
   - 新增 `Chorus/Audio/Playback/` 三個檔案，以及 `AudioProcessRegistry.isOtherAppAudible(than:)`。
   - `xcodegen generate`，然後 build。
   - commit：`feat: Add playback control seam with media-key implementation 功能：新增播放控制接縫與媒體鍵實作`
4. **引擎 hold、暫停、恢復（先紅後綠）**
   - 先寫 `CallHandoffHoldTests.swift`（§5.2），`xcodegen generate`，確認紅。
   - 再改 `TapEngine.swift`（§2.4）與 `AppState.swift`（§2.5），跑到綠。
   - 跑整個 `ChorusAppTests`。
   - commit：`fix: Pause podcast while a call takes the AirPods, resume on return 修復：來電帶走耳機時暫停播放，原耳機回來再自動播放`
5. **建置**：Debug 與 Release 的 `xcodebuild build` 各跑一次。確認 Release 沒有引用 `FakeTapBackend` 或 `FakePlaybackController`，它們都在 `#if DEBUG` 裡。
6. **自我檢查**：
   - `git diff 82c8f1aad608bd001f308c2d31758c98f4a408be --stat` 只能出現 §3 的 12 個檔。
   - `git status` 如果出現 `Localizable.xcstrings`，用 `git checkout` 還原。
7. **回報**：寫明測試指令與結果、驗收逐條打勾、偏離計畫的地方，以及實機驗證的待辦。
8. **實機驗證（§5.5）交給有核准的驗證者**。實作者沒有 iPhone 來電的環境時，標成「未驗證」，不能自行宣稱通過。

---

## 5. 測試

### 5.1 ChorusCore（`swift test`，不碰 CoreAudio）

`CallHandoffTests.swift` 用 `ManualClock.Instant` 當 `Instant`。

| 測試 | 期待 |
|---|---|
| `NominalSampleRate(hertz:)`：0、負數、`.nan`、`.infinity` | nil |
| `isTelephonyBand` | 8000、16000、24000 → true；11025、22050、32000、44100、48000、96000 → false |
| record 24000 → +14 s record 48000 → 再 +14 s 查詢 | true（回到 48000 不會清除） |
| record 24000 → +60.000 s 查詢 | true（含邊界） |
| record 24000 → +60.001 s 查詢 | false |
| record 24000 → +50 s record 16000 → 再 +50 s 查詢 | true（從最後一次起算） |
| UID A 有語音紀錄，查 UID B | false（依 UID 分開） |
| 只 record 48000 | false |
| `decide` 表格（§2.1 規則 1–4） | 至少涵蓋：hold 中原 UID 回來 → resume；hold 中原 UID 不在、預設是另一副耳機 → stayHeld；hold 中 `homeTelephonyRecent == false` → 仍是 stayHeld；沒有 hold、home 不在、有紀錄 → enterHold；home 不在、沒有紀錄 → normal；home 還在、跟隨預設、預設已換、有紀錄、未逾期 → deferFollow；同上但已逾期 → normal；同上但指定路由（`followsDefault == false`）→ normal；home 還在、預設沒換 → normal；home 為 nil → normal |
| `pauseGate` | 目標沒發聲 → `.userAlreadyPaused`（不論別人）；目標發聲、別人也發聲 → `.skippedOtherAudible`；只有目標發聲 → nil |
| `afterPauseSent` | `.sent → .requested`、`.unsupported → .unsupported`、`.failed(_) → .failed` |
| `verify` | `.requested` 加上仍發聲 → `.failed`；`.requested` 加上不發聲 → `.confirmed`；其他狀態原樣 |
| `shouldAutoPlay` | 只有 `(.confirmed, 目標不發聲, 別人不發聲)` 為 true。其他六種狀態都是 false；`.confirmed` 但目標在發聲（使用者已自己按播放）→ false；`.confirmed` 但別人在發聲 → false |

### 5.2 App（`CallHandoffHoldTests.swift`，FakeTapBackend 加 FakePlaybackController）

**共用設定**：

- UID：`let screen = "ChorusAudioDevice_UID"`、`airpods = "94-16-25-48-CC-A9:output"`、`airpods4 = "F8-D3-F0-59-73-BD:output"`。
- 初始裝置：`availableOutputUIDs = [airpods, "BuiltInSpeakerDevice", screen]`，`defaultOutputUID = airpods`。
- registry：`injectFake` 放 Music（objectID 1001，`isAudible: true`），需要時再加 Safari（1002）。helper `setAudible(_ bundle:, _ on:)` 重新 `injectFake`。
- 引擎：`TapEngine(backend:registry:settings:playback: fakePlayback)`。
  - `engine.rebuildDelay = .seconds(3600)`
  - `engine.handoffSettleDelay = .seconds(3)`
  - `engine.pauseSettleDelay = .seconds(3600)`
  - `engine.playbackVerifyDelay = .seconds(3600)`
  - 用測試內的 `@MainActor final class TestClock { var now = ContinuousClock.now }` 注入 `engine.currentInstant`。
  - 所有延遲步驟都用同步呼叫驅動，不等真實計時器，避免時好時壞：`engine.audioDevicesChanged()`、`backend.simulateDefaultOutputChange()`、`engine.handoffPlaybackTick()`。
- `fakePlayback.onSend`：收到 `.pause` 時把 Music 設成不發聲，收到 `.play` 時設成發聲。只有測試需要「沒有生效」時才清掉這個 closure。
- helper `reproduce1440()`，依序：
  1. `setGain(0.5)`
  2. `nominalRates[airpods] = 24000` → `liveSessions[Music].simulateDeviceReconfigured(to: 24000)` → `audioDevicesChanged()`（在 24 kHz 重建）
  3. `nominalRates[airpods] = 48000` → `simulateDeviceReconfigured(to: 48000)` → `audioDevicesChanged()`（回到 48 kHz）
  4. 時鐘 +11 s
- helper `takeAway(defaultFirst: Bool)`：把 airpods 移出清單、`defaultOutputUID = screen`，依參數決定先呼叫 `simulateDefaultOutputChange()` 還是 `audioDevicesChanged()`，兩個都會呼叫。

**測試案例**：

| ID | 測試名（`@Test` 字串） | 步驟重點 | 期待 |
|---|---|---|---|
| H1 | 來電帶走耳機（先消失再換預設）：先靜音、不進 Screen Output，再暫停 | `reproduce1440` → `takeAway(defaultFirst: false)` → `handoffPlaybackTick()` | tick 前：`heldOutputUID == airpods`；`startedOutputs` 不含 screen 與 BuiltInSpeakerDevice；`liveSilencers[Music]` 存在且未 stop；舊 playthrough 已 `stopped`；`events` 中 `silencer+:Music` 在最後一個 `stop:Music` 之前；`activeOutputUID == nil`；`tappedBundles` 不含 Music；`setting.outputDeviceUID == nil`；`fakePlayback.commands.isEmpty`（暫停在 silencer 之後才送）。tick 後：`commands == [(.pause, Music)]`；`handoffPauseState == .requested`。再 tick 一次 → `.confirmed` |
| H1b | 14:40:19 的順序（先換預設、裝置還列著）：不提前灌進 Screen Output | `reproduce1440` → `defaultOutputUID = screen`，airpods 仍在清單 → `simulateDefaultOutputChange()` → 移除 airpods → `audioDevicesChanged()` | 換預設後：`activeOutputUID == airpods`，沒有新的 playthrough。移除之後同 H1。整個過程 `startedOutputs` 不含 screen |
| H1c | 重新配置收掉、還沒重建時裝置就消失：一樣 hold | `reproduce1440` 的第 2 步之後 → `simulateDeviceReconfigured(to: 24000)`（session 已收）→ `takeAway` | 進入 hold，`startedOutputs` 不含 screen |
| H2 | 原耳機回來：先接回路由，再自動播放 Chorus 暫停的 | H1（到 `.confirmed`）→ 加回 airpods、`defaultOutputUID = airpods` → `audioDevicesChanged()` | 新的 playthrough 剛好 1 條，目標 airpods；`events` 順序：`play:Music@airpods` 在 `silencer-:Music` 之前；`commands.last == (.play, Music)`，而且是在 playthrough 建立之後才送（由 `onSend` 內記下 `backend.events.count` 來比對）；`heldOutputUID == nil`；`lastGain == 0.5`；`setting.outputDeviceUID == nil` |
| H2b | 原耳機回來時預設仍是 Screen Output：仍建回原 UID 再播放 | 同 H2，但 `defaultOutputUID` 保持 screen | 新 playthrough 目標 airpods；有送 `.play` |
| H2c | 使用者本來就暫停（進 hold 時沒在發聲）：不暫停、回來不代按播放 | `reproduce1440` → `setAudible(Music, false)` → `takeAway` → tick → 加回 airpods → `audioDevicesChanged()` | `handoffPauseState == .userAlreadyPaused`；`commands.isEmpty`；playthrough 建回 airpods |
| H2d | 等待中使用者自己按了播放：回來不代按（避免切換鍵反而暫停） | H1（`.confirmed`）→ `setAudible(Music, true)` → 加回 airpods → `audioDevicesChanged()` | `commands` 只有那一筆 `.pause`；playthrough 建回 airpods；在這之前 silencer 一直沒 stop，所以等待期間 Music 不出聲 |
| H2e | 暫停送出但沒生效：視為失敗，保持靜音，回來不代按 | `onSend = nil`（Music 一直發聲）→ H1 → tick → tick | `handoffPauseState == .failed`；silencer 未 stop；`startedOutputs` 不含 screen；回來之後 `commands` 沒有 `.play` |
| H2f | 沒有播放控制（無權限）：退化成靜音等待，不代按 | `nextOutcome = .unsupported` → H1 → tick → 回來 | `.unsupported`；等待期間 silencer 存在、不進 screen；回來後沒有 `.play`；playthrough 建回 airpods |
| H2g | 有別的 App 在發聲：媒體鍵可能打錯，不送暫停 | Safari 也發聲 → H1 → tick | `.skippedOtherAudible`；`commands.isEmpty`；silencer 存在 |
| H2h | 驗證前就回來：就地驗證後才決定播放 | H1 只 tick 一次（`.requested`）→ 加回 airpods → `audioDevicesChanged()` | 就地驗證得到 `.confirmed`（`onSend` 已讓 Music 不發聲）→ 有送 `.play` |
| H3 | 一般拔除（沒有語音取樣率）：維持退回系統預設，不暫停 | 只有 48 kHz → `takeAway` → tick | `activeOutputUID == screen`；`startedSilencers.isEmpty`；`heldOutputUID == nil`；`commands.isEmpty`。插回後，跟隨預設的 App 跟著預設回到 airpods |
| H3b | 指定路由的一般拔除：退回預設，設定與 notice 照舊 | `setOutputDevice(airpods)`，只有 48 kHz → 移除 airpods → `audioDevicesChanged()` | 和舊測試「指定的裝置被拔掉」相同：`activeOutputUID == screen`、`lastTapError != nil`、設定仍是 airpods；沒有 silencer、沒有 command |
| H4 | 只有取樣率變化、裝置還在：延遲重建、不 hold、不暫停 | `simulateDeviceReconfigured(to: 24000)` → `audioDevicesChanged()`（airpods 仍在，預設不變）→ tick | 新 playthrough 目標 airpods；`startedSilencers.isEmpty`；`heldOutputUID == nil`；`commands.isEmpty` |
| H5 | 語音紀錄超過 60 秒後的普通消失：退回預設 | `reproduce1440`，時鐘推到最後一次 24 kHz 之後 +60.001 s → `takeAway` | `activeOutputUID == screen`；沒有 silencer；沒有 command |
| H5b | 60 秒整（含邊界）仍算來電 | 同 H5，但只推到 +60.000 s | 進入 hold |
| H6 | 語音紀錄撐過回到 48000 Hz（約 14 秒間隔） | `reproduce1440` → 再 +3 s → `takeAway` | 進入 hold |
| H7 | 等待中使用者指定路由（即使是 Screen Output）：結束等待、照新路由走、不代按播放 | H1（`.confirmed`）→ `setOutputDevice(screen)` | `heldOutputUID == nil`；playthrough 目標 screen；`play:Music@screen` 在 `silencer-:Music` 之前；`commands` 沒有 `.play`；`setting.outputDeviceUID == screen` |
| H7b | 等待中使用者選「跟隨系統預設」：結束等待、不代按播放 | 先 `setOutputDevice(airpods)` 再跑 H1 → `setOutputDevice(nil)` | `heldOutputUID == nil`；gain 0.5 仍需要 tap，playthrough 建在目前的預設；沒有 `.play` |
| H8 | 系統預設自動改到別的耳機、內建喇叭或 Screen Output：不結束等待、不播放 | H1 → 加入 airpods4 並設為預設 → `simulateDefaultOutputChange()` 加 `audioDevicesChanged()`；接著改成 BuiltInSpeakerDevice，再改成 screen | 每一步都 `heldOutputUID == airpods`；playthrough 的開始次數不變；`startedSilencers.count == 1`；`commands` 只有那一筆 `.pause` |
| H9 | 重跑對帳不會讓等待中出聲兩次、提前灌進 Screen Output，或多送指令 | H1 → `audioDevicesChanged()` 三次、`simulateDefaultOutputChange()` 兩次、`setGain(0.3)`、`setMuted(true)` 再 `setMuted(false)`、`handoffPlaybackTick()` 兩次 → H2 恢復 → 再 `audioDevicesChanged()` 三次、tick 兩次 | 等待期間：playthrough 開始次數不變、`startedSilencers.count == 1`、`startedOutputs` 不含 screen、`.pause` 只有 1 筆。恢復後：恰好多 1 條 playthrough（airpods）、`.play` 只有 1 筆，之後重跑都不再增加；`liveSessions[Music].initialGain == 0.3`（等待中的調整有存，恢復時套用） |
| H10 | 等待中的 App 從裝置級全域 tap 排除 | H1 → `updateDeviceProcessing(deviceUID: screen, gain: 0.5, muted: false, eq: nil)` | `backend.globalExclusions.contains(1001)` |
| H11 | reset、排除、停用會結束等待並收掉 silencer，不代按播放 | 三個獨立情境：H1 之後分別呼叫 `reset`、`setExcluded(true)`、`setEnabled(false)` | `heldOutputUID == nil`；silencer `stopped`；沒有新的 playthrough 到 screen；沒有 `.play` |
| H12 | silencer 建不起來：不退回任何輸出，排程重試，暫停照送 | `silencerFailuresRemaining = 1` → H1 的消失步驟 → tick | `heldOutputUID == airpods`；`startedOutputs` 不含 screen；`lastTapError == nil`（不新增 UI 文字）；有送 `.pause`。再呼叫一次 `audioDevicesChanged()`，`liveSilencers[Music]` 就建立 |
| H13 | 回來時建 playthrough 失敗：維持等待、維持 silencer、不播放 | H1（`.confirmed`）→ `failingPlaythroughOutputs = [airpods]` → 加回 airpods → `audioDevicesChanged()` | `heldOutputUID == airpods`；silencer 未 stop；沒有 `.play`。清空 `failingPlaythroughOutputs` 再對帳 → 恢復並送 `.play` |
| H14 | 指定路由到原耳機的 App：hold、恢復，設定始終不變 | 先 `setOutputDevice(airpods)`，再跑 H1 → H2 | 期待同 H1 與 H2；`setting.outputDeviceUID == airpods` 從頭到尾不變 |
| H15 | 別的 UID 有語音紀錄，不影響這個 UID 的消失 | `nominalRates[airpods4] = 24000`，讓另一個 App 在 airpods4 上記到語音頻段；Music 在 airpods 上只有 48 kHz → 移除 airpods | Music 退回預設；沒有 silencer、沒有 command |
| H16 | 先換預設、原耳機一直沒消失：寬限過後照常跟隨預設 | `reproduce1440` → `defaultOutputUID = screen`，airpods 仍在 → `simulateDefaultOutputChange()` → 時鐘 +3 s → `audioDevicesChanged()` | 第一次仍留在 airpods；寬限過後 `activeOutputUID == screen`；沒有 silencer、沒有 command |

### 5.3 必須保持全綠的舊測試（一行不改）

`Tests/ChorusAppTests/TapEngineTests.swift` 的 56 個測試全部要綠，尤其是：
- 「指定的裝置被拔掉：暫時退回系統預設，但設定留著」
- 「預設輸出變更：跟隨預設的 session 搬家（收舊建新）」
- 「換系統預設：跟隨預設的搬家，指定路由的不動」
- 「裝置中途重新配置（藍牙耳機切降噪）→ 立即收掉、延遲後重建、設定原樣重放」
- 「每一路音訊只處理一次：被 per-app tap 抓走的行程要從全域 tap 排除」

它們不受影響的原因：舊測試不設 `nominalRates`，fake 一律回報 48000，所以永遠走 `.normal`；它們用三參數 init，拿到的是 `NullPlaybackController`。任何舊測試變紅時，要修的是實作，不是測試的預期值。

### 5.4 指令

```sh
{ swift test --package-path Packages/ChorusCore ; } 2>&1 | xcsift -f toon -w -E
xcodegen generate
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests/CallHandoffHoldTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild build -scheme Chorus -destination platform=macOS -configuration Release ; } 2>&1 | xcsift -f toon -w -E
```

以 TOON 的 `status:` 為準，不要只看 exit code。這個 worktree 在 `~/orca/workspaces`，不在 iCloud 底下，`DerivedData` 用預設位置即可。

### 5.5 實機驗證（交給有核准的驗證者，實作者標「未驗證」）

前置條件：Chorus 已取得輔助使用權限；Podcast 設了 gain ≠ 1，讓 Chorus 接管。

| ID | 步驟 | 通過條件 |
|---|---|---|
| V-P1 | 不打電話，也不新增測試鉤子。Podcasts 播放中，按實體鍵盤的播放／暫停鍵（F8）兩次；同時用 `log stream --predicate 'subsystem == "com.hermes.Chorus"'` 看 Chorus | 第一次 Podcasts 暫停，第二次恢復，表示 Podcasts 是 Now Playing 目標。Chorus 自己送出的事件在 V-H1 用 log 的 `requested → confirmed` 驗證。V-H1 拿不到 `confirmed` 時，正式版改接 `NullPlaybackController` 並 escalate |
| V-H1 | 重現 14:40：Mac 用 AirPods 播 Podcast，iPhone 來電，在 iPhone 上接聽 | log 依序出現「語音頻段」「來電接手：…先靜音」「來電接手暫停：pending → requested → confirmed」；**沒有**「per-app session 建立：com.apple.podcasts → ChorusAudioDevice_UID」；Podcasts 顯示已暫停；螢幕喇叭與內建喇叭都沒有聲音 |
| V-H2 | 確認 silencer 有效（假設 A5）：暫時拿掉輔助使用權限，重做 V-H1 | Podcast 的進度在走，但 Mac 上任何輸出都沒有聲音。不通過時，實作 §2.2 的 fallback B，再重做 V-H1 與 V-H2 |
| V-H3 | 掛斷，AirPods 回到 Mac | log 出現「來電接手結束：… 回來，接回；播放：已送出」，Podcast 從 AirPods 自動繼續播放，音量與 EQ 和來電前一樣 |
| V-H4 | Podcast 先手動暫停，再來電、掛斷 | 不會自動播放 |
| V-H5 | 一般拔除：AirPods 收進盒子，沒有來電 | 和 13:58 一樣退回系統預設；沒有暫停；沒有 hold 相關 log |
| V-H6 | 只切換降噪模式 | 一樣延遲重建；沒有暫停；沒有 hold 相關 log |
| V-H7 | 等待中接上另一副耳機（AirPods4） | 仍然暫停且無聲，沒有自動播放 |
| V-H8 | 等待中在選單為 Podcast 指定 Screen Output | 等待結束，Podcast 不會自動播放；使用者手動按播放時，聲音從螢幕出來 |

---

## 6. 驗收條件

每一條都要有對應的自動測試通過（括號內是 §5.2 的 ID）；實機項目另外標示。

- [ ] **正常 hold**：出現語音頻段後原 UID 消失 → 先靜音，再暫停該 App。playthrough 不建到 `ChorusAudioDevice_UID` 或任何其他輸出。使用者設定不變。（H1、H1b、H1c、H6；實機 V-H1）
- [ ] **原 UID 回來恢復**：同一個 UID 重新出現 → 剛好建 1 條 playthrough 回該 UID，先建後拆 silencer，**之後**才代按播放，而且只在 Chorus 暫停並驗證過時才播。不改寫 `outputDeviceUID`。（H2、H2b、H2h、H14；實機 V-H3）
- [ ] **只播 Chorus 暫停的**：使用者本來就暫停、等待中自己按了播放、暫停沒生效、沒有權限、有別的 App 在發聲，這些情況都不代按播放。（H2c、H2d、H2e、H2f、H2g；實機 V-H4）
- [ ] **暫停失敗也不進 Screen Output**：沒有權限或暫停沒生效時，silencer 仍讓 App 無聲，不建任何 playthrough。（H2e、H2f；實機 V-H2）
- [ ] **一般拔除仍退回預設**：沒有語音紀錄的消失，行為與基線相同（包括指定路由的 notice），不暫停。（H3、H3b、H15；舊測試；實機 V-H5）
- [ ] **只有取樣率變化不 hold**：裝置還在 → 立刻收掉、延遲後在同一個 UID 重建，沒有 silencer，不暫停。（H4；舊測試「裝置中途重新配置」；實機 V-H6）
- [ ] **hold 逾時窗口**：最後一次語音頻段超過 60 秒後的消失 → 退回預設；剛好 60 秒仍然 hold。（H5、H5b）
- [ ] **使用者改路由結束 hold**：等待中明確指定路由（包括 Screen Output 與跟隨預設）→ 結束等待，照新路由走，先建後拆，不代按播放。（H7、H7b；實機 V-H8）
- [ ] **另一個 UID 成為預設不結束 hold**：另一副耳機、內建喇叭或 Screen Output 自動成為預設時，等待不變，不出聲，不播放。（H8；實機 V-H7）
- [ ] **重跑對帳冪等**：等待期間任何對帳或 tick 都不會多建 silencer、不會建 playthrough、不會進 Screen Output、不會多送指令。恢復後重跑也不會再多建或多播。（H9）
- [ ] **不從全域 tap 漏出**：等待中的 App 在全域 tap 的排除清單裡。（H10）
- [ ] **失敗安全**：silencer 建不起來時不退回任何輸出；恢復失敗時維持等待、不播放。（H12、H13）
- [ ] **使用者動作結束 hold**：reset、排除、停用 taps，都不代按播放。（H11）
- [ ] **取樣率型別化**：`kAudioDevicePropertyNominalSampleRate` 只出現在 `CoreAudioTapBackend.swift`（`grep -rn kAudioDevicePropertyNominalSampleRate Chorus`）。引擎與測試只碰 `NominalSampleRate`。
- [ ] **播放接縫可假**：App 測試沒有送出真的媒體鍵，也沒有啟動 Podcasts。`MediaKeyPlaybackController` 只在 `AppState` 非 `--fake-taps` 時建立。沒有用到任何私有 API（`grep -rn "MediaRemote\|MRMediaRemote" Chorus` 沒有結果）。
- [ ] **舊測試**：`TapEngineTests.swift` 的 56 個測試全綠，而且 `git diff 82c8f1aad608bd001f308c2d31758c98f4a408be -- Tests/ChorusAppTests/TapEngineTests.swift` 是空的。
- [ ] **範圍**：`git diff --stat` 只有 §3 的 12 個檔。沒有動到 `Localizable.xcstrings`、UI、MediaKeys、AudioDeviceManager、VirtualAudioDriver、entitlements、Info.plist、keep-awake、Lid Guard、`project.yml`。
- [ ] **建置**：Debug 與 Release 的 `xcodebuild build` 都是 `status: success`，Swift 6 strict concurrency 沒有新警告（`-w`）。

---

## 7. 風險

| 風險 | 影響 | 對策 |
|---|---|---|
| A5 不成立：沒有讀取者的 `.muted` tap 不會靜音 | 暫停送出前，以及暫停失敗時，Podcast 會從 Screen Output 出聲 | V-H2 必驗；不成立就用 fallback B；兩個都不成立就停在本機並 escalate |
| 媒體鍵打到錯的 App（Now Playing 不是目標） | 可能讓別的 App 開始播放，或暫停別的 App | 只在「目標正在發聲、而且沒有別的 App 在發聲」時才送；送出後驗證；只有 `.confirmed` 才在回來時播放，播放前再查一次。殘留風險：Now Playing 是一個已暫停的別的 App，同時目標正在發聲。這種組合很少見，而且 silencer 會讓目標維持無聲 |
| 系統自己在耳機離開時暫停了 Podcast，但 IO 還沒停 | 送出的切換鍵反而讓它開始播放 | `pauseSettleDelay` 1 秒後才判斷；驗證時還在發聲就判定 `.failed`，silencer 讓它保持無聲，回來時不代按播放。最壞情況是使用者回來時 Podcast 正在播 |
| App 暫停後 IO 還跑超過 2 秒 | 誤判成 `.failed`，回來不自動播放 | 偏向保守（使用者手動按播放就好）。V-P1 會量實際時間，必要時調整 `playbackVerifyDelay` |
| 沒有輔助使用或傳送事件的權限 | 不會暫停，只有靜音等待；回來不代按播放 | A8。不新增 UI；log 寫明 `.unsupported` |
| Mac 自己通話（FaceTime 或 Teams 用 AirPods）後 60 秒內，AirPods 被拔走 | 被誤判成來電接手，Podcast 暫停到原耳機回來 | 決策已接受「原耳機沒回來前保持暫停」。log 有明確 notice |
| 延後跟隨 3 秒 | Mac 自己通話後 60 秒內手動換系統預設，跟隨預設的 App 最多晚 3 秒才搬 | 有上限；只在該 UID 有語音紀錄時才發生 |
| 指定路由的 App 在等待中顯示既有的橘字 | 文字意思不準 | 要求不改文案（A13）；列為後續 UI 任務 |
| 等待中 App 重啟或停用 taps | hold 消失，可能從 Screen Output 出聲，也不會自動播放 | A11。停用是使用者動作；App 重啟很罕見 |

---

## 8. 不在範圍內

- Music.app 的 AppleScript 專用路徑。它可以精準暫停，但需要 Apple Events entitlement、Info.plist 用途說明與 TCC 提示，會動到 entitlements 與文案。
- MediaRemote 私有 API（A9）。
- hold 期間的 UI 提示或選單文案。
- 跨 App 重啟保留 hold。
