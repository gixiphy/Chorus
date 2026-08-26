import Testing
@testable import ChorusCore

@Suite("Throttle")
struct ThrottleTests {
    let key = ControlKey.brightness(displayUUID: nil)

    @Test("First event sends immediately, rapid follow-ups defer")
    func basicThrottle() {
        var throttle = Throttle(intervalMillis: 50)
        #expect(throttle.shouldSend(key: key, nowMillis: 1000) == .sendNow)
        #expect(throttle.shouldSend(key: key, nowMillis: 1010) == .deferUntil(millis: 1050))
        #expect(throttle.shouldSend(key: key, nowMillis: 1049) == .deferUntil(millis: 1050))
    }

    @Test("After the interval passes, sending resumes")
    func resumesAfterInterval() {
        var throttle = Throttle(intervalMillis: 50)
        #expect(throttle.shouldSend(key: key, nowMillis: 1000) == .sendNow)
        #expect(throttle.shouldSend(key: key, nowMillis: 1051) == .sendNow)
    }

    @Test("Deferred send updates the baseline")
    func deferredSendBaseline() {
        var throttle = Throttle(intervalMillis: 50)
        #expect(throttle.shouldSend(key: key, nowMillis: 1000) == .sendNow)
        #expect(throttle.shouldSend(key: key, nowMillis: 1020) == .deferUntil(millis: 1050))
        throttle.didSendDeferred(key: key, nowMillis: 1050)
        #expect(throttle.shouldSend(key: key, nowMillis: 1060) == .deferUntil(millis: 1100))
    }

    @Test("Keys are throttled independently")
    func independentKeys() {
        var throttle = Throttle(intervalMillis: 50)
        let volumeKey = ControlKey.volume(deviceUID: nil)
        #expect(throttle.shouldSend(key: key, nowMillis: 1000) == .sendNow)
        #expect(throttle.shouldSend(key: volumeKey, nowMillis: 1001) == .sendNow)
    }
}
