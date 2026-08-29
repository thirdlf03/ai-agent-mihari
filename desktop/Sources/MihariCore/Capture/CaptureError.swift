import Foundation

/// カメラ撮影・スクリーンショット撮影まわりのエラー。
///
/// 権限が下りていないケースは `PermissionChecker` が返す `detail` をそのまま埋め込み、
/// 「拒否」なのか「まだ聞いていない」なのかが UI とログの両方から分かるようにする。
public enum CaptureError: LocalizedError, Equatable, Sendable {
    case cameraPermissionNotGranted(detail: String)
    case cameraDeviceUnavailable
    case cameraSessionConfigurationFailed(reason: String)
    case cameraPhotoDataMissing
    case cameraCaptureFailed(reason: String)

    case screenRecordingPermissionNotGranted(detail: String)
    case screenCaptureNoDisplay
    case screenCaptureFailed(reason: String)

    case imageEncodingFailed
    case imageDecodingFailed
    case fileWriteFailed(reason: String)
    case fileDeleteFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .cameraPermissionNotGranted(let detail):
            return "カメラの権限が許可されていない (\(detail))"
        case .cameraDeviceUnavailable:
            return "利用できるカメラが見つからない"
        case .cameraSessionConfigurationFailed(let reason):
            return "カメラの初期化に失敗した: \(reason)"
        case .cameraPhotoDataMissing:
            return "撮影データを取得できなかった"
        case .cameraCaptureFailed(let reason):
            return "撮影に失敗した: \(reason)"

        case .screenRecordingPermissionNotGranted(let detail):
            return "画面収録の権限が許可されていない (\(detail))"
        case .screenCaptureNoDisplay:
            return "キャプチャ対象のディスプレイが見つからない(画面収録の権限が未許可の可能性が高い)"
        case .screenCaptureFailed(let reason):
            return "スクリーンショットの取得に失敗した: \(reason)"

        case .imageEncodingFailed:
            return "画像を PNG に変換できなかった"
        case .imageDecodingFailed:
            return "撮影データから画像を復元できなかった"
        case .fileWriteFailed(let reason):
            return "画像の保存に失敗した: \(reason)"
        case .fileDeleteFailed(let reason):
            return "画像の削除に失敗した: \(reason)"
        }
    }
}
