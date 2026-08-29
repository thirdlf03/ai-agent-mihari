import Foundation
import SwiftUI
import os

/// デーモンの起動・接続・再起動を束ねる。
///
/// 画面はこの型の `@Published` だけを見る。プロセスと HTTP の面倒はここで完結させる。
@MainActor
public final class DaemonController: ObservableObject {

    /// アプリから見たデーモンの状態。
    public enum State: Equatable {
        case stopped
        case starting
        case running(port: Int, pid: Int)
        case failed(message: String)

        public var label: String {
            switch self {
            case .stopped: return "停止中"
            case .starting: return "起動中…"
            case .running(let port, let pid): return "稼働中 (port \(port) / pid \(pid))"
            case .failed(let message): return "失敗: \(message)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "daemon-controller")

    /// 画面に残すイベントの件数。古いものから捨てる。
    public static let eventHistoryLimit = 50

    /// 予期しない終了から再起動するまでの待ち時間。
    public static let restartDelay: Duration = .seconds(2)

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var isStreamConnected = false
    @Published public private(set) var events: [DaemonEvent] = []
    @Published public private(set) var devices: [DeviceSummary] = []
    @Published public private(set) var lastError: String?

    private var process: DaemonProcess?
    private var client: DaemonClient?
    private var streamTask: Task<Void, Never>?
    /// 明示的に止めたのか、落ちたのかを区別する。落ちたときだけ再起動する。
    private var stoppedIntentionally = false

    public init() {}

    /// 他のコントローラに渡すための接続済みクライアント。デーモンが動いていなければ `nil`。
    public var connectedClient: DaemonClient? { client }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// デーモンを起動し、イベントの購読を始める。
    public func start() async {
        guard case .stopped = state else { return }
        state = .starting
        stoppedIntentionally = false
        lastError = nil

        let process = DaemonProcess()
        process.onTermination = { [weak self] status in
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }
        self.process = process

        do {
            let announcement = try await process.start()
            guard let baseURL = announcement.baseURL else {
                throw DaemonError.announcementUnreadable(message: "接続先を組み立てられない")
            }
            client = DaemonClient(baseURL: baseURL, token: process.token)
            state = .running(port: announcement.port, pid: announcement.pid)
            startStreaming()
        } catch {
            let message = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("daemon start failed: \(message, privacy: .public)")
            state = .failed(message: message)
            lastError = message
            self.process = nil
        }
    }

    /// デーモンを止める。アプリ終了時にも必ず通る。
    public func stop() {
        stoppedIntentionally = true
        streamTask?.cancel()
        streamTask = nil
        isStreamConnected = false
        process?.terminate()
        process = nil
        client = nil
        devices = []
        state = .stopped
    }

    public func restart() async {
        stop()
        await start()
    }

    /// iPhone の一覧を取り直す。
    public func refreshDevices(wifi: Bool = true) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            devices = try await client.devices(wifi: wifi).devices
            lastError = nil
        } catch {
            devices = []
            lastError = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 経路が端から端まで通っているかを確かめる。Python 側から SSE でイベントが返ってくる。
    public func sendTestEvent() async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            try await client.publishTestEvent(name: "test.ping", payload: ["from": "app"])
            lastError = nil
        } catch {
            lastError = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startStreaming() {
        guard let client else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.consumeEvents(client: client)
        }
    }

    private func consumeEvents(client: DaemonClient) async {
        do {
            let (bytes, status) = try await client.openEventStream()

            guard (200..<300).contains(status) else {
                lastError = DaemonError.requestFailed(status: status, message: "SSE に接続できない").errorDescription
                return
            }

            isStreamConnected = true
            var parser = ServerSentEventParser()
            var lines = LineAccumulator()
            // bytes.lines は空行を捨ててしまい SSE のフレーム区切りが取れないため、自前で行に切る。
            for try await byte in bytes {
                guard let line = lines.consume(byte: byte) else { continue }
                guard let frame = parser.consume(line: line) else { continue }
                append(frame: frame)
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.error("event stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        isStreamConnected = false
    }

    private func append(frame: ServerSentEventParser.Frame) {
        guard let data = frame.data.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: data) else {
            Self.logger.error("イベントを解釈できない: \(frame.data, privacy: .public)")
            return
        }
        events.insert(event, at: 0)
        if events.count > Self.eventHistoryLimit {
            events.removeLast(events.count - Self.eventHistoryLimit)
        }
    }

    private func handleTermination(status: Int32) {
        isStreamConnected = false
        guard !stoppedIntentionally else { return }

        // 落ちた。状態を落としてから、少し待って起動し直す。
        let message = "デーモンが終了した (status=\(status))"
        Self.logger.error("\(message, privacy: .public)")
        lastError = message
        streamTask?.cancel()
        streamTask = nil
        process = nil
        client = nil
        state = .stopped

        Task { [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard let self, !self.stoppedIntentionally else { return }
            await self.start()
        }
    }
}
