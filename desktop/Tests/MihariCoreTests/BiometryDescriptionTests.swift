import Foundation
import LocalAuthentication
import Testing

@testable import MihariCore

@Suite("biometryType / 認証エラーの表示文言への翻訳")
struct BiometryDescriptionTests {

    @Test(
        "biometryType の種類ごとに表示文言が決まっている",
        arguments: [
            (LABiometryType.none, "生体認証なし"),
            (LABiometryType.touchID, "Touch ID"),
            (LABiometryType.faceID, "Face ID"),
            (LABiometryType.opticID, "Optic ID"),
        ]
    )
    func biometryTypeText(type: LABiometryType, expected: String) {
        #expect(BiometryDescription.text(for: type) == expected)
    }

    @Test(
        "代表的な LAError はそれぞれ専用の文言になる",
        arguments: [
            (LAError.Code.userCancel, "キャンセルされた"),
            (LAError.Code.userFallback, "パスワード入力が選ばれた"),
            (LAError.Code.biometryNotEnrolled, "指紋 / 顔が登録されていない"),
            (LAError.Code.biometryLockout, "失敗が続いたためロックされた。パスワードで解除する"),
        ]
    )
    func laErrorText(code: LAError.Code, expected: String) {
        let error = NSError(domain: LAError.errorDomain, code: code.rawValue)
        #expect(BiometryDescription.text(for: error) == expected)
    }

    @Test("LAError 以外は localizedDescription にフォールバックする")
    func nonLAErrorFallsBackToLocalizedDescription() {
        let error = NSError(domain: "com.example.other", code: 1, userInfo: [NSLocalizedDescriptionKey: "テスト用エラー"])
        #expect(BiometryDescription.text(for: error) == "テスト用エラー")
    }
}
