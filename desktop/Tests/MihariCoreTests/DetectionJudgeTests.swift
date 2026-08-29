import Foundation
import Testing

@testable import MihariCore

@Suite("サボり判定")
struct DetectionJudgeTests {

    /// 疑い 2 分 / 確定 5 分 / スタンプ猶予 5 分 / クールダウン 3 分。
    private let judge = DetectionJudge(thresholds: .default)

    private func signals(
        idle: TimeInterval,
        iphone: SpeechRequest.IPhoneState = .unreachable,
        sinceStamp: TimeInterval? = nil,
        app: String? = nil
    ) -> DetectionSignals {
        DetectionSignals(
            macIdleSeconds: idle,
            iphone: iphone,
            secondsSinceStamp: sinceStamp,
            frontmostApp: app
        )
    }

    // MARK: - 正常

    @Test("触っている間は何も起きない")
    func activeUserIsLeftAlone() {
        let decision = judge.decide(signals(idle: 10))
        #expect(decision.state == .normal)
        #expect(decision.evidence == .none)
        #expect(decision.shouldSpeak == false)
        #expect(decision.shouldInterrupt == false)
    }

    @Test("iPhone を触っていても Mac を触っていれば何も起きない")
    func macActivityWinsOverPhone() {
        // サボり判定の出発点はあくまで Mac の無操作。
        #expect(judge.decide(signals(idle: 5, iphone: .active)).state == .normal)
    }

    // MARK: - 疑い

    @Test("2 分を超えると疑いになり、声をかけるが撮らない")
    func suspectedSpeaksButDoesNotCapture() {
        let decision = judge.decide(signals(idle: 150))
        #expect(decision.state == .suspected)
        #expect(decision.shouldSpeak)
        #expect(decision.evidence == .none)
        #expect(decision.shouldInterrupt == false)
    }

    @Test("疑いの境界は 2 分ちょうどから")
    func suspectBoundary() {
        #expect(judge.decide(signals(idle: 119)).state == .normal)
        #expect(judge.decide(signals(idle: 120)).state == .suspected)
    }

    // MARK: - 確定と分岐（この Issue の中心）

    @Test("Mac 無操作 × iPhone 応答なし → Mac のカメラで撮る")
    func unreachablePhoneMeansCamera() {
        // iPhone からも反応が無い＝寝ているか席にいない。だから顔を撮る。
        let decision = judge.decide(signals(idle: 400, iphone: .unreachable))
        #expect(decision.state == .confirmed)
        #expect(decision.evidence == .macCamera)
    }

    @Test("Mac 無操作 × iPhone 操作中 → iPhone のスクショを撮る")
    func activePhoneMeansPhoneScreenshot() {
        // Mac は放置して iPhone を触っている＝何を見ているかを晒す。
        let decision = judge.decide(signals(idle: 400, iphone: .active))
        #expect(decision.state == .confirmed)
        #expect(decision.evidence == .iphoneScreenshot)
    }

    @Test("Mac 無操作 × iPhone も置かれたまま → Mac のカメラで撮る")
    func idlePhoneMeansCamera() {
        #expect(judge.decide(signals(idle: 400, iphone: .idle)).evidence == .macCamera)
    }

    @Test("確定の境界は 5 分ちょうどから")
    func confirmBoundary() {
        #expect(judge.decide(signals(idle: 299)).state == .suspected)
        #expect(judge.decide(signals(idle: 300)).state == .confirmed)
    }

    @Test("確定すると音楽を止めて聞かせる段階になる")
    func confirmedInterrupts() {
        #expect(judge.decide(signals(idle: 400)).shouldInterrupt)
    }

    // MARK: - 在席スタンプによる猶予

    @Test("スタンプ直後は確定に届いていても見逃す")
    func recentStampSuppressesEverything() {
        // 本人が指紋で「席にいる」と示した直後に撮りに行くと、ただの嫌がらせになる。
        let decision = judge.decide(signals(idle: 600, sinceStamp: 60))
        #expect(decision.state == .normal)
        #expect(decision.evidence == .none)
        #expect(decision.reason.contains("在席スタンプ"))
    }

    @Test("猶予が切れれば普通に確定する")
    func expiredStampDoesNotSuppress() {
        #expect(judge.decide(signals(idle: 600, sinceStamp: 301)).state == .confirmed)
    }

    @Test("スタンプ猶予の境界は 5 分ちょうどまで")
    func stampGraceBoundary() {
        #expect(judge.decide(signals(idle: 600, sinceStamp: 299)).state == .normal)
        #expect(judge.decide(signals(idle: 600, sinceStamp: 300)).state == .confirmed)
    }

    @Test("スタンプを一度も押していなければ猶予は効かない")
    func noStampMeansNoGrace() {
        #expect(judge.decide(signals(idle: 600, sinceStamp: nil)).state == .confirmed)
    }

    // MARK: - クールダウン

    @Test("直前に撮っていれば、確定でも撮り直さない")
    func cooldownSuppressesCapture() {
        // これが無いと 1 秒ごとに撮って送り続けることになる。
        let decision = judge.decide(signals(idle: 600), secondsSinceLastEvidence: 30)
        #expect(decision.state == .confirmed)
        #expect(decision.evidence == .none)
        #expect(decision.shouldSpeak)
        #expect(decision.shouldInterrupt == false)
    }

    @Test("クールダウンが明ければまた撮る")
    func cooldownExpires() {
        #expect(judge.decide(signals(idle: 600), secondsSinceLastEvidence: 181).evidence == .macCamera)
    }

    @Test("クールダウンの境界は 3 分ちょうどまで")
    func cooldownBoundary() {
        #expect(judge.decide(signals(idle: 600), secondsSinceLastEvidence: 179).evidence == .none)
        #expect(judge.decide(signals(idle: 600), secondsSinceLastEvidence: 180).evidence == .macCamera)
    }

    // MARK: - 判断の根拠

    @Test("なぜそう判断したかが必ず残る")
    func reasonIsAlwaysPresent() {
        for idle in [10.0, 150.0, 600.0] {
            #expect(!judge.decide(signals(idle: idle)).reason.isEmpty)
        }
    }

    @Test("確定の根拠には無操作時間と iPhone の様子が入る")
    func confirmedReasonNamesTheSignals() {
        let reason = judge.decide(signals(idle: 600, iphone: .active, app: "Safari")).reason
        #expect(reason.contains("10分"))
        #expect(reason.contains("操作中"))
        #expect(reason.contains("Safari"))
    }

    @Test("秒数は 60 秒を境に分表記になる")
    func reasonFormatsDuration() {
        #expect(judge.decide(signals(idle: 30)).reason.contains("秒"))
        #expect(judge.decide(signals(idle: 150)).reason.contains("2分"))
    }

    // MARK: - 閾値の差し替え

    @Test("閾値を差し替えれば判定も変わる")
    func thresholdsAreInjectable() {
        let strict = DetectionJudge(thresholds: DetectionThresholds(suspectSeconds: 5, confirmSeconds: 10))
        #expect(strict.decide(signals(idle: 6)).state == .suspected)
        #expect(strict.decide(signals(idle: 11)).state == .confirmed)
    }

    @Test("確定が疑いより手前に設定されても破綻しない")
    func confirmNeverPrecedesSuspect() {
        // 設定ミスで確定が先に来ると、疑いの段階が消えて挙動が読めなくなる。
        let thresholds = DetectionThresholds(suspectSeconds: 300, confirmSeconds: 60)
        #expect(thresholds.confirmSeconds == 300)
    }

    @Test("負の無操作秒数は 0 として扱う")
    func negativeIdleIsClamped() {
        #expect(DetectionSignals(macIdleSeconds: -10).macIdleSeconds == 0)
    }
}
