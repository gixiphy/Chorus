# AGENTS.md

給在這個 repo 工作的 AI agent（Codex、Cursor、Antigravity、Grok、Claude）的共同規則。

## 專案速覽
- Chorus：Swift 6 選單列 App，支援 macOS 26 以上、Apple Silicon，未沙箱，以 Developer ID 公證發行。
- 專案以 XcodeGen 產生（`project.yml`）。`*.xcodeproj` 不要提交，新增檔案後執行 `xcodegen generate`。
- 核心純邏輯放在 SPM 套件 `Packages/ChorusCore`：`swift test --package-path Packages/ChorusCore`。
- App 測試：`xcodebuild test -scheme Chorus`。
- UI 原文是繁體中文，英文是翻譯（`Chorus/Resources/*.xcstrings`）。
- `docs/` 在 `.gitignore` 中，內部文件只保留在本機。

## 通用規則
- **不要** push、開 PR、merge，也不要執行 `scripts/release.sh`。這些都要先得到 Fi 核准。
- **不要**執行 `sudo`，不要修改系統設定，不要註冊系統服務。需要時寫成步驟，交給有核准的驗證者執行。
- **不要**修改其他工具的設定或 hook，例如 Orca 的 `~/Library/Application Support/orca/*`。
- 只修改分配給你的檔案。需要動到別人的檔案時，在交接紀錄中提出。
- 沒有確認的事寫成「未確認」，不要編造數字或 API。

## 功能：Agent 工作中時闔蓋不睡（Lid-Closed Keep Awake）
- **狀態**：規劃完成，尚未實作，基準是 build 136。
- **文件**（都在本機 `docs/`）：
  - 規格：`docs/spec.md`（唯一的事實來源，與它衝突時以 spec 為準）
  - 任務與檔案範圍：`docs/plans/keepawake-tasks.md`
  - 驗證：`docs/plans/keepawake-verification.md`
  - 待核准與研究題目：`docs/plans/keepawake-approvals.md`
  - 調研：`docs/research/chorus-keepawake.md`
- **一句話架構**：
  1. 多個工作來源取 OR，再加 300 秒寬限，得到 busy。來源包括既有的 log 與行程兩層、Orca CLI、Codex／Claude 桌面 App、`chorus keepawake hold` 租約，以及 opt-in 的 Grok Bot。
  2. busy 時，Lid policy 依電量 ≥30%、溫度低於 serious、闔蓋時限決定是否持有。
  3. App 透過 XPC 請求 root helper（`SMAppService.daemon`）執行 `pmset -a disablesleep 1/0`。
  4. helper 在斷線、60 秒沒有心跳、開機時都會自己還原。
- **不可以放寬的安全界線**（spec §11）：
  - helper 的 XPC 只有 `setSleepDisabled(Bool)` 與 `status()`。
  - 雙向驗證 code signing，Team 為 `2ENEDJHX95`。
  - pmset 使用固定 argv，不經 shell。
  - 外部設定的 SleepDisabled 不碰。
  - Release build 中沒有任何測試開關。
- **角色分工**：
  - Opus：只寫 spec。
  - Cursor：實作（C01–C10）。
  - Codex：UI（U01、U02），以及 review 和驗證（V01）。
  - Antigravity：測試資料、翻譯、README（A01、A02）。
  - Grok：研究（R01）。

## 交接規則（handoff）
1. 開工前先讀 spec 中對應的章節，以及 tasks 文件中你的任務段落。確認相依的任務已經完成，或者已經提交骨架。
2. 只碰你的任務「檔案範圍」中列出的檔案。`Localizable.xcstrings` 只有 A02 可以提交，其他任務提交前要 `git checkout` 還原。
3. 完成時，在 `docs/plans/keepawake-handoff.md` 中**自己的** `## <任務代號>` 段落附加以下內容，不要改別人的段落：
   - 改了哪些檔案
   - 測試指令與結果
   - 驗收條件逐條打勾
   - 偏離 spec 的地方及理由
   - 給下游的注意事項
4. 發現 spec 有錯或缺漏時，不要自行改 spec。寫進交接紀錄的「spec 問題」，由 Opus 改版，並更新 spec 檔頭的版本。
5. 需要核准的事項（approvals §A）沒有核准前，只能在本機做到「可以驗證但不發布」為止。
6. 研究結論（R01）如果改變 spec 的假設，例如 bundle id 或 JSON 欄位，由 Opus 更新 spec 之後，下游才能跟著改。

## Code Review Rules

### 1. Output only — never post by default
- Review results go to the requester (Orca / Fi) as plain output only.
- Do NOT post PR comments, inline comments, approvals, or "request changes", and do not run `gh pr comment` / `gh pr review`, unless Fi has explicitly approved posting for this specific review.
- If no issues survive filtering, output: "No issues found. Checked for bugs and AGENTS.md compliance."

### 2. Reference format
- Every finding cites: `path/from/repo/root.ext:START-END @ <full 40-char commit SHA>`
  - Example: `Sources/BLE/Manager.swift:42-48 @ 94506ff0d3bd9185f1752da36e968775021fb48f`
- Include at least 1 line of context before and after the problem line(s).
- Use the SHA of the reviewed head commit. Never use short SHAs, branch names, or unexpanded `$(git rev-parse HEAD)`.
- A GitHub link is optional and only an extra. The local path:line + SHA is required.

### 3. Do NOT report (false-positive list)
1. Pre-existing issues that this change did not introduce.
2. Things that look like bugs but are actually correct.
3. Pedantic nitpicks a senior engineer would not raise.
4. Issues a linter, type checker, or compiler would catch (assume CI/build runs them).
5. General code-quality concerns (test coverage, docs, style), unless this file explicitly requires them.
6. Issues that the code explicitly silences (e.g. lint-ignore comments, `#pragma clang diagnostic ignored`, `// swiftlint:disable`).
7. Behavior changes that are likely intentional and tied to the purpose of the change.
8. Real issues on lines the change did not modify.
When unsure whether something is a real bug, leave it out, or mark it "unverified" for the verifier. Never present a guess as a finding.
