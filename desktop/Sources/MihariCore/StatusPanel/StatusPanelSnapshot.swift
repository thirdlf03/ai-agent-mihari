import Foundation

/// 状態パネルに出す 1 画面ぶんの値。
///
/// 表示のためだけの型で、OS 呼び出しも SwiftUI も含まない。`DetectionEngine` と
/// `DaemonController` の状態を渡すと文字列・色・バーの進捗まで決まる。
/// 「いま何を見て、何秒でどう判断したか」がデバッグの主題なので、
/// **どう組み立てたかを机上で確かめられる**ことを優先してここに切り出している。
public struct StatusPanelSnapshot: Equatable, Sendable {

    /// 1 行目の丸の色分け。
    public enum Tone: Equatable, Sendable {
        /// 正常。
        case normal
        /// 疑い。
        case suspected
        /// サボり確定。
        case confirmed
        /// 停止中・休憩中。判定そのものをしていない。
        case inactive
    }

    /// まだ評価していない行に出す文字。
    public static let placeholder = "—"

    /// 無操作バーの升目の数。
    public static let barCells = 10

    /// 1 行目の丸の色。
    public let tone: Tone
    /// 1 行目の状態。「疑い 1 回目(段階 1)」「メンヘラ(3 回目)(段階 5)」。
    public let stateText: String
    /// 1 行目の右。「監視中」「休憩中(残り 12:30)」「停止中」。
    public let watchText: String
    /// 休憩が明ける時刻。非 nil のときだけ残り時間を滑らかに動かす。
    ///
    /// `watchText` にも残りが入っているが、そちらは 5 秒ごとの評価でしか変わらない。
    /// 画面では時計として動かしたいので、元の時刻も一緒に持たせる。
    public let breakUntil: Date?
    /// Mac の無操作秒数。
    public let idleText: String
    /// 疑いに入るまでの進捗(0...1)。疑いに達したら満タン。
    public let idleProgress: Double
    /// 無操作の閾値。「疑い 60 / 段ごと 30」。
    public let thresholdText: String
    /// iPhone の様子。
    public let iphoneText: String
    /// 音楽。
    public let musicText: String
    /// 前面アプリ。
    public let frontmostAppText: String
    /// 在席スタンプ。「4 分前(猶予中)」「押されていない」。
    public let attendanceText: String
    /// 最後の判断。「「Mac が 2分 無操作 → 声をかけた」」。
    public let judgementText: String
    /// 最後の判断の時刻。まだ何も起きていなければ nil。
    public let judgementTimeText: String?
    /// デーモン。「接続中(port 51234)」「未接続」。
    public let daemonText: String

    /// 表示用の値を組み立てる。
    ///
    /// - Parameters:
    ///   - signals: 直近の評価で見た材料。まだ評価していなければ nil。全行が「—」になる。
    ///   - lastEvidenceAt: 最後に証拠を撮った時刻。まだ撮っていなければ nil。
    ///   - lastLog: 判断の記録の先頭(最新)。
    ///   - daemonPort: デーモンに繋がっていればそのポート。繋がっていなければ nil。
    public static func make(
        isWatching: Bool,
        state: DetectionState,
        escalationStage: Int,
        signals: DetectionSignals?,
        thresholds: DetectionThresholds,
        breakUntil: Date?,
        lastEvidenceAt: Date?,
        lastLog: DetectionLogEntry?,
        daemonPort: Int?,
        now: Date = Date()
    ) -> StatusPanelSnapshot {
        let onBreak = breakUntil.map { now < $0 } ?? false

        return StatusPanelSnapshot(
            tone: tone(isWatching: isWatching, onBreak: onBreak, state: state),
            stateText: "\(state.label)(段階 \(escalationStage))",
            watchText: watchText(isWatching: isWatching, breakUntil: onBreak ? breakUntil : nil, now: now),
            breakUntil: onBreak ? breakUntil : nil,
            idleText: signals.map { "\(Int($0.macIdleSeconds)) 秒" } ?? placeholder,
            idleProgress: idleProgress(signals: signals, thresholds: thresholds),
            thresholdText: "疑い \(Int(thresholds.suspectSeconds)) / 段ごと \(Int(thresholds.stageIntervalSeconds))",
            iphoneText: signals.map { iphoneText($0.iphone) } ?? placeholder,
            musicText: signals?.music.label ?? placeholder,
            frontmostAppText: signals.map { $0.frontmostApp ?? "不明" } ?? placeholder,
            attendanceText: signals.map { attendanceText(signals: $0, thresholds: thresholds) } ?? placeholder,
            judgementText: lastLog.map { "「\($0.reason) → \($0.outcome)」" } ?? placeholder,
            judgementTimeText: lastLog.map { $0.at.formatted(date: .omitted, time: .standard) },
            daemonText: daemonPort.map { "接続中(port \($0))" } ?? "未接続"
        )
    }

    /// 無操作バーの升目。埋まっているぶんだけ `▓`、残りは `░`。
    public var idleBar: String {
        let filled = min(Self.barCells, max(0, Int((idleProgress * Double(Self.barCells)).rounded())))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: Self.barCells - filled)
    }

    // MARK: - 各行

    /// 止まっている(停止中・休憩中)ときは判定そのものをしていないので、状態の色は出さない。
    private static func tone(isWatching: Bool, onBreak: Bool, state: DetectionState) -> Tone {
        guard isWatching, !onBreak else { return .inactive }
        switch state {
        case .normal: return .normal
        case .suspect: return .suspected
        case .exposing, .clingy: return .confirmed
        }
    }

    private static func watchText(isWatching: Bool, breakUntil: Date?, now: Date) -> String {
        if let breakUntil { return "休憩中(残り \(remainingText(until: breakUntil, now: now)))" }
        return isWatching ? "監視中" : "停止中"
    }

    /// 疑いに入るまでどれだけ来ているか。疑いに達したら満タンで止める。
    private static func idleProgress(signals: DetectionSignals?, thresholds: DetectionThresholds) -> Double {
        guard let signals, thresholds.suspectSeconds > 0 else { return 0 }
        return min(1, max(0, signals.macIdleSeconds / thresholds.suspectSeconds))
    }

    private static func iphoneText(_ state: SpeechRequest.IPhoneState) -> String {
        switch state {
        case .active: return "操作中"
        case .idle: return "置かれたまま"
        case .unreachable: return "応答なし"
        }
    }

    private static func attendanceText(signals: DetectionSignals, thresholds: DetectionThresholds) -> String {
        guard let since = signals.secondsSinceStamp else { return "押されていない" }
        let elapsed = elapsedText(since)
        return since < thresholds.stampGraceSeconds ? "\(elapsed)(猶予中)" : elapsed
    }

    // MARK: - 秒の見せ方

    /// 残り時間を `12:30` の形で出す。
    static func remainingText(until: Date, now: Date) -> String {
        let total = max(0, Int(until.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 経過時間を「4 分前」の形で出す。1 分未満は秒で出す。
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total) 秒前" : "\(total / 60) 分前"
    }
}

extension StatusPanelSnapshot {
    /// 動いているエンジンとデーモンから組み立てる。画面から呼ぶのはこちら。
    @MainActor
    public static func make(
        engine: DetectionEngine,
        daemon: DaemonController,
        now: Date = Date()
    ) -> StatusPanelSnapshot {
        make(
            isWatching: engine.isWatching,
            state: engine.state,
            escalationStage: engine.escalationStage,
            signals: engine.lastSignals,
            thresholds: engine.thresholds,
            breakUntil: engine.breakUntil,
            lastEvidenceAt: engine.lastEvidenceAt,
            lastLog: engine.log.first,
            daemonPort: daemonPort(of: daemon),
            now: now
        )
    }

    @MainActor
    private static func daemonPort(of daemon: DaemonController) -> Int? {
        guard case .running(let port, _) = daemon.state else { return nil }
        return port
    }
}
