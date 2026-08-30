import LocalAuthentication

/// ポリシー1件分の利用可否。`canEvaluatePolicy` の結果をそのまま持つ。
public struct TouchIDAvailability: Sendable {
    public let canEvaluate: Bool
    public let biometryType: LABiometryType
    public let error: Error?

    public init(canEvaluate: Bool, biometryType: LABiometryType, error: Error?) {
        self.canEvaluate = canEvaluate
        self.biometryType = biometryType
        self.error = error
    }
}

/// 認証ダイアログを出した結果。
public enum TouchIDAuthenticationResult: Sendable {
    case success
    case failure(message: String)
}

/// `LocalAuthentication` を抽象化するプロトコル。
///
/// `LAContext` を直接呼ぶ実装は `LocalAuthenticationTouchIDAuthenticator` に閉じ込め、
/// テストではこのプロトコルをスタブに差し替えることで、実際に Touch ID のダイアログを
/// 出さずに `AttendanceModel` の分岐を検証できるようにする。
public protocol TouchIDAuthenticating: Sendable {
    /// 生体認証(Touch ID / Face ID)だけで認証できるか。
    func biometricsAvailability() -> TouchIDAvailability
    /// 生体認証が使えないときに、パスワードへのフォールバックを含めて認証できるか。
    func deviceOwnerAvailability() -> TouchIDAvailability
    /// 実際に認証ダイアログを出す。
    func authenticate(policy: LAPolicy, reason: String) async -> TouchIDAuthenticationResult
    /// 出したままの認証ダイアログを閉じる。時間切れで打ち切るときに呼ぶ。
    ///
    /// 閉じられた `authenticate(policy:reason:)` は失敗として返ってくる。
    /// 認証が動いていなければ何もしない。
    func cancelAuthentication()
}
