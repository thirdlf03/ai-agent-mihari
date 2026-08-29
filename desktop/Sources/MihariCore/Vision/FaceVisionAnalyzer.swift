import CoreGraphics
import Foundation
import Vision
import os

/// `VNDetectFaceLandmarksRequest` を実行し、結果を Vision フレームワークに依存しない
/// `FaceDetectionOutcome` に変換する。
///
/// ラベル付けは付加価値であって、これが原因で撮影や送信が止まってはいけない(#11 受け入れ条件)。
/// そのため公開 API は例外を投げず、失敗時は `.detectionFailed` を返すだけにしてある。
public enum FaceVisionAnalyzer {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "vision")

    /// 画像 1 枚を解析する。
    ///
    /// - Parameter image: 解析対象の画像。`CaptureService` が撮った写真を想定する。
    /// - Returns: 顔検出の結果。例外は内部で吸収し、失敗時は `.detectionFailed` を返す。
    public static func analyze(_ image: CGImage) -> FaceDetectionOutcome {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.error("Vision 解析に失敗した: \(error.localizedDescription, privacy: .public)")
            return .detectionFailed(reason: error.localizedDescription)
        }

        guard let observations = request.results, !observations.isEmpty else {
            return .noFaceFound
        }

        // 複数人写っていても、最も信頼度の高い 1 件だけを見る。
        guard let best = observations.max(by: { $0.confidence < $1.confidence }) else {
            return .noFaceFound
        }

        return .faceFound(metrics(from: best, imageSize: CGSize(width: image.width, height: image.height)))
    }

    /// 1 件の顔観測から判定用の指標を取り出す。
    private static func metrics(from observation: VNFaceObservation, imageSize: CGSize) -> FaceLandmarkMetrics {
        let landmarks = observation.landmarks
        let leftOpenness = landmarks?.leftEye.flatMap { region in
            FaceLandmarkGeometry.eyeOpenness(points: region.pointsInImage(imageSize: imageSize))
        }
        let rightOpenness = landmarks?.rightEye.flatMap { region in
            FaceLandmarkGeometry.eyeOpenness(points: region.pointsInImage(imageSize: imageSize))
        }

        if landmarks == nil {
            logger.info("顔は検出できたがランドマークが取れなかった(confidence=\(observation.confidence, privacy: .public))")
        }

        return FaceLandmarkMetrics(
            leftEyeOpenness: leftOpenness,
            rightEyeOpenness: rightOpenness,
            yawRadians: observation.yaw?.doubleValue
        )
    }
}
