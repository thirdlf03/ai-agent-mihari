import Foundation
import LocalAuthentication
import SwiftUI

/// 在席スタンプを押した結末。演出(`AttendanceCeremonyScript`)はこれを見て結末を決める。
public enum AttendanceStampOutcome: Sendable, Equatable {
    /// 認証に成功して履歴が増えた。
    case stamped
    /// 認証に失敗した(キャンセル含む)。
    case failed
    /// 指を置かないまま時間切れになり、こちらからダイアログを閉じた。
    case timedOut
    /// 生体認証もパスワード認証も使えず、ダイアログを出せなかった。
    case unavailable
}

/// 在席スタンプ画面の状態。
///
/// `PermissionsModel` / `DaemonController` と同じ形で、実際に副作用を起こす処理
/// (`TouchIDAuthenticating` / `AttendanceStore`)を注入できるようにしている。
@MainActor
public final class AttendanceModel: ObservableObject {

    /// 認証ダイアログに出す理由文言。
    public static let authenticationReason = "在席スタンプを押します"

    /// 認証を打ち切るまでの秒数。指を置かないまま放置されたときに、
    /// ダイアログとカットインを出したままにしないための上限。
    ///
    /// 検知の閾値(`DetectionThresholds.touchIDTimeoutSeconds`)の既定値としても使うので、
    /// メインアクタの外からも読めるようにしてある。
    nonisolated public static let defaultAuthenticationTimeout: TimeInterval = 10

    @Published public private(set) var stamps: [AttendanceStamp] = []
    @Published public private(set) var biometryTypeText: String = "未確認"
    @Published public private(set) var isBiometricsAvailable = false
    @Published public private(set) var isDeviceOwnerAvailable = false
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var isAuthenticating = false

    private let store: AttendanceStore
    private let authenticator: TouchIDAuthenticating
    private let authenticationTimeout: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: スタンプ履歴の永続化。テストでは空の `UserDefaults` を渡す。
    ///   - authenticator: 実際に Touch ID を叩く処理。テストではスタブに差し替えて、
    ///     テスト実行だけで認証ダイアログが出ないようにする。
    ///   - authenticationTimeout: 認証を打ち切るまでの秒数。テストでは短くする。
    ///   - now: 現在時刻の取得。テストでは固定時刻を返す関数に差し替える。
    public init(
        store: AttendanceStore = AttendanceStore(),
        authenticator: TouchIDAuthenticating = LocalAuthenticationTouchIDAuthenticator(),
        authenticationTimeout: TimeInterval = AttendanceModel.defaultAuthenticationTimeout,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.authenticator = authenticator
        self.authenticationTimeout = authenticationTimeout
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
    /// 指を置かないまま `authenticationTimeout` 秒経ったら、こちらからダイアログを閉じて
    /// `.timedOut` を返す。
    @discardableResult
    public func stamp() async -> AttendanceStampOutcome {
        await authenticate(recording: true)
    }

    /// 指紋だけ確かめる。**履歴には残さない。**
    ///
    /// 疑い 1 の Touch ID チェックで使う。ここで猶予(`lastStampAt`)まで更新してしまうと、
    /// 見張りに促されて置いた指で 5 分間見逃されることになり、チェックの意味が無くなる。
    @discardableResult
    public func verify() async -> AttendanceStampOutcome {
        await authenticate(recording: false)
    }

    /// 出している認証ダイアログを閉じる。返事を待たずに畳むときに呼ぶ。
    ///
    /// 走っている `stamp()` / `verify()` は失敗として返ってくる。呼んだ側が結果を捨てる前提。
    public func cancelAuthentication() {
        guard isAuthenticating else { return }
        authenticator.cancelAuthentication()
    }

    /// 認証ダイアログを出して結末を返す。`recording` が true のときだけ履歴を増やす。
    private func authenticate(recording: Bool) async -> AttendanceStampOutcome {
        // 走っている認証があるうちは重ねて出さない。押した側からは空振りに見せる。
        guard !isAuthenticating else { return .failed }
        isAuthenticating = true
        defer { isAuthenticating = false }

        refreshAvailability()
        guard isBiometricsAvailable || isDeviceOwnerAvailable else {
            lastMessage = "生体認証もパスワード認証も使えない"
            return .unavailable
        }
        let policy: LAPolicy =
            isBiometricsAvailable ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication

        switch await authenticateWithTimeout(policy: policy) {
        case .authenticated(.success):
            guard recording else {
                lastMessage = "在席を確かめた(\(biometryTypeText))"
                return .stamped
            }
            let stamp = AttendanceStamp(stampedAt: now(), biometryTypeText: biometryTypeText)
            stamps = store.append(stamp, to: stamps)
            lastMessage = "スタンプを押した(\(biometryTypeText))"
            return .stamped
        case .authenticated(.failure(let message)):
            lastMessage = "認証に失敗: \(message)"
            return .failed
        case .timedOut:
            lastMessage = "認証が時間切れ(\(Self.secondsText(authenticationTimeout)) 秒)"
            return .timedOut
        }
    }

    /// 認証と時間切れの競争の結果。
    private enum AuthenticationRace {
        case authenticated(TouchIDAuthenticationResult)
        case timedOut
    }

    /// 認証ダイアログと `authenticationTimeout` 秒のタイマーを競争させる。
    ///
    /// 時間切れが先なら `cancelAuthentication()` でダイアログを閉じ、認証が返るのを待ってから
    /// `.timedOut` を返す(閉じたことによる失敗は演出に使わない)。認証が先に返ればタイマーを取り消す。
    private func authenticateWithTimeout(policy: LAPolicy) async -> AuthenticationRace {
        let authenticator = self.authenticator
        let reason = Self.authenticationReason
        let timeout = authenticationTimeout

        return await withTaskGroup(of: AuthenticationRace?.self, returning: AuthenticationRace.self) { group in
            group.addTask {
                .authenticated(await authenticator.authenticate(policy: policy, reason: reason))
            }
            group.addTask {
                // 取り消されたときは時間切れではないので、何も返さない。
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return nil }
                return .timedOut
            }

            var timedOut = false
            var authenticated: TouchIDAuthenticationResult?
            while authenticated == nil, let result = await group.next() {
                switch result {
                case .authenticated(let value):
                    authenticated = value
                case .timedOut:
                    timedOut = true
                    // ダイアログを閉じる。認証は失敗として返ってくるので、それを待ってから抜ける。
                    authenticator.cancelAuthentication()
                case nil:
                    break
                }
            }
            group.cancelAll()

            if let authenticated, !timedOut { return .authenticated(authenticated) }
            return .timedOut
        }
    }

    /// 時間切れの文言に出す秒数。10 は「10」、0.05 は「0.05」と書く。
    private static func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
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
