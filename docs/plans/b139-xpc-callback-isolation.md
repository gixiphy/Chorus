# b139 計畫：XPC 回呼的 MainActor 隔離 crash（RealPowerHelperXPCProxy）

- 基準：worktree `chorus-keepawake`，HEAD `c2b47d6`（1.15.3 build 138）
- 目標：build 139
- 撰寫：Claude（只有計畫，沒改程式，沒 commit），2026-10-13
- 風險等級：**高**。這次會動到 App 端的 helper client，也就是 XPC 呼叫、逾時，以及只 reply 一次的語意。**合併前需要 Claude 與 Codex 各自審查並通過**（見 §7）。

---

## 0. 事實與根因

**現象**：在 M1 上，b138 一啟動就 `EXC_BREAKPOINT`。

```
_dispatch_assert_queue_fail
← swift_task_isCurrentExecutor
← closure #1 in RealPowerHelperXPCProxy.status(reply:)   (PowerHelperClient.swift:1313)
← __NSXPCCONNECTION_IS_CALLING_OUT_TO_ERROR_BLOCK__      (背景 XPC queue)
```

**根因**：
1. `RealPowerHelperXPCProxy` 與 `PowerHelperXPCProxying` 都標了 `@MainActor`。在 MainActor 方法或 init 裡寫的 closure literal，如果沒有標 `@Sendable`，在 Swift 6 會被推斷為 **MainActor 隔離**。
2. 這種 closure 直接交給 ObjC API 時，編譯器會在 closure 的 prologue 插入執行期隔離檢查（`swift_task_isCurrentExecutor` → `dispatch_assert_queue`）。
3. NSXPCConnection 在自己的私有背景 queue 呼叫這個 block，檢查失敗就 trap。

**SDK 已確認**（`Foundation.framework/Headers/NSXPCConnection.h`，macOS 27 SDK）：

| API | 標註 | Swift 端的型別 |
|---|---|---|
| `NSXPCProxyCreating` 協定的 `remoteObjectProxyWithErrorHandler:`（第 36 行） | 有 `NS_SWIFT_SENDABLE` | `@Sendable` |
| **`NSXPCConnection` 本身**的 `remoteObjectProxyWithErrorHandler:`（第 97 行） | **沒有** `NS_SWIFT_SENDABLE` | 非 Sendable |
| `interruptionHandler`（第 107 行） | **沒有** | 非 Sendable |
| `invalidationHandler`（第 112 行） | **沒有** | 非 Sendable |

在 `NSXPCConnection` 上直接呼叫時，用的是第 97 行的非 Sendable 版本。

**觸發條件**：
1. SMAppService 回報 `.enabled`，但 helper 已被 `launchctl bootout`、尚未核准，或 launchd job 不存在。
2. 這時 `LidSleepGuardController.performRefreshHelper(.launch)` 走到 `.connecting`，接著是 `runHelperHandshake`、`readHelperEvidence`，最後是 `PowerHelperClient.status()`。
3. 對 helper 發出的 XPC 訊息失敗，觸發 error block，在背景 queue 執行，於是 trap。

**未確認**：
- b136／b137 為什麼沒有觸發（可能是啟動路徑的時序，或 helper 一直在跑）。這不影響修法。
- interruption 與 invalidation 兩個 handler 依同一機制推論也會 trap，但還沒有實機 crash log 佐證。

---

## 1. 審查：所有 XPC 與跨 queue 回呼

範圍：
- `grep NSXPCConnection|remoteObjectProxy|interruptionHandler|invalidationHandler|SMAppService|errorHandler`
- 範圍內的 XPC client 只有 `Chorus/Display/PowerHelperClient.swift`。
- `SettingsView.swift`（`SMAppService.mainApp`）、`LidSleepGuardController.swift`、ChorusCore 的 `LidSleepGuard.swift` 只是同步呼叫或註解，**沒有** XPC 回呼。
- Automation（`AutomationHTTPTransport`）沒有 XPC，它的 `DispatchSource` handler 不在這次範圍內（見 §1.3）。

### 1.1 會 trap 的位置（必修）

| # | 位置 | 回呼 | 誰呼叫、在哪個 queue | 判定 |
|---|---|---|---|---|
| T1 | `PowerHelperClient.swift:1313` `status(reply:)` | `remoteObjectProxyWithErrorHandler { _ in reply(Data()) }` | XPC error block，背景 queue | **已實機 crash** |
| T2 | `:1302` `setSleepDisabled(_:reply:)` | `remoteObjectProxyWithErrorHandler { error in reply(nil, …) }` | XPC error block，背景 queue | 寫法與 T1 相同，**必 trap** |
| T3 | `:1287` init | `connection.invalidationHandler = { [weak self] in Task { @MainActor … } }` | XPC 背景 queue | 外層 closure 本身就是 MainActor 隔離，裡面的 `Task { @MainActor }` 來不及救，prologue 就先 trap 了。**高機率 trap**（未實機） |
| T4 | `:1292` init | `connection.interruptionHandler = { … }` | 同 T3 | 同 T3 |

補充：
- T3 與 T4 現有的註解寫著 `C8-1: NSXPC handlers fire off MainActor — hop first`。意圖正確，但 hop 寫在 closure **裡面**，隔離檢查發生在 closure **進入時**，所以沒有效果。
- `invalidate()` 先把 handler 清成 nil 再 invalidate，所以主動拆線不會觸發 T3／T4。helper 被 bootout，或連線被系統 invalidate 時，就會觸發。

### 1.2 潛在風險位置（同批加固，不改語意）

這幾處是 MainActor 環境裡的 closure literal，經過 **Swift 函式參數**轉手後，才在背景被呼叫。

現有測試 `C8-1 off-actor status reply resumes safely on MainActor`（`PowerHelperClientTests.swift:339`）從 `DispatchQueue.global` 呼叫 reply，結果通過。這代表目前的編譯器沒有在純 Swift 參數的 closure 插入檢查，但這是**實作細節，不是保證**（未確認，會隨編譯器版本改變）。所以一律改成 `@Sendable`，讓它們明確不隔離。

| # | 位置 | 內容 |
|---|---|---|
| L1 | `:841` `setSleepDisabled` 交給 `proxy.setSleepDisabled` 的 reply literal | 呼叫 `continuation(...)` |
| L2 | `:863` `status()` 交給 `proxy.status` 的 reply literal | 呼叫 `continuation(.success)` |
| L3 | `:1051` `withTimeout` 交給 `body` 的 `{ result in Task { @MainActor … } }` | 外層 closure 會在 XPC queue 執行 |
| L4 | `:938` `setSleepDisabledSynchronously` 的 `{ _, error in box.setOK; sem.signal() }` | **一定**在背景執行，因為 MainActor 正卡在 `sem.wait` |
| L5 | `:1309` 與 `:1320` 把 `reply` 直接轉交給 `ChorusPowerHelperXPC` | 一旦 reply 型別改為 `@Sendable` 就安全。`ChorusPowerHelperXPC` 協定不用改（`@Sendable` 可以隱式轉成非 Sendable 參數） |
| L6 | `:958` `ensureProxy` 的 `onConnectionEvent = { [weak self] event in Task { @MainActor … } }` | 正式環境由 T3／T4 hop 回 MainActor 後才呼叫，所以安全。測試 `offActorConnectionEvent` 會從 global queue 呼叫它，目前同樣靠「純 Swift 參數不檢查」。型別改成 `@Sendable` |

### 1.3 不在範圍內、不修，只記錄

- **`PowerHelper/`（helper 本體）**：`PowerHelperService`、`main.swift` 的 `NSXPCListener` 與 exported object 沒有 `@MainActor`，不受影響。依指示**不動**。pmset 程式也不動。
- **`ChorusCore/PowerHelperXPC.swift`** 的 `ChorusPowerHelperXPC`：**不改**。改了 helper 的 conformance 簽名也要跟著改，會碰到 helper。
- **App 內其他 ObjC 回呼**：`Process.terminationHandler`（`VirtualAudioDriver`、`HeadsetBatteryMonitor`、`AlertVolumeController`、`CLIAdviceProvider`）、`DispatchSource.setEventHandler`（`MemoryPressureMonitor`、`MainLoopWatchdog`、`AutomationHTTPTransport`）、`NotificationCenter`（`queue: .main`）、`IOServiceAddInterestNotification`（`LidStateMonitor`）。
  - 這些在 b136 以前就存在，目前沒有 crash 報告。
  - Foundation overlay 的 `terminationHandler` 與 `setEventHandler` 型別本來就是 `@Sendable`，**但沒有逐一確認**。
  - 建議另開題目，用同樣的 grep 加 SDK 標註清單做稽核。**b139 不修**，以控制變更面。

---

## 2. 修法

原則：
- 回呼型別一律改成 `@Sendable`。
- closure literal 明確寫 `{ @Sendable … in }`，讓它不繼承 MainActor。
- 在碰到 MainActor 狀態**之前**明確 hop，用 `Task { @MainActor in }`。
- 保留 `withTimeout`／`ReplyGate` 與 `ReplyBox` 的語意。
- 不改 public 行為、錯誤碼、逾時數值。

### 2.1 `PowerHelperXPCProxying`（protocol）

```swift
@MainActor
protocol PowerHelperXPCProxying: AnyObject {
    func setSleepDisabled(_ enabled: Bool, reply: @escaping @Sendable (Data?, String?) -> Void)
    func status(reply: @escaping @Sendable (Data) -> Void)
    var onConnectionEvent: (@Sendable (PowerHelperConnectionEvent) -> Void)? { get set }
    func invalidate()
}
```

- 方法本身維持 MainActor，因為呼叫端都在 MainActor 上。**只有回呼型別改成 `@Sendable`。**
- `onConnectionEvent` 用 `@Sendable`，不用 `@MainActor`，理由有兩個：
  - 保留「可以從任何 queue 呼叫，內部自行 hop」的現有語意。
  - 現有測試 `offActorConnectionEvent` 可以照常編譯。

### 2.2 `RealPowerHelperXPCProxy`

```swift
// T3/T4: handler 本身必須 nonisolated；hop 寫在裡面
connection.invalidationHandler = { @Sendable [weak self] in
    Task { @MainActor in self?.onConnectionEvent?(.invalidated) }
}
connection.interruptionHandler = { @Sendable [weak self] in
    Task { @MainActor in self?.onConnectionEvent?(.interrupted) }
}

func setSleepDisabled(_ enabled: Bool, reply: @escaping @Sendable (Data?, String?) -> Void) {
    let once = OneShotReply2(reply)                       // 每次呼叫一個 gate
    let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in   // T2
        once.fire(nil, "xpc:\(error.localizedDescription)")
    }
    guard let helper = proxy as? ChorusPowerHelperXPC else { once.fire(nil, "badProxy"); return }
    helper.setSleepDisabled(enabled) { @Sendable data, code in once.fire(data, code) }
}

func status(reply: @escaping @Sendable (Data) -> Void) {
    let once = OneShotReply1(reply)
    let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.fire(Data()) }  // T1
    guard let helper = proxy as? ChorusPowerHelperXPC else { once.fire(Data()); return }
    helper.status { @Sendable data in once.fire(data) }
}
```

**只 reply 一次的保證**：
- NSXPC 文件說，同一則訊息只會呼叫 reply 或 error handler 其中一個。
- 但 error handler 是掛在 proxy 物件上的，加上還有 `badProxy` 這條早退路徑，所以在 proxy 這層多加一道**每次呼叫一個的 one-shot gate**，沿用 `ReplyGate`（以 `NSLock` 保護，`@unchecked Sendable`）。
- 下游的 `withTimeout`/`ReplyGate` 仍然保證 continuation 只 resume 一次。兩層互不衝突。
- 對 `setSleepDisabledSynchronously` 來說，這層 gate 可以避免 `sem.signal()` 被呼叫兩次。實作上也可以只寫一個泛型 `OneShot<Args>`。名稱由實作者決定，但**不可以**用 `@MainActor`。

**`[weak self]` 的捕獲**：
- `RealPowerHelperXPCProxy` 是 `@MainActor final class`，因此是 Sendable，可以用 `weak` 捕獲進 `@Sendable` closure。
- 在 `@MainActor` 的 `Task` 裡讀取 `self?.onConnectionEvent` 合法。

**測試 seam**（為了 §3 的真實 NSXPC 測試）：

新增 `#if DEBUG` 才存在的 `init(testConnection: NSXPCConnection)`。這個 init 會：
- 設定 `remoteObjectInterface`。
- **不設**定 code signing requirement。
- 掛上同樣的 handler，然後 `resume()`。

正式環境的 `init(machServiceName:requirement:)` 不變，仍然固定使用 `.privileged`，並呼叫 `setCodeSigningRequirement`。兩個 init 共用 handler 的安裝函式，避免測到的程式與正式程式分岔。

> 安全界線（spec §11）：Release build 不包含這個 init（`#if DEBUG`），也沒有任何執行期開關，所以雙向簽章驗證不受影響。審查時要逐條確認。

### 2.3 `PowerHelperClient`

| 位置 | 修改 |
|---|---|
| `withTimeout`（L3） | 參數型別改為 `_ body: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void`。內層寫成 `{ @Sendable result in Task { @MainActor in guard gate.claim() else { return }; continuation.resume(with: result) } }`。逾時 Task 不變。`ReplyGate` 語意不變 |
| `setSleepDisabled`（L1） | `proxy.setSleepDisabled(on) { @Sendable statusJSON, errorCode in … continuation(...) }`。只用到參數與 `continuation`，沒有碰 self |
| `status()`（L2） | `proxy.status { @Sendable statusJSON in continuation(.success(statusJSON)) }` |
| `setSleepDisabledSynchronously`（L4） | `{ @Sendable _, error in box.setOK(error == nil); sem.signal() }`。**不可以** hop 到 MainActor，否則會跟 `sem.wait` 死結。現有 C8-1 的註解保留 |
| `ensureProxy`（L6） | `created.onConnectionEvent = { @Sendable [weak self] event in Task { @MainActor in self?.handleConnectionEvent(event, token: token, proxy: created) } }`。`token` 是 `UInt64`；`created` 是 MainActor 類別實例，屬於 Sendable |

**不改的部分**：
- generation、connectionToken、readinessEpoch 的檢查。
- 逾時數值。
- 錯誤 enum。
- `PowerHelperClienting` protocol。
- `LidSleepGuardController`。

### 2.4 測試替身 `FakePowerHelperProxy`（`Tests/ChorusAppTests/PowerHelperClientTests.swift`）

- `setHandler` 與 `statusHandler` 的型別改成 `@Sendable` reply。
- 方法簽名要跟 protocol 一致。
- 現有的 closure 主體不需要改；`DispatchQueue.global().async { reply(...) }` 在改為 `@Sendable` 之後反而更正確。

---

## 3. 測試

建立新 Suite：`@Suite("B139 XPC callback isolation")`，放在新檔 `Tests/ChorusAppTests/PowerHelperXPCIsolationTests.swift`。每個測試都加 `.timeLimit(.minutes(1))`。

### 3.1 回呼在背景 queue 觸發（核心）

| ID | 內容 | 修前 | 修後 |
|---|---|---|---|
| X1 | **真實 NSXPC，error 路徑**：用 `NSXPCListener.anonymous()` 在本程序建立 listener，取得 `endpoint`，接著 `listener.invalidate()`。再以 `NSXPCConnection(listenerEndpoint:)` 和 `RealPowerHelperXPCProxy(testConnection:)` 呼叫 `status(reply:)`，error block 會在 XPC 私有 queue 觸發 | trap（T1） | reply 收到 `Data()`；在 reply 裡記錄 `Thread.isMainThread == false`；`Mutex` 計數為 1 |
| X2 | 同 X1，改呼叫 `setSleepDisabled(true, reply:)` | trap（T2） | 收到 `(nil, "xpc:…")`，計數為 1 |
| X3 | **真實 NSXPC，reply 路徑**：anonymous listener 存活，exported object 是測試用的 `ChorusPowerHelperXPC` 實作，在 `DispatchQueue.global` 回 status JSON 與 set JSON | 這條預期不 trap（reply literal 走 Swift 參數），作為回歸防護 | 收到正確 JSON，不在 main，計數為 1 |
| X4 | **真實 NSXPC，invalidation**：listener 存活，連線成功後，由 listener 端的 `shouldAcceptNewConnection` 保存並 `invalidate()` 對端連線，或直接 invalidate listener 後再送一則訊息。client 端的 `invalidationHandler` 會在背景觸發 | trap（T3） | `onConnectionEvent` 收到 `.invalidated`，且收到時位在 MainActor（用 `MainActor.assertIsolated()`） |
| X5 | **PowerHelperClient 加上真實 proxy，helper 不可用**：`PowerHelperClient(makeProxy: { RealPowerHelperXPCProxy(testConnection: dead) }, serviceStatus: { .enabled }, callTimeout: 1)`，接著 `refreshAvailability(.launch)` 再 `status()` | trap | 拋出 `decodingFailed`（空 Data）或 `timedOut`，**不 crash**；`availability` 不是 `.ready` |
| X6 | 同 X5，改走 `setSleepDisabledSynchronously(false, timeout: 0.5)`（關機路徑，MainActor 正被 semaphore 卡住） | trap 或 0.5 秒後逾時 | 回傳 `false`，耗時小於 1 秒，不 crash |
| X7 | **Fake 從背景 queue 呼叫 reply 兩次**（先 reply，再模擬 error 再 reply 一次） | — | `withTimeout` 只 resume 一次，`status()` 正常回傳。驗證 `ReplyGate` 語意保留 |

**interruptionHandler（T4）**：只有在遠端行程死掉時才會觸發，同一個程序內的 anonymous listener 無法可靠地造出來。這一項以「與 T3 同一個 helper 函式安裝」作為結構保證，並交給雙審逐行確認。手動驗收見 §5 的 M2。**它沒有自動化測試，這點會明確寫進 handoff。**

**X1／X4 的 fallback**：如果 anonymous listener 在 hosted test 環境裡沒辦法讓 error block 在背景觸發（未確認），改用 `NSXPCConnection(machServiceName: "com.hermes.Chorus.b139test.\(UUID())", options: [])`，查詢不存在的 service 會被 invalidate。這兩個做法**都不需要 root，也不碰真的 helper**。

### 3.2 怎麼安全驗證「修前會 trap」

trap 會讓整個 test host 行程結束，所以不能混在全套測試裡驗證。步驟：

1. **紅燈：先寫測試，不改產品碼。**
   - 例外：seam `init(testConnection:)` 必須先加，否則測試無法編譯。這個 seam 只是包一層 init，不碰 handler 的隔離。
   - 只跑新的 Suite：
     ```
     { xcodebuild test -scheme Chorus -only-testing:ChorusAppTests/PowerHelperXPCIsolationTests ; } 2>&1 | xcsift -f toon -w -E
     ```
   - 預期 X1、X2、X4、X5、X6 讓 runner 出現 crash，xcresult 會顯示 crashed／restarted。
   - 到 `~/Library/Logs/DiagnosticReports/` 取最新的 `xctest`／`Chorus` `.ips`，確認堆疊含有 `_dispatch_assert_queue_fail ← swift_task_isCurrentExecutor ← closure #1 in RealPowerHelperXPCProxy…`。
   - 把檔名與關鍵幾行貼進 handoff。
   - 可以逐一用 `-only-testing:…/X1` 跑，避免一個 crash 吃掉其他案例。
2. **可選：用 exit test 把「會 trap」寫成常駐的反向測試**（Swift Testing 的 `#expect(processExitsWith: .failure) { … }`，Swift 6.2 以上支援 macOS）。
   - App-hosted 的測試 target 是否支援 exit test：**未確認**。
   - 先花至多 15 分鐘試做；不支援就放棄，只留步驟 1 的紀錄。
   - 不要因為這件事去改測試 target 的設定。
3. **綠燈**：套用 §2 的修改後，先跑新 Suite，再跑全套。

### 3.3 App 啟動時 helper 不可用不會 crash

| ID | 內容 |
|---|---|
| S1 | `LidSleepGuardControllerTests` 新增一個測試：用 `LidSleepGuardController(settings:…, helper: PowerHelperClient(makeProxy: { RealPowerHelperXPCProxy(testConnection: dead) }, serviceStatus: { .enabled }, callTimeout: 1), …)` 模擬 SM 顯示 enabled、但 helper 已被 bootout。接著 `await refreshHelperAvailabilityAsync(reason: .launch)`，等到交握失敗並排入 retry。**斷言**：行程存活；`helper.availability` 不是 `.ready`；沒有 acquire 呼叫；有排入 evidence retry（沿用該檔現有的觀察方式） |
| S2 | 同 S1，但 SM 為 `.requiresApproval`。斷言不會發出任何 XPC（`makeProxy` 的呼叫次數為 0），且沒有 crash |

`LidSleepGuardControllerTests` 現有的 fake helper 是 `PowerHelperClienting` 層的替身，碰不到 `RealPowerHelperXPCProxy`。所以 S1 必須用真的 `PowerHelperClient`，加上真的 proxy 與一條死連線。

---

## 4. 檔案清單

| 檔案 | 變更 |
|---|---|
| `Chorus/Display/PowerHelperClient.swift` | §2.1 到 §2.3：protocol 回呼改 `@Sendable`；Real proxy 的 4 個 handler；one-shot gate；`#if DEBUG` 的 `init(testConnection:)`；`withTimeout` 等 4 處 literal |
| `Tests/ChorusAppTests/PowerHelperClientTests.swift` | 只改 `FakePowerHelperProxy` 的簽名與 handler 型別（§2.4），再加上 X7 |
| `Tests/ChorusAppTests/PowerHelperXPCIsolationTests.swift`（新檔） | X1 到 X6，以及測試用的 exported object |
| `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift` | S1、S2 |
| `project.yml`／`xcodegen generate` | `sources` 用目錄收檔的話不需要改 yml，但新增檔案後要執行 `xcodegen generate`（AGENTS.md）。`*.xcodeproj` 不提交 |
| `docs/plans/keepawake-handoff.md` | 新增 `## B139` 段落 |
| build bump（另開 commit） | 照既有慣例（`chore(build): bump to … build 139`）。是否由實作者處理，由 Fi 決定 |

**不可以動**：
- `PowerHelper/**`（helper 本體）
- pmset 相關程式
- `Packages/ChorusCore/**`，包括 `ChorusPowerHelperXPC`
- `LidSleepGuardController.swift` 的產品碼
- `Localizable.xcstrings`
- `scripts/release.sh`

---

## 5. 步驟

1. 讀 spec §6.4、§6.5、§11、§14.2，以及本計畫。
2. 加上 `#if DEBUG` 的 `init(testConnection:)`，並把 handler 安裝抽成共用函式，**隔離寫法保持不變**。
3. 寫 X1 到 X7 與 S1、S2。依 §3.2 跑紅燈，蒐集 crash 證據（`.ips` 堆疊）。exit test 的 spike 可選做，上限 15 分鐘。
4. 套用 §2.1 到 §2.4。
5. `xcodegen generate`，執行 build：
   ```
   { xcodebuild build -scheme Chorus ; } 2>&1 | xcsift -f toon -w -E
   ```
   要求 0 個新增 warning，特別是 concurrency 類。
6. 跑全套綠燈（§6）。flaky 的處理照 merge fix1 的慣例：重跑 3 次，附證據。
7. 自己 review diff：
   - `grep -n "remoteObjectProxyWithErrorHandler\|invalidationHandler\|interruptionHandler" Chorus` 列出的每一處都是 `@Sendable` literal。
   - Release 設定下 `init(testConnection:)` 不存在。用 `xcodebuild -configuration Release build` 編譯，或靠 `#if DEBUG` 的編譯錯誤驗證。
8. 寫 handoff 的 `## B139`，然後送 Claude 與 Codex 雙審（§7）。
9. 手動驗收（需要 Fi 或核准過的驗證者，本機，不發布）：
   - **M1**：在 M1 上裝 b139 dev build。`sudo launchctl bootout system/<helper label>` **由 Fi 執行**（agent 不碰 sudo）。啟動 App：不 crash，Lid Guard 顯示 helper 不可用或重試中。
   - **M2**：App 執行中再 bootout 一次，觸發 interruption／invalidation：不 crash，狀態退回 connecting。
   - **M3**：重新 bootstrap 並核准後，交握回到 ready，闔蓋持有正常。
   - 跑完要確認 `pmset -g` 中的 SleepDisabled 已經還原。

---

## 6. 驗收

- [ ] Core：`{ swift test --package-path Packages/ChorusCore ; } 2>&1 | xcsift -f toon -w -E`，**843** 全綠（Core 沒有改，數字應該不變）
- [ ] App：`{ xcodebuild test -scheme Chorus -only-testing:ChorusAppTests ; } 2>&1 | xcsift -f toon -w -E`，**674 加上新增數量（預期 +9，總數 ≥ 683）**全綠，沒有 crashed／restarted
- [ ] helper：`ChorusPowerHelperTests` **53** 全綠（helper 沒有改，數字應該不變）
- [ ] 紅燈證據：至少 X1 修前的 crash `.ips` 堆疊已貼進 handoff
- [ ] `PowerHelperClient.swift` 內所有交給 NSXPC 的 closure（T1 到 T4）都是 `@Sendable` literal；L1 到 L6 的回呼型別都是 `@Sendable`
- [ ] reply 只呼叫一次：X7 通過；proxy 層有 one-shot gate
- [ ] `setSleepDisabledSynchronously` 沒有 hop 到 MainActor；X6 在 1 秒內回傳 false
- [ ] spec §11 不變：helper 的 XPC 介面只有兩個方法；Release 仍然設定 code signing requirement、固定 `.privileged`；Release 中沒有 `init(testConnection:)` 與任何測試開關
- [ ] `git diff --stat` 只包含 §4 允許的檔案；`Localizable.xcstrings` 沒有變更
- [ ] 手動 M1 到 M3 由 Fi 執行並記錄；沒有完成前，b139 只能停在「可以驗證、不發布」

---

## 7. 風險與審查

**高風險**：helper client 是闔蓋不睡安全鏈的 App 端。改錯可能導致下面幾種狀況：
- reply 遺失，變成逾時，接著誤判 helper 不可用。
- continuation 被 resume 兩次（crash）。
- 關機路徑死結（`setSleepDisabledSynchronously`）。
- 連線事件不再 revoke readiness，導致在斷線的狀態下仍顯示 ready。

**雙審（缺一不可）**：

| 審查者 | 重點 |
|---|---|
| **Claude** | 隔離正確性：每個 closure 的推斷隔離；`@Sendable` 捕獲（`weak self`、continuation、box）；Swift 6.4 strict concurrency 0 warning；one-shot gate 的鎖 |
| **Codex** | 行為等價：generation、connectionToken、readinessEpoch 的檢查都沒有被繞過；逾時與錯誤碼不變；X1 到 X7 與 S1、S2 是否真的在非 main queue 觸發（不能是假綠）；spec §11 安全界線；Release 中沒有測試 seam |

兩方都要回報「approve」，或是所有 must-fix 都已處理，才可以交給 Fi。

**回合上限**：
- 實作與紅綠循環：最多 **2 輪**修正（不含紅燈蒐證）。
- 審查：每位審查者最多 **3 輪**（r1 到 r3），照 `keepawake-*-review-r{1,2,3}.md` 的慣例。
- 超過上限仍有 must-fix，或者發現必須修改 helper、ChorusCore 協定才能修好：**停下來，寫進 handoff 的「spec 問題」，交給 Fi 與 Opus 決定**，不要自行擴大範圍。

**push、PR、release.sh、sudo 都要先得到 Fi 核准**（AGENTS.md）。
