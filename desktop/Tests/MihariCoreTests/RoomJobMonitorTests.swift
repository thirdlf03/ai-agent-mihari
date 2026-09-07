import Foundation
import Testing

@testable import MihariCore

/// 部屋の進捗を購読する `RoomJobMonitor` の、位相の写し・喋りの絞り・重複排除・再開を確かめる。
@Suite("部屋の進捗の監視")
@MainActor
struct RoomJobMonitorTests {

    /// 通信をスタブに差し替えた部屋の口。開くたびに「次のストリーム」を返す。
    @MainActor
    private final class StubRoomAccess: RoomAccess {
        var listRunningResults: [RoomJobDetail] = []
        private(set) var listRunningCalls = 0
        var listJobsResults: [RoomJobDetail] = []
        private(set) var listJobsCalls = 0
        var detailResults: [String: RoomJobDetail] = [:]
        private(set) var followupCalls: [String] = []
        private(set) var cancelCalls: [String] = []
        /// 追記の応答。設定が無ければ「作業中」を返す。
        var followupResults: [String: JobRequestResponse] = [:]
        /// 追記・中断・決定・ロールバックが投げるエラー。設定しておくと API より先に見る。
        var operationError: (any Error)?
        /// SSE を開いた順の仕事 ID。
        private(set) var openedJobIDs: [String] = []
        /// SSE を開いた順のカーソル。
        private(set) var openedCursors: [String?] = []
        /// 開く回ごとに返す(バイト列, 状態)。回数が足りなければ最後の値を使う。
        var streamsForOpen: [(RoomEventByteStream, Int)] = []
        /// 開くたびに投げるエラー。設定しておくとストリームより先に見る。
        var openError: (any Error)?

        func listRunning() async throws -> [RoomJobDetail] {
            listRunningCalls += 1
            return listRunningResults
        }

        func listJobs() async throws -> [RoomJobDetail] {
            listJobsCalls += 1
            return listJobsResults
        }

        func detail(jobID: String) async throws -> RoomJobDetail {
            detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }

        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            followupCalls.append(jobID)
            if let operationError { throw operationError }
            return followupResults[jobID] ?? JobRequestResponse(jobID: jobID, threadID: nil, status: "running")
        }

        func cancel(jobID: String) async throws -> JobRequestResponse {
            cancelCalls.append(jobID)
            if let operationError { throw operationError }
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "cancelled")
        }

        var memoryResults: [String: [RoomMemoryCandidate]] = [:]
        private(set) var approveCalls: [(String, String)] = []
        private(set) var rejectCalls: [(String, String)] = []

        func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] {
            memoryResults[jobID] ?? []
        }

        func approveMemory(jobID: String, candidateID: String) async throws {
            if let operationError { throw operationError }
            approveCalls.append((jobID, candidateID))
        }

        func rejectMemory(jobID: String, candidateID: String) async throws {
            if let operationError { throw operationError }
            rejectCalls.append((jobID, candidateID))
        }

        private(set) var rollbackCalls: [(String, String)] = []
        private(set) var publishCalls: [(String, String)] = []
        private(set) var unpublishCalls: [(String, String)] = []
        private(set) var restoreCalls: [(String, String)] = []

        func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            rollbackCalls.append((jobID, version))
            return RoomArtifact(artifactID: "rolled-\(version)", version: version)
        }

        func publishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            publishCalls.append((jobID, version))
            return RoomArtifact(
                artifactID: "art-\(jobID)-v\(version)",
                version: version,
                previewURL: URL(string: "https://preview.example.test/\(version)tok/")!,
                visibility: "public"
            )
        }

        func unpublishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            unpublishCalls.append((jobID, version))
            return RoomArtifact(
                artifactID: "art-\(jobID)-v\(version)",
                version: version,
                previewURL: nil,
                visibility: "private"
            )
        }

        func restoreArtifact(jobID: String, version: String) async throws {
            restoreCalls.append((jobID, version))
        }

        @MainActor
        func openEventStream(jobID: String, lastEventID: String?) async throws -> (RoomEventByteStream, Int) {
            openedJobIDs.append(jobID)
            openedCursors.append(lastEventID)
            if let openError { throw openError }
            guard !streamsForOpen.isEmpty else { return (Self.emptyStream(), 200) }
            let index = min(openedCursors.count - 1, streamsForOpen.count - 1)
            return streamsForOpen[index]
        }

        static func emptyStream() -> RoomEventByteStream {
            RoomEventByteStream(AsyncStream<UInt8> { $0.finish() })
        }
    }

    /// 実行のたびに空の UserDefaults を使い、テスト同士で共有しないようにする。
    private func makeStore() -> UserDefaultsRoomJobCursorStore {
        let suiteName = "mihari.test.roomMonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    /// イベント 1 件の JSON 文字列。位相や種類は `nil` なら JSON に載せない。
    private func eventJSON(
        id: String,
        jobID: String,
        phase: String?,
        kind: String?,
        text: String,
        progress: Double? = nil
    ) -> String {
        var fields: [String] = [
            "\"id\":\"\(id)\"",
            "\"job_id\":\"\(jobID)\"",
            "\"text\":\"\(text)\"",
        ]
        if let phase { fields.append("\"phase\":\"\(phase)\"") }
        if let kind { fields.append("\"kind\":\"\(kind)\"") }
        if let progress { fields.append("\"progress\":\(progress)") }
        return "{\(fields.joined(separator: ","))}"
    }

    /// SSE のフレーム列のバイト列を作る。
    private func sse(frames: [String]) -> RoomEventByteStream {
        let raw = frames.joined().data(using: .utf8)!
        let stream = AsyncStream<UInt8> { continuation in
            for byte in raw {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        return RoomEventByteStream(stream)
    }

    private func frame(_ json: String) -> String {
        "data: \(json)\n\n"
    }

    /// 条件が満たされるまで少しずつ待つ。
    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("待っても条件を満たさなかった: \(what)")
    }

    // MARK: - 位相の写し

    @Test("位相をペットの動きへ写す(queued/waiting → waiting)")
    func mapsWaitingPhases() {
        let directive = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .queued, kind: .speech, text: "始める"),
            previousPhase: nil,
            isFirstEvent: true,
            wasSeeded: false
        )
        #expect(directive.fixedAnimation == .waiting)
    }

    @Test("位相をペットの動きへ写す(researching/downloading/deploying → running)")
    func mapsRunningPhases() {
        for phase in [RoomJobPhase.researching, .downloading, .deploying] {
            let directive = RoomJobMonitor.makeDirective(
                event: RoomEvent(id: "1", jobID: "abc", phase: phase, kind: .speech, text: "やってる"),
                previousPhase: nil,
                isFirstEvent: false,
                wasSeeded: false
            )
            #expect(directive.fixedAnimation == .running, "phase=\(phase)")
        }
    }

    @Test("位相をペットの動きへ写す(building/verifying → review)")
    func mapsReviewPhases() {
        for phase in [RoomJobPhase.building, .verifying] {
            let directive = RoomJobMonitor.makeDirective(
                event: RoomEvent(id: "1", jobID: "abc", phase: phase, kind: .speech, text: "確認"),
                previousPhase: nil,
                isFirstEvent: false,
                wasSeeded: false
            )
            #expect(directive.fixedAnimation == .review, "phase=\(phase)")
        }
    }

    @Test("done は 1 回だけのお祝い(waving か jumping)")
    func doneCelebratesOnce() {
        let directive = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .done, kind: .speech, text: "完了した"),
            previousPhase: .building,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(directive.fixedAnimation == nil)
        #expect(directive.playOnce == .waving || directive.playOnce == .jumping)
        #expect(directive.line == "完了した")
    }

    @Test("failed は落ち込んだ姿で固定する")
    func failedIsFixedBehind() {
        let directive = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .failed, kind: .speech, text: "失敗した"),
            previousPhase: .verifying,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(directive.fixedAnimation == .failed)
        #expect(directive.line == "失敗した")
    }

    // MARK: - 喋りの絞り

    @Test("speech は位相の変わり目にだけ喋る")
    func speaksOnlyOnPhaseChange() {
        // 同じ位相の speech は喋らない。
        let samePhase = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .downloading, kind: .speech, text: "続報"),
            previousPhase: .downloading,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(samePhase.line == nil)

        // 位相が変わった speech は喋る。
        let changed = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "2", jobID: "abc", phase: .building, kind: .speech, text: "組み立てた"),
            previousPhase: .downloading,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(changed.line == "組み立てた")
    }

    @Test("最初のイベントは位相が同じでも喋る(開始の一言)")
    func speaksFirstEvent() {
        let first = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .researching, kind: .speech, text: "調べ始めた"),
            previousPhase: nil,
            isFirstEvent: true,
            wasSeeded: false
        )
        #expect(first.line == "調べ始めた")
    }

    @Test("検出済みの仕事に付け直したときの最初の一括配信は喋らない")
    func seededReplayIsSilent() {
        let seeded = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "10", jobID: "abc", phase: .downloading, kind: .speech, text: "取得中だよ"),
            previousPhase: .downloading,
            isFirstEvent: true,
            wasSeeded: true
        )
        #expect(seeded.line == nil)
    }

    @Test("summary は終わりでも一切喋らない")
    func summariesNeverSpeak() {
        let summary = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .done, kind: .summary, text: "まとめると…"),
            previousPhase: .building,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(summary.line == nil)
        #expect(summary.playOnce == .waving || summary.playOnce == .jumping)
    }

    @Test("cancelled は喋らず、待ちの姿で止める")
    func cancellationIsSilentAndWaits() {
        let directive = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "1", jobID: "abc", phase: .waiting, kind: .cancelled, text: "止めた"),
            previousPhase: .researching,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(directive.line == nil)
        #expect(directive.fixedAnimation == .waiting)
        #expect(directive.playOnce == nil)
    }

    @Test("log と file も喋らない")
    func logsAndFilesNeverSpeak() {
        for kind in [RoomEventKind.log, .file] {
            let directive = RoomJobMonitor.makeDirective(
                event: RoomEvent(id: "1", jobID: "abc", phase: .downloading, kind: kind, text: "取れた"),
                previousPhase: .queued,
                isFirstEvent: false,
                wasSeeded: false
            )
            #expect(directive.line == nil, "kind=\(kind)")
        }
    }

    // MARK: - 状態の更新

    @Test("イベントから仕事の状態を決める")
    func statusAfterEvent() {
        func with(phase: RoomJobPhase?, kind: RoomEventKind? = nil) -> RoomEvent {
            RoomEvent(id: "1", jobID: "abc", phase: phase, kind: kind, text: "")
        }
        #expect(RoomJobMonitor.status(after: with(phase: .queued)) == .queued)
        #expect(RoomJobMonitor.status(after: with(phase: .researching)) == .running)
        #expect(RoomJobMonitor.status(after: with(phase: .waiting)) == .running)
        #expect(RoomJobMonitor.status(after: with(phase: .done)) == .done)
        #expect(RoomJobMonitor.status(after: with(phase: .failed)) == .failed)
        #expect(RoomJobMonitor.status(after: with(phase: nil)) == .running)
        #expect(RoomJobMonitor.status(after: with(phase: .waiting, kind: .cancelled)) == .cancelled)
    }

    // MARK: - 監視のふるまい

    @Test("イベントを適用し、仕事の状態とカーソルを更新する")
    func appliesEventsAndPersistsCursor() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                    frame(eventJSON(id: "3", jobID: "abc", phase: "building", kind: "speech", text: "組み立てる")),
                ]),
                200
            )
        ]
        let store = makeStore()
        let monitor = RoomJobMonitor(access: access, cursorStore: store)
        var spoken: [String] = []
        monitor.onDirective = { tracked in
            if let line = tracked.directive?.line { spoken.append(line) }
        }

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("仕事の状態が反映される") {
            monitor.jobs.first?.phase == .building
        }
        let job = try #require(monitor.jobs.first)
        #expect(job.title == "掃除")
        #expect(job.status == .running)
        #expect(job.latestText == "組み立てる")
        #expect(spoken == ["始める", "調べる", "組み立てる"])
        // カーソルが保存されている。
        #expect(store.cursor(for: "abc") == "3")
        #expect(store.lastJobID == "abc")
        // 最初はカーソルなしで開く。
        #expect(access.openedCursors.first.flatMap { $0 } == nil)
    }

    @Test("同じイベントの再送は二度扱わない")
    func dropsReplayedDuplicates() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        var directives = 0
        var spoken: [String] = []
        monitor.onDirective = { tracked in
            directives += 1
            if let line = tracked.directive?.line { spoken.append(line) }
        }

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("2 件だけ適用される") {
            monitor.jobs.first?.phase == .researching
        }
        #expect(directives == 2)
        #expect(spoken == ["始める", "調べる"])
    }

    @Test("配信が切れたらカーソルを載せて張り直す")
    func reconnectsWithLastEventID() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                ]),
                200
            ),
            (StubRoomAccess.emptyStream(), 200),
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("張り直しが起きる") {
            access.openedCursors.count >= 2
        }
        #expect(access.openedCursors.first.flatMap { $0 } == nil)
        #expect(access.openedCursors[1] == "2")
        #expect(access.openedJobIDs.allSatisfy { $0 == "abc" })
    }

    @Test("接続エラーでは投げずに張り直す")
    func retriesAfterError() async throws {
        let access = StubRoomAccess()
        access.openError = RoomError.requestFailed(status: 0, message: "落ちた")
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("投げずに張り直す", timeout: .seconds(12)) {
            access.openedCursors.count >= 2
        }
        #expect(access.openedCursors.allSatisfy { $0 == nil })
    }

    @Test("4xx は張り直さず、その仕事のエラーとして残す")
    func stopsOnClientErrorStatus() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [(StubRoomAccess.emptyStream(), 404)]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("エラーが残る") {
            monitor.jobs.first?.lastError != nil
        }
        // 最初の 1 回だけで張り直さない。
        try await Task.sleep(for: .milliseconds(300))
        #expect(access.openedCursors.count == 1)
        #expect(monitor.jobs.first?.lastError?.contains("404") == true)
    }

    @Test("resume は走っている仕事を発見し、見えなくなった仕事をやめる")
    func resumeDiscoversAndDropsJobs() async throws {
        let access = StubRoomAccess()
        access.listRunningResults = [
            RoomJobDetail(
                jobID: "running-1",
                title: "掃除",
                status: "running",
                artifacts: [],
                latestEvent: RoomEvent(
                    id: "9",
                    jobID: "running-1",
                    phase: .downloading,
                    kind: .speech,
                    text: "取得中だよ"
                )
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())

        await monitor.resume()
        defer { monitor.stopAll() }

        try await eventually("走っている仕事が拾われる") {
            monitor.jobs.contains { $0.jobID == "running-1" }
        }
        let job = try #require(monitor.jobs.first { $0.jobID == "running-1" })
        #expect(job.title == "掃除")
        #expect(job.status == .running)
        #expect(job.phase == .downloading)
        // 発見した時点の最新イベントをカーソルにして開く。
        try await eventually("SSE が開かれる") {
            access.openedCursors.count >= 1
        }
        #expect(access.openedCursors[0] == "9")

        // 配信に「すでに見た位相の speech」が流れても喋らない(検出済みの再送)。
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(
                        eventJSON(id: "10", jobID: "running-1", phase: "downloading", kind: "speech", text: "取得中だよ")
                    )
                ]),
                200
            )
        ]
        var spoken: [String] = []
        monitor.onDirective = { tracked in
            if let line = tracked.directive?.line { spoken.append(line) }
        }
        try await eventually("同じ位相の speech は喋らない") {
            spoken.count == 0 && monitor.jobs.first?.latestText == "取得中だよ"
        }
        #expect(spoken.isEmpty)

        // もう走っていなければ一覧から外れるが、最後に追っていた仕事は詳細から
        // 拾い直して、完了の状態と成果物を見せ続ける。
        access.listRunningResults = []
        access.detailResults = [
            "running-1": RoomJobDetail(
                jobID: "running-1",
                title: "掃除",
                status: "done",
                artifacts: [
                    RoomArtifact(
                        artifactID: "art-1",
                        kind: "report",
                        previewURL: URL(string: "https://example.com/r.pdf")!
                    )
                ],
                latestEvent: RoomEvent(id: "20", jobID: "running-1", phase: .done, kind: .summary, text: "完了した")
            )
        ]
        await monitor.resume()
        try await eventually("最後の仕事が詳細から拾い直される") {
            monitor.jobs.first?.jobID == "running-1" && monitor.jobs.first?.status == .done
        }
        #expect(monitor.jobs.first?.latestText == "完了した")
        #expect(monitor.jobs.first?.artifacts.map(\.artifactID) == ["art-1"])
    }

    @Test("中断のイベントで状態を cancelled にする")
    func cancellationUpdatesState() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "waiting", kind: "cancelled", text: "止めた"))
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.onDirective = { tracked in
            if let line = tracked.directive?.line {
                Issue.record("cancelled は喋らない: \(line)")
            }
        }

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("cancelled になる") {
            monitor.jobs.first?.status == .cancelled
        }
        let job = try #require(monitor.jobs.first)
        #expect(job.phase == .waiting)
        #expect(job.directive?.fixedAnimation == .waiting)
    }

    @Test("仕事ごとに重複排除の目印を分ける")
    func resetsDedupPerJob() async throws {
        let access = StubRoomAccess()
        // 2 つの仕事が同じイベント ID を持っていても、それぞれ独立に適用される。
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "aaa", phase: "researching", kind: "speech", text: "A 調べる"))
                ]),
                200
            ),
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "bbb", phase: "downloading", kind: "speech", text: "B 取得する"))
                ]),
                200
            ),
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        var spoken: [String] = []
        monitor.onDirective = { tracked in
            if let line = tracked.directive?.line { spoken.append(line) }
        }

        monitor.attach(jobID: "aaa", title: "A")
        monitor.attach(jobID: "bbb", title: "B")
        defer { monitor.stopAll() }

        try await eventually("2 件とも進む") {
            monitor.jobs.count == 2
                && monitor.jobs.contains { $0.jobID == "aaa" && $0.latestText == "A 調べる" }
                && monitor.jobs.contains { $0.jobID == "bbb" && $0.latestText == "B 取得する" }
        }
        #expect(Set(spoken) == Set(["A 調べる", "B 取得する"]))
    }

    @Test("resume は最後に追っていた仕事も詳細から拾い直す")
    func resumeReattachesLastJob() async throws {
        let access = StubRoomAccess()
        access.listRunningResults = []
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                title: "掃除",
                status: "done",
                artifacts: [
                    RoomArtifact(
                        artifactID: "art-1",
                        kind: "report",
                        previewURL: URL(string: "https://example.com/r.pdf")!
                    )
                ],
                latestEvent: RoomEvent(id: "9", jobID: "abc", phase: .done, kind: .summary, text: "完了した")
            )
        ]
        let store = makeStore()
        store.lastJobID = "abc"
        let monitor = RoomJobMonitor(access: access, cursorStore: store)

        await monitor.resume()
        defer { monitor.stopAll() }

        try await eventually("最後の仕事が拾われる") {
            monitor.jobs.contains { $0.jobID == "abc" }
        }
        let job = try #require(monitor.jobs.first { $0.jobID == "abc" })
        #expect(job.status == .done)
        #expect(job.artifacts.map(\.artifactID) == ["art-1"])
        // 詳細の最新イベントをカーソルにして開く。
        try await eventually("SSE が開かれる") {
            access.openedCursors.count >= 1
        }
        #expect(access.openedCursors[0] == "9")
    }

    @Test("rollback は部屋へ送って成果物を引き直す")
    func rollbackCallsRoomAndRefreshes() async throws {
        let access = StubRoomAccess()
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                artifacts: [
                    RoomArtifact(artifactID: "art-abc-v3", version: "3")
                ]
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        let rolled = try await monitor.rollbackArtifact(jobID: "abc", version: "1")
        #expect(access.rollbackCalls.map { "\($0.0):\($0.1)" } == ["abc:1"])
        #expect(rolled.artifactID == "rolled-1")
        try await eventually("成果物が引き直される") {
            monitor.jobs.first?.artifacts.first?.artifactID == "art-abc-v3"
        }
    }

    @Test("バックオフは上限で頭打ちになる")
    func backoffIsBounded() {
        let first = RoomJobMonitor.backoffDelay(attempt: 0)
        let capped = RoomJobMonitor.backoffDelay(attempt: 100)
        #expect(first >= .seconds(1))
        #expect(first <= .seconds(2))
        #expect(capped >= .seconds(29))
        #expect(capped <= .seconds(31))
    }

    @Test("流れた出来事を新しい順の履歴に残す")
    func keepsHistoryNewestFirst() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "log", text: "調べている")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())

        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("履歴が 2 件残る") {
            monitor.jobs.first?.history.count == 2
        }
        let history = monitor.jobs.first?.history ?? []
        // 新しい順。
        #expect(history.map(\.text) == ["調べている", "始める"])
        #expect(history.first?.phase == .researching)
        #expect(history.first?.kind == .log)
    }

    // MARK: - 再実行・巻き戻し

    @Test("完了後の追記は応答を正として「待ち」へ戻る")
    func followupAfterDoneMovesToQueuedImmediately() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "queued", kind: "log", text: "受け付けたよ")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                    frame(eventJSON(id: "3", jobID: "abc", phase: "done", kind: "summary", text: "完了した")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("完了になる") { monitor.jobs.first?.status == .done }
        #expect(monitor.jobs.first?.latestText == "完了した")

        // サーバが「待ち」に戻した応答を正として、イベントを待たず表示を切り替える。
        access.followupResults["abc"] = JobRequestResponse(jobID: "abc", threadID: nil, status: "queued")
        _ = try await monitor.followup(jobID: "abc", body: "直して")
        #expect(monitor.jobs.first?.status == .queued)

        // 詳細の更新で、再実行の「作業中」とその後の「完了」もサーバ状態に合わせて拾う。
        access.detailResults["abc"] = RoomJobDetail(
            jobID: "abc",
            title: "掃除",
            status: "running",
            latestEvent: RoomEvent(id: "4", jobID: "abc", phase: .researching, kind: .speech, text: "直す")
        )
        await monitor.refreshArtifacts(jobID: "abc")
        #expect(monitor.jobs.first?.status == .running)
        #expect(monitor.jobs.first?.latestText == "直す")

        access.detailResults["abc"] = RoomJobDetail(
            jobID: "abc",
            title: "掃除",
            status: "done",
            latestEvent: RoomEvent(id: "5", jobID: "abc", phase: .done, kind: .summary, text: "直した")
        )
        await monitor.refreshArtifacts(jobID: "abc")
        #expect(monitor.jobs.first?.status == .done)
        #expect(monitor.jobs.first?.latestText == "直した")
    }

    @Test("失敗後の再実行イベントで終端を抜けて待ち・作業中・完了へ進む")
    func failedRestartExitsTerminalOnQueuedEvent() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "failed", kind: "speech", text: "失敗した")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "queued", kind: "log", text: "続きが来た")),
                    frame(eventJSON(id: "3", jobID: "abc", phase: "researching", kind: "speech", text: "直す")),
                    frame(eventJSON(id: "4", jobID: "abc", phase: "done", kind: "summary", text: "直した")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        // 終端で止まらず、最後まで再実行の結果（完了）に追いつく。
        try await eventually("再実行の完了になる") { monitor.jobs.first?.status == .done }
        #expect(monitor.jobs.first?.latestText == "直した")
    }

    @Test("中断後の再実行イベントで終端を抜ける")
    func cancelledRestartExitsTerminalOnQueuedEvent() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "waiting", kind: "cancelled", text: "やめたよ")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "queued", kind: "log", text: "続きが来た")),
                    frame(eventJSON(id: "3", jobID: "abc", phase: "researching", kind: "speech", text: "直す")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        // 中断のまま止まらず、再実行の「作業中」へ進む。
        try await eventually("作業中になる") { monitor.jobs.first?.status == .running }
        #expect(monitor.jobs.first?.phase == .researching)
    }

    @Test("記憶の承認・決定イベントでは完了表示を巻き戻さない")
    func memoryDecisionDoesNotRewindDone() async throws {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(eventJSON(id: "1", jobID: "abc", phase: "done", kind: "summary", text: "完了した")),
                    frame(eventJSON(id: "2", jobID: "abc", phase: "waiting", kind: "log", text: "memory 候補を確定したよ。")),
                ]),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        try await eventually("決定イベントが載る") { monitor.jobs.first?.latestText == "memory 候補を確定したよ。" }
        // 本文は更新しても、状態は完了のまま。
        #expect(monitor.jobs.first?.status == .done)
    }

    @Test("復帰時も詳細の status を正とし、記憶決定イベントから作業中と推測しない")
    func resumeDoesNotInferRunningFromMemoryDecision() async throws {
        let access = StubRoomAccess()
        access.listRunningResults = []
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                title: "掃除",
                status: "done",
                latestEvent: RoomEvent(id: "9", jobID: "abc", phase: .waiting, kind: .log, text: "memory 候補を確定したよ。")
            )
        ]
        let store = makeStore()
        store.lastJobID = "abc"
        store.setCursor("9", for: "abc")
        let monitor = RoomJobMonitor(access: access, cursorStore: store)

        await monitor.resume()
        defer { monitor.stopAll() }

        try await eventually("完了の仕事が拾われる") { monitor.jobs.contains { $0.jobID == "abc" } }
        #expect(monitor.jobs.first?.status == .done)
    }

    @Test("中断・承認の失敗は操作エラーとして表示に残る")
    func operationFailuresAreRecorded() async throws {
        let access = StubRoomAccess()
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        access.operationError = RoomError.requestFailed(status: 403, message: "止められない")
        await #expect(throws: RoomError.self) {
            try await monitor.cancel(jobID: "abc")
        }
        #expect(monitor.jobs.first?.operationError?.contains("止められない") == true)

        access.operationError = RoomError.requestFailed(status: 409, message: "すでに決定済み")
        await #expect(throws: RoomError.self) {
            try await monitor.approveMemory(jobID: "abc", candidateID: "c1")
        }
        #expect(monitor.jobs.first?.operationError?.contains("すでに決定済み") == true)

        // 次に成功したら失敗表示は消える。
        access.operationError = nil
        access.memoryResults = ["abc": []]
        try await monitor.rejectMemory(jobID: "abc", candidateID: "c1")
        #expect(monitor.jobs.first?.operationError == nil)
    }

    @Test("対象が消えた（404）操作は監視から外して表示も巻き戻さない")
    func missingJobOperationStopsTracking() async throws {
        let access = StubRoomAccess()
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        access.operationError = RoomError.requestFailed(status: 404, message: "仕事がない")
        await #expect(throws: RoomError.self) {
            try await monitor.cancel(jobID: "abc")
        }
        #expect(monitor.jobs.isEmpty)
    }

    @Test("イベント 1 件から次の状態を決める（終端は queued でだけ抜ける）")
    func advanceStatusTransitions() {
        func event(id: String, phase: RoomJobPhase?, kind: RoomEventKind?) -> RoomEvent {
            RoomEvent(id: id, jobID: "abc", phase: phase, kind: kind, text: "")
        }

        // 完了中の仕事に waiting（記憶の決定・候補）が来ても完了のまま。
        #expect(RoomJobMonitor.advanceStatus(from: .done, after: event(id: "1", phase: .waiting, kind: .log)) == .done)
        #expect(
            RoomJobMonitor.advanceStatus(from: .done, after: event(id: "2", phase: .waiting, kind: .memoryCandidate))
                == .done
        )
        // 中断後の trailing な進捗でも中断のまま。
        #expect(
            RoomJobMonitor.advanceStatus(from: .cancelled, after: event(id: "3", phase: .researching, kind: .speech))
                == .cancelled
        )
        // 本当の再実行（queued）だけが終端を抜ける。
        #expect(RoomJobMonitor.advanceStatus(from: .done, after: event(id: "4", phase: .queued, kind: .log)) == .queued)
        #expect(
            RoomJobMonitor.advanceStatus(from: .failed, after: event(id: "5", phase: .queued, kind: .log)) == .queued
        )
        #expect(
            RoomJobMonitor.advanceStatus(from: .cancelled, after: event(id: "6", phase: .queued, kind: .log)) == .queued
        )
        #expect(
            RoomJobMonitor.advanceStatus(from: .queued, after: event(id: "7", phase: .researching, kind: .speech))
                == .running
        )
        #expect(
            RoomJobMonitor.advanceStatus(from: .running, after: event(id: "8", phase: .done, kind: .summary)) == .done
        )
        // 再実行の失敗も終端として受け取る。
        #expect(
            RoomJobMonitor.advanceStatus(from: .queued, after: event(id: "9", phase: .failed, kind: .speech)) == .failed
        )
    }
}
