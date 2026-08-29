import SwiftUI

/// オンボーディングの 1 行。権限名・用途・現在の状態・操作ボタンを並べる。
struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityLabel(indicatorLabel)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.body).bold()
                    badge
                }
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.grant != .granted {
                    Text("未許可だと: \(kind.consequenceIfDenied)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // 画面収録は許可した瞬間には効かず、次に起動したプロセスからしか使えない。
                // ここに書いておかないと「許可したのに撮れない」で詰まる。
                if kind == .screenRecording, state.grant != .granted {
                    Text("許可後はアプリの再起動が必要")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(kind.api)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(kind.api)
            }
            .frame(minWidth: 260, alignment: .leading)

            Text(state.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let title = kind.requestButtonTitle, state.grant != .granted {
                    Button(title, action: onRequest)
                        .controlSize(.small)
                }
                Button("システム設定を開く", action: onOpenSettings)
                    .controlSize(.small)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 必須か任意か。必須が 1 つでも欠けていると監視を始められないので、ひと目で分かるようにする。
    private var badge: some View {
        Text(kind.isRequired ? "必須" : "任意")
            .font(.system(size: 10))
            .bold()
            .foregroundStyle(kind.isRequired ? Color.orange : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (kind.isRequired ? Color.orange : Color.secondary).opacity(0.15),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    private var indicatorColor: Color {
        switch state.grant {
        case .granted: return .green
        case .denied: return .red
        case .undetermined: return .gray
        }
    }

    private var indicatorLabel: String {
        switch state.grant {
        case .granted: return "許可済み"
        case .denied: return "拒否"
        case .undetermined: return "未決定"
        }
    }
}
