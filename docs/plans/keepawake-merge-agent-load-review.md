# 審查：keepawake-merge-agent-load.md（實作前）

- 日期：2026-10-13
- 基準：`eb3170a`（與計畫一致）
- 結論：**可實作**。無產品語意 IMPL-BLOCKED；下列為計畫／原始碼落差與實作修正。

---

## 發現

| 嚴重度 | 項目 | 說明 | 處置 |
|---|---|---|---|
| Medium | `docs/` 被 `.gitignore`（A7） | 實作 prompt 要求把 `docs/decisions.md`、計畫、審查一并 commit；A7 說 docs 只留本機 | **Ruling**：本回合依 prompt 對這三個檔 `git add -f`；不 push。遠端仍不會靠一般 clone 拿到 docs。 |
| Medium | AGENTS：`Localizable.xcstrings` 僅 A02、README 僅 A01 | 計畫 §5.1 列兩者；prompt 要求照 §5 改檔 | **Ruling**：一併改並 commit（本合併任務的檔案範圍以計畫為準）。 |
| Low | `SettingsView.swift:187`、`:190` | 仍寫「有 agent 在工作時／高負載時」分列；§1.3 未逐條點名但要求 grep 盤點 | 實作時改成合併名稱／語意。 |
| Low | `SystemLoadMonitor.running`／hub `running` 皆 private | §5.3 測試「兩者都在執行」需可觀察 | 加 `internal var isRunning`（唯讀），不改行為。 |
| Low | 舊測試 `loadModeResumesAfterSleep` | willSleep 現在改為 stop＋reevaluate，不再無條件 release | 在合併模式下若 hub 不 busy，reevaluate 仍會放掉；測試改 `.whileAgentsWorking` 後預期不變。 |
| Info | Codable `encode(to:)` | 計畫標「未確認」是否合成 | 手寫 `init(from:)`＋`encode(to:)`，用 mirror enum，避免合成缺口。 |
| Info | helper／Lid／pmset | §4 與原始碼一致；`lidGuard.update` 仍只看 `sourceHub.busy` | 不碰。 |

## 與決策對齊

D-2026-10-13b Q1–Q5 全部照建議；實作採：
- OR 持有、assertion 固定擋螢幕＋系統
- Lid 只看 agent
- 閒置熄屏整模式
- restore 吸收 legacy load 旗標並正規化
- 不做單一偵測開關


---

## fix1（2026-10-13）：Codex 驗收 FAIL 的修正

對應 `~/kp-verify/chorus-merge-verify.md` 問題 1–6。

| # | 處理 |
|---|---|
| 2 | `portableMerged` 邊界遷移 load→agent；Core 測試 2 個；計畫 §3.2 已補述 |
| 3 | `CloudBackup.onImported` → `KeepAwakeController.syncModeWithSettings()`；App 測試 4 個＋CloudBackup 測試 2 個 |
| 4 | 補 4 個動態句 en／zh-Hans；`KeepAwakeMergedLocalizationTests` 驗編譯後 en.lproj 與 xcstrings（en／zh-Hans、translated、placeholder 數量） |
| 5 | `KeepAwakeControllerTests` 的 `var idle` → `let`。本檔其餘 VariableNeverMutated 等 warning 在未改動的檔案，屬既有 |
| 6 | 新增 closed-lid 測試：Lid 選項 enabled＋蓋子 closed＋只有負載 → 等 400ms 仍無 `set(true)`；另有對照組（同條件改 agent 租約 → 確實 `set(true)`），證明測試抓得到。formatter 測試改驗完整句子、最多 2 個來源、「等 N 個」 |
| 1 | 見下 |

### 問題 1：`CloudBackupFaultTests` crash 對照

只跑 `-only-testing:ChorusAppTests/CloudBackupFaultTests`，乾淨 worktree、各自獨立 DerivedData，`build-for-testing` 後 `test-without-building` 連跑 6 次：

| commit | 通過 | 失敗 |
|---|---|---|
| `eb3170a`（合併前基準） | 5 | **1**（第 1 次，cold start：多個 hung-write 測試的期限落空，後續 `hungImportAppliesNothing` 的 `files[…]` 越界 → SIGTRAP） |
| `e4b2aff`（HEAD） | 6 | 0 |

- 結論：此 suite 在**基準上也會偶發失敗**，不是合併引入的 regression；失敗型態是時序（期限）敏感。原驗收那次的簽章是 `LidStateMonitor` 回呼 `EXC_BAD_ACCESS`，與基準觀察到的 SIGTRAP 不同，兩次都沒有穩定重現，**根因未確認**。
- `LidStateMonitor` 的 `Unmanaged.passUnretained(self)` refcon 有一個**確定的生命週期洞**：沒呼叫 `stop()` 就釋放時，notification port 仍掛在 main run loop，下一次電源事件會讀到懸空指標。已加 `isolated deinit` 拆除（App 端監看，未碰 helper／pmset／LidSleep 路徑）。**這是防禦性修正，沒有證據證明它就是該次 crash 的原因。**
- 另：完整 App 測試會偶發 `PERF1-R3 recoveryBlocked retries read-only status` 失敗。**在乾淨的 `e4b2aff` 上完整跑 2 次，1 次同樣失敗**（單獨跑該 suite 則全過），所以不是本次改動造成。原因是測試的 `sleepGate.releaseOne()` 在重試任務還沒睡進 gate 時是 no-op，這一拍就漏了。已在該測試 release 前先等 `recordedDelays` 非空（只改測試）。修後完整跑 3 次全綠。

### 最終數字（fix1）
- ChorusCore：843 tests／120 suites（原 841）
- ChorusAppTests：669（原 656）；ChorusPowerHelperTests：53；App＋helper 共 722，連跑 3 次全綠
- 沒有碰 `PowerHelper/`、`PowerHelperClient`、`LidSleepGuard*`、pmset；唯一的 App 端監看改動是 `LidStateMonitor` 的 `isolated deinit`

---

## fix2／NEW-1（2026-10-13）：同模式備份匯入未同步負載設定

對應 `~/kp-verify/chorus-merge-verify-2.md` **NEW-1**。

**根因**：`syncModeWithSettings()` 在模式相同時只 `normalizeSavedFlags()`；`SystemLoadMonitor` 與 controller 的 `alsoPreventSystemSleep`／battery／process／idle 快取不會從 SettingsStore 重載。設定 UI 走 setter／`applySystemLoadConfiguration`，匯入走另一條路。

**修正**：
1. `syncModeWithSettings()` 先 `syncRuntimeCachesFromSettings()`（快取、來源 hub、idle 相關），同模式再 `applyPersistedSystemLoadConfigurationIfNeeded()`。
2. `SystemLoadMonitor.applyConfiguration`：config 未變則不重啟（保留遲滯／generation）；有變更才 `start`。
3. 測試：同模式 CPU→network＋門檻＋快取立即生效；相同設定保留 hold／`startedAt`；timed／display 模式只更新快取不改 mode；monitor 同 config 不重啟。

### 最終數字（fix2）
- ChorusCore：843 tests／120 suites
- ChorusAppTests：674（+5）；ChorusPowerHelperTests：53；App＋helper 共 727（summary 頂層）
- 安全檔案 diff 空：`PowerHelper/`、`PowerHelperClient`、`LidSleepGuard*`、pmset／XPC／ledger 未碰
