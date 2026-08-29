import AppKit
import Foundation
import SwiftUI
import os

/// `VisionView` の状態。
///
/// 「撮ってラベルを付ける」1 アクションに対して、プレビュー・判定結果・算出した指標の
/// 生の値・エラーをまとめて保持する。閾値は初期化時に注入できるようにし、
/// 実機での調整をこの型の外(呼び出し側)から行えるようにしてある。
@MainActor
public final class FaceVisionViewModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "vision-view")

    @Published public private(set) var isAnalyzing = false
    @Published public private(set) var previewImage: NSImage?
    @Published public private(set) var label: SpeechRequest.VisionLabel?
    @Published public private(set) var metrics: FaceLandmarkMetrics?
    @Published public private(set) var outcomeDescription: String?
    @Published public private(set) var errorMessage: String?

    private let captureService: CaptureService
    private let closedEyeOpennessThreshold: Double
    private let lookingAwayYawRadiansThreshold: Double

    public init(
        captureService: CaptureService = CaptureService(),
        closedEyeOpennessThreshold: Double = VisionLabelClassifier.defaultClosedEyeOpennessThreshold,
        lookingAwayYawRadiansThreshold: Double = VisionLabelClassifier.defaultLookingAwayYawRadiansThreshold
    ) {
        self.captureService = captureService
        self.closedEyeOpennessThreshold = closedEyeOpennessThreshold
        self.lookingAwayYawRadiansThreshold = lookingAwayYawRadiansThreshold
    }

    /// カメラで 1 枚撮り、その場でラベルを付ける。
    ///
    /// 撮影・デコード・Vision 解析のどこで失敗しても例外を外へ投げず、`errorMessage` に
    /// 理由を残したうえで `label` を `.unknown` にする(判定はあくまで付加価値のため)。
    public func captureAndLabel() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        errorMessage = nil

        do {
            let artifact = try await captureService.capturePhoto()
            let data = try Data(contentsOf: artifact.url)
            // 検証用に撮っただけの画像なので、読み終えたら残さない(長期保存はしない方針)。
            try? artifact.delete()

            let image = try CaptureImageCodec.decode(data)
            previewImage = CaptureImageCodec.nsImage(from: image)

            apply(FaceVisionAnalyzer.analyze(image))
        } catch {
            let message = (error as? CaptureError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            label = .unknown
            metrics = nil
            outcomeDescription = nil
            Self.logger.error("撮影またはラベル付けに失敗した: \(message, privacy: .public)")
        }
    }

    private func apply(_ outcome: FaceDetectionOutcome) {
        switch outcome {
        case .detectionFailed(let reason):
            outcomeDescription = "Vision 解析に失敗した: \(reason)"
            metrics = nil
        case .noFaceFound:
            outcomeDescription = "顔を検出できなかった"
            metrics = nil
        case .faceFound(let found):
            outcomeDescription = "顔を検出した"
            metrics = found
        }
        label = VisionLabelClassifier.classify(
            outcome: outcome,
            closedEyeOpennessThreshold: closedEyeOpennessThreshold,
            lookingAwayYawRadiansThreshold: lookingAwayYawRadiansThreshold
        )
    }
}
