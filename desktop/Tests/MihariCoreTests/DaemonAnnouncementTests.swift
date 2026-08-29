import Foundation
import Testing

@testable import MihariCore

@Suite("デーモンのポート通知")
struct DaemonAnnouncementTests {

    @Test("stdout の 1 行からポートと pid を読む")
    func decodesLine() throws {
        let announcement = try DaemonAnnouncement.decode(line: #"{"port": 51234, "pid": 4242}"#)
        #expect(announcement == DaemonAnnouncement(port: 51234, pid: 4242))
        #expect(announcement.baseURL?.absoluteString == "http://127.0.0.1:51234")
    }

    @Test("前後の空白や改行が付いていても読める")
    func toleratesWhitespace() throws {
        let announcement = try DaemonAnnouncement.decode(line: "  {\"port\": 1, \"pid\": 2}\n")
        #expect(announcement.port == 1)
    }

    @Test("何も出力されなかったときは理由が分かるエラーになる")
    func emptyLineFails() {
        #expect(throws: DaemonError.announcementUnreadable(message: "何も出力されなかった")) {
            try DaemonAnnouncement.decode(line: "   \n")
        }
    }

    @Test("JSON でない行はそのまま添えて失敗する")
    func garbageFails() {
        // Python 側が起動に失敗してトレースバックを吐いた場合、その中身が見えないと調べようがない。
        #expect(throws: DaemonError.announcementUnreadable(message: "Traceback (most recent call last):")) {
            try DaemonAnnouncement.decode(line: "Traceback (most recent call last):")
        }
    }

    @Test("ポートが範囲外なら弾く")
    func rejectsOutOfRangePort() {
        #expect(throws: DaemonError.self) {
            try DaemonAnnouncement.decode(line: #"{"port": 0, "pid": 1}"#)
        }
    }
}
