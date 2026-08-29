import Foundation

/// 常駐デーモンまわりのエラー。
public enum DaemonError: LocalizedError, Equatable {
    case uvNotFound
    case bridgeDirectoryNotFound(path: String)
    case launchFailed(message: String)
    /// stdout の 1 行目が読めない、または JSON として解釈できない。
    case announcementUnreadable(message: String)
    case notRunning
    case requestFailed(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv が見つからない。UV_PATH を設定するか、uv をインストールする"
        case .bridgeDirectoryNotFound(let path):
            return "bridge/ が見つからない: \(path)。DEVICE_BRIDGE_DIR を設定する"
        case .launchFailed(let message):
            return "デーモンを起動できなかった: \(message)"
        case .announcementUnreadable(let message):
            return "デーモンがポートを通知しなかった: \(message)"
        case .notRunning:
            return "デーモンが起動していない"
        case .requestFailed(let status, let message):
            return "デーモンへの要求が失敗した (HTTP \(status)): \(message)"
        }
    }
}
