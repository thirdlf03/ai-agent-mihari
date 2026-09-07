import Foundation
import Testing

@testable import MihariCore

/// 仕事の詳細パネルの状態。更新が状態・成果物・記憶をまとめて引き、
/// 対象が消えたら別の仕事に切り替えないことを確かめる。
@Suite("仕事の詳細パネルの状態")
@MainActor
struct RoomJobDetailViewModelTests {

    /// 通信を差し替えた部屋の口。
    @MainActor
    private final class StubRoomAccess: RoomAccess {
        var listRunningResults: [RoomJobDetail] = []
        var detailResults: [String: RoomJobDetail] = [:]
        /// 詳細取得が投げるエラー。設定しておくと detail より先に見る。
        var detailError: (any Error)?
        var memoryResults: [String: [RoomMemoryCandidate]] = [:]
        /// 追記・中断・決定が投げるエラー。
        var operationError: (any Error)?
        private(set) var followupCalls: [String] = []

        func listRunning() async throws -> [RoomJobDetail] { listRunningResults }
        func detail(jobID: String) async throws -> RoomJobDetail {
            if let detailError { throw detailError }
            return detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }
        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            followupCalls.append(jobID)
            if let operationError { throw operationError }
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "queued")
        }
        func cancel(jobID: String) async throws -> JobRequestResponse {
            if let operationError { throw operationError }
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "cancelled")
        }
        func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] {
            memoryResults[jobID] ?? []
        }
        func approveMemory(jobID: String, candidateID: String) async throws {
            if let operationError { throw operationError }
        }
        func rejectMemory(jobID: String, candidateID: String) async throws {
            if let operationError { throw operationError }
        }
        func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            if let operationError { throw operationError }
            return RoomArtifact(artifactID: "rolled-\(version)", version: version)
        }
        @MainActor
        func openEventStream(jobID: String, lastEventID: String?) async throws -> (RoomEventByteStream, Int) {
            (RoomEventByteStream(AsyncStream<UInt8> { $0.finish() }), 200)
        }
    }

    private func makeStore() -> UserDefaultsRoomJobCursorStore {
        let suite = "mihari.test.roomDetail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    @Test("更新は状態・成果物・記憶をまとめて引き直す")
    func refreshFetchesStatusArtifactsAndMemory() async throws {
        let access = StubRoomAccess()
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                title: "掃除",
                status: "running",
                artifacts: [
                    RoomArtifact(
                        artifactID: "art-1",
                        kind: "report",
                        previewURL: URL(string: "https://example.com/r.pdf")!
                    )
                ]
            )
        ]
        access.memoryResults = [
            "abc": [
                RoomMemoryCandidate(
                    candidateID: "c1",
                    target: "MEMORY.md",
                    content: "深煎りが好き",
                    status: "pending"
                )
            ]
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "abc")
        await model.refresh()

        let job = try #require(monitor.jobs.first { $0.jobID == "abc" })
        #expect(job.status == .running)
        #expect(job.artifacts.map(\.artifactID) == ["art-1"])
        #expect(job.pendingMemoryCount == 1)
    }

    @Test("対象が監視から外れても別の仕事に表示を切り替えない")
    func trackedJobDoesNotSwitchToAnotherJob() async {
        let access = StubRoomAccess()
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "aaa", title: "A")
        monitor.attach(jobID: "bbb", title: "B")
        defer { monitor.stopAll() }

        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "aaa")
        #expect(model.trackedJob?.jobID == "aaa")

        // aaa が監視から外れても、別に bbb が残っていても bbb を見せない。
        monitor.stop(jobID: "aaa")
        #expect(monitor.jobs.map(\.jobID) == ["bbb"])
        #expect(model.trackedJob == nil)
    }

    @Test("対象が部屋から消えた更新は「追っていない」表示になる")
    func refreshOfMissingJobClearsTracking() async {
        let access = StubRoomAccess()
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "abc")
        access.detailError = RoomError.requestFailed(status: 404, message: "仕事がない")
        await model.refresh()

        #expect(model.trackedJob == nil)
        #expect(monitor.jobs.isEmpty)
    }

    @Test("指摘の送信失敗は操作エラーとして表示に残る")
    func submitCommentFailureIsShownAndRecorded() async {
        let access = StubRoomAccess()
        access.operationError = RoomError.requestFailed(status: 500, message: "サーバが落ちた")
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "abc")
        model.comment = "色を直して"
        await model.submitComment(previewURL: nil)

        #expect(model.didFail)
        #expect(model.notice?.contains("サーバが落ちた") == true)
        #expect(monitor.jobs.first?.operationError?.contains("サーバが落ちた") == true)
    }
}
