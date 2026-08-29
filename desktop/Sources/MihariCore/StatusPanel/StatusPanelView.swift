import SwiftUI

/// デスクトップに出しておく状態パネルの見た目。
///
/// 値の組み立ては `StatusPanelSnapshot` が持つ。ここは並べるだけ。
struct StatusPanelView: View {

    /// パネル全体の幅(pt)。
    static let width: CGFloat = 300

    /// 行の見出しの幅(pt)。値の頭を揃える。
    private static let titleWidth: CGFloat = 78

    @ObservedObject var engine: DetectionEngine
    @ObservedObject var daemon: DaemonController

    var body: some View {
        let snapshot = StatusPanelSnapshot.make(engine: engine, daemon: daemon)
        VStack(alignment: .leading, spacing: 4) {
            headline(snapshot)
            row("Mac 無操作") {
                Text(snapshot.idleText)
                Text(snapshot.idleBar).foregroundStyle(barColor(snapshot.tone))
                Text(snapshot.thresholdText).foregroundStyle(.white.opacity(0.5))
            }
            row("視線") {
                Text(snapshot.gazeText)
                if let openness = snapshot.eyeOpennessText {
                    Text("目の開き \(openness)").foregroundStyle(.white.opacity(0.5))
                }
            }
            row("iPhone") { Text(snapshot.iphoneText) }
            row("音楽") { Text(snapshot.musicText) }
            row("前面アプリ") { Text(snapshot.frontmostAppText) }
            row("在席スタンプ") {
                Text(snapshot.attendanceText)
                cooldown(snapshot)
            }
            row("最後の判断") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.judgementText)
                    if let time = snapshot.judgementTimeText {
                        Text(time).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            row("デーモン") { Text(snapshot.daemonText) }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 1 行目。状態の丸と、監視 / 休憩 / 停止。
    private func headline(_ snapshot: StatusPanelSnapshot) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: snapshot.tone))
                .frame(width: 8, height: 8)
            Text(snapshot.stateText).bold()
            Spacer(minLength: 4)
            // 休憩の残りは 5 秒ごとの評価を待たずに動かす。時計として見たいのはここだけ。
            if let until = snapshot.breakUntil {
                (Text("休憩中(残り ") + Text(until, style: .timer) + Text(")"))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text(snapshot.watchText).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    /// クールダウンの残り。撮れる状態なら「なし」。
    @ViewBuilder
    private func cooldown(_ snapshot: StatusPanelSnapshot) -> some View {
        if let until = snapshot.cooldownUntil {
            (Text("クールダウン 残り ") + Text(until, style: .timer))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            Text("クールダウン \(snapshot.cooldownText)").foregroundStyle(.white.opacity(0.5))
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: Self.titleWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func color(for tone: StatusPanelSnapshot.Tone) -> Color {
        switch tone {
        case .normal: return .green
        case .suspected: return .orange
        case .confirmed: return .red
        case .inactive: return .gray
        }
    }

    /// バーは状態と同じ色にする。止まっているあいだは目立たせない。
    private func barColor(_ tone: StatusPanelSnapshot.Tone) -> Color {
        tone == .inactive ? .gray : color(for: tone)
    }
}
