import Foundation
import Testing

@testable import MihariCore

@Suite("オンボーディングの状態")
@MainActor
struct PermissionsModelTests {

    /// 実際の TCC プロンプトを出さない要求スタブ。呼ばれた権限を記録する。
    private final class RequestSpy: @unchecked Sendable {
        private(set) var requested: [PermissionKind] = []

        func request(_ kind: PermissionKind) async -> String {
            requested.append(kind)
            return "\(kind.title): stub"
        }
    }

    private func makeDefaults() -> UserDefaults {
        // 実行のたびに空の UserDefaults を使い、テスト同士が初回起動フラグを共有しないようにする。
        let suiteName = "mihari.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("初期状態ではすべて未チェックで、未許可として数えられる")
    func startsUnchecked() {
        let model = PermissionsModel(defaults: makeDefaults())
        #expect(model.lastCheckedAt == nil)
        for kind in PermissionKind.allCases {
            #expect(model.state(for: kind) == .unchecked)
        }
        #expect(model.pending.count == PermissionKind.allCases.count)
    }

    @Test("refresh すると全権限の状態が入り、チェック時刻が記録される")
    func refreshFillsEveryKind() {
        let model = PermissionsModel(defaults: makeDefaults())
        model.refresh()
        #expect(model.lastCheckedAt != nil)
        for kind in PermissionKind.allCases {
            #expect(model.state(for: kind) != .unchecked, "状態が入っていない: \(kind.rawValue)")
        }
    }

    @Test("初回起動のまとめ要求は一度きりで、2 回目以降は勝手にプロンプトを出さない")
    func firstLaunchRequestRunsOnce() async {
        let defaults = makeDefaults()
        #expect(defaults.bool(forKey: PermissionsModel.didRequestOnLaunchKey) == false)

        let spy = RequestSpy()
        let model = PermissionsModel(defaults: defaults, requestPermission: spy.request)
        await model.requestOnFirstLaunchIfNeeded()
        #expect(defaults.bool(forKey: PermissionsModel.didRequestOnLaunchKey) == true)
        #expect(!spy.requested.isEmpty)

        // 同じ defaults を引き継いだ別インスタンスでは、もう要求が走らない。
        let secondSpy = RequestSpy()
        let second = PermissionsModel(defaults: defaults, requestPermission: secondSpy.request)
        await second.requestOnFirstLaunchIfNeeded()
        #expect(secondSpy.requested.isEmpty)
        #expect(second.lastMessage == nil)
    }

    @Test("まとめ要求は許可済みの権限を飛ばす")
    func requestAllSkipsGranted() async {
        let spy = RequestSpy()
        let model = PermissionsModel(defaults: makeDefaults(), requestPermission: spy.request)
        model.refresh()

        let alreadyGranted = PermissionKind.requestableOnLaunch.filter { model.state(for: $0).grant == .granted }
        await model.requestAll()

        for kind in alreadyGranted {
            #expect(!spy.requested.contains(kind), "許可済みなのに要求した: \(kind.rawValue)")
        }
        #expect(model.lastMessage != nil)
    }
}
