import LocalAuthentication

/// `LABiometryType` / 認証エラーを画面表示用の日本語に翻訳する純粋なロジック。
///
/// SaboriLab の `TouchIDModule.describe` を土台にしているが、こちらはログ用の英語コード名を
/// 出さず、ユーザーに見せてよい短い日本語だけを返す。
public enum BiometryDescription {

    /// 生体認証の種類を表示用の文言にする。
    public static func text(for type: LABiometryType) -> String {
        switch type {
        case .none: return "生体認証なし"
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        @unknown default: return "不明な生体認証(raw=\(type.rawValue))"
        }
    }

    /// 認証失敗の理由を人に見せる文言にする。
    ///
    /// `LAError` 以外(OS 側の一般エラーなど)は `localizedDescription` にフォールバックする。
    public static func text(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain, let code = LAError.Code(rawValue: nsError.code) else {
            return nsError.localizedDescription
        }
        return text(for: code) ?? nsError.localizedDescription
    }

    private static func text(for code: LAError.Code) -> String? {
        switch code {
        case .userCancel: return "キャンセルされた"
        case .userFallback: return "パスワード入力が選ばれた"
        case .systemCancel: return "システムに中断された"
        case .appCancel: return "アプリの都合で中断された"
        case .passcodeNotSet: return "Mac にパスワードが設定されていない"
        case .biometryNotAvailable: return "この Mac では生体認証が使えない"
        case .biometryNotEnrolled: return "指紋 / 顔が登録されていない"
        case .biometryLockout: return "失敗が続いたためロックされた。パスワードで解除する"
        case .authenticationFailed: return "認証に失敗した"
        default: return nil
        }
    }
}
