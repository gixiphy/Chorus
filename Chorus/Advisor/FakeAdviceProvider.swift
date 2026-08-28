#if DEBUG
import ChorusCore
import Foundation

/// 測試引擎：回放注入的 advice（比照 --fake-als 套路；TestHooks "injectAdvice"）。
/// 不碰照片、不 spawn 任何子行程。
struct FakeAdviceProvider: LightingAdviceProvider {
    let advice: LightingAdvice
    var delay: Duration = .zero

    func advise(photos: [LabeledPhoto], context: AdviceContext) async throws -> LightingAdvice {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return advice
    }
}
#endif
