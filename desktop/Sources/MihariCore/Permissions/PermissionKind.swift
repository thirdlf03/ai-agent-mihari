import Foundation

/// Mihari が使う TCC 権限。オンボーディング画面にはこの順で並ぶ。
public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case camera
    case microphone
    case screenRecording
    case inputMonitoring
    case automation
    case motion

    public var id: String { rawValue }

    /// アプリからプロンプトを出せる権限。初回起動時はこの順に要求する。
    /// モーションは AirPods が接続されていないとプロンプトが出ないため、まとめ要求からは外す。
    public static var requestableOnLaunch: [PermissionKind] {
        [.camera, .microphone, .screenRecording, .inputMonitoring]
    }

    public var title: String {
        switch self {
        case .camera: return "カメラ"
        case .microphone: return "マイク"
        case .screenRecording: return "画面収録"
        case .inputMonitoring: return "入力監視"
        case .automation: return "オートメーション"
        case .motion: return "モーション(AirPods)"
        }
    }

    /// この権限が何に使われるか。ユーザーに見せる説明で、Info.plist の用途文字列と揃える。
    public var purpose: String {
        switch self {
        case .camera: return "サボり検知時に証拠写真を1枚撮る"
        case .microphone: return "在席状況の判定に使う(音声は保存しない)"
        case .screenRecording: return "サボり検知時に画面のスクショを撮る"
        case .inputMonitoring: return "キーやマウスの操作有無からアイドルを判定する"
        case .automation: return "説教中に再生中の音楽を止める"
        case .motion: return "AirPods の首振りを はい/いいえ として受け取る"
        }
    }

    /// 状態の照会に使っている API。想定と違う状態のときに、どこを見ればよいか分かるように出す。
    public var api: String {
        switch self {
        case .camera: return "AVCaptureDevice.authorizationStatus(for: .video)"
        case .microphone: return "AVCaptureDevice.authorizationStatus(for: .audio)"
        case .screenRecording: return "CGPreflightScreenCaptureAccess()"
        case .inputMonitoring: return "IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)"
        case .automation: return "AEDeterminePermissionToAutomateTarget(com.apple.Music)"
        case .motion: return "CMHeadphoneMotionManager.authorizationStatus()"
        }
    }

    public var pane: PrivacyPane {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenRecording: return .screenCapture
        case .inputMonitoring: return .listenEvent
        case .automation: return .automation
        case .motion: return .motion
        }
    }

    /// アプリから権限要求 API を叩ける権限だけボタンのラベルを返す。
    /// オートメーションは対象アプリへ実際にイベントを送った瞬間しかプロンプトが出ないため、ここでは要求できない。
    public var requestButtonTitle: String? {
        switch self {
        case .camera, .microphone: return "許可を求める"
        case .screenRecording: return "許可を求める"
        case .inputMonitoring: return "許可を求める"
        case .motion: return "許可を求める"
        case .automation: return nil
        }
    }

    /// 権限が下りていないときに、その権限に依存する機能がどう壊れるか。
    public var consequenceIfDenied: String {
        switch self {
        case .camera: return "居眠りの証拠写真が撮れない"
        case .microphone: return "音による在席判定が使えない"
        case .screenRecording: return "Mac の画面を晒せない"
        case .inputMonitoring: return "アイドル判定の精度が落ちる"
        case .automation: return "音楽を止められない(オーバーレイは出る)"
        case .motion: return "首振りで答えられない"
        }
    }
}
