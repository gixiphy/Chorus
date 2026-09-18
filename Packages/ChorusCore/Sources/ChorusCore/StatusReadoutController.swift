import Foundation
import Observation

/// 「調整當下才出現的數字」：亮度或音量被使用者改了，就把百分比端出來，
/// 停留一小段時間後收掉。連續調整（拖曳、連按媒體鍵）會一直延長，
/// 放手後才開始倒數。
///
/// 只認**使用者的**調整：遠端同步、自動亮度、原生按鍵讀回都不經過這裡，
/// 否則自動亮度每動一下數字就閃一次。
@MainActor
@Observable
public final class StatusReadoutController {
    public private(set) var readout: StatusReadout?

    @ObservationIgnored private let hold: Duration
    @ObservationIgnored private var expiry: Task<Void, Never>?

    public init(hold: Duration = .milliseconds(1500)) {
        self.hold = hold
    }

    public func show(_ kind: StatusReadoutKind, value: Double) {
        readout = StatusReadout(kind: kind, value: value)
        expiry?.cancel()
        expiry = Task { [weak self, hold] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.readout = nil
        }
    }
}
