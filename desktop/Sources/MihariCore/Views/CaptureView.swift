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
                if model.canReadScreen {
                    screenReadingSection
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
                .disabled(isBusy)

            Button("スクショを撮る") { Task { await model.captureScreenshot() } }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

            if model.canCaptureIPhone {
                Button("iPhone のスクショを撮る") { Task { await model.captureIPhoneScreenshot() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
            }

            if model.canReadScreen {
                Button("この画面を読ませて喋らせる") { Task { await model.readIPhoneScreenAloud() } }
                    // まだ撮っていなければ送るものが無い。
                    .disabled(isBusy || model.lastIPhonePNG == nil)
            }

            if model.lastArtifact != nil {
                Button("削除", role: .destructive) { model.deleteLastArtifact() }
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// どれか 1 つでも撮影中なら、全部のボタンを止める(結果の置き場が 1 つしかないため)。
    /// 読ませている最中も同じ扱いにして、その間に撮り直されないようにする。
    private var isBusy: Bool {
        model.isCapturingPhoto || model.isCapturingScreenshot || model.isCapturingIPhone
            || model.isReadingScreen
    }

    /// 読ませた結果。セリフと、読めた画面 / 読めなかった理由を並べるだけ。
    private var screenReadingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reading = model.screenReading {
                Text(reading.text).font(.callout).textSelection(.enabled)
                if let screen = reading.screen {
                    Text("画面: \(screen.app ?? "不明") / \(screen.category) / \(screen.activity)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = reading.screenError {
                    Text("画面を読めなかった: \(error)").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("まだ読ませていない。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
