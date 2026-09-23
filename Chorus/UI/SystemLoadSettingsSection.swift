import ChorusCore
import SwiftUI

/// 顯示器設定頁：高負載常亮門檻 draft 編輯。
struct SystemLoadSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var draft = SystemLoadConfiguration.default
    @State private var errorMessage: String?

    var body: some View {
        Section("高負載時自動常亮") {
            if appState.keepAwake.mode != .whileSystemBusy {
                Text("未啟用高負載模式")
                    .foregroundStyle(.secondary)
            }

            Text("監測整機負載（非單一 App）。網路含區域網路流量；單核忙碌未必達到整機 CPU 門檻。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("CPU", isOn: binding(\.cpuEnabled, preventsLastDisable: true))
            percentFields(title: "CPU", threshold: $draft.cpu)

            Toggle("GPU", isOn: binding(\.gpuEnabled, preventsLastDisable: true))
            percentFields(title: "GPU", threshold: $draft.gpu)
            gpuStatusRow

            Toggle("網路", isOn: binding(\.networkEnabled, preventsLastDisable: true))
            networkFields

            LabeledContent("啟用持續時間") {
                Stepper(value: $draft.activationSeconds, in: 5...120, step: 5) {
                    Text("\(Int(draft.activationSeconds)) 秒")
                }
            }
            LabeledContent("解除延遲") {
                Stepper(value: $draft.releaseSeconds, in: 30...600, step: 5) {
                    Text("\(Int(draft.releaseSeconds)) 秒")
                }
            }

            if appState.keepAwake.mode == .whileSystemBusy, let sample = appState.keepAwake.systemLoad.latestSample {
                LabeledContent("目前讀值") {
                    Text(liveReadings(sample))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("套用") { apply() }
                Button("恢復預設") {
                    draft = .default
                    apply()
                }
            }
        }
        .onAppear {
            draft = appState.settings.keepAwakeSystemLoadConfiguration
        }
    }

    private var gpuStatusRow: some View {
        Group {
            if appState.keepAwake.mode == .whileSystemBusy {
                switch appState.keepAwake.systemLoad.latestSample?.gpu {
                case .unsupported:
                    Text("此機 GPU 使用率不可讀；CPU／網路仍可監測。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unavailable:
                    Text("GPU 暫時讀取失敗，將自動重試。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .value(let value):
                    Text(String(format: String(localized: "GPU %.0f%%"), value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    private func percentFields(title: String, threshold: Binding<SystemLoadThreshold>) -> some View {
        Group {
            LabeledContent("\(title) 啟用門檻") {
                HStack {
                    TextField("", value: threshold.activation, format: .number)
                        .frame(width: 64)
                    Text("%")
                }
            }
            LabeledContent("\(title) 維持門檻") {
                HStack {
                    TextField("", value: threshold.release, format: .number)
                        .frame(width: 64)
                    Text("%")
                }
            }
        }
    }

    private var networkFields: some View {
        Group {
            LabeledContent("網路啟用門檻") {
                HStack {
                    TextField(
                        "",
                        value: Binding(
                            get: { draft.network.activation / 1_048_576 },
                            set: { draft.network.activation = $0 * 1_048_576 }
                        ),
                        format: .number
                    )
                    .frame(width: 72)
                    Text("MiB/s")
                }
            }
            LabeledContent("網路維持門檻") {
                HStack {
                    TextField(
                        "",
                        value: Binding(
                            get: { draft.network.release / 1_048_576 },
                            set: { draft.network.release = $0 * 1_048_576 }
                        ),
                        format: .number
                    )
                    .frame(width: 72)
                    Text("MiB/s")
                }
            }
        }
    }

    private func binding(
        _ keyPath: WritableKeyPath<SystemLoadConfiguration, Bool>,
        preventsLastDisable: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                if !newValue && preventsLastDisable {
                    let enabledCount = [draft.cpuEnabled, draft.gpuEnabled, draft.networkEnabled]
                        .filter(\.self).count
                    if enabledCount <= 1 && draft[keyPath: keyPath] {
                        errorMessage = String(localized: "至少選擇一項監測指標")
                        return
                    }
                }
                draft[keyPath: keyPath] = newValue
                errorMessage = nil
            }
        )
    }

    private func apply() {
        guard draft.isValid else {
            errorMessage = String(localized: "設定無效：請檢查門檻範圍與啟用／維持關係")
            return
        }
        errorMessage = nil
        appState.keepAwake.applySystemLoadConfiguration(draft)
        draft = appState.settings.keepAwakeSystemLoadConfiguration
    }

    private func liveReadings(_ sample: SystemLoadSample) -> String {
        func fmt(_ reading: SystemLoadReading, unit: String) -> String {
            switch reading {
            case .value(let v) where unit == "MiB/s":
                String(format: "%.2f %@", v / 1_048_576, unit)
            case .value(let v):
                String(format: "%.0f%@", v, unit)
            case .unavailable: "—"
            case .unsupported: "不支援"
            }
        }
        return "CPU \(fmt(sample.cpu, unit: "%")) · GPU \(fmt(sample.gpu, unit: "%")) · 網路 \(fmt(sample.network, unit: "MiB/s"))"
    }
}
