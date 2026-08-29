import AVFoundation
import Foundation
import Vision
import os

/// カメラを開けたまま視線を見張る。
///
/// **怪しくなってから開き、手が動いたら閉じる。** 常時開けっぱなしにはしない。
///
/// 単発で撮る方式をやめたのは 2 つ理由がある。
/// 1. 1 フレームだけだと瞬きや一瞬の視線移動で判定が飛ぶ。続いた秒数で見れば埋もれる
/// 2. 撮るたびにセッションを開き直すと自動露出が毎回やり直しになり、
///    実機では平均輝度 0.017(ほぼ真っ黒)のフレームしか返らないことがあった
public class GazeMonitor: NSObject, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "gaze")

    /// Vision にかけるフレームの間隔。毎フレーム解析しても判定は良くならず、CPU だけ食う。
    public static let analysisIntervalSeconds: TimeInterval = 0.25

    /// カメラを開けてから、露出が落ち着くまで結果を採用しない時間。
    /// 開いた直後のフレームは暗く、顔が取れないため。
    public static let warmupSeconds: TimeInterval = 1.2

    private let queue = DispatchQueue(label: "com.thirdlf03.mihari.gaze")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var _observation = GazeObservation.none
    private var notLookingSince: Date?
    private var startedAt: Date?
    private var lastAnalyzedAt: Date?
    private var configured = false

    /// いまの視線の状況。
    open var observation: GazeObservation {
        lock.withLock { _observation }
    }

    open var isRunning: Bool { session.isRunning }

    /// 見張り始める。すでに動いていれば何もしない。
    open func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            guard configure() else { return }
            lock.withLock {
                startedAt = Date()
                notLookingSince = nil
                _observation = .none
            }
            Self.logger.info("視線の監視を開始する(緑ランプ点灯)")
            session.startRunning()
        }
    }

    /// 見張りをやめて、覚えていた結果も捨てる。
    open func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
                Self.logger.info("視線の監視を停止した(緑ランプ消灯)")
            }
            lock.withLock {
                startedAt = nil
                notLookingSince = nil
                lastAnalyzedAt = nil
                _observation = .none
            }
        }
    }

    /// 呼び出し元は必ず `queue` 上にいる。
    private func configure() -> Bool {
        guard !configured else { return true }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 顔を取り逃がす方が困るので解像度は落とさない。
        // 解析は 4 fps 程度に間引いてあり、この解像度でも CPU は問題にならない。
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            Self.logger.error("カメラが見つからない")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            Self.logger.error("カメラを入力に追加できない")
            return false
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            Self.logger.error("映像出力を追加できない")
            return false
        }
        session.addOutput(output)

        configured = true
        return true
    }
}

extension GazeMonitor: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()

        let shouldAnalyze: Bool = lock.withLock {
            guard let startedAt, now.timeIntervalSince(startedAt) >= Self.warmupSeconds else {
                // 露出が落ち着く前のフレームは暗くて顔が取れない。捨てる。
                return false
            }
            if let lastAnalyzedAt, now.timeIntervalSince(lastAnalyzedAt) < Self.analysisIntervalSeconds {
                return false
            }
            lastAnalyzedAt = now
            return true
        }
        guard shouldAnalyze else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let outcome = FaceVisionAnalyzer.analyze(pixelBuffer: pixelBuffer)
        update(with: outcome, now: now)
    }

    private func update(with outcome: FaceDetectionOutcome, now: Date) {
        let state = GazeState.from(outcome: outcome)
        var openness: Double?
        var yaw: Double?
        var noseOffset: Double?
        if case .faceFound(let metrics) = outcome {
            openness = metrics.averageEyeOpenness
            yaw = metrics.yawRadians
            noseOffset = metrics.noseOffset
        }

        lock.withLock {
            switch state {
            case .notLooking:
                // 続いている長さを測るため、始まりの時刻を覚える。
                if notLookingSince == nil { notLookingSince = now }
            case .lookingAtScreen:
                notLookingSince = nil
            case .unknown:
                // 解析できなかっただけ。数えている途中の時間は崩さない。
                break
            }

            let duration = notLookingSince.map { now.timeIntervalSince($0) } ?? 0
            _observation = GazeObservation(
                state: state,
                notLookingSeconds: duration,
                eyeOpenness: openness,
                yawRadians: yaw,
                noseOffset: noseOffset,
                updatedAt: now
            )
        }
    }
}
