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
    /// `pending_questions` の未回答分。会話 UI で回答する。
    @Published public private(set) var pendingQuestions: [VoicePendingQuestion] = []
    /// 会話から依頼した直近の仕事 ID（Hermes job と voice session は別）。
    @Published public private(set) var activeVoiceJobID: String?

    public struct Dependencies {
        var connector: VoiceStreamConnector
        var speechPlayer: SpeechPlayer
        var voicevox: VoicevoxClient
        var micFactory: @MainActor () -> any MicCapturing
        var jobCollaboration: any VoiceJobCollaborating
        var screenCapture: any VoiceScreenCapturing
        /// 仕事依頼成功時 `(jobID, title)`。`RoomJobMonitor.attach` などへ。
        var onJobSubmitted: (@MainActor (_ jobID: String, _ title: String?) -> Void)?
        /// マイク権限の照会。テストでは実機の TCC を見ないよう差し替える。
        var checkMicPermission: @Sendable () -> PermissionState = {
            PermissionChecker.check(.microphone)
        }
        /// マイク権限の要求。許可されたかだけを返す。テストではプロンプトを出さないよう差し替える。
        var requestMicPermission: @Sendable () async -> Bool = {
            _ = await PermissionRequester.request(.microphone)
            return PermissionChecker.check(.microphone).grant == .granted
        }

        @MainActor public static func makeDefault(
            speechPlayer: SpeechPlayer,
            onJobSubmitted: (@MainActor (_ jobID: String, _ title: String?) -> Void)? = nil
        ) -> Dependencies {
            Dependencies(
                connector: VoiceStreamConnector(),
                speechPlayer: speechPlayer,
                voicevox: VoicevoxClient(),
                micFactory: { AVAudioMicCapture() },
                jobCollaboration: LiveVoiceJobCollaboration.makeFromEnvironment(),
                screenCapture: LiveVoiceScreenCapture(),
                onJobSubmitted: onJobSubmitted
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
    /// 待機中の質問を取り直す間隔(秒)。
    private static let questionPollInterval: TimeInterval = 8

    private let deps: Dependencies
    private var runTask: Task<Void, Never>?
    private var mic: (any MicCapturing)?
    private var currentSocket: (any VoiceStreamSocket)?
    private var sessionID: String?
    private var streamPath: String?

    private var backoffSeconds: TimeInterval = 1
    private var shouldReconnect = false
    private var manualReconnectRequested = false

    /// input.audio などの送信を直列化するチェーン。チャンクごとに Task を並べると
    /// 到着順が不定になるため、前の送信の完了を待ってから次を送る。
    private var sendTail: Task<Void, Never>?
    /// 発話終了の見張り。最後に声を検した時点から無音が続いたらターンを確定する。
    private var silenceWatchdog: Task<Void, Never>?
    /// 会話中の質問の取り直しループ。
    private var questionPollTask: Task<Void, Never>?

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
        pendingQuestions = []
        connectionState = .connecting
        statusText = "接続中…"
        appendSystem("会話を開始した")

        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        startMic()
        startQuestionPolling()
    }

    /// 会話を終了する。
    public func stop() {
        // 窓を閉じる操作などからの再入で、終了処理を二度走らせない。
        guard isActive else { return }
        shouldReconnect = false
        isActive = false
        stopMic()
        runTask?.cancel()
        runTask = nil
        questionPollTask?.cancel()
        questionPollTask = nil
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

    /// 「画面見て」: マウスがあるディスプレイ 1 枚を撮って `input.image` で送る（確認なし）。
    public func captureAndSendScreen(prompt: String = "この画面を見て状況を説明して。") {
        guard isActive else { return }
        Task { await performCaptureAndSend(prompt: prompt) }
    }

    /// 表示中の質問へ回答する。
    public func submitPendingQuestionAnswer(_ answer: String, questionID: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let question = pendingQuestions.first(where: { $0.questionID == questionID })
        else {
            return
        }
        pendingQuestions.removeAll(where: { $0.questionID == questionID })
        appendMessage(VoiceConversationMessage(role: .user, text: trimmed))
        Task {
            do {
                _ = try await deps.jobCollaboration.answerQuestion(
                    jobID: question.jobID,
                    questionID: question.questionID,
                    answer: trimmed
                )
                appendSystem("回答を送った（\(question.questionID)）")
                await refreshPendingQuestions(jobID: question.jobID)
            } catch {
                appendSystem("回答を送れなかった: \(error.localizedDescription)")
                mergePendingQuestions([question])
            }
        }
    }

    // MARK: - §5-3 ツール・仕事・画面

    private func handleToolCall(name: String, arguments: String) {
        let action = VoiceToolCallHandler.action(for: name, arguments: arguments)
        Task {
            switch action {
            case .captureScreen(let prompt):
                await performCaptureAndSend(prompt: prompt)
            case .submitJob(let title, let body):
                await performSubmitJob(title: title, body: body)
            case .steerJob(let jobID, let instruction):
                await performSteer(jobID: jobID, instruction: instruction)
            case .getJobStatus(let jobID):
                await performGetJobStatus(jobID: jobID)
            case .showQuestion(let jobID, let questionID, let prompt):
                mergePendingQuestions([
                    VoicePendingQuestion(jobID: jobID, questionID: questionID, prompt: prompt),
                ])
            case .unsupported:
                break
            }
        }
    }

    private func performCaptureAndSend(prompt: String) async {
        statusText = "画面を撮影中…"
        do {
            let capture = try await deps.screenCapture.captureMouseDisplayPNG()
            try await sendInputImage(png: capture.pngData, prompt: prompt)
            let thumbnail = VoiceScreenThumbnail.png(from: capture.pngData)
            appendMessage(
                VoiceConversationMessage(
                    role: .user,
                    text: "（\(capture.displayTitle) の画面を送信）",
                    imageThumbnailPNG: thumbnail
                )
            )
            statusText = connectionState == .ready ? "話しかけてください" : statusText
        } catch {
            appendSystem("画面を送れなかった: \(error.localizedDescription)")
            statusText = error.localizedDescription
        }
    }

    private func sendInputImage(png: Data, prompt: String) async throws {
        // input.audio と同じ送信チェーンに載せ、音声チャンクとの順序を保つ。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendTail = Task { [sendTail] in
                _ = await sendTail?.value
                do {
                    guard let socket = currentSocket else {
                        throw VoiceSessionError.notReady
                    }
                    let text = try VoiceOutgoingFrame.inputImage(png: png, prompt: prompt)
                    try await socket.send(text)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performSubmitJob(title: String, body: String) async {
        let resolvedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedBody.isEmpty else {
            appendSystem("仕事依頼: 本文が空だった")
            return
        }
        do {
            let response = try await deps.jobCollaboration.submitJob(title: title, body: resolvedBody)
            if let jobID = response.jobID, !jobID.isEmpty {
                activeVoiceJobID = jobID
                deps.onJobSubmitted?(jobID, JobRequestClient.resolveTitle(title: title, body: resolvedBody))
                appendSystem("仕事を依頼した（\(jobID)）")
                await refreshPendingQuestions(jobID: jobID)
            } else {
                appendSystem("仕事を依頼した（ID 不明）")
            }
        } catch {
            appendSystem("仕事を依頼できなかった: \(error.localizedDescription)")
        }
    }

    private func performSteer(jobID: String?, instruction: String) async {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            appendSystem("steer: 指示が空だった")
            return
        }
        guard let targetJobID = resolvedJobID(jobID) else {
            appendSystem("steer: 対象の仕事が無い")
            return
        }
        do {
            let response = try await deps.jobCollaboration.steer(
                jobID: targetJobID,
                instruction: text
            )
            // room は実行中の作業への即時配信を保証しない。届いていなければ
            // 保存だけ済んで次ターンで読まれる旨をはっきり出す。
            if response.delivered == false {
                appendSystem("仕事 \(targetJobID) に指示を保存した（実行中の作業へは未配信・次ターンで読み込まれる）")
            } else {
                appendSystem("仕事 \(targetJobID) へ指示を送った")
            }
            await refreshPendingQuestions(jobID: targetJobID)
        } catch {
            appendSystem("steer に失敗: \(error.localizedDescription)")
        }
    }

    private func performGetJobStatus(jobID: String?) async {
        if let targetJobID = resolvedJobID(jobID) {
            await reportJobStatus(jobID: targetJobID)
            return
        }
        do {
            let running = try await deps.jobCollaboration.listRunning()
            if running.isEmpty {
                appendSystem("走っている仕事は無い")
                return
            }
            for detail in running {
                await reportJobStatus(jobID: detail.jobID, detail: detail)
            }
        } catch {
            appendSystem("進捗を取得できなかった: \(error.localizedDescription)")
        }
    }

    private func reportJobStatus(jobID: String, detail: RoomJobDetail? = nil) async {
        do {
            // `??` の自動クロージャは async/throws を包めないので素直に分岐する。
            let resolved: RoomJobDetail
            if let detail {
                resolved = detail
            } else {
                resolved = try await deps.jobCollaboration.fetchJob(jobID: jobID)
            }
            appendSystem(VoiceJobQuestionParser.statusSummary(from: resolved))
            let pending = VoiceJobQuestionParser.pendingQuestions(from: resolved)
            if !pending.isEmpty {
                mergePendingQuestions(pending)
            }
            if resolved.status == RoomJobStatus.running.rawValue
                || resolved.status == RoomJobStatus.waitingForInput.rawValue
            {
                activeVoiceJobID = resolved.jobID
            }
        } catch {
            appendSystem("仕事 \(jobID) の状態を読めなかった: \(error.localizedDescription)")
        }
    }

    private func refreshPendingQuestions(jobID: String) async {
        guard let detail = try? await deps.jobCollaboration.fetchJob(jobID: jobID) else { return }
        let pending = VoiceJobQuestionParser.pendingQuestions(from: detail)
        pendingQuestions.removeAll(where: { $0.jobID == jobID })
        mergePendingQuestions(pending)
    }

    private func mergePendingQuestions(_ incoming: [VoicePendingQuestion]) {
        for question in incoming {
            guard !question.jobID.isEmpty, !question.questionID.isEmpty, !question.prompt.isEmpty else {
                continue
            }
            if pendingQuestions.contains(where: { $0.questionID == question.questionID }) {
                continue
            }
            pendingQuestions.append(question)
            appendSystem("質問: \(question.prompt)")
        }
    }

    private func resolvedJobID(_ explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        return activeVoiceJobID
    }

    /// 質問が来てもツール呼び出しが届かない経路があるため、会話から依頼した仕事が
    /// あるあいだは `pending_questions` を定期的に取り直す。
    private func startQuestionPolling() {
        questionPollTask?.cancel()
        questionPollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isActive {
                try? await Task.sleep(for: .seconds(Self.questionPollInterval))
                guard !Task.isCancelled, self.isActive else { break }
                if let jobID = self.activeVoiceJobID {
                    await self.refreshPendingQuestions(jobID: jobID)
                }
            }
        }
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

        case .historySync(let entries):
            applyHistorySync(entries)
            return false

        case .userText(let text):
            applyUserTranscript(text)
            return false

        case .assistantText(let delta, let text, let done):
            // done フレームの text は全文なので、delta の累積へ足すと二重になる。
            // 全文が届いたら累積を捨てて置き換える。
            if done, !text.isEmpty {
                pendingAssistantText = text
                updateAssistantDraft(text)
                finalizeAssistantMessage()
                return false
            }
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

        case .assistantToolCall(let name, _, let arguments):
            appendSystem("ツール呼び出し: \(name)")
            handleToolCall(name: name, arguments: arguments)
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
        switch deps.checkMicPermission().grant {
        case .granted:
            beginMicCapture()
        case .undetermined:
            // まだ聞いていないので、ここで一度だけプロンプトを出す。結果を見てから開始する。
            statusText = "マイクの許可を待っている…"
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.deps.requestMicPermission()
                guard self.isActive else { return }
                if granted {
                    self.beginMicCapture()
                } else {
                    self.showMicPermissionRequired()
                }
            }
        case .denied:
            showMicPermissionRequired()
        }
    }

    private func showMicPermissionRequired() {
        statusText = "マイクの利用許可が必要"
        appendSystem("マイクの利用許可が必要です。システム設定のプライバシーとセキュリティから許可してください")
    }

    private func beginMicCapture() {
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
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
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
            scheduleSilenceWatchdog()
        }

        if isUserSpeaking {
            if !speakingNow,
                let lastSpeechTime,
                Date().timeIntervalSince(lastSpeechTime) >= Self.silenceDuration
            {
                // 無音が続いたので発話終了とみなし、このチャンクは送らず確定する。
                commitUserTurn()
            } else {
                // 発話中は語尾の小さい音も欠けないよう、レベルに関係なくすべての
                // チャンクを送る。空のチャンクは sendAudioChunk 側で捨てられる。
                hasStreamedAudioInTurn = true
                sendAudioChunk(data, commit: false, createResponse: false)
            }
        }
    }

    /// 最後に声を検した時点から無音が続いたかを見る。チャンクが途絶えても
    /// ターンが確定するように、発話のたびに仕掛け直す。
    private func scheduleSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceDuration))
            guard let self, !Task.isCancelled else { return }
            guard self.isUserSpeaking,
                let lastSpeechTime = self.lastSpeechTime,
                Date().timeIntervalSince(lastSpeechTime) >= Self.silenceDuration
            else { return }
            self.commitUserTurn()
        }
    }

    private func commitUserTurn() {
        guard isUserSpeaking else { return }
        isUserSpeaking = false
        lastSpeechTime = nil
        silenceWatchdog?.cancel()
        silenceWatchdog = nil

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
        let previous = sendTail
        sendTail = Task {
            // 前の送信が終わってから送り、フレームの順序を保つ。
            _ = await previous?.value
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

    /// 発話確定時に履歴へ置く、文字起こし待ちの目印。`user.text` が届いたら書き換える。
    private static let userPlaceholderText = "（音声を送信）"

    private func appendUserPlaceholder() {
        appendMessage(VoiceConversationMessage(role: .user, text: Self.userPlaceholderText))
    }

    /// room が送る入力音声の文字起こし。直前がプレースホルダなら本当の文に差し替え、
    /// そうでなければ新しい user 行として追加する。
    private func applyUserTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        if let last = messages.last,
            last.role == .user,
            last.text == Self.userPlaceholderText
        {
            messages[messages.count - 1].text = text
        } else {
            appendMessage(VoiceConversationMessage(role: .user, text: text))
        }
    }

    private func updateAssistantDraft(_ text: String) {
        if let id = currentAssistantMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            messages[index] = VoiceConversationMessage(
                id: id,
                role: .assistant,
                text: text,
                timestamp: messages[index].timestamp,
                imageThumbnailPNG: messages[index].imageThumbnailPNG
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

    /// room から送られた `history.sync` でローカル履歴を置き換える。
    private func applyHistorySync(_ entries: [VoiceHistorySyncEntry]) {
        pendingAssistantText = ""
        currentAssistantMessageID = nil
        messages = entries.compactMap { $0.asConversationMessage() }
        statusText = "履歴を同期した（\(messages.count) 件）"
    }

    private func closeSocket() {
        let socket = currentSocket
        currentSocket = nil
        sendTail = nil
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
        sendTail = nil
    }
}
