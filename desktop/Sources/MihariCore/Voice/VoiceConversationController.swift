import Foundation
import os

/// §5-2: room voice WS → テキスト → VOICEVOX 短文 → 再生。割り込み・エコー対策・履歴・再接続。
@MainActor
public final class VoiceConversationController: ObservableObject {

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case ready
        case reconnecting
        case error(String)
    }

    /// 接続状態。
    @Published public private(set) var connectionState: ConnectionState = .idle
    /// テキスト履歴（マイク音声ファイルは保存しない）。
    @Published public private(set) var messages: [VoiceConversationMessage] = []
    /// 状態パネル用の 1 行。
    @Published public private(set) var statusText = "未接続"
    /// 会話が有効か。
    @Published public private(set) var isActive = false
    /// マイクが有効か（エコー対策で一時停止中は false）。
    @Published public private(set) var isMicLive = false

    struct Dependencies {
        var connector: VoiceStreamConnector
        var speechPlayer: SpeechPlayer
        var voicevox: VoicevoxClient
        var micFactory: @MainActor () -> any MicCapturing

        @MainActor static func makeDefault(speechPlayer: SpeechPlayer) -> Dependencies {
            Dependencies(
                connector: VoiceStreamConnector(),
                speechPlayer: speechPlayer,
                voicevox: VoicevoxClient(),
                micFactory: { AVAudioMicCapture() }
            )
        }
    }

    private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "VoiceConversation"
    )

    /// 発話判定の RMS しきい値。
    private static let speechThreshold: Float = 0.015
    /// 発話終了とみなす無音時間(秒)。
    private static let silenceDuration: TimeInterval = 0.75
    /// 再接続の最大待ち(秒)。
    private static let maxBackoff: TimeInterval = 30

    private let deps: Dependencies
    private var runTask: Task<Void, Never>?
    private var mic: (any MicCapturing)?
    private var currentSocket: (any VoiceStreamSocket)?
    private var sessionID: String?
    private var streamPath: String?

    private var backoffSeconds: TimeInterval = 1
    private var shouldReconnect = false
    private var manualReconnectRequested = false

    /// 再生中はマイク送信を止める（エコー対策）。
    private var echoGuardActive = false
    /// 合成・再生の世代。古い結果は捨てる。
    private var playbackGeneration = 0
    /// 受信中の assistant テキスト。
    private var pendingAssistantText = ""
    private var currentAssistantMessageID: UUID?

    /// VAD 状態。発話中に commit:false で送ったか（確定時に全体を再送しない）。
    private var hasStreamedAudioInTurn = false
    private var isUserSpeaking = false
    private var lastSpeechTime: Date?

    public init(deps: Dependencies) {
        self.deps = deps
    }

    /// `SpeechPlayer.onPlaybackFinished` から呼ぶ（`VoiceController` とチェーンすること）。
    public func handlePlaybackFinished(priority: SpeechPriority) {
        guard priority == .chatter else { return }
        handlePlaybackFinished()
    }

    /// 会話を開始する。
    public func start() {
        guard !isActive else { return }
        isActive = true
        shouldReconnect = true
        manualReconnectRequested = false
        backoffSeconds = 1
        messages = []
        connectionState = .connecting
        statusText = "接続中…"
        appendSystem("会話を開始した")

        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        startMic()
    }

    /// 会話を終了する。
    public func stop() {
        shouldReconnect = false
        isActive = false
        stopMic()
        runTask?.cancel()
        runTask = nil
        closeSocket()
        playbackGeneration += 1
        deps.speechPlayer.stop(priority: .chatter)
        echoGuardActive = false
        isMicLive = false
        connectionState = .idle
        statusText = "終了"
        appendSystem("会話を終了した")
    }

    /// 手動で再接続する（常に新規セッション）。
    public func reconnect() {
        guard isActive else { return }
        manualReconnectRequested = true
        clearSession()
        closeSocket()
    }

    // MARK: - 接続ループ

    private func runLoop() async {
        while !Task.isCancelled, isActive {
            do {
                let connection = try await openConnection()
                currentSocket = connection.socket
                backoffSeconds = 1

                var ready = false
                while !Task.isCancelled, isActive {
                    guard let text = try await connection.socket.receive() else { break }
                    guard let data = text.data(using: .utf8),
                        let frame = VoiceIncomingFrame.parse(data: data)
                    else {
                        continue
                    }
                    if handleIncoming(frame) {
                        ready = true
                    }
                }
                if ready {
                    connectionState = .idle
                }
            } catch is CancellationError {
                break
            } catch {
                clearSession()
                connectionState = .error(error.localizedDescription)
                statusText = "切断: \(error.localizedDescription)"
                appendSystem("切断: \(error.localizedDescription)")
                Self.logger.debug("voice stream failed: \(error.localizedDescription, privacy: .public)")
            }

            closeSocket()
            guard isActive, shouldReconnect else { break }

            connectionState = .reconnecting
            statusText = "再接続を待つ… (\(Int(backoffSeconds))秒)"
            let delay = backoffSeconds
            backoffSeconds = min(backoffSeconds * 2, Self.maxBackoff)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    @discardableResult
    private func handleIncoming(_ frame: VoiceIncomingFrame) -> Bool {
        switch frame {
        case .sessionReady(let sessionID, let model):
            connectionState = .ready
            statusText = "接続済み (\(model))"
            appendSystem("セッション \(sessionID) が準備できた")
            return true

        case .assistantText(let delta, let text, let done):
            let piece = !delta.isEmpty ? delta : text
            guard !piece.isEmpty else {
                if done { finalizeAssistantMessage() }
                return false
            }
            pendingAssistantText += piece
            updateAssistantDraft(pendingAssistantText)
            if done {
                finalizeAssistantMessage()
            }
            return false

        case .assistantToolCall(let name, _, _):
            appendSystem("ツール呼び出し: \(name)")
            return false

        case .error(_, let message):
            appendSystem("エラー: \(message)")
            statusText = message
            return false

        case .sessionClosed(let reason):
            let detail = reason.isEmpty ? "セッションが閉じた" : reason
            appendSystem(detail)
            statusText = detail
            clearSession()
            return false

        case .unknown:
            return false
        }
    }

    // MARK: - マイク

    private func startMic() {
        stopMic()
        let capture = deps.micFactory()
        capture.onChunk = { [weak self] data, level in
            Task { @MainActor [weak self] in
                self?.handleMicChunk(data: data, level: level)
            }
        }
        do {
            try capture.start()
            mic = capture
            isMicLive = true
        } catch {
            connectionState = .error(error.localizedDescription)
            statusText = "マイクを開始できない: \(error.localizedDescription)"
            appendSystem(statusText)
        }
    }

    private func stopMic() {
        mic?.stop()
        mic = nil
        isMicLive = false
        hasStreamedAudioInTurn = false
        isUserSpeaking = false
        lastSpeechTime = nil
    }

    private func handleMicChunk(data: Data, level: Float) {
        guard isActive else { return }

        let speakingNow = level >= Self.speechThreshold

        // 割り込み: 再生中にユーザーが話したら止める。
        if speakingNow, echoGuardActive || deps.speechPlayer.isSpeaking {
            bargeIn()
        }

        guard !echoGuardActive else {
            isMicLive = false
            return
        }
        isMicLive = mic?.isRunning ?? false

        if speakingNow {
            isUserSpeaking = true
            lastSpeechTime = Date()
            hasStreamedAudioInTurn = true
            sendAudioChunk(data, commit: false, createResponse: false)
        } else if isUserSpeaking {
            if let lastSpeechTime,
                Date().timeIntervalSince(lastSpeechTime) >= Self.silenceDuration
            {
                commitUserTurn()
            }
        }
    }

    private func commitUserTurn() {
        guard isUserSpeaking else { return }
        isUserSpeaking = false
        lastSpeechTime = nil

        // 発話中に送ったチャンクを再送しない。commit + create_response だけ送る。
        if hasStreamedAudioInTurn {
            sendAudioChunk(Self.commitOnlyPCM, commit: true, createResponse: true)
            appendUserPlaceholder()
        }
        hasStreamedAudioInTurn = false
    }

    /// 確定専用の最小 PCM16（1 サンプル無音）。room は空 base64 を拒否する。
    private static let commitOnlyPCM = Data([0, 0])

    private func sendAudioChunk(_ pcm: Data, commit: Bool, createResponse: Bool) {
        guard let socket = currentSocket, !pcm.isEmpty else { return }
        Task {
            do {
                let text = try VoiceOutgoingFrame.inputAudio(
                    pcm16: pcm,
                    commit: commit,
                    createResponse: createResponse
                )
                try await socket.send(text)
            } catch {
                Self.logger.debug("input.audio send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func bargeIn() {
        playbackGeneration += 1
        pendingAssistantText = ""
        currentAssistantMessageID = nil
        deps.speechPlayer.stop(priority: .chatter)
        echoGuardActive = false
        isMicLive = mic?.isRunning ?? false
    }

    // MARK: - 合成・再生

    private func finalizeAssistantMessage() {
        let text = pendingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAssistantText = ""
        currentAssistantMessageID = nil
        guard !text.isEmpty else { return }

        if !messages.contains(where: { $0.role == .assistant && $0.text == text }) {
            appendMessage(VoiceConversationMessage(role: .assistant, text: text))
        }
        speakAssistant(text)
    }

    private func speakAssistant(_ text: String) {
        let spoken = Self.shortenForSpeech(text)
        guard !spoken.isEmpty else { return }

        playbackGeneration += 1
        let generation = playbackGeneration
        echoGuardActive = true
        isMicLive = false

        Task {
            do {
                let wave = try await deps.voicevox.synthesize(text: spoken)
                await MainActor.run {
                    guard generation == self.playbackGeneration, self.isActive else { return }
                    if self.deps.speechPlayer.play(audio: wave, priority: .chatter) {
                        self.statusText = "再生中…"
                    } else {
                        self.echoGuardActive = false
                        self.isMicLive = self.mic?.isRunning ?? false
                    }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.playbackGeneration else { return }
                    self.echoGuardActive = false
                    self.isMicLive = self.mic?.isRunning ?? false
                    self.appendSystem("VOICEVOX 合成に失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handlePlaybackFinished() {
        echoGuardActive = false
        isMicLive = mic?.isRunning ?? false
        if connectionState == .ready {
            statusText = "話しかけてください"
        }
    }

    /// 長文は先頭 1 文・最大 120 文字に切る（短文合成）。
    private static func shortenForSpeech(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let firstSentence =
            trimmed.split(whereSeparator: { ".。!！?？\n".contains($0) }).first.map(String.init)
            ?? trimmed
        if firstSentence.count <= 120 { return firstSentence }
        return String(firstSentence.prefix(119)) + "…"
    }

    // MARK: - 履歴

    private func appendUserPlaceholder() {
        appendMessage(VoiceConversationMessage(role: .user, text: "（音声を送信）"))
    }

    private func updateAssistantDraft(_ text: String) {
        if let id = currentAssistantMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            messages[index] = VoiceConversationMessage(
                id: id,
                role: .assistant,
                text: text,
                timestamp: messages[index].timestamp
            )
        } else {
            let message = VoiceConversationMessage(role: .assistant, text: text)
            currentAssistantMessageID = message.id
            appendMessage(message)
        }
    }

    private func appendSystem(_ text: String) {
        appendMessage(VoiceConversationMessage(role: .system, text: text))
    }

    private func appendMessage(_ message: VoiceConversationMessage) {
        messages.append(message)
    }

    private func closeSocket() {
        let socket = currentSocket
        currentSocket = nil
        if let socket {
            Task { await socket.close() }
        }
    }

    /// 再接続可能なら同一セッションへ。`closed` や失敗時は新規セッション。
    private func openConnection() async throws -> VoiceStreamConnection {
        if manualReconnectRequested {
            manualReconnectRequested = false
            return try await connectNew()
        }

        if let sessionID, let streamPath {
            connectionState = .reconnecting
            statusText = "再接続中…"
            if let restored = try await deps.connector.tryReconnect(
                sessionID: sessionID,
                streamPath: streamPath
            ) {
                return restored
            }
            clearSession()
            appendSystem("セッションが閉じていたため新規セッションを開始する")
        }

        return try await connectNew()
    }

    private func connectNew() async throws -> VoiceStreamConnection {
        connectionState = .connecting
        statusText = "接続中…"
        let connection = try await deps.connector.connectNew()
        sessionID = connection.sessionID
        streamPath = connection.streamPath
        return connection
    }

    private func clearSession() {
        sessionID = nil
        streamPath = nil
    }
}
