import Foundation
import Testing

@testable import MihariCore

/// 同梱ペットがリソースバンドルから読めることを固定する。
/// `Bundle.module` は .app の中を探せないため、探索は `PetResourceBundle` が自前で行っている。
@Suite("同梱ペットの読み込み")
struct PetLibraryTests {

    @Test("リソースバンドルを見つけられる")
    func locatesResourceBundle() {
        #expect(PetResourceBundle.locate() != nil)
    }

    @Test("同梱ペットの mauve が一覧に入る")
    func findsBundledPet() {
        let pets = PetLibrary.availablePets()
        #expect(pets.contains { $0.id == PetLibrary.defaultPetID })
    }

    @Test("同梱ペットのスプライトシートが実在する")
    func bundledSpritesheetExists() throws {
        let pets = PetLibrary.availablePets()
        let mauve = try #require(pets.first { $0.id == PetLibrary.defaultPetID })
        #expect(FileManager.default.fileExists(atPath: mauve.spritesheetURL.path))
    }
}
