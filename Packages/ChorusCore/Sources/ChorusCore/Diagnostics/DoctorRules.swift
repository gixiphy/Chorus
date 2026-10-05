import Foundation

/// 把快照翻成「哪裡有問題、下一步做什麼」。順序：App → 系統權限 → 同步 → 各裝置。
public enum DoctorRules {
    static let localNetworkRemedy = "到系統設定 → 隱私權與安全性 → 區域網路 開啟 Chorus；若清單中沒有 Chorus，重新開機通常可以修復。"

    /// 與設定頁「無法探索裝置」提示共用同一條判斷。
    public static func isDiscoveryProblem(_ browserState: String) -> Bool {
        browserState.contains("NoAuth") || browserState.hasPrefix("waiting")
    }

    public static func evaluate(_ inputs: DoctorInputs) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        checks.append(mainLoop(inputs))
        if inputs.lastExitWasCrash {
            checks.append(DoctorCheck(
                id: "app.lastExit", status: .warning, title: "上次結束",
                detail: "Chorus 上次是異常結束。",
                remedy: "到設定頁按「匯出診斷包…」，把檔案附在問題回報裡。"
            ))
        }
        checks.append(accessibility(inputs))
        checks.append(audioTap(inputs))
        checks.append(discovery(inputs))
        checks.append(listener(inputs))
        if inputs.peers.isEmpty {
            checks.append(DoctorCheck(
                id: "sync.peers", status: .info, title: "已配對的裝置",
                detail: "尚未配對任何裝置。", remedy: "需要多台同步時，到設定頁按「配對新裝置」。"
            ))
        }
        for peer in inputs.peers {
            checks.append(connection(peer))
            if peer.permissions != .full {
                checks.append(DoctorCheck(
                    id: "peer.\(peer.peerID.prefix(8)).permissions", status: .info,
                    title: "\(peer.deviceName) 的權限",
                    detail: permissionSummary(peer.permissions),
                    remedy: "要調整時，到設定頁「已配對的裝置」該列的權限選單。"
                ))
            }
        }
        return checks
    }

    public static func permissionSummary(_ policy: PeerPermissionPolicy) -> String {
        if policy == .viewOnly { return "只能查看" }
        let names: [(PeerPermissionPolicy.Control, String)] = [
            (.brightness, "亮度與對比"), (.audio, "音量與靜音"),
            (.displayPower, "螢幕電源與輸入源"), (.keepAwake, "防睡眠"),
        ]
        let allowed = names.filter { policy.allowedControls.contains($0.0) }.map(\.1)
        let sync = policy.acceptsSync ? "接受同步" : "不接受同步"
        let controls = allowed.isEmpty ? "不允許遙控" : "允許遙控：" + allowed.joined(separator: "、")
        return "\(sync)；\(controls)"
    }

    // MARK: - 個別項目

    private static func mainLoop(_ inputs: DoctorInputs) -> DoctorCheck {
        inputs.mainLoopResponsive
            ? DoctorCheck(id: "app.mainLoop", status: .ok, title: "App 回應", detail: "正常")
            : DoctorCheck(
                id: "app.mainLoop", status: .warning, title: "App 回應",
                // 報告本身在主執行緒上組：走到這裡代表它已經恢復，只是探針還沒清
                detail: "主執行緒剛才有一段時間沒有回應（產生這份報告時已恢復）。",
                remedy: "若反覆出現，到設定頁按「匯出診斷包…」，把檔案附在問題回報裡。"
            )
    }

    private static func accessibility(_ inputs: DoctorInputs) -> DoctorCheck {
        inputs.accessibilityTrusted
            ? DoctorCheck(id: "permissions.accessibility", status: .ok, title: "輔助使用權限", detail: "已授權")
            : DoctorCheck(
                id: "permissions.accessibility", status: .warning, title: "輔助使用權限",
                detail: "未授權：視窗管理、媒體鍵與緊急復原無法使用。",
                remedy: "到系統設定 → 隱私權與安全性 → 輔助使用 開啟 Chorus。"
            )
    }

    private static func audioTap(_ inputs: DoctorInputs) -> DoctorCheck {
        let title = "逐 App 音訊"
        switch inputs.tapState {
        case .active:
            return DoctorCheck(id: "audio.tap", status: .ok, title: title, detail: "正常")
        case .off:
            return DoctorCheck(
                id: "audio.tap", status: .info, title: title, detail: "未啟用。",
                remedy: "需要逐 App 調音量時，到設定頁的音訊區開啟。"
            )
        case .probing:
            return DoctorCheck(
                id: "audio.tap", status: .info, title: title, detail: "正在確認系統音訊錄製權限。",
                remedy: "播放任何聲音以完成確認。"
            )
        case .denied:
            return DoctorCheck(
                id: "audio.tap", status: .error, title: title,
                detail: "偵測到系統音訊全為靜音，權限可能被拒。",
                remedy: "到系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 開啟 Chorus，然後重新開啟 Chorus。"
            )
        case .failed:
            return DoctorCheck(
                id: "audio.tap", status: .error, title: title,
                detail: "音訊引擎啟動失敗" + (inputs.tapError.map { "：\($0)" } ?? "。"),
                remedy: "到設定頁關閉再開啟逐 App 音訊；若仍失敗，請匯出診斷包回報。"
            )
        }
    }

    private static func discovery(_ inputs: DoctorInputs) -> DoctorCheck {
        if isDiscoveryProblem(inputs.browserState) {
            return DoctorCheck(
                id: "sync.discovery", status: .error, title: "探索其他 Mac",
                detail: "Bonjour 探索無法運作（\(inputs.browserState)）。",
                remedy: localNetworkRemedy
            )
        }
        if inputs.browserState.isEmpty {
            return DoctorCheck(
                id: "sync.discovery", status: .info, title: "探索其他 Mac", detail: "尚未啟動。",
                remedy: "同步啟動後會自動開始；若一直如此，重新開啟 Chorus。"
            )
        }
        return DoctorCheck(id: "sync.discovery", status: .ok, title: "探索其他 Mac", detail: "正常")
    }

    private static func listener(_ inputs: DoctorInputs) -> DoctorCheck {
        if inputs.listenerState.hasPrefix("failed") {
            return DoctorCheck(
                id: "sync.listener", status: .error, title: "接受其他 Mac 連入",
                detail: "同步 listener 失敗（\(inputs.listenerState)）。",
                remedy: "結束並重新開啟 Chorus；若持續發生，確認沒有其他程式佔用指定的同步 port。"
            )
        }
        // TLS-PSK 沒有金鑰就無從驗證，所以沒配對時刻意不開 listener（BonjourAdvertiser.restart）
        if inputs.listenerState.isEmpty, inputs.peers.isEmpty {
            return DoctorCheck(
                id: "sync.listener", status: .ok, title: "接受其他 Mac 連入",
                detail: "尚未配對任何裝置，配對後才會開啟。"
            )
        }
        if inputs.listenerState == "ready" {
            return DoctorCheck(id: "sync.listener", status: .ok, title: "接受其他 Mac 連入", detail: "正常")
        }
        return DoctorCheck(
            id: "sync.listener", status: .info, title: "接受其他 Mac 連入",
            detail: inputs.listenerState.isEmpty ? "尚未啟動。" : inputs.listenerState,
            remedy: "通常幾秒內會就緒；若一直如此，重新開啟 Chorus。"
        )
    }

    private static func connection(_ peer: DoctorInputs.Peer) -> DoctorCheck {
        let id = "peer.\(peer.peerID.prefix(8)).connection"
        let title = "\(peer.deviceName)（\(peer.peerID.prefix(8))）"
        switch peer.key {
        case .present:
            break
        case .missing:
            return DoctorCheck(
                id: id, status: .error, title: title, detail: "配對金鑰遺失，無法建立加密連線。",
                remedy: "在設定頁移除這台裝置，然後重新配對。"
            )
        case let .unreadable(status):
            return DoctorCheck(
                id: id, status: .error, title: title,
                detail: "無法讀取配對金鑰（Keychain OSStatus \(status)）。",
                remedy: "解鎖登入鑰匙圈，或在「鑰匙圈存取」允許 Chorus 讀取這個項目；金鑰仍在，不要移除這台裝置。"
            )
        }
        switch peer.phase {
        case .connected:
            let heard = peer.lastHeardSecondsAgo.map { "，最後收到訊息 \($0) 秒前" } ?? ""
            return DoctorCheck(id: id, status: .ok, title: title, detail: "已連線\(heard)")
        case .connecting:
            return DoctorCheck(
                id: id, status: .info, title: title, detail: "連線中。",
                remedy: "幾秒後再執行一次 chorus doctor。"
            )
        case .backoff, .idle:
            break
        }
        guard peer.isDialer else {
            return DoctorCheck(
                id: id, status: .warning, title: title,
                detail: "未連線，等待對方撥入（由 peerID 較小的一方撥號）。",
                remedy: "在「\(peer.deviceName)」上執行 chorus doctor，查看它撥號失敗的原因。"
            )
        }
        guard !peer.candidates.isEmpty else {
            return DoctorCheck(
                id: id, status: .warning, title: title, detail: "找不到這台裝置的位址。",
                remedy: "確認兩台 Mac 在同一個網路、對方的 Chorus 正在執行；跨網段時需要手動位址。"
            )
        }
        var detail = "未連線"
        if peer.consecutiveFailures > 0 { detail += "，已連續失敗 \(peer.consecutiveFailures) 次" }
        if case let .backoff(seconds) = peer.phase { detail += "，\(seconds) 秒後重撥" }
        detail += "；候選位址：\(peer.candidates.joined(separator: "、"))"
        if let next = peer.nextCandidate, peer.candidates.count > 1 { detail += "（下次嘗試 \(next)）" }
        return DoctorCheck(
            id: id, status: .warning, title: title, detail: detail + "。",
            remedy: "確認對方的 Chorus 正在執行、兩台在同一個網路；對方也可以執行 chorus doctor 檢查區域網路權限。"
        )
    }
}
