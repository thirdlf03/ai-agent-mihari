import Foundation
import os

/// `device-bridge serve` を子プロセスとして起動し、終了まで面倒を見る。
///
/// stdin は開いたまま保持する。アプリが死ぬとパイプが閉じ、Python 側がそれを検知して
/// 自分から終了する。孤児のデーモンが残らないための仕掛け。
public final class DaemonProcess: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "daemon")

    /// 起動後、ポート通知を待つ上限。uv の初回同期が走ると時間がかかるため長めに取る。
    public static let announcementTimeout: Duration = .seconds(60)

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    public let token: String
    public private(set) var announcement: DaemonAnnouncement?

    public var isRunning: Bool { process.isRunning }

    /// プロセスが終了したときに呼ばれる。予期しない終了の検知に使う。
    public var onTermination: (@Sendable (Int32) -> Void)?

    public init(token: String = UUID().uuidString) {
        self.token = token
    }

    /// 起動して、ポート通知が届くまで待つ。
    public func start(locator: DaemonLocator = DaemonLocator()) async throws -> DaemonAnnouncement {
        let uv = try locator.uvPath()
        let bridge = try locator.bridgeDirectory()

        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = [
            "run", "--frozen", "--project", bridge,
            "device-bridge", "serve", "--token", token,
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [onTermination] process in
            Self.logger.info("daemon exited: status=\(process.terminationStatus, privacy: .public)")
            onTermination?(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw DaemonError.launchFailed(message: error.localizedDescription)
        }

        let announcement = try await readAnnouncement()
        self.announcement = announcement
        Self.logger.info("daemon ready on port \(announcement.port, privacy: .public)")
        return announcement
    }

    /// 終了させる。すでに落ちていれば何もしない。
    public func terminate() {
        guard process.isRunning else { return }
        // stdin を閉じると Python 側が自分から終わる。届かない場合に備えて SIGTERM も送る。
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
    }

    /// stderr に溜まった内容。起動に失敗した理由を出すために使う。
    public func drainStandardError() -> String {
        let data = stderrPipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func readAnnouncement() async throws -> DaemonAnnouncement {
        let handle = stdoutPipe.fileHandleForReading
        let line = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                Self.readLine(from: handle)
            }
            group.addTask {
                try await Task.sleep(for: Self.announcementTimeout)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }

        guard let line else {
            let stderr = drainStandardError()
            terminate()
            throw DaemonError.announcementUnreadable(
                message: stderr.isEmpty ? "\(Self.announcementTimeout) 待っても応答がない" : stderr
            )
        }
        return try DaemonAnnouncement.decode(line: line)
    }

    /// stdout から改行までを 1 行読む。1 行しか出さない約束なので、この後は読まない。
    private static func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF。プロセスが即死した場合はここに来る。
                return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return String(data: buffer[..<index], encoding: .utf8)
            }
        }
    }
}
