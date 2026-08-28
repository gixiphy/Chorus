# ChorusAudioDevice — HAL 虛擬輸出裝置（BV）

改作自 [proxy-audio-device](https://github.com/briankendall/proxy-audio-device)
（Unlicense／公有領域，revision 以 2026-08 主線為底）。

## 為什麼需要它

DP/HDMI 螢幕音訊在 CoreAudio 沒有音量屬性，macOS 會停用整組系統音量 UI
（Touch Bar、控制中心、選單列、音量鍵）。BK 的 event tap 只救得了實體鍵盤；
Touch Bar 滑桿直接呼叫 CoreAudio，攔不到。唯一解法：一個**自報有音量控制**的
虛擬輸出裝置，設為預設輸出後系統音量 UI 全部復活，音訊由它轉送到實體螢幕輸出。

Chorus 監聽虛擬裝置的音量變更：

1. 實體裝置有 DDC 橋接 → **鏡射到 VCP 0x62**（真硬體音量，不損音質；
   此時驅動內的數位衰減關閉，樣本原樣通過）
2. 無 DDC → 驅動內數位衰減（軟體音量 fallback）

## 與上游的差異

- 識別碼全改（bundle id `com.hermes.ChorusAudioDevice`、box/device UID、
  factory UUID）——可與原版 ProxyAudioDevice 並存。
- 預設裝置名稱 "Chorus Screen Output"。
- 新增 `applyVolume` 設定（box-name 設定通道同上游協議）：
  `applyVolume=0` 時 IOProc 不做音量縮放（DDC 鏡射模式），mute 仍然有效。
- 移除 Settings App——設定由 Chorus 本體經 box-name 通道下達。

## 建置與安裝

driver 是 Chorus.xcodeproj 的 `ChorusAudioDevice` target，**隨 App 一起建置並
內嵌在 Chorus.app/Contents/PlugIns**——不是分開的產物。

安裝／更新／移除**只走 Chorus 設定頁「音訊」分頁的按鈕**（管理員密碼一次；
安裝＝把內嵌 driver 複製到 `/Library/Audio/Plug-Ins/HAL`——HAL plugin 的
macOS 硬性要求——並重啟 coreaudiod）。沒有腳本路徑。

**改動 driver 程式碼時記得把 `AudioDriver/Info.plist` 的 `CFBundleVersion`
+1**——設定頁靠它比對「已安裝 vs App 內附」版本來顯示「更新驅動」按鈕。

## 設定通道（與上游同協議）

找到 box（UID `ChorusAudioBox_UID`）後：

- 讀值：對 box 設 identify 值為 `-ConfigType`，再讀 box 的 name 屬性。
- 寫值：把 box 的 name 屬性設為 `key=value` 字串
  （`outputDevice=<UID>`、`deviceName=<名稱>`、`applyVolume=0|1` …）。
