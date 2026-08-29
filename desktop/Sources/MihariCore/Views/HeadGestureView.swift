import SwiftUI

/// AirPods 首振り Yes/No の動作確認画面。
///
/// 生の pitch/yaw を出しているのは、実機で閾値(`HeadGestureThresholds`)を調整するため。
/// 数値が見えないと、どのくらいの振れ幅で反応させるべきか判断できない。
public struct HeadGestureView: View {
    @ObservedObject var controller: HeadGestureController

    public init(controller: HeadGestureController) {
        self.controller = controller
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                availabilitySection
                rawValuesSection
                controls
                resultSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            controller.refreshAvailability()
            controller.startPreview()
        }
        .onDisappear {
            controller.stopPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AirPods 首振り").font(.title2).bold()
            Text("うなずくと「はい」、横に振ると「いいえ」と判定される。カメラのフォールバックは持たない。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var availabilitySection: some View {
        HStack(spacing: 8) {
            Image(systemName: availabilityIcon)
                .foregroundStyle(availabilityColor)
            Text(availabilityLabel)
            Spacer()
            Button("状態を取り直す") {
                controller.refreshAvailability()
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rawValuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生の pitch / yaw").font(.headline)
            if let sample = controller.latestSample {
                HStack(spacing: 24) {
                    valueLabel("pitch(うなずき)", degrees: sample.pitchDegrees)
                    valueLabel("yaw(首振り)", degrees: sample.yawDegrees)
                }
            } else {
                Text(controller.isPreviewing ? "値を待っている…" : "プレビュー停止中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func valueLabel(_ title: String, degrees: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f°", degrees))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("質問してみる") {
                Task { await controller.askSampleQuestion() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isAsking || !controller.availability.isAvailable)

            if controller.isAsking {
                ProgressView().controlSize(.small)
                Text("首振りを待っている…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("結果").font(.headline)
            if let response = controller.lastResponse {
                Label(resultLabel(for: response), systemImage: resultIcon(for: response))
                    .font(.callout)
                    .foregroundStyle(resultColor(for: response))
            } else {
                Text("まだ質問していない。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var availabilityIcon: String {
        controller.availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var availabilityColor: Color {
        controller.availability.isAvailable ? .green : .orange
    }

    private var availabilityLabel: String {
        controller.availability.isAvailable
            ? "利用できる"
            : (controller.availability.reason ?? "利用できない")
    }

    private func resultLabel(for response: HeadGestureResponse) -> String {
        switch response {
        case .yes: return "はい"
        case .no: return "いいえ"
        case .timedOut: return "時間切れ"
        case .unavailable(let reason): return "利用できない: \(reason)"
        }
    }

    private func resultIcon(for response: HeadGestureResponse) -> String {
        switch response {
        case .yes: return "hand.thumbsup.fill"
        case .no: return "hand.thumbsdown.fill"
        case .timedOut: return "clock.badge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private func resultColor(for response: HeadGestureResponse) -> Color {
        switch response {
        case .yes: return .green
        case .no: return .red
        case .timedOut, .unavailable: return .orange
        }
    }
}
