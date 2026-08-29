import AppKit
import Foundation

/// 実機でしか確かめられない経路を、一度に通して結果を出す。
///
/// 単体テストは「自分で書いたスタブ相手に、自分で書いたロジックが仕様どおりか」しか見ていない。
/// カメラが本当に写るか、ScreenCaptureKit が本当に撮れるか、Vision が本当に顔を見つけるかは、
/// 署名済みの `.app` の中で実際に呼んでみないと分からない。
///
/// 使い方:
/// ```sh
/// MIHARI_SELFTEST=1 ./Mihari.app/Contents/MacOS/Mihari
/// ```
public enum SelfTest {

    /// 環境変数で自己診断が要求されているか。
    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment["MIHARI_SELFTEST"] == "1"
    }

    /// 1 項目の結果。
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    /// 実行して標準出力に並べ、すべて成功なら `true`。
    @MainActor
    public static func run() async -> Bool {
        var results: [Result] = []
        results.append(await screenshot())
        results.append(await camera())
        results.append(contentsOf: vision(from: results))
        results.append(gaze())
        results.append(await music())
        results.append(await overlay())

        FileHandle.standardOutput.write(Data(render(results).utf8))
        return results.allSatisfy(\.ok)
    }

    @MainActor
    private static func screenshot() async -> Result {
        do {
            let artifact = try await CaptureService().captureScreenshot()
            let size = (try? Data(contentsOf: artifact.url).count) ?? 0
            try? artifact.delete()
            return Result(name: "画面のスクショ", ok: size > 0, detail: "\(size) バイトの PNG を保存した")
        } catch {
            return Result(name: "画面のスクショ", ok: false, detail: describe(error))
        }
    }

    @MainActor
    private static func camera() async -> Result {
        do {
            let artifact = try await CaptureService().capturePhoto()
            let data = try Data(contentsOf: artifact.url)
            try? artifact.delete()
            lastPhoto = data
            return Result(name: "カメラで 1 枚撮る", ok: !data.isEmpty, detail: "\(data.count) バイトの PNG を保存した")
        } catch {
            return Result(name: "カメラで 1 枚撮る", ok: false, detail: describe(error))
        }
    }

    /// カメラが撮れたときだけ、その写真に対して見立てを試す。
    private static func vision(from results: [Result]) -> [Result] {
        guard let data = lastPhoto, let image = try? CaptureImageCodec.decode(data) else {
            return [Result(name: "写真の見立て", ok: false, detail: "写真が無いので試せない")]
        }
        let outcome = FaceVisionAnalyzer.analyze(image)
        let label = VisionLabelClassifier.classify(outcome: outcome)
        // 顔が写っていなくても「動いた」ことは分かる。判定内容ではなく、実行できたかを見る。
        return [Result(name: "写真の見立て", ok: true, detail: "\(outcome) → \(label.rawValue)")]
    }

    /// いま画面を見ているか。判定の入力そのものなので、実機で値を見ておきたい。
    private static func gaze() -> Result {
        guard let data = lastPhoto, let image = try? CaptureImageCodec.decode(data) else {
            return Result(name: "視線の判定", ok: false, detail: "写真が無いので試せない")
        }
        let state = GazeState.from(outcome: FaceVisionAnalyzer.analyze(image))
        return Result(name: "視線の判定", ok: true, detail: state.label)
    }

    /// 音楽を止められるか。オートメーション権限が無ければ失敗するが、それも分かってよい情報。
    @MainActor
    private static func music() async -> Result {
        let outcome = await AppleScriptMusicController().stopPlaying()
        return Result(name: "音楽を止める", ok: true, detail: "\(outcome)")
    }

    /// **一番危険な経路。** 全画面を覆ったあと、本当に自動で解除されるかを見る。
    /// 解除されないと Mac が操作不能になるので、上限秒数を短くして必ず確かめる。
    @MainActor
    private static func overlay() async -> Result {
        let model = OverlayModel(
            presenter: ScreenSaverOverlayPresenter(),
            maxDurationSeconds: 2,
            resumeMusicAfterDismiss: false
        )
        model.show()
        let shown = model.isPresented

        // 上限の 2 秒 + 余裕を見て待ち、自力で消えていることを確かめる。
        try? await Task.sleep(for: .seconds(5))

        if model.isPresented {
            // 消えていない。これは実害が出る不具合なので、手で消したうえで失敗として報告する。
            model.dismissManually()
            return Result(name: "全画面オーバーレイの自動解除", ok: false, detail: "上限を過ぎても解除されなかった")
        }
        return Result(
            name: "全画面オーバーレイの自動解除",
            ok: shown,
            detail: shown ? "表示され、2 秒で自動解除された" : "そもそも表示できなかった"
        )
    }

    private nonisolated(unsafe) static var lastPhoto: Data?

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func render(_ results: [Result]) -> String {
        var lines = ["Mihari 自己診断", String(repeating: "-", count: 40)]
        for result in results {
            lines.append("\(result.ok ? "OK" : "NG")  \(result.name): \(result.detail)")
        }
        let failed = results.filter { !$0.ok }.count
        lines.append(String(repeating: "-", count: 40))
        lines.append(failed == 0 ? "すべて成功" : "\(failed) 件失敗")
        return lines.joined(separator: "\n") + "\n"
    }
}
