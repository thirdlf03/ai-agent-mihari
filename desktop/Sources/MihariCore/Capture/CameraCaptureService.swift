import AVFoundation
import Foundation
import os

/// 非 Sendable な `AVCaptureSession` を `@Sendable` クロージャ越しに渡すための箱。
/// セッションの操作は必ず `CameraCaptureService` 専用のシリアルキュー上でしか行わないため、
/// 実質的にスレッドセーフだが、型として Sendable ではないので `@unchecked` で包む。
private struct CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

/// `AVCapturePhotoOutput` のデリゲート。撮影が完了するまで自身が保持される必要があるので、
/// `CameraCaptureService` 側で参照を持ち、完了したら手放す。
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(CaptureError.cameraCaptureFailed(reason: error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(CaptureError.cameraPhotoDataMissing))
            return
        }
        completion(.success(data))
    }
}

/// カメラで 1 枚だけ撮る。
///
/// 呼び出しのたびに `AVCaptureSession` を新しく組み立てて開始し、撮影が終わったら
/// 必ず `stopRunning()` する。常時セッションを保持しない(= 緑ランプを点けっぱなしにしない)ことを
/// 型そのものの制約にしている。
///
/// セッションの操作は専用のシリアルキューで行い、Swift Concurrency との境界では
/// `Data` / `Error` という Sendable な値だけをやり取りする。
public final class CameraCaptureService: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "camera-capture")

    private let queue = DispatchQueue(label: "com.thirdlf03.mihari.camera-capture")
    /// 撮影完了まで delegate の参照を切らさないための保持。キュー上でしか触らない。
    private var activeDelegate: PhotoCaptureDelegate?

    private let checkPermission: @Sendable () -> PermissionState

    /// - Parameter checkPermission: 権限状態の照会。テストでは差し替えて、
    ///   実機のカメラ権限に依存せず「未許可時に落ちないこと」を検証する。
    public init(checkPermission: @escaping @Sendable () -> PermissionState = { PermissionChecker.check(.camera) }) {
        self.checkPermission = checkPermission
    }

    /// 1 枚撮影し、生の画像データ(JPEG 相当)を返す。
    public func captureSinglePhoto() async throws -> Data {
        let permission = checkPermission()
        guard permission.grant == .granted else {
            throw CaptureError.cameraPermissionNotGranted(detail: permission.detail)
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                captureOnQueue { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// 呼び出し元は必ず `queue` 上にいる。
    private func captureOnQueue(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            completion(.failure(CaptureError.cameraDeviceUnavailable))
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            completion(.failure(CaptureError.cameraSessionConfigurationFailed(reason: error.localizedDescription)))
            return
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            completion(.failure(CaptureError.cameraSessionConfigurationFailed(reason: "入力を追加できない")))
            return
        }
        session.addInput(input)

        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            completion(.failure(CaptureError.cameraSessionConfigurationFailed(reason: "出力を追加できない")))
            return
        }
        session.addOutput(photoOutput)
        session.commitConfiguration()

        Self.logger.info("AVCaptureSession を開始する(撮影のみ・緑ランプ点灯)")
        session.startRunning()

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue])
        } else {
            settings = AVCapturePhotoSettings()
        }

        let sessionBox = CaptureSessionBox(session: session)
        let delegate = PhotoCaptureDelegate { [weak self] result in
            guard let self else {
                sessionBox.session.stopRunning()
                completion(result)
                return
            }
            self.queue.async {
                sessionBox.session.stopRunning()
                Self.logger.info("AVCaptureSession を停止した(緑ランプ消灯)")
                self.activeDelegate = nil
                completion(result)
            }
        }
        activeDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }
}
