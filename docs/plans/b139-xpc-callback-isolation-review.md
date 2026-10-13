# b139 計畫短審（實作前）

- 審查者：Cursor（實作者），2026-10-13
- 計畫：`docs/plans/b139-xpc-callback-isolation.md`（D-2026-10-13c）
- 結論：**可照做**；無阻塞問題。下列為注意事項，不阻擋開工。

## 同意

1. 根因敘述正確：`@MainActor` 方法內的未標註 closure 在 Swift 6 會被推成 MainActor 隔離；NSXPC 背景 queue 呼叫 → `swift_task_isCurrentExecutor` trap。T1 已有實機堆疊。
2. 修法正確：回呼型別與 literal 標 `@Sendable`，再 `Task { @MainActor }` hop；`setSleepDisabledSynchronously` 不可 hop（會與 `sem.wait` 死結）。
3. 範圍正確：不動 `PowerHelper/**`、pmset、`ChorusPowerHelperXPC`、Lid 產品碼、`Localizable.xcstrings`。
4. `#if DEBUG` 的 `init(testConnection:)` 符合 spec §11（Release 無測試開關）。
5. 紅燈必須單獨跑新 Suite（trap 會殺 test host），再套修法綠燈。

## 非阻塞注意

| # | 項目 | 處置 |
|---|---|---|
| N1 | T4 `interruptionHandler` 無自動化測試（同程序 anonymous listener 造不出可靠 interruption） | 依計畫：與 T3 共用安裝函式 + 手動 M2；handoff 寫明 |
| N2 | Exit test（`processExitsWith`）在 App-hosted target **未確認** | 最多試 15 分鐘；失敗則只留 `.ips` 紅燈證據 |
| N3 | 計畫行號相對 HEAD `c2b47d6`；實作時以符號為準 | 無 |
| N4 | X1／X4 若 anonymous listener 在 hosted 環境行為異常 | 依計畫 fallback：不存在的 machServiceName |
| N5 | `docs/` 被 ignore，但 merge 先例曾 `git add -f` 追蹤特定計畫／決策檔 | 本輪同樣 force-add 計畫、審查、`decisions.md` 的 D-2026-10-13c |
| N6 | Build bump 139「由 Fi 決定」 | 實作目標為 build 139；一併 bump `project.yml`（另 commit） |

## 無 must-fix

未發現與 spec §6.4／§6.5／§11／§14.2 衝突，或必須擴大到 helper／ChorusCore 協定才能修的缺口。

## 實作中 Ruling（RED 蒐證）

| Ruling | 理由 | 若錯的代價 |
|---|---|---|
| X1/X2/X5/X6 改用 `missingMachProxy`（不存在的 machServiceName），不用匿名 listener invalidate | 本機 RED：`deadProxy()`（anonymous invalidate）**不**觸發 errorHandler，X1/X2 卡到 60s；X5/X6 靠 `withTimeout` 逾時「假綠」。計畫 §3.1 已允許此 fallback | 若 missing-mach 在某些 OS 也不觸發 error block，需再改 fixture |
| 紅燈堆疊以 X3 `.ips` 為主證據 | `Chorus-2026-10-13-213112.ips`：`EXC_BREAKPOINT` on `com.apple.NSXPCConnection.user.endpoint`，`_dispatch_assert_queue_fail` ← `swift_task_isCurrentExecutor…` ← XPC reply block。證明同一 MainActor 隔離 prologue 機制；T1 error path 改由 missing-mach 覆蓋 | 審查者可能要再看一筆 errorHandler 專屬 .ips |

| X4 用 DEBUG `invalidateConnectionKeepingHandlersForTesting()` 觸發 invalidation | listener／peer invalidate 在 hosted 測試會先 `.interrupted` 或不觸發；seam 仍 `#if DEBUG` | 若 Release 誤編入 seam 會違反 §11（已用 Release nm 否定） |

