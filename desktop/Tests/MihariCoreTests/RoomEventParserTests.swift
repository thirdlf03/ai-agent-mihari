import Foundation
import Testing

@testable import MihariCore

/// SSE のフレームから部屋のイベントを組み立て、位相・種類・進捗を正しく取り出せるか。
@Suite("部屋のイベントの解釈")
struct RoomEventParserTests {

    /// フレームの JSON 文字列を 1 イベントに解釈する。
    private func decode(_ json: String) throws -> RoomEvent {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(RoomEvent.self, from: data)
    }

    @Test("契約どおりのイベントを読む")
    func decodesFullEvent() throws {
        let event = try decode(
            #"{"id":"ev-1","job_id":"abc","phase":"researching","kind":"speech","text":"調べている","progress":12,"created_at":"2026-01-02T03:04:05Z"}"#
        )
        #expect(event.id == "ev-1")
        #expect(event.jobID == "abc")
        #expect(event.phase == .researching)
        #expect(event.kind == .speech)
        #expect(event.text == "調べている")
        #expect(event.progress == 12)
        #expect(event.createdAt != nil)
    }

    @Test("progress が null でも読める")
    func progressNull() throws {
        let event = try decode(#"{"id":"ev-2","job_id":"abc","phase":"queued","text":"始める","progress":null}"#)
        #expect(event.progress == nil)
    }

    @Test("progress が無くても読める")
    func progressMissing() throws {
        let event = try decode(#"{"id":"ev-3","job_id":"abc","phase":"done","text":"完了"}"#)
        #expect(event.progress == nil)
        #expect(event.kind == nil)
    }

    @Test("知らない位相は黙って nil になる")
    func unknownPhaseBecomesNil() throws {
        let event = try decode(#"{"id":"ev-4","job_id":"abc","phase":"teleporting","kind":"speech","text":"?"}"#)
        #expect(event.phase == nil)
    }

    @Test("知らない種類も黙って nil になる")
    func unknownKindBecomesNil() throws {
        let event = try decode(#"{"id":"ev-5","job_id":"abc","phase":"waiting","kind":"mystery","text":"?"}"#)
        #expect(event.kind == nil)
    }

    @Test("足りないフィールドは読める(追加フィールドは無視する)")
    func toleratesMissingAndExtraFields() throws {
        let event = try decode(
            #"{"id":"ev-6","job_id":"abc","phase":"building","kind":"log","text":"","extra_thing":{"a":1},"progress":50}"#
        )
        #expect(event.phase == .building)
        #expect(event.kind == .log)
        #expect(event.text == "")
        #expect(event.progress == 50)
    }

    @Test("id が無いイベントは本文と時刻から合成する")
    func synthesizesIDWhenMissing() throws {
        let first = try decode(
            #"{"job_id":"abc","phase":"queued","kind":"speech","text":"同じ本文","created_at":"2026-01-02T03:04:05Z"}"#
        )
        let second = try decode(
            #"{"job_id":"abc","phase":"queued","kind":"speech","text":"同じ本文","created_at":"2026-01-02T03:04:05Z"}"#
        )
        #expect(!first.id.isEmpty)
        #expect(first.id == second.id)
    }

    @Test("created_at が解釈できなければ nil にする")
    func unparseableDateBecomesNil() throws {
        let event = try decode(#"{"id":"ev-7","job_id":"abc","text":"","created_at":"昨日"}"#)
        #expect(event.createdAt == nil)
    }

    @Test("成果物を読む")
    func decodesArtifact() throws {
        let data = try #require(
            #"{"id":"art-1","job_id":"abc","session_id":"s1","version":3,"kind":"report","preview_url":"https://example.com/r.pdf","expires_at":"2026-02-03T04:05:06Z","sha256":"abcd","source_ids":["ev-1","ev-2"]}"#
                .data(using: .utf8)
        )
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: data)
        #expect(artifact.artifactID == "art-1")
        #expect(artifact.jobID == "abc")
        #expect(artifact.sessionID == "s1")
        #expect(artifact.version == "3")
        #expect(artifact.kind == "report")
        #expect(artifact.previewURL?.absoluteString == "https://example.com/r.pdf")
        #expect(artifact.sha256 == "abcd")
        #expect(artifact.sourceIDs == ["ev-1", "ev-2"])
        #expect(artifact.id == "art-1-v3")
    }

    @Test("仕事の詳細に一時デプロイを読む")
    func decodesTempDeploy() throws {
        let data = try #require(
            #"{"job_id":"abc","temp_deploys":[{"preview_url":"https://w.example.workers.dev","claim_url":"https://dash.cloudflare.com/claim-preview?claimToken=x"}]}"#
                .data(using: .utf8)
        )
        let detail = try JSONDecoder().decode(RoomJobDetail.self, from: data)
        #expect(detail.tempDeploys.count == 1)
        #expect(detail.tempDeploys[0].previewURL?.host == "w.example.workers.dev")
        #expect(detail.tempDeploys[0].claimURL?.absoluteString.contains("claimToken") == true)
    }

    @Test("仕事の詳細を読む")
    func decodesJobDetail() throws {
        let data = try #require(
            #"{"job_id":"abc","title":"掃除","status":"done","thread_id":7,"session_id":"s1","artifacts":[{"id":"art-1","kind":"report"}],"latest_event":{"id":"ev-9","job_id":"abc","phase":"done","kind":"summary","text":"完了した"}}"#
                .data(using: .utf8)
        )
        let detail = try JSONDecoder().decode(RoomJobDetail.self, from: data)
        #expect(detail.jobID == "abc")
        #expect(detail.title == "掃除")
        #expect(detail.status == "done")
        #expect(detail.threadID == 7)
        #expect(detail.sessionID == "s1")
        #expect(detail.artifacts.count == 1)
        #expect(detail.latestEvent?.phase == .done)
    }

    @Test("`/jobs/running` の応答を読む")
    func decodesRunningResponse() throws {
        let data = try #require(
            #"{"jobs":[{"job_id":"abc","status":"running"},{"job_id":"def"}]}"#.data(using: .utf8)
        )
        let response = try JSONDecoder().decode(RoomJobsResponse.self, from: data)
        #expect(response.jobs.map(\.jobID) == ["abc", "def"])
    }

    @Test("位相のラベルは日本語")
    func phaseLabels() {
        #expect(RoomJobPhase.queued.label == "待ち")
        #expect(RoomJobPhase.done.label == "完了")
        #expect(RoomJobPhase.failed.label == "失敗")
    }
}
