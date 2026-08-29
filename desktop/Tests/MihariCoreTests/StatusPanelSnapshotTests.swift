import Foundation
import Testing

@testable import MihariCore

@Suite("状態パネルの表示")
struct StatusPanelSnapshotTests {

    /// 環境変数(`MIHARI_FAST_THRESHOLDS`)で揺れないよう、閾値は固定で持つ。
    private let thresholds = DetectionThresholds(
        suspectSeconds: 120,
        confirmSeconds: 300,
        gazeWatchSeconds: 60,
        stampGraceSeconds: 300,
        cooldownSeconds: 180
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

        let suspected = snapshot(state: .suspected, escalationStage: 1)
        #expect(suspected.tone == .suspected)
        #expect(suspected.stateText == "疑い(段階 1)")

        let confirmed = snapshot(state: .confirmed, escalationStage: 3)
        #expect(confirmed.tone == .confirmed)
        #expect(confirmed.stateText == "サボり確定(段階 3)")
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
        let resting = snapshot(state: .confirmed, breakUntil: until)
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

    @Test("無操作のバーは確定までの進捗で、確定に達したら満タン")
    func idleBarFillsUpToConfirm() {
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 0)).idleProgress == 0)
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 0)).idleBar == "░░░░░░░░░░")

        // 疑い(120 秒)は確定(300 秒)の 4 割。
        let suspect = snapshot(signals: DetectionSignals(macIdleSeconds: 120))
        #expect(abs(suspect.idleProgress - 0.4) < 0.0001)
        #expect(suspect.idleBar == "▓▓▓▓░░░░░░")

        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 300)).idleProgress == 1)
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 300)).idleBar == "▓▓▓▓▓▓▓▓▓▓")
        // 確定を越えてもはみ出さない。
        #expect(snapshot(signals: DetectionSignals(macIdleSeconds: 9_000)).idleProgress == 1)
    }

    @Test("閾値はそのままの値を出す")
    func thresholdsAreShownAsIs() {
        #expect(snapshot().thresholdText == "疑い 120 / 確定 300")
    }

    // MARK: - 視線

    @Test("視線は見ている / 見ていない / カメラ閉の 3 通り")
    func gazeHasThreeForms() {
        let notLooking = snapshot(
            signals: DetectionSignals(
                macIdleSeconds: 200,
                gaze: GazeObservation(state: .notLooking, notLookingSeconds: 6.2, eyeOpenness: 0.31)
            )
        )
        #expect(notLooking.gazeText == "見ていない 6.2 秒")
        #expect(notLooking.eyeOpennessText == "0.31")

        let looking = snapshot(
            signals: DetectionSignals(
                macIdleSeconds: 200,
                gaze: GazeObservation(state: .lookingAtScreen)
            )
        )
        #expect(looking.gazeText == "見ている")
        #expect(looking.eyeOpennessText == nil)

        // カメラを開ける秒数(60)に届いていないので、そもそも覗いていない。
        let closed = snapshot(signals: DetectionSignals(macIdleSeconds: 10))
        #expect(closed.gazeText == "不明(カメラ閉)")
    }

    // MARK: - 在席スタンプとクールダウン

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

    @Test("クールダウンは最後に撮った時刻から残りを出す")
    func cooldownCountsDown() {
        // 180 秒のうち 100 秒経ったので残り 80 秒。
        let cooling = snapshot(lastEvidenceAt: now.addingTimeInterval(-100))
        #expect(cooling.cooldownText == "残り 1:20")
        #expect(cooling.cooldownUntil == now.addingTimeInterval(80))

        let expired = snapshot(lastEvidenceAt: now.addingTimeInterval(-180))
        #expect(expired.cooldownText == "なし")
        #expect(expired.cooldownUntil == nil)

        let never = snapshot()
        #expect(never.cooldownText == "なし")
        #expect(never.cooldownUntil == nil)
    }

    // MARK: - 最後の判断とデーモン

    @Test("最後の判断は根拠と結果をそのまま出す")
    func lastJudgementIsShown() {
        let entry = DetectionLogEntry(
            at: now,
            state: .suspected,
            evidence: .none,
            reason: "Mac が 2分 無操作 / iPhone は応答なし",
            outcome: "声をかけた"
        )
        let shown = snapshot(lastLog: entry)
        #expect(shown.judgementText == "「Mac が 2分 無操作 / iPhone は応答なし → 声をかけた」")
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
        #expect(blank.gazeText == "—")
        #expect(blank.eyeOpennessText == nil)
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
