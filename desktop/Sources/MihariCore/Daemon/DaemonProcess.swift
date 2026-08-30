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

    /// 手元に残す stderr の行数。起動に失敗した理由を出すのに足りればよい。
    public static let stderrTailLines = 50

    /// 終了を待つ上限。これを過ぎたら SIGKILL に切り替える。
    public static let terminationTimeout: TimeInterval = 5

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// stderr は読み出しハンドラ(別スレッド)と `drainStandardError()` の両方から触る。
    private let stderrLock = NSLock()
    private var stderrLog = DaemonStderrLog(capacity: DaemonProcess.stderrTailLines)

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
        startDrainingStandardError()

        let announcement = try await readAnnouncement()
        self.announcement = announcement
        Self.logger.info("daemon ready on port \(announcement.port, privacy: .public)")
        return announcement
    }

    /// 終了させる。すでに落ちていれば何もしない。
    ///
    /// `applicationWillTerminate` から同期的に呼ばれるため、この関数は同期のまま
    /// 終わるところまで見届ける。落ちきらないうちにアプリが消えると、ポートを掴んだ
    /// デーモンだけが残る。
    public func terminate() {
        guard process.isRunning else { return }

        let uvPID = process.processIdentifier
        let pythonPID = announcement.map { Int32($0.pid) }

        // stdin を閉じると Python 側が自分から終わる。届かない場合に備えて SIGTERM も送る。
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
        // uv への SIGTERM は uv 止まりのことがある。ポート通知で受け取った Python の
        // pid にも直接送らないと、子だけが生き残ってポートを掴んだままになる。
        if let pythonPID, pythonPID > 0 {
            kill(pythonPID, SIGTERM)
        }

        if waitForExit(within: Self.terminationTimeout) {
            Self.logger.info("daemon を正常終了させた: status=\(self.process.terminationStatus, privacy: .public)")
            return
        }

        Self.logger.error(
            "daemon が \(Self.terminationTimeout, privacy: .public) 秒待っても終わらないので強制終了する"
        )
        kill(uvPID, SIGKILL)
        if let pythonPID, pythonPID > 0 {
            kill(pythonPID, SIGKILL)
        }
    }

    /// これまでに拾った stderr の直近ぶん。起動に失敗した理由を出すために使う。
    public func drainStandardError() -> String {
        withStderrLog { $0.recentText }
    }

    /// stderr を読み続け、行ごとに unified log へ流す。
    ///
    /// 誰も読まないとパイプのバッファ(64KB)が埋まった時点で子プロセスが書き込みで
    /// 止まる。読み続けることが、記録を残すことと詰まりの予防を兼ねる。
    private func startDrainingStandardError() {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF。子プロセスが stderr を閉じた。改行の付かないまま残った行を吐いて手を引く。
                handle.readabilityHandler = nil
                let leftover = self.withStderrLog { $0.flush() }
                Self.emit(lines: leftover.map { [$0] } ?? [])
                return
            }
            Self.emit(lines: self.withStderrLog { $0.consume(chunk: chunk) })
        }
    }

    private static func emit(lines: [String]) {
        for line in lines {
            logger.info("daemon stderr: \(line, privacy: .public)")
        }
    }

    private func withStderrLog<T>(_ body: (inout DaemonStderrLog) -> T) -> T {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return body(&stderrLog)
    }

    /// 終了するまで待つ。時間内に終わらなければ `false`。
    private func waitForExit(within timeout: TimeInterval) -> Bool {
        let process = self.process
        let done = DispatchSemaphore(value: 0)
        // `waitUntilExit()` は終わるまで戻らないので、別スレッドに待たせて手元は期限付きで待つ。
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
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
