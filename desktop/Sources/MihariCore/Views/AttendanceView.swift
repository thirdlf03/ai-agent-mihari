import SwiftUI

/// 在席スタンプ画面。
///
/// Touch ID(またはパスワード)で在席を証明し、履歴と猶予の残り時間を表示する。
/// `RootView` への組み込みは親が行うため、ここでは単体で動く `View` を用意するだけにする。
public struct AttendanceView: View {
    @ObservedObject var model: AttendanceModel

    /// 猶予の残り時間の表示更新に使うタイマー。認証結果そのものには関与しない。
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(model: AttendanceModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                if let message = model.lastMessage {
                    messageBox(message)
                }
                graceSection
                historySection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(ticker) { _ in
            // 猶予の残り時間を毎秒再計算させるための空更新。
            model.objectWillChange.send()
        }
        .task {
            model.refreshAvailability()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("在席スタンプ").font(.title2).bold()
            Text("指紋(またはパスワード)で「席にいる」を証明する。押した直後はサボり判定が見送られる。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(model.biometryTypeText, systemImage: "touchid")
                Label(
                    model.isBiometricsAvailable
                        ? "生体認証: 使える" : (model.isDeviceOwnerAvailable ? "生体認証: 使えない(パスワードで代替)" : "認証手段なし"),
                    systemImage: model.isBiometricsAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.isBiometricsAvailable ? Color.green : Color.orange)
            }
            .font(.callout)
            .padding(.top, 2)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("スタンプを押す") { Task { await model.stamp() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAuthenticating || (!model.isBiometricsAvailable && !model.isDeviceOwnerAvailable))
            Button("利用可否を確認し直す") { model.refreshAvailability() }
            if model.isAuthenticating {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private func messageBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var graceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("猶予期間").font(.headline)
            if model.isWithinGracePeriod {
                Text("在席が証明済み。残り \(Int(model.graceRemainingSeconds.rounded(.up))) 秒はサボり判定を見送る。")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("猶予期間外。スタンプを押すとサボり判定が \(Int(AttendanceGrace.defaultGracePeriod)) 秒間見送られる。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("スタンプ履歴").font(.headline)
            if model.stamps.isEmpty {
                Text("まだスタンプがない。「スタンプを押す」で最初の1件を記録できる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.stamps) { stamp in
                    HStack(spacing: 8) {
                        Text(stamp.stampedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                        Text(stamp.biometryTypeText)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
