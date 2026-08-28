import Foundation
import Testing
@testable import ChorusCore

@Suite("ControlScene")
struct ControlSceneTests {
    private func scene(_ name: String) -> ControlScene {
        ControlScene(name: name, requests: [
            ControlRequest(verb: .set, target: .allDisplays, property: .brightness, value: "30%"),
        ])
    }

    @Test("JSON 往返")
    func roundTrip() throws {
        let original = ControlScene(name: "電影", requests: [
            ControlRequest(verb: .set, target: .allDisplays, property: .brightness, value: "30%"),
            ControlRequest(verb: .set, target: .defaultOutput, property: .volume, value: "20%"),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ControlScene.self, from: data) == original)
    }

    @Test("名稱比對忽略大小寫與頭尾空白")
    func nameMatching() {
        let movie = scene("Movie")
        #expect(movie.matches(name: "movie"))
        #expect(movie.matches(name: "  MOVIE  "))
        #expect(!movie.matches(name: "movies"))
    }

    @Test("全半形不敏感——CLI 打半形也要中全形的名字")
    func widthInsensitive() {
        #expect(scene("ＭＯＶＩＥ").matches(name: "movie"))
    }

    @Test("查找：精確優先")
    func lookupExact() {
        let scenes = [scene("電影"), scene("電影院")]
        #expect(scenes.scene(named: "電影")?.name == "電影")
    }

    @Test("查找：唯一前綴相符可中")
    func lookupPrefix() {
        let scenes = [scene("電影"), scene("會議")]
        #expect(scenes.scene(named: "會")?.name == "會議")
    }

    @Test("查找：前綴有歧義時回 nil，不亂猜")
    func lookupAmbiguous() {
        let scenes = [scene("會議"), scene("會客")]
        #expect(scenes.scene(named: "會") == nil)
    }

    @Test("查找：空字串與找不到都回 nil")
    func lookupMisses() {
        let scenes = [scene("電影")]
        #expect(scenes.scene(named: "") == nil)
        #expect(scenes.scene(named: "  ") == nil)
        #expect(scenes.scene(named: "不存在") == nil)
    }
}
