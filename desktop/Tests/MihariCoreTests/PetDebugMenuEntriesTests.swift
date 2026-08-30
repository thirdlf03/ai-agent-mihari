import Foundation
import Testing

@testable import MihariCore

/// デバッグメニューの項目が、狙ったとおりにペットを動かすかを検証する。
/// `show()` を呼ばなければウィンドウは作られないので、結果は `lastDirective` などで確かめる。
@Suite("デバッグメニューの項目")
@MainActor
struct PetDebugMenuEntriesTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.petDebugMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    /// 並びの中から、サブメニューも含めてタイトルの一致する項目を探す。
    private func findItem(_ title: String, in entries: [PetMenuEntry]) -> (@MainActor () -> Void)? {
        for entry in entries {
            switch entry {
            case .item(let itemTitle, _, let action):
                if itemTitle == title { return action }
            case .submenu(_, let children):
                if let action = findItem(title, in: children) { return action }
            case .separator:
                continue
            }
        }
        return nil
    }

    /// タイトルの一致する項目の action を呼ぶ。見つからなければテストを失敗させる。
    private func tap(_ title: String, in entries: [PetMenuEntry]) {
        guard let action = findItem(title, in: entries) else {
            Issue.record("「\(title)」の項目が見つからない")
            return
        }
        action()
    }

    /// タイトルの一致するサブメニューを探す。
    private func findSubmenu(_ title: String, in entries: [PetMenuEntry]) -> [PetMenuEntry]? {
        for entry in entries {
            if case .submenu(let submenuTitle, let children) = entry, submenuTitle == title {
                return children
            }
        }
        return nil
    }

    /// 項目のタイトルだけを、区切り線を飛ばして並び順に取り出す。
    private func itemTitles(_ entries: [PetMenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let title, _, _) = entry { return title }
            return nil
        }
    }

    /// チェックの付いている項目のタイトルだけを並び順に取り出す。
    private func checkedTitles(_ entries: [PetMenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let title, let isChecked, _) = entry, isChecked { return title }
            return nil
        }
    }

    @Test("「アニメーションを固定」は固定を解く項目と 9 種を定義順に並べる")
    func fixedAnimationSubmenuListsEveryAnimation() throws {
        let presenter = makePresenter()
        let entries = PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter)

        let submenu = try #require(findSubmenu("アニメーションを固定", in: entries))
        let titles = itemTitles(submenu)

        #expect(titles.count == PetAnimation.allCases.count + 1)
        #expect(titles.first == "固定しない(自律行動)")
        #expect(
            Array(titles.dropFirst())
                == PetAnimation.allCases.map { "\($0.rawValue)(\($0.debugLabel))" }
        )
    }

    @Test("「検知の状態を再現」は新フローの 6 状態を並べる")
    func detectionStateSubmenuFollowsTheNewFlow() throws {
        let presenter = makePresenter()
        let entries = PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter)

        let submenu = try #require(findSubmenu("検知の状態を再現", in: entries))

        #expect(
            itemTitles(submenu).prefix(6)
                == ["正常に戻す", "疑い 1(Touch ID)", "疑い 2(首振り)", "疑い 3(最終警告)", "晒し", "メンヘラ"]
        )
    }

    @Test("「疑い 1(Touch ID)」で waiting に固定する")
    func suspectedEntryFixesWaiting() {
        let presenter = makePresenter()

        tap("疑い 1(Touch ID)", in: PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter))

        #expect(presenter.state == .suspected)
        #expect(presenter.lastDirective.fixedAnimation == .waiting)
    }

    @Test("「晒し」で failed に固定して 1 回跳ねる")
    func exposingEntryFixesFailedAndJumps() {
        let presenter = makePresenter()

        tap("晒し", in: PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter))

        #expect(presenter.lastDirective.fixedAnimation == .failed)
        #expect(presenter.lastDirective.playOnce == .jumping)
    }

    @Test("「実際に進める」は検知エンジンへの操作をそのまま並べて投げる")
    func realStepsSubmenuForwardsToTheEngine() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        let entries = PetDebugMenuEntries.make(actions: actions, presenter: presenter)

        let submenu = try #require(findSubmenu("実際に進める(撮影・投稿あり)", in: entries))
        #expect(itemTitles(submenu) == DetectionDebugStep.allCases.map(\.title))

        tap(DetectionDebugStep.expose.title, in: entries)
        #expect(actions.detectionSteps == [.expose])
    }

    @Test("問いかけを出して、閉じる項目で捨てる")
    func promptEntryShowsAndDismissesPrompt() {
        let presenter = makePresenter()

        tap("問いかけ(はい / いいえ)", in: PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter))
        #expect(presenter.pendingPrompt != nil)

        tap("問いかけを閉じる", in: PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter))
        #expect(presenter.pendingPrompt == nil)
    }

    @Test("「音声」は 2 つのモードを並べ、押すと切り替わる")
    func voiceModeEntriesSwitchTheMode() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let submenu = try #require(
            findSubmenu("音声", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(itemTitles(submenu) == VoiceMode.allCases.map(\.label))

        tap(VoiceMode.live.label, in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        #expect(actions.voiceMode == .live)
    }

    @Test("「検知の閾値」は標準 / 短縮を並べ、いまの preset にチェックを付ける")
    func thresholdPresetEntriesSwitchThePreset() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let submenu = try #require(
            findSubmenu("検知の閾値", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(itemTitles(submenu) == PetDebugMenuEntries.thresholdPresets.map(\.title))
        #expect(checkedTitles(submenu) == ["標準(疑い 60 秒 / 段ごと 30 秒)"])

        tap(
            "短縮(疑い 15 秒 / 段ごと 10 秒・デモ用)",
            in: PetDebugMenuEntries.make(actions: actions, presenter: presenter)
        )
        #expect(actions.isFastThresholds)

        let afterSwitch = try #require(
            findSubmenu("検知の閾値", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(checkedTitles(afterSwitch) == ["短縮(疑い 15 秒 / 段ごと 10 秒・デモ用)"])
    }

    @Test("「集中継続の間隔」は 15 分 / 1 分を切り替える")
    func focusStreakIntervalEntriesSwitchTheInterval() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let submenu = try #require(
            findSubmenu("集中継続の間隔", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(itemTitles(submenu) == ["15 分", "1 分"])

        tap("1 分", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))
        #expect(actions.focusStreakIntervalSeconds == 60)
    }

    @Test("「集中継続のセリフを再現」で褒めるセリフを呼び出す")
    func focusStreakReplayEntryCallsBack() {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        tap("集中継続のセリフを再現", in: PetDebugMenuEntries.make(actions: actions, presenter: presenter))

        #expect(actions.focusStreakReplays == 1)
    }

    @Test("アニメーションの固定と解除がコントローラに伝わる")
    func fixedAnimationEntriesUpdateController() throws {
        let presenter = makePresenter()

        // 「1 回だけ再生」にも同じタイトルの項目があるので、固定する方のサブメニューに絞って押す。
        func fixedAnimationSubmenu() throws -> [PetMenuEntry] {
            try #require(
                findSubmenu(
                    "アニメーションを固定",
                    in: PetDebugMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter)
                )
            )
        }

        tap("waiting(待つ)", in: try fixedAnimationSubmenu())
        #expect(presenter.controller.fixedAnimation == .waiting)

        tap("固定しない(自律行動)", in: try fixedAnimationSubmenu())
        #expect(presenter.controller.fixedAnimation == nil)
    }
}
