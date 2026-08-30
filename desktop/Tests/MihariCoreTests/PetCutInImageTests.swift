import Foundation
import Testing

@testable import MihariCore

/// カットイン用の画像を「`cutin/<name>.png` が置いてあるか」だけで解決する規約を固定する。
@Suite("ペットのカットイン画像の解決")
struct PetCutInImageTests {

    /// 実在しないディレクトリを指すペット。
    private var missingPet: PetDefinition {
        PetDefinition(
            manifest: PetManifest(
                id: "not-a-pet",
                displayName: "居ないペット",
                description: "テスト用",
                spritesheetPath: "spritesheet.webp"
            ),
            directoryURL: URL(fileURLWithPath: "/var/empty/mihari-not-a-pet"),
            speechURL: nil
        )
    }

    @Test("同梱ペットの mauve は 3 枚とも解決でき、ファイルが実在する")
    func bundledPetHasEveryCutInImage() throws {
        let pets = PetLibrary.availablePets()
        let mauve = try #require(pets.first { $0.id == PetLibrary.defaultPetID })
        for image in AttendanceCutInImage.allCases {
            let url = try #require(mauve.cutInImageURL(image), "\(image.rawValue) の URL を解決できない")
            #expect(url.lastPathComponent == "\(image.rawValue).png")
            #expect(url.deletingLastPathComponent().lastPathComponent == "cutin")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(mauve.hasCutInImages)
    }

    @Test("ディレクトリが無いペットはどの絵も nil になり、揃っていないと判定する")
    func missingDirectoryResolvesToNil() {
        let pet = missingPet
        for image in AttendanceCutInImage.allCases {
            #expect(pet.cutInImageURL(image) == nil)
        }
        #expect(pet.hasCutInImages == false)
    }

    @Test("cutin ディレクトリが空なら揃っていないと判定する")
    func emptyCutInDirectoryIsNotEnough() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mihari-cutin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("cutin"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let pet = PetDefinition(
            manifest: PetManifest(
                id: "empty",
                displayName: "空のペット",
                description: "テスト用",
                spritesheetPath: "spritesheet.webp"
            ),
            directoryURL: directory,
            speechURL: nil
        )
        #expect(pet.cutInImageURL(.reach) == nil)
        #expect(pet.hasCutInImages == false)
    }
}
