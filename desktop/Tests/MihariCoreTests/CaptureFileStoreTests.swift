import Foundation
import Testing

@testable import MihariCore

@Suite("撮影画像のファイル名・保存先の組み立て")
struct CaptureFileStoreTests {

    @Test("ファイル名は 種類-日時-ランダム値.png の形式になる")
    func buildsFileName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 29
        components.hour = 12
        components.minute = 34
        components.second = 56
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let name = CaptureFileStore.fileName(kind: .camera, date: date, randomSuffix: { "abcdef1234567890" })

        #expect(name == "camera-20260829-123456-abcdef12.png")
    }

    @Test("スクリーンショットも同じ形式になる")
    func buildsFileNameForScreenshot() {
        let name = CaptureFileStore.fileName(
            kind: .screenshot,
            date: Date(timeIntervalSince1970: 0),
            randomSuffix: { "x" }
        )
        #expect(name.hasPrefix("screenshot-"))
        #expect(name.hasSuffix("-x.png"))
    }

    @Test("保存先ディレクトリは一時ディレクトリ配下の専用フォルダになる")
    func buildsDirectory() {
        let base = URL(fileURLWithPath: "/tmp/mihari-test-base", isDirectory: true)
        let directory = CaptureFileStore.directory(temporaryDirectory: base)
        #expect(directory.path == "/tmp/mihari-test-base/com.thirdlf03.mihari.capture")
    }

    @Test("write はディレクトリを自動で作り、指定したデータをそのまま書き出す")
    func writesDataAndCreatesDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let data = Data([0x01, 0x02, 0x03])
        let url = try CaptureFileStore.write(data, kind: .camera, directory: root)

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == data)
        #expect(url.deletingLastPathComponent().path == root.path)
    }

    @Test("write を2回呼んでも別ファイルとして保存される")
    func writingTwiceProducesDistinctFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let first = try CaptureFileStore.write(Data([0x00]), kind: .screenshot, directory: root)
        let second = try CaptureFileStore.write(Data([0x00]), kind: .screenshot, directory: root)

        #expect(first != second)
    }
}
