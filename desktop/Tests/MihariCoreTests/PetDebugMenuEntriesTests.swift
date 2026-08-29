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

    @Test("「アニメーションを固定」は固定を解く項目と 9 種を定義順に並べる")
    func fixedAnimationSubmenuListsEveryAnimation() throws {
        let presenter = makePresenter()
        let entries = PetDebugMenuEntries.make(presenter: presenter)

        let submenu = try #require(findSubmenu("アニメーションを固定", in: entries))
        let titles = itemTitles(submenu)

        #expect(titles.count == PetAnimation.allCases.count + 1)
        #expect(titles.first == "固定しない(自律行動)")
        #expect(
            Array(titles.dropFirst())
                == PetAnimation.allCases.map { "\($0.rawValue)(\($0.debugLabel))" }
        )
    }

    @Test("「疑い(段階 1)」で waiting に固定する")
    func suspectedEntryFixesWaiting() {
        let presenter = makePresenter()

        tap("疑い(段階 1)", in: PetDebugMenuEntries.make(presenter: presenter))

        #expect(presenter.state == .suspected)
        #expect(presenter.lastDirective.fixedAnimation == .waiting)
    }

    @Test("「サボり確定・撮影(段階 3)」で failed に固定して 1 回跳ねる")
    func confirmedEntryFixesFailedAndJumps() {
        let presenter = makePresenter()

        tap("サボり確定・撮影(段階 3)", in: PetDebugMenuEntries.make(presenter: presenter))

        #expect(presenter.lastDirective.fixedAnimation == .failed)
        #expect(presenter.lastDirective.playOnce == .jumping)
    }

    @Test("問いかけを出して、閉じる項目で捨てる")
    func promptEntryShowsAndDismissesPrompt() {
        let presenter = makePresenter()

        tap("問いかけ(はい / いいえ)", in: PetDebugMenuEntries.make(presenter: presenter))
        #expect(presenter.pendingPrompt != nil)

        tap("問いかけを閉じる", in: PetDebugMenuEntries.make(presenter: presenter))
        #expect(presenter.pendingPrompt == nil)
    }

    @Test("アニメーションの固定と解除がコントローラに伝わる")
    func fixedAnimationEntriesUpdateController() throws {
        let presenter = makePresenter()

        // 「1 回だけ再生」にも同じタイトルの項目があるので、固定する方のサブメニューに絞って押す。
        func fixedAnimationSubmenu() throws -> [PetMenuEntry] {
            try #require(findSubmenu("アニメーションを固定", in: PetDebugMenuEntries.make(presenter: presenter)))
        }

        tap("waiting(待つ)", in: try fixedAnimationSubmenu())
        #expect(presenter.controller.fixedAnimation == .waiting)

        tap("固定しない(自律行動)", in: try fixedAnimationSubmenu())
        #expect(presenter.controller.fixedAnimation == nil)
    }
}
