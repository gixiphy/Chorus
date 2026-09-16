/// 亮度讀回來源。輪詢與快速讀回共用同一對帳入口時用來區分語意。
public enum BrightnessReadSource: String, Sendable, Hashable, CaseIterable {
    case nativeKey
    case poll
    case localWrite
    case remoteWrite
    case autoWrite
}

/// 亮度對帳決策：相同讀值不重複發事件；App 寫入後的平滑中間值不當成新輸入。
public struct BrightnessReconcile: Sendable, Equatable {
    public var epsilon: Double
    /// 本機寫入後忽略「朝目標前進」的中間讀值的時間窗。
    public var localWriteSettle: Duration

    public init(epsilon: Double = 0.005, localWriteSettle: Duration = .milliseconds(500)) {
        self.epsilon = epsilon
        self.localWriteSettle = localWriteSettle
    }

    public struct LocalWrite: Sendable, Equatable {
        public var target: Double
        public var writtenAt: Duration

        public init(target: Double, writtenAt: Duration) {
            self.target = target
            self.writtenAt = writtenAt
        }
    }

    public enum Decision: Sendable, Equatable {
        /// 與 model 相同（或仍在本機寫入收斂中）→ 不更新、不廣播。
        case ignore
        /// 更新 model；`broadcast` 表示是否視為使用者輸入並對外同步。
        case accept(broadcast: Bool)
    }

    public func decide(
        modelBrightness: Double,
        actual: Double,
        source: BrightnessReadSource,
        localWrite: LocalWrite?,
        now: Duration,
        autoHandled: Bool
    ) -> Decision {
        if abs(actual - modelBrightness) <= epsilon {
            return .ignore
        }

        if let localWrite,
           now - localWrite.writtenAt <= localWriteSettle,
           source == .poll || source == .nativeKey
        {
            // 朝我們剛寫的目標收斂：吞掉中間值
            if abs(actual - localWrite.target) <= epsilon {
                return .accept(broadcast: false)
            }
            let movingTowardTarget =
                (localWrite.target - modelBrightness) * (actual - modelBrightness) > 0
                && abs(actual - localWrite.target) < abs(modelBrightness - localWrite.target) + epsilon
            if movingTowardTarget {
                return .ignore
            }
        }

        if autoHandled {
            return .accept(broadcast: false)
        }

        switch source {
        case .nativeKey, .poll:
            return .accept(broadcast: true)
        case .localWrite, .remoteWrite, .autoWrite:
            return .accept(broadcast: false)
        }
    }
}
