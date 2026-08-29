import Foundation
import LocalAuthentication
import Testing

@testable import MihariCore

@Suite("在席スタンプ画面の状態")
@MainActor
struct AttendanceModelTests {

    /// 実際の LocalAuthentication を呼ばないスタブ。呼ばれたポリシーを記録する。
    private final class StubAuthenticator: TouchIDAuthenticating, @unchecked Sendable {
        var biometrics: TouchIDAvailability
        var deviceOwner: TouchIDAvailability
        var authenticateResult: TouchIDAuthenticationResult
        private(set) var authenticateCalls: [LAPolicy] = []

        init(
            biometrics: TouchIDAvailability,
            deviceOwner: TouchIDAvailability,
            authenticateResult: TouchIDAuthenticationResult = .success
        ) {
            self.biometrics = biometrics
            self.deviceOwner = deviceOwner
            self.authenticateResult = authenticateResult
        }

        func biometricsAvailability() -> TouchIDAvailability { biometrics }
        func deviceOwnerAvailability() -> TouchIDAvailability { deviceOwner }

        func authenticate(policy: LAPolicy, reason: String) async -> TouchIDAuthenticationResult {
            authenticateCalls.append(policy)
            return authenticateResult
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.attendance-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func availability(canEvaluate: Bool, type: LABiometryType = .touchID) -> TouchIDAvailability {
        TouchIDAvailability(canEvaluate: canEvaluate, biometryType: type, error: nil)
    }

    @Test("Touch ID が使えるときはそのポリシーで認証し、成功したら履歴に残る")
    func stampSucceedsWithBiometrics() async {
        let authenticator = StubAuthenticator(
            biometrics: availability(canEvaluate: true, type: .touchID),
            deviceOwner: availability(canEvaluate: true, type: .touchID)
        )
        let model = AttendanceModel(store: AttendanceStore(defaults: makeDefaults()), authenticator: authenticator)

        await model.stamp()

        #expect(authenticator.authenticateCalls == [.deviceOwnerAuthenticationWithBiometrics])
        #expect(model.stamps.count == 1)
        #expect(model.stamps.first?.biometryTypeText == "Touch ID")
        #expect(model.lastMessage?.contains("スタンプを押した") == true)
    }

    @Test("Touch ID が使えなければパスワード認証にフォールバックする")
    func stampFallsBackToPasswordWhenBiometricsUnavailable() async {
        let authenticator = StubAuthenticator(
            biometrics: availability(canEvaluate: false, type: .none),
            deviceOwner: availability(canEvaluate: true, type: .none)
        )
        let model = AttendanceModel(store: AttendanceStore(defaults: makeDefaults()), authenticator: authenticator)

        await model.stamp()

        #expect(authenticator.authenticateCalls == [.deviceOwnerAuthentication])
        #expect(model.stamps.count == 1)
    }

    @Test("生体認証もパスワードも使えないときは認証を試みず、履歴も増えない")
    func stampDoesNothingWhenNoAuthenticationIsAvailable() async {
        let authenticator = StubAuthenticator(
            biometrics: availability(canEvaluate: false, type: .none),
            deviceOwner: availability(canEvaluate: false, type: .none)
        )
        let model = AttendanceModel(store: AttendanceStore(defaults: makeDefaults()), authenticator: authenticator)

        await model.stamp()

        #expect(authenticator.authenticateCalls.isEmpty)
        #expect(model.stamps.isEmpty)
        #expect(model.lastMessage != nil)
    }

    @Test("認証に失敗(キャンセル含む)しても履歴は増えず、アプリは落ちずにメッセージだけ残る")
    func stampFailureLeavesNoStampButSetsMessage() async {
        let authenticator = StubAuthenticator(
            biometrics: availability(canEvaluate: true, type: .touchID),
            deviceOwner: availability(canEvaluate: true, type: .touchID),
            authenticateResult: .failure(message: "キャンセルされた")
        )
        let model = AttendanceModel(store: AttendanceStore(defaults: makeDefaults()), authenticator: authenticator)

        await model.stamp()

        #expect(model.stamps.isEmpty)
        #expect(model.lastMessage?.contains("キャンセルされた") == true)
    }

    /// `@Sendable () -> Date` から書き換え可能にするための箱。テストでだけ時刻を進める。
    private final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ current: Date) { self.current = current }
    }

    @Test("スタンプ直後は猶予期間中になる")
    func gracePeriodStartsRightAfterStamp() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let authenticator = StubAuthenticator(
            biometrics: availability(canEvaluate: true, type: .touchID),
            deviceOwner: availability(canEvaluate: true, type: .touchID)
        )
        let model = AttendanceModel(
            store: AttendanceStore(defaults: makeDefaults()),
            authenticator: authenticator,
            now: { clock.current }
        )

        #expect(model.isWithinGracePeriod == false)
        await model.stamp()
        #expect(model.isWithinGracePeriod == true)

        clock.current = clock.current.addingTimeInterval(AttendanceGrace.defaultGracePeriod + 1)
        #expect(model.isWithinGracePeriod == false)
    }
}
