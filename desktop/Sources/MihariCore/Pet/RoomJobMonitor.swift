import Foundation
import os

/// ペットメニューに出す仕事の状態。
public enum RoomJobStatus: String, Sendable, Equatable, CaseIterable {
    case queued
    case running
    case done
    case failed
    case cancelled

    /// 画面表示用の日本語ラベル。
    public var label: String {
        switch self {
        case .queued: return "待ち"
        case .running: return "作業中"
        case .done: return "完了"
        case .failed: return "失敗"
        case .cancelled: return "中断"
        }
    }
}

/// 監視している仕事 1 件分の見た目。
public struct RoomJobTrackedJob: Equatable, Sendable, Identifiable {
    public let jobID: String
    public let title: String
    public let status: RoomJobStatus
    /// 最後に見た位相。未知のままだと `nil`。
    public let phase: RoomJobPhase?
    /// 最後のイベント本文。無ければ `nil`。
    public let latestText: String?
    /// 直近で取れた成果物。
    public let artifacts: [RoomArtifact]
    /// 一時デプロイ。
    public let tempDeploys: [RoomTempDeploy]
    /// 配信が止まっている理由。正常なら `nil`。
    public let lastError: String?
    /// 直近の中断・承認・公開などの操作の失敗。正常なら `nil`。
    public let operationError: String?
    /// 直近で取れた記憶の候補。承認待ちの表示と件数に使う。
    public let memories: [RoomMemoryCandidate]
    /// 記憶の一覧を取りに行くときの失敗。正常なら `nil`。
    public let memoryError: String?
    /// 直近の位相変化でペットへ与える指示。テストからの観測点にもなる。
    public let directive: RoomPhaseDirective?
    /// 承認待ちの件数。
    public var pendingMemoryCount: Int { memories.filter(\.isPending).count }
    /// 監視中に見た出来事の履歴（新しい順）。詳細パネルの「履歴」に出す。
    public var history: [RoomJobHistoryEntry] = []

    public var id: String { jobID }

    public init(
        jobID: String,
        title: String,
        status: RoomJobStatus,
        phase: RoomJobPhase? = nil,
        latestText: String? = nil,
        artifacts: [RoomArtifact] = [],
        tempDeploys: [RoomTempDeploy] = [],
        lastError: String? = nil,
        operationError: String? = nil,
        memories: [RoomMemoryCandidate] = [],
        memoryError: String? = nil,
        directive: RoomPhaseDirective? = nil,
        history: [RoomJobHistoryEntry] = []
    ) {
        self.jobID = jobID
        self.title = title
        self.status = status
        self.phase = phase
        self.latestText = latestText
        self.artifacts = artifacts
        self.tempDeploys = tempDeploys
        self.lastError = lastError
        self.operationError = operationError
        self.memories = memories
        self.memoryError = memoryError
        self.directive = directive
        self.history = history
    }

    /// メニューに出す要約。
    public var summary: RoomJobSummary {
        RoomJobSummary(
            jobID: jobID,
            title: title,
            status: status,
            phase: phase,
            latestText: latestText,
            artifacts: artifacts,
            tempDeploys: tempDeploys,
            lastError: lastError,
            operationError: operationError,
            memoryCandidates: memories
        )
    }
}

/// 部屋の仕事の進捗を購読し、ペットへの指示に落とす。
///
/// - 依頼が通ったら `attach(jobID:title:)`、起動時や繋ぎ直しでは `resume()` が
///   `/jobs/running` を引いて走っている仕事を拾う。
/// - SSE はデーモン(bridge)とは別のセッションで開くので、そちらの流れを奪わない。
/// - 切れたら指数バックオフ(上限 30 秒)で張り直し、`Last-Event-ID` で再開点を伝える。
/// - 再送されたイベントは ID で重複排除し、位相をまたぐ speech だけを喋らせる。
///
/// 喋るのはペット側の仕事なので、この型は「喋ってほしい文」を `directive.line` に載せて
/// `onDirective` で渡すだけに留める。
@MainActor
public final class RoomJobMonitor: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "room")

    /// 再送の重複排除に覚えておくイベント ID の上限。
    static let seenIDLimit = 512
    /// 重複排除の集合が上限を超えたとき、残しておく件数。
    static let seenIDTrim = 256
    /// 詳細の「履歴」に残す出来事の上限。
    static let historyLimit = 100
    /// バックオフの上限(秒)。これ以上は長くしない。
    nonisolated static let backoffCapSeconds: TimeInterval = 30
    /// バックオフの起点(秒)。
    nonisolated static let backoffBaseSeconds: TimeInterval = 1

    /// いま監視している仕事。直近に動いた順。
    @Published public private(set) var jobs: [RoomJobTrackedJob] = []
    /// 仕事の一覧を取りに行くときの失敗。配信自体のエラーは各仕事の `lastError` に出る。
    @Published public private(set) var lastError: String?

    /// 位相の変化をペットへ伝える口。`AppCoordinator` が `begin()` で差し込む。
    public var onDirective: (@MainActor (RoomJobTrackedJob) -> Void)?

    private let access: any RoomAccess
    private var cursorStore: RoomJobCursorStoring
    private var states: [String: JobState] = [:]

    /// 1 件の仕事について監視が持つ状態。
    private struct JobState {
        var title: String?
        var task: Task<Void, Never>?
        var seenIDs: Set<String> = []
        var latestEventID: String?
        var lastPhase: RoomJobPhase?
        var handledCount = 0
        var seeded = false
        var status: RoomJobStatus = .queued
        var latestText: String?
        var artifacts: [RoomArtifact] = []
        var tempDeploys: [RoomTempDeploy] = []
        var memories: [RoomMemoryCandidate] = []
        var memoryError: String?
        var lastError: String?
        var operationError: String?
        var lastActivityAt = Date.distantPast
        var lastDirective: RoomPhaseDirective?
        var history: [RoomJobHistoryEntry] = []
    }

    public init(access: any RoomAccess, cursorStore: RoomJobCursorStoring) {
        self.access = access
        self.cursorStore = cursorStore
    }

    // MARK: - 購読の開始

    /// 依頼が通った仕事を監視し始める。最初のイベントから読むので、開始の一言も喋る。
    public func attach(jobID: String, title: String?) {
        guard !jobID.isEmpty else { return }
        var state = states[jobID] ?? JobState()
        state.title = state.title ?? title ?? jobID
        state.lastError = nil
        states[jobID] = state
        cursorStore.lastJobID = jobID
        startStream(jobID: jobID)
        // タイトルと成果物を取り直す。取れなくても購読は続く。
        Task { [weak self] in
            await self?.refreshArtifacts(jobID: jobID)
        }
        publish()
    }

    /// 起動時・繋ぎ直しに `/jobs/running` を引き、走っている仕事を拾う。
    ///
    /// すでに走っている仕事に付け直すときは、最新イベントの位相と ID を「すでに見た」状態に
    /// してから購読する。過去の配信を全部喋り直さないため。`/jobs/running` は走っている
    /// 仕事だけを返すので、カーソルが残っている仕事(待ち・完了・失敗)は詳細から拾い直して
    /// 状態と成果物と記憶の候補を見せ続ける。
    public func resume() async {
        do {
            let running = try await access.listRunning()
            lastError = nil
            // 見えなくなった仕事は監視をやめる。ただしカーソルが残っている仕事は
            // 下で詳細から拾い直すので、ここでは走っている仕事以外をいったん外すだけ。
            let liveIDs = Set(running.map(\.jobID))
            for jobID in states.keys where !liveIDs.contains(jobID) {
                stop(jobID: jobID)
            }
            // 新しい / 見失っていた仕事から付け直す。
            for detail in running {
                attach(detail: detail)
            }
            // カーソルが残っている仕事は、走っていなくても詳細から拾い直す。
            // 待ち・完了・失敗の仕事の成果物と記憶の候補を開くため。
            var restoreIDs = Set(cursorStore.knownJobIDs())
            if let lastID = cursorStore.lastJobID { restoreIDs.insert(lastID) }
            for jobID in restoreIDs.sorted() where !liveIDs.contains(jobID) {
                guard !states.keys.contains(jobID) else { continue }
                guard let detail = try? await access.detail(jobID: jobID) else { continue }
                attach(detail: detail)
            }
        } catch {
            lastError = describe(error)
        }
    }

    /// 発見した仕事の詳細から監視し始める。
    public func attach(detail: RoomJobDetail) {
        guard !detail.jobID.isEmpty else { return }
        var state = states[detail.jobID] ?? JobState()
        state.title = detail.title ?? detail.jobID
        state.artifacts = detail.artifacts
        state.tempDeploys = detail.tempDeploys
        state.status = Self.status(fromRaw: detail.status) ?? state.status
        if let latest = detail.latestEvent {
            state.seeded = true
            state.handledCount = 1
            state.lastPhase = latest.phase
            state.latestText = latest.text
            state.latestEventID = latest.id
            state.lastActivityAt = latest.createdAt ?? .now
            state.seenIDs.insert(latest.id)
            // ジョブ状態（詳細の status）を正とする。記憶の決定・候補（waiting）が
            // 最新でも「作業中」へ巻き戻さない。
            state.status =
                Self.status(fromRaw: detail.status) ?? Self.status(after: latest)
            cursorStore.setCursor(latest.id, for: detail.jobID)
        }
        states[detail.jobID] = state
        cursorStore.lastJobID = detail.jobID
        startStream(jobID: detail.jobID)
        // 記憶の候補は別口なので、詳細と一緒に引き直す。取れなくても購読は続く。
        Task { [weak self] in
            await self?.refreshMemory(jobID: detail.jobID)
        }
        publish()
    }

    /// いま追っている仕事を切り替える。古い仕事の配信は止め、橋(bridge)の購読とは無関係。
    ///
    /// 付け替えたあとは新しい仕事だけを追う。SSE は部屋専用の別セッションで開くので、
    /// デーモン側の流れを奪わない。
    public func focus(jobID: String, title: String?) {
        for known in Array(states.keys) where known != jobID {
            stop(jobID: known)
        }
        attach(jobID: jobID, title: title)
    }

    /// 監視をやめる。アプリ終了時にもここを通る。
    public func stop(jobID: String) {
        states[jobID]?.task?.cancel()
        states[jobID]?.task = nil
        states[jobID] = nil
        publish()
    }

    /// 全部やめる。
    public func stopAll() {
        for state in states.values {
            state.task?.cancel()
        }
        states = [:]
        publish()
    }

    // MARK: - 操作

    /// 仕事へ追記する。戻り値は依頼と同じ `Create` 契約の応答。
    @discardableResult
    public func followup(jobID: String, body: String, requestedBy: String? = nil) async throws -> JobRequestResponse {
        let response: JobRequestResponse
        do {
            response = try await access.followup(jobID: jobID, body: body, requestedBy: requestedBy)
        } catch {
            recordOperationError(jobID, error)
            throw error
        }
        if var state = states[jobID] {
            state.latestText = "追記: \(body)"
            state.lastActivityAt = .now
            state.lastError = nil
            state.operationError = nil
            // ジョブ状態を正とする。追記で待ちに戻ったら、イベントを待たずに表示を切り替える。
            if let raw = response.status, let parsed = Self.status(fromRaw: raw) {
                state.status = parsed
                if let phase = Self.phase(forStatus: parsed) {
                    state.lastPhase = phase
                }
            }
            states[jobID] = state
            publish()
        }
        // 終端で部屋が stream を閉じたあとでも、追記したら続きを追えるよう開き直す。
        startStream(jobID: jobID)
        return response
    }

    /// 仕事を中断する。戻り値は依頼と同じ `Create` 契約の応答。
    @discardableResult
    public func cancel(jobID: String) async throws -> JobRequestResponse {
        let response: JobRequestResponse
        do {
            response = try await access.cancel(jobID: jobID)
        } catch {
            recordOperationError(jobID, error)
            throw error
        }
        if var state = states[jobID] {
            state.status = Self.status(fromRaw: response.status) ?? .cancelled
            state.lastPhase = .waiting
            state.latestText = "中断した"
            state.latestEventID = nil
            state.lastActivityAt = .now
            state.lastError = nil
            state.operationError = nil
            state.lastDirective = RoomPhaseDirective(fixedAnimation: .waiting)
            states[jobID] = state
            publish()
            if let tracked = trackedJob(jobID) {
                onDirective?(tracked)
            }
        }
        return response
    }

    /// 成果物を最新に引き直す。完了・失敗で配信が止まったあとに呼ぶ。
    /// ジョブ状態（詳細の `status`）と最新イベント・成果物・記憶の候補を引き直す。
    public func refreshArtifacts(jobID: String) async {
        do {
            let detail = try await access.detail(jobID: jobID)
            if var state = states[jobID] {
                state.artifacts = detail.artifacts
                state.tempDeploys = detail.tempDeploys
                state.title = state.title ?? detail.title ?? jobID
                // ジョブ状態を正とする。記憶の決定・候補（waiting）が最新でも
                // 「作業中」へ巻き戻さない。
                let raw = detail.status.flatMap(Self.status(fromRaw:))
                if let latest = detail.latestEvent {
                    let currentID = state.latestEventID
                    if currentID == nil || Self.isNewerEventID(latest.id, than: currentID) {
                        if let raw { state.status = raw }
                        state.lastPhase = latest.phase ?? state.lastPhase
                        if !latest.text.isEmpty { state.latestText = latest.text }
                        state.latestEventID = latest.id
                        state.seenIDs.insert(latest.id)
                        cursorStore.setCursor(latest.id, for: jobID)
                    } else if let raw {
                        // 配信が詳細より先まで進んでいるときも、状態だけは正へ寄せる。
                        state.status = raw
                    }
                } else if let raw {
                    state.status = raw
                }
                states[jobID] = state
                publish()
            }
        } catch {
            if Self.isJobMissing(error) {
                // 部屋から消えた仕事は追い続けない。詳細は「追っていない」表示になる。
                stop(jobID: jobID)
            } else {
                setStreamError(jobID, message: describe(error))
            }
        }
        await refreshMemory(jobID: jobID)
    }

    /// 記憶の候補を最新に引き直す。詳細の取得・候補イベント・決定後に呼ぶ。
    public func refreshMemory(jobID: String) async {
        do {
            let candidates = try await access.listMemory(jobID: jobID)
            if var state = states[jobID] {
                state.memories = candidates
                state.memoryError = nil
                states[jobID] = state
                publish()
            }
        } catch {
            if var state = states[jobID] {
                state.memoryError = describe(error)
                states[jobID] = state
                publish()
            }
        }
    }

    /// 記憶の候補を承認する。API が成功してから一覧を引き直すまで約束しない。
    public func approveMemory(jobID: String, candidateID: String) async throws {
        do {
            try await access.approveMemory(jobID: jobID, candidateID: candidateID)
        } catch {
            recordOperationError(jobID, error)
            throw error
        }
        clearOperationError(jobID)
        await refreshMemory(jobID: jobID)
    }

    /// 記憶の候補を却下する。API が成功してから一覧を引き直すまで約束しない。
    public func rejectMemory(jobID: String, candidateID: String) async throws {
        do {
            try await access.rejectMemory(jobID: jobID, candidateID: candidateID)
        } catch {
            recordOperationError(jobID, error)
            throw error
        }
        clearOperationError(jobID)
        await refreshMemory(jobID: jobID)
    }

    /// 旧バージョンを新しい token として再公開する。成功したら成果物を引き直す。
    @discardableResult
    public func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        let manifest: RoomArtifact
        do {
            manifest = try await access.rollbackArtifact(jobID: jobID, version: version)
        } catch {
            recordOperationError(jobID, error)
            throw error
        }
        clearOperationError(jobID)
        await refreshArtifacts(jobID: jobID)
        return manifest
    }

    /// 版を公開する（共有 URL を発行）。成功したら成果物を引き直す。
    @discardableResult
    public func publishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        let manifest = try await access.publishArtifact(jobID: jobID, version: version)
        await refreshArtifacts(jobID: jobID)
        return manifest
    }

    /// 版を非公開に戻す（発行済み URL を無効化）。成功したら成果物を引き直す。
    @discardableResult
    public func unpublishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        let manifest = try await access.unpublishArtifact(jobID: jobID, version: version)
        await refreshArtifacts(jobID: jobID)
        return manifest
    }

    /// その版の作業ファイルを作業フォルダへ復元する。
    /// 実行中の仕事は部屋側が 409 で断る。成功したら成果物を引き直す。
    public func restoreArtifact(jobID: String, version: String) async throws {
        try await access.restoreArtifact(jobID: jobID, version: version)
        await refreshArtifacts(jobID: jobID)
    }

    // MARK: - 監視の中身

    private func startStream(jobID: String) {
        guard states[jobID]?.task == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStream(jobID: jobID)
        }
        states[jobID]?.task = task
    }

    /// 部屋へ渡すカーソル。数値文字列だけを通し、旧式(`ev-*`)や壊れた値は `nil` にする。
    ///
    /// 部屋側は解釈できない `Last-Event-ID` を 0(最初から)とみなして全部返してくる。
    /// 旧式のまま送ると再送の嵐になるので、送る前に落とす。`nil` でも最初からは
    /// 変わらないが、呼び出し側は詳細の最新イベントで種付けして喋り直しを抑える。
    nonisolated static func normalizeCursor(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return nil }
        return raw
    }

    private func runStream(jobID: String) async {
        // 旧式のカーソルが残っていたら、詳細の最新イベントで種付けしてから開く。
        // そのまま開くと部屋が最初から全部返し、過去を喋り直してしまう。
        if cursorStore.cursor(for: jobID) != nil,
            Self.normalizeCursor(cursorStore.cursor(for: jobID)) == nil
        {
            await seedFromDetail(jobID: jobID)
        }
        var attempt = 0
        while !Task.isCancelled {
            let cursor = Self.normalizeCursor(cursorStore.cursor(for: jobID))
            do {
                let (bytes, status) = try await access.openEventStream(jobID: jobID, lastEventID: cursor)
                // 4xx は張り直しても直らないことが多いので、その仕事の配信を諦めて理由を残す。
                // 408 / 429 は時間を置けば直るので張り直す。
                if (400..<500).contains(status), status != 408, status != 429 {
                    setStreamError(jobID, message: "部屋が配信を拒否した (\(status))")
                    return
                }
                guard (200..<300).contains(status) else {
                    try? await Task.sleep(for: Self.backoffDelay(attempt: attempt))
                    attempt += 1
                    continue
                }
                // つながった。バックオフを忘れて、以後は張り直すたびに最初から数える。
                attempt = 0
                var parser = ServerSentEventParser()
                var lines = LineAccumulator()
                for try await byte in bytes {
                    guard let line = lines.consume(byte: byte) else { continue }
                    guard let frame = parser.consume(line: line) else { continue }
                    handle(frame, jobID: jobID)
                }
                // サーバー側が切った。少し待って張り直す。
                try? await Task.sleep(for: Self.backoffDelay(attempt: attempt))
            } catch {
                guard !Task.isCancelled else { return }
                attempt += 1
                try? await Task.sleep(for: Self.backoffDelay(attempt: attempt))
            }
        }
    }

    private func handle(_ frame: ServerSentEventParser.Frame, jobID: String) {
        guard let data = frame.data.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(RoomEvent.self, from: data) else {
            Self.logger.error("部屋のイベントを解釈できない: \(frame.data, privacy: .public)")
            return
        }
        // 同じ部屋でも別の仕事のイベントが混ざって流れてきたら無視する。
        guard event.jobID.isEmpty || event.jobID == jobID else { return }
        apply(event, jobID: jobID)
    }

    private func apply(_ event: RoomEvent, jobID: String) {
        guard var state = states[jobID] else { return }
        // Last-Event-ID の再送などで同じイベントがもう一度来ても、二度は扱わない。
        guard state.seenIDs.insert(event.id).inserted else { return }
        if state.seenIDs.count > Self.seenIDLimit {
            state.seenIDs = Set(state.seenIDs.suffix(Self.seenIDTrim))
        }
        state.latestEventID = event.id
        state.lastActivityAt = .now
        state.latestText = event.text
        cursorStore.setCursor(event.id, for: jobID)

        let isFirst = state.handledCount == 0
        let directive = Self.makeDirective(
            event: event,
            previousPhase: state.lastPhase,
            isFirstEvent: isFirst,
            wasSeeded: state.seeded
        )
        // 未知の位相は前のまま保つ。
        state.lastPhase = event.phase ?? state.lastPhase
        // 終わった仕事は後の雑音で巻き戻さない（失敗を見落とさない、
        // 記憶の決定・候補で「作業中」に戻さない）。ただし追記で本当に
        // 再実行が始まったとき（queued）だけは終端を抜けて「待ち」へ戻す。
        state.status = Self.advanceStatus(from: state.status, after: event)
        state.handledCount += 1
        state.lastDirective = directive
        // 履歴は新しい順に保ち、上限で古いものを落とす。
        state.history.insert(
            RoomJobHistoryEntry(phase: event.phase, kind: event.kind, text: event.text),
            at: 0
        )
        if state.history.count > Self.historyLimit {
            state.history = Array(state.history.prefix(Self.historyLimit))
        }
        states[jobID] = state

        publish()
        if let tracked = trackedJob(jobID) {
            onDirective?(tracked)
        }

        // 終わったあとで成果物を取り直す。配信はフォローアップのために開いたままにする。
        // 部屋は終端のあと hold して stream を閉じるので、張り直しは runStream が担う。
        if event.phase?.isTerminal == true {
            Task { [weak self] in
                await self?.refreshArtifacts(jobID: jobID)
            }
        }
        // 記憶の候補が出たら一覧を引き直す。喋らない。
        if event.kind == .memoryCandidate {
            Task { [weak self] in
                await self?.refreshMemory(jobID: jobID)
            }
        }
        if event.kind == .tempDeploy {
            Task { [weak self] in
                await self?.refreshArtifacts(jobID: jobID)
            }
        }
    }

    /// 詳細の最新イベントで種付けする。未知のカーソルで過去を喋り直さないため。
    private func seedFromDetail(jobID: String) async {
        guard var state = states[jobID] else { return }
        guard let detail = try? await access.detail(jobID: jobID) else { return }
        if let latest = detail.latestEvent {
            state.seeded = true
            state.handledCount = max(state.handledCount, 1)
            state.lastPhase = latest.phase ?? state.lastPhase
            state.latestText = state.latestText ?? latest.text
            state.latestEventID = latest.id
            state.seenIDs.insert(latest.id)
            cursorStore.setCursor(latest.id, for: jobID)
            states[jobID] = state
        } else {
            cursorStore.setCursor(nil, for: jobID)
        }
    }

    private func setStreamError(_ jobID: String, message: String) {
        if var state = states[jobID] {
            state.lastError = message
            states[jobID] = state
            publish()
        }
    }

    /// 中断・承認・公開などの操作の失敗を、その仕事の表示へ残して伝える。
    /// 部屋から仕事が消えていたら（404）監視もやめる。
    private func recordOperationError(_ jobID: String, _ error: Error) {
        if var state = states[jobID] {
            state.operationError = describe(error)
            states[jobID] = state
            publish()
        }
        if Self.isJobMissing(error) {
            stop(jobID: jobID)
        }
    }

    /// 直近の操作の失敗表示を消す。
    private func clearOperationError(_ jobID: String) {
        if var state = states[jobID], state.operationError != nil {
            state.operationError = nil
            states[jobID] = state
            publish()
        }
    }

    /// 部屋に仕事が無い（404）失敗か。対象が消えていたら追跡もやめる目印。
    nonisolated static func isJobMissing(_ error: Error) -> Bool {
        guard case RoomError.requestFailed(let status, _) = error else { return false }
        return status == 404
    }

    /// 候補のイベント ID が、すでに見た ID より新しいか（同一は同じイベントの再取得なので新しい扱い）。
    /// 部屋の ID は整数連番なので数値で比べる。文字列比較は桁で狂う。
    nonisolated static func isNewerEventID(_ candidate: String, than seen: String?) -> Bool {
        guard let seen else { return true }
        if let a = Int(candidate), let b = Int(seen) {
            return a >= b
        }
        return candidate == seen
    }

    /// バックオフの待ち時間。`attempt` が大きくなるほど長く、上限で頭打ちになる。
    nonisolated static func backoffDelay(attempt: Int) -> Duration {
        let exponent = Double(min(max(attempt, 0), 5))
        let raw = backoffBaseSeconds * pow(2.0, exponent)
        let jitter = Double.random(in: 0..<0.3) * raw
        return .seconds(min(raw + jitter, backoffCapSeconds))
    }

    private func publish() {
        jobs =
            states
            .sorted { $0.value.lastActivityAt > $1.value.lastActivityAt }
            .map { jobID, state in
                RoomJobTrackedJob(
                    jobID: jobID,
                    title: state.title ?? jobID,
                    status: state.status,
                    phase: state.lastPhase,
                    latestText: state.latestText,
                    artifacts: state.artifacts,
                    tempDeploys: state.tempDeploys,
                    lastError: state.lastError,
                    operationError: state.operationError,
                    memories: state.memories,
                    memoryError: state.memoryError,
                    directive: state.lastDirective,
                    history: state.history
                )
            }
    }

    private func trackedJob(_ jobID: String) -> RoomJobTrackedJob? {
        states[jobID].map { state in
            RoomJobTrackedJob(
                jobID: jobID,
                title: state.title ?? jobID,
                status: state.status,
                phase: state.lastPhase,
                latestText: state.latestText,
                artifacts: state.artifacts,
                tempDeploys: state.tempDeploys,
                lastError: state.lastError,
                operationError: state.operationError,
                memories: state.memories,
                memoryError: state.memoryError,
                directive: state.lastDirective,
                history: state.history
            )
        }
    }

    /// その仕事をいま監視しているか。詳細を開く前に拾い直す判断に使う。
    public func isTracking(_ jobID: String) -> Bool {
        states[jobID] != nil
    }

    private func describe(_ error: Error) -> String {
        (error as? RoomError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 指示の決定(テストから直接見る)

    /// イベント 1 件をペットへの指示に落とす。
    ///
    /// - 位相 → 固着アニメーション: queued/waiting は待つ、researching/downloading/deploying
    ///   は集中、building/verifying は確認、done は 1 回だけのお祝い(waving / jumping)、
    ///   failed は落ち込む。
    /// - 喋るのは `kind == speech` だけ。位相の変わり目・始まり・終わり(done/failed/cancelled)
    ///   に限る。summary・log・file・memory_candidate・temp_deploy は一切喋らない。
    nonisolated static func makeDirective(
        event: RoomEvent,
        previousPhase: RoomJobPhase?,
        isFirstEvent: Bool,
        wasSeeded: Bool
    ) -> RoomPhaseDirective {
        let phase = event.phase
        let phaseChanged = phase != nil && phase != previousPhase
        let isEnd = phase?.isTerminal == true || event.kind == .cancelled

        var fixedAnimation: PetAnimation?
        var playOnce: PetAnimation?
        switch phase {
        case .done:
            // 完了は固定を解いて、1 回だけお祝いする。
            playOnce = Bool.random() ? .waving : .jumping
        case .failed:
            fixedAnimation = .failed
        default:
            fixedAnimation = phase?.fixedAnimation
        }
        if event.kind == .cancelled {
            // 中断は「待ち」の姿で止める。
            fixedAnimation = .waiting
        }

        let shouldSpeak =
            event.kind == .speech
            && (isEnd || phaseChanged || (isFirstEvent && !wasSeeded))

        return RoomPhaseDirective(
            fixedAnimation: fixedAnimation,
            playOnce: playOnce,
            line: shouldSpeak ? event.text : nil
        )
    }

    /// ジョブ状態から位相の見た目を決める。`running` はイベント任せにする。
    nonisolated static func phase(forStatus status: RoomJobStatus) -> RoomJobPhase? {
        switch status {
        case .queued: return .queued
        case .done: return .done
        case .failed: return .failed
        case .cancelled: return .waiting
        case .running: return nil
        }
    }

    /// イベントから仕事の状態を決める。
    nonisolated static func status(after event: RoomEvent) -> RoomJobStatus {
        if event.kind == .cancelled { return .cancelled }
        switch event.phase {
        case .queued: return .queued
        case .done: return .done
        case .failed: return .failed
        case nil, .waiting, .researching, .downloading, .building, .deploying, .verifying:
            return .running
        }
    }

    /// 現在の状態とイベント 1 件から次の状態を決める。
    ///
    /// 終端（完了・失敗・中断）は、本当に再実行が始まったとき（queued）だけ抜けられる。
    /// 記憶の決定・候補のような waiting イベントや、中断後に残る worker の進捗では
    /// 巻き戻さない。ジョブ状態（詳細の status）を正とする。
    nonisolated static func advanceStatus(from current: RoomJobStatus, after event: RoomEvent) -> RoomJobStatus {
        let next = status(after: event)
        switch current {
        case .queued, .running:
            return next
        case .done, .failed, .cancelled:
            if event.kind == .cancelled {
                return .cancelled
            }
            if event.phase == .queued {
                return .queued
            }
            if next == .done || next == .failed || next == .cancelled {
                return next
            }
            // waiting や working のイベントでは終端のまま保つ。
            return current
        }
    }

    /// 詳細の `status` 文字列から状態を決める。読めなければ `nil`。
    nonisolated static func status(fromRaw raw: String?) -> RoomJobStatus? {
        guard let raw else { return nil }
        return RoomJobStatus(rawValue: raw)
    }
}
