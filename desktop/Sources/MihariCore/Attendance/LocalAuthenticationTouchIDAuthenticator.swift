import LocalAuthentication
import os

/// `TouchIDAuthenticating` の本番実装。SaboriLab の `TouchIDModule` で検証済みの
/// `LAContext` の使い方をそのまま踏襲する。
public struct LocalAuthenticationTouchIDAuthenticator: TouchIDAuthenticating {
    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "touch-id")

    public init() {}

    public func biometricsAvailability() -> TouchIDAvailability {
        availability(for: .deviceOwnerAuthenticationWithBiometrics)
    }

    public func deviceOwnerAvailability() -> TouchIDAvailability {
        availability(for: .deviceOwnerAuthentication)
    }

    private func availability(for policy: LAPolicy) -> TouchIDAvailability {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(policy, error: &error)
        // biometryType は canEvaluatePolicy を呼んだあとでないと正しい値にならない。
        return TouchIDAvailability(canEvaluate: canEvaluate, biometryType: context.biometryType, error: error)
    }

    public func authenticate(policy: LAPolicy, reason: String) async -> TouchIDAuthenticationResult {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    Self.logger.info("Touch ID 認証に成功した")
                    continuation.resume(returning: .success)
                    return
                }
                let message = error.map(BiometryDescription.text(for:)) ?? "エラーなしで失敗"
                Self.logger.info("Touch ID 認証に失敗した: \(message, privacy: .public)")
                continuation.resume(returning: .failure(message: message))
            }
        }
    }
}
