import AudioToolbox
import ChorusCore
import CoreAudioKit
import SwiftUI

/// AU 效果鏈編輯（AU-3）。裝置層與 App 層共用同一個面板——
/// 差別只在讀寫哪份設定、抓哪條 session 的活實例，由 `Target` 封裝。
///
/// 每格的「參數…」開 CoreAudioKit 的 generic 面板（AUGenericView），
/// 直接編輯 **render 鏈上的活實例**（改了立刻聽得到）；關閉面板時把
/// ClassInfo 讀回存檔，其他 session 的同格實例由就地套用同步
/// （CoreAudioTapSession.pushEffects 的 classInfo 快路徑）。
struct EffectChainView: View {
    enum Target {
        case device(AudioDeviceModel)
        case app(String)
    }

    @Environment(AppState.self) private var appState
    let target: Target

    /// 正在編輯參數的格。sheet 的生命週期綁它；鏈的組成一變就收掉
    /// （活實例可能已隨舊鏈退休，繼續編輯是在戳懸空指標）。
    @State private var editingEntry: AUEffectEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("效果鏈（Audio Unit）")
                    .font(.callout)
                Spacer()
                Menu("加入效果") {
                    if appState.auCatalog.items.isEmpty {
                        Button("重新掃描") { appState.auCatalog.refresh() }
                    }
                    ForEach(appState.auCatalog.items) { item in
                        Button("\(item.manufacturerName) — \(item.name)") {
                            setEntries(entries + [appState.auCatalog.makeEntry(item)])
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }

            if entries.isEmpty {
                Text("沒有效果。掛上的外掛以 in-process 執行——不穩的外掛可能連帶影響 Chorus；崩潰過的會被自動隔離、不再自動載入。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    slotRow(entry, index: index)
                }
                if let reason = unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(failures, id: \.self) { failure in
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // 鏈的組成變了（增刪、開關、換順序）→ 活實例即將換代，
        // 參數面板不能留著編輯舊實例
        .onChange(of: entries.map(\.id)) { _, _ in editingEntry = nil }
        .onAppear {
            if appState.auCatalog.items.isEmpty { appState.auCatalog.refresh() }
        }
        .sheet(item: $editingEntry) { entry in
            AUParameterSheet(
                title: entry.name,
                unit: liveUnit(for: entry),
                onDismiss: { persistParameters(of: entry) }
            )
        }
    }

    // MARK: - 每格

    @ViewBuilder
    private func slotRow(_ entry: AUEffectEntry, index: Int) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { enabled in
                    var updated = entries
                    updated[index].enabled = enabled
                    setEntries(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(quarantined(entry))

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(.caption)
                Text(entry.manufacturerName).font(.caption2).foregroundStyle(.tertiary)
            }
            .opacity(entry.enabled && !quarantined(entry) ? 1 : 0.5)

            if quarantined(entry) {
                Text("已隔離")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("上次載入這個外掛時 Chorus 崩潰了——不再自動載入")
                Button("再試一次") {
                    appState.tapEngine.setQuarantined(false, key: entry.component.key)
                }
                .buttonStyle(.link)
                .font(.caption2)
            }

            Spacer()

            Button("參數…") { editingEntry = entry }
                .controlSize(.mini)
                .disabled(liveUnit(for: entry) == nil)
                .help(liveUnit(for: entry) == nil
                    ? "鏈未生效（未播放或未達成立條件）時無法編輯參數"
                    : "開 generic 參數面板，直接編輯活實例——改了立刻聽得到")

            // 順序即處理順序——上下移比拖曳在窄面板裡可靠
            Button {
                var updated = entries
                updated.swapAt(index, index - 1)
                setEntries(updated)
            } label: { Image(systemName: "chevron.up").imageScale(.small) }
                .buttonStyle(.plain)
                .disabled(index == 0)
            Button {
                var updated = entries
                updated.swapAt(index, index + 1)
                setEntries(updated)
            } label: { Image(systemName: "chevron.down").imageScale(.small) }
                .buttonStyle(.plain)
                .disabled(index == entries.count - 1)

            Button {
                var updated = entries
                updated.remove(at: index)
                setEntries(updated)
            } label: { Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("從鏈上移除")
        }
    }

    // MARK: - target 分流

    private var entries: [AUEffectEntry] {
        switch target {
        case let .device(device): appState.audioManager.deviceEffects(for: device)
        case let .app(bundleID): appState.tapEngine.setting(for: bundleID).effects
        }
    }

    private func setEntries(_ updated: [AUEffectEntry]) {
        switch target {
        case let .device(device): appState.audioManager.setDeviceEffects(updated, for: device)
        case let .app(bundleID): appState.tapEngine.setAppEffects(updated, bundleID: bundleID)
        }
    }

    private func liveUnit(for entry: AUEffectEntry) -> AudioUnit? {
        switch target {
        case .device: appState.tapEngine.liveDeviceEffectUnit(id: entry.id)
        case let .app(bundleID): appState.tapEngine.liveAppEffectUnit(bundleID: bundleID, id: entry.id)
        }
    }

    private var failures: [String] {
        switch target {
        case .device: appState.tapEngine.deviceEffectFailures()
        case let .app(bundleID): appState.tapEngine.appEffectFailures(bundleID: bundleID)
        }
    }

    private func quarantined(_ entry: AUEffectEntry) -> Bool {
        appState.tapEngine.isQuarantined(entry.component)
    }

    /// 鏈為什麼沒生效（與 EQ 的誠實提示同一套條件與語氣）。
    private var unavailableReason: String? {
        guard entries.contains(where: \.enabled) else { return nil }
        switch target {
        case let .device(device):
            if !device.isDefault { return "效果鏈只在此裝置是預設輸出時生效" }
        case .app:
            break
        }
        switch appState.tapEngine.state {
        case .active: return nil
        case .denied: return "系統音訊錄製權限被拒——效果鏈無法運作"
        case .off: return "需要先在設定 → 音訊開啟「App 音訊接管」"
        default: return "正在確認權限…"
        }
    }

    /// 關面板時把活實例目前的參數讀回存檔——其他 session 的同格實例
    /// 由 pushEffects 的 classInfo 快路徑就地同步，不重建鏈。
    private func persistParameters(of entry: AUEffectEntry) {
        guard let unit = liveUnit(for: entry),
              let data = AUChainBuilder.classInfoData(of: unit) else { return }
        var updated = entries
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else { return }
        guard updated[index].classInfo != data else { return }
        updated[index].classInfo = data
        setEntries(updated)
    }
}

/// generic 參數面板的 sheet（CoreAudioKit AUGenericView 包一層）。
/// SoundSource 手冊自己說 generic 介面「避免問題」；外掛自帶的
/// custom 視窗第一版不載（DESIGN §1.4）。
private struct AUParameterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let unit: AudioUnit?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("完成") {
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let unit {
                // 寬高交給 AUGenericView 的自然尺寸決定（sizeThatFits）；
                // 硬給 minWidth 會讓 generic 面板比 sheet 寬、右緣被裁
                AUGenericParameterView(unit: unit)
            } else {
                Text("活實例已不在（鏈被重建）——重新打開面板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 120)
            }
        }
    }
}

private struct AUGenericParameterView: NSViewRepresentable {
    let unit: AudioUnit

    /// sheet 的尺寸邊界：窄於 minWidth 拉到 minWidth，
    /// 超過 maxWidth / maxHeight 就靠 NSScrollView 捲
    private static let minWidth: CGFloat = 480
    private static let maxWidth: CGFloat = 960
    private static let maxHeight: CGFloat = 560

    final class Coordinator {
        var naturalSize = CGSize(width: 480, height: 320)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let generic = AUGenericView(audioUnit: unit)
        generic.showsExpertParameters = false

        // AUGenericView 在 init 就依偏好尺寸把 slider 排好，之後不會跟著
        // 容器縮；所以反過來讓 sheet 配合它，而不是給它一個更窄的框
        var natural = generic.frame.size
        if natural.width < 1 || natural.height < 1 { natural = generic.fittingSize }
        natural.width = max(Self.minWidth, natural.width)
        generic.frame = CGRect(origin: .zero, size: natural)
        context.coordinator.naturalSize = natural

        // 翻轉的容器讓內容從頂端開始排（NSScrollView 的 documentView 預設
        // 原點在左下，內容比視窗矮時會沉到底部）
        let container = FlippedContainer(frame: CGRect(origin: .zero, size: natural))
        container.addSubview(generic)
        generic.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = container
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let natural = context.coordinator.naturalSize
        return CGSize(
            width: min(natural.width, Self.maxWidth),
            height: min(natural.height, Self.maxHeight)
        )
    }
}

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
