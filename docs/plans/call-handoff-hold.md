# 計畫：來電接手時暫停 Podcast，原耳機回來再自動播放（call-handoff hold）

- 版本：r2（2026-10-27，依第 1 次審查修訂；前一版是 commit `9a1abc958155a128833263a14bfe4a6f5664f974`）
- 基線產品碼：`82c8f1aad608bd001f308c2d31758c98f4a408be`（main，1.16.1 build 142）
- 回滾點：產品碼回到 `82c8f1aad608bd001f308c2d31758c98f4a408be` 就恢復今天的行為；計畫本身的回滾點是 `9a1abc958155a128833263a14bfe4a6f5664f974`
- 決策：主 checkout 的 `docs/decisions.md`「D-2026-10-27 — 來電接手時 Podcast 不要進 Screen Output」，以 **16:24 修訂版**為準：暫停播放；同一個輸出 UID 回來才自動播放；只有 Chorus 自己暫停、而且能歸屬到該 App 的，才自動播放；聲音不得進入 Chorus Screen Output。worktree 裡的 `docs/decisions.md` 是舊副本，沒有這一條
- 診斷：`~/Downloads/Chorus-diagnostics-3138DD9E-A70F-43A8-868D-07A97102AAF4/chorus.log`
- 風險等級：L2（改一條會出聲的音訊路由，並新增對其他 App 的播放控制）
- 撰寫：Claude，2026-10-27。只有計畫，沒有改產品程式或測試
- 實作者權限：本機 commit。不 push、不開 PR、不合併、不跑 `scripts/release.sh`
- **開工前的阻擋**：§9 的 Fi 問題 1 沒有答覆前，正式版的播放控制一律接 `NullPlaybackController`。結果是「只靜音、不暫停、不自動播放」，做不到決策要求的「暫停後自動播放」。其餘部分（靜音不變式、hold、恢復路由）不受這個問題影響，可以先實作

## r2 修訂對照（第 1 次審查）

| 審查意見 | 嚴重度 | 改在哪裡 |
|---|---|---|
| silencer 失敗時仍然 `stopSession`，來源解除靜音後走系統預設（可能是 Screen Output）；H12 沒有證明原生路徑也不出聲 | high | §2.0 的**靜音不變式**；§2.2 改成 `ensureMuteGuard`；§2.4.1 的 `.enterHold`／`.stayHeld` 在 guard 建立之前**不收** playthrough；§2.4.4 失敗路徑。測試：§3 Fake 新增 `sourceOutput(for:)` 與 `muteGaps(for:)`，H12 與 H12b 改寫 |
| `onDeviceReconfigured` 先收 tap，若原 UID 在重建前消失，清單對帳還沒跑就已漏聲；H1c 只看最後結果 | high | §2.4.3 的重新配置處理：有語音頻段或 UID 有語音紀錄時，**先建 guard 再收**，失敗就保留舊 session、標記 stale。§2.4.2 在語音頻段一出現時就**預先武裝** guard。測試：H1c 改寫（逐步檢查）、新增 H1d、H4 改寫 |
| 媒體鍵是切換鍵且不看 bundleID，發聲轉靜默也不能證明是 Chorus 暫停的 | high | 選**阻擋**：§2.3 接縫要求 `canAddress(bundleID:)`，只有能把指令確定送到指定 bundle 的實作才可以回 true；公開 API 沒有這種實作，所以正式版是 `NullPlaybackController`。媒體鍵實作移到 §8 選項 (a)。§9 的 Fi 問題 1 列出三個選項。測試：P1、P2、P3 |
| 共用的 `handoffPlaybackTask` 會取消別人的驗證期限；tick 不看各 App 自己的期限 | medium | §2.4.5：每個 hold 記錄自己的 `pauseDue`／`verifyDue`；tick 只處理到期的項目；排程用所有期限中最早的那個。測試：D1、D2 |

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

- 「AU 鏈建立」共 92 行：91 行是 48000 Hz，1 行是 24000 Hz（`grep -o "格，[0-9]* Hz" | sort | uniq -c`）。
- 13:58:05 同一個 UID 消失時，log 裡沒有 24000 Hz。session 退回 `ChorusAudioDevice_UID`；14:00:23 原機回來後又接回，系統預設也同時切回它。這條一般拔除要維持現況。
- **順序**：14:40:19.648 session 先被收掉並重建，AudioDeviceManager 的「裝置清單變更」在 118 ms 之後才記錄。觸發 TapEngine 的是 backend 的預設輸出 listener（`defaultOutputChanged`），不是 `audioDevicesChanged`。對帳當下 `94-16…` 是否還在 `outputDeviceUIDs()` 裡，log 判斷不出來（**未確認**）。計畫要同時處理兩種順序：先消失再換預設，以及先換預設、裝置還列著（§2.4.1 的延後跟隨）。
- **漏聲空窗**：14:40:04.880 收掉 tap，14:40:05.854 才重建，中間約 1 秒來源沒有被任何 tap 靜音，聲音走原生路徑。當時原 UID 還在，所以聲音走 AirPods。如果原 UID 在這段時間消失，聲音就會走系統預設（Screen Output）。r2 用 §2.4.3 關掉這個空窗。
- log 看不出 Podcast 的設定是「跟隨預設」還是「指定 94-16…」，因為 `App 設定` 是 info 等級，沒有進診斷檔。計畫兩種都處理。

### 0.2 本機系統（2026-10-27，macOS 27.0.1）

- `/System/Applications/Podcasts.app` **沒有** `.sdef`，Info.plist 也**沒有** `NSAppleScriptEnabled` 或 `OSAScriptingDefinition`。Podcasts 不能用 Apple Events 或 AppleScript 控制（已驗證）。
- `/System/Applications/Music.app` 可以用 AppleScript 控制（`com.apple.Music.sdef`）。
- Chorus 沒有 MediaRemote 或 Now Playing 客戶端。macOS 沒有公開 API 可以查詢 Now Playing 是哪個 App，也沒有公開 API 可以對指定 bundle 送出暫停或播放。媒體鍵（`NX_KEYTYPE_PLAY`）是切換鍵，作用在 Now Playing，不看 bundle。
- `Chorus/MediaKeys/MediaKeyInterceptor.swift` 已經用輔助使用權限攔截媒體鍵，但只接手音量鍵與亮度鍵。
- `Chorus/Support/Chorus.entitlements`：未沙箱，沒有 `com.apple.security.automation.apple-events`。

### 0.3 程式現況（基線 commit）

| 位置 | 現況 |
|---|---|
| `Chorus/Audio/Taps/TapEngine.swift:506-608` `reconcileSessions` | 指定的裝置不在 → 改用 `backend.defaultOutputDeviceUID()`，設定不動，並設 notice。跟隨預設 → 用預設輸出。實際 UID 和目標不同 → 先 `stopSession` 再建 |
| `TapEngine.swift:574-579` | `onDeviceReconfigured` 立刻 `stopSession`，再 `scheduleRebuild(after: rebuildDelay)`（正式值 1.5 s）。回呼不帶取樣率 |
| `TapEngine.swift:615-622` `stopSession` | 會連 `sessionOutputUIDs` 一起清掉，所以從重新配置到重建之間，引擎不知道這個 App 原本建在哪 |
| `TapEngine.swift:405-407` | 全域 tap 的排除清單是 `sessions.keys ∪ excludedApps` |
| `TapEngine.swift:709-724` `defaultOutputChanged` | active 時直接呼叫 `reconcileSessions()` |
| `Chorus/Audio/Taps/TapBackend.swift:44` | `var onDeviceReconfigured: (@MainActor () -> Void)?` |
| `Chorus/Audio/Taps/CoreAudioTapBackend.swift:162-180` | 正式 per-app 用 `muteBehavior = .mutedWhenTapped`。**tap 收掉之後，來源會解除靜音，改走系統預設** |
| `CoreAudioTapBackend.swift:605-615` | rate listener 掛在 aggregate 的 `kAudioDevicePropertyNominalSampleRate`，只負責清快取、呼叫回呼 |
| `CoreAudioTapBackend.swift:763-772` `deviceSampleRate()` | 懶讀 aggregate 的名義取樣率，讀不到就退回 `EQSettings.referenceSampleRate`。log 裡的「24000 Hz」就是這個值（`AUEffectChain.swift:367`） |
| `Chorus/Audio/Taps/AudioProcessRegistry.swift` | `isGroupAudible(bundleID:)` 讀 `kAudioProcessPropertyIsRunningOutput`；`refresh()` 在 `isFake` 時不做事；`injectFake` 會觸發 `onProcessesChanged` |
| `Chorus/Audio/VirtualAudioDriver.swift:17` | 虛擬裝置的 UID 是 `ChorusAudioDevice_UID` |
| `Chorus/App/AppState.swift:180` | `TapEngine(backend:registry:settings:)` |
| `Tests/ChorusAppTests/TapEngineTests.swift` | 56 個 `@Test`，全部走 FakeTapBackend，用三參數的 init 建引擎 |

---

## 1. 假設與理由

| # | 假設 | 理由與證據 | 不成立時 |
|---|---|---|---|
| A1 | 判斷「語音頻段」用的是 aggregate 的名義取樣率，它等於 main sub-device（耳機）的名義取樣率 | log 的 24000 Hz 就是從 aggregate 讀到的，這是唯一已驗證的來源 | 改讀 sub-device。只動 `CoreAudioTapSession` 讀值的那一處 |
| A2 | 語音頻段是名義取樣率**恰好**等於 8000、16000 或 24000 Hz | brief 指定。整份 log 只有這一次不是 48000 | 只改 `NominalSampleRate.isTelephonyBand` |
| A3 | 視窗 60 秒，從**最後一次**觀察到語音頻段起算，含 60.000 s 這個邊界。之後觀察到 48000 也**不清除**紀錄 | brief 行為 1 與 3。14:40 從 24000 到消失約 14 s | 只改 `TelephonyRateMemory.window` |
| A4 | 「先換預設、裝置還列著」時，延後跟隨的寬限是 3 秒 | log 中預設變更與清單變更相差 118 ms；而且只在該 UID 有語音紀錄時才生效 | 只改 `handoffSettleDelay` |
| A5 | `muteBehavior = .muted` 的 process tap，**不建 aggregate、不開 IOProc**，就能讓來源在系統端靜音，而且不輸出到任何裝置 | Apple 對 `CATapMuteBehavior.muted` 的定義是「被 tap 擷取並靜音」，不需要有讀取者。**未確認** | 改用 §2.2 的 fallback B；如果 B 也不行，就停在「可以驗證但不發布」並 escalate |
| A6 | 同一個行程同時有 mute guard（`.muted`）與 playthrough tap（`.mutedWhenTapped`）時，playthrough 仍然讀得到來源的聲音，寫回原 UID 時聽得見 | tap 擷取的是行程的輸出，靜音發生在送往硬體的那一端。**未確認** | 實機 V-G1 不通過時，改成「延後武裝」（§2.4.2 的 fallback）：只在要收掉 playthrough 的前一刻才建 guard。代價是 HAL 自己移除裝置的那幾毫秒無法覆蓋（§7） |
| A7 | 公開 API 無法確認 Now Playing 是誰，也無法把暫停或播放送到指定的 bundle。發聲轉成靜默，也不能證明是 Chorus 暫停的 | §0.2 | 見 §9 Fi 問題 1 |
| A8 | hold 只存在記憶體中。App 重啟或停用 taps 時，hold 就消失 | 決策沒有要求跨重啟 | 另開任務 |
| A9 | 原 UID 回來時，不論系統預設是誰，都先把 playthrough 建回原 UID。恢復之後，回到一般規則 | 決策要求同一副耳機回來後恢復；14:00:23 的 log 顯示，原機回來時預設也同時切回 | — |
| A10 | hold 期間不新增任何 UI 文字或 notice。指定路由的 App 會顯示既有的橘字「指定的輸出裝置不在，暫時走系統預設」，意思不完全準確 | 要求不改選單文案、不改 `Localizable.xcstrings` | 列為後續 UI 任務 |

---

## 2. 設計

### 2.0 總覽與靜音不變式

**靜音不變式**：一個 App 只要符合下列任一條件，從那一刻起到條件解除為止，來源**在任何時刻**都至少要被一個 tap 靜音住，也就是 playthrough tap（`.mutedWhenTapped`，IO 在跑）或 mute guard（`.muted`）兩者至少存在一個：
- (i) 它的 home UID 在 60 秒內出現過語音頻段（「有語音紀錄」）
- (ii) 它在 hold 中

引擎對這種 App **不准**在 mute guard 確定建立之前收掉 playthrough。建立失敗時，寧可保留一條格式過期的 playthrough，或保留一條建在已消失裝置上的 playthrough，也不准解除靜音。沒有語音紀錄的 App 維持基線行為。

流程如下：

1. **預先武裝**：某個 UID 一出現語音頻段（session 建立時讀到，或重新配置回呼帶進來），就替所有 home 在這個 UID 上的 App 建 mute guard。playthrough 繼續照常出聲（A6）。
2. **重新配置**：如果帶進來的是語音頻段，或該 UID 有語音紀錄，就確認 guard 存在之後才收掉舊 session，並延遲重建（行為不變）。guard 建不起來，就保留舊 session、標記為 stale，重試成功後才收掉。
3. **原 UID 消失 → hold**：guard 已經存在，就收掉 playthrough；guard 不存在，就**不收**，並重試 guard。兩種情況都不建任何新 playthrough。
4. **暫停**：只在播放控制能確定把指令送到該 bundle 時才送（§2.3）。正式版目前做不到（A7），所以只維持靜音，等 Fi 決定（§9）。
5. **原 UID 回來**：先在原 UID 建好 playthrough，再決定是否收 guard，最後才決定是否自動播放。自動播放只在 Chorus 自己送出暫停、播放控制確認送達該 bundle、而且回來時仍能定址到它的時候進行。
6. **使用者介入**：使用者明確指定路由、reset、排除、停用時，結束 hold，不自動播放。這些是使用者的明確動作，之後走新的路由或原生路徑。
7. **解除武裝**：沒有 hold、語音紀錄過期、而且在 home 上有活著的 playthrough 時，才收掉 guard。

### 2.1 型別化的取樣率與純邏輯（ChorusCore）

取樣率只在 `CoreAudioTapSession` 從 HAL 讀一次，之後一律用 `NominalSampleRate` 傳遞。

新檔 `Packages/ChorusCore/Sources/ChorusCore/CallHandoff.swift`：

```swift
/// 輸出裝置的名義取樣率。只在擁有它的邊界（CoreAudioTapSession）讀一次 HAL，
/// 之後以這個型別傳遞——引擎與測試都不碰 CoreAudio。
public struct NominalSampleRate: Sendable, Hashable {
    public let hertz: Double
    /// 非有限值或 ≤ 0 → nil。
    public init?(hertz: Double)
    /// 藍牙通話（HFP）語音頻段：恰好 8000、16000、24000 Hz。
    public var isTelephonyBand: Bool { get }
}

/// 每個輸出 UID「最後一次觀察到語音頻段」的時間。之後回到 48000 不清除。
public struct TelephonyRateMemory<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public static var window: Duration { .seconds(60) }
    public init()
    public mutating func record(_ rate: NominalSampleRate, outputUID: String, at now: Instant)
    /// 過去 60 秒內（含 60.000 s）是否觀察過語音頻段。
    public func isRecentTelephony(outputUID: String, at now: Instant) -> Bool
    /// 紀錄到期的時刻（最後一次 + 60 s）；沒有紀錄回 nil。排程解除武裝用。
    public func expiry(outputUID: String) -> Instant?
}

public enum CallHandoffDecision: Sendable, Equatable {
    case normal
    case enterHold(outputUID: String)
    case stayHeld(outputUID: String)
    case resume(outputUID: String)
    case deferFollow(outputUID: String)
}

public enum CallHandoffPolicy {
    public static func decide(
        heldUID: String?, homeUID: String?, followsDefault: Bool, defaultUID: String?,
        available: Set<String>, homeTelephonyRecent: Bool, deferralExpired: Bool
    ) -> CallHandoffDecision
}
```

`decide` 依序判斷，先符合的先贏：
1. `heldUID != nil`：如果 `available` 含它 → `.resume(held)`；否則 → `.stayHeld(held)`。hold 中不看預設，也不看語音紀錄是否過期。
2. `homeUID != nil`，`available` 不含它，而且 `homeTelephonyRecent` → `.enterHold(home)`。
3. `followsDefault`、`homeUID` 在 `available` 裡、`homeTelephonyRecent`、`defaultUID != homeUID`、`!deferralExpired` 全部成立 → `.deferFollow(home)`。
4. 其他 → `.normal`。

播放的純邏輯也放在同一個檔案。**歸屬**的定義是：播放控制回報「已送達該 bundle」（`.delivered`），而且送出時能定址到它。只看發聲狀態不算歸屬。

```swift
public enum PlaybackCommand: Sendable, Equatable { case pause, play }

public enum PlaybackCommandOutcome: Sendable, Equatable {
    /// 實作保證指令送到了這個 bundle（不是「送了一個全域按鍵」）。
    case delivered
    case unsupported
    case failed(String)
}

public enum HandoffPauseState: Sendable, Equatable {
    case pending             // 剛進 hold，等 pauseDue
    case notAddressable      // 播放控制無法確定送到這個 bundle：不送，回來也不播
    case userAlreadyPaused   // 判斷時目標沒在發聲：不送，回來也不播
    case requested           // 已送達，等 verifyDue
    case confirmed           // 已送達且驗證時已不發聲 → 可歸屬為 Chorus 暫停的
    case failed              // 送出失敗，或驗證時仍在發聲
}

public enum HandoffPlaybackPolicy {
    /// pending 到期時呼叫。nil＝送暫停；非 nil＝不送，直接進入該狀態。
    public static func pauseGate(canAddress: Bool, targetAudible: Bool) -> HandoffPauseState?
    //   !canAddress → .notAddressable；!targetAudible → .userAlreadyPaused；否則 nil
    public static func afterPauseSent(_ outcome: PlaybackCommandOutcome) -> HandoffPauseState
    //   .delivered → .requested；.unsupported → .notAddressable；.failed → .failed
    public static func verify(_ state: HandoffPauseState, targetAudible: Bool) -> HandoffPauseState
    //   .requested → targetAudible ? .failed : .confirmed；其他狀態原樣
    public static func shouldAutoPlay(_ state: HandoffPauseState, canAddressNow: Bool, targetAudible: Bool) -> Bool
    //   state == .confirmed && canAddressNow && !targetAudible
}
```

### 2.2 mute guard（不出聲的 tap）

在 `TapBackend.swift` 新增：

```swift
/// 讓一個 App 完全無聲的 tap：不寫回任何輸出。stop() 冪等；擁有者（TapEngine）負責收。
@MainActor
protocol TapSilencer: AnyObject {
    func stop()
}

// TapBackend 新增
/// 只靜音、不寫回。**不得**建 aggregate 到任何輸出裝置（D-2026-10-27）。
func startSilencer(bundleID: String, memberBundleIDs: [String]) throws -> any TapSilencer
```

`CoreAudioTapBackend` 的主方案 A：

```swift
func startSilencer(bundleID: String, memberBundleIDs: [String]) throws -> any TapSilencer {
    try rejectSelfTap(bundleID: bundleID, memberBundleIDs: memberBundleIDs)
    let description = CATapDescription(stereoMixdownOfProcesses: [])
    description.bundleIDs = memberBundleIDs.isEmpty ? [bundleID] : memberBundleIDs
    description.isProcessRestoreEnabled = true
    description.name = "Chorus call-handoff guard (\(bundleID))"
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

`CoreAudioTapSilencer` 宣告為 `@MainActor private final class`，放在檔尾；`stop()` 用 `audio.tap.destroy` 量測。

**fallback B**：只有在 V-H2 證實方案 A 不會靜音時才做。tap 改用 `.mutedWhenTapped`，放進一個 private aggregate。這個 aggregate 的 `kAudioAggregateDeviceTapListKey` 只放這個 tap，**不放** `kAudioAggregateDeviceSubDeviceListKey` 或 `kAudioAggregateDeviceMainSubDeviceKey`。IOProc 只計數，不寫 `outOutputData`。B 也不行時，就停在「可以驗證但不發布」並 escalate。

### 2.3 播放控制接縫（審查 high 2：選阻擋）

新目錄 `Chorus/Audio/Playback/`。`project.yml` 用 `sources: - path: Chorus` 遞迴納入，不用改設定檔，只需要跑 `xcodegen generate`。

`PlaybackControlling.swift`：

```swift
import ChorusCore

/// 對其他 App 的播放控制（來電接手，D-2026-10-27）。可假的接縫。
///
/// **契約**：`canAddress` 只在實作能把指令**確定送到這個 bundle**時回 true
/// ——送一個作用在 Now Playing 的全域切換鍵不算。`send` 回 `.delivered`
/// 也必須是同一個保證。引擎在 `canAddress == false` 時不送任何指令。
@MainActor
protocol PlaybackControlling: AnyObject {
    func canAddress(bundleID: String) -> Bool
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome
}

/// 無法定址任何 bundle：不送、不播。正式版在 Fi 決定 §9 問題 1 之前用它。
@MainActor
final class NullPlaybackController: PlaybackControlling {
    func canAddress(bundleID: String) -> Bool { false }
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome { .unsupported }
}
```

`FakePlaybackController.swift`（`#if DEBUG`）：

```swift
@MainActor
final class FakePlaybackController: PlaybackControlling {
    /// 模擬「目前能確定送達的 bundle」（例如 Now Playing 是誰）。測試可隨時改。
    var addressable: Set<String> = []
    var nextOutcome: PlaybackCommandOutcome = .delivered
    private(set) var commands: [(command: PlaybackCommand, bundleID: String)] = []
    /// 送出時呼叫（測試用它改 registry 的發聲狀態，模擬對方真的停了或播了）。
    var onSend: ((PlaybackCommand, String) -> Void)?
    func canAddress(bundleID: String) -> Bool { addressable.contains(bundleID) }
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome {
        commands.append((command, bundleID))
        onSend?(command, bundleID)
        return nextOutcome
    }
}
```

**正式版接 `NullPlaybackController`**：`TapEngine.init` 的 `playback` 參數預設為 nil，代表 Null。`AppState` 不用改。在 Fi 回答 §9 之前，正式行為是：先靜音、hold、原 UID 回來時恢復 playthrough；**不暫停，也不自動播放**。Podcast 在等待期間會繼續播放，只是聽不到。這一點做不到決策的要求，所以列為阻擋（§9）。

不採用的實作：
- 媒體鍵：不看 bundle，屬於 §9 的選項 (a)。設計放在 §8，Fi 選 (a) 才實作。
- MediaRemote：私有 API，屬於選項 (c)，要另開任務評估。本計畫不實作。
- Apple Events：Podcasts 不支援（§0.2）。

### 2.4 引擎（`TapEngine.swift`）

**init**：改成 `init(backend:registry:settings:playback: (any PlaybackControlling)? = nil)`，存成 `playback ?? NullPlaybackController()`。舊測試的三參數呼叫照常編譯。

**新增的 `@ObservationIgnored` 狀態**：

```swift
@ObservationIgnored private let playback: any PlaybackControlling
@ObservationIgnored private var telephonyRates = TelephonyRateMemory<ContinuousClock.Instant>()
/// 上次「可聽見的 playthrough」建在哪個 UID。stopSession 不清它。
@ObservationIgnored private var homeOutputUIDs: [String: String] = [:]
/// mute guard 的唯一擁有者（武裝與 hold 共用）。
@ObservationIgnored private var muteGuards: [String: any TapSilencer] = [:]
/// 重新配置時建不起 guard、只好留下的過期 session；guard 建好後再收舊建新。
@ObservationIgnored private var staleSessions: Set<String> = []
@ObservationIgnored private var holds: [String: CallHandoffHold] = [:]
@ObservationIgnored private var followDeferrals: [String: ContinuousClock.Instant] = [:]
@ObservationIgnored private var handoffRecheckTask: Task<Void, Never>?
@ObservationIgnored private var handoffPlaybackTask: Task<Void, Never>?
@ObservationIgnored var currentInstant: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
@ObservationIgnored var handoffSettleDelay: Duration = .seconds(3)
@ObservationIgnored var pauseSettleDelay: Duration = .seconds(1)
@ObservationIgnored var playbackVerifyDelay: Duration = .seconds(2)
```

```swift
private struct CallHandoffHold {
    let outputUID: String
    var pause: HandoffPauseState = .pending
    var pauseDue: ContinuousClock.Instant?    // pending 時有值
    var verifyDue: ContinuousClock.Instant?   // requested 時有值
}
```

**給測試用的 internal 讀取器**（這次不接 UI）：

```swift
func heldOutputUID(bundleID: String) -> String? { holds[bundleID]?.outputUID }
func handoffPauseState(bundleID: String) -> HandoffPauseState? { holds[bundleID]?.pause }
func hasMuteGuard(bundleID: String) -> Bool { muteGuards[bundleID] != nil }
func nextHandoffPlaybackDue() -> ContinuousClock.Instant? // 所有 hold 的 pauseDue／verifyDue 取最小
```

`activeOutputUID(bundleID:)` 與 `tappedBundles` 的語意不變。

**guard 的私有 helper**：

```swift
/// 確保這個 App 有 mute guard。已有就回 true；建立失敗回 false（log error、scheduleRetry）。
private func ensureMuteGuard(_ bundleID: String, members: [String]) -> Bool
/// 只有在 guard 確實存在時才收 playthrough。回傳是否收了。
/// **靜音不變式的唯一執行點**：有語音紀錄或 hold 的 App，一律走這裡收 session。
private func stopSessionKeepingSilent(_ bundleID: String, members: [String]) -> Bool {
    guard ensureMuteGuard(bundleID, members: members) else { return false }
    stopSession(bundleID)
    staleSessions.remove(bundleID)
    return true
}
private func releaseMuteGuard(_ bundleID: String) { muteGuards.removeValue(forKey: bundleID)?.stop() }
```

#### 2.4.1 對帳（`reconcileSessions`）

在 `let available = …` 之後，加上 `let now = currentInstant()`。

**不在 desired 的 App**：走 `sessions.keys ∪ holds.keys ∪ homeOutputUIDs.keys ∪ followDeferrals.keys ∪ muteGuards.keys ∪ staleSessions`。對每一個執行 `stopSession`、`releaseMuteGuard`，並清掉 `holds`、`homeOutputUIDs`、`followDeferrals`、`staleSessions`。這涵蓋 reset、排除、調整歸零三種情況，都是使用者動作，所以來源回到原生路徑，**不**自動播放。

**每個 desired App**：先算出 `members`（把現有第 552 行往前移），再呼叫 `CallHandoffPolicy.decide(...)`（參數同 r1）。依結果處理：

| decision | 動作 |
|---|---|
| `.enterHold(uid)` | ① 建立 `holds[bundleID] = .init(outputUID: uid, pause: .pending, pauseDue: now + pauseSettleDelay)`，從此不會被建到別處。② 呼叫 `stopSessionKeepingSilent`；回 false 時**保留**現有的 playthrough（它的 tap 仍讓來源靜音），log error，`hadSessionFailure = true`。③ 清掉 `followDeferrals[bundleID]`。④ 呼叫 `rescheduleHandoffPlayback()`（§2.4.5）。⑤ 呼叫 `continue`。**不准**建 playthrough，**不准**在 guard 建好前收 session |
| `.stayHeld(uid)` | 如果 `sessions[bundleID] != nil`（上一輪 guard 失敗時留下的），就用 `stopSessionKeepingSilent` 再試一次；否則用 `ensureMuteGuard` 確保 guard 存在。不建 playthrough，不設 notice，不送任何指令。呼叫 `continue` |
| `.resume(uid)` | 令 `outputUID = uid`，走既有的建 session 區塊。成功時呼叫 `finishHold(bundleID)`（§2.4.4）；失敗時 hold 與 guard 原樣保留，走既有的 catch |
| `.deferFollow(uid)` | 令 `outputUID = uid`，留在原 UID。如果 `followDeferrals[bundleID]` 是 nil，就設定期限，並呼叫 `rescheduleHandoffRecheck()` |
| `.normal` | 清掉 `followDeferrals[bundleID]`，走今天的路由計算。另外，如果這個 App 有語音紀錄、而且即將因為換裝置而收掉 session（第 547-549 行的 `actual != outputUID`），要改用 `stopSessionKeepingSilent`；回 false 就跳過這一輪（保留舊 session），並 `scheduleRetry()` |

**stale session**：在建 session 區塊之前，如果 `staleSessions.contains(bundleID)`，就呼叫 `stopSessionKeepingSilent`，成功後照常在 `outputUID` 重建。

**解除武裝**：在每個 desired App 處理完之後，如果 `muteGuards[bundleID] != nil`、`holds[bundleID] == nil`、home 沒有語音紀錄、而且 `sessions[bundleID]` 活著並建在 home 上，就 `releaseMuteGuard(bundleID)`。

**建 session 成功時**：設定 `homeOutputUIDs[bundleID] = outputUID`，並呼叫 `recordRate(session.nominalSampleRate, outputUID:)`（§2.4.2）。

**全域 session**：排除清單改成 `Set(sessions.keys).union(holds.keys).union(muteGuards.keys).union(settings.excludedApps)`。建立成功時與 `onDeviceReconfigured` 時都呼叫 `recordRate(..., outputUID: globalOutputUID)`。

**probe 的 `onDeviceReconfigured`**：只把簽名改成 `{ [weak self] _ in`。

**`rescheduleHandoffRecheck()`**：取消舊的 `handoffRecheckTask`，改排在「所有 `followDeferrals` 期限」與「所有有 guard 的 App 的 home 語音紀錄到期時刻」中最早的那一個，時間到就跑 `reconcileSessions()`。不共用 `rebuildTask`。

#### 2.4.2 記錄取樣率與預先武裝

```swift
private func recordRate(_ rate: NominalSampleRate?, outputUID: String?) {
    guard let rate, let outputUID else { return }
    telephonyRates.record(rate, outputUID: outputUID, at: currentInstant())
    guard rate.isTelephonyBand else { return }
    log.notice("輸出 \(outputUID) 名義取樣率 \(Int(rate.hertz)) Hz（語音頻段）→ 武裝靜音保護")
    for (bundleID, home) in homeOutputUIDs where home == outputUID {
        _ = ensureMuteGuard(bundleID, members: registry.memberBundleIDs(bundleID: bundleID))
    }
    rescheduleHandoffRecheck()
}
```

guard 在 playthrough 照常出聲時就已經存在（A6）。14:40:05 建在 24 kHz 的那條 session 一建立就會武裝；所以 14:40:19 裝置消失時 guard 早已到位，HAL 自己重新路由的那一瞬間也有覆蓋。

**fallback（V-G1 不通過時）：延後武裝**。`recordRate` 不建 guard，只記錄。guard 只在 `stopSessionKeepingSilent` 裡建立，也就是要收 session 的前一刻。重新配置與 hold 的空窗仍然關得住，但 HAL 在 Chorus 反應之前就移除裝置的那幾毫秒不保證（§7）。

#### 2.4.3 重新配置（審查 high 1 的空窗）

per-app `onDeviceReconfigured`（第 574 行）改成：

```swift
sessions[bundleID]?.onDeviceReconfigured = { [weak self] rate in
    guard let self, self.sessions[bundleID] != nil else { return }
    let uid = self.sessionOutputUIDs[bundleID]
    self.recordRate(rate, outputUID: uid)   // 語音頻段 → 這裡就武裝 guard
    let telephony = uid.map { self.telephonyRates.isRecentTelephony(outputUID: $0, at: self.currentInstant()) } ?? false
    if telephony {
        // 靜音不變式：guard 建好之前不收。建不起來就留著過期 session（可能有雜音，
        // 但不會從 Screen Output 出聲），標 stale、排重試。
        guard self.stopSessionKeepingSilent(bundleID, members: self.registry.memberBundleIDs(bundleID: bundleID)) else {
            self.staleSessions.insert(bundleID)
            self.log.error("per-app session 的裝置重新配置：\(bundleID) 靜音保護建不起來 → 先留著舊 session")
            self.scheduleRetry()
            return
        }
    } else {
        self.stopSession(bundleID)          // 基線行為（降噪切換）
    }
    self.log.notice("per-app session 的裝置重新配置：\(bundleID) → 收掉、\(self.rebuildDelay.components.seconds)s 後重建")
    self.scheduleRebuild(after: self.rebuildDelay)
}
```

- 帶進來的是語音頻段（14:40:04 的 48→24），或 UID 已經有語音紀錄（14:40:07 的 24→48）：先建 guard 再收舊 session。重建之前，來源由 guard 靜音。重建之前原 UID 就消失時，下一輪對帳會得到 `.enterHold`，guard 已經在了。
- 沒有語音紀錄、帶進來的也不是語音頻段（降噪切換、舊測試）：基線行為一字不改。
- **行為變化（刻意的）**：語音頻段的重新配置在 1.5 s 重建期間由原本「走原生路徑從原 UID 出聲」改成「無聲」。這只發生在有語音紀錄時，不影響降噪切換。

#### 2.4.4 結束 hold 與自動播放

`finishHold(_ bundleID:)` 只在 `.resume` 成功建好 playthrough 之後呼叫：

```swift
guard var hold = holds.removeValue(forKey: bundleID) else { return }
// playthrough 已在原 UID：guard 交給 §2.4.1 的「解除武裝」決定（語音紀錄過期才收）
registry.refresh()
let targetAudible = registry.isGroupAudible(bundleID: bundleID)
if hold.pause == .requested { hold.pause = HandoffPlaybackPolicy.verify(.requested, targetAudible: targetAudible) }
if HandoffPlaybackPolicy.shouldAutoPlay(hold.pause,
                                        canAddressNow: playback.canAddress(bundleID: bundleID),
                                        targetAudible: targetAudible) {
    let outcome = playback.send(.play, bundleID: bundleID)
    log.notice("來電接手結束：\(bundleID) 接回 \(hold.outputUID)；自動播放 \(String(describing: outcome))")
} else {
    log.notice("來電接手結束：\(bundleID) 接回 \(hold.outputUID)；不自動播放（\(String(describing: hold.pause))）")
}
rescheduleHandoffPlayback()
```

**使用者介入**：`setOutputDevice(_:bundleID:)` 改成下面這樣：

```swift
func setOutputDevice(_ uid: String?, bundleID: String) {
    // 來電接手等待中，使用者明確選了路由 → 結束等待、照新路由走、不自動播放（D-2026-10-27）。
    let wasHeld = holds.removeValue(forKey: bundleID) != nil
    homeOutputUIDs.removeValue(forKey: bundleID)
    followDeferrals.removeValue(forKey: bundleID)
    if wasHeld { log.notice("來電接手等待結束：\(bundleID) 使用者改路由 → \(uid ?? "預設")，不自動播放") }
    update(bundleID: bundleID) { $0.outputDeviceUID = uid }
    // 新 session 建好（或新路由不需要 tap）之後才收 guard：使用者選的路由才是答案
    releaseMuteGuard(bundleID)
    staleSessions.remove(bundleID)
    rescheduleHandoffPlayback()
}
```

- 呼叫就結束等待，不比較新舊值。呼叫端只有選單（`AppVolumeSection.swift:186,195`）與 TestHooks。
- `setGain`、`setMuted`、EQ、效果**不會**結束等待。它們會走全量對帳，得到 `.stayHeld`，設定照存。
- `reset`、`setExcluded(true)`：由 §2.4.1 的清理段結束等待，不自動播放。
- `shutdownSessions()`：收掉所有 guard，清空 `holds`、`homeOutputUIDs`、`followDeferrals`、`staleSessions`，取消兩個 handoff task，並 `telephonyRates = .init()`。這是使用者的停用動作；重新探測則是基線行為。

**失敗路徑總表**（審查 high 1）：

| 情況 | 來源狀態 | 會不會進 Screen Output |
|---|---|---|
| guard 預先武裝成功 | guard 靜音 | 不會 |
| 預先武裝失敗，之後重新配置 | 保留舊 session（stale），由 tap 靜音 | 不會（可能有格式雜音，原 UID 還在時從原 UID 出來） |
| guard 失敗，原 UID 消失 | 保留建在已消失裝置上的 playthrough。它的 tap 還在，IO 有沒有停是 HAL 的事（**未確認**） | 如果 HAL 停了 IO，就有可能。這是殘留風險，見 §7 與實機 V-H9 |
| 暫停失敗、沒有權限、無法定址 | guard 靜音，持續到原 UID 回來或使用者介入 | 不會 |

#### 2.4.5 每個 App 各自的暫停與驗證期限（審查 medium 3）

```swift
/// internal——測試直接呼叫（同 healthTick）。只處理已到期的項目。
func handoffPlaybackTick() {
    let now = currentInstant()
    registry.refresh()
    for bundleID in holds.keys.sorted() {
        guard var hold = holds[bundleID] else { continue }
        let targetAudible = registry.isGroupAudible(bundleID: bundleID)
        switch hold.pause {
        case .pending where (hold.pauseDue.map { $0 <= now } ?? false):
            hold.pauseDue = nil
            if let skip = HandoffPlaybackPolicy.pauseGate(
                canAddress: playback.canAddress(bundleID: bundleID), targetAudible: targetAudible) {
                hold.pause = skip
            } else {
                hold.pause = HandoffPlaybackPolicy.afterPauseSent(playback.send(.pause, bundleID: bundleID))
                if hold.pause == .requested { hold.verifyDue = now + playbackVerifyDelay }
            }
        case .requested where (hold.verifyDue.map { $0 <= now } ?? false):
            hold.verifyDue = nil
            hold.pause = HandoffPlaybackPolicy.verify(.requested, targetAudible: targetAudible)
        default:
            break // 未到期或已是終態：不動
        }
        holds[bundleID] = hold // 狀態有變就 log notice
    }
    rescheduleHandoffPlayback()
}

/// 取所有 hold 的 pauseDue／verifyDue 中最早的那個排程；沒有就取消。
/// 每次 hold 增減、tick 之後都呼叫——後進來的 hold 不會蓋掉先到期的那個。
private func rescheduleHandoffPlayback() {
    handoffPlaybackTask?.cancel()
    guard let due = nextHandoffPlaybackDue() else { handoffPlaybackTask = nil; return }
    let delay = currentInstant().duration(to: due)
    handoffPlaybackTask = Task { [weak self] in
        try? await Task.sleep(for: max(delay, .zero))
        guard let self, !Task.isCancelled else { return }
        self.handoffPlaybackTick()
    }
}
```

這樣，提早喚醒或多次喚醒都不會讓任何一個 App 提早驗證，因為 tick 只看 App 自己的期限；排程永遠取最早的期限，也不會漏掉。

### 2.5 AppState

不改。`TapEngine` 預設接 Null。Fi 選 (a) 時，才依 §8 在 `AppState.swift:180` 傳入媒體鍵實作。

### 2.6 不動的東西

- 系統預設輸出、虛擬裝置的轉送目標（`AudioDeviceManager.updateVirtualTarget`）
- Lid Guard、keep-awake
- `Localizable.xcstrings`、選單文案、任何 `Text(...)`
- `AppAudioSetting` 與 `SettingsStore` 的 schema
- entitlements、Info.plist
- `MediaKeyInterceptor`、`AppState`

hold 路徑**不寫** `settings.appAudio`。

### 2.7 log

這些是診斷用 log，不進 xcstrings：
- 語音頻段與武裝：§2.4.2
- 進入 hold：`notice("來電接手：\(bundleID) 原本 → \(uid)，\(秒數)s 前出現語音取樣率；靜音等原裝置回來")`
- guard 失敗：`error("來電接手靜音保護失敗：\(bundleID) \(error)；保留現有 tap")`
- 暫停狀態有變化：`notice("來電接手暫停：\(bundleID) \(舊) → \(新)")`
- 延後跟隨：`notice("預設輸出換了但 \(uid) 還在且剛出現語音取樣率：\(bundleID) 先留 \(秒數)s")`
- 結束 hold：§2.4.4

---

## 3. 檔案

| 檔案 | 動作 | 內容 |
|---|---|---|
| `Packages/ChorusCore/Sources/ChorusCore/CallHandoff.swift` | 新增 | §2.1 |
| `Packages/ChorusCore/Tests/ChorusCoreTests/CallHandoffTests.swift` | 新增 | §5.1 |
| `Chorus/Audio/Taps/TapBackend.swift` | 修改 | 新增 `TapSession.nominalSampleRate`；`onDeviceReconfigured` 改成 `(@MainActor (NominalSampleRate?) -> Void)?`；新增 `TapSilencer` 與 `startSilencer` |
| `Chorus/Audio/Taps/CoreAudioTapBackend.swift` | 修改 | `CoreAudioTapSession` 在 init 讀一次名義取樣率，存起來並當作 `cachedSampleRate` 的初值；listener 讀一次並傳出去；新增 `startSilencer` 與 `CoreAudioTapSilencer` |
| `Chorus/Audio/Taps/FakeTapBackend.swift` | 修改 | 見下方 |
| `Chorus/Audio/Taps/TapEngine.swift` | 修改 | §2.4 |
| `Chorus/Audio/Playback/PlaybackControlling.swift` | 新增 | 協定、`NullPlaybackController` |
| `Chorus/Audio/Playback/FakePlaybackController.swift` | 新增 | `#if DEBUG` |
| `Tests/ChorusAppTests/CallHandoffHoldTests.swift` | 新增 | §5.2 |

r1 列的 `AudioProcessRegistry.swift`、`AppState.swift`、`MediaKeyPlaybackController.swift` 在 r2 **移除**，本計畫不碰。

`FakeTapBackend` 只新增成員，既有成員的簽名與行為不變：

```swift
var nominalRates: [String: NominalSampleRate] = [:]           // 沒設＝48000
/// 依序記錄：「play:<bundle>@<uid>」「stop:<bundle>」「silencer+:<bundle>」「silencer-:<bundle>」
private(set) var events: [String] = []
private(set) var startedSilencers: [String] = []
private(set) var liveSilencers: [String: FakeTapSilencer] = [:]
var silencerFailuresRemaining = 0                              // > 0：下一次 startSilencer 丟錯並遞減
var failingPlaythroughOutputs: Set<String> = []                // 對這些 UID 建 playthrough 會丟錯

/// 模擬來源的原生路徑：這個 bundle 目前有沒有被任何 tap 靜音（活著的 playthrough
/// 或活著的 silencer）。沒有 → 原生輸出就是 `defaultOutputUID`；有 → nil。
/// **審查 high 1 的斷言點**：測試要證明這個值在等待期間永遠不是 Screen Output。
func sourceOutput(for bundleID: String) -> String?
/// 從 `events` 重播：自第一次 play 這個 bundle 起，靜音持有者（play +1、stop −1、
/// silencer+ +1、silencer− −1）降到 0 的每個事件索引。空陣列＝從未解除靜音。
func muteGaps(for bundleID: String, since index: Int = 0) -> [Int]
```

- `startPlaythroughSession`：目標在 `failingPlaythroughOutputs` 裡時，丟 `createAggregateFailed(-1)`，而且丟錯前不改任何紀錄。成功時附加 `play:` 事件，把 `nominalRates[uid] ?? 48000` 傳給 session，`label = bundleID`。
- `FakeTapSession`：init 新增 `nominalSampleRate`（預設 48000）與 `label`（預設 nil）。`stop()` 第一次被呼叫且有 label 時附加 `stop:<label>`。`simulateDeviceReconfigured(to rate: NominalSampleRate? = nil)` 保留原本無參數的呼叫方式。
- `FakeTapSilencer`：有 `stopped`；`stop()` 冪等，第一次呼叫時附加 `silencer-:`。

新增檔案之後要跑 `xcodegen generate`（`*.xcodeproj` 不提交）。

**不准碰**：
- `Tests/ChorusAppTests/TapEngineTests.swift`
- `Chorus/Resources/*.xcstrings`
- `Chorus/UI/**`、`Chorus/MediaKeys/**`、`Chorus/App/**`
- `Chorus/Audio/AudioDeviceManager.swift`、`Chorus/Audio/VirtualAudioDriver.swift`、`Chorus/Audio/Taps/AudioProcessRegistry.swift`
- entitlements、Info.plist、`project.yml`
- keep-awake 與 Lid Guard
- `docs/` 底下的其他檔案

---

## 4. 步驟（TDD，每步一個本機 commit）

commit 第一行用 repo 慣例：英文 Conventional Commit，同一行後面接中文。

1. **ChorusCore 型別與政策**：先寫 `CallHandoffTests.swift`，確認紅燈；再寫 `CallHandoff.swift`，到綠燈。commit：`feat: Add call-handoff rate memory and playback policy 功能：新增來電接手取樣率記憶與播放判斷`
2. **backend 接縫**：修改 `TapBackend`、`FakeTapBackend`、`CoreAudioTapBackend`。`TapEngine` 的三個 closure 只改簽名。56 個舊測試必須全綠。commit：`refactor: Carry typed nominal sample rate through tap sessions 重構：tap session 改傳型別化名義取樣率`
3. **播放接縫**：新增 `Chorus/Audio/Playback/` 底下的兩個檔，跑 `xcodegen generate`，然後 build。commit：`feat: Add addressable playback control seam 功能：新增可定址的播放控制接縫`
4. **引擎**：先寫 `CallHandoffHoldTests.swift`，確認紅燈；再改 `TapEngine.swift`（§2.4），到綠燈；接著跑整個 `ChorusAppTests`。commit：`fix: Keep per-app audio silent while a call takes the AirPods 修復：來電帶走耳機時 per-app 音訊維持無聲，原耳機回來再接回`
5. **建置**：Debug 與 Release 的 `xcodebuild build`。確認 Release 沒有引用任何 Fake。
6. **自我檢查**：`git diff 82c8f1aad608bd001f308c2d31758c98f4a408be --stat` 只能出現 §3 的 9 個檔；`Localizable.xcstrings` 如果有變動，就 `git checkout` 還原。
7. **回報**：測試指令與結果、驗收逐條、偏離的地方、§9 的 Fi 答覆狀態。
8. **實機驗證**（§5.5）：交給有核准的驗證者。實作者沒有測試環境時標「未驗證」。

---

## 5. 測試

### 5.1 ChorusCore（`swift test`）

用 `ManualClock.Instant`。

| 測試 | 期待 |
|---|---|
| `NominalSampleRate(hertz:)`：0、負數、`.nan`、`.infinity` | nil |
| `isTelephonyBand` | 8000／16000／24000 → true；11025／22050／32000／44100／48000／96000 → false |
| 記 24000，+14 s 記 48000，再 +14 s 查詢 | true |
| 記 24000，+60.000 s 查詢 | true |
| 記 24000，+60.001 s 查詢 | false |
| 記 24000，+50 s 記 16000，再 +50 s 查詢 | true |
| `expiry` | 最後一次語音頻段 + 60 s；只記過 48000 → nil |
| UID A 有紀錄，查 UID B | false |
| `decide` 表格 | 以下十種情況：(1) hold 中且原 UID 回來 → resume；(2) hold 中、原 UID 不在、預設是另一副耳機 → stayHeld；(3) hold 中且 `homeTelephonyRecent == false` → 仍是 stayHeld；(4) 沒有 hold、home 不在、有語音紀錄 → enterHold；(5) home 不在、沒有語音紀錄 → normal；(6) home 還在、跟隨預設、預設已換、有語音紀錄、延後期限未到 → deferFollow；(7) 同 (6) 但延後期限已到 → normal；(8) 同 (6) 但改成指定路由 → normal；(9) home 還在、預設沒換 → normal；(10) home 為 nil → normal |
| `pauseGate` | `canAddress == false` → `.notAddressable`（不論是否發聲）；可定址但不發聲 → `.userAlreadyPaused`；可定址且發聲 → nil |
| `afterPauseSent` | `.delivered → .requested`；`.unsupported → .notAddressable`；`.failed → .failed` |
| `verify` | `.requested` 且仍發聲 → `.failed`；`.requested` 且已不發聲 → `.confirmed`；其他狀態原樣 |
| `shouldAutoPlay` | 只有 `(.confirmed, canAddressNow: true, targetAudible: false)` 回 true。`.confirmed` 但不能定址 → false；`.confirmed` 但在發聲 → false；其他五種狀態一律 false |

### 5.2 App（`CallHandoffHoldTests.swift`）

**共用設定**：
- `screen = "ChorusAudioDevice_UID"`、`airpods = "94-16-25-48-CC-A9:output"`、`airpods4 = "F8-D3-F0-59-73-BD:output"`、`headsetB = "headset-b"`。
- `availableOutputUIDs = [airpods, headsetB, "BuiltInSpeakerDevice", screen]`，`defaultOutputUID = airpods`。
- registry 用 `injectFake` 注入 Music（1001，發聲）與 Safari（1002，發聲）；helper `setAudible`。
- `TapEngine(…, playback: fakePlayback)`；只有標明「Null」的案例改用三參數 init。
- `rebuildDelay = .seconds(3600)`、`handoffSettleDelay = .seconds(3)`、`pauseSettleDelay = .seconds(1)`、`playbackVerifyDelay = .seconds(2)`。
- 用 `@MainActor final class TestClock` 注入 `currentInstant`。延遲一律以同步呼叫驅動，不靠真實計時器：`audioDevicesChanged()`、`simulateDefaultOutputChange()`，或「推進時鐘後呼叫 `handoffPlaybackTick()`」。真實計時器提早或多次觸發，也只會處理已到期的項目，不影響斷言。
- `fakePlayback.addressable = [Music]`；`onSend` 在 `.pause` 時讓目標不發聲、在 `.play` 時讓目標發聲。
- 每個 hold 案例都在進入等待前記下 `let mark = backend.events.count`，並在每個檢查點斷言 `backend.sourceOutput(for: Music) != screen` 與 `backend.muteGaps(for: Music, since: mark).isEmpty`。下表以「**靜音檢查**」代稱這兩個斷言。
- helper `reproduce1440()`：`setGain(0.5)` → `nominalRates[airpods] = 24000` → `simulateDeviceReconfigured(to: 24000)` → `audioDevicesChanged()` → `nominalRates[airpods] = 48000` → `simulateDeviceReconfigured(to: 48000)` → `audioDevicesChanged()` → 時鐘 +11 s。
- helper `takeAway(defaultFirst:)`：把 airpods 移出清單，`defaultOutputUID = screen`，依參數順序呼叫 `simulateDefaultOutputChange()` 與 `audioDevicesChanged()`。

**hold 與靜音**：

| ID | 測試名 | 步驟 | 期待 |
|---|---|---|---|
| H1 | 來電帶走耳機（先消失再換預設）：全程靜音、不進 Screen Output | `reproduce1440` → `takeAway(defaultFirst: false)` | `heldOutputUID == airpods`；`startedOutputs` 不含 screen 與內建喇叭；`hasMuteGuard`；`setting.outputDeviceUID == nil`；`tappedBundles` 不含 Music；**靜音檢查**（從 24 kHz 第一次出現起） |
| H1b | 14:40:19 的順序（先換預設、裝置還列著） | `reproduce1440` → 預設改成 screen（airpods 仍在清單）→ `simulateDefaultOutputChange()` → 移除 airpods → `audioDevicesChanged()` | 換預設後 `activeOutputUID == airpods`；最後同 H1；每一步都做**靜音檢查** |
| H1c | **重新配置已拆 tap、裝置接著消失**：拆之前已有 guard，消失前後都不漏聲 | `setGain(0.5)`（48 kHz）→ `mark` → `simulateDeviceReconfigured(to: 24000)` → 檢查 → 不重建，直接 `takeAway(defaultFirst: true)`，每個呼叫之後都檢查 | `events` 中 `silencer+:Music` 在 `stop:Music` **之前**；拆完之後 `sourceOutput(for: Music) == nil`；換預設後與清單對帳後都是 nil；最後 `heldOutputUID == airpods`、`startedSilencers.count == 1`；整段 `muteGaps` 為空 |
| H1d | UID 已有語音紀錄，回到 48 kHz 時的重新配置也先建 guard | `reproduce1440` 的前半段（24 kHz 已建）→ `mark` → `simulateDeviceReconfigured(to: 48000)` | `silencer+` 已在（武裝時建立），收掉之後**靜音檢查**通過 |
| H2 | 原耳機回來：先接回路由，再自動播放 Chorus 暫停的 | H1 → 時鐘 +1 s → tick（送暫停）→ +2 s → tick（confirmed）→ 加回 airpods、預設改回 airpods → `audioDevicesChanged()` | 剛好多 1 條 playthrough，建在 airpods；`commands == [(.pause, M), (.play, M)]`，而且 `.play` 送出時 `events` 已含 `play:Music@airpods`；`heldOutputUID == nil`；`lastGain == 0.5`；設定不變 |
| H2b | 回來時預設仍是 screen：仍建回原 UID | 同 H2，但預設保持 screen | playthrough 建在 airpods |
| H2c | 原 UID 回來時語音紀錄已過期：接回後解除武裝 | H2，但回來前時鐘再 +61 s | 接回之後 `hasMuteGuard == false`，`silencer-:Music` 在 `play:Music@airpods` 之後 |
| H3 | 一般拔除（沒有語音取樣率）：退回系統預設 | 只有 48 kHz → `takeAway` | `activeOutputUID == screen`；`startedSilencers.isEmpty`；沒有 hold；`commands.isEmpty` |
| H3b | 指定路由的一般拔除 | `setOutputDevice(airpods)`，只有 48 kHz → 移除 airpods | 和舊測試相同：`activeOutputUID == screen`、`lastTapError != nil`、設定仍是 airpods；沒有 guard |
| H4 | 只有取樣率變化、裝置還在：延遲重建、不 hold；靜音保護在紀錄過期後解除 | `simulateDeviceReconfigured(to: 24000)` → `audioDevicesChanged()`（airpods 還在）→ 時鐘 +60.001 s → `audioDevicesChanged()` | 重建在 airpods；`heldOutputUID == nil`；`commands.isEmpty`；武裝期間有 guard；過期後 `hasMuteGuard == false`；`startedOutputs` 不含 screen |
| H4b | 降噪切換（非語音頻段、沒有紀錄）完全是基線行為 | `simulateDeviceReconfigured(to: 44100)` → `audioDevicesChanged()` | `startedSilencers.isEmpty`；舊 session 立刻 stopped；在 airpods 重建 |
| H5 | 語音紀錄超過 60 s 後的普通消失 | `reproduce1440`，時鐘推到最後一次 24 kHz 後 +60.001 s，先 `audioDevicesChanged()`（解除武裝）→ `takeAway` | `activeOutputUID == screen`；沒有 hold |
| H5b | 剛好 60 s 仍算來電 | 推到 +60.000 s → `takeAway` | 進入 hold，**靜音檢查** |
| H6 | 語音紀錄撐過回到 48000 Hz（約 14 s） | `reproduce1440` → +3 s → `takeAway` | 進入 hold |
| H7 | 等待中使用者指定 screen：結束等待、照新路由、不自動播放 | H1 → `setOutputDevice(screen)` | `heldOutputUID == nil`；playthrough 建在 screen；`play:Music@screen` 在 `silencer-:Music` 之前；沒有 `.play`；設定為 screen |
| H7b | 等待中使用者選「跟隨預設」 | 先 `setOutputDevice(airpods)` 再跑 H1 → `setOutputDevice(nil)` | 結束等待；playthrough 建在目前預設；沒有 `.play` |
| H8 | 預設自動改到別的耳機、內建喇叭或 screen：不結束等待、不播放 | H1 → 依序把預設改成 airpods4、內建喇叭、screen，每次都觸發兩種事件 | 每一步都 `heldOutputUID == airpods`；playthrough 次數不變；`startedSilencers.count == 1`；沒有 `.play`；**靜音檢查** |
| H9 | 重跑對帳冪等 | H1 → `audioDevicesChanged()` ×3、`simulateDefaultOutputChange()` ×2、`setGain(0.3)`、`setMuted` 兩次、tick ×3 → H2 恢復 → 再對帳 ×3、tick ×2 | 等待期間：playthrough 次數不變、`startedSilencers.count == 1`、`.pause` 只送 1 次、**靜音檢查**。恢復後：剛好多 1 條，`.play` 只送 1 次，之後不再增加；`initialGain == 0.3` |
| H10 | 等待中的 App 從全域 tap 排除 | H1 → `updateDeviceProcessing(deviceUID: screen, …)` | `globalExclusions.contains(1001)` |
| H11 | reset、排除、停用會結束等待、收掉 guard、不自動播放 | 三個獨立情境 | `heldOutputUID == nil`；guard stopped；沒有 `.play`；沒有 playthrough 到 screen |
| H12 | **guard 建不起來：不解除靜音、原生路徑不落到 screen** | `silencerFailuresRemaining = 99` → `setGain(0.5)` → `mark` → `simulateDeviceReconfigured(to: 24000)`（武裝失敗、重新配置也無法建 guard）→ `takeAway(defaultFirst: true)` → `audioDevicesChanged()` ×2 | 舊 session **沒有** stopped（`liveSessions[Music]?.stopped == false`）；`heldOutputUID == airpods`；`startedOutputs` 不含 screen；**`sourceOutput(for: Music) == nil`**；`muteGaps` 為空；`lastTapError == nil` |
| H12b | guard 之後建得起來：先建 guard、再收 stale session | 接 H12 → `silencerFailuresRemaining = 0` → `audioDevicesChanged()` | `silencer+:Music` 在 `stop:Music` 之前；仍在 hold；**靜音檢查** |
| H13 | 回來時建 playthrough 失敗：維持 hold、維持 guard、不播放 | H2 的 confirmed 之後 → `failingPlaythroughOutputs = [airpods]` → 加回 airpods | `heldOutputUID == airpods`；guard 存在；沒有 `.play`。清除失敗設定再對帳 → 恢復並播放 |
| H14 | 指定路由到 airpods 的 App：hold、恢復，設定始終不變 | `setOutputDevice(airpods)` → H1 → H2 | 同 H1 加 H2；設定始終為 airpods |
| H15 | 別的 UID 有語音紀錄，不影響這個 UID 的消失 | `nominalRates[airpods4] = 24000` 給另一個 App；Music 在 airpods 上只有 48 kHz → 移除 airpods | Music 退回預設；Music 沒有 guard |
| H16 | 先換預設、原耳機沒消失：寬限之後照常跟隨 | `reproduce1440` → 預設改成 screen（airpods 仍在）→ +3 s → `audioDevicesChanged()` | 第一次留在 airpods；寬限後建在 screen（這時 airpods 還在，屬於使用者或系統的一般換預設）；**注意**：語音紀錄未過期時，搬家要經過 `stopSessionKeepingSilent`，`silencer+` 在 `stop:Music` 之前 |
| N1 | 正式預設（Null）：只有靜音，不暫停也不播放 | 三參數 init → H1 → +1 s tick → H2 的回來步驟 | `handoffPauseState == .notAddressable`；全程沒有指令；回來後 playthrough 建在 airpods；**靜音檢查** |

**播放歸屬（審查 high 2）**：

| ID | 測試名 | 步驟 | 期待 |
|---|---|---|---|
| P1 | Now Playing 不是目標：不送暫停、不播放、只維持無聲 | `addressable = ["com.apple.Safari"]` → H1 → +1 s tick → 回來 | `.notAddressable`；`commands.isEmpty`；**靜音檢查**；回來後沒有 `.play` |
| P2 | 等待中 Now Playing 換人：已暫停也不代按 | `addressable = [Music]` → H1 → tick（送暫停）→ +2 s tick（confirmed）→ `addressable = ["com.apple.Safari"]` → 回來 | `commands == [(.pause, Music)]`；沒有 `.play` |
| P3 | 目標自己停下來：不是 Chorus 暫停的，不送也不播 | H1 → `setAudible(Music, false)` → +1 s tick → 回來 | `.userAlreadyPaused`；`commands.isEmpty` |
| P3b | 送出暫停後目標仍在發聲：視為失敗，不播 | `onSend = nil` → H1 → tick → +2 s tick | `.failed`；回來後沒有 `.play`；**靜音檢查** |
| P3c | 等待中使用者自己按了播放：不代按 | H2 的 confirmed 之後 → `setAudible(Music, true)` → 回來 | 沒有 `.play` |
| P4 | 驗證到期前就回來：就地驗證後才決定 | H1 → +1 s tick（requested）→ 立刻回來 | 就地得到 confirmed，送 `.play` |

**期限（審查 medium 3）**：

| ID | 測試名 | 步驟 | 期待 |
|---|---|---|---|
| D1 | 兩個 App 先後進入 hold：後進來的不讓先進來的提早驗證 | `addressable = [Music, Safari]`。Music 在 airpods、Safari 指定 headsetB。t0：Music 進入 hold（airpods 語音頻段後消失）。t0+1：tick → Music `.requested`，verifyDue = t0+3。t0+1.5：讓 headsetB 出現語音頻段並消失 → Safari 進入 hold，pauseDue = t0+2.5。t0+2.5：tick | t0+2.5 的 tick 之後：Safari `.requested`；**Music 仍是 `.requested`**（期限 t0+3 未到）。t0+3 tick → Music `.confirmed`、Safari 仍 `.requested`。t0+4.5 tick → Safari `.confirmed` |
| D2 | 排程取最早的期限 | 接 D1 的各時點 | Safari 進入 hold 後，`nextHandoffPlaybackDue() == t0+2.5`；t0+2.5 tick 之後 `== t0+3`（不是 t0+4.5）；兩者都結束後為 nil |

### 5.3 必須保持全綠的舊測試（一行不改）

`TapEngineTests.swift` 的 56 個測試全部都要通過。它們不受影響的機制：fake 一律回報 48000，不會留下語音紀錄；三參數 init 拿到的是 Null；沒有語音紀錄的重新配置走基線的 `stopSession`。任何一個舊測試變紅，都是修實作，不是修預期值。

### 5.4 指令

```sh
{ swift test --package-path Packages/ChorusCore ; } 2>&1 | xcsift -f toon -w -E
xcodegen generate
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests/CallHandoffHoldTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild build -scheme Chorus -destination platform=macOS -configuration Release ; } 2>&1 | xcsift -f toon -w -E
```

以 TOON 輸出的 `status:` 為準。

### 5.5 實機驗證（交給有核准的驗證者；實作者標「未驗證」）

| ID | 步驟 | 通過條件 |
|---|---|---|
| V-G1 | 用 AirPods 播 Podcast（gain ≠ 1）。在 Mac 上用 FaceTime 撥一通測試電話製造語音頻段，然後掛斷，裝置不移除 | 語音頻段出現時 log 有「武裝靜音保護」；guard 存在期間，Podcast 仍然從 AirPods 出聲（A6）。不通過時改用延後武裝 |
| V-H1 | 重現 14:40：iPhone 來電、在 iPhone 接聽 | **沒有**出現「per-app session 建立：com.apple.podcasts → ChorusAudioDevice_UID」；螢幕喇叭與內建喇叭整段都沒有 Podcast 的聲音；log 有「來電接手」 |
| V-H2 | 承 V-H1，確認 guard 本身有效（A5） | 進度在走，Mac 上任何輸出都沒有聲音。不通過時改用 fallback B |
| V-H3 | 掛斷，AirPods 回到 Mac | Podcast 從 AirPods 出聲，音量與 EQ 和之前一樣（Null 版：Podcast 一直在播，接回就聽得到） |
| V-H5 | 一般拔除（收進盒子） | 和 13:58 一樣退回預設 |
| V-H6 | 只切換降噪 | 延遲重建；沒有武裝的 log |
| V-H7 | 等待中接上 AirPods4 | 仍然無聲 |
| V-H8 | 等待中指定 Screen Output | 等待結束，從螢幕出聲 |
| V-H9 | 量測殘留風險：重現 V-H1，同時錄下 Screen Output 的輸出（例如用 Chorus 的診斷或 QuickTime 錄螢幕喇叭） | 14:40:19 前後沒有可聽見的片段。有的話回報時間長度，交給 Fi 判斷 |

---

## 6. 驗收條件

- [ ] **正常 hold**：出現語音頻段後原 UID 消失 → 進入 hold；playthrough 不會建到 `ChorusAudioDevice_UID` 或其他輸出；**原生路徑也不落到 screen**；設定不變。（H1、H1b、H6、N1；V-H1）
- [ ] **重新配置空窗已關閉**：有語音紀錄時，先建 guard 才收 tap；收掉之後到重建或 hold 之間不漏聲。（H1c、H1d）
- [ ] **guard 失敗不解除靜音**：guard 建不起來時，保留現有 tap，`sourceOutput` 不落到 screen；guard 之後建得起來，就先建 guard 再收。（H12、H12b）
- [ ] **原 UID 回來就恢復**：剛好建 1 條 playthrough 回原 UID；不改寫 `outputDeviceUID`；語音紀錄過期後解除 guard。（H2、H2b、H2c、H14；V-H3）
- [ ] **只播放可歸屬的**：要同時滿足「能定址」、「已送達」、「已驗證」、「回來時仍能定址」、「回來時不在發聲」才自動播放。Now Playing 不是目標、等待中 Now Playing 換人、目標自己停下、暫停沒生效、使用者自己按了播放，都不播。（P1、P2、P3、P3b、P3c、P4）
- [ ] **正式版不送無法歸屬的指令**：在 Fi 回答 §9 之前，正式版接 Null，不送任何指令，只維持無聲。（N1）
- [ ] **一般拔除仍退回預設**。（H3、H3b、H15；舊測試；V-H5）
- [ ] **只有取樣率變化時不 hold**：延遲重建；降噪切換完全是基線行為。（H4、H4b；舊測試；V-H6）
- [ ] **逾時窗口**：60 s 整仍算來電，60.001 s 退回預設。（H5、H5b）
- [ ] **使用者改路由會結束 hold**，並且不自動播放。（H7、H7b；V-H8）
- [ ] **另一個 UID 成為預設不會結束 hold**，也不播放。（H8；V-H7）
- [ ] **重跑對帳冪等**。（H9）
- [ ] **全域 tap 不漏**。（H10）
- [ ] **使用者動作會結束 hold**。（H11）
- [ ] **期限依 App 分開**：後進入 hold 的 App 不讓先進入的提早驗證，排程取最早的期限。（D1、D2）
- [ ] **取樣率型別化**：`kAudioDevicePropertyNominalSampleRate` 只出現在 `CoreAudioTapBackend.swift`。
- [ ] **舊測試**：56 個全綠，`git diff 82c8f1aad608bd001f308c2d31758c98f4a408be -- Tests/ChorusAppTests/TapEngineTests.swift` 為空。
- [ ] **範圍**：只動 §3 的 9 個檔。
- [ ] **建置**：Debug 與 Release 都是 `status: success`，沒有新的警告。

---

## 7. 風險

| 風險 | 影響 | 對策 |
|---|---|---|
| A5 不成立 | guard 沒有靜音效果 | V-H2；fallback B；都不成立就 escalate |
| A6 不成立（guard 讓 playthrough 也收不到聲音） | 語音紀錄期間（最長 60 s）播放無聲 | V-G1；改用延後武裝，代價是下一列的空窗 |
| HAL 在 Chorus 反應前就移除裝置，playthrough 的 IO 停止，`.mutedWhenTapped` 解除靜音 | 預先武裝失敗或改用延後武裝時，可能從 Screen Output 漏出幾十毫秒 | 預先武裝（主方案）可以關掉這個空窗；V-H9 量測。程式碼這一層無法再進一步保證 |
| guard 失敗而且原 UID 已消失 | 保留下來的 playthrough 若被 HAL 停掉，就會漏聲 | 重試 guard；log error；V-H9 |
| 語音頻段的重新配置在 1.5 s 重建期間無聲 | 刻意的行為變化（§2.4.3） | 只在有語音紀錄時發生 |
| Mac 自己通話後 60 s 內拔掉 AirPods | 被當成來電接手，維持無聲到原耳機回來 | 決策已接受 |
| 決策要求的「暫停、自動播放」在正式版做不到 | Podcast 在等待期間繼續播放（聽不到），使用者會錯過內容 | §9 Fi 問題 1 |
| 指定路由的 App 顯示既有的橘字 | 文字意思不準確 | A10，列為後續 UI 任務 |

---

## 8. 不在範圍內，以及 Fi 選 (a) 時的設計

不在範圍內：Music.app 的 AppleScript 路徑；MediaRemote；hold 期間的 UI；跨 App 重啟保留 hold。

**如果 Fi 選 (a)（接受媒體鍵可能打錯 App）**，另開一個小任務：
- 新增 `Chorus/Audio/Playback/MediaKeyPlaybackController.swift`。`send` 透過 `NSEvent.otherEvent(.systemDefined, subtype: 8, data1: (16 << 16) | (0xA/0xB << 8))` 加上 `cgEvent.post(tap: .cghidEventTap)` 送出播放／暫停鍵；`CGPreflightPostEventAccess()` 為 false 時回 `.unsupported`。
- `canAddress` 的定義由 Fi 的接受範圍決定。建議是「目標正在發聲，而且沒有別的 App 在發聲」（需要 `AudioProcessRegistry.isOtherAppAudible(than:)`）。這**不是**真正的定址，接縫契約要在那個任務裡明文放寬。
- `AppState.swift:180` 傳入這個實作（`--fake-taps` 時傳 Null）。
- 測試 P1–P3 的期待值要跟著 Fi 接受的範圍重寫。

---

## 9. 給拍板者（Fi）的問題

**問題 1：沒有公開 API 能確定暫停或播放的對象，要怎麼處理「暫停、回來自動播放」？**

背景：Podcasts 不支援 AppleScript（§0.2）。媒體鍵是切換鍵，作用在系統的 Now Playing App，不看 bundle。即使目標是唯一正在發聲的 App，Now Playing 也可能是另一個已暫停的 App。回來時所有 App 都沒有聲音，更無法確定播放鍵會打到誰。發聲轉為靜默，也不能證明是 Chorus 暫停的。

- **(a)** 接受媒體鍵可能打錯 App。只在「目標正在發聲、而且沒有別的 App 在發聲」時送暫停；回來時只在「確認暫停過、目前沒有任何 App 在發聲」時送播放。風險是可能讓另一個已暫停的 App 開始播放，或把別的 App 暫停。
- **(b)** 無法確認目標時，只維持無聲，不暫停也不自動播放。這是本計畫目前的正式行為。風險是 Podcast 在通話期間繼續播放（聽不到），使用者回來會錯過一段內容。
- **(c)** 另開任務評估私有的 MediaRemote（能查詢 Now Playing 的 bundle，也能定址）。macOS 15.4 之後已限制第三方使用，本機 macOS 27 的狀況**未確認**；採用還需要核准私有 API。本計畫不採用。

**建議**：先出 (b)，它保證不進 Screen Output，也不會誤操作別的 App。同時另開 (c) 的評估任務；如果評估結果可行，再把它接到同一個 `PlaybackControlling` 接縫上（可定址的實作，P1–P3 的期待值不用改）。只有在可以接受偶爾打錯 App 的情況下，才考慮 (a)。
