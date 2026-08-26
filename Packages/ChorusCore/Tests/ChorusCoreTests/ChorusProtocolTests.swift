import Testing
@testable import ChorusCore

@Test("Protocol version is stable")
func protocolVersion() {
    #expect(ChorusProtocol.version == 1)
    #expect(ChorusProtocol.serviceType == "_chorus._tcp")
}
