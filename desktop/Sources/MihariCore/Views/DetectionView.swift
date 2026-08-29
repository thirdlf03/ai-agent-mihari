import SwiftUI

/// 検知の状態と、判断の根拠を見る画面。
public struct DetectionView: View {
    @ObservedObject var engine: DetectionEngine

    public init(engine: DetectionEngine) {
        self.engine = engine
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                thresholdSection
                signalSection
                logSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("検知").font(.title2).bold()
            Text("Mac の無操作時間と iPhone の様子から、声をかけるか・証拠を取るかを決める。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(engine.state.label, systemImage: stateIcon)
                    .foregroundStyle(stateColor)
                    .font(.callout)
                Label(engine.isWatching ? "監視中" : "停止中", systemImage: engine.isWatching ? "eye" : "eye.slash")
                    .foregroundStyle(engine.isWatching ? Color.green : Color.secondary)
                    .font(.callout)
                Label(engine.gaze.summary, systemImage: gazeIcon)
                    .foregroundStyle(gazeColor)
                    .font(.callout)
                Label(engine.music.label, systemImage: engine.music.isPlaying ? "music.note" : "speaker.slash")
                    .foregroundStyle(engine.music.isPlaying ? Color.orange : Color.secondary)
                    .font(.callout)
            }
            .padding(.top, 2)

            HStack(spacing: 10) {
                Button(engine.isWatching ? "監視を止める" : "監視を始める") {
                    engine.isWatching ? engine.stop() : engine.start()
                }
                .buttonStyle(.borderedProminent)
                Button("いま評価する") { Task { await engine.evaluate() } }
                Spacer()
            }
        }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("閾値").font(.headline)
            Text("すべて要調整。デモしながら詰める前提の値。")
                .font(.caption)
                .foregroundStyle(.secondary)
            thresholdRow("疑い", engine.thresholds.suspectSeconds, "声をかけ始める")
            thresholdRow("確定", engine.thresholds.confirmSeconds, "証拠を取って晒す")
            thresholdRow("カメラを開ける", engine.thresholds.gazeWatchSeconds, "ここまではカメラを起動しない")
            thresholdRow("見ていない継続", engine.thresholds.notLookingDurationSeconds, "この秒数続いたら確定する")
            thresholdRow("スタンプ猶予", engine.thresholds.stampGraceSeconds, "在席スタンプ直後は見逃す")
            thresholdRow("クールダウン", engine.thresholds.cooldownSeconds, "次に撮るまで空ける")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func thresholdRow(_ title: String, _ seconds: TimeInterval, _ note: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 110, alignment: .leading).font(.callout)
            Text("\(Int(seconds)) 秒").font(.system(size: 12, design: .monospaced))
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var signalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("いまの材料").font(.headline)
            if let signals = engine.lastSignals {
                row("Mac 無操作", "\(Int(signals.macIdleSeconds)) 秒")
                row("iPhone", iphoneLabel(signals.iphone))
                row("視線", signals.gaze.summary)
                row("音楽", signals.music.label)
                row("前面アプリ", signals.frontmostApp ?? "不明")
                row(
                    "在席スタンプから",
                    signals.secondsSinceStamp.map { "\(Int($0)) 秒" } ?? "押されていない"
                )
            } else {
                Text("まだ評価していない。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 110, alignment: .leading).font(.callout)
            Text(value).font(.system(size: 12, design: .monospaced))
            Spacer()
        }
    }

    private func iphoneLabel(_ state: SpeechRequest.IPhoneState) -> String {
        switch state {
        case .active: return "操作中"
        case .idle: return "置かれたまま"
        case .unreachable: return "応答なし"
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("判断の記録").font(.headline)
            if engine.log.isEmpty {
                Text("まだ何も起きていない。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(engine.log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(entry.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.state.label)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                            if entry.evidence != .none {
                                Text(entry.evidence == .macCamera ? "カメラ" : "iPhone")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        Text(entry.reason).font(.callout)
                        Text(entry.outcome).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var gazeIcon: String {
        switch engine.gaze.state {
        case .lookingAtScreen: return "eye.circle.fill"
        case .notLooking: return "eye.slash.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var gazeColor: Color {
        switch engine.gaze.state {
        case .lookingAtScreen: return .green
        case .notLooking: return .orange
        case .unknown: return .secondary
        }
    }

    private var stateIcon: String {
        switch engine.state {
        case .normal: return "checkmark.circle"
        case .suspected: return "exclamationmark.circle"
        case .confirmed: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .normal: return .green
        case .suspected: return .orange
        case .confirmed: return .red
        }
    }
}
