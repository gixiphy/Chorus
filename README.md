# Chorus

macOS 選單列 App：控制所有螢幕與音訊裝置——並且在同一區網的多台 Mac 之間
**即時同步、互相遙控**。內建兩位 AI 顧問：一位看桌面照片給調光策略，
一位替 App 與輸出裝置推薦 **EQ 與 AU 效果**。

> 亮度控制的參考點是 [Lunar](https://lunar.fyi)，per-app 音訊是
> [SoundSource](https://rogueamoeba.com/soundsource/) 那一類。Chorus 把兩邊收進
> 同一個選單列，再疊上跨機與 AI 這兩層——那才是它真正的差異點。

`1.1.0`（build 61）· macOS 26+ · Apple Silicon · Swift 6（strict concurrency）· SwiftUI `MenuBarExtra`

<img src="assets/menubar.png" alt="Chorus 選單列" width="330">

*選單列：本機的螢幕、音訊裝置與各 App 音量，最下面是同一張桌上的另一台 Mac——
亮度與音量在兩台之間即時同步，也可以直接從這裡拉它的滑桿。*

---

## ① 跨設備同步與遙控

一組 Mac 當成一台用。在任一台調亮度或音量，其他配對的機器同一瞬間跟上；
也可以只針對某一台下指令。

- **探索與配對**：Bonjour 探索 → 一次性 PIN（SAS）確認 Curve25519 ECDH 金鑰交換
  → 32-byte PSK 存 Keychain。日常連線走 TLS 1.2 PSK，**未配對連線一律拒絕**。
- **拓樸**：full mesh（實測範圍 2–5 台），無中心節點、無雲端、無帳號。
- **會同步的**：螢幕亮度、輸出音量／靜音（兩者各有獨立開關）、環境光讀值。
- **只遙控不同步的**：螢幕電源、輸入源、對比、防睡眠、逐 App 音量／靜音——
  這些是動作或單機狀態，用 LWW 同步只會讓兩台機器互相把對方的螢幕關掉。
  選單列可直接展開任一台 peer 的螢幕與音訊裝置操作，「把客廳那台的螢幕關掉」
  不必走過去。
- **跨機環境光**：有光感的 Mac 當基準源廣播 lux（15s keepalive），
  沒有感測器的機器跟隨；基準源靜默 45s 才 failover——MacBook 闔蓋不會讓
  Mac mini 的螢幕忽明忽暗。
- **跨機 per-app**：連逐 App 的音訊都能跨機下手（跨機 `set`／`toggle`；
  跨機讀值尚未支援）。

```bash
chorus set --peer "Mac mini" --all-displays --power off
chorus set --peer "Mac mini" --app com.spotify.client --mute on
```

**收斂紀律**：衝突以 Hybrid Logical Clock last-writer-wins 收斂；防迴圈三層——
origin 直發不轉發（結構）、`(originID, seq)` 去重、expectedValue echo 抑制。

---

## ② AI 光環境顧問：照片 → 調光策略

拍一張桌面佈置的照片，讓模型看懂你的光環境，回一份可逐項套用的調光建議。

1. 在**裝置配置圖**視窗匯入桌面照片、把螢幕節點拖到照片上對應的位置。
2. 按「分析光環境」。送出的 context：照片縮圖、節點座標、每台顯示器的
   backend（DDC／DisplayServices／gamma）與現行曲線與 offset、近期 lux 統計。
3. 回一份 `LightingAdvice`：**per-display offset**、`maxLux`、`minBrightness`，
   外加警告與每一項的理由（「這台在櫃下陰影帶，offset 往上」「掛燈直射，
   建議關掉這台的自動模式」）。
4. 本地 schema 驗證與夾值後預覽，**逐項勾選才套用**；套用前 snapshot 舊值，
   一鍵單層還原。保留最近 5 筆分析結果可回看。

<img src="assets/lighting-advice.png" alt="光環境分析建議" width="700">

*建議逐項可勾選：每台顯示器的差異值、曲線參數，加上不能自動套用的警告。
已配對的 Mac 也是分析對象之一（上圖第三項）。截圖中的建議內容是示範資料，
不是某次真實模型輸出。*

「家」與「公司」可各存一份**桌面情境**（配置圖＋照片＋曲線＋offset），
以當時連接的顯示器組合為指紋自動切換。

---

## ③ AI 調音顧問：EQ 與 AU 推薦

同一套架構搬到音訊側。選一個目標（某個 App 或某台輸出裝置），用一句話說你要什麼——

> 「玩 FPS 想聽清腳步」「Podcast 人聲清楚一點」

送出的 context 是純文字：目標資訊、你的需求、**本機實際掃描到的 AU 清單**、
10 段頻率與現行 EQ／效果鏈摘要。回一份 `AudioTuningAdvice`：

```json
{ "summary": "…",
  "eq": { "bandsGainDB": [10 個 dB], "reason": "…" },
  "effects": [{ "componentKey": "…", "name": "…", "reason": "…" }],
  "warnings": ["…"] }
```

- **模型只能從本機清單挑外掛**——`componentKey` 不在清單裡就丟掉，杜絕
  「編造外掛」；增益本地夾 ±12 dB、效果上限 3 格。
- 結果卡逐段列出「現在 → 建議」與理由，**不自動套用**；按「套用」才寫入
  （走既有的 `setAppEQ`／`setEQSettings`／`setDeviceEffects` 路徑），單層還原。
- 明確不做：不送音訊樣本或頻譜給模型（那是量測校正，AutoEq 已覆蓋耳機那塊）；
  AU 的參數數值也不交給模型——generic 面板調參數本來就即時可聽。

<img src="assets/audio-advice.png" alt="App 音訊處理：等化器、效果鏈與 AI 調音建議" width="420">

*一個 App 一個視窗：等化器（只套這個 App）、AU 效果鏈，最下面是建議卡——
逐段列出「現在 → 建議」，按下「套用」才會生效。建議內容同樣是示範資料。*

### 分析引擎：零金鑰，用你自己的訂閱

兩位顧問共用一組引擎。Chorus **不經手任何 API key**——它 spawn 你本機
已經登入的 LLM CLI，計費走你既有的訂閱。偵測到誰就在設定頁列誰：

| CLI | 顯示名稱 |
|---|---|
| `claude` | Claude Code（預設） |
| `agy` | Antigravity |
| `grok` | Grok Build |
| `codex` | Codex CLI |
| `opencode` | OpenCode |

<img src="assets/advice-engines.png" alt="分析引擎設定" width="460">

分析是**顯式動作**（按鈕觸發，首次有確認對話框），不在背景送任何東西。

---

## 等化器與效果鏈

- **EQ**：每個輸出裝置與每個 App 各一組 biquad cascade（peaking／low・high shelf）。
  手動 10 段、**21 條風格 preset**，或 [AutoEq](https://github.com/jaakkopasanen/AutoEq)
  耳機校正（內建常見型號、也可貼上校正檔）。一律自動套 negative preamp 防削波。
- **AU 效果掛載**：掃描本機 Audio Unit，per-app 與裝置級各自掛鏈，
  參數用 `AUGenericView` 的原生面板即時調。
  鏈順序：`appGain × appEQ.preamp → appEQ → appAU → deviceEQ → deviceAU → SoftClip`。
- **隔離閂**：AUv2 只能 in-process 載入，所以每次實例化前先把外掛識別寫進
  latch 檔、成功後清掉。App 若在載入期間崩潰，下次啟動看到 latch 沒清
  ＝那個外掛帶走了我們 → 標記「已隔離」、不自動載入。**最壞只崩一次。**

---

## 其餘功能

### 顯示

- **亮度**：外接螢幕 DDC/CI（`IOAVService`）、內建面板與 Apple 顯示器
  （private `DisplayServices`）；DDC 不可用時自動降級 gamma 軟體調光
  （連續 3 次寫入失敗即降級）。滑桿下段 25% 改走軟體調光——外接螢幕的硬體
  最低亮度常常還是太亮。
- **自動亮度**：Mac 內建光感 → 遲滯平滑 → log 曲線映射（`minBrightness`／
  `maxLux` 可調），per-display offset；哪台參與可逐台關。
- **螢幕電源**：三層自動選用——DDC DPMS off／SkyLight soft-disconnect
  （內建面板唯一的真關閉）／gamma 全黑保底。UI 上只有一顆電源鈕。
- **輸入源切換**、**對比**、**防睡眠**（30 分鐘／1 小時／無限期／接著某台螢幕）。
- **緊急復原**：3 秒內連按 8 次 ⌘，把所有被關掉的螢幕接回來——不會把自己鎖在黑屏裡
  （gamma 與 soft-disconnect 另有結束即還原的保險，手勢失效也救得回來）。
- **媒體鍵接管**：只在 macOS 原生處理不了時接手（HDMI/DP 螢幕喇叭的音量鍵、
  沒有內建螢幕機器的亮度鍵），其餘維持原生行為。

### 音訊

- **裝置層**：各輸出裝置音量／靜音／預設裝置切換、左右平衡（原生 `vmbc`／`span`，
  沒有的裝置退軟體後端）、裝置優先順序（偏好裝置接上即成為預設並還原音量）、
  提示音音量獨立於輸出音量。
- **per-app**（CoreAudio process taps，**預設關閉**，需系統音訊錄製權限）：
  逐 App 音量（0–4x，>1x 過 soft limiter）／靜音／輸出路由；增益變更走 ~10 ms
  斜坡不爆音；設定以 bundle id 為鍵，App 重啟自動恢復。
  **排除清單**上的 App，Chorus 完全不碰。
  沒有調整過的 App 走原生路徑——**一個 tap 都不建立**。
- **虛擬輸出裝置**（內嵌 HAL driver，設定頁一鍵安裝）：DP/HDMI 螢幕音訊沒有
  系統音量，macOS 會停用音量鍵與控制中心。把虛擬裝置設為預設輸出後音量 UI
  全部恢復；支援 DDC 的螢幕直接鏡射硬體音量（不損音質），其餘用數位衰減。
- 權限被拒時 per-app 與等化整組隱藏；裝置音量、亮度、同步完全不受影響。

### 自動化介面

所有操作收斂成一組動詞（`get`／`set`／`toggle`／`perform`）＋目標定位
（`display:`／`displayWithMouse`／`device:`／`app:`／`allApps`／`peer:` …），
CLI、HTTP 與場景共用同一套語意。**`peer` 是請求的一個欄位，不是另一條 API。**

```bash
chorus set --brightness 50%
chorus set --display-like DELL --brightness +10%
chorus set --app com.apple.Music --volume 40%
chorus scene 電影
chorus listen | jq          # SSE 事件流，一行一個 JSON
```

- **localhost HTTP**：`POST /v1/command`、`GET /v1/state`／`/v1/scenes`／`/v1/events`。
  只綁 `127.0.0.1`、token 驗證（App 寫入 `~/.config/chorus/config.json`，權限 600）。
  預設關閉，設定頁開啟。**不綁 0.0.0.0、不做遠端 HTTP、不做 URL scheme。**
- **場景**：一組具名的請求（「電影」＝全部螢幕 30%＋輸出音量 20%）。
  選單列、`chorus scene <名稱>` 與 HTTP 觸發的是同一份。
- `chorus` 內嵌在 App 裡，設定頁一鍵 symlink 到 `/usr/local/bin`（不需要 admin）。

---

## 安裝

以 Developer ID 簽章＋notarization 發行——**上不了 Mac App Store**
（用了 `DisplayServices`、`IOAVService`、SkyLight 等 private API，且必須關 sandbox）。

自行建置：

```bash
xcodegen generate        # 產生 Chorus.xcodeproj（.xcodeproj 不進版控）
open Chorus.xcodeproj
```

`./scripts/package.sh` 會自動遞增 build 號、跑 Release archive、驗簽並產出 zip。

## 開發

- 純邏輯全部在 `Packages/ChorusCore`（HLC、LWW 引擎、去重、配對密碼學、
  biquad、環境光曲線、動詞層、顧問的 prompt／schema／夾值）：
  `cd Packages/ChorusCore && swift test`——不碰硬體就跑得完。
- App 層測試在 `Tests/ChorusAppTests`；`scripts/test-b*.py` 是各批的 E2E。
- 硬體與權限相關的接縫都有 fake 實作（`--fake-als`、`FakeTapBackend`、
  `FakeAdviceProvider`），DEBUG 版可用 DistributedNotificationCenter
  `com.hermes.Chorus.test` 驅動（見 `TestHooks.swift`）。

### 同機測試（兩份 instance）

```bash
APP=~/Library/Developer/Xcode/DerivedData/Chorus-*/Build/Products/Debug/Chorus.app
open $APP --args --state-dump /tmp/a.json --listen-port 47700 --pair-port 47800
open -n $APP --args --instance B --state-dump /tmp/b.json --listen-port 47701 --pair-port 47801
```

`--instance` 切換獨立的 UserDefaults／Keychain／peerID；`--listen-port`／`--pair-port`
啟用固定 port 的手動端點模式（不註冊 Bonjour，loopback 不受區域網路權限管制）。

## 已知事項

- **區域網路權限**（macOS 15+）：拒絕時為靜默丟包；若系統設定清單中沒有 Chorus
  且 mDNS 回 NoAuth，重新開機通常可修復（已知 macOS 問題）。選單列會顯示疑難排解提示。
- M1 世代 Mac mini 的內建 HDMI 埠無 DDC；部分 USB-C→HDMI 轉接器不透傳 DDC I2C
  ——這些情況自動降級為軟體調光。
- AU 在 render 期間崩潰攔不住（產業現狀）；隔離閂只保證不會每次啟動都崩。
- 虛擬裝置的 DDC 鏡射模式下左右平衡不生效（driver 端樣本原樣通過），UI 有誠實提示。

## 授權

- `Chorus/Display/Vendor/AppleSiliconDDC.swift` vendored 自
  [waydabber/AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)（MIT）。
- 等化器的耳機校正資料來自 [AutoEq](https://github.com/jaakkopasanen/AutoEq)（MIT）；
  biquad 係數公式取自公開的 Audio EQ Cookbook（Robert Bristow-Johnson）。
  風格 preset 的曲線為自行編寫。
- `AudioDriver/` 底本為
  [proxy-audio-device](https://github.com/briankendall/proxy-audio-device)（Unlicense）。
