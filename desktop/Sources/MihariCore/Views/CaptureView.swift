import SwiftUI

/// カメラ撮影・スクリーンショット撮影の単体確認用画面(#10)。
///
/// 検知が発火した瞬間の証拠取得を手元で試せるように、「撮る」ボタン・プレビュー・
/// 保存先パス・エラー表示だけを持つ最小限の画面にしている。タブへの組み込みは親側で行う。
public struct CaptureView: View {
    @ObservedObject var model: CaptureViewModel

    public init(model: CaptureViewModel) {
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
                previewSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("カメラ / スクリーンショット").font(.title2).bold()
            Text("検知が発火した瞬間に証拠を1枚だけ取得する。カメラは撮影の間だけセッションを開き、撮り終えたら閉じる(緑ランプは撮影中だけ点く)。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("カメラで撮る") { Task { await model.capturePhoto() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCapturingPhoto || model.isCapturingScreenshot)

            Button("スクショを撮る") { Task { await model.captureScreenshot() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCapturingPhoto || model.isCapturingScreenshot)

            if model.lastArtifact != nil {
                Button("削除", role: .destructive) { model.deleteLastArtifact() }
            }

            Spacer()

            if model.isCapturingPhoto || model.isCapturingScreenshot {
                ProgressView().controlSize(.small)
            }
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
                        .frame(maxWidth: 360, maxHeight: 240)
                        .border(Color.secondary.opacity(0.4))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(maxWidth: 360, maxHeight: 200)
                        .overlay(
                            Text("未撮影").font(.caption).foregroundStyle(.secondary)
                        )
                }
            }

            if let artifact = model.lastArtifact {
                Text("種類: \(artifact.kind.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("保存先: \(model.lastArtifact?.url.path ?? "-")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
