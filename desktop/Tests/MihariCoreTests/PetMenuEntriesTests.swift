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
