import Foundation

/// サボりを判定する。**このアプリの仕様の中心。**
///
/// OS も HTTP も触らない純粋関数にしてある。`DetectionSignals` を入れると
/// `DetectionDecision` が出るだけなので、閾値の境界や分岐を机上で全部確かめられる。
public struct DetectionJudge: Sendable {

    private let thresholds: DetectionThresholds

    public init(thresholds: DetectionThresholds = .default) {
        self.thresholds = thresholds
    }

    /// 判定する。
    ///
    /// - Parameters:
    ///   - signals: いまの材料。
    ///   - secondsSinceLastEvidence: 前回証拠を取ってからの秒数。まだ取っていなければ `nil`。
    public func decide(
        _ signals: DetectionSignals,
        secondsSinceLastEvidence: TimeInterval? = nil
    ) -> DetectionDecision {
        // 手が動いていれば何もしない。ここが一番よくある道なので最初に返す。
        if signals.macIdleSeconds < thresholds.minimumIdleSeconds {
            return .idle(reason: "Mac を \(seconds: signals.macIdleSeconds) 前まで触っている")
        }

        // 本人が指紋で「席にいる」と示した直後は見逃す。撮りに行くとただの嫌がらせになる。
        if let sinceStamp = signals.secondsSinceStamp, sinceStamp < thresholds.stampGraceSeconds {
            return .idle(reason: "\(seconds: sinceStamp) 前に在席スタンプが押されている")
        }

        guard let confirmedBy = confirmationCause(signals) else {
            guard signals.macIdleSeconds >= thresholds.suspectSeconds else {
                return .idle(reason: "Mac が \(seconds: signals.macIdleSeconds) 無操作")
            }
            return DetectionDecision(
                state: .suspected,
                evidence: .none,
                shouldSpeak: true,
                shouldInterrupt: false,
                reason: "Mac が \(seconds: signals.macIdleSeconds) 無操作"
            )
        }

        // 確定。ただし直前に撮っていれば、声だけかけて撮り直さない。
        if let sinceEvidence = secondsSinceLastEvidence, sinceEvidence < thresholds.cooldownSeconds {
            return DetectionDecision(
                state: .confirmed,
                evidence: .none,
                shouldSpeak: true,
                shouldInterrupt: false,
                reason: "\(seconds: sinceEvidence) 前に証拠を取ったばかり"
            )
        }

        return DetectionDecision(
            state: .confirmed,
            evidence: evidence(for: signals.iphone),
            shouldSpeak: true,
            // 止める音楽が無いのに画面を覆っても、「音楽を止めて聞かせる」が空振りするだけ。
            // 鳴っているときだけ画面を奪う。鳴っていなければ声だけかける。
            shouldInterrupt: signals.music.isPlaying,
            reason: confirmedReason(signals, cause: confirmedBy)
        )
    }

    /// 確定に至った理由。確定しないなら `nil`。
    ///
    /// 時間切れだけでなく、**画面を見ていないと確認できた**場合も確定させる。
    /// 見ていないことが分かっているなら、時間切れまで待つ理由がない。
    private func confirmationCause(_ signals: DetectionSignals) -> ConfirmationCause? {
        // 「見ていない」が続いた長さで決める。単発のフレームで決めると瞬きで飛ぶ。
        if signals.gaze.notLookingSeconds >= thresholds.notLookingDurationSeconds {
            return .notLookingAtScreen
        }
        if signals.macIdleSeconds >= thresholds.confirmSeconds {
            return .idleTooLong
        }
        return nil
    }

    /// 「分岐」の本体。Mac が止まっているとき、iPhone を触っているかで撮る先が変わる。
    private func evidence(for iphone: SpeechRequest.IPhoneState) -> EvidenceKind {
        switch iphone {
        case .active:
            // Mac は放置して iPhone を触っている。何を見ているかを晒す。
            return .iphoneScreenshot
        case .idle, .unreachable:
            // iPhone からも反応が無い。寝ているか席にいないので、顔を撮る。
            return .macCamera
        }
    }

    private func confirmedReason(_ signals: DetectionSignals, cause: ConfirmationCause) -> String {
        var parts: [String] = []
        if cause == .notLookingAtScreen {
            // どちらの条件で引っかかったのかが分からないと、閾値を詰めようがない。
            parts.append("画面を \(seconds: signals.gaze.notLookingSeconds) 見ていない")
        }
        parts.append("Mac が \(seconds: signals.macIdleSeconds) 無操作")
        switch signals.iphone {
        case .active:
            parts.append("iPhone は操作中")
        case .idle:
            parts.append("iPhone は置かれたまま")
        case .unreachable:
            parts.append("iPhone は応答なし")
        }
        if signals.music.isPlaying {
            parts.append(signals.music.label)
        }
        if let app = signals.frontmostApp {
            parts.append("直前は \(app)")
        }
        return parts.joined(separator: " / ")
    }
}

/// 何をもって確定としたか。
private enum ConfirmationCause {
    /// 無操作が続きすぎた。
    case idleTooLong
    /// 画面を見ていないと確認できた。
    case notLookingAtScreen
}

extension DefaultStringInterpolation {
    /// 秒数を読みやすく差し込む。ログと Discord の文面の両方で使う。
    mutating func appendInterpolation(seconds value: TimeInterval) {
        let total = Int(value.rounded())
        if total < 60 {
            appendLiteral("\(total)秒")
        } else {
            appendLiteral("\(total / 60)分")
        }
    }
}
