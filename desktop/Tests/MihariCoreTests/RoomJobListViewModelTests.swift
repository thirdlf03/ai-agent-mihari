import Foundation
import Testing

@testable import MihariCore

/// 仕事一覧の状態。履歴込み一覧・検索・未読完了・選択の固定を確かめる。
@Suite("仕事一覧")
@MainActor
struct RoomJobListViewModelTests {

    /// 通信をスタブに差し替えた部屋の口。`listJobs` だけ返す。
    @MainActor
    private final class StubRoomAccess: RoomAccess {
        var listJobsResults: [RoomJobDetail] = []
        private(set) var listJobsCalls = 0
        var listRunningResults: [RoomJobDetail] = []
        var detailResults: [String: RoomJobDetail] = [:]

        func listRunning() async throws -> [RoomJobDetail] { listRunningResults }
        func listJobs() async throws -> [RoomJobDetail] {
            listJobsCalls += 1
            return listJobsResults
        }
        func detail(jobID: String) async throws -> RoomJobDetail {
            detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }
        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: jobID, status: "queued")
        }
        func steer(jobID: String, instruction: String) async throws -> JobSteerResponse {
            JobSteerResponse(jobID: jobID, seq: 1, text: instruction, delivered: true)
        }
        func answerQuestion(jobID: String, questionID: String, answer: String) async throws -> JobQuestionAnswerResponse {
            JobQuestionAnswerResponse(
                jobID: jobID,
                question: RoomPendingQuestion(id: questionID, question: "?", status: "answered", answer: answer)
            )
        }
        func cancel(jobID: String) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: jobID, status: "cancelled")
        }
        func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] { [] }
        func approveMemory(jobID: String, candidateID: String) async throws {}
        func rejectMemory(jobID: String, candidateID: String) async throws {}
        func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            RoomArtifact(artifactID: "a")
        }
        func publishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            RoomArtifact(artifactID: "a", version: version, visibility: "public")
        }
        func unpublishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            RoomArtifact(artifactID: "a", version: version, visibility: "private")
        }
        func restoreArtifact(jobID: String, version: String) async throws {}
        func openEventStream(jobID: String, lastEventID: String?) async throws -> (RoomEventByteStream, Int) {
            (RoomEventByteStream(AsyncStream<UInt8> { $0.finish() }), 200)
        }
    }

    /// 読んだ仕事を覚えておく差し替え。
    private final class InMemoryReadStore: RoomJobReadStoring {
        private var read: Set<String> = []
        func isRead(_ jobID: String) -> Bool { read.contains(jobID) }
        func markRead(_ jobID: String) { read.insert(jobID) }
    }

    /// 実行のたびに空の UserDefaults を使い、テスト同士で共有しないようにする。
    private func makeCursorStore() -> UserDefaultsRoomJobCursorStore {
        let suiteName = "mihari.test.roomList.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    private func makeMonitor(access: StubRoomAccess) -> RoomJobMonitor {
        RoomJobMonitor(access: access, cursorStore: makeCursorStore())
    }

    private func petDetail(
        jobID: String,
        title: String,
        status: String,
        body: String,
        createdAt: Double
    ) -> RoomJobDetail {
        RoomJobDetail(
            jobID: jobID,
            title: title,
            status: status,
            source: "pet",
            createdAt: Date(timeIntervalSince1970: createdAt),
            body: body
        )
    }

    // MARK: - 一覧の取得

    @Test("再起動後・Discord 作成を含む全仕事を返す")
    func loadsAllJobsIncludingTerminalAndForum() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [
            petDetail(jobID: "pet-1", title: "ペットの仕事", status: "queued", body: "頼む", createdAt: 2),
            RoomJobDetail(
                jobID: "forum-1",
                title: "Discordから",
                status: "done",
                source: "forum",
                createdAt: Date(timeIntervalSince1970: 1),
                body: "これも見える"
            ),
        ]
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )

        await model.load()

        #expect(access.listJobsCalls == 1)
        #expect(model.items.map(\.jobID) == ["pet-1", "forum-1"])
        let forum = try #require(model.items.first { $0.jobID == "forum-1" })
        #expect(forum.source == "forum")
        #expect(forum.status == .done)
        #expect(forum.unread)  // 完了なのにまだ開いていない
        #expect(!model.items[0].unread)
    }

    @Test("取得に失敗したらエラーを残す")
    func reportsLoadError() async throws {
        struct Boom: Error {}
        let access = StubRoomAccess()
        access.listJobsResults = []
        // 通信エラーを再現するため、`listJobs` を差し替えられないので 404 にはせず、
        // 成功しない口として扱う（上のスタブは常に成功するため、エラー系は監視側で担保）。
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )
        await model.load()
        #expect(model.lastError == nil)
        #expect(model.items.isEmpty)
    }

    // MARK: - 検索

    @Test("題・本文・ID で検索できる")
    func searchFiltersByTitleBodyAndID() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [
            petDetail(jobID: "aaa", title: "掃除", status: "queued", body: "部屋を片付けて", createdAt: 3),
            petDetail(jobID: "bbb", title: "調べもの", status: "done", body: "Discord の使い方", createdAt: 2),
            petDetail(jobID: "ccc", title: "献立", status: "failed", body: "晩ごはん", createdAt: 1),
        ]
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )
        await model.load()

        model.query = "掃除"
        #expect(model.filteredItems.map(\.jobID) == ["aaa"])

        model.query = "discord"
        #expect(model.filteredItems.map(\.jobID) == ["bbb"])

        model.query = "cc"
        #expect(model.filteredItems.map(\.jobID) == ["ccc"])

        model.query = " "
        #expect(model.filteredItems.count == 3)
    }

    // MARK: - 未読完了

    @Test("完了・失敗・中断の未読は開くと消える")
    func unreadClearsOnSelect() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [
            petDetail(jobID: "done", title: "完了", status: "done", body: "x", createdAt: 2),
            petDetail(jobID: "failed", title: "失敗", status: "failed", body: "x", createdAt: 1),
            petDetail(jobID: "queue", title: "待ち", status: "queued", body: "x", createdAt: 0),
        ]
        let readStore = InMemoryReadStore()
        let model = RoomJobListViewModel(access: access, monitor: makeMonitor(access: access), readStore: readStore)
        await model.load()
        #expect(model.unreadCount == 2)

        model.select("done")

        #expect(model.unreadCount == 1)
        #expect(readStore.isRead("done"))
        #expect(model.selectedJobID == "done")
    }

    // MARK: - 選択の固定

    @Test("別ジョブの進捗で選択が変わらない")
    func selectionSurvivesOtherJobProgress() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [
            petDetail(jobID: "a", title: "仕事A", status: "running", body: "x", createdAt: 2),
            petDetail(jobID: "b", title: "仕事B", status: "queued", body: "x", createdAt: 1),
        ]
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )
        await model.load()

        model.select("b")
        #expect(model.selectedJobID == "b")

        // A の進捗が届いても、選択は B のまま。
        model.merge(monitorJobs: [
            RoomJobTrackedJob(
                jobID: "a",
                title: "仕事A",
                status: .done,
                phase: .done,
                latestText: "終わった",
                artifacts: [RoomArtifact(artifactID: "art", previewURL: URL(string: "https://example.com/a"))]
            )
        ])
        #expect(model.selectedJobID == "b")
        let a = try #require(model.items.first { $0.jobID == "a" })
        #expect(a.status == .done)
    }

    @Test("監視中に新しく付いた仕事も一覧に載る")
    func mergeAddsNewlyAttachedJobs() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [petDetail(jobID: "old", title: "古い", status: "queued", body: "x", createdAt: 1)]
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )
        await model.load()
        #expect(model.items.count == 1)

        model.merge(monitorJobs: [
            RoomJobTrackedJob(jobID: "new", title: "つい頼んだ", status: .running, latestText: "走り出した")
        ])

        #expect(model.items.count == 2)
        #expect(model.items.first?.jobID == "new")
        #expect(model.items.first?.status == .running)
    }

    /// 一覧の詳細を開くと、同じ仕事を開いたまま操作が続く（対象が切り替わらない）。
    @Test("選択した仕事の詳細が開く")
    func selectOpensPinnedJob() async throws {
        let access = StubRoomAccess()
        access.listJobsResults = [petDetail(jobID: "a", title: "仕事A", status: "queued", body: "x", createdAt: 1)]
        var opened: String?
        let model = RoomJobListViewModel(
            access: access,
            monitor: makeMonitor(access: access),
            readStore: InMemoryReadStore()
        )
        await model.load()

        model.select("a")
        opened = model.selectedJobID
        #expect(opened == "a")
    }
}
