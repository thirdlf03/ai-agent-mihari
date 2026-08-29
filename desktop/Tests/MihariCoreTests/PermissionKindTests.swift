import Testing

@testable import MihariCore

@Suite("権限の定義")
struct PermissionKindTests {

    @Test("すべての権限に表示用の文言が揃っている")
    func metadataIsComplete() {
        for kind in PermissionKind.allCases {
            #expect(!kind.title.isEmpty, "title がない: \(kind.rawValue)")
            #expect(!kind.purpose.isEmpty, "purpose がない: \(kind.rawValue)")
            #expect(!kind.api.isEmpty, "api がない: \(kind.rawValue)")
            #expect(!kind.consequenceIfDenied.isEmpty, "consequenceIfDenied がない: \(kind.rawValue)")
        }
    }

    @Test("権限ごとに開くシステム設定のペインが重複しない")
    func panesAreDistinct() {
        let panes = PermissionKind.allCases.map(\.pane)
        #expect(Set(panes).count == panes.count)
    }

    @Test("オートメーションだけはアプリから要求できない")
    func onlyAutomationHasNoRequestButton() {
        for kind in PermissionKind.allCases {
            if kind == .automation {
                #expect(kind.requestButtonTitle == nil)
            } else {
                #expect(kind.requestButtonTitle != nil, "要求ボタンがない: \(kind.rawValue)")
            }
        }
    }
}

@Suite("必須と任意の切り分け")
struct RequiredPermissionTests {

    @Test("必須は 4 つ、任意は 2 つ")
    func requiredCount() {
        #expect(PermissionKind.required == [.camera, .microphone, .screenRecording, .inputMonitoring])
        #expect(PermissionKind.allCases.filter { !$0.isRequired } == [.automation, .motion])
    }

    @Test("必須の権限はアプリからプロンプトを出せる")
    func requiredKindsAreRequestable() {
        for kind in PermissionKind.required {
            #expect(kind.requestButtonTitle != nil, "要求できない権限を必須にしている: \(kind.rawValue)")
        }
    }
}

@Suite("初回起動でまとめ要求する権限")
struct RequestableOnLaunchTests {

    @Test("まとめ要求の対象はアプリから要求できる権限だけ")
    func onlyRequestableKinds() {
        for kind in PermissionKind.requestableOnLaunch {
            #expect(kind.requestButtonTitle != nil, "要求できない権限が混ざっている: \(kind.rawValue)")
        }
    }

    @Test("AirPods が要るモーションはまとめ要求に含めない")
    func motionIsExcluded() {
        #expect(!PermissionKind.requestableOnLaunch.contains(.motion))
        #expect(!PermissionKind.requestableOnLaunch.contains(.automation))
    }
}
