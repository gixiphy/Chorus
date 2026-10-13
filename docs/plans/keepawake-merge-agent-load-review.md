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
