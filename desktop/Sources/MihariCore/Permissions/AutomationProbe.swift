import CoreServices
import Foundation

/// オートメーション(Apple Events)権限を、プロンプトを出さずに照会する。
///
/// `AEDeterminePermissionToAutomateTarget` に `askUserIfNeeded: false` を渡すと、
/// 未決定のときにプロンプトを出さずに `errAEEventWouldRequireUserConsent` が返る。
/// オンボーディング画面を開いただけで許可ダイアログが出てしまうのを避けるため、必ず false で呼ぶ。
public enum AutomationProbe {

    /// 音楽の停止に使う既定のターゲット。
    public static let musicBundleID = "com.apple.Music"

    /// 指定したバンドル ID のアプリを操作する権限があるかを照会する。
    public static func status(forBundleID bundleID: String = musicBundleID) -> PermissionState {
        guard let data = bundleID.data(using: .utf8) else {
            return PermissionState(grant: .undetermined, detail: "バンドル ID をエンコードできない")
        }

        var target = AEAddressDesc()
        // AECreateDesc は OSErr(Int16) を返すので、他の Apple Events API と揃えて OSStatus に広げる。
        let createStatus = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            return OSStatus(AECreateDesc(typeApplicationBundleID, base, buffer.count, &target))
        }
        guard createStatus == noErr else {
            return PermissionState(grant: .undetermined, detail: "AECreateDesc 失敗 (OSStatus=\(createStatus))")
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        return PermissionStateMapper.fromAutomation(status: status)
    }
}
