import Testing
@testable import ChorusCore

@Suite("DialCandidateCursor")
struct DialCandidateCursorTests {
    let candidates = ["bonjour", "manual"]

    @Test("No candidates yields nil")
    func empty() {
        #expect(DialCandidateCursor().pick("A", from: [String]()) == nil)
    }

    @Test("Starts with the first candidate")
    func first() {
        #expect(DialCandidateCursor().pick("A", from: candidates) == "bonjour")
    }

    @Test("Each failure rotates to the next candidate and wraps")
    func rotates() {
        var cursor = DialCandidateCursor()
        cursor.failed("A")
        #expect(cursor.pick("A", from: candidates) == "manual")
        cursor.failed("A")
        #expect(cursor.pick("A", from: candidates) == "bonjour")
    }

    @Test("Pick is stable within one dial attempt")
    func pickIsStable() {
        var cursor = DialCandidateCursor()
        cursor.failed("A")
        #expect(cursor.pick("A", from: candidates) == cursor.pick("A", from: candidates))
    }

    @Test("Success and reset return to the first candidate")
    func successResets() {
        var cursor = DialCandidateCursor()
        cursor.failed("A")
        cursor.succeeded("A")
        #expect(cursor.pick("A", from: candidates) == "bonjour")
        cursor.failed("A")
        cursor.reset()
        #expect(cursor.pick("A", from: candidates) == "bonjour")
    }

    @Test("Peers rotate independently")
    func independent() {
        var cursor = DialCandidateCursor()
        cursor.failed("A")
        #expect(cursor.pick("B", from: candidates) == "bonjour")
    }

    @Test("A shrinking candidate list never goes out of range")
    func shrink() {
        var cursor = DialCandidateCursor()
        cursor.failed("A")
        cursor.failed("A")
        cursor.failed("A")
        #expect(cursor.pick("A", from: ["manual"]) == "manual")
    }

    @Test("ordered drops nils and duplicates, keeping order")
    func ordered() {
        #expect(DialCandidateCursor.ordered(["x", nil, "y", "x"]) == ["x", "y"])
    }
}
