# Chorus 闔蓋防睡：重大決策紀錄

來源：`docs/plans/keepawake-approvals.md` §D。  
Fi 於 **2026-10-12 19:22（台北）** 核准 A1–A8，採納 Opus 與 Codex 的建議。  
原話：「A1–A8 照 Opus 和 Codex 的建議；接受當掉時手動還原的風險，README 寫上還原指令；用 M1 做闔蓋測試，但硬斷電測試先不做」。

> 注意：本 repo 的 `docs/` 被 `.gitignore` 忽略（見 A7），本檔只留本機，不進 git。

---

## A1 — 特權輔助程序（SMAppService.daemon）

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 核准以 `SMAppService.daemon` 安裝 root LaunchDaemon（`ChorusPowerHelper`）。`protocolVersion` 不符時自動 unregister／register；但 `holderCount>0` 或 restore 失敗時**阻止並提示**（保守）。安裝／註冊到任何 Mac 前仍須逐次詢問 Fi。 |
| **考慮過的替代方案** | (a) `sudoers.d`：沒有當機還原、安裝體驗差；(b) 不做闔蓋防睡，只提示使用 clamshell 條件。 |
| **理由** | 這是唯一能在當機後盡量自動還原的做法（Opus／Codex 建議）。 |
| **接受的風險** | helper 當掉、BTM 停用或 binary 被移除時，可能留下 `SleepDisabled=1`；以 README 手動還原指令補救。產品文案**不得**宣稱「一定還原」。 |

---

## A2 — 以 root 執行 `pmset -a disablesleep`

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 使用 `pmset -a`（全機）。外部殘留（非 Chorus 設的 SleepDisabled=1）：只提示＋手動指令，**不**自動覆寫。持有期間遇外部改 0：**釋放並提示**，不重寫競爭。`overrideForeign` 不做。執行 `sudo pmset` 前仍須逐次詢問 Fi。 |
| **考慮過的替代方案** | (a) 改用 `-b`（電池 profile，作用範圍未確認）；(b) 啟動時自動覆寫 foreign（與「外部值不碰／XPC 只有兩方法」衝突，需另開 spec）。 |
| **理由** | `-a` 是社群唯一有實測的做法；不碰 foreign 維持既定安全界線（Opus／Codex 建議）。 |
| **接受的風險** | 影響全機、所有使用者，且可能跨過電池保護；無法完全辨識 ownership；與其他闔蓋工具並用時可能互相干擾。 |

---

## A3 — 電池、溫度與時限預設值

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 總開關預設關；電池闔蓋底線 30%；thermal `.serious` 解除；最長 3 小時（AC 也套用）；helper 硬底線 critical／電池 <10%；Orca `permission` 算工作中；Grok Bot 預設否；通知 30 分鐘一次；無蓋機型**隱藏且禁止 arm**（含已存設定與自動化）；租約 TTL 600 s（30–3600，最多 32）。App restart／wake 不重置闔蓋時限（deadline 持久化）；電源／電量／thermal 未知時拒絕新 acquire 並解除（保守）。解除延遲上界以 M-16 實測後填入。 |
| **考慮過的替代方案** | 電池底線 40%／50%；時限 2h 或 4h；無蓋機型只防一般睡眠；Orca permission 預設不算工作中。 |
| **理由** | 在續航與長任務之間取折衷，並對未知狀態採保守拒絕（Opus／Codex 建議）。 |
| **接受的風險** | 解除有取樣延遲；permission 算工作中時，使用者不在也可能醒到時限；無蓋機若誤觸自動化需靠「禁止 arm」擋下。 |

---

## A4 — 偵測行為變更

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 新來源（Orca、桌面 App、租約、Grok Bot）也影響既有 IOPMAssertion。wire 分別提供 `assertionEffective`／`lidEffective`。離開 Agent 模式、停用 automation、token rotation 時**立即清除**租約、不延長 grace。Claude Team ID 未確認時**停用桌面 Claude 來源**。Orca permission 遮蔽問題等 R01 結果再定，暫以 worktree status 為準。 |
| **考慮過的替代方案** | 新來源只影響闔蓋防睡、不影響一般 assertion；租約保留至 TTL／給 grace；Claude 來源以路徑降級繼續使用。 |
| **理由** | 行為一致；wire 分開可避免 lidGuardOff 與 assertion active 矛盾；停止接收時不延長較保守（Opus／Codex 建議）。 |
| **接受的風險** | 闔蓋選項關著時，Orca working 仍可能擋住開蓋閒置睡眠；Claude 來源暫時不可用；permission 與 working terminal 的優先序可能漏判或遮住狀態。 |

---

## A5 — 不修改 Orca hook／設定

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 本輪**不**修改 Orca 的 hook、設定或 runtime DB。Orca 來源只用唯讀的 `orca worktree ps --json`。日後若要做 hook 整合，另開 spec。 |
| **考慮過的替代方案** | 在 Orca agent hooks 於 working／done 時呼叫 `chorus keepawake hold/release`，免輪詢。 |
| **理由** | 縮小本輪攻擊面與還原成本；輪詢已足夠驗證產品行為（Opus／Codex 建議）。 |
| **接受的風險** | 依賴輪詢，狀態可能有短暫延遲；CLI 缺失時需退回行程偵測（僅在可實測時）。 |

---

## A6 — 簽章、公證與 entitlements

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 可修改 `package.sh`／`project.yml`。Release helper **只接受 Developer ID、排除 get-task-allow**（保守），Debug 另行要求。建置、簽章、公證、安裝**分開核准**；公證與安裝本輪不做。App 與 helper 都不新增受限 entitlement。 |
| **考慮過的替代方案** | Release 也接受同 Team＋identifier 的 Apple Development client（利於開發互通）；一次核准整條 package／公證／安裝流程。 |
| **理由** | 正式 helper 簽章要求更嚴；拆步核准避免「只驗證」被當成全部已准（Opus／Codex 建議）。 |
| **接受的風險** | Debug／Release 驗證路徑分叉，建置腳本更複雜；本輪未公證，分發僅限受控本機。 |

---

## A7 — Git：push、PR、merge

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 單一 feature branch `gixiphy/chorus-keepawake`；本機 commit 允許。**push／PR／merge／release 都須 Fi 逐次核准。** `AGENTS.md` 納入追蹤；`docs/` 維持 ignored、只留本機。 |
| **考慮過的替代方案** | 每任務子分支／每任務一 PR；例外追蹤 `docs/spec.md`；允許 agent 在 review 後自行開 PR。 |
| **理由** | 特權與電源相關變更必須由 Fi 把關；內部規劃文件不必進公開 repo（Opus／Codex 建議）。 |
| **接受的風險** | `docs/`（含本檔與 spec）不會進 remote，換機或清 worktree 時需自行同步本機副本。 |

---

## A8 — Ledger、README 還原指令與測試硬體

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-12 19:22（台北） |
| **決策** | 移除 helper 時**保留** ledger。corrupt／missing ledger 且 SleepDisabled=1：保持原值、停止新 acquire、提示手動還原。README（中英）公開 `sudo pmset -a disablesleep 0` 疑難排解。闔蓋實測用 **MacBook Pro M1**（Orca env `mac-m1`）；**M-9a 硬斷電測試跳過**。M1 與 M5 共用 iCloud repo 時，不可同時在兩台開 Chorus worktree。 |
| **考慮過的替代方案** | 移除時刪掉 ledger；corrupt 時另設自動 recovery；硬斷電用可犧牲的 MacBook 實測。 |
| **理由** | ledger 很小、無副作用；硬斷電有資料毀損風險，本輪不做（Opus／Codex 建議＋Fi 原話）。 |
| **接受的風險** | 無法證明 ownership 時只能人工復原；硬斷電路徑未經實機驗證；雙機同開 worktree 有 git 衝突風險（靠流程約束）。 |

---

## D-2026-10-13 — 特權相關 PR 雙審

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-13（台北） |
| **決策** | 凡會動到**特權 helper**或 **`sudo pmset`** 的變更，開 PR **之前**須由 **Claude 與 Codex 各審一次**。push／開 PR／merge 仍須 **Fi 每次核准**（延續 A7）。 |
| **考慮過的替代方案** | 只由一家審；審完後允許 agent 自動開 PR／merge。 |
| **理由** | 特權與電源控制屬高風險；雙審可降低漏看；最終合併權仍留給 Fi（Fi 經 Ayame 於 2026-10-13 同意）。 |
| **接受的風險** | 多一輪審查會多花額度與時間；兩家意見不一致時仍須交 Fi 決定。 |

---

## D-2026-10-13b — 螢幕長亮合併「有 agent 在工作時」與「高負載時」

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-13（台北） |
| **決策** | 兩個選項合併成「有 agent 工作或高負載時」，條件是 agent busy **OR** 負載 busy。計畫 `docs/plans/keepawake-merge-agent-load.md` §7 的五題都照建議：**Q1** 持有期間一律擋螢幕＋系統待機（Agent 語意，不看「連系統待機一起擋」開關）；**Q2** 負載**不**觸發闔蓋不睡，Lid Guard 的 busy 只看 agent 來源；**Q3** 閒置熄屏在整個合併模式都適用，不分觸發來源；**Q4** 新模式沿用 `keepAwakeAgentMode`，**隨備份跨機搬**（portable），legacy `keepAwakeSystemLoadMode` 在 restore 時吸收；**Q5** 本次不提供只開單一偵測，合併模式一律 OR。 |
| **考慮過的替代方案** | Q1：依觸發來源分別決定，或一律看開關；Q2：負載也觸發 SleepDisabled（要改 spec §1.3 並雙審）；Q3：只在 agent 觸發時熄屏；Q4：新模式改成綁機；Q5：加「高負載也算」開關，讓舊 Agent 使用者升級後行為不變。 |
| **理由** | 規則最簡單，assertion 與 Lid／helper 路徑的程式都不用改，符合 spec §1.3，也不必走 D-2026-10-13 雙審（仍建議 Codex 審一輪）。Agent 設定原本就是「這個人怎麼跑 agent」，所以可攜（Fi 核准）。 |
| **接受的風險** | 原「高負載」使用者如果關著系統待機開關，現在會多擋系統待機；原 Agent 使用者升級後，高負載也會讓螢幕常亮，並多出每 5 秒一次的負載取樣（耗電影響未確認），要在升級說明中註明；原本只用負載模式的人匯入到另一台 Mac 時，那台也會開啟新模式。 |

---

## D-2026-10-13c — build 139：XPC 回呼 MainActor 隔離 crash

| 欄位 | 內容 |
|---|---|
| **日期** | 2026-10-13（台北） |
| **決策** | Fi 21:05 核准 build 139，修 `RealPowerHelperXPCProxy`／`PowerHelperClient` 的 NSXPC error／reply／invalidation／interruption 回呼 MainActor 隔離 trap（計畫 `docs/plans/b139-xpc-callback-isolation.md`）。不動 helper 本體、pmset、`ChorusPowerHelperXPC`。Debug-only test seam 不得進 Release。合併前仍須 Claude＋Codex 雙審（延續 D-2026-10-13）；push／PR／merge／打包仍須 Fi 逐次核准。 |
| **考慮過的替代方案** | (a) 拿掉 `@MainActor` 整顆 proxy（變更面更大）；(b) 只 hop 不改型別（C8-1 已證明 hop 寫在 closure 內無效）。 |
| **理由** | M1 上 b138 啟動即 `EXC_BREAKPOINT`；根因是 MainActor 方法內未標註 closure 被推成 MainActor 隔離，由 NSXPC 背景 queue 呼叫。 |
| **接受的風險** | 動到 helper client 的 reply／逾時／連線事件語意；以雙審＋X1–X7／S1／S2 與手動 M1–M3 控管。 |
