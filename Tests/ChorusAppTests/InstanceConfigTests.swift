import Testing
@testable import Chorus

@Test("InstanceConfig parses --instance argument")
func instanceArgumentParsing() {
    let config = InstanceConfig(arguments: ["/path/Chorus", "--instance", "B"])
    #expect(config.name == "B")

    let defaultConfig = InstanceConfig(arguments: ["/path/Chorus"])
    #expect(defaultConfig.name == nil)

    let danglingConfig = InstanceConfig(arguments: ["/path/Chorus", "--instance"])
    #expect(danglingConfig.name == nil)
}
