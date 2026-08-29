import Foundation

/// `uv` と `bridge/` の場所を決める。
///
/// 環境変数での上書きを許すのは、リポジトリの外から `.app` を動かす場合に
/// パスの推測が当てにならないため。
public struct DaemonLocator: Sendable {

    public typealias FileCheck = @Sendable (String) -> Bool

    private let environment: [String: String]
    private let isExecutable: FileCheck
    private let directoryExists: FileCheck

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping FileCheck = { FileManager.default.isExecutableFile(atPath: $0) },
        directoryExists: @escaping FileCheck = { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    ) {
        self.environment = environment
        self.isExecutable = isExecutable
        self.directoryExists = directoryExists
    }

    /// `uv` の探索順。`UV_PATH` があればそれだけを見る。
    public static func uvCandidates(home: String) -> [String] {
        [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
    }

    public func uvPath(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        if let path = environment["UV_PATH"], !path.isEmpty {
            guard isExecutable(path) else { throw DaemonError.uvNotFound }
            return path
        }
        for candidate in Self.uvCandidates(home: home) where isExecutable(candidate) {
            return candidate
        }
        throw DaemonError.uvNotFound
    }

    /// `bridge/` の場所。`DEVICE_BRIDGE_DIR` があればそれを優先する。
    public func bridgeDirectory(defaultPath: String = Self.repositoryBridgePath) throws -> String {
        let path = environment["DEVICE_BRIDGE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
        guard directoryExists(path) else {
            throw DaemonError.bridgeDirectoryNotFound(path: path)
        }
        return path
    }

    /// ソース位置からリポジトリルートを逆算した `bridge/`。
    /// desktop/Sources/MihariCore/Daemon/DaemonLocator.swift → <root>/bridge
    public static var repositoryBridgePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Daemon
            .deletingLastPathComponent()  // MihariCore
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // desktop
            .deletingLastPathComponent()  // <root>
            .appendingPathComponent("bridge")
            .path
    }
}
