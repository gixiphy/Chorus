import Testing

@Suite("PMSetArgumentBuilder")
struct PMSetArgumentBuilderTests {
    @Test("write argv is fixed disablesleep 0/1")
    func writeArgs() {
        #expect(PMSetArgumentBuilder.writeArguments(enabled: true) == ["-a", "disablesleep", "1"])
        #expect(PMSetArgumentBuilder.writeArguments(enabled: false) == ["-a", "disablesleep", "0"])
    }

    @Test("read argv is only -g")
    func readArgs() {
        #expect(PMSetArgumentBuilder.readArguments() == ["-g"])
    }

    @Test("executable path is /usr/bin/pmset")
    func executable() {
        #expect(PMSetArgumentBuilder.executablePath == "/usr/bin/pmset")
    }
}
