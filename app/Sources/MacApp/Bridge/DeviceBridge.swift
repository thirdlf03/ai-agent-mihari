import Foundation

/// Python 側の `device-bridge` CLI をサブプロセスとして起動し、stdout の JSON を受け取る。
struct DeviceBridge {
    /// 接続中のデバイス一覧を取得する。
    func listDevices() async throws -> [DeviceSummary] {
        let data = try await run(arguments: ["list"])
        return try decoder.decode(DeviceListResponse.self, from: data).devices
    }

    /// 指定した UDID のデバイスの基本情報を取得する。
    func deviceInfo(udid: String) async throws -> DeviceInfo {
        let data = try await run(arguments: ["info", "--udid", udid])
        return try decoder.decode(DeviceInfo.self, from: data)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func run(arguments: [String]) async throws -> Data {
        let uv = try Self.uvURL()
        let bridgeDirectory = Self.bridgeDirectory()

        let process = Process()
        process.executableURL = uv
        process.arguments = ["run", "--frozen", "--project", bridgeDirectory.path, "device-bridge"] + arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        // パイプが埋まって子プロセスがブロックしないよう、終了を待つ前に読み出しを始める。
        let outputTask = Task.detached { standardOutput.fileHandleForReading.readDataToEndOfFile() }
        let errorTask = Task.detached { standardError.fileHandleForReading.readDataToEndOfFile() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            // 読み出し側が EOF を受け取れるよう書き込み端を閉じる。
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            throw error
        }

        let outputData = await outputTask.value
        let errorData = await errorTask.value

        guard process.terminationStatus == 0 else {
            throw BridgeError.commandFailed(message: Self.errorMessage(from: errorData))
        }

        return outputData
    }

    private static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(BridgeErrorPayload.self, from: data) {
            return payload.error
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "device-bridge の実行に失敗しました" : trimmed
    }

    /// `uv` の実行ファイルを探す。`UV_PATH` があればそれを優先する。
    private static func uvURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["UV_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        throw BridgeError.uvNotFound
    }

    /// Python パッケージのあるディレクトリ。`DEVICE_BRIDGE_DIR` があればそれを優先する。
    private static func bridgeDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["DEVICE_BRIDGE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        // <root>/app/Sources/MacApp/Bridge/DeviceBridge.swift → <root>
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Bridge
            .deletingLastPathComponent()  // MacApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // <root>
        return repositoryRoot.appendingPathComponent("bridge")
    }
}

/// `device-bridge` が stderr に出力するエラー JSON。
private struct BridgeErrorPayload: Decodable {
    let error: String
}

/// ブリッジ実行時のエラー。
enum BridgeError: LocalizedError {
    case uvNotFound
    case commandFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv が見つかりません。UV_PATH を設定してください。"
        case .commandFailed(let message):
            return message
        }
    }
}
