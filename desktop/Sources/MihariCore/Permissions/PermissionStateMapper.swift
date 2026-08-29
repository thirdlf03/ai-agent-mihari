import AVFoundation
import CoreMotion
import Foundation
import IOKit.hidsystem

/// 各 API が返す生の値を `PermissionState` に翻訳する。
///
/// 実際に OS を叩く処理とは分けてある。API ごとに「未決定」の表し方が違い、
/// ここを取り違えると許可済みを未許可と誤判定するため、単体テストで固定したい。
public enum PermissionStateMapper {

    /// カメラ / マイクの `AVAuthorizationStatus`。
    public static func from(authorization status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            return PermissionState(grant: .granted, detail: "authorized (許可)")
        case .denied:
            return PermissionState(grant: .denied, detail: "denied (拒否)")
        case .restricted:
            return PermissionState(grant: .denied, detail: "restricted (制限)")
        case .notDetermined:
            return PermissionState(grant: .undetermined, detail: "notDetermined (未決定)")
        @unknown default:
            return PermissionState(grant: .undetermined, detail: "unknown (raw=\(status.rawValue))")
        }
    }

    /// 画面収録。`CGPreflightScreenCaptureAccess()` は Bool しか返さず、
    /// 「未決定」と「拒否済み」を区別できない。false は一律 undetermined として扱う。
    public static func fromScreenRecording(preflight granted: Bool) -> PermissionState {
        granted
            ? PermissionState(grant: .granted, detail: "true (許可済み)")
            : PermissionState(grant: .undetermined, detail: "false (未許可。未決定か拒否かは判別できない)")
    }

    /// 入力監視の `IOHIDCheckAccess`。
    public static func from(hidAccess access: IOHIDAccessType) -> PermissionState {
        switch access {
        case kIOHIDAccessTypeGranted:
            return PermissionState(grant: .granted, detail: "granted (許可)")
        case kIOHIDAccessTypeDenied:
            return PermissionState(grant: .denied, detail: "denied (拒否)")
        case kIOHIDAccessTypeUnknown:
            return PermissionState(grant: .undetermined, detail: "unknown (未決定)")
        default:
            return PermissionState(grant: .undetermined, detail: "raw=\(access.rawValue)")
        }
    }

    /// AirPods のモーション。`CMHeadphoneMotionManager.authorizationStatus()`。
    public static func from(motion status: CMAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            return PermissionState(grant: .granted, detail: "authorized (許可)")
        case .denied:
            return PermissionState(grant: .denied, detail: "denied (拒否)")
        case .restricted:
            return PermissionState(grant: .denied, detail: "restricted (制限)")
        case .notDetermined:
            return PermissionState(grant: .undetermined, detail: "notDetermined (未決定)")
        @unknown default:
            return PermissionState(grant: .undetermined, detail: "unknown (raw=\(status.rawValue))")
        }
    }

    /// オートメーション。`AEDeterminePermissionToAutomateTarget` の OSStatus。
    ///
    /// 対象アプリが起動していないと `procNotFound` が返り、許可の有無は判定できない。
    /// これを「拒否」と読むと、音楽アプリを閉じているだけで赤く出てしまうので undetermined に倒す。
    public static func fromAutomation(status: OSStatus) -> PermissionState {
        switch status {
        case noErr:
            return PermissionState(grant: .granted, detail: "noErr (許可)")
        case OSStatus(errAEEventNotPermitted):
            return PermissionState(grant: .denied, detail: "errAEEventNotPermitted (拒否)")
        case OSStatus(errAEEventWouldRequireUserConsent):
            return PermissionState(grant: .undetermined, detail: "errAEEventWouldRequireUserConsent (未決定)")
        case OSStatus(procNotFound):
            return PermissionState(grant: .undetermined, detail: "procNotFound (対象アプリが起動していない)")
        default:
            return PermissionState(grant: .undetermined, detail: "OSStatus=\(status)")
        }
    }
}
