import Foundation
import Testing

@testable import MihariCore

/// ペットメニューの並びが、そのときの状態をチェックに映すかを検証する。
@Suite("ペットメニューの並び")
@MainActor
struct PetMenuEntriesTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.petMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    /// タイトルの一致する項目を探す。
    private func findItem(
        _ title: String,
        in entries: [PetMenuEntry]
    ) -> (isChecked: Bool, action: @MainActor () -> Void)? {
        for entry in entries {
            if case .item(let itemTitle, let isChecked, let action) = entry, itemTitle == title {
                return (isChecked, action)
            }
        }
        return nil
    }

    @Test("「スクショに写り込む」のチェックは写り込みの入り / 切りを映し、押すと切り替わる")
    func photobombEntryReflectsAndTogglesTheSetting() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let enabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(enabled.isChecked)

        enabled.action()
        #expect(actions.isPhotobombEnabled == false)

        let disabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(disabled.isChecked == false)
    }

    @Test("「仕事を頼む…」は作業部屋のそばにあり、押すと依頼窓を開く")
    func jobRequestEntryOpensTheWindow() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let titles = titles(of: entries)
        // 仕事を頼む… の直後に作業部屋(仕事なし)を置き、その次に Discord 設定を置く。
        let jobIndex = try #require(titles.firstIndex(of: "仕事を頼む…"))
        let roomIndex = try #require(titles.firstIndex(of: "作業部屋(仕事なし)"))
        let discordIndex = try #require(titles.firstIndex(of: "Discord 設定…"))
        #expect(roomIndex == jobIndex + 1)
        #expect(discordIndex == roomIndex + 1)

        let item = try #require(findItem("仕事を頼む…", in: entries))
        item.action()
        #expect(actions.jobRequestOpens == 1)
    }

    @Test("作業部屋のサブメニューに仕事の状態と追記・中断・成果物が並ぶ")
    func roomSubmenuShowsJobAndActions() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.roomJob = RoomJobSummary(
            jobID: "abc",
            title: "掃除",
            status: .running,
            phase: .downloading,
            latestText: "取得している",
            artifacts: [
                RoomArtifact(artifactID: "art-1", kind: "report", previewURL: URL(string: "https://example.com/r.pdf")!)
            ],
            lastError: nil
        )

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let submenu = try #require(findSubmenu("作業部屋", in: entries))
        let titles = titles(of: submenu)
        #expect(titles.contains("状態: 掃除 — 作業中"))
        #expect(titles.contains("進捗: 取得している"))

        let followup = try #require(findItem("追記する…", in: submenu))
        followup.action()
        #expect(actions.roomFollowUps == 1)

        let cancel = try #require(findItem("中断する", in: submenu))
        cancel.action()
        #expect(actions.roomCancels == 1)

        let artifact = try #require(findItem("成果物を開く: report", in: submenu))
        artifact.action()
        #expect(actions.roomArtifactURLs == [URL(string: "https://example.com/r.pdf")!])
    }

    @Test("開けないプロトコルの成果物はメニューに載せない")
    func roomSubmenuSkipsNonHttpArtifacts() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.roomJob = RoomJobSummary(
            jobID: "abc",
            title: "掃除",
            status: .done,
            phase: .done,
            latestText: nil,
            artifacts: [
                RoomArtifact(artifactID: "art-1", kind: "local", previewURL: URL(string: "file:///tmp/out.pdf")!)
            ],
            lastError: nil
        )

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let submenu = try #require(findSubmenu("作業部屋", in: entries))
        let titles = titles(of: submenu)
        #expect(titles.contains("成果物なし"))
        #expect(!titles.contains("成果物を開く: local"))
    }

    @Test("仕事が無いときは作業部屋を押すと依頼窓を開く")
    func roomSubmenuWithoutJobOpensRequest() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let item = try #require(findItem("作業部屋(仕事なし)", in: entries))
        item.action()
        #expect(actions.jobRequestOpens == 1)
    }

    @Test("記憶の候補があれば件数と詳細への導線が出る")
    func roomSubmenuShowsMemoryPending() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.roomJob = RoomJobSummary(
            jobID: "abc",
            title: "掃除",
            status: .running,
            phase: .waiting,
            latestText: nil,
            artifacts: [],
            lastError: nil,
            memoryCandidates: [
                RoomMemoryCandidate(candidateID: "c1", target: "MEMORY.md", content: "深煎りが好き", status: "pending")
            ]
        )

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let submenu = try #require(findSubmenu("作業部屋", in: entries))
        let detail = try #require(findItem("詳細を開く…", in: submenu))
        detail.action()
        #expect(actions.roomDetailOpens == 1)
        let approve = try #require(findItem("承認: 深煎りが好き", in: submenu))
        approve.action()
        #expect(actions.approvedMemoryIDs == ["c1"])
        let reject = try #require(findItem("却下: 深煎りが好き", in: submenu))
        reject.action()
        #expect(actions.rejectedMemoryIDs == ["c1"])
        #expect(!titles(of: submenu).contains("記憶の候補: 1件待ち — 詳細で承認"))
    }

    @Test("成果物は version 付きで開き、ロールバックできる")
    func roomSubmenuShowsVersionedArtifacts() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.roomJob = RoomJobSummary(
            jobID: "abc",
            title: "掃除",
            status: .done,
            phase: .done,
            artifacts: [
                RoomArtifact(
                    artifactID: "art-abc-v1",
                    version: "1",
                    kind: "web",
                    previewURL: URL(string: "https://preview.example/a/")!
                ),
                RoomArtifact(
                    artifactID: "art-abc-v2",
                    version: "2",
                    kind: "web",
                    previewURL: URL(string: "https://preview.example/b/")!
                ),
            ]
        )

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let submenu = try #require(findSubmenu("作業部屋", in: entries))
        let titles = titles(of: submenu)
        #expect(titles.contains("v1 を開く"))
        #expect(titles.contains("v2 を開く"))
        #expect(titles.contains("v1 に戻す"))
        #expect(titles.contains("v2 に戻す"))

        let rollback = try #require(findItem("v1 に戻す", in: submenu))
        rollback.action()
        #expect(actions.rolledBackVersions == ["1"])
    }

    /// タイトルの一致するサブメニューを探す。
    private func findSubmenu(_ title: String, in entries: [PetMenuEntry]) -> [PetMenuEntry]? {
        for entry in entries {
            if case .submenu(let itemTitle, let inner) = entry, itemTitle == title {
                return inner
            }
        }
        return nil
    }

    /// 並びをタイトルの列に潰す。
    private func titles(of entries: [PetMenuEntry]) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case .item(let title, _, _): return title
            case .submenu(let title, _): return title
            case .separator: return nil
            }
        }
    }
}
