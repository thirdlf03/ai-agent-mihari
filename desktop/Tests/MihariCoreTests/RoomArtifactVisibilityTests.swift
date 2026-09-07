import Foundation
import Testing

@testable import MihariCore

/// 成果物の版ごとの公開・非公開（#19）を確かめる。
///
/// - モデルは `visibility` / `view_url` を読む（古い応答は preview_url の有無で判定）
/// - 監視は publish / unpublish / restore を部屋へ送り、成果物を引き直す
/// - 認証付きプレビューのフェッチャーはトークンをヘッダにだけ載せる
/// - 「この版から修正」は復元 → 追記の順で、実行中は送らせない
@Suite("成果物の公開・非公開")
@MainActor
struct RoomArtifactVisibilityTests {

    /// 通信を差し替えた部屋の口。
    @MainActor
    private final class StubRoomAccess: RoomAccess {
        var listRunningResults: [RoomJobDetail] = []
        var detailResults: [String: RoomJobDetail] = [:]
        private(set) var publishCalls: [(String, String)] = []
        private(set) var unpublishCalls: [(String, String)] = []
        private(set) var restoreCalls: [(String, String)] = []
        private(set) var followupCalls: [String] = []
        var streamsForOpen: [(RoomEventByteStream, Int)] = []

        func listRunning() async throws -> [RoomJobDetail] { listRunningResults }
        func listJobs() async throws -> [RoomJobDetail] { listRunningResults }
        func detail(jobID: String) async throws -> RoomJobDetail {
            detailResults[jobID] ?? RoomJobDetail(jobID: jobID)
        }
        func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse {
            followupCalls.append(jobID)
            return JobRequestResponse(jobID: jobID, threadID: nil, status: "running")
        }
        func cancel(jobID: String) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: jobID, threadID: nil, status: "cancelled")
        }
        func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] { [] }
        func approveMemory(jobID: String, candidateID: String) async throws {}
        func rejectMemory(jobID: String, candidateID: String) async throws {}
        func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
            RoomArtifact(
                artifactID: "art-\(jobID)-v3",
                version: "3",
                visibility: "private",
                viewPath: "/jobs/\(jobID)/artifacts/3/files/"
            )
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
                visibility: "private",
                viewPath: "/jobs/\(jobID)/artifacts/\(version)/files/"
            )
        }
        func restoreArtifact(jobID: String, version: String) async throws {
            restoreCalls.append((jobID, version))
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
        let suite = "mihari.test.roomArtifacts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    // MARK: - モデルのデコード

    @Test("公開状態と認証付き取得経路を読む（非公開）")
    func decodesPrivateArtifact() throws {
        let json = """
            {"id":"art-x-v2","job_id":"x","version":2,"kind":"web",
             "preview_url":null,"visibility":"private",
             "view_url":"/jobs/x/artifacts/2/files/","sha256":"abcd"}
            """
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: Data(json.utf8))
        #expect(artifact.version == "2")
        #expect(artifact.previewURL == nil)
        #expect(artifact.visibility == "private")
        #expect(artifact.isPublic == false)
        #expect(artifact.viewPath == "/jobs/x/artifacts/2/files/")
    }

    @Test("公開中は共有 URL を持ち、非公開扱いにならない")
    func decodesPublicArtifact() throws {
        let json = """
            {"id":"art-x-v1","job_id":"x","version":1,
             "preview_url":"https://preview.example.test/abc/","visibility":"public"}
            """
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: Data(json.utf8))
        #expect(artifact.isPublic == true)
        #expect(artifact.previewURL?.absoluteString == "https://preview.example.test/abc/")
    }

    @Test("古い応答（公開状態なし）は共有 URL の有無で判定する")
    func legacyArtifactFallsBackToPreviewURL() throws {
        let publicLegacy = """
            {"id":"art-x-v1","job_id":"x","version":1,
             "preview_url":"https://preview.example.test/aaa/"}
            """
        #expect(
            try JSONDecoder().decode(RoomArtifact.self, from: Data(publicLegacy.utf8)).isPublic == true
        )
        let privateWithoutField = """
            {"id":"art-x-v1","job_id":"x","version":1,"preview_url":null}
            """
        #expect(
            try JSONDecoder().decode(RoomArtifact.self, from: Data(privateWithoutField.utf8)).isPublic
                == false
        )
    }

    // MARK: - 監視の操作

    @Test("公開・非公開・復元は部屋へ送って成果物を引き直す")
    func publishUnpublishRestoreCallRoomAndRefresh() async throws {
        let access = StubRoomAccess()
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                artifacts: [
                    RoomArtifact(artifactID: "art-abc-v1", version: "1", visibility: "public")
                ]
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }

        let published = try await monitor.publishArtifact(jobID: "abc", version: "1")
        #expect(access.publishCalls.map { "\($0.0):\($0.1)" } == ["abc:1"])
        #expect(published.isPublic == true)

        let unpublished = try await monitor.unpublishArtifact(jobID: "abc", version: "1")
        #expect(access.unpublishCalls.map { "\($0.0):\($0.1)" } == ["abc:1"])
        #expect(unpublished.isPublic == false)

        try await monitor.restoreArtifact(jobID: "abc", version: "1")
        #expect(access.restoreCalls.map { "\($0.0):\($0.1)" } == ["abc:1"])

        try await eventually("公開・非公開の結果が詳細に反映される") {
            monitor.jobs.first?.artifacts.first?.visibility == "public"
        }
    }

    // MARK: - 認証付きプレビューのフェッチャー

    @Test("フィッチャーはトークンをヘッダにだけ載せる")
    func fetcherKeepsTokenOutOfURLs() throws {
        let fetcher = RoomPreviewFetcher(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "room-token",
            session: URLSession.shared,
            jobID: "abc",
            version: "2"
        )
        let page = try #require(fetcher.pageURL(jobID: "abc", version: "2"))
        #expect(page.scheme == RoomAuthenticatedPreview.scheme)
        #expect(page.host == "room")
        // URLComponents は末尾の / を正規化する。URL オブジェクト自体は / 付きのまま。
        #expect(page.path == "/jobs/abc/artifacts/2/files")
        // URL にトークンは入らない。
        #expect(!page.absoluteString.contains("room-token"))

        let request = try #require(fetcher.request(forScheme: page))
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/jobs/abc/artifacts/2/files")
        #expect(request.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "room-token")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        // ヘッダにしか載っていない。
        #expect(
            !(request.description.contains("room-token")
                && request.value(forHTTPHeaderField: DaemonClient.tokenHeader) == nil)
        )

        // 相対リソース（app.css）も同じくヘッダ付きで部屋へ向かう。
        let css = try #require(URL(string: "app.css", relativeTo: page))
        let cssRequest = try #require(fetcher.request(forScheme: css))
        #expect(cssRequest.url?.absoluteString == "http://127.0.0.1:8787/jobs/abc/artifacts/2/files/app.css")
        #expect(cssRequest.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "room-token")

        // 他の仕事や API は中継しない（トークン付きオープンプロキシにしない）。
        let otherJob = try #require(URL(string: "mihari-preview://room/jobs/other/artifacts/2/files/"))
        #expect(fetcher.request(forScheme: otherJob) == nil)
        let jobAPI = try #require(URL(string: "mihari-preview://room/jobs/abc"))
        #expect(fetcher.request(forScheme: jobAPI) == nil)
        let traversal = try #require(URL(string: "mihari-preview://room/jobs/abc/artifacts/2/files/../secret"))
        #expect(fetcher.request(forScheme: traversal) == nil)
    }

    // MARK: - 「この版から修正」の流れ

    @Test("修正対象を固定すると復元 → 追記の順で送る")
    func fixFromVersionRestoresThenFollowsUp() async throws {
        let access = StubRoomAccess()
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                status: "done",
                artifacts: [
                    RoomArtifact(artifactID: "art-abc-v1", version: "1", visibility: "private")
                ]
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(jobID: "abc", title: "掃除")
        defer { monitor.stopAll() }
        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "abc")

        model.comment = "色を直して"
        model.toggleFixSelection(version: "1")
        #expect(model.selectedFixVersion == "1")
        #expect(model.canSubmitComment == true)

        await model.submitComment()

        #expect(access.restoreCalls.map { "\($0.0):\($0.1)" } == ["abc:1"])
        #expect(access.followupCalls == ["abc"])
        #expect(model.selectedFixVersion == nil)
        #expect(model.notice?.contains("指摘を送ったよ") == true)
    }

    @Test("実行中の仕事は修正対象を固定したまま送れない（復元不可）")
    func fixFromVersionIsBlockedWhileRunning() async throws {
        let access = StubRoomAccess()
        access.detailResults = [
            "abc": RoomJobDetail(
                jobID: "abc",
                status: "running",
                artifacts: [
                    RoomArtifact(artifactID: "art-abc-v1", version: "1", visibility: "private")
                ]
            )
        ]
        let monitor = RoomJobMonitor(access: access, cursorStore: makeStore())
        monitor.attach(
            detail: RoomJobDetail(
                jobID: "abc",
                title: "掃除",
                status: "running",
                artifacts: [
                    RoomArtifact(artifactID: "art-abc-v1", version: "1", visibility: "private")
                ]
            )
        )
        defer { monitor.stopAll() }
        let model = RoomJobDetailViewModel(monitor: monitor, jobID: "abc")
        model.comment = "直して"
        model.toggleFixSelection(version: "1")

        #expect(model.canSubmitComment == false)
        // 実行中は送らない（復元も呼ばれない）。
        await model.submitComment()
        #expect(access.restoreCalls.isEmpty)
        #expect(access.followupCalls.isEmpty)

        // 修正対象を固定しなければ、通常の追記は実行中でも送れる。
        model.toggleFixSelection(version: "1")
        #expect(model.canSubmitComment == true)
        await model.submitComment()
        #expect(access.followupCalls == ["abc"])
        #expect(access.restoreCalls.isEmpty)
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
}
