import AVFoundation
import CoreGraphics
import CoreMotion
import Foundation
import IOKit.hidsystem
import os

/// 権限のプロンプトを出す。ユーザーがボタンを押したときだけ呼ぶ。
public enum PermissionRequester {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "permission")

    /// 要求の結果を人に見せるための文言。要求できない権限は理由を返す。
    public static func request(_ kind: PermissionKind) async -> String {
        switch kind {
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            logger.info("camera requestAccess -> \(granted, privacy: .public)")
            return "カメラ: \(granted ? "許可された" : "許可されなかった")"

        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            logger.info("microphone requestAccess -> \(granted, privacy: .public)")
            return "マイク: \(granted ? "許可された" : "許可されなかった")"

        case .screenRecording:
            // 初回だけプロンプトが出る。2 回目以降は false のままで、システム設定から許可するしかない。
            let granted = CGRequestScreenCaptureAccess()
            logger.info("CGRequestScreenCaptureAccess -> \(granted, privacy: .public)")
            return granted
                ? "画面収録: 許可された"
                : "画面収録: プロンプトが出なければ、システム設定から許可してアプリを再起動する"

        case .inputMonitoring:
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            logger.info("IOHIDRequestAccess -> \(granted, privacy: .public)")
            return "入力監視: \(granted ? "許可された" : "許可されなかった")"

        case .motion:
            return await requestMotion()

        case .automation:
            return "オートメーションは対象アプリへ実際に命令を送った瞬間にしか聞かれない。システム設定から許可する"
        }
    }

    /// モーションには専用の要求 API がないため、一度だけ更新を開始して停止することでプロンプトを出す。
    private static func requestMotion() async -> String {
        let manager = CMHeadphoneMotionManager()
        guard manager.isDeviceMotionAvailable else {
            return "モーション: この Mac / AirPods では device motion が使えない"
        }
        manager.startDeviceMotionUpdates()
        // プロンプトの応答を待つ。押されなければタイムアウトして現在の状態を返す。
        try? await Task.sleep(for: .seconds(1))
        manager.stopDeviceMotionUpdates()
        let status = CMHeadphoneMotionManager.authorizationStatus()
        logger.info("headphone motion authorization -> \(status.rawValue, privacy: .public)")
        return "モーション: \(PermissionStateMapper.from(motion: status).detail)"
    }
}
