# Chorus

macOS 選單列 App：控制螢幕亮度與音量，並在**同一區網的多台 Mac 之間即時同步**。
類似 [Lunar](https://lunar.fyi) 的亮度控制，加上跨機同步作為核心特色；音訊功能將於
Phase 2 擴充至 [SoundSource](https://rogueamoeba.com/soundsource/) 類的 per-app 控制。

## 功能（MVP）

- **亮度**：外接螢幕 DDC/CI（Apple Silicon `IOAVService`）、內建面板與 Apple 顯示器
  （private `DisplayServices`）、DDC 不可用時自動降級 gamma 軟體調光
- **音量**：各輸出裝置音量／靜音／預設裝置切換；HDMI/DP 螢幕（無軟體音量）自動
  橋接到 DDC VCP 0x62/0x8D
- **跨機同步**：Bonjour 探索 + TLS-PSK（full mesh，2–5 台）；在任一台調整亮度或
  音量，其他配對的 Mac 即時跟進；亦可從選單直接遙控特定一台
- **配對**：一次性 PIN（SAS）確認 Curve25519 ECDH 金鑰交換 → 32-byte PSK 存
  Keychain；日常連線走 TLS 1.2 PSK，未配對連線一律拒絕

## 開發

```bash
xcodegen generate        # 產生 Chorus.xcodeproj（.xcodeproj 不進版控）
open Chorus.xcodeproj
```

- macOS 26+、Swift 6（strict concurrency）、SwiftUI `MenuBarExtra`
- 純同步邏輯在 `Packages/ChorusCore`（HLC、LWW 引擎、去重、配對密碼學）：
  `cd Packages/ChorusCore && swift test`
- private API（DisplayServices、IOAVService）→ 無法上 Mac App Store，
  以 Developer ID + notarization 發行；sandbox 關閉

### 同機測試（兩份 instance）

```bash
APP=~/Library/Developer/Xcode/DerivedData/Chorus-*/Build/Products/Debug/Chorus.app
open $APP --args --state-dump /tmp/a.json --listen-port 47700 --pair-port 47800
open -n $APP --args --instance B --state-dump /tmp/b.json --listen-port 47701 --pair-port 47801
```

`--instance` 切換獨立的 UserDefaults／Keychain／peerID；`--listen-port`／`--pair-port`
啟用固定 port 的手動端點模式（不註冊 Bonjour，loopback 不受區域網路權限管制）。
DEBUG 版可用 DistributedNotificationCenter `com.hermes.Chorus.test` 驅動配對與
控制（見 `TestHooks.swift`）。

## 已知事項

- **區域網路權限**（macOS 15+）：拒絕時為靜默丟包；若系統設定清單中沒有 Chorus
  且 mDNS 回 NoAuth，重新開機通常可修復（已知 macOS 問題）。選單列會顯示
  疑難排解提示。
- M1 世代 Mac mini 的內建 HDMI 埠無 DDC；部分 USB-C→HDMI 轉接器不透傳 DDC
  I2C —— 這些情況會自動降級為軟體調光（連續 3 次寫入失敗即降級）。
- 防迴圈三層：origin 直發不轉發（結構）、`(originID, seq)` 去重、expectedValue
  echo 抑制；衝突以 Hybrid Logical Clock last-writer-wins 收斂。

## 授權

`Chorus/Display/Vendor/AppleSiliconDDC.swift` vendored 自
[waydabber/AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)（MIT）。
