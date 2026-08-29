import Foundation
import SwiftUI
import os

/// `HeadGestureView` を裏で支える。
///
/// 生の pitch/yaw を出し続けるプレビューと、実際の問いかけ API(`HeadGestureQuestioner`)を
/// 試す「質問してみる」ボタンの両方をここでまとめる。CMHeadphoneMotionManager は同時に
/// 1つの購読しか持てないため、質問中はプレビューを止め、終わったら元に戻す。
@MainActor
public final class HeadGestureController: ObservableObject {

    /// 動作確認用の固定質問文。実際の問いかけ文言は#16(ペットUI)側が持つため、ここではダミー。
    public static let samplePrompt = "動作確認用の質問(うなずく/首を振る)"

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "head-gesture")

    @Published public private(set) var availability: HeadGestureAvailability = .unavailable(reason: "未チェック")
    @Published public private(set) var latestSample: HeadOrientationSample?
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var isAsking = false
    @Published public private(set) var lastResponse: HeadGestureResponse?

    private let source: HeadOrientationSource
    private let questioner: HeadGestureQuestioner
    private var previewTask: Task<Void, Never>?

    public init(
        source: HeadOrientationSource = AirPodsHeadOrientationSource(),
        thresholds: HeadGestureThresholds = .default
    ) {
        self.source = source
        self.questioner = HeadGestureQuestioner(source: source, thresholds: thresholds)
    }

    /// 接続状況/対応状況を取り直す。プロンプトは出さない。
    public func refreshAvailability() {
        availability = source.availability()
    }

    /// 生の pitch/yaw を出し続ける。閾値の調整に使う。質問中は開始しない。
    public func startPreview() {
        guard previewTask == nil, !isAsking else { return }
        refreshAvailability()
        guard availability.isAvailable else { return }

        isPreviewing = true
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await sample in self.source.updates() {
                if Task.isCancelled { break }
                self.latestSample = sample
            }
        }
    }

    /// プレビューを止める。CMHeadphoneMotionManager の購読を手放し、電池を消費し続けないようにする。
    public func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
    }

    /// 「質問してみる」ボタンから呼ぶ。プレビュー中なら一旦止め、終わったら元の状態に戻す。
    public func askSampleQuestion() async {
        guard !isAsking else { return }

        let wasPreviewing = isPreviewing
        stopPreview()

        isAsking = true
        lastResponse = await questioner.ask(prompt: Self.samplePrompt)
        isAsking = false

        if wasPreviewing {
            startPreview()
        }
    }
}
