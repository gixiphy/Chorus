# 修正計畫：hold 期間新 helper 也要被靜音（mute-guard refresh）

- 版本：r1（2026-10-27，實作驗收 FAIL 第 1 次退回）
- 基線 commit：`31b37c4c57b773b67b17e6b8b5913646f3453fcf`
- 回滾點：`31b37c4c57b773b67b17e6b8b5913646f3453fcf`（產品碼與測試回到這個 commit，就是這次修正之前的行為）
- 上層計畫：`docs/plans/call-handoff-hold.md`（r2）。本檔只補這一個缺陷，**其餘不變**
- 撰寫：Claude。只有計畫，沒有改產品程式或測試
- 實作者權限：本機 commit。不 push、不開 PR、不合併、不跑 `scripts/release.sh`

## 1. 缺陷

`Chorus/Audio/Taps/TapEngine.swift` 的 `ensureMuteGuard(_:members:)`（基線 L154–167）：

```swift
if muteGuards[bundleID] != nil { return true }
```

guard 已存在就直接回 true，不看傳進來的 `members`。

重現路徑：

1. 語音頻段出現，App 進入 hold，guard 以當下的成員（例如 `[com.apple.Music]`）建立。per-app playthrough 已收掉。
2. 同一個 App 出現新的 helper（`com.apple.Music.helper`）。`registry.onProcessesChanged` 觸發 `reconcileSessions()`，`.stayHeld` 分支帶著新的 `membersList` 呼叫 `ensureMuteGuard`。
3. `ensureMuteGuard` 直接回 true。舊 silencer 的 `CATapDescription.bundleIDs` 仍是第 1 步的清單，CoreAudio 只捕捉建立時寫進去的 bundle，所以新 helper 不在 guard 裡，聲音會走系統預設輸出，可能是 Chorus Screen Output。

同一個漏洞也會出現在其他經過 `ensureMuteGuard` 的路徑：`recordRate` 預先武裝的 guard，之後 `reconcilePlaythrough` 因為新成員重建 playthrough，會呼叫 `stopSessionKeepingSilent`，它內部也是先 `ensureMuteGuard`。修正放在 `ensureMuteGuard` 裡面，所有呼叫端都會一起修好。

**不在範圍內的殘留，維持不變**：拍板者接受的「guard 建不起來，而且原 UID 已消失」那一條。不要為它加新機制。

## 2. 能不能改既有 silencer 的成員？

**不能（以現有接縫而言）。**

- `TapSilencer` 協定（`Chorus/Audio/Taps/TapBackend.swift` L79–81）只有 `stop()`，沒有更新成員的方法。
- `TapBackend.startSilencer(bundleID:memberBundleIDs:)` 每次呼叫都建一個新的 process tap。
- `CoreAudioTapSilencer`（`CoreAudioTapBackend.swift` L831–）只持有 `tapID`，沒有保存 description，也沒有呼叫 `AudioObjectSetPropertyData` 的路徑。
- CoreAudio 能不能透過 `kAudioTapPropertyDescription` 對已存在的 tap 改 `bundleIDs`，並且立即生效：**未確認**。這次不採用，也不擴充協定。

所以採用 **make-before-break**：先用新成員建好新的 silencer，成功後才 `stop()` 舊的。新的沒建成就保留舊的，不准先拆。兩個 silencer 短暫並存，兩者都是 `.muted` 而且不寫回，並存只會讓聲音保持無聲，不會出聲。

## 3. 檔案範圍

| 檔案 | 動作 |
|---|---|
| `Chorus/Audio/Taps/TapEngine.swift` | 改 `muteGuards` 的值型別、`ensureMuteGuard`、`releaseMuteGuard` |
| `Chorus/Audio/Taps/FakeTapBackend.swift`（`#if DEBUG`） | 讓 fake silencer 記錄成員，新增查詢 |
| `Tests/ChorusAppTests/CallHandoffHoldTests.swift` | **只新增**測試 H17–H17c；既有測試的預期值一律不改 |

**不碰**：`TapBackend.swift`（協定不變）、`CoreAudioTapBackend.swift`、`CallHandoffPolicy`／`HandoffPlaybackPolicy`、任何 `PlaybackControlling` 實作、媒體鍵、MediaRemote、`Info.plist`、`Localizable.xcstrings`。不新增檔案，所以不需要 `xcodegen generate`。

## 4. 步驟

### 4.1 TapEngine：guard 記住自己涵蓋的成員

把

```swift
@ObservationIgnored private var muteGuards: [String: any TapSilencer] = [:]
```

改成：

```swift
private struct MuteGuard {
    let silencer: any TapSilencer
    /// 建立時寫進 tap 描述的 bundle（root＋helper）。CoreAudio 只捕捉這些。
    let members: Set<String>
}
/// mute guard 的唯一擁有者（武裝與 hold 共用）。
@ObservationIgnored private var muteGuards: [String: MuteGuard] = [:]
```

其他只用到 `muteGuards.keys`、`muteGuards[bundleID] != nil` 的地方（`hasMuteGuard`、`reconcileSessions` 的 tracked／解除武裝、`rescheduleHandoffRecheck`、`shutdownSessions`）都不必改語意，編譯過即可。

### 4.2 `releaseMuteGuard`

```swift
private func releaseMuteGuard(_ bundleID: String) {
    muteGuards.removeValue(forKey: bundleID)?.silencer.stop()
}
```

### 4.3 `ensureMuteGuard`：成員變多就先建後拆

```swift
/// 確保這個 App 有涵蓋 `members` 的 mute guard。已涵蓋就回 true；
/// 成員多了 → 先建新的、成功後才收舊的（中間不能有空窗）；建立失敗回 false，舊的照留。
private func ensureMuteGuard(_ bundleID: String, members: [String]) -> Bool {
    let existing = muteGuards[bundleID]
    let wanted = Set(members).union([bundleID])
    if let existing, wanted.isSubset(of: existing.members) { return true }
    // 不縮小涵蓋：暫時消失的 helper 回來時也要已經在 guard 裡
    let covered = wanted.union(existing?.members ?? [])
    do {
        let silencer = try backend.startSilencer(
            bundleID: bundleID, memberBundleIDs: covered.sorted()
        )
        muteGuards[bundleID] = MuteGuard(silencer: silencer, members: covered)
        if let existing {
            existing.silencer.stop()
            log.notice("來電接手靜音保護換新：\(bundleID) 成員 \(existing.members.count) → \(covered.count) 個")
        }
        return true
    } catch {
        log.error("來電接手靜音保護失敗：\(bundleID) \(error)；保留現有 tap")
        scheduleRetry()
        return false
    }
}
```

重點：

- 判斷條件和 playthrough 的 `sessionMemberBundles` 一致：用 `isSubset`。成員只少不多時不重建（成員減少不會漏聲）。
- 成員清單一律包含 root，即使 registry 回傳空陣列也一樣。
- **順序固定**：`startSilencer` 成功 → 寫回 `muteGuards` → `stop()` 舊的。不可以先 `releaseMuteGuard` 再建。
- 失敗時舊 guard **不動**，回 false。呼叫端的既有行為不變：`stopSessionKeepingSilent` 回 false，就不收 playthrough；`.stayHeld` 沒有 session 時忽略回傳值，靠 `scheduleRetry()` 下一輪再試。這是既有機制，不是新的機制。
- 不改任何呼叫端，也不改 `.stayHeld`／`.enterHold` 的決策。

### 4.4 FakeTapBackend：看得到 silencer 的成員

在 `FakeTapSilencer` 加上成員：

```swift
final class FakeTapSilencer: TapSilencer {
    let bundleID: String
    let memberBundleIDs: [String]
    ...
    init(bundleID: String, memberBundleIDs: [String], backend: FakeTapBackend)
}
```

在 `FakeTapBackend`：

```swift
/// 每一個建過的 silencer（依建立順序，含已停的）。
private(set) var allSilencers: [FakeTapSilencer] = []

/// 目前活著的 silencer 合起來靜音了這個 App 的哪些成員。
func silencedMembers(for bundleID: String) -> Set<String> {
    allSilencers
        .filter { $0.bundleID == bundleID && !$0.stopped }
        .reduce(into: Set<String>()) { $0.formUnion($1.memberBundleIDs) }
}
```

`startSilencer` 建立時，把 `memberBundleIDs`（空的話用 `[bundleID]`，和真實 backend 一致）傳給 silencer，並 append 到 `allSilencers`。

**不改**：`events` 的字串格式（`silencer+:<bundle>`／`silencer-:<bundle>`）、`startedSilencers`、`liveSilencers`、`muteGaps(for:since:)`、`sourceOutput(for:)`。

既有的 `recordSilencerStop` 已經只在 `liveSilencers[bundleID]` 是停掉的那一個時才移除。先建後拆時，`liveSilencers[bundleID]` 已經換成新的，舊的 `stop()` 不會把新的移掉。`muteGaps` 的計數會是 +1（新的）→ −1（舊的），持有者不會降到 0，所以不會記成 gap。實作時要確認這兩點成立。

### 4.5 新增測試（`CallHandoffHoldTests.swift`）

共用的 helper 注入（寫成 private func，放在 `restoreAirpods` 之後）：

```swift
private let musicHelper = "com.apple.Music.helper"

private func addMusicHelper(_ h: Harness) {
    var entries = h.registry.processes
    entries.append(.init(
        objectID: 1003, pid: 2003, bundleID: musicHelper,
        name: "Music Helper", isAudible: true, kind: .other
    ))
    h.registry.injectFake(entries) // 會觸發 onProcessesChanged → reconcileSessions
}
```

**H17 hold 中新增 helper：新成員也被靜音，中間沒有空窗**（必須）

1. `let h = makeHarness()`；`let mark = reproduce1440(h)`；`takeAway(h, defaultFirst: false)`。
2. 前提：`heldOutputUID == airpods`、`hasMuteGuard`、`backend.silencedMembers(for: music) == [music]`、`!tappedBundles.contains(music)`。
3. 記下 `let before = h.backend.events.count`、`let commandsBefore = h.playback?.commands.count`。
4. `addMusicHelper(h)`。
5. 斷言：
   - `backend.silencedMembers(for: music) == [music, musicHelper]`
   - `Array(backend.events[before...]) == ["silencer+:\(music)", "silencer-:\(music)"]`（先建新的再拆舊的，中間沒有 play／stop）
   - `backend.muteGaps(for: music, since: mark).isEmpty`
   - `backend.startedSilencers.count == 2`，活著的 silencer 只有一個：`allSilencers.filter { !$0.stopped }.count == 1`
   - `heldOutputUID == airpods`，`!startedOutputs.contains(screen)`，`!startedOutputs.contains(builtIn)`
   - `h.playback?.commands.count == commandsBefore`（沒有因此送 pause／play）
   - `setting(for: music).outputDeviceUID == nil`
6. 冪等：`h.engine.audioDevicesChanged()` 再跑一次，`startedSilencers.count` 仍然是 2。

**H17b 換新 guard 失敗：舊 guard 不拆，下一輪補上**（必須）

1. 同 H17 的第 1–2 步。
2. `h.backend.silencerFailuresRemaining = 1`，記下 `before`，然後 `addMusicHelper(h)`。
3. 斷言：`events[before...]` 裡沒有 `silencer-:\(music)`；`hasMuteGuard`；`silencedMembers(for: music) == [music]`；`muteGaps(for: music, since: mark).isEmpty`；`heldOutputUID == airpods`。
4. `h.engine.audioDevicesChanged()`（模擬重試那一輪）。
5. 斷言：`silencedMembers(for: music) == [music, musicHelper]`；`muteGaps(for: music, since: mark).isEmpty`。

**H17c helper 消失後不縮小、不重建**（必須）

1. 接著 H17 的狀態，把 helper entry 從 registry 移除（`injectFake` 不含 1003）。
2. 斷言：`startedSilencers.count` 不變；`silencedMembers(for: music)` 仍然包含 `musicHelper`。

**H17d 武裝中（還沒 hold）出現 helper：重建 playthrough 前 guard 已涵蓋 helper**（必須）

1. `let h = makeHarness()`；`h.engine.setGain(0.5, bundleID: music)`；`h.backend.nominalRates[airpods] = rate(24000)`；`h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))`；`h.engine.audioDevicesChanged()`。此時 guard 已武裝，playthrough 在 airpods 上。
2. 記下 `mark`，然後 `addMusicHelper(h)`。
   （前提先斷言：`hasMuteGuard`、`liveSessions[music]?.stopped == false`、`heldOutputUID == nil`。前置步驟如果和 harness 實際流程不同，可以調整前置步驟，但下面的斷言不能放寬。）
3. 斷言：在 `events[mark...]` 裡，第一個 `silencer+:\(music)` 的索引小於第一個 `stop:\(music)` 的索引；之後 `silencedMembers(for: music)` 包含 `musicHelper`；`muteGaps(for: music, since: mark).isEmpty`；新的 playthrough 仍然建在 airpods（`startedOutputs.last == airpods`）。

## 5. 驗收條件

- [ ] `ensureMuteGuard` 在成員多出來時會建新的 silencer，而且新 silencer 的 `memberBundleIDs` 包含新成員
- [ ] 換新的順序是先建新的再拆舊的；建立失敗時舊的不拆（H17、H17b）
- [ ] 成員只減不增時不重建（H17c）；同樣的成員重跑對帳不重建（H17 第 6 步、既有 H9）
- [ ] Fake 能列出活著的 silencer 的成員；新測試斷言的是成員清單，不只是 root 有沒有 silencer
- [ ] 既有 `CallHandoffHoldTests` 全部通過，**預期值一個都沒改**（特別是 H1c、H8、H9 的 `startedSilencers.count == 1`）
- [ ] 其他 `ChorusAppTests` 全部通過
- [ ] `git diff 31b37c4c57b773b67b17e6b8b5913646f3453fcf --stat` 只有 §3 的三個檔案
- [ ] diff 裡沒有 `PlaybackCommand`、`send(.pause`、`send(.play`、MediaRemote、媒體鍵、`Info.plist`、`Localizable.xcstrings` 的變動；`CallHandoffPolicy`／`HandoffPlaybackPolicy` 沒有動
- [ ] Release build 沒有引用 `FakeTapSilencer`／`allSilencers`／`silencedMembers`（都在 `#if DEBUG` 裡）

## 6. 測試指令

```sh
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests/CallHandoffHoldTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild test -scheme Chorus -destination platform=macOS -only-testing:ChorusAppTests ; } 2>&1 | xcsift -f toon -w -E
{ xcodebuild build -scheme Chorus -configuration Release -destination platform=macOS ; } 2>&1 | xcsift -f toon -w -E
```

以 TOON 輸出的 `status:` 判斷成敗。建置快取依全域規則放在 `~/Library/Caches/DevBuild/`。

## 7. Commit

疊在 `31b37c4c57b773b67b17e6b8b5913646f3453fcf` 之上，不 amend、不 reset。建議訊息：

```
fix: Refresh mute guard when held app gains a helper
修復：hold 中 App 新增 helper 時更新靜音保護
```

## 8. 給驗證者

- 真機重現：AirPods 播 Music／瀏覽器，接電話讓 AirPods 被帶走（進 hold）。hold 期間讓同一個 App 生出新的音訊 helper，例如瀏覽器開一個新分頁播放。Screen Output 不應該出聲。這個情境依賴第三方 App 的行為，**未確認**能不能穩定重現；不能重現時以 H17–H17d 為準。
- CoreAudio 兩個 `.muted` tap 短暫並存涵蓋同一個 bundle，預期不會出聲。這一點**未在真機確認**，驗證時請看 log 中「靜音保護換新」前後有沒有聲音漏出。
