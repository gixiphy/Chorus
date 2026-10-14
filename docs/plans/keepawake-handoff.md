# Keepawake handoff（C01–C03 Wave 0 + W0 review fixes r1/r2）

各任務只附加自己的段落。權威：spec v1.1-review §14；Fi decisions approvals §D 覆寫舊 E11／未知電源／簽章文字。

---

## C01

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/KeepAwakeSources.swift`
- `Packages/ChorusCore/Sources/ChorusCore/KeepAwakeLease.swift`
- `Packages/ChorusCore/Sources/ChorusCore/Automation/KeepAwakeLeaseRequest.swift`（初版；本輪未再改 wire 形狀）
- `Packages/ChorusCore/Tests/ChorusCoreTests/KeepAwakeSourcesTests.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/KeepAwakeLeaseTests.swift`

### 測試
```
CLANG_MODULE_CACHE_PATH="$PWD/.wave0-cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.wave0-cache/swift" \
swift test --package-path Packages/ChorusCore --scratch-path "$PWD/.wave0-native-build" \
  --cache-path "$PWD/.wave0-cache/spm" --manifest-cache local --disable-sandbox --build-system native
→ 801 tests in 117 suites passed
```

### 驗收條件
- [x] 純函式／值型別，不 import AppKit／IOKit
- [x] 公開 API 與 spec §4.1／§4.5 一致；偏離見下
- [x] V-C01-* 與 Wave0 review「Test to add」（W0-7／W0-8／W0-10 C01）已補
- [x] W0-10 r2：StatusResponse **獨立固定 JSON fixture**（`secondsSince1970`），含 source kind／name／working／timestamp／health 與 optional 出現／缺席鎖定

### 偏離／給下游的 API 合約
1. **`invalidTTL`**：非有限 `ttl`（NaN／±∞）回 `HoldResult.invalidTTL`（§14.3）；C09 應對 400。
2. **獨立 wire DTO**：`KeepAwakeHelperStatusDTO`／`KeepAwakeLeaseStatusDTO`／`lidPhase: String?` 不依賴 C02／C03 型別。C08／C09 組裝 status 時自行映射。
3. **Fi A4**：`KeepAwakeHoldResponse`／`KeepAwakeStatusResponse` 必填 `assertionEffective`／`lidEffective`；`effective` = 二者 OR。舊 JSON 缺欄**不解碼**（非相容）；新協定。
4. **未來時間（W0-8／§14.3）**：`KeepAwakeBusyAggregator` 對 `lastWorkingAt`／排序／`releaseAt` 使用同一 `min(last, now)`。**C07** 仍須在來源層第一次觀察時做**穩定 clamp**，同一份未變 mtime 不可每 tick 重送未來值。
5. **有界 grace（W0-7）**：個別 tombstone ≤ 32；超出摺入 `aggregateGrace`（保留最新 `lastWorkingAt`）。`purgeExpired` 不提早刪仍在 grace 的證據。C07 report 可用 `graceTombstones`＋`aggregateGraceContribution`／`graceEvidenceTimes`。`foldedCount` **不是**精確的當下 active／grace 計數；aggregate 保留 OR busy／最新 deadline，不保留每個 per-id 身分。
6. **Fi A4 清除**：離開 Agent／停用 automation／token rotation 時立即清租約、不延長 grace——實作在 C07／C08／C09，表本身提供 `release`。

### Spec 問題
無（未改 spec）。

### 覆蓋誠實聲明（r2）
- Restart persistence／lease 立即清除：仍屬 C06／C07／C08／C09，**不**在 C01 宣稱完成。

---

## C02

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/LidSleepGuard.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/LidSleepGuardTests.swift`

### 測試
同上全套件指令；C02 相關全綠。

### 驗收條件
- [x] policy 純函式，時間只來自 `input.now`
- [x] §5.3 判定順序＋§14.2／Fi A3 覆寫
- [x] 狀態圖邊與 W0-2／W0-3／W0-9／W0-10／**W0-11** 測試
- [x] W0-10 r2：明確 predicate 優先序（pause／helper／busy／thermal／power／duration）＋ continuous-clock wake-jump deadline
- [x] W0-11：`onBattery == nil` 在 `hasInternalBattery == false` 短路之前拒絕

### 偏離／給下游的 API 合約
1. **`LidClosedReading`**（取代 `Bool?`）：`.open`／`.closed`／`.noLid`／`.unknown`。只有 `.open` 清 `lidClosedSince`／`maxDurationLatched`。
2. **新 block reasons**：`.noLid`（Fi A3 禁止 arm）、`.lidUnknown`、`.unknownPower`（`onBattery == nil`；W0-3／W0-11／Fi A3）。
3. **未知電源**：不論 percentage **與**是否有內建電池，拒絕新持有並解除既有 wants；已知 AC／電池行為不變。無電池＋已知 AC 為正例（跳過電量百分比）。
4. **時限 latch（W0-2）**：`maxDurationLatched` 在確認開蓋前持續有效；AC 豁免（`limitDurationOnAC == false`）不可繞過既有 latch。
5. **PowerSnapshot 缺樣合約**（無法改 PowerFloor.swift）：`onBattery == nil` → `.unknownPower`（含無電池）；`thermal` 非 optional——取樣失敗／未知 enum 時呼叫端應傳 blocking 值或依賴 `@unknown default`。
6. **`normalized()`（W0-9）**：Int.min／Int.max／NaN／±∞／負時限不 trap；輸出落在允許地板與小時。
7. **持續時限 deadline**：App restart／wake 持久化屬 C06／C08；本 policy 只看注入的 `lidClosedSince`／latch。測試涵蓋注入時鐘的 wake jump；**不**宣稱跨行程持久化完成。

### Spec 問題
舊 tasks「`onBattery == nil` 視為用電池」已被 Fi A3／§14 覆寫為拒絕。

---

## C03

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/PowerHelperXPC.swift`
- `Packages/ChorusCore/Sources/ChorusCore/SleepGuardLedger.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/PowerHelperXPCTests.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/SleepGuardLedgerTests.swift`

### 測試
同上全套件指令；C03 相關全綠。未執行 pmset／未註冊 helper／未 codesign。

### 驗收條件
- [x] XPC 協定僅兩方法；帳本無 I/O
- [x] W0-1 r2：foreign／owned 持有 session 見外部 0 → `externalInterference`；foreign `shouldRestore:false`；續約／新連線×同／異 uid
- [x] W0-4／W0-5／W0-6 r2／W0-10（協定列舉含 optional class；restore nil-read retry）
- [ ] **PENDING**：signed-client 執行矩陣（Developer ID 接受／Apple Development 拒絕／get-task-allow 拒絕）— **未簽章、未跑 SecStaticCodeCheckValidity**；測試明確標 PENDING

### 偏離／給下游的 API 合約
1. **`Action` 擴充**（C05 必須處理）：
   - `.none`／`.write(Bool)`（意圖，非已成功）
   - `.externalInterference(shouldRestore:)`（Fi A2／W0-1）：**任何**既有 holders 見外部 0 → 清空**所有** holder，**禁止 write(true)**；`shouldRestore == setByHelper`（foreign 為 false，不寫系統值）；C05 在 shouldRestore 時 write(false) 並通知 App
   - `.recoveryBlocked`（Fi A8／W0-4）
   - `.systemValueUnknown`（`currentSystemValue == nil` 的新 acquire）
2. **`pendingRestore`／`acknowledgeWrite`**：寫 0 確認前不清 ownership；失敗呼叫 `noteWriteFailure()` 可重試。nil system read 期間意圖存活，可再取得 `write(false)`。C05 不得把 staged `setByHelper=true` 當已確認寫入。
3. **`recoveryBlocked`**：`reconcileOnLaunch(persisted:nil, system≠false)` → 封鎖；重複 acquire 拒絕、無 holder、無 write。已知 foreign（`setByHelper==false`）維持原行為。核准 recovery 後呼叫 `clearRecoveryBlock()`。
4. **Release／Debug requirement（W0-5／Fi A6）**：
   - `debugClientRequirement`／`debugHelperRequirement`：spec 原文（允許 Apple Development）
   - `releaseClientRequirement`／`releaseHelperRequirement`：Developer ID OID `1.2.840.113635.100.6.1.13`＋排除 `get-task-allow`
   - `clientRequirement(forRelease:)`／`helperRequirement(forRelease:)`；`validateRequirementSyntax` 用 `SecRequirementCreateWithString`
   - **C05 Release 必須安裝 Release requirement**；別名 `clientRequirement` 預設仍是 Debug
5. **`PMSetOutputParser`（W0-6 r2）**：嚴格標頭列（非整串 contains）＋已知鍵列文法（恰好鍵+合法值）；畸形已知鍵／僞標頭／精簡文法夾雜 → `nil`。完整結構且無旗標 → `false`。精簡文法：每列皆合法設定列，且含 SleepDisabled 或 ≥2 列。C05 須先確認 exit=0、未截斷再呼叫解析器。
6. **LedgerStore（C05）**：持久化只存 recovery metadata，不存 live holders；驗證 root／權限／symlink。
7. **pmset 樣本**：測試仍為調研格式；V-C03-1 實機 macOS 26 樣本 UNCONFIRMED（R01／V01）。

### Spec 問題
E11「續約重寫 1」已被 Fi A2 覆寫為釋放＋提示；以本帳本為準。

### 重入／重新 acquire（W0-1）
干擾後 holders 空、owned 時 `pendingRestore`／`setByHelper` 仍可能為 true。C05 應先完成 restore ack，再接受新 acquire；在 `recoveryBlocked` 或未 ack 的 restore 期間勿當成可競爭重寫。Preserve documented C05 restore-before-reacquire ordering.

### 覆蓋誠實聲明（r2）
| 項目 | 狀態 |
|---|---|
| W0-1 foreign＋owned 干擾 | 已測（續約／新連線×同／異 uid） |
| W0-6 嚴格文法＋三條精確回歸樣本 | 已測 |
| 協定 required／optional instance／required／optional class 列舉 | 已測 |
| writeAck nil-read restore retry | 已測 |
| Signed-client SecStaticCodeCheckValidity 矩陣 | **PENDING**（未簽章） |
| 真實 pmset／helper 整合 | 下游 C05／V01 |

---

## C05

### 改了哪些檔案
- `PowerHelper/main.swift`、`PowerHelperService.swift`、`PMSetRunner.swift`、`HelperPowerSafety.swift`、`LedgerStore.swift`
- `PowerHelper/com.hermes.Chorus.PowerHelper.plist`、`ChorusPowerHelper.entitlements`
- `project.yml`（ChorusPowerHelper target、embed executables、plist copyFiles、ChorusPowerHelperTests）
- `scripts/package.sh`（單一版本來源、helper 先簽、PKG-4／PKG-11 檢查）
- `Tests/ChorusPowerHelperTests/**`

### 測試
```
xcodebuild -scheme ChorusPowerHelper … CODE_SIGNING_ALLOWED=NO build  → BUILD SUCCEEDED
xcrun xctest .dd/…/ChorusPowerHelperTests.xctest → 17 tests passed
xcodebuild -scheme Chorus … build → helper at Contents/MacOS/ChorusPowerHelper；plist lint OK（PKG-1/2）
（xcodebuild test 對 hostless tool 測試 bundle 曾載入失敗；以 xctest 直接跑為準）
未執行 package.sh／notarytool／真實 codesign／pmset／register
```

### 驗收條件
- [x] helper 無字串型外部輸入；固定 argv；Release requirement = Developer ID + 排除 get-task-allow
- [x] V-C05-1／2／3 以 fake runner／store／safety 覆蓋主要 crash window、refuse、symlink／corrupt
- [x] PKG-1／PKG-2（未簽章項目）；PKG-3..7／簽章矩陣 PENDING（需 Developer ID 核准）
- [x] DEBUG-only `debug-force-critical` 檔案開關；Release 無外部判斷路徑

### 偏離／給下游
1. **restore-before-reacquire**：`pendingRestore`＋`setByHelper` 時先 write(false) ack 再 accept 新 acquire。
2. **Action 處理**：`externalInterference`／`recoveryBlocked`／`systemValueUnknown`／`storeFailed` 錯誤碼。
3. **tool 無法 @testable link**：測試 target 直接編進 helper 源碼（排除 main）。
4. **C06**：用 `clientRequirement(forRelease:)`／`helperRequirement(forRelease:)`；握手後再持有。
5. **C08**：unregister 前確認 own release；勿執行 register／pmset。

### Spec 問題
無。

### Wave1 fix round 1（W1-1／2／3／7／8／9／10 helper／12）
#### 改了哪些檔案
- `PowerHelper/PowerHelperService.swift`、`PMSetRunner.swift`、`HelperPowerSafety.swift`、`LedgerStore.swift`、`MonotonicTime.swift`（新增）
- `scripts/package.sh`、`scripts/release.sh`、`scripts/lib/chorus-version.sh`（新增）、`scripts/test-chorus-version-extract.sh`（新增）
- `Tests/ChorusPowerHelperTests/**`

#### 測試
```
ChorusCore: 802 tests / 117 suites，exit 0
./scripts/test-chorus-version-extract.sh → ALL PASS（未執行 release.sh／package.sh）
xcrun xctest …/ChorusPowerHelperTests.xctest → 32 tests / 7 suites passed，exit 0
（xcodebuild -scheme ChorusPowerHelper test 仍可能無法載入 hostless bundle；以 xctest 為準）
未 sudo／pmset／register／SMAppService.register／真實簽章／公證
```

#### 驗收（W1）
- [x] W1-1：pmset I/O 在獨立 `ioQueue`；generation 丟棄過期 acquire；monotonic runner deadline；wedged＋forceOff 測試
- [x] W1-2：App info.properties 精確抽取（共用 lib）；fixture 證明 naïve grep 多行
- [x] W1-3：helper metadata fail closed（不可用 NEXT_BUILD 頂替）
- [x] W1-7：nil／未知 providing → unknown；空／全失敗描述 → unknown；確認 AC；非有限容量
- [x] W1-8：persist 失敗回報 storeFailed；write0 後 save 失敗重掛 pendingRestore
- [x] W1-9：watchdog 不重置 idle；pending restore／persistRetry 阻止 idle exit
- [x] W1-10 helper：`MonotonicTime`／`CLOCK_MONOTONIC_RAW` 取代 systemUptime 預設
- [x] W1-12：fstatat／openat／O_EXCL／renameat／0600；FIFO 不阻塞；symlink／writable parent 測試

#### 覆蓋誠實聲明（修正 Wave1 handoff）
- V-C05-2：已有 wedged runner／forceOff 獨立性測試；真實 subprocess 飽和 pipe 以 timeout＋TERM ignore 測
- V-C05-3：ancestor／regular-file／FIFO／symlink 矩陣已補；replaceItemAt 行為改為 renameat（不再依賴）
- PKG-8／9／10／11：抽取與 fail-closed 以 fixture 驗證；真實 artifact 簽章仍 PENDING

#### 給下游
- C06／C08：unregister 必須走 client 驗證路徑（見 C06 W1-6）
- V01：helper scheme 用 `xcrun xctest` 或修正 host；勿宣稱 xcodebuild test 已載入 helper bundle

### Wave1 fix round 2（W1-1／7／12／15／16）
#### 改了哪些檔案
- `PowerHelper/PowerHelperService.swift`、`PMSetRunner.swift`、`HelperPowerSafety.swift`、`LedgerStore.swift`
- `Tests/ChorusPowerHelperTests/PowerHelperServiceTests.swift`

#### 測試
```
ChorusCore: 802 tests / 117 suites，exit 0
./scripts/test-chorus-version-extract.sh → ALL PASS（未執行 release.sh／package.sh）
xcrun xctest …/ChorusPowerHelperTests.xctest → 43 tests / 8 suites passed，exit 0
plutil -lint PowerHelper plist: OK
未 sudo／pmset／register／SMAppService.register／真實簽章／公證
```

#### 驗收（W1 r2）
- [x] W1-1：coalesced reads；cancel before write；refuse 不 bump generation；process-group TERM/KILL；bounded drain／reap；descendant＋雙 pipe 測試
- [x] W1-7：malformed max → nil；huge finite ratio clamp；unsafe heartbeat → protected forceOff
- [x] W1-12：rejectAllSymlinks＋openat O_NOFOLLOW walk；save fstatat／O_NONBLOCK／dir fsync；中間 symlink／writable ancestor／FIFO save
- [x] W1-15：async launch reconcile；`whenStartupReady`；無同 queue wait
- [x] W1-16：blocker 清除後 rearm idle（不 touch external activity）
- [x] W1-2／3／8／9：r1 合格；本輪複核未回歸（version fixture ALL PASS；crash-window／idle 測試綠）

#### 覆蓋誠實聲明
- V-C05-2：wedged／refuse-vs-release／obsolete write／descendant pipes 有單元覆蓋；真實 pmset 未跑
- V-C05-3：中間 symlink／writable ancestor／save-FIFO 有測；需 Darwin realpath 測試根（URL.resolvingSymlinksInPath 不夠）
- 啟動 reconcile 延遲 write／RPC-during-startup 有測；完整 crash-window 硬體仍 PENDING

#### 給下游
- status JSON 含 `recoveryBlocked`／`pendingRestore`／`persistRetryNeeded`（C06 unregister 依賴）
- set(false) 在 zero-holder＋setByHelper／pendingRestore 時走 forceOff
- V01：繼續用 `xcrun xctest` 跑 helper bundle

---

## C06

### 改了哪些檔案
- `Chorus/Display/PowerHelperClient.swift`
- `Chorus/Display/LidStateMonitor.swift`
- `Tests/ChorusAppTests/PowerHelperClientTests.swift`

### 測試
```
xcodebuild -scheme Chorus … -only-testing:ChorusAppTests/PowerHelper* …
  -only-testing:…/LidClamshell* -only-testing:…/LidClosedSessionStoreTests
  -only-testing:…/SleepDisabledProbeTests test
→ 15 tests passed；TEST SUCCEEDED
未呼叫 SMAppService.register；未連真實 XPC／pmset
```

### 驗收條件
- [x] V-C06-1／2／3／4（availability、handshake、timeout、shutdown 有界、invalidate）
- [x] Lid 屬性解析 CFBoolean／nil／錯型；讀不到 → nil／`.unknown` 不 crash
- [x] Fi A3：`LidClosedSessionStore` 跨 restart 投影 uptime deadline（C08 接線）
- [x] 無 UI

### 偏離／給下游
1. **`LidClosedReading`** 為權威；`isClosed: Bool?` 為相容映射（noLid／unknown → nil）。
2. **`LidClosedSessionStore.restoredLidClosedSince`**：C08 啟動時注入 policy 的 `lidClosedSince`／latch。
3. **`setPollingEnabled`**：armed／holding 才開 5s 輪詢。
4. **`SleepDisabledProbe`**：使用者身分 `pmset -g`，供 C08 `detectLeftover`。
5. **Q10** interest notification 常數：best-effort；失敗靠輪詢。

### Spec 問題
無。

### Wave1 fix round 1（W1-4／5／6／10 lid／11）
#### 改了哪些檔案
- `Chorus/Display/PowerHelperClient.swift`、`LidStateMonitor.swift`
- `Tests/ChorusAppTests/PowerHelperClientTests.swift`

#### 測試
```
xcodebuild -project Chorus.xcodeproj -scheme Chorus … CODE_SIGNING_ALLOWED=NO \
  -only-testing:ChorusAppTests/PowerHelper* -only-testing:…/Lid* -only-testing:…/SleepDisabledProbeTests test
→ 29 tests / 10 suites passed；** TEST SUCCEEDED **；exit 0
未 register／真實 XPC／pmset
```

#### 驗收（W1）
- [x] W1-4：interruption／invalidation → 立即清 ready；`enabled` 無握手 ≠ ready；舊連線 invalidate
- [x] W1-5：每次連線先 status 握手；protocol mismatch 永不 set(true)；同協定不同 build 允許
- [x] W1-6：unregister 驗證 release／holders／foreign／restore；不安全案例阻擋
- [x] W1-10 lid：連續時間＋bootSessionUUID 持久化；wall-clock 不影響 deadline；reboot → nil
- [x] W1-11：`LidCapability`／`LidCapabilityClassifier`；confirmed noLid vs transient unknown；noLid 不可 arm（policy 層）

#### 給下游
- **C08／U01**：消費 `reading == .noLid` 隱藏／禁用 UI；已存設定與自動化亦不可 arm（Fi A3）
- **C08**：`LidClosedSessionStore.restoredLidClosedSince(nowContinuous:bootSessionUUID:)` — 欄位改為 continuous，不再用 wall elapsed
- **M1**：clamshell interest／闔蓋時序仍 **UNCONFIRMED**（research Q10／Q9）；桌機僅能證 noLid

### Wave1 fix round 2（W1-4／6／10／13／14；W1-11 複核）
#### 改了哪些檔案
- `Chorus/Display/PowerHelperClient.swift`、`LidStateMonitor.swift`
- `Tests/ChorusAppTests/PowerHelperClientTests.swift`
- `Packages/ChorusCore/Sources/ChorusCore/PowerHelperXPC.swift`（W1-6 recovery 欄位；C03 檔案）
- `Packages/ChorusCore/Tests/ChorusCoreTests/PowerHelperXPCTests.swift`

#### 測試
```
xcodebuild -project Chorus.xcodeproj -scheme Chorus … CODE_SIGNING_ALLOWED=NO \
  -only-testing:ChorusAppTests/PowerHelper* -only-testing:…/Lid* \
  -only-testing:…/SleepDisabledProbeTests -only-testing:…/PowerHelperRepairTests test
→ 43 tests / 11 suites passed；** TEST SUCCEEDED **；exit 0
ChorusCore: 802 tests／含 PowerHelperStatus recovery 往返
未 register／真實 XPC／pmset（repair 僅注入 FakeRepairing）
```

#### 驗收（W1 r2）
- [x] W1-4：event 綁 connectionToken＋proxy；延遲 A 事件不 invalidate ready B
- [x] W1-6：nil／pendingRestore／persistRetry／final true 阻擋；own residual release；status 健康欄位
- [x] W1-10：`LidSessionRestoreResult`；corrupt／reboot → `.invalid`（≠ absent）；無 systemUptime fallback
- [x] W1-11：維持 Q10（IOPMrootDomain＋缺 AppleClamshellState → noLid）；M1 通知 **UNCONFIRMED**
- [x] W1-13：sync true 無 handshake／mismatch → false
- [x] W1-14：repair state machine；holders／recovery／sleepDisabled≠false → skippedUnsafe、零 service ops

#### 給下游
- **C08**：優先用 `sessionStore.restoreResult()`；`.invalid` 必須保守 latch，不可當「無 session」重開時限
- **C08／U01**：noLid 隱藏／禁 arm（含已存設定與自動化）仍待接線
- Repair 預設可呼叫 SMAppService；驗證環境必須注入 `PowerHelperRepairing`／勿跑真實 register

---

## C09

### 改了哪些檔案
- `Chorus/Automation/AutomationHTTPTransport.swift`
- `Chorus/Automation/ControlHTTPServer.swift`
- `CLI/ChorusCLI.swift`
- `Tests/ChorusAppTests/KeepAwakeLeaseHTTPTests.swift`
- `Packages/ChorusCore/.../KeepAwakeLeaseRequest.swift`（**C09 授權 fallback**：`KeepAwakeCLIParser` 供 App 測試引用）

### 測試
```
xcodebuild … -only-testing:ChorusAppTests/KeepAwakeLeaseHTTPTests
  -only-testing:ChorusAppTests/KeepAwakeCLIParserTests test → 11 tests passed
ChorusCore swift test → 802 tests passed
未跑 scripts/test-b4-automation.py（交 V01）
```

### 驗收條件
- [x] 路由：401／403 gates、400、429、200、503；既有 Host／Bearer／body limit 未放寬
- [x] CLI：`keepawake hold|release|status`、`--json`、`--peer` 拒絕、exit 2／3／4 映射
- [x] Fi A4：`regenerateToken`／`stop()` 呼叫 `clearLeases`（C08 接上實作）
- [x] `setKeepAwakeHandlers` 供 C08 接線；handler 預設 503

### 偏離／給下游
1. **C08** 必須 `setKeepAwakeHandlers(hold:release:status:clearLeases:)`，hold 組裝 `assertionEffective`／`lidEffective`／`reason`。
2. **離開 Agent 模式清租約**屬 C08（automation stop／token 已在 C09 掛鉤）。
3. **GET status** 應取快取 helper 狀態，不阻塞 main actor（C08）。
4. Live loopback 401／403 E2E 改為 gate 單元測試（避免 URLSession Host 掛起）；V01 可用 curl 補 S-9。

### Spec 問題
無。

---

## C04

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/OrcaWorktreeStatus.swift`（新增）
- `Packages/ChorusCore/Sources/ChorusCore/DesktopAgentMatcher.swift`（新增）
- `Packages/ChorusCore/Tests/ChorusCoreTests/OrcaWorktreeStatusTests.swift`（新增）
- `Packages/ChorusCore/Tests/ChorusCoreTests/DesktopAgentMatcherTests.swift`（新增）

### 測試
```
CLANG_MODULE_CACHE_PATH="$PWD/.wave0-cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.wave0-cache/swift" \
swift test --package-path Packages/ChorusCore --scratch-path "$PWD/.wave0-native-build" \
  --cache-path "$PWD/.wave0-cache/spm" --manifest-cache local --disable-sandbox --build-system native
→ 822 tests in 119 suites passed；exit 0
（含 V-C04-1／V-C04-2 與既有套件）
```

### 驗收條件
- [x] 不執行任何行程，不讀任何檔案
- [x] 每一份 `OrcaFixtures` 有對應期望；`activeOnly` → idle
- [x] `countPermissionAsWorking` true／false 差異
- [x] 每一列 `DesktopAgentFixtures` 符合期望
- [x] §14.3：truncated 無 working → `.incomplete`（非完整 idle）；unknown-only → `.incomplete`
- [x] Fi A4：`claudeTeamID == nil`、`claudeDesktopSourceEnabled == false`（matcher 仍可分類 Claude 路徑）

### 偏離／給下游的 API 合約
1. **`OrcaClassification`**：除 `.working`／`.idle`／`.failed` 外新增 `.incomplete(reason:)`（§14.3 truncated／unknown）。C07 report 應對 incomplete 設 `health = .degraded`，`isWorkingNow = false`。
2. **R01 常數**：`OrcaWorktreeStatus.knownBundleIDs = ["com.stablyai.orca"]`，`teamID = 6CX3WHS9HZ`，CLI 候選以 `/opt/homebrew/bin/orca` 為首。
3. **Codex**：`DesktopAgentMatcher.codexTeamID = "2DC432GLL2"`。
4. **Claude**：路徑規則仍實作於 matcher（fixtures）；**來源層必須檢查 `claudeDesktopSourceEnabled`**，未確認前不發 report。
5. **Row 解碼**：`id`←`worktreeId`／`id`／`path`；`name`←`displayName`／`name`；`lastActivityAt` 接受 ISO8601 與 epoch ms。

### Spec 問題
無（未改 spec）。R01 已確認的 bundle／Team／CLI 建議 Opus 回填 §4.3「未確認」標註。

### 給下游（C07）
- Orca CLI 失敗 → degraded + 既有 tty 退路；找不到 CLI → unavailable。
- Desktop：驗簽 + mtime；Claude 來源 disabled。
- Grok Bot 常數屬 C07 `AppPresenceSource`（`com.anysphere.sand`）。
- 穩定第一次觀察 clamp 未來 mtime（C01 handoff #4）。

### C04FIX1（Codex review C4-1..C4-4，attempt 2）
#### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/OrcaWorktreeStatus.swift`
- `Packages/ChorusCore/Sources/ChorusCore/DesktopAgentMatcher.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/OrcaWorktreeStatusTests.swift`
- `Packages/ChorusCore/Tests/ChorusCoreTests/DesktopAgentMatcherTests.swift`
- 未改 C07／A01 fixtures／Localizable

#### 測試指令與結果
```
CLANG_MODULE_CACHE_PATH=… SWIFTPM_MODULECACHE_OVERRIDE=… \
swift test --package-path Packages/ChorusCore --scratch-path … --build-system native --disable-sandbox
→ 829 tests in 119 suites passed；exit 0
```
`.wave0-cache`／`.wave0-native-build` 測完已刪。

#### 驗收（對 review）
- [x] C4-1：任一 unknown → 無 working 時 `.incomplete`；有 working 時 `.working(..., qualityWarning:)`；不把 unknown 當 working
- [x] C4-2：`.failed` reason 僅固定類別或 allowlisted code；不含 path／控制字元／長 payload
- [x] C4-3：Codex 要求 argv[0] basename `codex`（獨立於 trusted path）
- [x] C4-4：numeric `lastActivityAt` 一律 ÷1000（epoch ms）

#### 偏離 spec／API 破壞
1. **`OrcaClassification.working`** 改為 `working(rows:qualityWarning:)`。C07 `OrcaActivitySource.applyClassification` 的 `case let .working(rows)` **必須改**為綁定 `qualityWarning`；非 nil 時 health 應 degraded（仍 `isWorkingNow=true`）。本輪依範圍**未改 C07**。
2. 失敗 reason 不再轉發 CLI message／任意 code（§14.3）；allowlist 目前僅 `RUNTIME_UNAVAILABLE`。

#### 給下游注意
- C07 亦須 sanitize subprocess stderr／其他 failure 路徑（review 註記）。
- truncated notice／quality 仍由 C07 映射；本輪 qualityWarning 只覆蓋 unknown status。

---

## C07

### 改了哪些檔案
- `Chorus/Display/KeepAwakeSourceHub.swift`（新增；含 `KeepAwakeSource`／settings／mtime clamp）
- `Chorus/Display/OrcaActivitySource.swift`（新增）
- `Chorus/Display/DesktopAgentSource.swift`（新增）
- `Chorus/Display/CodeSignatureVerifier.swift`（新增）
- `Chorus/Display/KeepAwakeLeaseSource.swift`（新增）
- `Chorus/Display/AppPresenceSource.swift`（新增；`GrokBotPresence`）
- `Chorus/Display/AgentActivityMonitor.swift`（**只新增** `sourceReport()`／mtime clamp）
- `Tests/ChorusAppTests/KeepAwakeSourceHubTests.swift`（新增）
- `Tests/ChorusAppTests/OrcaActivitySourceTests.swift`（新增）
- `Tests/ChorusAppTests/DesktopAgentSourceTests.swift`（新增）
- `Tests/ChorusAppTests/KeepAwakeLeaseSourceTests.swift`（新增）
- `Tests/ChorusAppTests/AgentActivityMonitorTests.swift`（sourceReport 回歸）

### 測試
```
ChorusCore（指定 native／cache 指令）→ 822 tests / 119 suites；exit 0
xcodegen generate → ok
xcodebuild -project Chorus.xcodeproj -scheme Chorus … CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ChorusAppTests
→ 464 tests / 67 suites；** TEST SUCCEEDED **；exit 0
```
未跑真實 `orca` CLI／未讀 Orca DB／未 sudo／pmset／helper 註冊。

### 驗收條件
- [x] Hub OR／tick／stop 不回呼／設定關閉不啟動（V-C07-1）
- [x] Orca：CLI 缺失、逾時 kill 路徑、退避、Orca 不在不執行、permission（V-C07-2）
- [x] Desktop：驗簽失敗、mtime 過舊、無行程、未來 mtime 穩定 clamp（V-C07-3／6）
- [x] agents 不雙重寬限 300≠600（V-C07-4）；opt-out 立即移除（V-C07-5）
- [x] Lease hold→onChange；到期 grace `isWorkingNow=false`；`clearImmediately` 無 grace（Fi A4）
- [x] `sourceReport()`：空→nil；`isWorkingNow=false`；max lastWrite
- [x] 同步子行程／檔案 I/O 在 `.utility`；Claude 來源 disabled；Grok 預設 off
- [x] 不讀檔案內容（只 mtime）

### 偏離／給下游的 API 合約
1. **`KeepAwakeSourceHub.stop()`** 呼叫 `leases.clearImmediately()`（Fi A4）。C08 離開 Agent／C09 token／automation stop 亦應清租約（C09 已有 clearLeases 掛鉤；C08 接 `leases.clearImmediately`）。
2. **`KeepAwakeLeaseSource.hold/release/snapshot/clearImmediately`** 供 C08／C09。
3. **`OrcaActivitySource`**：注入 `OrcaCommandRunning`／`OrcaPresenceChecking`；`cliPathResolver` 一旦設定，nil 不回退本機定位。
4. **Claude**：`DesktopAgentMatcher.claudeDesktopSourceEnabled == false` → 不發 report。
5. **Grok Bot**：`GrokBotPresence.bundleIDs = com.anysphere.sand`；僅 opt-in `grokBotEnabled`。
6. **未來 mtime**：`KeepAwakeMtimeClampCache` 於 agents／desktop 第一次觀察穩定 clamp。
7. **未接線**：Hub 尚未掛入 `KeepAwakeController`／AppState（屬 C08）。

### Spec 問題
無。

### C07 review fix r1（2026-10-13）— C7-1..C7-9 + C4-5
#### 改了哪些檔案
- `Chorus/Display/{KeepAwakeSourceHub,OrcaActivitySource,DesktopAgentSource,KeepAwakeLeaseSource,AppPresenceSource,AgentActivityMonitor}.swift`
- `Tests/ChorusAppTests/{KeepAwakeSourceHubTests,OrcaActivitySourceTests,DesktopAgentSourceTests,KeepAwakeLeaseSourceTests}.swift`

#### 測試指令與結果
```
xcodegen generate → ok
xcodebuild … test -only-testing:ChorusAppTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120
→ 480 tests / 67 suites；TEST SUCCEEDED；exit 0
ChorusCore native → 829 tests / 119 suites；exit 0
```
Hang 根因：`OrcaActivitySourceTests.stopDiscardsLateFlight` 在 `@MainActor` 上阻塞 `SyncGate.waitUntilWaiting`，同 actor 的 `pollOnce` Task 永遠排不到（0% CPU）。已改為 yield 輪詢；真實 `Process`／`sleep`／`dd` 子行程測試改為 FakeRunner + `OrcaPipeDrain.Buffer` 單元測試。

#### 驗收（C7-1..C7-9／C4-5）
- [x] C7-1 hub tick 自動 `leases.refresh()`；TTL／grace 無需手動 refresh
- [x] C7-2 generation＋stop 丟棄晚到結果；max concurrent child=1
- [x] C7-3 並行 pipe drain／overflow；測試不 spawn 真實子行程
- [x] C7-4 uid／startTime；signature cache prune
- [x] C7-5 Grok 結束時刻＋tick 自校正
- [x] C7-6 busy 不變也通知 contributing／細節變更
- [x] C7-7 誠實 fallback 文案（TTY off／unverified）
- [x] C7-8 workspace observers＋absence 單次 grace
- [x] C7-9 `clearImmediately` 執行中通知 hub；`hub.stop` 仍靜默
- [x] C4-5 `qualityWarning` → degraded、保留 working 證據

#### 偏離
無。C7-3 實機 pipe／TERM→KILL 改由 Fake／Buffer 覆蓋（避免 app test host hang）；`ProcessOrcaCommandRunner` 實作仍在。

#### 給下游
- C08：接 `leases.clearImmediately`／hub `onBusyChanged`（細節變更也會 fire）
- 未 push／PR／merge；未 sudo／pmset／helper／真實 orca

---

### Codex FIXER r2 — 2026-10-13 (Fi-approved C07 takeover)

- Files: `Chorus/Display/{OrcaActivitySource,DesktopAgentSource,KeepAwakeSourceHub,AgentActivityMonitor}.swift`; `Tests/ChorusAppTests/{OrcaActivitySourceTests,DesktopAgentSourceTests,KeepAwakeSourceHubTests,AgentActivityMonitorTests}.swift`.
- Detailed per-issue changes, commands, limits and suggested commit: `docs/plans/keepawake-c07-codexfix.md`.
- Verification: worktree-cache ChorusCore dependency build exit 0; actual C07 production subset Swift 6 module emission exit 0; all five C07 test files Swift 6 typecheck exit 0; `git diff --check` exit 0. App test execution/full build/real-child semantics **未確認**, coordinator-owned.
- [x] C7-2 token before preflight; overlap/event/stop-start/configure gates; existing monitor invalidation regression.
- [x] C7-3 nonblocking drain/EOF and error states; virtual TERM/KILL/reap/inherited writer policy; retain ownership until direct-child termination.
- [x] C7-4 metadata/cache/signature/transcript live checks with gated identity regressions.
- [x] C7-8 event presence independent of flight; utility tick scans; observer lifecycle; virtual retry/backoff notification tests.
- [x] New C7-10 safe bounded eviction/pruning; 600-live-sample adapter and churn tests over >=300 seconds.
- [ ] Runtime regression acceptance: coordinator must run app tests.
- Deviation/limit: bounded mtime retirement is conservative and can shorten new evidence below the retired raw ceiling (review explicitly permits a conservative representation). An unconfirmed live child keeps ownership even beyond KILL rather than reporting false cleanup success. No spec changes; no new spec question identified.
- Downstream: pass the ignored local report separately; preserve baseline untracked AGENTS.md. No commit/staging/push/PR/system/helper/Orca changes; all source/test changes remain unstaged.


## V01

### Wave 0 third verification — 2026-10-12
- Reviewed r2 remaining issues against spec §14, approvals §D and C01–C03 handoff at `4e7e02c`.
- Direct fix: C03-scoped `PowerHelperXPC.swift`, `PowerHelperXPCTests.swift`; reject header-masked unknown rows and validate exact AC/Battery/UPS headers.
- [x] W0-1 independent owned/foreign interference matrix passes.
- [x] W0-6 regressions failed 5 assertions before direct fix, then pass.
- [x] W0-10 protocol categories, nil-read restore retry, predicate priorities/deadline and independent JSON fixtures verified.
- [x] W0-11 no-battery unknown-power refusal and known AC controls pass.
- [x] Full supplied test command: 802 tests, 117 suites, exit 0; `/tmp/chorus-wave0-r3-green.log`.
- [ ] Signed-client execution PENDING, accepted for Wave 0; no signing performed.
- [ ] Required commit BLOCKED: Git metadata outside writable roots, index.lock denied. No hash. Requested message `fix(keepawake): Codex direct fix W0-6`; patch `/tmp/chorus-wave0-r3-W0-6.patch`.
- No spec changes. Unknown real pmset rows return nil conservatively; actual macOS 26 sample UNCONFIRMED. C05 must gate runner output and preserve restore-before-reacquire ordering.
- Full evidence and CHANGES-REQUIRED verdict (commit limitation only): `docs/plans/keepawake-wave0-review-r3.md`.


### Wave 1 third verification — 2026-10-12 (V01, authorized direct C05/C06 fixes)

- Report: docs/plans/keepawake-wave1-review-r3.md; verdict CHANGES-REQUIRED pending focused execution/C08 integration.
- Direct files: PowerHelper/{PowerHelperService,PMSetRunner,LedgerStore,MonotonicTime}.swift; Chorus/Display/{PowerHelperClient,LidStateMonitor}.swift; Tests/ChorusPowerHelperTests/PowerHelperServiceTests.swift; Tests/ChorusAppTests/PowerHelperClientTests.swift. All unstaged; no commit. Per-issue commit messages in r3.
- Exact native Core command: exit 0, 802 tests/117 suites. Version extraction: exit 0 ALL PASS. Changed files parse; helper/client source-only Swift 6 typecheck exit 0 with warnings. New helper/App runtime UNVERIFIED, coordinator runs Xcode outside sandbox.
- [x] Per-issue r2, §14/§D and handoff static review.
- [x] Direct third-attempt repairs for remaining W1-1/6/10/12 gaps; W1-4/7 commit fixes inspected.
- [x] W1-13..16 reviewed; W1-14 default-denied operation authorization added.
- [x] Regression tests added, unstaged scope documented.
- [ ] Fresh helper/App execution, C08 restart/wake integration, runtime descendant cleanup and M1 verification.
- Spec deviation: none intended; invalid session preserved/latched, foreign ownership preserved, unknown removal evidence fails closed. No spec edits.
- Downstream: consume restoreResult/latch until confirmed open; supply current transaction approval to authorizeProtocolRepair (default denial deliberate). Core/typecheck is not helper test PASS. Worktree verification caches removed; /tmp logs retained.

---

### C08 third verification — 2026-10-13 (V01, authorized direct C08 fixes)

- Report: `docs/plans/keepawake-c08-review-r3.md`; VERDICT PASS for reviewed source defects, with runtime limits documented.
- Changed source/test files: `Chorus/Display/{LidSleepGuardController,KeepAwakeController}.swift`, `Chorus/Persistence/SettingsStore.swift`, `Tests/ChorusAppTests/{LidSleepGuardControllerTests,KeepAwakeControllerTests}.swift`; uncommitted, coordinator commits. Local documents: r3 report and this V01 entry only.
- [x] C8-1 callback/handshake/sync shutdown fix verified against actual client source and injected off-actor seam tests.
- [x] C8-2 serial release/evidence gating and delayed reply guards repaired; deterministic regressions pass.
- [x] C8-4 recovery gating survives failed refresh, releases our holder, rejects late refresh and exposes three allowlisted HTTP booleans; regressions pass.
- [x] C8-7 partial-effect explanations checked; enabled-unavailable/pending fallback corrected.
- [x] R2 NEW-1 clamp-changing assignment persistence/reevaluation repaired and fresh-store regression passes.
- [x] Core command in report: 829 tests/119 suites, exit 0; native Swift 6 harness final serial command: 99 tests/13 suites, exit 0. `git diff --check` passes. Red regression evidence preserved in /private/tmp logs.
- [ ] Full post-patch Xcode App execution: blocked by sandbox manifest execution; coordinator reruns outside sandbox. Parallel native harness signal 11 also reproduced with unmodified 179f9a5; cause UNCONFIRMED. Serial final harness passes; see report for explicit substitutions and logs.
- [ ] Live XPC/service/signing/CLI/hardware verification remains unverified; no pmset, sudo, registration, commit, push, PR, merge or release performed.
- Spec deviation: no spec edits. Additive recovery encoding lives in C08 to stay within scope; C01 can adopt optional typed fields later. Existing wire DTO decoding remains compatible.
- Downstream: coordinator commits five files and runs full App tests; U01 consumes no-lid capability; Opus/UI reconcile old selector text with approved ≤3h including AC. No edits to C06/Core/helper/CLI/catalog/AGENTS.

### Wave 4 / whole-feature V01 review — 2026-10-13

- Report: `docs/plans/keepawake-v01-review.md`; **VERDICT: CHANGES-REQUIRED**. Open V1-1–12: 6 High, 4 Medium, 2 Low, with file:line evidence, owner/fix and verification gaps. Reviewed `56f476a → 220c7b8`, specifically C10/resume/U01-U02/A02 Wave 4 commits, spec v1.1-review §14 and approvals §D.
- Changed test only: `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift`. Added deterministic resume regressions for pause/release/resume/reacquire, thermal reevaluation and no-op when not paused. Fixed clock and fake helper; AsyncStream completion, no sleep/poll delays. No production source edits.
- Fresh checks: `xcrun swiftc -frontend -parse Tests/ChorusAppTests/LidSleepGuardControllerTests.swift` and `git diff --check`, exit 0. New tests have **not** been typechecked/executed here; coordinator runs focused/full Xcode suites and Core outside sandbox. User-supplied prior App success/Core 833 pass is attributed baseline evidence only.
- [x] Wave 4 and overall source integration review; two independent read-only review scopes cross-checked.
- [x] Required regression tests and local review document; changed-file scope inspected.
- [x] Every finding includes severity, evidence and required fix; remaining V/M/S/PKG verification explicitly listed.
- [ ] Fresh regression execution/helper target execution, live HTTP/CLI, three settings screenshots, M1/signing/service verification and original V01 recorder/full per-run report.
- Spec questions: old 4h/AC exemption, external-0 rewrite and M5/hard-power-off steps conflict with §D; Opus should reconcile them. No spec changes made. Accepted helper-crash residue remains a documented risk.
- Downstream: fix V1 High items in their owners' scopes before treating the feature as integrated; run added tests and issue-specific regressions. M1 registration/install and every sudo pmset injection still require Fi approval and an authorized verifier; M-9a hard power-off is skipped. No commit/push/PR/merge/package/release, helper/system or Orca operations performed.

### V01FIX1 — Cursor（2026-10-13）attempt 2 — V1-1..V1-12

Authorized cross-owner feature edits (helper/client/controller/sources/CLI/diagnostics) + regressions.

| ID | Fix |
|---|---|
| V1-1 | `PMSetOutputParser`：assertion 註解、lowpowermode／powermode／DestroyFVKeyOnStandby、標頭模式可忽略型式正確未知鍵；SleepDisabled 仍嚴格 0／1 |
| V1-2 | hub configure 冪等；lease `start` 冪等＋穩定 wall；controller `reevaluate` coalesce |
| V1-3 | leftover probe `async`／off-MainActor；subprocess 連續 drain＋TERM／KILL＋有界 EOF |
| V1-4 | own residual 直接 `set(false)`；generation／shutdown gate；追蹤／取消 recovery Task |
| V1-5 | transport `invalidateKeepAwakeAuthorization` 於 rotate／stop 先於 clearLeases；mutation 時驗證 generation |
| V1-6 | hold／release `admitCommands(1)`，504 後仍占額度至完成 |
| V1-7 | lease 預設 `LidMonotonicTime`；hold／status wire 用同一 continuous clock |
| V1-8 | 公開 `lidGuard.helperAvailability`；doctor／export 用實際 availability，不從 phase 捏造 |
| V1-9 | `KeepAwakeLeaseTable.hold` 同一次 `now` 先 purge 再容量檢查 |
| V1-10 | `AppPresenceSource.stop` → `clearEvidence` |
| V1-11 | `Lease.ttl` 持久化；status 回實際 clamped TTL |
| V1-12 | helper `encodeStatus` 用連線認證 uid（非 holder 推導） |

#### 測試
```
ChorusCore native → 836 tests / 120 suites；exit 0
xcodebuild … -only-testing:ChorusAppTests （timeouts 60/120）
→ 572 tests / 72 suites；TEST SUCCEEDED；exit 0
xcrun xctest ChorusPowerHelperTests.xctest → 50 tests / 8 suites；exit 0
（xcodebuild -only-testing:ChorusPowerHelperTests 在此路徑仍無法載入 bundle；改用直接 xctest）
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。未 sudo／pmset／register／簽章／push／PR／merge。

### V01 R2 — Codex static re-review（2026-10-13）

- Report: `docs/plans/keepawake-v01-review-r2.md`; reviewed `b8afcdb..ccfa966` plus affected context, spec v1.1-review §14, approvals §D and verification plan. **VERDICT: CHANGES-REQUIRED**.
- Changed files: the local R2 report and this appended V01 handoff entry only. No source/test/catalog/spec edits, test execution, pmset/sudo/service/system operations, commit/push/PR/merge/package/release.
- Fresh read-only checks: requested HEAD confirmed; `git diff --check b8afcdb..ccfa966` exit 0; tracked/untracked Git status clean before writes. Final document/scope checks are recorded in the report evidence.
- Coordinator reports App + helper TEST SUCCEEDED and Core 836 passed outside sandbox; raw logs/build environment remain unverified by Codex. Cursor's handoff separately describes direct helper xctest fallback; no scheme-loading claim is inferred.
- [x] Each V1-1–V1-12 has FIXED/NOT-FIXED and file/line evidence: 8 FIXED, 4 NOT-FIXED.
- [x] Remaining defects: V1-5 High (generation check before actor hop plus separate token/generation sampling); V1-3/4/7 residual Medium. Original V1-3 MainActor block and V1-4 acquire-after-shutdown mechanisms are removed.
- [x] NEW findings: permissive/incomplete parser tails (Medium); successful manual residual restore retains warning (Low). Report identifies owners and regressions needed.
- [x] Remaining M1/manual, S/PKG/integration evidence and approval boundaries listed; M-9a remains SKIPPED under §D.
- [ ] Production transport race tests, hostile probe fixtures, generation-gated recovery failures and production wake lease refresh; signed XPC/M1/system evidence and original recorder/full per-run report.
- Spec deviations/questions: no spec changes. §14/§D govern over older examples; Opus should reconcile old M5/4h/AC exemption/external-0 rewrite/hard-power-off wording.
- Downstream: C09/C08 must make authorization capture atomic and recheck on MainActor at the mutation; C06 must finish continuous deadline/cleanup; C08 must gate failed/probe recovery completions and clear successful manual recovery presentation; C07/C08 must refresh leases before wake policy and avoid clock epoch fallback; C03 must validate annotation tails. Passing substitute-seam tests do not close these paths. Hardware install/register and each sudo pmset action still need Fi's specific approval.

### V01FIX2 — Cursor（2026-10-13）attempt 3 — V1-3/4/5/7 + NEW-1/2

Authorized cross-owner feature edits + **production-path** regressions (not substitute seams).

| ID | Fix |
|---|---|
| V1-5 | Token+generation 同一 `Mutex` 原子 admit；`rotateKeepAwakeAuthorization`；MainActor 上同步 revalidate→hold/release（無 await 夾縫）；production-path gates 測 rotation／disable／MainActor 窗 |
| V1-3 | Probe runner 改 `ContinuousClock` deadline；fcntl／setpgid 失敗顯式清理；正常 exit 仍有繼承 writer 時 group-KILL＋truncate；真實 saturated／ignore-TERM／inherited-writer 子行程 fixture |
| V1-4 | `detectLeftover` 在首個 await **前**抓 generation；success／failure／probe 皆 gate；stale status failure 不覆寫 |
| V1-7 | `handleDidWake` 先 `sourceHub.tick()` 再 reevaluate；lease 時鐘失敗凍結 last-good continuous（不切 `systemUptime`） |
| NEW-1 | sleep／displaysleep 僅接受平衡 `(…)` 註解；其餘鍵拒垃圾尾；殘缺註解 → nil |
| NEW-2 | 手動 `restoreLeftover` 成功且 generation 有效時清 leftover＋publish；失敗保留警告 |

#### 測試
```
ChorusCore native → 837 tests / 120 suites；exit 0
xcodebuild … -only-testing:ChorusAppTests （timeouts 60/120）
→ 583 tests / 72 suites；TEST SUCCEEDED；exit 0
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。未 sudo／pmset／register／簽章／push／PR／merge。未啟動 /Applications/Chorus.app。

#### 偏離／下游
- 無 spec 編輯。M1／signing／live XPC／helper 安裝仍 PENDING（需 Fi 核准）。
- Codex V01 靜態 re-review 應走 production-path 測試名（非 `executeKeepAwakeMutationForTesting` capacity seam）。



### V01 R3 — 2026-10-13 (9d78818 re-review, authorized direct repairs)

- Report: `docs/plans/keepawake-v01-review-r3.md`; VERDICT PASS for reviewed source defects after the unstaged fixes. User explicitly authorized third-strike source/regression repairs; no commit/push/staging.
- Files: `Chorus/Automation/AutomationHTTPTransport.swift`; `Chorus/Display/{PowerHelperClient,LidSleepGuardController,KeepAwakeLeaseSource,KeepAwakeController}.swift`; `Packages/ChorusCore/Sources/ChorusCore/{KeepAwakeLease,PowerHelperXPC}.swift`; `Tests/ChorusAppTests/{PowerHelperClient,LidSleepGuardController,KeepAwakeLeaseSource,KeepAwakeController,KeepAwakeLeaseHTTP}Tests.swift`; `Packages/ChorusCore/Tests/ChorusCoreTests/PowerHelperXPCTests.swift`. Local docs: r3 report and this V01 subsection only.
- Tests: exact commands/environment and logs in report. Fresh Core 838/120 suites PASS; native App harness 144/16 suites PASS (skip actual assertion test and actual pmset probe); native Release build PASS and new mutation gate symbols absent. Xcode package resolution blocked by sandbox user-cache writes; coordinator must rerun full Xcode App+Helper after patch.
- [x] V1-1/2/5/6/8/9/10/11/12 and NEW-2 fixes inspected; runtime limits distinguished from coordinator reports.
- [x] V1-3 actual runner inherited-writer regression fails before repair, passes after spawn-time process group and bounded drain/reap cleanup.
- [x] V1-4 actual controller concurrent same-generation stale status/probe regressions fail before repair, pass after independent recovery generation and cancellation guards; shutdown/manual restore tests pass.
- [x] V1-7 production wake refresh confirmed; clock failure/first-sample regressions fail before repair, pass after clearing evidence/rejecting admission; actual controller wake/503/recovery test passes.
- [x] NEW-1 multiple/empty annotation regressions fail before repair, pass after single-group validation.
- [x] R3 NEW-3 Medium test gates in Release removed behind DEBUG; before/after native Release symbols retained.
- [ ] Full Xcode runtime, production socket/config lifecycle, signed XPC/BTM and M1 manual evidence. §D installation/registration and each sudo pmset operation need Fi-specific approval via approved verifier. M-9a hard power-off remains SKIPPED.
- Spec problem: §14.2 does not specify exact failed continuous-sample wire/retention behavior. Repair fails closed: discard lease/grace, 503 clockUnavailable, fresh hold after recovery. Opus should document it; no spec/catalog edits. Downstream exhaustive switches must handle new HoldResult.clockUnavailable.
- Downstream: all 13 source/test files remain unstaged; full patch `/private/tmp/chorus-v01r3-source.patch`. Logs/harness preserved in `/private/tmp`; review report is ignored local content and must be passed separately. No helper/root/system/Orca/signing/release operation was performed.

### 合併模式複驗 — 第 2 次嘗試（2026-10-13，HEAD bb1e8aa）

- 報告：`~/kp-verify/chorus-merge-verify-2.md`；VERDICT FAIL。前次問題1–6指定複驗通過，但新增 NEW-1 Medium：同模式備份匯入更新 defaults，未同步執行中的負載 configuration／controller 快取。
- 修改檔案：本 V01 段落、外部報告與 `/private/tmp/chorus-merge-reverify-*.py`／logs／fixture 結果。沒有 source 修正、沒有 commit；未 push／PR／merge／release／sudo／helper 註冊／pmset 寫入。
- 測試：`swift test --package-path Packages/ChorusCore --scratch-path ~/Library/Caches/DevBuild/Chorus_merge-codex-core`，timeout900，exit0，843 tests／120 suites；指定 `xcodebuild test`（App＋helper，CODE_SIGNING_ALLOWED=NO，DerivedData=Chorus_merge-codex），timeout1200，exit0，669＋53＝722，0 failed／0 skipped。完整命令與179.11秒結果見報告及 `/private/tmp/chorus-merge-reverify-test-results.json`。
- [x] 前次 crash 本次未重現；isolated deinit 拆除在 MainActor、handle 清零、重複拆除 no-op；原 crash 根因仍未確認。
- [x] 前次 LegacyLoad／MergedAgent 跨機 fixture 均在同一PID立即進agents，flags=true／false，CPU sample已出現；`backup-results-reverify-2.json`。
- [x] 四個動態key en／zh-Hans與compiled en測試通過；新idle warning已消除；closed-lid load-only陰性及agent lease陽性對照通過。
- [x] PowerHelper／PowerHelperClient／pmset／LidSleepGuard production diff相對eb3170a為空；LidStateMonitor明確例外只有8行deinit。
- [ ] NEW-1：`config-results-reverify-2.json` 重現匯入CPU=false但11秒後仍採樣CPU；controller設定快取亦未同步。超出幾行小修，按prompt只寫分析與修正計畫，留給下游處理。
- spec／計畫問題：舊合併計畫Core≥844及含LidStateMonitor零diff的驗收文字未對齊fix1／本次prompt；未自行修改spec／計畫。實測Core843，monitor防禦性修正已審查，未宣稱實機安全驗證。
- 下游注意：需完整匯入runtime settings同步，比較負載configuration後才更新monitor，避免相同設定重置遲滯／startedAt；補battery／idle／process快取與各模式測試，再跑全量及兩支E2E。專用驗證實例均已正常退出。


### 合併模式複驗 — 第 3 次（2026-10-13，HEAD ed20fda）

- 報告：`~/kp-verify/chorus-merge-verify-3.md`；VERDICT PASS。
- 修改：自己的 V01 段落、報告及 `/private/tmp/chorus-merge-reverify3-*`／fixture 結果；沒有 source 修改或 commit。
- 測試：Core timeout900、exit0、3.80秒、843／120 suites；App＋helper timeout1200、exit0、172.66秒、674＋53＝727；xcresult727 passed、0 failed、0 skipped。
- [x] NEW-1：真正跨機同模式匯入（PID33661）1.136秒內CPU unavailable／null、preventsSystemSleep=true，11秒後與defaults一致；config-results-reverify-3.json；正常退出。
- [x] 問題1–6：無crash、PERF1-R3與hung-write通過；LegacyLoad／MergedAgent同PID34894從off匯入生效、旗標正規化；四key翻譯、指定warning、closed-lid陰性／陽性对照通過。
- [x] 相同config不restart／保留grace與startedAt、battery／idle／process快取與timed／display模式的新測試通過。
- [x] PowerHelper／pmset／LidSleepGuard／XPC／ledger相對eb3170a零diff；LidStateMonitor相對上一輪零diff（基準仍有8行deinit例外）。
- 偏離／spec問題：沒有新增；舊計畫Core≥844與包含monitor零diff文字落差仍待owner更新。前次偶發crash根因仍未確認。
- 下游：本次僅自動化＋Debug命名實例，沒有Release／真實闔蓋／簽章XPC驗證；未push／PR／merge／release／sudo／helper註冊／pmset寫入。既有.dd未動。


## C08

### 改了哪些檔案
**Skeleton** (`e7f4666`):
- `Chorus/Display/LidSleepGuardController.swift`（新增；公開 API）
- `Chorus/Display/KeepAwakeController.swift`（sourceHub／lidGuard 骨架）
- `Chorus/App/KeepAwakeNotifier.swift`（§7.3 protocol）
- `Chorus/Persistence/SettingsStore.swift`（§8.1 keys）

**Integration**:
- `Chorus/Display/LidSleepGuardController.swift`（policy／set／心跳／退避／leftover／session）
- `Chorus/Display/KeepAwakeController.swift`（hub busy→assertion、HTTP handlers、shutdown 順序）
- `Chorus/App/KeepAwakeNotifier.swift`（§7.3 文案）
- `Chorus/App/AppState.swift`（setKeepAwakeHandlers／detectLeftover；XCTest 跳過真 XPC）
- `Chorus/App/TestHooks.swift`（DEBUG M-5／M-12／M-13 覆寫）
- `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift`（新增）
- `Tests/ChorusAppTests/KeepAwakeControllerTests.swift`

### 測試
```
xcodegen generate → ok
xcodebuild … -only-testing:ChorusAppTests -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120
→ 505 tests / 69 suites；TEST SUCCEEDED；exit 0
ChorusCore native → 829 tests / 119 suites；exit 0
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。
未 sudo／pmset／SMAppService.register／簽章／啟動 /Applications/Chorus.app。

### 驗收條件
- [x] V-C08-1：set／心跳（注入短 interval）／退避／forcedOff
- [x] V-C08-2：shutdown sync ≤1s（helper hang）
- [x] V-C08-3：leftover 四分支（own／foreign／otherUser／unknownOwner）
- [x] V-C08-4：armed 通知同 busy 期一次＋30min 節流
- [x] V-C08-5：選項關閉不 set(true)；既有 KeepAwake 測試綠
- [x] V-C08-6：E2E named instance 零 helper 呼叫
- [x] V-C08-7：關選項允許只讀 probe；restore 失敗不發已還原通知；同 uid 其他 holder ≠ leftover
- [x] Fi A4：assertionEffective／lidEffective；clearLeases；新來源驅動 assertion
- [x] Fi A3：noLid／unknownPower 由 policy；max 3h 含 AC；電池底線≥30；thermal serious；通知 30min
- [x] C06：invalid session → maxDurationLatched；protocol-repair 預設拒絕（authorizeProtocolRepair={false}）
- [x] 無 NSAlert／confirm

### 偏離／給下游
1. **XPC 閘門**：`requestSet`／`refreshFromHelper`／`detectLeftover` 在 `.ready` **或** `.connecting`（handshake）時可開 `status()`；`.notRegistered`／approval／notFound 仍不開 XPC。Named E2E 零呼叫。
2. **shutdown sync release**：僅在曾 wants／callerIsHolder／setByHelper 時呼叫 sync set(false)，避免無謂開連線。
3. **AppState detectLeftover**：`XCTestConfigurationFilePath` 存在時跳過（測試 host）；正式啟動仍跑。
4. **心跳測試**：注入 `heartbeatInterval`（預設仍 20s）以保持確定性。
5. **U01／U02**：公開 API 齊（phase／leftover／isActuallyHolding／`lidReading`／`isConfirmedNoLid`／register／unregister／pause／settings／onChange）。no-lid 時隱藏設定區並禁 arm。
6. **C10**：可讀 `lidGuard.leftover`（含 `.recoveryBlocked`）／`helperStatus`；doctor 未接（屬 C10）。
7. **Fi A3 時限**：C08／SettingsStore 強制 `maxLidClosedSeconds ≤ 3h` 且 `limitDurationOnAC=true`（舊 4h／AC 豁免遷移）。C02 `normalized()` 仍允許 4h——若要改 core 需 Opus／C02。
8. **HTTP helper DTO**：`KeepAwakeHelperStatusDTO` 仍無 `recoveryBlocked`／`pendingRestore`／`persistRetryNeeded`（C01 範圍）；leftover／通知已覆蓋 recovery 呈現。延伸 DTO 需 C01／C09。

### Spec 問題
1. Spec §5.1／§8.1 仍寫允許 2／3／4h 與 `limitDurationOnAC`；Fi A3 已定 3h 含 AC。建議 Opus 改版。

### 覆蓋誠實聲明
- V-INT-* 實機／curl 交 V01
- 真實 helper register／pmset／闔蓋硬體交核准後 V01

### C08 review fix r1（2026-10-13）— C8-1..C8-7
| ID | Fix |
|---|---|
| C8-1 | `.connecting` 時 bounded `status()` handshake；E2E 不握手 |
| C8-2 | `externalInterference` latch：停心跳／禁 set(true)；busy／Agent／設定關閉才清 |
| C8-3 | SettingsStore／controller 強制 ≤3h＋AC 限時 |
| C8-4 | leftover `.recoveryBlocked`＋recovery 通知；不誤標 foreign、不 acquire-as-repair |
| C8-5 | armed 通知以 aggregate busy 期為準（非來源 ID 集合） |
| C8-6 | 公開 `lidReading`／`isConfirmedNoLid`；noLid 禁 arm |
| C8-7 | hold `reason`：agentModeOff → lidGuardOff → blocked:* |

#### 測試
```
xcodebuild … -only-testing:ChorusAppTests （timeouts 60/120）
→ 516 tests / 69 suites；TEST SUCCEEDED；exit 0
ChorusCore native → 829 tests / 119 suites；exit 0
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。未 sudo／pmset／register／簽章／push。

### C08 review fix r2（2026-10-13）— C8-1／C8-2／C8-4／C8-7（Codex r2 NOT-FIXED）
| ID | Fix |
|---|---|
| C8-1 | C06 `RealPowerHelperXPCProxy`：invalidation／interruption 先 hop 再讀 handler；`withTimeout` reply hop MainActor；sync set 用 lock `ReplyBox`（不 hop，避免 shutdown 死鎖）。Off-actor reply／event 測經 client seam。 |
| C8-2 | 失敗 holding set 後先 `status()` 取 forced-off 證據；無證據則 `awaitingForcedOffEvidence` 禁 reacquire；safe reset 才清。 |
| C8-4 | handshake／refresh／set 路徑 `considerRecoveryHealth`；ordinary arm 對 recovery 三旗標 gate；unavailable＋recovery 通知。HTTP DTO 仍交 C01／C09。 |
| C8-7 | 獨立說明：partial（assertion XOR lid）仍給對應 `reason`；雙失效維持 agentModeOff→lidGuardOff→blocked:*。 |

#### 檔案
- C08：`LidSleepGuardController.swift`、`KeepAwakeController.swift`、對應 AppTests
- C06（C8-1 Required 協調）：`PowerHelperClient.swift`、`PowerHelperClientTests.swift`

#### 測試
```
xcodebuild … -only-testing:ChorusAppTests （timeouts 60/120）
→ 525 tests / 69 suites；TEST SUCCEEDED；exit 0
ChorusCore native → 829 tests / 119 suites；exit 0
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。未 sudo／pmset／register／簽章／push／PR／merge。

#### 給下游
1. NEW-1（clamp assignment 跳過 persist／reevaluate）本輪未修——見 `keepawake-c08-review-r2.md`。
2. HTTP helper DTO 仍無 recovery 三旗標（C01／C09）。
3. U01 須消費 `isConfirmedNoLid` 隱藏設定區。

### C08／V01FIX1 note（2026-10-13）
V1-1..V1-12 已在上方 Wave 4 `### V01FIX1` 段落記錄。C08 相關：`LidSleepGuardController`／`KeepAwakeController`＋AppTests；並協調改動 C01／C03／C05／C06／C07／C09／C10 檔案。App 572／72；Core 836／120。

## C10

### 確認（動手前）
- Doctor 報告型別**確實**位於 `Packages/ChorusCore/Sources/ChorusCore/Diagnostics/`（`Doctor.swift`／`DoctorRules.swift`／`DoctorFormatter.swift` 等）。
- 依 tasks §4：core 範圍僅動 `Diagnostics/Doctor.swift`、`Diagnostics/DoctorRules.swift` 與對應 `DoctorTests`；未把整個 `Diagnostics/*` 當無界授權。

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/Diagnostics/Doctor.swift` — optional `DoctorInputs.lidKeepAwake` 快照型別
- `Packages/ChorusCore/Sources/ChorusCore/Diagnostics/DoctorRules.swift` — 檢查 `keepawake.lid`「闔蓋防睡」；殘留 → warning
- `Packages/ChorusCore/Tests/ChorusCoreTests/DoctorTests.swift` — V-C10-1／V-C10-2
- `Chorus/Support/DoctorInputsCollector.swift` — 從 `keepAwake.lidGuard`／`sourceHub.reports` 組快照；reason 消毒
- `Chorus/Support/DiagnosticBundleExporter.swift` — 附 `helper-status.json`（allowlist，無 uid／pid）
- `Tests/ChorusAppTests/DoctorInputsCollectorTests.swift`
- `Tests/ChorusAppTests/DiagnosticBundleExporterTests.swift`

### 測試
```
ChorusCore native（指定 cache／scratch）→ 831 tests / 119 suites；exit 0

xcodebuild … -only-testing:ChorusAppTests （timeouts 60/120）— 第一輪：
→ 546 tests / 70 suites；僅 `DiagnosticBundleExporterTests.helperStatusAttachmentHasNoUIDOrPID`
  因 zip deflate 內容非明文而誤 assert `holderCount` 於 zip bytes（已修正為只檢查檔名）。
→ DoctorInputsCollector 全綠（含 V-C10-1／V-C10-2／JSON 含 keepawake.lid）

重跑被並行 U02 擋住：
→ `Chorus/UI/MenuBarView.swift` 呼叫不存在的 `lidGuard.resumeAfterPause()`，App 建置失敗。
→ C10 未改 UI；依指示以 ChorusCore + 第一輪 App 結果／靜態審查為準。
```
`.dd`／`.wave0-cache`／`.wave0-native-build` 測完已刪。
未 sudo／pmset／SMAppService.register／簽章／啟動 /Applications/Chorus.app／push／PR／merge。

### 驗收條件
- [x] V-C10-1：殘留 → warning；正常 → ok；診斷包附 helper status 且 JSON 不含 uid／pid
- [x] V-C10-2：`lidKeepAwake` optional（舊 evaluate 無新項目）；attachment 缺欄位可解；reason／forcedOff 消毒 path／uid／pid／token
- [x] `chorus doctor --json` 路徑會產出 `keepawake.lid`（collector → DoctorRules；單元測試覆蓋編碼）
- [x] 檔案範圍未越界（未碰 U01／U02／Localizable.xcstrings）

### 偏離／給下游
1. **availability 推導**：C08 未公開 `lidGuard.helper.availability`。doctor／診斷包以 `phase`（`.unavailable`）、`helperStatus != nil` → ready、`leftover == .unknownOwner` → unavailable、否則 `notRegistered` 推導。若需精確 SMAppService 狀態，建議 C08 加 `private(set) var helperAvailability`。
2. **診斷包來源**：`AppStateRegistry.keepAwake` 讀快取 status（與 HTTP status 同源），不同步打 XPC。
3. **A02**：`DoctorRules` 新增繁中字串「闔蓋防睡」等；catalog／英文翻譯交 A02。
4. **U02 並行**：`MenuBarView.resumeAfterPause` 編譯錯誤屬 U02／C08 API 缺口，非 C10。

### Spec 問題
無。

## U01

### Codex UI implementation — 2026-10-13
- Changed: `Chorus/UI/LidSleepSettingsSection.swift` (new), `Chorus/UI/SettingsView.swift` (one insertion after AgentDetectionControls), `Tests/ChorusAppTests/LidSleepSettingsPresentationTests.swift` (new), and explicitly authorized U01/U02 entries in `Chorus/Resources/Localizable.xcstrings` (English + zh-Hant; existing translations preserved).
- [x] Settings controls, helper status/actions, explanation sheet before enabling; cancel leaves master off. Inline removal confirmation; C06 verifies release/readback/other holders/recovery before unregister. Protocol repair stops on failed verified unregister, then restores the previous enabled setting only after success.
- [x] Fi §D: master default off, ≥30% battery choices, only 2/3h from allowedMaxHours filtered by approved ≤3h, fixed AC time limit, no absolute restoration claim. Confirmed no-lid hides Lid controls and refuses enable/install; C08 owns the policy prohibition.
- [x] Source toggles configure the hub immediately; Grok default off and §4.6 exact explanation. Nonblocking NSOpenPanel; executable-file validation off actor. Health does not invent an active process fallback. Valid lease counts update even after the bounded 10min approval polling window. Automation link opens an inline sheet with its real activation control and points to Diagnostics for CLI/token.
- [x] Current policy / contributing sources and off-mode residual warning; manual restore command is selectable text only. No command executed.
- [x] V-U01-1 presentation coverage, including safe repair sequencing and blocked removal.
- [ ] Coordinator: full App build/test and actual settings screenshots for not-installed / approval / enabled. No screenshots fabricated; this sandbox does not run Xcode App tests.
- Tests: native presentation harness (actual presentation model extracted from this UI file, actual formatter/renderer and actual three test files) → **14 tests / 3 suites passed**, exit 0; `/private/tmp/chorus-u0102-presentation-final.log`. Full Core → **833 tests / 120 suites passed**, exit 0; `/private/tmp/chorus-u0102-core.log`. New UI/tests Swift parse, XcodeGen generation, git diff --check pass. Initial Core attempt failed cache permissions; rerun with task-owned caches passed.
- Deviation: only the approved Fi overrides of the older spec selectors; no spec edited. User explicitly authorized the catalog additions although the older task ownership assigns catalog commits to A02. No commit made; A02 can polish these entries.
- Downstream: screenshots / Xcode runtime verification remain UNVERIFIED. Explanation confirmation is the only installation/repair trigger; appearance and tests do not register a helper. README changes remain A02's scope.

## U02

### Codex UI implementation — 2026-10-13
- Changed: `Chorus/UI/MenuBarView.swift` (KeepAwakeRow and private helpers only), `Chorus/UI/MenuBarLabel.swift`, `Chorus/UI/StatusIconRenderer.swift`, `Chorus/UI/LidMenuStatusFormatter.swift` (new), `Packages/ChorusCore/Sources/ChorusCore/StatusIcon.swift`, `Packages/ChorusCore/Tests/ChorusCoreTests/StatusIconTests.swift`, `Tests/ChorusAppTests/LidMenuStatusFormatterTests.swift` (new), `Tests/ChorusAppTests/StatusIconRendererTests.swift` (new); catalog entries shared with U01.
- [x] V-U02-1: all §8.3 phases plus no-lid/unknown-lid/unknown-power/recovery/other-holder, pending versus confirmed, fixed clock + timezone, unchanged grace/deadline, three-source truncation and full detail/health hover.
- [x] V-U02-2: actual AppKit image rendering compares held/pending/stale/foreign/off pixels. Independent solid monochrome corner dot, no width change; countdown/readout/headset battery layouts preserved. Core tests exhaustively gate wants/caller/system/ownership/freshness/recovery evidence. Off/no-residual has no extra row or badge; foreign/unknown/recovery/other-holder warnings stay visible with the master off (§14.2).
- [x] Pause 1h, approval and management actions, own-residual restore, selectable manual restore command (no shell execution). Status and icon never label a pending request as a confirmed hold.
- [ ] **Integration blocker: C08 has no `resumeAfterPause()` API** (state is private(set)). MenuBarView's requested resume action currently calls that exact missing method. User asked through the pending input request to have C08 owner add it or narrowly authorize the addition. No C08 file modified by U01/U02. Do not claim App build passes until this is resolved.
- Tests: same native harness / Core results as U01. App native source typecheck with SDK macros loaded explicitly identifies the missing resume method (`/private/tmp/chorus-u0102-app-typecheck2.log`); unconditional App build remains BLOCKED. Xcode build/test remains coordinator-owned. Conditional API-only typecheck uses an unshipped, unexecuted `/private/tmp/chorus-u0102-assumed-resume.swift` declaration solely to check the other UI types; it does not implement or verify resume behavior.
- Review: independent read-only reviewer found safe-repair/current-settings-status gaps, now fixed, and identified the remaining resume API blocker. No C10 diagnostics files touched.
- Spec/API issue for C08: add a main-actor `resumeAfterPause()` that clears `state.userPausedUntil` and calls `scheduleReevaluate()`; deterministic C08 behavior regression belongs to that owner. UI must not reach into private state or use Debug switches.
- [ ] Coordinator: real App UI screenshots / full integration tests, and C08 resume behavior. Manual hardware/helper/signing verification remains outside this task.
- No git commit/push, sudo/pmset execution, helper registration, system service changes, Orca changes, or README edits.

### Additional foreign-value regression / validation
- Foreign SleepDisabled=1 can have a caller holder without helper ownership (ledger acquire). Presentation now derives that warning from helperStatus even if C08 leftover is nil, instead of displaying pending forever. It never overrides or restores this value automatically. Settings and menu share the same pure resolver.
- RED: `/private/tmp/chorus-u0102-foreign-red.log` missing resolver API, exit 1; GREEN: `/private/tmp/chorus-u0102-presentation-final.log`, **15 tests / 3 suites passed**, exit 0.
- Catalog audit: **90** U01/U02 entries have en + zh-Hant; all pre-existing locale translations unchanged. Scope audit passes; only pre-existing untracked AGENTS.md lies outside the authorized UI changes.

- Fresh conditional API source typecheck after the foreign warning change: exit 0 (`/private/tmp/chorus-u0102-app-conditional-typecheck.log`). All App source compiled for typechecking with SDK macros explicitly loaded and the unexecuted, unshipped resume declaration seam. This is **not** a successful unconditional App build; the real C08 resume API is still required.

---

## A02

### 改了哪些檔案
- `README.md`
- `README.en.md`
- `Chorus/Resources/Localizable.xcstrings`（已審核並確認所有 90 個闔蓋／防睡新 key 之繁中與英文翻譯完整度）

### 測試指令與結果
- 執行 JSON catalog 稽核腳本：
  - 1,109 個 key 格式正確無損。
  - 所有 90 個 keepawake／lid 相關鍵值均具備完整的 `zh-Hant` 與 `en` 翻譯，無缺漏。
  - 鍵名保持原樣未改動，未修改任何 Swift 原始碼。
- 測試指令：
  - `git diff README.md README.en.md` 驗證中英文版功能描述、規格、範例與疑難排解指令完全一致。
  - 未執行 git commit／push，未執行 sudo，未執行 pmset。

### 驗收條件逐條打勾
- [x] catalog 中沒有缺少英文翻譯的新 key（90 個新 keepawake 鍵值均具備對應英文與繁中翻譯，格式字元 `%lld`、`%@` 匹配）。
- [x] README 中文版與英文版新增「闔蓋防睡」功能描述：
  - 預設關閉（default off）
  - 用電池時電量底線 ≥30%（30% battery floor）
  - 溫度達「嚴重」（`.serious`）即解除（thermal serious release）
  - 最長 3 小時（即使接上 AC 電源亦套用，3h max incl AC）
  - 無蓋機種（如 Mac mini 等）不支援且隱藏（no-lid models unsupported）
- [x] README 中文版與英文版新增特權輔助程序說明（安裝、允許、移除）。
- [x] README 中文版與英文版新增 `chorus keepawake hold/release/status` 範例與 wrapper 心跳迴圈腳本。
- [x] README 中文版與英文版新增「疑難排解：闔蓋防睡殘留」（Troubleshooting: lid-closed keep-awake leftover）段落：
  - 提供檢查指令 `pmset -g | grep SleepDisabled`
  - 提供還原指令 `sudo pmset -a disablesleep 0`
  - 明確說明輔助程序異常崩潰或當機時可能需要手動還原，絕不宣稱「一定還原」（never claim it always restores）。
- [x] 嚴格限制在 A02 檔案範圍內（`README.md`、`README.en.md`、`Chorus/Resources/Localizable.xcstrings`）。
- [x] 未執行 git commit / git push，未執行 sudo 或 pmset。

### 偏離 spec 的地方及理由
- 無偏離。依據 Fi 於 approvals §D 之裁決（接受當機時手動還原風險，文案不宣稱保證還原；無蓋機型隱藏並禁止 arm；時限 3 小時含 AC；電量底線 30%）。

### 給下游的注意事項
- README 中英版內容已同步就緒。下游驗證（V01）可依 README 中的指令與步驟進行疑難排解測試（M-9）。


## PERF-1

### Cursor FIX3 — 2026-10-13 (NEW-1..NEW-4)

**Commits** (branch `gixiphy/chorus-keepawake`):
- `9796e1f` fix(keepawake): PERF-1 NEW-1 clear vs in-flight async saves
- `ca7832a` fix(keepawake): PERF-1 NEW-2 flush chains latest revision
- `77177d3` fix(keepawake): PERF-1 NEW-3 wake latch needs fresh healthy status
- `54a550e` fix(keepawake): PERF-1 NEW-4 healthy evidence cancels armed retry

### 改了哪些檔案
- `Chorus/Display/LidStateMonitor.swift` — clear accounts for in-flight; revision gate before mutation + undo raced writes; flushPending submits/chains latest revision; completion chains leftover pending; requestSave coalesce-back-to-committed when pending ahead
- `Chorus/Display/LidSleepGuardController.swift` — wake does not clear latch from cached ready; revoke hold confirmation on failed status; refresh coordinator drains missed wake after stale completed task; cancelArmedEvidenceRetry generation on fresh healthy evidence
- `Tests/ChorusAppTests/PowerHelperClientTests.swift` — PERF1-NEW-1 / PERF1-NEW-2
- `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift` — PERF1-NEW-3 / PERF1-NEW-4

### 測試指令與結果
```
swift test --package-path Packages/ChorusCore
→ 840 tests / 120 suites passed

xcodegen generate
xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug \
  -derivedDataPath "$PWD/.dd" CODE_SIGNING_ALLOWED=NO test \
  -only-testing:ChorusAppTests -only-testing:ChorusPowerHelperTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120
→ ChorusAppTests 616 passed; ChorusPowerHelperTests 53 passed; TEST SUCCEEDED
```

### 驗收條件
- [x] NEW-1: gated save → clear → fresh-store restore absent; obsolete revision rejected before/undone after mutation
- [x] NEW-2: flush with newer coalesced pending + older in-flight returns; latest revision committed; no stranded waiters
- [x] NEW-3: failed wake status keeps awaitingForcedOffEvidence; no reacquire from cached ready; fresh healthy status clears latch
- [x] NEW-4: recoveryBlocked → healthy-idle cancels armed retry; zero further .retry refreshes
- [x] No push/PR/merge/sudo/pmset/helper register; no Chorus.app launch outside tests

### 偏離 spec
無。Helper XPC / signing / fixed pmset argv / ownership unchanged.

### 給下游
- NEW-1 production (revision gate + clear in-flight) and NEW-2 flush/chain share `LidClosedSessionCoordinator`; NEW-2 commit adds the flush regression while production landed with NEW-1.
- NEW-4 cancelArmedEvidenceRetry / generation lands with NEW-3 controller commit; NEW-4 commit is the idle-retry regression.
- Review2 R1–R7 remain accepted; only NEW-1..NEW-4 addressed this round.

### Cursor FIX3 R-round3 — 2026-10-13 (R1/R3/R4/R5/R7; R2/R6 already closed)

**Commits** (branch `gixiphy/chorus-keepawake`):
- `ade92b0` / `cd221b2` fix(keepawake): PERF-1 R1 round3 require enabled SM before ready (+ fresh SM after invalidate)
- `4a82120` fix(keepawake): PERF-1 R4 round3 register needs new-epoch enabled sample
- `7ab1b8c` fix(keepawake): PERF-1 R3 round3 coordinate register and evidence retries
- `9bc4f04` fix(keepawake): PERF-1 R7 round3 latency overlap and gate cleanup
- `5863204` fix(keepawake): PERF-1 R5 round3 preload off-main and await shutdown drain

### 改了哪些檔案
- `Chorus/Display/PowerHelperClient.swift` — ready only with current-epoch enabled SM; invalidate publishes connecting + clears SM/floor clock; empty-cache floor falls through to physical read; register handshake only after enabled sample; versionMismatch still publishes without SM
- `Chorus/Display/LidSleepGuardController.swift` — register/unregister/detectLeftover/retry via refreshHelper; generation/cancellation gates; shutdown awaits drain ~250ms
- `Chorus/Display/LidStateMonitor.swift` — async preload; LoadState; absent/corrupt clears without sync backend on MainActor
- `Tests/ChorusAppTests/PowerHelperClientTests.swift` — PERF1-R1/R4/R5/R7 round3 + refresh-before-ready in lifecycle tests
- `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift` — PERF1-R3/R7 round3

### 測試指令與結果
```
swift test --package-path Packages/ChorusCore
→ 840 tests / 120 suites passed

xcodegen generate
xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug \
  -derivedDataPath "$PWD/.dd" CODE_SIGNING_ALLOWED=NO test \
  -only-testing:ChorusAppTests -only-testing:ChorusPowerHelperTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120
→ ChorusAppTests 620 passed; ChorusPowerHelperTests 53 passed; TEST SUCCEEDED
```

### 驗收條件
- [x] R1: delayed XPC / post-invalidation status never restores ready without fresh enabled SM; invalidation leaves ready immediately
- [x] R3: register requiring approval starts SM-only retry; healthy recovery clears evidence waiting; coordinator gates
- [x] R4: register during blocked getter fails boundedly without handshake/ready; replacement read preserved
- [x] R5: blocked read/write sinks do not delay MainActor; shutdown drain awaited within budget
- [x] R7: worker-overlap / latency / counted backoff / gate cleanup
- [x] No push/PR/merge/sudo/pmset/helper register; no Chorus.app launch outside tests

### 偏離 spec
無。

### 給下游
- Ready path now requires `refreshAvailability` (enabled SM sample) before `status()` can publish `.ready`; lifecycle tests updated accordingly.
- `invalidateConnection` clears `lastPhysicalStartAt`; empty-cache + floor no longer returns early without a physical read.


### Codex direct fixes — review3 (2026-10-13; uncommitted)

Scope: R3, R5, R7, NEW-5 through NEW-10 in keepawake-perf1-review3.md. Base HEAD is cd221b2754aa7dd2a43f60327bee3a67019eb948 on gixiphy/chorus-keepawake. Source changes are limited to the three Display files below and their two existing test files; spec, localization, helper, signing, project generation and release files are unchanged.

| Finding | Changed files | Regression tests |
| --- | --- | --- |
| R3 | Chorus/Display/LidSleepGuardController.swift; Chorus/Display/PowerHelperClient.swift; Tests/ChorusAppTests/LidSleepGuardControllerTests.swift | perf1R3StaleEvidenceAcrossMutation (success/failure × release/removal/shutdown); perf1R3EvidenceWaitsForMutation; perf1HoldingRecoveryBlockRetainsRetry; perf1DeferredSMRefreshGatesEvidenceXPC |
| R5 | Chorus/Display/LidStateMonitor.swift; Chorus/Display/LidSleepGuardController.swift; both test files | perf1New6CleanupIOOutsideLock; perf1New7ShutdownSharedDeadline; perf1R5AcquireWaitsForStartDurability; perf1ClosedHoldingResumesHeartbeatsAfterDurability |
| R7 | Tests/ChorusAppTests/LidSleepGuardControllerTests.swift; Tests/ChorusAppTests/PowerHelperClientTests.swift | perf1R7MainActorLatencyDuringSlowStatus; perf1R7ApprovalBackoffCallCounts; perf1R7RecoveryBackoffCallCounts; singleFlightAndMapping; twentyOverlapping |
| NEW-5 | Chorus/Display/LidStateMonitor.swift; Chorus/Display/LidSleepGuardController.swift; both test files | perf1New5LoadingPreservesSession (expired/latched); perf1New5MonitorLoadingPreservesLatch |
| NEW-6 | Chorus/Display/LidStateMonitor.swift; Tests/ChorusAppTests/PowerHelperClientTests.swift | perf1New6CleanupIOOutsideLock (20 actual controller updates while correction removal is blocked) |
| NEW-7 | Chorus/Display/LidSleepGuardController.swift; Chorus/Display/LidStateMonitor.swift; Tests/ChorusAppTests/LidSleepGuardControllerTests.swift | perf1New7ShutdownSharedDeadline (responsive/silent helper; successful persistence before return) |
| NEW-8 | Chorus/Display/LidSleepGuardController.swift; Tests/ChorusAppTests/LidSleepGuardControllerTests.swift | perf1New8StatusFailureRecoversHeartbeats; perf1ClosedHoldingResumesHeartbeatsAfterDurability |
| NEW-9 | Chorus/Display/PowerHelperClient.swift; Chorus/Display/LidSleepGuardController.swift; both test files | perf1New9DisconnectStormFloor (direct invalidation/connection events); registerBypassesFloor; perf1DeferredSMRefreshGatesEvidenceXPC |
| NEW-10 | Chorus/Display/LidStateMonitor.swift; Tests/ChorusAppTests/PowerHelperClientTests.swift | perf1New10CancelledFlushIsBounded; flushChainsLatestRevisionNoStrandedWaiters |

Implementation decisions:
- Loading is a distinct restore result. Closed monitor/controller paths await validated preload rather than creating a replacement origin/latch. Confirmed open still clears the session.
- Persistence correction I/O stays on the serialized backend queue outside the memory lock. Durability waits remove their continuations on cancellation. Shutdown submits a backend completion marker before release; both operations use one monotonic one-second deadline with a small return margin. No MainActor task is needed to signal drain completion.
- All controller evidence reads share a task and a mutation epoch. Release/removal supersede prior read outcomes; new evidence waits for mutation completion. A newer explicit leftover detection can supersede an older detection. Both success and failure paths check lifecycle, cancellation and generations.
- Failed holding status enters a nonholding evidence gate, releases safely, and recovers through fresh evidence plus confirmed acquisition. Recovery health discovered while holding also rearms the evidence retry after release. Pending closed-session durability gets a waiter even when already holding, so heartbeats resume after persistence.
- The physical query start clock survives invalidation. One pending timer respects the five-second floor; only the existing post-registration/unregistration bypass may skip it. Current-epoch enabled evidence is exposed through the app client protocol and gates controller XPC evidence; the root XPC contract remains exactly setSleepDisabled/status.
- Tests use cancellation-aware evidence gates, five-second maximum worker gates, completion signaling with per-wait deadlines, explicit timeLimit traits, and deferred cleanup. MainActor sentinels are awaited through bounded completion signaling, never a structured race against task.value.

Verification evidence:
- New review3 tests were run before fixes: 23 expected issues across stale completions, loading, cleanup latency, shutdown bound, heartbeat recovery, physical floor and durability cancellation. The final reviewer found three further edges; armed→closed heartbeat and all three newly observed recovery flags failed before their fixes. The new deferred-SM test initially exposed an actor-isolated test closure; its worker closure is now explicitly Sendable.
- swift build --package-path Packages/ChorusCore --scratch-path /private/tmp/chorus-keepawake-codex-build: PASS.
- swift test --package-path Packages/ChorusCore --scratch-path /private/tmp/chorus-keepawake-codex-build: PASS, 840 tests / 120 suites; /private/tmp/chorus-codex-core.log.
- Xcode required explicit -project Chorus.xcodeproj (there are two project directories). Initial sandbox failures were compiler-cache/service access restrictions; approved escalation allowed fake-only tests. Generated/temporary build artifacts stay outside the tracked source files.
- Targeted Xcode run after the three final review fixes: PASS, 78 tests / 3 suites. Final expanded run and exact timing values recorded below after completion.

Review: requesting-code-review dispatched one read-only reviewer. Its three Important findings were addressed with the additional tests above. Real SM approval/signing/hardware sleep behavior remains 未確認 and belongs to the approved verifier. Parser/root-helper/UI code outside this patch was not re-reviewed.

No commits, push, PR, merge, sudo, pmset, helper registration/launch or system-setting changes were performed. Tests inject SM/XPC operations. Coordinator should commit only the five modified Swift files; ignored docs remain local. Pre-existing untracked .dd/ remains untouched.

Spec deviations: none; shutdown's deadline includes both release and persistence. The five-second floor intentionally changes old tests that assumed immediate resampling after invalidation; those tests now inject time and advance to t=5 before checking the replacement connection's readiness.
Spec issues: none identified for this patch.

Final expanded verification: PASS — 110 tests / 8 suites, TEST SUCCEEDED, exit 0. Log: /private/tmp/chorus-codex-broad.log. Exact command:

```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination platform=macOS \
  -derivedDataPath /private/tmp/chorus-keepawake-codex-dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:ChorusAppTests/LidSleepGuardControllerTests \
  -only-testing:ChorusAppTests/PowerHelperClientPERF1StatusTests \
  -only-testing:ChorusAppTests/LidClosedSessionStorePERF1R5Tests \
  -only-testing:ChorusAppTests/PowerHelperClientConnectionTests \
  -only-testing:ChorusAppTests/PowerHelperClientUnregisterTests \
  -only-testing:ChorusAppTests/PowerHelperClientShutdownTests \
  -only-testing:ChorusAppTests/LidClosedSessionStoreTests \
  -only-testing:ChorusAppTests/LidClosedSessionStorePERF1Tests
```

Measured final run (monotonic): 20 slow-SM controller updates maximum 0.01425 ms, actual release update 0.017208 ms, MainActor sentinel 0.035125 ms. Raced-save correction while blocked: all 20 controller updates total 0.041584 ms and sentinel 0.014584 ms. Shutdown with successful drain: responsive helper 0.0315495 s; silent helper 0.996049958 s. Physical approval/recovery schedules assert exactly five SM reads through t=75; recovery additionally asserts five read-only XPC statuses and zero acquires. Disconnect storms assert zero extra physical reads before t=5 and one permitted post-register bypass.

Acceptance:
- [x] R3: serialized mutation/evidence admission and stale success/failure guards; release/removal/shutdown races covered; recovery retry survives release.
- [x] R5: no backend I/O under the memory lock; first-start durability gates acquisition; pending writes drain within the shared shutdown bound.
- [x] R7: confirmed holding precedes slow-SM release; worker entry/finish prove overlap; physical schedules counted; every new wait has a deadline and cleanup.
- [x] NEW-5: blocked expired/latched preload preserves origin/latch with zero acquire; monitor does not overwrite it.
- [x] NEW-6: blocked stale-save correction permits actual controller updates and bounded MainActor sentinel below 50 ms.
- [x] NEW-7: actor-independent drain finishes before return when backend completes; silent-helper total shutdown below one second.
- [x] NEW-8: failed status releases and revokes display; healthy evidence plus confirmed acquisition restarts continuing heartbeats; closed-session durability also resumes heartbeats.
- [x] NEW-9: invalidation retains physical-start clock; single deferred refresh respects floor; controller waits for current enabled SM evidence before handshake.
- [x] NEW-10: withheld durability times out through bounded signaling; cancelled flush detaches promptly with cleanup, without a structured task-value race.
- [x] git diff --check passes; HEAD unchanged; all changes uncommitted; only five authorized Swift files in tracked diff.

### Codex FIX2 — R3/R7 final-check follow-up (base e43ac67; uncommitted)

Changed only Chorus/Display/LidSleepGuardController.swift, Chorus/Display/PowerHelperClient.swift, Tests/ChorusAppTests/LidSleepGuardControllerTests.swift and Tests/ChorusAppTests/PowerHelperClientTests.swift.

- R3: registration/removal claim the same mutation slot only after an active release completes. Pending user operations forbid acquisition and new evidence, duplicate false requests share the active release, and waiting/cancelled operations do not invalidate its generation. User-operation waits are cancellation-aware and shutdown resumes them. An armed approval/recovery retry is restored after failed user operations.
- R3: concurrent launch/detect/settings events share one refresh task and its evidence result. Detection reuses that result, with an evidence revision checked after the probe; newer applied status, revocation or read failure invalidates reuse. Registration can reuse the client's freshly validated status only while generation/readiness/availability remain current. No root XPC protocol changes.
- R7: added perf1Fix2ConcurrentLaunchDetectSettings (join during blocked SM read or blocked XPC handshake; exactly one physical read and handshake), perf1Fix2UserOperationsDuringBlockedRelease (real PowerHelperClient, register/remove × idle/toggle, extra concurrent toggles, zero service/status work before release and exact post-operation counts), perf1Fix2ProbePreservesNewerSettingsEvidence (three recovery flags, other holder, failed read), and perf1Fix2FailedUserOperationRetainsRetry (register/remove × approval/recovery with healthy subsequent recovery).
- All new cases have explicit one-minute test limits, per-wait deadlines, deferred task/gate/reply cleanup, and fake SM/XPC operations. The prior removal fixture now blocks removal rather than also blocking its initial serialized release.
- The existing offMainActorProbe test now injects fake output and verifies worker execution; the async probe accepts a Sendable read dependency with unchanged production default. Full App tests therefore execute no real pmset probe.

Red/green evidence: the initial two tests reproduced 18 issues on e43ac67; read-only final review found freshness and failed-operation retry interactions, whose additional cases reproduced 27 issues before fixes. Final targeted run: 82 tests / 3 suites PASS. Core: 840 tests / 120 suites PASS, /private/tmp/chorus-codex-core.log. Full App/helper final result recorded below.

Exact commands:
```sh
swift test --package-path Packages/ChorusCore --scratch-path /private/tmp/chorus-keepawake-codex-build
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination platform=macOS \
  -derivedDataPath /private/tmp/chorus-keepawake-codex-dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:ChorusAppTests -only-testing:ChorusPowerHelperTests
```

- [x] R3 user set/toggle/register/unregister coordination and single shared concurrent handshake.
- [x] R7 required concurrent call-count and real-client blocked-release regression coverage.
- [x] Newer evidence preserved after blocked probe; failed user operation restores recovery chain.
- [x] No commits, sudo, pmset, real helper registration/launch, push, PR, merge or release.
- [x] Root helper protocol/signing/argv/ownership boundaries unchanged; Release contains no new test switches.
- [x] No spec changes/deviations. Real signing, service approval and hardware behavior remain 未確認.

Final full verification: PASS, App 637 / 75 suites and helper 53 / 9 suites; TEST SUCCEEDED, exit 0. Log: /private/tmp/chorus-codex-fix2-full.log. Core 840 remains green. git diff --check PASS; HEAD remains e43ac6780e7364e640c767db47b0c823159a821c, four modified Swift files uncommitted, pre-existing .dd/ untouched.

## MERGE — agent ∨ load（Cursor，2026-10-13）

### 改了哪些檔案
- Core：`Packages/ChorusCore/Sources/ChorusCore/KeepAwake.swift`（刪 `.whileSystemBusy`、legacy Codable、OR `shouldHold`）、`DeviceBackup.swift`（註解）
- Core 測試：`KeepAwakeTests.swift`
- Controller：`KeepAwakeController.swift`、`KeepAwakeSourceHub.swift`（`isRunning`）、`SystemLoadMonitor.swift`（`isRunning`）
- UI：`KeepAwakeWorkStatusFormatter.swift`（新）、`SystemLoadStatusFormatter.swift`、`MenuBarView.swift`、`SystemLoadSettingsSection.swift`、`SettingsView.swift`、`LidSleepSettingsSection.swift`
- 其他：`TestHooks.swift`、`SettingsStore.swift`（註解）、`README.md`／`README.en.md`、`Localizable.xcstrings`
- 測試：`KeepAwakeControllerTests.swift`、`SystemLoadMonitorTests.swift`、`KeepAwakeWorkStatusFormatterTests.swift`（新）
- 計畫審查：`docs/plans/keepawake-merge-agent-load-review.md`
- **未改**：PowerHelper、PowerHelperClient、LidSleepGuard*、pmset、`docs/spec.md`

### 測試指令與結果
```sh
{ swift test --package-path Packages/ChorusCore --scratch-path ~/Library/Caches/DevBuild/Chorus_merge-core ; } 2>&1 | xcsift -f toon -w -E
# → 841 tests PASS

{ xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination platform=macOS \
    -derivedDataPath ~/Library/Caches/DevBuild/Chorus_merge-dd CODE_SIGNING_ALLOWED=NO \
    -only-testing:ChorusAppTests ; } 2>&1 | xcsift -f toon -w -E
# → 657 PASS

{ xcodebuild test ... -only-testing:ChorusPowerHelperTests ; } 2>&1 | xcsift -f toon -w -E
# → 53 PASS
```
§4 privileged diff（對 `eb3170a`）：空。

### 驗收條件
- [x] 選單只剩一個「有 agent 工作或高負載時」
- [x] Core 841、App 657、helper 53 全綠
- [x] §4 diff 空
- [x] legacy load 旗標 restore → 合併模式、正規化 agent=true load=false
- [x] FocusSnapshot legacy `whileSystemBusy` 可解
- [ ] 手動 E2E（Debug `setKeepAwake load` + CPU）— 未跑，留給驗證者
- [x] formatter §1.2 表格有單元測試
- [x] xcstrings 新 key 有 en／zh-Hans
- [x] Release 無新測試開關

### 偏離／Ruling
- docs 被 gitignore（A7）；依實作 prompt 對計畫／審查／decisions `git add -f`
- AGENTS 原定 Localizable／README 屬 A02／A01；本合併任務依計畫一併改並 commit
- FocusSession 測試改測 `FocusSnapshot`（`keepAwake` 在 snapshot 上）

### spec 問題（交給 Opus）
- §1.3「高負載模式」措辭需改成合併模式語意

### 給下游
- Codex：請審 `KeepAwakeController` 合併語意（willSleep 不再無條件放 assertion；Lid busy 仍只看 hub）
- 手動 E2E 與 Activity Monitor 耗電比較未做

## B139

### 改了哪些檔案
- `Chorus/Display/PowerHelperClient.swift` — `@Sendable` XPC 回呼／handlers；one-shot gate；`#if DEBUG` `init(testConnection:)` + `invalidateConnectionKeepingHandlersForTesting()`；`PowerHelperXPCProxying: Sendable`
- `Tests/ChorusAppTests/PowerHelperXPCIsolationTests.swift`（新）— X1–X6
- `Tests/ChorusAppTests/PowerHelperClientTests.swift` — Fake `@Sendable` 簽名 + X7
- `Tests/ChorusAppTests/LidSleepGuardControllerTests.swift` — S1／S2
- `project.yml` — build 139
- `docs/plans/b139-xpc-callback-isolation.md`、`b139-xpc-callback-isolation-review.md`、`docs/decisions.md`（D-2026-10-13c）

### 測試指令與結果
```
swift test --package-path Packages/ChorusCore → 843 / 120 suites；exit 0
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -derivedDataPath ~/Library/Caches/DevBuild/Chorus_b139 -only-testing:ChorusAppTests → 683 / 78 suites；exit 0
xcodebuild test … -only-testing:ChorusPowerHelperTests → 53 / 9 suites；exit 0
Release build → success；nm 無 testConnection／KeepingHandlers 符號
```

### 紅燈證據（修前 trap）
- 檔案：`~/Library/Logs/DiagnosticReports/Chorus-2026-10-13-213112.ips`（副本 `/tmp/chorus-b139/Chorus-2026-10-13-213112.ips`）
- `EXC_BREAKPOINT (SIGTRAP)` on queue `com.apple.NSXPCConnection.user.endpoint`
- `_dispatch_assert_queue_fail` ← `swift_task_isCurrentExecutor…` ← XPC reply block（X3 `x3LiveReplyPath`，修前）
- 註：anonymous dead endpoint **不**觸發 errorHandler（X1／X2 逾時）；改用 missing-mach fallback（計畫 §3.1 允許）

### 驗收條件
- [x] Core 843
- [x] App ≥683（實得 683）
- [x] helper 53
- [x] 紅燈 `.ips` 堆疊已記錄
- [x] T1–T4 NSXPC closures 皆 `@Sendable` literal；L1–L6 `@Sendable`
- [x] X7 one-shot／ReplyGate；proxy 層 OneShotReply1／2
- [x] sync set 無 MainActor hop；X6 <1s 回 false
- [x] spec §11：未改 helper／ChorusCore 協定；Release 無測試 seam；仍 `.privileged` + code signing requirement
- [x] `Localizable.xcstrings` 未改
- [ ] 手動 M1–M3（Fi／核准驗證者；agent 不 sudo）

### 偏離與理由
1. dead fixture 用 missing machServiceName，不用 anonymous invalidate（RED 實測後者不起 errorHandler）
2. X4 用 DEBUG `invalidateConnectionKeepingHandlersForTesting()`（listener 端 invalidate 在 hosted 環境會先收到 `.interrupted` 或不觸發）
3. `PowerHelperXPCProxying` 加 `Sendable`（捕捉 `created` 進 `@Sendable` onConnectionEvent 所需）
4. interruptionHandler（T4）無自動化測試——與 T3 共用 `installConnectionHandlers()`；手動 M2

### 給下游
- Claude＋Codex 雙審（D-2026-10-13／計畫 §7）後才能請 Fi 准 push／PR
- 手動 M1–M3 需 Fi 執行 `launchctl bootout`（agent 不碰 sudo）

---

## P0（Cursor，2026-10-14，perf／idleblank）

### 改了哪些檔案
- `Chorus/Support/DiagnosticLog.swift`（`ChorusLog.event`、level 分流、`KeepAwakeLogEvent`）
- `Tests/ChorusAppTests/DiagnosticLogTests.swift`
- `docs/decisions.md`（D-2026-10-14；先前 commit）

### 測試
```
swift test --package-path Packages/ChorusCore → 843 passed
xcodebuild test -scheme Chorus -only-testing:ChorusAppTests/DiagnosticLogTests → 通過（見 review-w1-claude）
```

### 驗收條件
- [x] notice／info／error 落地；debug 不落地
- [x] KeepAwake 事件名常數（assertion／throttle／idle）
- [ ] 實機 `log show` 可見性（P5／未確認）

### 偏離／下游
- 無。P1／P2 用 `KeepAwakeLogEvent` 與 debug 彙總。

---

## P1（Cursor，2026-10-14，perf／idleblank）

### 改了哪些檔案
- `Chorus/Display/KeepAwakeController.swift`（assertion 持有快取、喚醒／60s 保底重驗）
- `Tests/ChorusAppTests/KeepAwakeControllerTests.swift`
- review fix `f6c05a6`：event key 排序、released `type`、recreated `trigger`

### 測試
```
xcodebuild test … KeepAwakeControllerTests／DiagnosticLogTests → 70 passed（f6c05a6）
swift test --package-path Packages/ChorusCore → 843 passed
```

### 驗收條件
- [x] 穩態 100× reevaluate 不查 `isActive`
- [x] 喚醒／session／保底重驗與失敗重試、ID=0
- [x] 只釋放本程序 assertion
- [ ] M5 實機 sample／`pmset -g assertions`（P5）

### 偏離／下游
- major #1（高頻 Task 迴圈）交 P2；喚醒必須繞過 P2「輸入未變」捷徑（已在 P2 保留）。

---

## P2（Cursor，2026-10-14，perf／idleblank）

### 改了哪些檔案
- `Chorus/Display/KeepAwakeController.swift`
- `Chorus/Display/KeepAwakeSourceHub.swift`
- `Tests/ChorusAppTests/KeepAwakeControllerTests.swift`
- `Tests/ChorusAppTests/KeepAwakeSourceHubTests.swift`
- `docs/plans/keepawake-handoff.md`（本段）

### 回授鏈（計數／程式推導）
1. **主鏈（對應 M5 `completeTaskWithClosure`）**：`KeepAwakeController.performReevaluation` → `lidGuard.update`（`suppressOnChange=true`）→ Lid 內部若 `pendingReevaluate` 則 `Task { Lid.reevaluate() }` → 離開 update 後 `suppressOnChange=false` → `publish()` → `lidGuard.onChange` → 再進 controller reevaluate；舊實作再用 `pendingReevaluate` + `Task { reevaluate() }` 無界自激。
2. **次鏈**：`hub.onBusyChanged`／`systemLoad.onDecisionChanged`／`powerSource.onChange` 在 reevaluate 期間重入 → 舊 `pendingReevaluate` Task 放大。
3. **非主因**：`sourceHub.configure` 同設定已 idempotent；相同 busy／reports 的 `recompute` 本就不通知（P2 補 `notifyStats.suppressedIdentical`）。
4. 風暴測試計數：`triggeredByReason["hub"]`／`["lid"]` 各 ≥100，但 `executed ≤ 5`（trailing coalesce + 輸入快照 no-op）。

### 實作要點
- 單一入口 `requestReevaluation(reason:urgency:)`：一般 callback **250ms trailing coalesce**；wake／tick／settings／busy 布林翻轉／power floor trip 為 immediate／safety。
- 輸入快照相同且非 verify／duration 到期／awaiting create 重試 → 略過 assertion／lid／idle 副作用；UI `remainingSeconds` 仍更新。
- review **#6**：`powerSource.onChange` → `markAssertionsNeedVerify()`。
- review **#7**：`KeepAwakeCreateErrorThrottle`（60s／type，彙總 suppressed）。
- review **#5**：本交接 P0／P1／P2 段落。
- `makeController` 預設私有 `NotificationCenter`（review #4）。

### 測試
```
swift test --package-path Packages/ChorusCore
→ 843 passed

xcodebuild test -scheme Chorus -derivedDataPath /private/tmp/chorus-perf-dd \
  -only-testing:ChorusAppTests/KeepAwakeControllerTests \
  -only-testing:ChorusAppTests/KeepAwakeSourceHubTests
→ 81 passed（含 P2 風暴／hub identical recompute）
```

### 驗收條件
- [x] 100 相同一般回呼 → ≤5 次實際 `executed`
- [x] 相同輸入不 create／release；wake 仍強制 verify
- [x] power floor trip 不被 debounce 延後
- [x] create failure log 節流單元測試
- [x] shutdown 取消待排 coalesce
- [x] 非同步測試 5s 截止／suite `.timeLimit(.minutes(1))`
- [ ] M5 實機 5 分鐘 ps／sample（P5）

### 偏離／給下游
1. hub／load **布林翻轉**用 immediate（否則 lease hold 測試與 CLI hold 回應會看到過期 isHolding）；細節變更仍 coalesce。
2. Lid 內部仍可能自排 Task；靠 controller 側 no-op 跳過 `lidGuard.update` 斷鏈。未改 `LidSleepGuardController.swift`（非 P2 檔案範圍）。
3. 節流彙總 `keepawake.throttle.summary` 為 **debug**（每 60s），不落地檔案。

### P1 R2（Codex 退回修正，2026-10-14）
- display／system **各自** `last*AssertionVerifyAt`；新建另一類不得延後未檢查舊 ID。
- 失效撤銷記 `assertion.released`（`reason=inactive`、`trigger`、舊 id／type）；重建失敗記 `assertion.recreated result=failed previousId=…`。
- 測試：`perTypeVerifyDeadlineNotDelayedByOtherCreate`、`repeatedSystemToggleDoesNotStarveDisplayVerify`、`inactiveDropLogsReleasedAndRecreateFailureRecovery`。

### P2/P3 回授斷鏈（2026-10-14）
- `LidSleepGuardController.publish`：語意快照相同不通知；helperStatus／leftover／forced-off／錯誤欄位變更仍會 publish。
- 測試：`identicalPolicyDoesNotRepublish`、`lidKeepAwakeFeedbackConverges`（MainActor 外 5s 截止）。
- 不碰 PowerHelper／PowerHelperClient。

---

## P4（Cursor，2026-10-14，perf／idleblank）

### 改了哪些檔案
- `Packages/ChorusCore/Sources/ChorusCore/AgentIdleBlank.swift`（`IdleBlankSignal`／`AgentIdleBlankProtection`；只有全部 inactive 才 blank；無效 idle 保守）
- `Packages/ChorusCore/Tests/ChorusCoreTests/AgentIdleBlankTests.swift`（真值表：媒體／全螢幕、遠端、foreign assertion、unknown、無效 idle、3/5/10/15）
- `Chorus/Display/AgentIdleBlanker.swift`（注入保護讀取器；外部 assertion 僅接近門檻／快取失效時查；blank／restore notice）
- `Chorus/Display/IdleActivityReaders.swift`（**新增**：CG idle ∩ HIDIdleTime 取 min；全失敗 → `.nan`）
- `Chorus/Display/IdleBlankProtectionReaders.swift`（**新增**：前景全螢幕、遠端／螢幕共享 bundle＋`kCGSessionOnConsoleKey`、`IOPMCopyAssertionsByProcess` 排除本 PID）
- `Tests/ChorusAppTests/AgentIdleBlankerTests.swift`
- 本機已 `xcodegen generate`（**不**提交 `*.xcodeproj`）

### 測試
```
swift test --package-path Packages/ChorusCore
→ 851 tests in 120 suites passed

xcodebuild test -scheme Chorus -derivedDataPath /private/tmp/chorus-perf-dd \
  -only-testing:ChorusAppTests/AgentIdleBlankerTests
→ status: success，passed_tests: 9
```

### 驗收條件
- [x] Core policy：media／fullscreen、remote、foreign assertion、unknown、無效 idle、3/5/10/15
- [x] App fake：影片／全螢幕擋熄、遠端擋熄、restore 只走 `restoreIdleBlank`、遠距門檻才查 foreign assertion、狀態變更 invalidate
- [x] 非同步測試 5s 截止／suite `.timeLimit(.minutes(1))`
- [x] 預設仍關閉＋5 分鐘、保留 3 分鐘、不覆寫已存（未改 `KeepAwakeAgentIdleMinutes.default`／設定遷移）
- [x] 不用私有 MediaRemote；不新增全域輸入監控權限前提
- [ ] 實機：影片／Screen Sharing／Universal Control／螢幕共享超過門檻不熄（P5；不可用標「未確認」）
- [ ] 開啟熄屏後 5 分鐘閒置 CPU 不因保護查詢顯著升高（P5）

### 偏離／給下游
1. Fi #2：媒體無法可靠判定 → **前景全螢幕即不熄**（誤保護成本：非媒體全螢幕也不熄）。
2. Fi #4：遠端偵測以公開 `NSWorkspace` bundle id／名稱＋`CGSessionCopyCurrentDictionary` 的 on-console；Universal Control／Screen Sharing 實機覆蓋 **P5 未確認**。抓不到或來源 unknown → 不熄。
3. 外部 `PreventUserIdleDisplaySleep`：只在 idle ≥ threshold−60s（或快取空／失效）查 `IOPMCopyAssertionsByProcess`；TTL 60s；已熄屏不每 500ms 重打 powerd。
4. Production `AgentIdleBlanker(displays:)` 接系統讀取器；測試 init 預設保護訊號 inactive（不影響既有 KeepAwakeControllerTests 注入）。
5. 未改 `KeepAwakeController.swift`／`LidSleepGuardController.swift`／PowerHelper。

### Spec 問題
無（本 worktree 仍無 `docs/spec.md`；依計畫＋`docs/decisions.md` D-2026-10-14）。
