# 選單列耳麥孔裝置改畫 `earpods` 實作計畫

> 給實作 agent：只有一個任務，照步驟打勾（`- [ ]`）做。不用再問就能開工。

- **目標**：預設輸出是 Mac 耳麥孔的「外接耳機／External Headphones」時，選單列圓環中央改畫 SF Symbol `earpods`，不再畫 `desktopcomputer`。
- **作法**：在 `StatusOutputGlyph` 新增一個 case `.earPods`，`symbolName` 為 `"earpods"`。`classify` 的 `.builtIn` 分支先看名字是不是耳機，是的話回 `.earPods`，不是再走原本的 macbook／desktop 判斷。renderer 不改，因為它已經用 `state.output.symbolName` 畫任意 SF Symbol。
- **技術**：Swift 6、SPM 套件 `Packages/ChorusCore`、Swift Testing。
- **基線 commit**：`3ca5532866b13c03f6ea364c54a94ed8abcdc280`（分支 `gixiphy/earpods-glyph`）
- **回滾點**：實作 commit 的父 commit，也就是本計畫的 commit（計畫之前是基線 `3ca5532866b13c03f6ea364c54a94ed8abcdc280`）。用 `git revert <實作 commit>` 或 `git reset --hard <計畫 commit>` 回滾。沒有寫入資料或設定，不需要還原資料。

## 全域限制

- 不 push、不合併、不打包、不重啟正在跑的 Chorus。
- 不改藍牙 `headphones`、AirPods 三種、MacBook 揚聲器（`laptopcomputer`）、HDMI／DisplayPort（`display`）、AirPlay、虛擬裝置的手繪喇叭。
- 不改右側 ∞ 防睡眠徽章、闔蓋圓點、音量弧、亮度弧，也不改彈出選單裡裝置列的圖示。
- 既有測試的預期值一行都不改。只能新增測試。
- `Localizable.xcstrings` 不動。這次沒有新增 UI 字串。

## 檔案

| 檔案 | 動作 | 內容 |
|---|---|---|
| `Packages/ChorusCore/Sources/ChorusCore/StatusIcon.swift:101-147` | 修改 | 新增 `case earPods`、`symbolName` 的分支、`.builtIn` 分類規則 |
| `Packages/ChorusCore/Tests/ChorusCoreTests/StatusIconTests.swift:103-140` | 修改（只新增） | 在 `StatusOutputGlyphTests` 中新增一個 `@Test` |
| `Chorus/Audio/AudioDeviceModel.swift:81-90` | **不改** | Built-in 已經對應到 `.builtIn`，並把裝置名傳給 `classify` |
| `Chorus/UI/MenuBarLabel.swift:36` | **不改** | 只讀 `device?.outputGlyph` |
| `Chorus/UI/StatusIconRenderer.swift:101-102, 210-212, 253-290` | **不改** | `drawDeviceSymbol` 依 `symbolName` 畫圖。`symbolBox` 維持 11.5×8.2，理由見假設 A3 |
| `scripts/render-icons.swift` | **不改** | 預覽用的腳本，不在這次範圍 |

`StatusOutputGlyph` 只有 `symbolName` 一個 exhaustive switch。基線 grep 結果：`classify` 回傳 enum，沒有對它做 switch，App target 也沒有對 `StatusOutputGlyph` 做 switch。所以新增 case 只需要補一個分支。

## 步驟

### Task 1：Built-in 耳麥孔分類成 `.earPods`

**Interfaces**
- Produces：`StatusOutputGlyph.earPods`，`symbolName == "earpods"`。`classify(transport:name:)` 的簽名不變。

- [ ] **Step 1：寫會失敗的測試**

  在 `StatusIconTests.swift` 的 `StatusOutputGlyphTests` 中，緊接在 `builtIn()` 之後新增以下測試（既有的 `builtIn()` 不要動）：

  ```swift
  @Test("內建耳麥孔畫有線耳機，不再畫成桌機")
  func builtInHeadphoneJack() {
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "外接耳機") == .earPods)
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "External Headphones") == .earPods)
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "外接耳機").symbolName == "earpods")
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "External Headphones").symbolName == "earpods")
      // 同一台 Mac 的喇叭、桌機、藍牙耳機都不受影響
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "MacBook Pro的揚聲器").symbolName == "laptopcomputer")
      #expect(StatusOutputGlyph.classify(transport: .builtIn, name: "iMac 揚聲器") == .desktop)
      #expect(StatusOutputGlyph.classify(transport: .bluetooth, name: "WH-1000XM5").symbolName == "headphones")
      // 只有 Built-in 才算耳麥孔：名字有 Headphones 的 USB 介面仍是手繪喇叭
      #expect(StatusOutputGlyph.classify(transport: .other, name: "USB Headphones") == .speaker)
  }
  ```

- [ ] **Step 2：執行測試，確認失敗**

  ```sh
  { swift test --package-path Packages/ChorusCore --filter StatusOutputGlyphTests ; } 2>&1 | xcsift -f toon -w -E
  ```
  預期：編譯失敗，錯誤是 `StatusOutputGlyph` 沒有成員 `earPods`。TOON 的 `status:` 不是成功。

- [ ] **Step 3：實作，修改 `StatusIcon.swift`**

  1. 在 `case headphones` 下一行新增 `case earPods`，加上一行 doc 註解：Mac 內建耳麥孔（「外接耳機」）。
  2. `symbolName` 新增 `case .earPods: "earpods"`。
  3. `classify` 的 `.builtIn` 分支改成以下內容，**耳機判斷放在 macbook 判斷之前**：
     ```swift
     case .builtIn:
         // 耳麥孔與喇叭是兩台 Built-in 裝置：「外接耳機」／「External Headphones」
         if lowered.contains("headphone") || lowered.contains("耳機") { return .earPods }
         // 「MacBook Pro的揚聲器」／「MacBook Air Speakers」——名字裡就有機型
         return lowered.contains("macbook") ? .laptop : .desktop
     ```
  其他 case 與 transport 分支都不動。

- [ ] **Step 4：執行測試，確認通過**

  ```sh
  { swift test --package-path Packages/ChorusCore --filter StatusOutputGlyphTests ; } 2>&1 | xcsift -f toon -w -E
  { swift test --package-path Packages/ChorusCore ; } 2>&1 | xcsift -f toon -w -E
  ```
  預期：兩次的 `status:` 都是成功，0 failed。`StatusOutputGlyphTests` 的 6 個測試全部通過，也就是原本 5 個加上新的 1 個。

- [ ] **Step 5：確認 App target 能編譯（選做，不需要重啟 Chorus）**

  ```sh
  xcodegen generate
  { xcodebuild build -scheme Chorus -destination 'platform=macOS' ; } 2>&1 | xcsift -f toon -w -E
  ```
  預期：`status:` 成功。這一步只確認新增 enum case 不會在 App target 造成 switch 不完整。**不要** run 或安裝 build 出來的 App。

- [ ] **Step 6：Commit**

  ```sh
  git add Packages/ChorusCore/Sources/ChorusCore/StatusIcon.swift Packages/ChorusCore/Tests/ChorusCoreTests/StatusIconTests.swift
  git status --short   # 只能有這兩個檔；Localizable.xcstrings 若被動到就 git checkout 還原
  git commit
  ```
  Commit 訊息：
  ```
  feat(status-icon): Draw earpods for the built-in headphone jack
  功能（狀態圖示）：內建耳麥孔改畫有線耳機

  <英文正文>

  <繁中正文>
  ```

## 測試

| 測試 | 涵蓋 |
|---|---|
| 新增 `StatusOutputGlyphTests.builtInHeadphoneJack` | 「外接耳機」與「External Headphones」對應到 `.earPods`／`"earpods"`。MacBook 喇叭仍是 `laptopcomputer`，iMac 仍是 `.desktop`，藍牙仍是 `headphones`，非 Built-in 的「Headphones」仍是 `.speaker` |
| 既有 `builtIn`、`wired`、`bluetooth`、`other`、`stateIncludesOutput` | 預期值不改，作為回歸測試 |
| 全套件 `swift test --package-path Packages/ChorusCore` | 沒有其他測試被破壞 |

**Review Focus**（沒被上面測試完整涵蓋、最可能出問題的情況）：
1. 名字同時含 `macbook` 與 `headphone`：依 Step 3 的順序判為 `.earPods`。基線沒看過這種名字，屬於防禦性設計，不另外寫測試。
2. 其他語系的耳麥孔名稱，例如簡體「外置耳机」：不會命中規則，退回 `.desktop`，維持基線行為（假設 A1）。
3. 靜音時的 slash 斜線疊在 `earpods` 上：沿用 `drawDeviceSymbol` 既有的邏輯，和 `airpods` 同尺寸。只能人工目視確認，見驗收條件 5。

## 驗收條件

1. [ ] `classify(transport: .builtIn, name: "外接耳機").symbolName == "earpods"`（新測試）。
2. [ ] `classify(transport: .builtIn, name: "External Headphones").symbolName == "earpods"`（新測試）。
3. [ ] `classify(transport: .builtIn, name: "MacBook Pro的揚聲器").symbolName == "laptopcomputer"`（新測試加上既有 `builtIn()`）。
4. [ ] `git diff 3ca5532866b13c03f6ea364c54a94ed8abcdc280 -- Packages/ChorusCore/Tests` 只有新增行，沒有刪除或修改既有的 `#expect`。`swift test --package-path Packages/ChorusCore` 全部通過。
5. [ ] **需要人工驗證**：在拍板者同意的時機，把預設輸出切到耳麥孔，目視確認圓環中央是有線耳機形狀，而且靜音斜線沒有切到環。實作者不重啟正在跑的 Chorus，這條標「已實作但未實機驗證」。如果看起來太小或認不出來，**不要自己改 `symbolBox`**，回報協調者另開修正 Task。
6. [ ] diff 只碰「檔案」表中標「修改」的兩個檔案。`AudioDeviceModel.swift`、`MenuBarLabel.swift`、`StatusIconRenderer.swift`、∞ 徽章、選單裝置列都沒有變動。

## 假設與理由

- **A1：只比對 `headphone` 與 `耳機`。** 理解卡只要求涵蓋「外接耳機」與「External Headphones」。`headphone` 也涵蓋單數與舊名「Headphones」。其他語系不命中時會退回 `.desktop`，和基線相同，不會變差。要擴充時，在這一行加字串，再補一行測試就好。
- **A2：只要是 Built-in、名字像耳機，任何 Mac 都畫 `earpods`。** 包括 Mac mini、iMac、Mac Studio 的耳機孔。這和「耳麥孔畫耳機」的目標一致，不限定只有 MacBook 適用。
- **A3：`symbolBox` 不改。** 2026-11-12 在本機用 `NSImage(systemSymbolName:)`，以 `pointSize 9, .medium` 實測，並依 `drawDeviceSymbol` 的等比縮放公式換算。`earpods` 原始尺寸是 11×11，畫進 11.5×8.2 的 box 後是 8.20×8.20，和 `airpods`（11×11 → 8.20×8.20）、`headphones`（12×12 → 8.20×8.20）一樣大。`laptopcomputer` 是 11.50×7.67。所以 `earpods` 不會比既有的符號小。這只量了名義尺寸，**辨識度還沒有人工確認**（驗收條件 5）。
- **A4：新增 case，不重用 `.headphones`。** 重用的話，不是畫成罩耳 `headphones`（不符合需求），就是連藍牙耳機一起改掉（屬於非目標）。
- **A5：case 命名為 `earPods`。** 依照既有的 `airPods`、`airPodsPro` 等 lowerCamelCase 寫法。SF Symbol 名稱是全小寫的 `earpods`。
- **與理解卡的差異**：無。
