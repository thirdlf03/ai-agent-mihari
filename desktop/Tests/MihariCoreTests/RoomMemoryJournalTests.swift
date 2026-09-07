import Foundation
import Testing

@testable import MihariCore

/// 部屋の日誌の実 JSON と記憶の承認の取り回し。
///
/// 日誌の実体は `room/src/mihari_room/events.py` の `EventJournal.append` が書く
/// `{id:number, job_id, phase, kind, text, progress, created_at:ISO8601}`。
/// `id` は数値、`kind: memory_candidate`・`phase: waiting` の候補イベントで記憶の
/// 一覧を引き直す。承認・却下は API が成功してから引き直すまで約束しない。
@Suite("部屋の日誌の実形と記憶の承認")
@MainActor
struct RoomMemoryJournalTests {

    /// 通信を差し替えた部屋の口。
    @MainActor
    private final class StubRoomAccess: RoomAccess {
        var listRunningResults: [RoomJobDetail] = []
        var detailResults: [String: RoomJobDetail] = [:]
        var memoryResults: [String: [RoomMemoryCandidate]] = [:]
        private(set) var approveCalls: [(String, String)] = []
        private(set) var rejectCalls: [(String, String)] = []
        var streamsForOpen: [(RoomEventByteStream, Int)] = []

        func listRunning() async throws -> [RoomJobDetail] { listRunningResults }
        func detail(jobID: String) async throws -> RoomJobDetail {
            detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }
        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: jobID, threadID: nil, status: "running")
        }
        func cancel(jobID: String) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: jobID, threadID: nil, status: "cancelled")
        }
        func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] {
            memoryResults[jobID] ?? []
        }
        func approveMemory(jobID: String, candidateID: String) async throws {
            approveCalls.append((jobID, candidateID))
        }
        func rejectMemory(jobID: String, candidateID: String) async throws {
            rejectCalls.append((jobID, candidateID))
        }
        @MainActor
        func openEventStream(jobID: String, lastEventID: String?) async throws -> (RoomEventByteStream, Int) {
            guard !streamsForOpen.isEmpty else {
                return (RoomEventByteStream(AsyncStream<UInt8> { $0.finish() }), 200)
            }
            return streamsForOpen[0]
        }
    }

    private func makeStore() -> UserDefaultsRoomJobCursorStore {
        let suite = "mihari.test.roomMemory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    private func decode(_ json: String) throws -> RoomEvent {
        try JSONDecoder().decode(RoomEvent.self, from: Data(json.utf8))
    }

    private func sse(_ frames: String...) -> RoomEventByteStream {
        let raw = frames.joined().data(using: .utf8)!
        let stream = AsyncStream<UInt8> { continuation in
            for byte in raw { continuation.yield(byte) }
            continuation.finish()
        }
        return RoomEventByteStream(stream)
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("待っても条件を満たさなかった: \(what)")
    }

    // MARK: - 実 JSON の読み

    @Test("日誌の実 JSON(数値 id・memory_candidate)を読む")
    func decodesRealJournalMemoryCandidate() throws {
        // `EventJournal.append` の実形そのまま。progress は null、created_at は秒精度 ISO8601。
        let event = try decode(
            #"{"id":7,"job_id":"abc","phase":"waiting","kind":"memory_candidate","text":"好きな珈琲は深煎り","progress":null,"created_at":"2026-09-05T12:00:00+00:00"}"#
        )
        #expect(event.id == "7")
        #expect(event.jobID == "abc")
        #expect(event.phase == .waiting)
        #expect(event.kind == .memoryCandidate)
        #expect(event.text == "好きな珈琲は深煎り")
        #expect(event.progress == nil)
        #expect(event.createdAt != nil)
    }

    @Test("数値 id と文字列 id を同じに読む")
    func readsNumericAndStringIDs() throws {
        let numeric = try decode(#"{"id":12,"job_id":"abc","phase":"queued","kind":"speech","text":"始める"}"#)
        let string = try decode(#"{"id":"12","job_id":"abc","phase":"queued","kind":"speech","text":"始める"}"#)
        #expect(numeric.id == "12")
        #expect(string.id == "12")
    }

    @Test("記憶の候補は喋らない")
    func memoryCandidateNeverSpeaks() {
        let directive = RoomJobMonitor.makeDirective(
            event: RoomEvent(id: "7", jobID: "abc", phase: .waiting, kind: .memoryCandidate, text: "覚えて"),
            previousPhase: .researching,
            isFirstEvent: false,
            wasSeeded: false
        )
        #expect(directive.line == nil)
        #expect(directive.fixedAnimation == .waiting)
    }

    @Test("カーソルは数値だけを通す")
    func cursorOnlyNumeric() {
        #expect(RoomJobMonitor.normalizeCursor("12") == "12")
        #expect(RoomJobMonitor.normalizeCursor("ev-1") == nil)
        #expect(RoomJobMonitor.normalizeCursor(nil) == nil)
        #expect(RoomJobMonitor.normalizeCursor("") == nil)
    }

    @Test("失敗のあとの雑音で巻き戻さない")
    func failedIsSticky() async {
        let access = StubRoomAccess()
        access.streamsForOpen = [
            (
                sse(
                    "data: {\"id\":1,\"job_id\":\"abc\",\"phase\":\"failed\",\"kind\":\"speech\",\"text\":\"失敗した\"}\n\n",
                    "data: {\"id\":2,\"job_id\":\"abc\",\"phase\":\"waiting\",\"kind\":\"log\",\"text\":\"後片付け\"}\n\n"
                ), 200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }
        await eventually("失敗になる") { monitor.jobs.first?.status == .failed }
        // 後の waiting/log が来ても失敗のまま。
        await eventually("失敗のまま保つ") { monitor.jobs.first?.latestText == "後片付け" }
        #expect(monitor.jobs.first?.status == .failed)
    }

    // MARK: - 記憶の一覧と決定

    @Test("候補イベントで記憶の一覧を引き直す")
    func candidateEventRefreshesMemory() async {
        let access = StubRoomAccess()
        access.memoryResults = [
            "abc": [RoomMemoryCandidate(candidateID: "c1", target: "MEMORY.md", content: "深煎りが好き", status: "pending")]
        ]
        access.streamsForOpen = [
            (
                sse(
                    "data: {\"id\":7,\"job_id\":\"abc\",\"phase\":\"waiting\","
                        + "\"kind\":\"memory_candidate\",\"text\":\"候補が出た\"}\n\n"
                ),
                200
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        var spoken: [String] = []
        monitor.onDirective = { tracked in
            if let line = tracked.directive?.line { spoken.append(line) }
        }
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }
        await eventually("記憶が載る") { monitor.jobs.first?.memories.count == 1 }
        #expect(monitor.jobs.first?.pendingMemoryCount == 1)
        #expect(monitor.jobs.first?.memories.first?.content == "深煎りが好き")
        #expect(spoken.isEmpty)
    }

    @Test("詳細の取得で記憶も引き直す")
    func detailFetchRefreshesMemory() async {
        let access = StubRoomAccess()
        access.detailResults = ["abc": RoomJobDetail(jobID: "abc", title: "掃除", status: "running")]
        access.memoryResults = [
            "abc": [RoomMemoryCandidate(candidateID: "c1", target: "USER.md", content: "早起き", status: "pending")]
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }
        await monitor.refreshArtifacts(jobID: "abc")
        #expect(monitor.jobs.first?.memories.first?.content == "早起き")
    }

    @Test("承認・却下は API のあとに一覧を引き直す")
    func decisionsRefreshAfterAPI() async throws {
        let access = StubRoomAccess()
        access.memoryResults = ["abc": []]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }
        try await monitor.approveMemory(jobID: "abc", candidateID: "c1")
        try await monitor.rejectMemory(jobID: "abc", candidateID: "c2")
        #expect(access.approveCalls.map(\.1) == ["c1"])
        #expect(access.rejectCalls.map(\.1) == ["c2"])
    }

    @Test("記憶の一覧の形を読む")
    func decodesMemoryList() throws {
        let data = Data(
            (#"{"candidates":[{"id":"c1","target":"MEMORY.md","#
                + #"content":"深煎りが好き","status":"pending","created_at":1757073600}]}"#)
                .utf8
        )
        let response = try JSONDecoder().decode(RoomMemoryCandidatesResponse.self, from: data)
        #expect(response.candidates.count == 1)
        #expect(response.candidates.first?.content == "深煎りが好き")
        #expect(response.candidates.first?.isPending == true)
    }

    // MARK: - 復帰と切り替え

    @Test("カーソルが残る仕事は詳細から拾い直す")
    func restoresPersistedTerminalJobs() async {
        let access = StubRoomAccess()
        access.listRunningResults = []
        access.detailResults = [
            "old": RoomJobDetail(jobID: "old", title: "終わった仕事", status: "done")
        ]
        let store = makeStore()
        store.setCursor("9", for: "old")
        let monitor = RoomJobMonitor(access: access, cursorStore: store)
        await monitor.resume()
        defer { monitor.stopAll() }
        await eventually("拾い直す") { monitor.jobs.contains { $0.jobID == "old" } }
        #expect(monitor.jobs.first?.status == .done)
    }

    @Test("切り替えたら古い配信を止める")
    func focusStopsOldStreams() async {
        let access = StubRoomAccess()
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "aaa", title: "A")
        monitor.focus(jobID: "bbb", title: "B")
        defer { monitor.stopAll() }
        await eventually("新しいだけ残る") { monitor.jobs.map(\.jobID) == ["bbb"] }
    }
}
