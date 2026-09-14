import AppKit
import Foundation
import Testing

@testable import MihariCore

/// 許可ダイアログ（AlertMacControlPermissionDecider）の応答と
/// 「今後は確認せず許可する」の保存・読み込みを確かめる。実際のアラートは出さない。
@Suite("Mac 操作許可の確認")
@MainActor
struct MacControlPermissionDeciderTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が常時許可を共有しないようにする。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.macControlPermission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeRequest() -> MacControlRequest {
        MacControlRequest(
            requestID: "r1",
            jobID: "job-1",
            runID: "run-1",
            jobTitle: "画面を触って",
            scope: "whole_mac",
            note: "この依頼の間だけ"
        )
    }

    @Test("常時許可が保存されていればアラートを出さず許可する")
    func alwaysAllowSkipsAlert() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AlertMacControlPermissionDecider.alwaysAllowKey)
        var alertRuns = 0
        let decider = AlertMacControlPermissionDecider(defaults: defaults) { _ in
            alertRuns += 1
            // 呼ばれたら拒否を返す。結果が許可ならアラートを出していない証拠になる。
            return .alertFirstButtonReturn
        }

        let decision = await decider.decide(request: makeRequest())

        #expect(decision == .allow)
        #expect(alertRuns == 0)
    }

    @Test("許可 + 「今後は確認せず許可する」で常時許可を保存する")
    func allowWithSuppressionSavesFlag() async {
        let defaults = makeDefaults()
        var suppressionSeen = false
        let decider = AlertMacControlPermissionDecider(defaults: defaults) { alert in
            suppressionSeen = alert.showsSuppressionButton
                && alert.suppressionButton?.title == "今後は確認せず許可する"
            alert.suppressionButton?.state = .on
            return .alertSecondButtonReturn
        }

        let decision = await decider.decide(request: makeRequest())

        #expect(decision == .allow)
        #expect(suppressionSeen)
        #expect(defaults.bool(forKey: AlertMacControlPermissionDecider.alwaysAllowKey))
    }

    @Test("チェックなしの許可は常時許可を保存しない")
    func allowWithoutSuppressionDoesNotSave() async {
        let defaults = makeDefaults()
        let decider = AlertMacControlPermissionDecider(defaults: defaults) { alert in
            alert.suppressionButton?.state = .off
            return .alertSecondButtonReturn
        }

        let decision = await decider.decide(request: makeRequest())

        #expect(decision == .allow)
        #expect(!defaults.bool(forKey: AlertMacControlPermissionDecider.alwaysAllowKey))
    }

    @Test("拒否は常時許可を保存しない（チェックを付けても）")
    func denyDoesNotSaveFlag() async {
        let defaults = makeDefaults()
        let decider = AlertMacControlPermissionDecider(defaults: defaults) { alert in
            alert.suppressionButton?.state = .on
            return .alertFirstButtonReturn
        }

        let decision = await decider.decide(request: makeRequest())

        #expect(decision == .deny)
        #expect(!defaults.bool(forKey: AlertMacControlPermissionDecider.alwaysAllowKey))
    }

    @Test("保存されたあとは次の依頼からアラートを出さない")
    func savedFlagAppliesToNextRequest() async {
        let defaults = makeDefaults()
        var alertRuns = 0
        let decider = AlertMacControlPermissionDecider(defaults: defaults) { alert in
            alertRuns += 1
            alert.suppressionButton?.state = .on
            return .alertSecondButtonReturn
        }

        let first = await decider.decide(request: makeRequest())
        #expect(first == .allow)
        #expect(alertRuns == 1)

        let second = await decider.decide(request: makeRequest())
        #expect(second == .allow)
        #expect(alertRuns == 1)
    }
}
