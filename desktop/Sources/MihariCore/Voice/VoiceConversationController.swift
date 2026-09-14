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
    /// 「話す」を押下中か（押しているあいだだけ音声を送る）。
    @Published public private(set) var isTalking = false
    /// 今まさに音声をソケットへ流しているか。
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
        /// `assistant.audio`（PCM16 24 kHz）の逐次再生。テストではスタブに差し替える。
        var pcmPlayer: any PCMStreamPlaying = PCMStreamPlayer()
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
                pcmPlayer: PCMStreamPlayer(),
                onJobSubmitted: onJobSubmitted
            )
        }
    }

    private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "VoiceConversation"
    )

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
    /// 会話中の質問の取り直しループ。
    private var questionPollTask: Task<Void, Never>?
    /// 終了したセッションの `POST /close`。次の新規作成より先に終わらせるため保持する。
    private var pendingSessionClose: Task<Void, Never>?

    /// 再生中はマイク送信を止める（エコー対策）。
    private var echoGuardActive = false
    /// 合成・再生の世代。古い結果は捨てる。
    private var playbackGeneration = 0
    /// 受信中の assistant テキスト。
    private var pendingAssistantText = ""
    private var currentAssistantMessageID: UUID?

    /// このセッションで `assistant.audio` を受けたか。受けたら音声は room 側（VC 済み）が
    /// 返すため、以降の `assistant.text` では VOICEVOX 合成・再生を行わない（二重発話防止）。
    private var assistantAudioMode = false

    /// upstream が無音も含めて入力音声を流し続ける前提のフルデュプレックスか
    /// （`session.ready` の `output_modalities` に `audio` を含む live_audio モード）。
    /// true のあいだは非押下中も無音チャンクを流してセッションのタイムラインを維持する。
    private var upstreamNeedsContinuousAudio = false

    /// 押下中に commit:false で送ったか（確定時に全体を再送しない）。
    private var hasStreamedAudioInTurn = false

    /// live_audio の逐次 `user.text` で更新中の user 行。`done: true` で確定し、
    /// 次の発話は新しい行から始める。
    private var streamingUserMessageID: UUID?

    /// 「話す」押下で始まった現在のターンに user.text が届いたか。
    /// フルデュプレックスでは押下中に文字起こしが先行することがあり、届いていれば
    /// 確定時の「（音声を送信）」プレースホルダは不要（孤児化の残存経路を塞ぐ）。
    private var userTranscriptSeenThisTurn = false

    public init(deps: Dependencies) {
        self.deps = deps
        // assistant.audio の 1 発話を鳴らし切ったらエコー対策を解除する。
        deps.pcmPlayer.onDrained = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePlaybackFinished()
            }
        }
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
        assistantAudioMode = false
        upstreamNeedsContinuousAudio = false
        streamingUserMessageID = nil
        connectionState = .connecting
        statusText = "接続中…"
        appendSystem("会話を開始した")

        // assistant.audio の再生エンジンを暖めておく（audio が来ないセッションでは使われない）。
        deps.pcmPlayer.start()

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
        isTalking = false
        stopMic()
        runTask?.cancel()
        runTask = nil
        questionPollTask?.cancel()
        questionPollTask = nil
        closeSocket()
        endServerSession()
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
        endServerSession()
        closeSocket()
    }

    /// 「話す」押下: 押しているあいだだけ音声を送る（プッシュ・トゥ・トーク）。
    /// 再生中に押した場合は割り込みとして再生を止める。
    public func beginPushToTalk() {
        guard isActive, !isTalking else { return }
        isTalking = true
        // 新しい発話ターンの開始。前ターンの transcript 到着フラグは降ろす。
        userTranscriptSeenThisTurn = false
        if echoGuardActive || deps.speechPlayer.isSpeaking {
            bargeIn()
        }
        if mic == nil {
            // 権限待ちなどでキャプチャが立っていなければ開始を試みる。
            startMic()
        }
        updateMicLive()
        if isMicLive, connectionState == .ready {
            statusText = "送信中…"
        }
    }

    /// 「話す」解放: 発話を確定して応答を要求する。
    public func endPushToTalk() {
        guard isTalking else { return }
        isTalking = false
        commitUserTurn()
        updateMicLive()
        if connectionState == .ready {
            statusText = "話しかけてください"
        }
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
                    VoicePendingQuestion(jobID: jobID, questionID: questionID, prompt: prompt)
                ])
            case .unsupported:
                break
            }
        }
    }

    private func performCaptureAndSend(prompt: String) async {
        statusText = "画面を撮影中…"
        do {
            // live_audio の delegation backend は入力履歴（128 items / 32768 UTF-8 bytes）が
            // 小さく、フル解像度 PNG の base64 が収まらず「input history is limited」で
            // 落ちた実績がある。そのモードでは縮小 JPEG（≤12KB 目標）で送る。
            let capture =
                upstreamNeedsContinuousAudio
                ? try await deps.screenCapture.captureMouseDisplayJPEG(
                    maxBytes: Self.liveImageMaxBytes
                )
                : try await deps.screenCapture.captureMouseDisplayPNG()
            try await sendInputImage(data: capture.data, mediaType: capture.mediaType, prompt: prompt)
            let thumbnail = VoiceScreenThumbnail.png(from: capture.data)
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

    /// live_audio で送る画像の目標サイズ（base64 前のバイト数）。
    /// base64 化で約 4/3 倍（~16K chars）になり、backend の入力上限内に収める。
    private static let liveImageMaxBytes = 12_000

    private func sendInputImage(data: Data, mediaType: String, prompt: String) async throws {
        // input.audio と同じ送信チェーンに載せ、音声チャンクとの順序を保つ。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendTail = Task { [sendTail] in
                _ = await sendTail?.value
                do {
                    guard let socket = currentSocket else {
                        throw VoiceSessionError.notReady
                    }
                    let text = try VoiceOutgoingFrame.inputImage(
                        data: data,
                        prompt: prompt,
                        mediaType: mediaType
                    )
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
                // 再接続では closeSocket で止まっているため起こし直す。冪等。
                deps.pcmPlayer.start()

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
        case .sessionReady(let sessionID, let model, let outputModalities):
            upstreamNeedsContinuousAudio = outputModalities.contains("audio")
            connectionState = .ready
            statusText = "接続済み (\(model))"
            appendSystem("セッション \(sessionID) が準備できた")
            return true

        case .historySync(let entries):
            applyHistorySync(entries)
            return false

        case .userText(let text, let delta, let done):
            applyUserTranscript(text, delta: delta, done: done)
            return false

        case .userTranscriptNone:
            // 音声は room に届いたが文字起こしが一度も来なかったターン
            // （live_audio）。残っている「（音声を送信）」を明示表示へ置き換える。
            // プレースホルダが無ければ何もしない。
            replaceUnresolvedUserPlaceholder(with: Self.userNoTranscriptText)
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

        case .assistantAudio(let pcm16, let done):
            handleAssistantAudio(pcm16: pcm16, done: done)
            return false

        case .assistantToolCall(let name, _, let arguments):
            // 進行中の assistant 下書きをここで確定する。確定しておかないと、
            // ツール実行後に届く応答テキストがツール行より上のバブルに追記されてしまう。
            finalizeAssistantMessage()
            appendSystem("ツール呼び出し: \(name)")
            handleToolCall(name: name, arguments: arguments)
            return false

        case .assistantToolActivity(let name, let callID, let status, let jobID, let title):
            // room が実行したツールの通知。client では実行しない。
            // tool_call と同じく、下書きを確定してから活動行を置く。
            finalizeAssistantMessage()
            appendSystem(VoiceToolActivityLabel.text(name: name, status: status, title: title))
            if name == "submit_job" {
                // 依頼時の活動通知は job_id フィールド、完了通知は call_id に
                // ジョブ ID が入る。届いたら RoomJobMonitor へ attach し、
                // 以降の進捗・完了発話・pending questions は既存の購読に任せる。
                let target = (jobID?.isEmpty == false ? jobID : nil) ?? callID
                if !target.isEmpty {
                    activeVoiceJobID = target
                    deps.onJobSubmitted?(target, title)
                }
            }
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
            updateMicLive()
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
    }

    /// isMicLive は「今音声をソケットへ流しているか」。押下中でエコー対策中でもなく、
    /// キャプチャが動いているときだけ true になる。
    private func updateMicLive() {
        isMicLive = isTalking && !echoGuardActive && (mic?.isRunning ?? false)
    }

    private func handleMicChunk(data: Data, level _: Float) {
        guard isActive else { return }
        if isTalking && !echoGuardActive {
            // 「話す」押下中は従来どおり実音声を送る。
            updateMicLive()
            hasStreamedAudioInTurn = true
            sendAudioChunk(data, commit: false, createResponse: false)
            return
        }
        // live_audio は入力が止まると upstream の応答も止まるため、話していない
        // あいだは同じ長さの無音をマイクのケイデンスで流し続ける。
        // text モードでは無音が確定ターンの input buffer を汚染するので送らない。
        guard upstreamNeedsContinuousAudio else { return }
        sendAudioChunk(Data(count: data.count), commit: false, createResponse: false)
    }

    private func commitUserTurn() {
        // 押下中に送ったチャンクを再送しない。commit + create_response だけ送る。
        if hasStreamedAudioInTurn {
            sendAudioChunk(Self.commitOnlyPCM, commit: true, createResponse: true)
            // このターンの user.text が既に届いている（= フルデュプレックスで
            // 文字起こしが先行した）なら、発話行はすでに存在するので
            // 「（音声を送信）」を新たに積まない（残ると孤児行になる）。
            if !userTranscriptSeenThisTurn {
                appendUserPlaceholder()
            }
        }
        hasStreamedAudioInTurn = false
        userTranscriptSeenThisTurn = false
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
        deps.pcmPlayer.stop()
        echoGuardActive = false
        updateMicLive()
    }

    // MARK: - 合成・再生

    /// 無音扱いにする PCM16 振幅の閾値。実測で無音フレームは peak 数十、
    /// 発話は数千〜1 万超なので十分に分離できる。
    private static let audiblePeakThreshold: Int16 = 512

    /// `assistant.audio`: room が VC 済みの音声を PCM で返すモード。
    /// 一度でも届いたらこのセッションでは VOICEVOX 経路へ流さない。
    private func handleAssistantAudio(pcm16: Data, done: Bool) {
        assistantAudioMode = true
        if !pcm16.isEmpty {
            deps.pcmPlayer.enqueue(pcm16: pcm16)
            statusText = "再生中…"
            // Live API は発話のあいだも無音フレームを垂れ流す。無音のたびに
            // エコーガードを立てるとマイクが常時ミュートになり会話が止まるので、
            // 実際に音が入っているフレームのときだけ立てる。
            if Self.hasAudibleSignal(pcm16) {
                echoGuardActive = true
                updateMicLive()
            }
        }
        if done {
            deps.pcmPlayer.finish()
        }
    }

    /// PCM16 LE モノラルに可聴レベルの信号があるか（無音フレームの判定用）。
    private static func hasAudibleSignal(_ pcm16: Data) -> Bool {
        pcm16.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count - 1, by: 2) {
                let s = Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
                if s > audiblePeakThreshold || s < -audiblePeakThreshold {
                    return true
                }
            }
            return false
        }
    }

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
        // assistant.audio モードでは音声は room が返すため、ここでは合成しない（二重発話防止）。
        // テキストは finalizeAssistantMessage で履歴に載っている。
        guard !assistantAudioMode else { return }

        let spoken = Self.shortenForSpeech(text)
        guard !spoken.isEmpty else { return }

        playbackGeneration += 1
        let generation = playbackGeneration
        echoGuardActive = true
        updateMicLive()

        Task {
            do {
                let wave = try await deps.voicevox.synthesize(text: spoken)
                await MainActor.run {
                    guard generation == self.playbackGeneration, self.isActive else { return }
                    if self.deps.speechPlayer.play(audio: wave, priority: .chatter) {
                        self.statusText = "再生中…"
                    } else {
                        self.echoGuardActive = false
                        self.updateMicLive()
                    }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.playbackGeneration else { return }
                    self.echoGuardActive = false
                    self.updateMicLive()
                    self.appendSystem("VOICEVOX 合成に失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handlePlaybackFinished() {
        echoGuardActive = false
        updateMicLive()
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

    /// `user.transcript_none` や切断・終了時に残ったプレースホルダへ書き込む明示表示。
    private static let userNoTranscriptText = "（聞き取れなかった）"

    /// 未置換の「（音声を送信）」が残っていれば `text` に書き換える。
    /// `user.transcript_none` 受信時と、切断・終了で取り残されたときの掃除に使う。
    private func replaceUnresolvedUserPlaceholder(with text: String) {
        guard let index = messages.lastIndex(where: {
            $0.role == .user && $0.text == Self.userPlaceholderText
        }) else { return }
        messages[index].text = text
    }

    private func appendUserPlaceholder() {
        // 未置換のプレースホルダが残っているのに追加すると、後の置き換えで片方が
        // 孤児行として残るため、残っているあいだは増やさない。
        guard !messages.contains(where: {
            $0.role == .user && $0.text == Self.userPlaceholderText
        }) else {
            return
        }
        appendMessage(VoiceConversationMessage(role: .user, text: Self.userPlaceholderText))
    }

    /// room が送る入力音声の文字起こし。
    ///
    /// live_audio の逐次形式（`delta` / `done` フィールド付き）は `text` が累積全文なので、
    /// 同一発話のあいだは同じ user 行を書き換えるだけにして行を増やさない。
    /// `done: true` で確定し、次の発話は新しい行から始める。
    /// 従来形式（`text` のみ）は非破壊のまま、プレースホルダ置換か新規行追加を行う。
    private func applyUserTranscript(_ text: String, delta: String?, done: Bool?) {
        guard delta != nil || done != nil else {
            if !text.isEmpty { userTranscriptSeenThisTurn = true }
            applyUserTranscriptFinal(text)
            return
        }
        defer {
            if done == true { streamingUserMessageID = nil }
        }
        guard !text.isEmpty else { return }
        userTranscriptSeenThisTurn = true

        // 進行中の発話行を追いかけて書き換える。途中に assistant/system 行が
        // 挟まっても ID で引き当てるため、同じ発話で行が増殖しない。
        if let id = streamingUserMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            messages[index].text = text
            return
        }
        // プッシュ・トゥ・トークのプレースホルダが残っていれば、その行を発話行にする。
        // live_audio はフルデュプレックスで assistant の出力が文字起こしより先に来るため、
        // 末尾だけでなく履歴の中から未置換のプレースホルダを探す（見つからなければ孤児になる）。
        if let index = messages.lastIndex(where: {
            $0.role == .user && $0.text == Self.userPlaceholderText
        }) {
            streamingUserMessageID = messages[index].id
            messages[index].text = text
            return
        }
        // done 確定後に遅れて届いた同一発話の delta は新規行にしない。
        // 直近 user 行と一致/包含なら同じ発話の続きとみなし、その行を引き継ぐ
        // （「今何してるんだっけ」が確定後にもう一度 delta で届く実機不具合の対策）。
        if let lastUser = messages.lastIndex(where: { $0.role == .user }) {
            let lastText = messages[lastUser].text
            if lastText != Self.userPlaceholderText,
                lastText == text || text.hasPrefix(lastText) || lastText.hasPrefix(text)
            {
                messages[lastUser].text = text.count > lastText.count ? text : lastText
                streamingUserMessageID = messages[lastUser].id
                return
            }
        }
        let message = VoiceConversationMessage(role: .user, text: text)
        streamingUserMessageID = message.id
        appendMessage(message)
    }

    /// 従来形式（`text` のみ）の確定済み文字起こし。未置換のプレースホルダが残って
    /// いればその行を本当の文に差し替え、そうでなければ新しい user 行として追加する。
    /// assistant の出力が先に履歴へ載っていても、末尾以外のプレースホルダを拾える。
    private func applyUserTranscriptFinal(_ text: String) {
        guard !text.isEmpty else { return }
        if let index = messages.lastIndex(where: {
            $0.role == .user && $0.text == Self.userPlaceholderText
        }) {
            messages[index].text = text
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
            return
        }
        // tool_activity 等でいったん確定した直後に、同じ全文の done が届く経路がある
        // （live_audio は transcript 確定が出力区切りまで遅れる）。直前に確定した
        // assistant 行と trim 一致するなら新バブルを作らず、その行を引き継ぐ。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }),
            messages[lastAssistant].text.trimmingCharacters(in: .whitespacesAndNewlines)
                == trimmed
        {
            currentAssistantMessageID = messages[lastAssistant].id
            return
        }
        let message = VoiceConversationMessage(role: .assistant, text: text)
        currentAssistantMessageID = message.id
        appendMessage(message)
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
        streamingUserMessageID = nil
        messages = entries.compactMap { $0.asConversationMessage() }
        statusText = "履歴を同期した（\(messages.count) 件）"
    }

    private func closeSocket() {
        let socket = currentSocket
        currentSocket = nil
        sendTail = nil
        // 切断で assistant.audio の再生が宙に浮かないよう止める。再接続時は runLoop が起こし直す。
        deps.pcmPlayer.stop()
        // 押下中に切断すると解放操作を受け取れないことがあるため、ここで戻す。
        isTalking = false
        hasStreamedAudioInTurn = false
        updateMicLive()
        // 切断・終了で残った「（音声を送信）」は二度と置き換わらないため明示表示にする。
        // 再接続に成功すれば history.sync で room の履歴に置き換わる。
        replaceUnresolvedUserPlaceholder(with: Self.userNoTranscriptText)
        if let socket {
            Task { await socket.close() }
        }
    }

    /// room 側のセッションを明示終了する。未 close のまま残すと
    /// 以降の `POST /voice/sessions` が 409 で拒否され続ける。
    private func endServerSession() {
        let closingSessionID = sessionID
        clearSession()
        guard let closingSessionID else { return }
        let connector = deps.connector
        pendingSessionClose = Task {
            try? await connector.closeSession(sessionID: closingSessionID)
        }
    }

    /// 再接続可能なら同一セッションへ。`closed` や失敗時は新規セッション。
    private func openConnection() async throws -> VoiceStreamConnection {
        // 明示 close の POST と新規作成の順序を保つ（先に作ると 409）。
        if let pendingSessionClose {
            _ = await pendingSessionClose.value
            self.pendingSessionClose = nil
        }
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
        // セッション単位のフラグ。新しいセッションでは audio モードを引き継がない。
        assistantAudioMode = false
        upstreamNeedsContinuousAudio = false
    }
}
