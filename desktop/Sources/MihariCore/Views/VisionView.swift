import SwiftUI

/// 撮った写真に Vision でラベルを付ける確認画面(#11)。
///
/// 「撮ってラベルを付ける」ボタン・プレビュー・判定結果に加えて、算出した指標の生の値
/// (目の開き具合・yaw の角度)をそのまま出す。生の値が見えないと閾値の調整ができないため。
/// 他タブへの組み込みは行っていない。
public struct VisionView: View {
    @ObservedObject var model: FaceVisionViewModel

    public init(model: FaceVisionViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                if let message = model.errorMessage {
                    errorBox(message)
                }
                HStack(alignment: .top, spacing: 16) {
                    previewSection
                    resultSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vision でラベル付け").font(.title2).bold()
            Text("撮った1枚に「寝てる / よそ見 / 不在」のラベルを付ける。判定そのものには使わず、Discord の文面とセリフ生成に渡す見立てを作るだけ。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("撮ってラベルを付ける") { Task { await model.captureAndLabel() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAnalyzing)

            if model.isAnalyzing { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("プレビュー").font(.headline)
            Group {
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 220)
                        .border(Color.secondary.opacity(0.4))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(maxWidth: 320, maxHeight: 200)
                        .overlay(Text("未撮影").font(.caption).foregroundStyle(.secondary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("判定結果").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(key: "ラベル", value: labelText)
                StatusRow(key: "検出", value: model.outcomeDescription ?? "-")
                StatusRow(key: "目の開き具合(左)", value: formattedMetric(model.metrics?.leftEyeOpenness))
                StatusRow(key: "目の開き具合(右)", value: formattedMetric(model.metrics?.rightEyeOpenness))
                StatusRow(key: "目の開き具合(平均)", value: formattedMetric(model.metrics?.averageEyeOpenness))
                StatusRow(key: "yaw(度)", value: formattedMetric(model.metrics?.yawDegrees))
            }
            Text(
                "閉眼の閾値: 平均開き具合 < \(VisionLabelClassifier.defaultClosedEyeOpennessThreshold, specifier: "%.2f") / よそ見の閾値: |yaw| > \(VisionLabelClassifier.defaultLookingAwayYawRadiansThreshold, specifier: "%.2f") rad"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var labelText: String {
        switch model.label {
        case .sleeping: return "寝てる"
        case .lookingAway: return "よそ見"
        case .absent: return "不在"
        case .unknown: return "不明"
        case nil: return "-"
        }
    }

    private func formattedMetric(_ value: Double?) -> String {
        guard let value else { return "取得できず" }
        return String(format: "%.3f", value)
    }
}

/// key-value を1行で並べる簡易表示。
private struct StatusRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
