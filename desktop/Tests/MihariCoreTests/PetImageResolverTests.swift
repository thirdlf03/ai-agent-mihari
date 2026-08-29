import Foundation
import Testing

@testable import MihariCore

@Suite("プレースホルダへのフォールバック判定")
struct PetImageResolverTests {

    @Test("画像パスが未設定ならプレースホルダになる")
    func fallsBackWhenPathIsNil() {
        let configuration = PetConfiguration(imagePath: nil)
        let source = PetImageResolver.resolve(configuration: configuration, fileExists: { _ in true })
        #expect(source == .symbol(name: PetConfiguration.defaultPlaceholderSymbolName))
    }

    @Test("画像パスが空文字ならプレースホルダになる")
    func fallsBackWhenPathIsEmpty() {
        let configuration = PetConfiguration(imagePath: "")
        let source = PetImageResolver.resolve(configuration: configuration, fileExists: { _ in true })
        #expect(source == .symbol(name: PetConfiguration.defaultPlaceholderSymbolName))
    }

    @Test("パスは設定されているがファイルが実在しないならプレースホルダになる")
    func fallsBackWhenFileMissing() {
        let configuration = PetConfiguration(imagePath: "/tmp/mihari-does-not-exist.png")
        let source = PetImageResolver.resolve(configuration: configuration, fileExists: { _ in false })
        #expect(source == .symbol(name: PetConfiguration.defaultPlaceholderSymbolName))
    }

    @Test("ファイルが実在するならそのパスを使う")
    func usesFileWhenItExists() {
        let configuration = PetConfiguration(imagePath: "/tmp/mihari-pet.png")
        let source = PetImageResolver.resolve(configuration: configuration, fileExists: { _ in true })
        #expect(source == .file(path: "/tmp/mihari-pet.png"))
    }

    @Test("プレースホルダのシンボル名は設定を引き継ぐ")
    func usesConfiguredSymbolName() {
        let configuration = PetConfiguration(imagePath: nil, placeholderSymbolName: "pawprint.fill")
        let source = PetImageResolver.resolve(configuration: configuration, fileExists: { _ in true })
        #expect(source == .symbol(name: "pawprint.fill"))
    }
}
