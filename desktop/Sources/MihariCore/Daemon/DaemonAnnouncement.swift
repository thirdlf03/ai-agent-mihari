import Foundation

/// デーモンが起動直後に stdout へ 1 行だけ出す通知。
///
/// ポート 0 で起動して OS に空きポートを選ばせているため、
/// 実際の接続先はこの行を読むまで分からない。
public struct DaemonAnnouncement: Decodable, Equatable, Sendable {
    public let port: Int
    public let pid: Int

    public init(port: Int, pid: Int) {
        self.port = port
        self.pid = pid
    }

    /// stdout の 1 行をデコードする。
    public static func decode(line: String) throws -> DaemonAnnouncement {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DaemonError.announcementUnreadable(message: "何も出力されなかった")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw DaemonError.announcementUnreadable(message: trimmed)
        }
        do {
            let announcement = try JSONDecoder().decode(DaemonAnnouncement.self, from: data)
            guard (1...65535).contains(announcement.port) else {
                throw DaemonError.announcementUnreadable(message: "ポートが範囲外: \(announcement.port)")
            }
            return announcement
        } catch let error as DaemonError {
            throw error
        } catch {
            throw DaemonError.announcementUnreadable(message: trimmed)
        }
    }

    public var baseURL: URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }
}
