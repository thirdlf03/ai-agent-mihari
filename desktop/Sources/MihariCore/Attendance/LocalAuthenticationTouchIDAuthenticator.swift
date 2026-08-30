import Foundation
import LocalAuthentication
import os

/// `TouchIDAuthenticating` の本番実装。SaboriLab の `TouchIDModule` で検証済みの
/// `LAContext` の使い方をそのまま踏襲する。
///
/// 時間切れでダイアログを閉じられるよう、進行中の `LAContext` を持つ。`LAContext` は
/// `Sendable` ではないので、値の出し入れは `NSLock` で守り `@unchecked Sendable` にしている。
public final class LocalAuthenticationTouchIDAuthenticator: TouchIDAuthenticating, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "touch-id")

    private let lock = NSLock()
    /// 出しているダイアログの `LAContext`。出していなければ `nil`。
    private var activeContext: LAContext?

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
        lock.withLock { activeContext = context }
        defer {
            // 自分が置いたものだけ片付ける。次の認証が始まっていたらそちらを消さない。
            lock.withLock {
                if activeContext === context { activeContext = nil }
            }
        }
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

    /// 出したままのダイアログを閉じる。`evaluatePolicy` は `LAError.appCancel` の失敗として返る。
    public func cancelAuthentication() {
        let context = lock.withLock { () -> LAContext? in
            let current = activeContext
            activeContext = nil
            return current
        }
        guard let context else { return }
        Self.logger.info("Touch ID の認証を打ち切った")
        context.invalidate()
    }
}
