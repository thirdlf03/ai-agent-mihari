import Foundation
import LocalAuthentication
import SwiftUI

/// 在席スタンプ画面の状態。
///
/// `PermissionsModel` / `DaemonController` と同じ形で、実際に副作用を起こす処理
/// (`TouchIDAuthenticating` / `AttendanceStore`)を注入できるようにしている。
@MainActor
public final class AttendanceModel: ObservableObject {

    /// 認証ダイアログに出す理由文言。
    public static let authenticationReason = "在席スタンプを押します"

    @Published public private(set) var stamps: [AttendanceStamp] = []
    @Published public private(set) var biometryTypeText: String = "未確認"
    @Published public private(set) var isBiometricsAvailable = false
    @Published public private(set) var isDeviceOwnerAvailable = false
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var isAuthenticating = false

    private let store: AttendanceStore
    private let authenticator: TouchIDAuthenticating
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: スタンプ履歴の永続化。テストでは空の `UserDefaults` を渡す。
    ///   - authenticator: 実際に Touch ID を叩く処理。テストではスタブに差し替えて、
    ///     テスト実行だけで認証ダイアログが出ないようにする。
    ///   - now: 現在時刻の取得。テストでは固定時刻を返す関数に差し替える。
    public init(
        store: AttendanceStore = AttendanceStore(),
        authenticator: TouchIDAuthenticating = LocalAuthenticationTouchIDAuthenticator(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.authenticator = authenticator
        self.now = now
        self.stamps = store.load()
    }

    /// `canEvaluatePolicy` を呼び直して、利用可否と biometryType を更新する。
    public func refreshAvailability() {
        let biometrics = authenticator.biometricsAvailability()
        isBiometricsAvailable = biometrics.canEvaluate
        biometryTypeText = BiometryDescription.text(for: biometrics.biometryType)

        let deviceOwner = authenticator.deviceOwnerAvailability()
        isDeviceOwnerAvailable = deviceOwner.canEvaluate
    }

    /// スタンプを押す。Touch ID が使えればそれで、使えなければパスワードにフォールバックする。
    ///
    /// 認証のキャンセル・失敗はどちらも `lastMessage` に文言を残すだけで、例外は投げない。
    public func stamp() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        refreshAvailability()
        guard isBiometricsAvailable || isDeviceOwnerAvailable else {
            lastMessage = "生体認証もパスワード認証も使えない"
            return
        }
        let policy: LAPolicy =
            isBiometricsAvailable ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication

        switch await authenticator.authenticate(policy: policy, reason: Self.authenticationReason) {
        case .success:
            let stamp = AttendanceStamp(stampedAt: now(), biometryTypeText: biometryTypeText)
            stamps = store.append(stamp, to: stamps)
            lastMessage = "スタンプを押した(\(biometryTypeText))"
        case .failure(let message):
            lastMessage = "認証に失敗: \(message)"
        }
    }

    /// 直近のスタンプから経過した秒数。1件もなければ `nil`。
    public var secondsSinceLastStamp: TimeInterval? {
        AttendanceGrace.secondsSinceLastStamp(stamps: stamps, now: now())
    }

    /// いま猶予期間中かどうか。
    public var isWithinGracePeriod: Bool {
        AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now())
    }

    /// 猶予の残り秒数。猶予期間外なら 0。
    public var graceRemainingSeconds: TimeInterval {
        AttendanceGrace.remainingGraceSeconds(stamps: stamps, now: now())
    }
}
