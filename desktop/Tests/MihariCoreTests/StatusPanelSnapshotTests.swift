import Foundation
import Testing

@testable import MihariCore

@Suite("状態パネルの表示")
struct StatusPanelSnapshotTests {

    /// 環境変数(`MIHARI_FAST_THRESHOLDS`)で揺れないよう、閾値は固定で持つ。
    private let thresholds = DetectionThresholds(
        suspectSeconds: 120,
        stageIntervalSeconds: 30,
        stampGraceSeconds: 300
    )

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        isWatching: Bool = true,
        state: DetectionState = .normal,
        escalationStage: Int = 0,
        signals: DetectionSignals? = nil,
        breakUntil: Date? = nil,
        lastEvidenceAt: Date? = nil,
        lastLog: DetectionLogEntry? = nil,
        daemonPort: Int? = nil
    ) -> StatusPanelSnapshot {
        StatusPanelSnapshot.make(
            isWatching: isWatching,
            state: state,
            escalationStage: escalationStage,
            signals: signals,
            thresholds: thresholds,
            breakUntil: breakUntil,
            lastEvidenceAt: lastEvidenceAt,
            lastLog: lastLog,
            daemonPort: daemonPort,
            now: now
        )
    }

    // MARK: - 1 行目

    @Test("正常は緑、疑い・確定は段階つきで色が変わる")
    func headlineFollowsState() {
        let normal = snapshot(state: .normal)
        #expect(normal.tone == .normal)
        #expect(normal.stateText == "正常(段階 0)")
        #expect(normal.watchText == "監視中")

        let suspected = snapshot(state: .suspect(stage: 2), escalationStage: 2)
        #expect(suspected.tone == .suspected)
        #expect(suspected.stateText == "疑い 2 回目(段階 2)")

        let exposing = snapshot(state: .exposing, escalationStage: PetEvent.exposingStage)
        #expect(exposing.tone == .confirmed)
        #expect(exposing.stateText == "晒し中(段階 4)")

        let clingy = snapshot(
            state: .clingy(since: now, count: 3),
            escalationStage: PetEvent.clingyStage
        )
        #expect(clingy.tone == .confirmed)
        #expect(clingy.stateText == "メンヘラ(3 回目)(段階 5)")
    }

    @Test("停止中は判定していないので灰色にする")
    func stoppedIsInactive() {
        let stopped = snapshot(isWatching: false, state: .normal)
        #expect(stopped.tone == .inactive)
        #expect(stopped.watchText == "停止中")
        #expect(stopped.breakUntil == nil)
    }

    @Test("休憩中は残り時間を出し、色は灰色にする")
    func breakShowsRemaining() {
        let until = now.addingTimeInterval(750)
        let resting = snapshot(state: .exposing, breakUntil: until)
        #expect(resting.tone == .inactive)
        #expect(resting.watchText == "休憩中(残り 12:30)")
        #expect(resting.breakUntil == until)
    }

    @Test("休憩が明けていれば休憩中とは出さない")
    func expiredBreakIsIgnored() {
        let expired = snapshot(breakUntil: now.addingTimeInterval(-1))
        #expect(expired.watchText == "監視中")
        #expect(expired.breakUntil == nil)
    }

    // MARK: - 無操作のバー

    @Test("無操作のバーは疑いに入るまでの進捗で、届いたら満タン")
    func idleBarFillsUpToSuspect() {
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 0)).idleProgress == 0)
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 0)).idleBar == "░░░░░░░░░░")

        // 48 秒は疑い(120 秒)の 4 割。
        let partway = snapshot(signals: DetectionSignals(macIdleSeconds: 48))
        #expect(abs(partway.idleProgress - 0.4) < 0.0001)
        #expect(partway.idleBar == "▓▓▓▓░░░░░░")

        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 120)).idleProgress == 1)
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 120)).idleBar == "▓▓▓▓▓▓▓▓▓▓")
        // 疑いを越えてもはみ出さない。
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 9_000)).idleProgress == 1)
    }

    @Test("閾値はそのままの値を出す")
    func thresholdsAreShownAsIs() {
        #expect(snapshot().thresholdText == "疑い 120 / 段ごと 30")
    }

    // MARK: - 在席スタンプ

    @Test("在席スタンプは猶予のあいだだけ猶予中と出す")
    func stampGraceIsMarked() {
        let inGrace = snapshot(
            signals: DetectionSignals(macIdleSeconds: 200, secondsSinceStamp: 240)
        )
        #expect(inGrace.attendanceText == "4 分前(猶予中)")

        let expired = snapshot(
            signals: DetectionSignals(macIdleSeconds: 200, secondsSinceStamp: 600)
        )
        #expect(expired.attendanceText == "10 分前")

        let never = snapshot(signals: DetectionSignals(macIdleSeconds: 200))
        #expect(never.attendanceText == "押されていない")
    }

    // MARK: - 最後の判断とデーモン

    @Test("最後の判断は根拠と結果をそのまま出す")
    func lastJudgementIsShown() {
        let entry = DetectionLogEntry(
            at: now,
            state: .suspect(stage: 1),
            evidence: .none,
            reason: "Mac が 2分 無操作(疑い 1 回目)",
            outcome: "Touch ID で確かめる"
        )
        let shown = snapshot(lastLog: entry)
        #expect(shown.judgementText == "「Mac が 2分 無操作(疑い 1 回目) → Touch ID で確かめる」")
        #expect(shown.judgementTimeText != nil)
    }

    @Test("デーモンは繋がっていればポートを出す")
    func daemonShowsPort() {
        #expect(snapshot(daemonPort: 51_234).daemonText == "接続中(port 51234)")
        #expect(snapshot().daemonText == "未接続")
    }

    // MARK: - まだ評価していない

    @Test("まだ評価していなければ材料の行は全部「—」")
    func unevaluatedRowsArePlaceholders() {
        let blank = snapshot(signals: nil)
        #expect(blank.idleText == "—")
        #expect(blank.idleProgress == 0)
        #expect(blank.idleBar == "░░░░░░░░░░")
        #expect(blank.iphoneText == "—")
        #expect(blank.musicText == "—")
        #expect(blank.frontmostAppText == "—")
        #expect(blank.attendanceText == "—")
        #expect(blank.judgementText == "—")
        #expect(blank.judgementTimeText == nil)
        // 状態とデーモンは材料と関係なく出る。
        #expect(blank.watchText == "監視中")
        #expect(blank.daemonText == "未接続")
    }

    // MARK: - 材料の見せ方

    @Test("iPhone・音楽・前面アプリは材料そのままの言い方で出す")
    func signalsUseExistingLabels() {
        let signals = DetectionSignals(
            macIdleSeconds: 200,
            iphone: .active,
            music: .playing(.spotify),
            frontmostApp: "Safari"
        )
        let shown = snapshot(signals: signals)
        #expect(shown.iphoneText == "操作中")
        #expect(shown.musicText == NowPlaying.playing(.spotify).label)
        #expect(shown.frontmostAppText == "Safari")

        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 200, iphone: .idle)).iphoneText == "置かれたまま")
        #expect(
            snapshot(signals: DetectionSignals(macIdleSeconds: 200, iphone: .unreachable)).iphoneText == "応答なし"
        )
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 200)).frontmostAppText == "不明")
    }
}
