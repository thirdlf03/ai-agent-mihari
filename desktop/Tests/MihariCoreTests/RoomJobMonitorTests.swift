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
        var detailResults: [String: RoomJobDetail] = [:]
        private(set) var followupCalls: [String] = []
        private(set) var cancelCalls: [String] = []
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

        func detail(jobID: String) async throws -> RoomJobDetail {
            detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }

        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            followupCalls.append(jobID)
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "running")
        }

        func cancel(jobID: String) async throws -> JobRequestResponse {
            cancelCalls.append(jobID)
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "cancelled")
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
                    frame(eventJSON(id: "ev-1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "ev-2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                    frame(eventJSON(id: "ev-3", jobID: "abc", phase: "building", kind: "speech", text: "組み立てる")),
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
        #expect(store.cursor(for: "abc") == "ev-3")
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
                    frame(eventJSON(id: "ev-1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "ev-1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "ev-2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
                    frame(eventJSON(id: "ev-2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
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
                    frame(eventJSON(id: "ev-1", jobID: "abc", phase: "queued", kind: "speech", text: "始める")),
                    frame(eventJSON(id: "ev-2", jobID: "abc", phase: "researching", kind: "speech", text: "調べる")),
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
        #expect(access.openedCursors[1] == "ev-2")
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
                    id: "ev-9",
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
        #expect(access.openedCursors[0] == "ev-9")

        // 配信に「すでに見た位相の speech」が流れても喋らない(検出済みの再送)。
        access.streamsForOpen = [
            (
                sse(frames: [
                    frame(
                        eventJSON(id: "ev-10", jobID: "running-1", phase: "downloading", kind: "speech", text: "取得中だよ")
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
                latestEvent: RoomEvent(id: "ev-20", jobID: "running-1", phase: .done, kind: .summary, text: "完了した")
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
                    frame(eventJSON(id: "ev-1", jobID: "abc", phase: "waiting", kind: "cancelled", text: "止めた"))
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
        #expect(spoken == ["A 調べる", "B 取得する"])
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
                latestEvent: RoomEvent(id: "ev-9", jobID: "abc", phase: .done, kind: .summary, text: "完了した")
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
        #expect(access.openedCursors[0] == "ev-9")
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
}
