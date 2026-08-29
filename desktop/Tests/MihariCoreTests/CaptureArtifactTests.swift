import Foundation
import Testing

@testable import MihariCore

@Suite("撮影画像 1 枚の保存先と削除")
struct CaptureArtifactTests {

    @Test("delete は存在するファイルを消す")
    func deletesExistingFile() throws {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x00]).write(to: url)
        let artifact = CaptureArtifact(kind: .camera, url: url)

        try artifact.delete()

        #expect(!fileManager.fileExists(atPath: url.path))
    }

    @Test("delete はファイルが既に無くても失敗しない(冪等)")
    func deletingMissingFileDoesNotThrow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let artifact = CaptureArtifact(kind: .screenshot, url: url)

        // 2 回消しても、1 回目のあとに手動で消しても、エラーにならないことを確認する。
        try artifact.delete()
    }

    @Test("kind と url は初期化した値をそのまま保持する")
    func retainsInitializedValues() {
        let url = URL(fileURLWithPath: "/tmp/example.png")
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let artifact = CaptureArtifact(kind: .screenshot, url: url, capturedAt: capturedAt)

        #expect(artifact.kind == .screenshot)
        #expect(artifact.url == url)
        #expect(artifact.capturedAt == capturedAt)
    }
}
