# 計畫：螢幕長亮選單合併「有 agent 在工作時」與「高負載時」

- 版本：plan v0.1（2026-10-13，Claude Opus 5.5 撰寫；僅規劃，未改程式碼）
- 基準：`gixiphy/chorus-keepawake` @ `eb3170a`（1.15.3 build 137）
- 測試基準：Core 840／App 637／helper 53，全綠
- 依據：`docs/spec.md` §1.3、§4.7、§5.3、§7.1、§8；`docs/decisions.md` A3、A4、D-2026-10-13
- 狀態：**§7 五題已決定**（Fi 於 2026-10-13 核准，全部照建議；見 `docs/decisions.md` D-2026-10-13b）。可以開始實作。

---

## 0. 現況盤點（只列事實，均已在原始碼確認）

| 項目 | Agent（`.whileAgentsWorking`） | 高負載（`.whileSystemBusy`） |
|---|---|---|
| 觸發 | `sourceHub.isBusy`：agents、Orca、桌面 App、租約、Grok Bot 取 OR，再加 300 秒寬限 | `systemLoad.evaluation.shouldHold`：CPU、GPU、網路任一項持續 `activationSeconds`（預設 15 秒）達門檻 |
| 放開延遲 | hub grace 300 秒（`KeepAwakeBusyAggregator.defaultGraceSeconds`） | `releaseSeconds`，預設 120 秒，可設 30–600 秒（`coolingDown` phase） |
| assertion（`KeepAwakePlanner.assertionPlan`） | **固定**擋螢幕與系統待機 | 固定擋螢幕待機；系統待機看「連系統待機一起擋」開關 |
| 監測器 | `sourceHub.start/stop`（`updateAgentMonitor`） | `systemLoad.start/stop`（`updateSystemLoadMonitor`） |
| tick | 10 秒 | 5 秒，每次 tick 呼叫 `systemLoad.evaluate` |
| willSleep／didWake | wake 時呼叫 `sourceHub.tick()` | willSleep 時呼叫 `systemLoad.stop()` 並放掉 assertion；wake 時呼叫 `resetAfterWake()` |
| 顯示器變更 | — | `invalidateGPUCapability()` |
| 閒置熄屏 `AgentIdleBlanker` | 有 | 無（`stop()`） |
| Lid Guard | `agentModeActive = mode == .whileAgentsWorking`，busy = `sourceHub.busy` | `.off`（spec §1.3：高負載**不**觸發 SleepDisabled） |
| 持久化旗標 | `chorus.keepAwake.agentMode` | `chorus.keepAwake.systemLoadMode` |
| 備份可攜性（`DeviceBackup`） | **portable**：跨機匯入採用備份值 | **device-bound**：「另一台不應因匯入就開始監測」 |
| TestHooks `setKeepAwake` | `"agents"` | `"load"` |
| `describe(mode)` | `"agents"` | `"load"` |
| HTTP `modeWire` | `"whileAgentsWorking"` | `"whileSystemBusy"` |
| 選單短標 `menuLabel` | 「Agent」 | 「高負載」 |
| 圖示 | `cpu`／`cpu.fill` | `cup.and.saucer`／`.fill` |

另外兩項會影響做法的發現：
- `KeepAwakeMode` 是 `Codable`，並且**會持久化**：`FocusSnapshot.keepAwake` → `FocusSession` → `SettingsStore.focusSession`（以 JSON 存在 defaults，`try? JSONDecoder().decode`）。直接刪掉 `.whileSystemBusy` case 的話，含舊 case 的專注場次會整筆解碼失敗、變成 nil。
- `Localizable.xcstrings` 的 `sourceLanguage` 是 zh-Hant，譯文有 **en 與 zh-Hans 兩種**（prompt 只提到簡中，en 也要更新）。

---

## 1. 名稱與文字

### 1.1 選項名稱
- **建議**：「**有 agent 工作或高負載時**」（en：`While agents work or under heavy load`）。
  - 理由：直接看得出兩個觸發條件，是舊名稱的聯集，舊使用者找得到。
- 備選：「Mac 忙碌時」比較短，但看不出來包含 agent 偵測，Orca、租約的使用者會困惑。不建議。
- 選單短標 `menuLabel`：「**自動**」或「Agent／負載」。**建議「Agent／負載」**，保留辨識度。
- 圖示沿用 `cpu`／`cpu.fill`，填滿表示正在持有。

### 1.2 狀態列副標（`statusCaption`）
既有的前置分支照舊，順序是：電量／過熱暫停 → `activationFailed` → `thermalWarning`。進入合併模式的分支後，由新的純函式 `KeepAwakeWorkStatusFormatter.caption(...)`（App 端）組字串。輸入如下：

- `agentBusy = sourceHub.isBusy`
- `agentNames`：`sourceHub.busy.contributing` 的 `displayName`，最多 2 個，其餘顯示「等 N 個」
- `load = systemLoad.evaluation`、`systemLoad.latestSample`
- `isHolding`、`idleBlanked`
- 「螢幕與系統不待機」的字尾依 §7 Q1 的決定產生

| 狀態 | 文字（zh-Hant 原文） |
|---|---|
| 只有 agent 觸發 | `Claude Code、Orca 工作中 — 螢幕與系統不待機` |
| 只有負載觸發（active） | `CPU 72% 高負載 — 螢幕與系統不待機`（`activeDetail` 沿用 `SystemLoadStatusFormatter`） |
| 兩者都觸發 | `Claude Code 工作中＋CPU 72% — 螢幕與系統不待機` |
| 只有負載在冷卻中，agent 閒置 | `負載降低 · 約 95 秒後解除` |
| agent 在 grace 中，負載未達門檻 | 沿用 agent 文字，**不顯示倒數**。agents 來源的 `lastWorkingAt` 會隨 log 一直往後推，倒數會亂跳 |
| 持有中而且閒置熄屏 | `工作中 — 閒置熄屏` |
| 都沒有：負載 waiting | `監測中：沒有 agent 工作、負載未達門檻` |
| 都沒有：負載 qualifying | `CPU 達門檻 · 確認中`（沿用） |
| 都沒有：負載 unavailable | `監測中：沒有 agent 工作（負載監測無資料）` |
| 都沒有：GPU unsupported | `監測中：沒有 agent 工作（GPU 不支援，CPU／網路監測中）` |

- Lid 那一行（`LidMenuStatusFormatter`）不改。
- Chrome 背景節流提示照舊，條件是 `mode == .whileAgentsWorking`。

### 1.3 其他要改的字串
- `SettingsView.swift:446`：「未啟用 Agent 模式」→「未啟用『有 agent 工作或高負載時』」。
- `SettingsView.swift:210`（閒置熄屏說明）：把「Agent 模式」改成新名稱（依 §7 Q3 的決定）。
- `SystemLoadSettingsSection`：
  - 區段標題「高負載時自動常亮」→「**高負載門檻**」。
  - 「未啟用高負載模式」→「未啟用『有 agent 工作或高負載時』」。
  - 三處 `mode == .whileSystemBusy` 改判斷合併模式。
- `LidSleepSettingsSection.swift:138`：「只在 Agent 模式生效」→「只在『有 agent 工作或高負載時』模式、由 agent 來源觸發時生效」（依 Q2 的決定）。這是 UI 文案，不碰 helper。
- README.md:158、176；README.en.md:203：同步改名。依 AGENTS.md 屬於 A01／Antigravity 的範圍，或由 Fi 指派。
- 實作前用 `grep -rn "Agent 模式\|高負載模式\|高負載時"` 做一次全面盤點。

---

## 2. 觸發語意

1. **持有條件**：`agentBusy || loadBusy`，而且 `startedAt != nil` 且 `!powerFloorTripped`。
2. **放開延遲不合併**：兩個偵測器各自保有自己的遲滯，OR 之後自然得到「兩邊都放開才放開」。
   - agent 側：hub 寬限 300 秒，不變。
   - 負載側：`activationSeconds`／`releaseSeconds` 照舊使用設定值，不變。
   - 實際放開時刻是兩者之中較晚的那一個。不新增共用的延遲參數。
3. **assertion 類型確實不同**（見 §0 表格）。合併後擋哪些，列為產品問題 **§7 Q1**。
   - 建議：**固定擋螢幕＋系統待機**，也就是採用 Agent 語意。
4. **監測器生命週期**：進入合併模式時，`sourceHub.start()` 與 `systemLoad.start(...)` 都要啟動；離開時兩者都停止。
   - 代價：原本只開 Agent 模式的使用者，會多出每 5 秒一次的負載取樣（CPU ticks、GPU、網路計數器）。
   - 耗電影響**未確認**。驗收時用 Activity Monitor 比較合併前後的 Energy Impact。
5. **tick 間隔**：合併模式用 5 秒，並在 tick 中呼叫 `systemLoad.evaluate`。hub 有自己的 30 秒 tick，不受影響。
6. **willSleep**：
   - 只呼叫 `systemLoad.stop()`，接著呼叫 `reevaluate()`。
   - **不要**無條件放掉 assertion，否則 agent 持有的保護會在睡前被拆掉，和現在 Agent 模式的行為不同。
   - stop 之後 `shouldHold == false`。這時 hub 不 busy 就會自然放掉，hub busy 則照舊持有。
7. **didWake**：先 `systemLoad.resetAfterWake()`，再 `sourceHub.tick()`，最後 `reevaluate()`。
8. **displaysDidChange**：合併模式也要呼叫 `systemLoad.invalidateGPUCapability()`。
9. **`applySystemLoadConfiguration`**：在合併模式中要即時套用。
10. **閒置熄屏**：見 §7 Q3。建議整個合併模式都適用，也就是只要持有中就會驅動，不管是哪個條件觸發。
11. **HTTP status／hold**：
    - `modeWire` 仍然輸出 `"whileAgentsWorking"`，CLI 與 `KeepAwakeLeaseTests` 的 fixture 不變。
    - `contributing` 仍然只列 hub 的來源，負載不進 DTO，避免改 Core 的 wire 型別。
    - `assertionEffective` 的語意不變（等於 `isHolding`）。
    - 負載觸發也會讓 `assertionEffective == true`。這是合理的，因為 assertion 確實生效了。

---

## 3. 設定遷移與型別

### 3.1 enum
- **建議**：只保留一個 case，**沿用 `.whileAgentsWorking` 這個 Swift 名稱**，更新它的 doc comment；刪除 `.whileSystemBusy`。內部保留兩個偵測器（`sourceHub`、`systemLoad`）。
  - 理由 1：Lid 路徑、`ineffectiveHoldReason`、`modeWire`、約 30 個既有測試都以這個 case 為準，沿用名稱可以讓 Lid／helper 相關程式**零 diff**（§4）。
  - 理由 2：HTTP wire 與 CLI 相容。
  - 備選：改名成 `.whileWorking`。名稱比較清楚，但要動 Lid 路徑的多個檔案，D-2026-10-13 的雙審範圍也會變大。不建議。
- **Codable 相容**：在 `KeepAwakeMode` 手寫 `init(from:)`，舊 key `whileSystemBusy` 解碼成 `.whileAgentsWorking`，其餘 case 照舊。
  - 作法：用一個 private 的 `LegacyCodingKeys` 判斷，其餘交給一個與舊 enum 同形的 private mirror enum 的合成解碼。
  - `encode(to:)` 維持合成實作。只自訂 `init(from:)` 時，Swift 是否仍會合成 `encode(to:)`：**未確認**，以 round-trip 測試證明；不行就兩邊都手寫。
- `KeepAwakePlanner.shouldHoldAssertion`：
  - `.whileAgentsWorking` 改回傳 `agentsWorking || systemBusy`。
  - 參數簽章不變，避免牽動呼叫端。
- `assertionPlan`：依 Q1 調整。建議維持 `.whileAgentsWorking → (true, true)`，程式不用改，只改註解。
- `encode`：從 switch 中移除 `.whileSystemBusy`，`decode` 不變。遠端控制仍然回 −1。

### 3.2 持久化旗標
- **不新增 key**，兩個舊 key 都保留：
  - `keepAwakeAgentMode`：代表新模式。
  - `keepAwakeSystemLoadMode`：降為 legacy，只讀不寫 true。
- `selectMode(.whileAgentsWorking)`：寫入 `agentMode = true`、`systemLoadMode = false`。其他模式維持兩者都清除的現行做法。
- `restoreSavedMode()` 的優先序維持：螢幕 > App > **(agent || load)** → `activate(.whileAgentsWorking)`。
  - 正規化：寫回 `agentMode = true`、`systemLoadMode = false`，屬一次性遷移。
  - 是否要寫回，見 §7 Q4（可攜性）。如果 Fi 選擇「保留綁機」，就改為不寫回，兩個 key 都只讀 OR。
- 舊存檔的四種組合：

| agent | load | 結果 |
|---|---|---|
| T | F | 新模式（與現在相同） |
| F | T | 新模式（遷移） |
| T | T | 新模式。現行程式不會產生這個組合，因為 `selectMode` 互斥，`restore` 也會清掉 load；但手改 defaults 或舊備份可能出現，一樣進新模式 |
| F | F | 不啟用 |

- 螢幕或 App 綁定存在時，照舊優先，並清除 agent／load。
- **負載門檻設定** `chorus.keepAwake.systemLoadConfiguration`：完整保留，key 不變，可攜性不變（portable）。
- **DeviceBackup／CloudBackup**：欄位都保留，舊備份照常解碼，Core 型別不改。
  - 唯一要決定的是 `keepAwakeSystemLoadMode` 是否還留在 device-bound 清單，見 Q4。
  - 建議留著。它只是 legacy 欄位，restore 時會被 OR 吸收。

### 3.3 設定頁「高負載時自動常亮」區段
- **建議**：保留這個 Section，改名為「高負載門檻」，位置緊接在 Agent 偵測控制（`AgentDetectionControls`）之後。這兩組是同一個模式的兩種偵測，放在一起比較直覺。
- 「目前讀值」和 GPU 狀態列：改成在合併模式下顯示。
- 「至少保留一個訊號」規則（`preventsLastDisable`）不變。所以合併模式**一定**包含負載觸發，沒辦法只開 agent。這點見 §7 Q5。

### 3.4 TestHooks
- `setKeepAwake`：`"agents"` 與 `"load"` 都對應到 `activate(.whileAgentsWorking)`，`"load"` 保留為舊 E2E 腳本的別名。
- `describe(mode)`：只剩 `"agents"`。
- `"systemLoad"` 快照欄位不變。
- `scripts/` 目前沒有任何地方用到 `"load"` 或 `"agents"`，已用 grep 確認。

---

## 4. 是否碰到 privileged helper／sudo pmset／LidSleep

| 對象 | 是否修改 | 理由 |
|---|---|---|
| `PowerHelper/`（ChorusPowerHelper） | **否** | XPC 介面、帳本、看門狗都與模式無關 |
| `PowerHelperClient.swift` | **否** | 同上 |
| `sudo pmset`／`pmset -a disablesleep` 路徑 | **否** | 只由 helper 執行 |
| `LidSleepGuard.swift`（Core policy） | **否** | `step` 的輸入型別與判定順序不變 |
| `LidSleepGuardController.swift` | **否** | `update(agentModeActive:busy:...)` 簽章不變 |
| `KeepAwakeController.reevaluate()` 的 `lidGuard.update(...)` 呼叫 | **程式碼不變**（Q2 採建議時） | 因為 case 名稱沿用，`agentModeActive` 的判斷式字面上不變，busy 仍傳 `sourceHub.busy`（只含 agent 來源） |

- **行為面有一個變化**：原本只用「高負載時」的使用者遷移到新模式後，`agentModeActive == true`。
  - 如果他們**另外**打開了闔蓋選項（預設關閉），Lid Guard 會依 agent 來源 arm。
  - 負載本身**不會**讓 SleepDisabled=1，仍然符合 spec §1.3。
- 結論：**不碰** helper、不碰 sudo pmset，Lid 相關程式也沒有 diff。
  - D-2026-10-13 雙審規則的觸發條件是「會動到特權 helper 或 sudo pmset 的變更」，嚴格來說這次不適用。
  - 但 `KeepAwakeController` 的語意改了，**建議仍請 Codex 審一輪**。
- **例外**：如果 Fi 在 Q2 選擇「負載也觸發闔蓋不睡」，就要把 `systemBusy` 併入 Lid 的 busy 輸入。
  - 這違反 spec §1.3，要先由 Opus 改 spec。
  - Lid 路徑會被改動，D-2026-10-13 的雙審就適用。

驗收時要求以下指令的輸出**為空**：

```sh
git diff --stat eb3170a -- PowerHelper Chorus/Display/PowerHelperClient.swift \
  Chorus/Display/LidSleepGuardController.swift Chorus/Display/LidStateMonitor.swift \
  Packages/ChorusCore/Sources/ChorusCore/LidSleepGuard.swift
```

---

## 5. 檔案、步驟、測試、驗收

### 5.1 檔案清單
| 檔案 | 變更 |
|---|---|
| `Packages/ChorusCore/Sources/ChorusCore/KeepAwake.swift` | 刪除 `.whileSystemBusy`；`init(from:)` 加上 legacy 對應；`shouldHold` 改成 OR；更新註解 |
| `Chorus/Display/KeepAwakeController.swift` | `selectMode`／`restoreSavedMode`／`applySystemLoadConfiguration`／`activate`（tick）／`displaysDidChange`／`handleWillSleep`／`handleDidWake`／`updateSystemLoadMonitor`／`modeWire`；Lid 的呼叫不動 |
| `Chorus/UI/MenuBarView.swift` | 兩個按鈕合成一個；`menuLabel`；`statusCaption` 改呼叫新的 formatter |
| `Chorus/UI/KeepAwakeWorkStatusFormatter.swift`（新檔） | §1.2 的純函式；新增後執行 `xcodegen generate` |
| `Chorus/UI/SystemLoadStatusFormatter.swift` | 把 `activeDetail` 等改成 internal 供重用，行為不變 |
| `Chorus/UI/SystemLoadSettingsSection.swift` | 標題、文字、mode 判斷 |
| `Chorus/UI/SettingsView.swift` | 區段位置、兩段文字 |
| `Chorus/UI/LidSleepSettingsSection.swift` | 只改 138 行的說明文字 |
| `Chorus/Persistence/SettingsStore.swift` | 只改兩個旗標的 doc comment，key 不變 |
| `Packages/ChorusCore/Sources/ChorusCore/DeviceBackup.swift` | 只改註解（依 Q4）；欄位不改 |
| `Chorus/App/TestHooks.swift` | `"load"` 改為別名；`describe` |
| `Chorus/Resources/Localizable.xcstrings` | 新字串，en＋zh-Hans；刪除不再使用的 key。依 AGENTS.md 只有 A02 能提交 |
| `README.md`／`README.en.md` | 改名（A01 的範圍） |
| `docs/spec.md` | 不自行修改。在 handoff 中提出「spec 問題」：§1.3 的「高負載模式」措辭要改，由 Opus 改版 |

### 5.2 步驟
1. **Core**：改 `KeepAwake.swift` 與 `KeepAwakeTests`，`swift test` 要全綠。
2. **Controller**：改 `KeepAwakeController`，把 `SystemLoadMonitorTests` 與 `KeepAwakeControllerTests` 中用到 `.whileSystemBusy` 的地方改成新模式，並補上 §5.3 的測試。
3. **UI**：新增 formatter 與測試；修改 `MenuBarView`、設定頁、TestHooks。
4. **字串**：`xcstrings` 加入 en／zh-Hans 譯文。
5. **全量測試**：Core、App、helper 都要跑，並跑 §4 的 diff 檢查。
6. **手動 E2E**：見 §5.4。
7. 撰寫 handoff，請 Codex review，再交 Fi 決定是否 commit。

### 5.3 測試

**ChorusCore（`KeepAwakeTests` 與 `FocusSession` 相關）**
- 合併模式的 OR 真值表：(F,F)→F、(T,F)→T、(F,T)→T、(T,T)→T。`powerFloorTripped` 時一律 F；`startedAt == nil` 時一律 F。
- `assertionPlan(.whileAgentsWorking, toggle)` 不管 toggle 為何，都回 (true, true)（Q1 採建議時）。「其他模式」的清單移除 `.whileSystemBusy`。
- Legacy 解碼：`{"whileSystemBusy":{}}` 解成 `.whileAgentsWorking`；其他 7 種舊 JSON 照常解碼；`.whileAgentsWorking` round-trip 不變。
- 含舊 `keepAwake: whileSystemBusy` 的 `FocusSession` JSON 能完整解碼，不會變成 nil。
- `encode(.whileAgentsWorking) == -1`；刪除 `.whileSystemBusy` 的斷言。
- 預估 Core 測試數：840 → 約 844。原有的 load Codable 測試改寫。

**ChorusAppTests**
- `KeepAwakeControllerTests`：
  1. 進入合併模式時，hub 與 systemLoad 都在執行；`activate(.off)` 後兩者都停止。
  2. 只有負載觸發（用 `systemLoad.ingestForTesting`）：持有螢幕＋系統 assertion；`lidGuard.update` 收到的 busy 是 false；即使 Lid enabled，`helper.setCalls` 也不含 true。
  3. 只有 agent 觸發（租約）：持有 assertion，負載仍持續取樣。
  4. 兩者都觸發：負載先冷卻完，仍然持有；hub grace 到期後才放掉。反過來的順序也要測。
  5. restore 矩陣：(T,F)／(F,T)／(T,T) 都進入新模式，旗標正規化；有螢幕或 App 綁定時優先。
  6. willSleep：負載停止，hub 仍 busy 時 **不放掉** assertion；wake 時依序 reset 與 tick，然後重新持有。
  7. `applySystemLoadConfiguration` 在合併模式中即時生效；在 `.indefinite` 時只寫入設定。
  8. 閒置熄屏：只有負載觸發時也會驅動（依 Q3）。
  9. HTTP status：只有負載觸發時，`mode == "whileAgentsWorking"`、`assertionEffective == true`、`contributing` 為空。
- `SystemLoadMonitorTests`：`selectModePersistsLoadFlagAndRestoreWorks` 改寫成「選擇新模式時寫入 agent=true、load=false；legacy load=true 能還原」；另外 2 處 `activate(.whileSystemBusy)` 改成新模式。
- `KeepAwakeWorkStatusFormatterTests`（新檔）：§1.2 表格的 10 列各一個案例。
- `SystemLoadSettingsTests.statusFormatterCoversKeyPhases`：確認行為沒變。
- 預估 App 測試數：637 → 約 655。
- helper：53，不變，但**必須實際跑一次**，證明沒有回歸。

**指令**（依 CLAUDE.md 透過 xcsift；以 TOON 的 `status:` 為準）：

```sh
{ swift test --package-path Packages/ChorusCore --scratch-path ~/Library/Caches/DevBuild/Chorus_merge-core ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination platform=macOS \
    -derivedDataPath ~/Library/Caches/DevBuild/Chorus_merge-dd CODE_SIGNING_ALLOWED=NO \
    -only-testing:ChorusAppTests -only-testing:ChorusPowerHelperTests ; } 2>&1 | xcsift -f toon -w -E
```

- helper bundle 在 `xcodebuild test` 中是否真的有載入，依 handoff V01 的說明，要以 53 這個數字核對。

### 5.4 驗收條件
- [ ] 選單只剩一個「有 agent 工作或高負載時」，其他選項的順序不變。
- [ ] Core ≥ 844、App ≥ 655、helper = 53，全綠，0 個新的 warning。
- [ ] §4 的 diff 指令輸出為空。
- [ ] 舊 defaults：`agentMode=false, systemLoadMode=true` 啟動後進入新模式，`describe == "agents"`。
- [ ] 含 `whileSystemBusy` 的舊 `FocusSession` 能還原。
- [ ] 手動 E2E（Debug，非 Release）：
  - `setKeepAwake load` 後跑 `yes > /dev/null` 讓 CPU 進入 `active`：assertion 持有，`pmset -g assertions` 可以看到 `PreventUserIdleSystemSleep`（依 Q1）；`lidPhase` 不是 armed。
  - 停止負載後 120 秒內放掉。
  - 開一個 lease 之後，同樣維持持有 300 秒寬限。
  - 以上都**不需要** sudo。
- [ ] 狀態列副標在 §1.2 的各種狀態下都符合表格（截圖附在 handoff）。
- [ ] xcstrings 的新 key 都有 en 與 zh-Hans 譯文，沒有 `stale` 狀態的 key。
- [ ] Release build 沒有新增任何測試開關（spec §11）。

---

## 6. 回合與額度上限建議

- **實作**：1 個 agent（Cursor 或 Codex），1 回合完成 §5.2 的步驟 1–5。
- **修正**：最多 2 回合，沿用 3-strike 規則。第 3 次仍然失敗就停下，交給 Fi 或 Opus 判斷，不要再開第 4 回合。
- **Review**：Codex 1 回合，最多 1 次複審。Claude 審查依 D-2026-10-13 屬於選擇性，因為這次不碰 helper。
- **時間**：每回合實作或修正的 wall time 以 60 分鐘為上限；全量 App 測試約 10–15 分鐘【未確認，以上次 log 為準】。
- **額度**：整件事約為 PERF-1 單一修正回合的 1/3–1/2。比例只是估計，**未確認**，沒有實際的 token 數字。超過這個範圍就停下來回報。
- §7 Q1–Q5 已於 2026-10-13 決定，實作照 §1–§5 的建議值進行。

---

## 7. 需要使用者決定的產品語意問題（**已決定**）

> **已決定（2026-10-13，Fi 核准，記錄於 `docs/decisions.md` D-2026-10-13b）**：Q1＝A（一律擋螢幕＋系統）、Q2＝A（負載不觸發闔蓋不睡）、Q3＝A（閒置熄屏不分觸發來源）、Q4＝A（可攜，隨備份搬）、Q5＝A（本次不做單一偵測）。以下保留原本的選項分析作為紀錄。

**Q1. 合併後擋哪一種待機？**（兩種模式現在確實不同）

| 選項 | 內容 | 優點 | 缺點 |
|---|---|---|---|
| A（建議） | 固定擋螢幕＋系統，採用 Agent 語意 | 規則最簡單，assertion 程式不用改；長時間編譯或下載也不會睡 | 原「高負載」使用者如果關著「連系統待機一起擋」，行為會比以前多擋系統待機。實務差異可能很小：macOS 在螢幕 assertion 持有期間通常也不會閒置睡眠【未確認，要用 `pmset -g assertions` 實測】 |
| B | 依觸發來源決定：有 agent 觸發就擋兩者；只有負載觸發時，系統待機看開關 | 保留兩種舊語意 | `assertionPlan` 要多一個參數，負載和 agent 交替時 assertion 會反覆建立、放掉，測試也加倍 |
| C | 一律看「連系統待機一起擋」開關 | 和其他模式一致 | 破壞 Agent 模式現有的保證（spec §1.1 的前提），不建議 |

**Q2. 負載觸發時，要不要也觸發闔蓋不睡？**
- A（建議）：**不要**。Lid 只看 agent 來源，符合 spec §1.3，也不碰特權路徑。
- B：要。這需要 Opus 改 spec §1.3，也會讓 Lid 路徑被改動、適用雙審；而且高負載常常不是使用者的意圖（例如 Spotlight 建索引），闔蓋還一直醒著的風險比較高。

**Q3. 閒置熄屏（`AgentIdleBlanker`）的適用範圍**
- A（建議）：整個合併模式，只要持有中就適用。設定依然預設關閉，文字改成新模式名稱。
- B：只在 agent 觸發時適用。只有負載觸發時不熄屏，這是原本「高負載常亮」的語意。程式要多傳一個 `agentTriggered`。

**Q4. 新模式的旗標在備份中要可攜還是綁機？**（原本 agent 可攜、負載綁機）
- A（建議）：**可攜**，沿用 `keepAwakeAgentMode`，restore 時把 legacy 的 load 旗標吸收進來。
  - 代價：原本只用負載模式的人匯入到另一台 Mac 時，那台也會開啟新模式並開始取樣。
- B：**綁機**。新模式改用 device-bound 的 key。
  - 代價：原本 Agent 使用者跨機匯入的行為會倒退；要新增 key、改 DeviceBackup 清單和測試。

**Q5. 要不要讓使用者只開其中一種偵測？**
- 現況：負載設定「至少保留一個訊號」，所以合併模式一定包含負載觸發。
- A（建議，本次範圍）：不提供，合併模式一律 OR。舊的 Agent 使用者會多一個負載觸發，在升級說明中註明。
- B：在「高負載門檻」區段加一個「高負載也算」開關（預設開），或允許三個訊號全部關閉。新增 1 個 key 與遷移規則，舊 Agent 使用者遷移後可以設成關，行為完全不變。
- 如果 Fi 在意「升級後行為不變」，選 B，遷移規則是：「只有 agent 旗標」→ 開關設為 off；「負載旗標」→ on。
