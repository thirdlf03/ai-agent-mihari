import AVFoundation
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
        results.append(cameras())
        results.append(await screenshot())
        results.append(await camera())
        results.append(contentsOf: vision(from: results))
        results.append(gaze())
        results.append(await continuousGaze())
        results.append(await music())
        results.append(await overlay())
        results.append(await headGesture())

        FileHandle.standardOutput.write(Data(render(results).utf8))
        return results.allSatisfy(\.ok)
    }

    /// どのカメラを掴んでいるか。Continuity Camera(iPhone)が既定に選ばれていると、
    /// 机に置いた iPhone が天井を撮って「顔がいない」と判定され続ける。
    private static func cameras() -> Result {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let selected = AVCaptureDevice.default(for: .video)
        let list = session.devices.map { device in
            let mark = device.uniqueID == selected?.uniqueID ? "★" : "  "
            return "\(mark)\(device.localizedName)[\(device.deviceType.rawValue)]"
        }
        return Result(
            name: "カメラの選択",
            ok: selected != nil,
            detail: list.isEmpty ? "カメラが見つからない" : list.joined(separator: " / ")
        )
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
            // 何が写っていたのかを目で確かめられるよう、診断時だけ手元に残す。
            if let keep = ProcessInfo.processInfo.environment["MIHARI_SELFTEST_KEEP_PHOTO"] {
                try? data.write(to: URL(fileURLWithPath: keep))
            }
            let brightness = averageBrightness(of: data)
            let note = brightness.map { String(format: "平均の明るさ %.3f", $0) } ?? "明るさ不明"
            return Result(name: "カメラで 1 枚撮る", ok: !data.isEmpty, detail: "\(data.count) バイト / \(note)")
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
        let outcome = FaceVisionAnalyzer.analyze(image)
        let state = GazeState.from(outcome: outcome)

        // どの条件で落ちているのかが分からないと閾値を詰められないので、生の値も出す。
        var note = state.label
        if case .faceFound(let metrics) = outcome {
            let openness = metrics.averageEyeOpenness.map { String(format: "%.3f", $0) } ?? "-"
            let yaw = metrics.yawRadians.map { String(format: "%.3f", $0) } ?? "-"
            note += "（目の開き \(openness) / しきい値 \(VisionLabelClassifier.defaultClosedEyeOpennessThreshold)"
            note += " · yaw \(yaw)＝判定には使わない）"
        } else {
            note += "（\(outcome)）"
        }
        return Result(name: "視線の判定", ok: true, detail: note)
    }

    /// 連続監視で視線が安定して取れるか。
    ///
    /// 単発フレームは瞬きや一瞬の視線移動で判定が飛ぶ。開けっぱなしにして
    /// 数秒ぶんを見たときに、ちゃんと落ち着いた結果になるかを確かめる。
    private static func continuousGaze() async -> Result {
        let monitor = GazeMonitor()
        monitor.start()
        defer { monitor.stop() }

        var samples: [GazeState] = []
        var openings: [Double] = []
        var yaws: [Double] = []
        var lastOpenness: Double?
        // 露出が落ち着くまでの待ちを含めて 6 秒ぶん見る。
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(250))
            let observation = monitor.observation
            guard observation.updatedAt != nil else { continue }
            samples.append(observation.state)
            if let openness = observation.eyeOpenness {
                openings.append(openness)
                lastOpenness = openness
            }
            if let yaw = observation.yawRadians {
                yaws.append(yaw)
            }
        }

        guard !samples.isEmpty else {
            return Result(name: "視線の連続監視", ok: false, detail: "フレームが 1 枚も解析されなかった")
        }
        _ = lastOpenness
        let looking = samples.filter { $0 == .lookingAtScreen }.count
        let notLooking = samples.filter { $0 == .notLooking }.count

        // 静止画と映像フレームで目の開きの出方が違うなら、閾値を測り直す必要がある。
        var spread = "顔なし"
        if !openings.isEmpty {
            let sorted = openings.sorted()
            spread = String(
                format: "最小 %.3f / 中央 %.3f / 最大 %.3f（%d/%d フレームで顔あり）",
                sorted.first ?? 0,
                sorted[sorted.count / 2],
                sorted.last ?? 0,
                openings.count,
                samples.count
            )
        }
        var yawSpread = "yaw なし"
        if !yaws.isEmpty {
            let sorted = yaws.map(abs).sorted()
            // 判定には使っていないが、将来この値が返るようになったか気づけるよう出しておく。
            yawSpread = String(
                format: "|yaw| 最小 %.3f / 中央 %.3f / 最大 %.3f（判定には未使用）",
                sorted.first ?? 0,
                sorted[sorted.count / 2],
                sorted.last ?? 0
            )
        }
        return Result(
            name: "視線の連続監視",
            ok: true,
            detail: "見ている \(looking) / 見ていない \(notLooking) · 目の開き \(spread) · \(yawSpread)"
        )
    }

    /// いま音楽が鳴っているか。**説教を出すかどうかの条件そのもの。**
    ///
    /// `MIHARI_SELFTEST_STOP_MUSIC=1` を付けたときだけ実際に止める。
    /// 付けなければ問い合わせるだけで、再生を邪魔しない。
    @MainActor
    private static func music() async -> Result {
        let controller = AppleScriptMusicController()
        let playing = await controller.nowPlaying()

        guard ProcessInfo.processInfo.environment["MIHARI_SELFTEST_STOP_MUSIC"] == "1" else {
            return Result(
                name: "音楽の再生状況",
                ok: true,
                detail: "\(playing.label) → 説教は\(playing.isPlaying ? "出る" : "出ない")"
            )
        }

        let outcome = await controller.stopPlaying()
        return Result(name: "音楽を止める", ok: true, detail: "\(playing.label) → \(outcome)")
    }

    /// **一番危険な経路。** 全画面を覆ったあと、本当に自動で解除されるかを見る。
    /// 解除されないと Mac が操作不能になるので、上限秒数を短くして必ず確かめる。
    @MainActor
    private static func overlay() async -> Result {
        // 実物の音楽コントローラを使うので、鳴っていれば本当に止まる。
        // 本番は止めっぱなしが既定(サボっていた人に音楽を返す理由がない)だが、
        // 診断で人の再生を奪ったまま終わるのは筋が違うので、ここだけ再開させる。
        let model = OverlayModel(
            presenter: ScreenSaverOverlayPresenter(),
            maxDurationSeconds: 2,
            resumeMusicAfterDismiss: true
        )
        let wasPlaying = await AppleScriptMusicController().nowPlaying()
        model.show()
        let shown = model.isPresented

        // 上限の 2 秒 + 余裕を見て待ち、自力で消えていることを確かめる。
        try? await Task.sleep(for: .seconds(5))

        if model.isPresented {
            // 消えていない。これは実害が出る不具合なので、手で消したうえで失敗として報告する。
            model.dismissManually()
            return Result(name: "全画面オーバーレイの自動解除", ok: false, detail: "上限を過ぎても解除されなかった")
        }
        var detail = shown ? "表示され、2 秒で自動解除された" : "そもそも表示できなかった"
        if wasPlaying.isPlaying {
            detail += "（\(wasPlaying.label)を止めて、解除時に再開した）"
        }
        return Result(name: "全画面オーバーレイの自動解除", ok: shown, detail: detail)
    }

    /// 写真全体の平均輝度(0=真っ黒, 1=真っ白)。暗すぎて顔が取れないのかを切り分ける。
    private static func averageBrightness(of data: Data) -> Double? {
        guard let image = try? CaptureImageCodec.decode(data) else { return nil }
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let total = pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(pixels.count * 255)
    }

    /// AirPods のヘッドトラッキングが実際に届くか。
    ///
    /// `CMHeadphoneMotionManager` は SaboriLab の 21 モジュールで唯一「未検証」だった API。
    /// `isDeviceMotionAvailable` は AirPods が未接続でも true を返す(機種対応を示すだけ)ので、
    /// **実際にサンプルが流れてくるか**を見ないと確かめたことにならない。
    ///
    /// `MIHARI_SELFTEST_HEAD_GESTURE=1` を付けたときだけ実行する。
    /// 人が首を振らないと判定まで到達しないため、既定では疎通だけを見る。
    @MainActor
    private static func headGesture() async -> Result {
        let source = AirPodsHeadOrientationSource()
        let availability = source.availability()
        guard availability.isAvailable else {
            return Result(
                name: "AirPods の首振り",
                ok: false,
                detail: availability.reason ?? "利用できない"
            )
        }

        // まずサンプルが本当に流れてくるかを見る。
        var samples: [HeadOrientationSample] = []
        let collector = Task {
            for await sample in source.updates() {
                samples.append(sample)
                if samples.count >= 40 { break }
            }
        }
        try? await Task.sleep(for: .seconds(3))
        collector.cancel()

        guard !samples.isEmpty else {
            return Result(
                name: "AirPods の首振り",
                ok: false,
                detail: "利用可能と出るがサンプルが 1 件も流れてこない（AirPods 未接続の可能性）"
            )
        }

        let pitches = samples.map { $0.pitchDegrees }
        let yaws = samples.map { $0.yawDegrees }
        let spread = String(
            format: "%d 件受信 · pitch %.1f〜%.1f° · yaw %.1f〜%.1f°",
            samples.count,
            pitches.min() ?? 0,
            pitches.max() ?? 0,
            yaws.min() ?? 0,
            yaws.max() ?? 0
        )

        guard ProcessInfo.processInfo.environment["MIHARI_SELFTEST_HEAD_GESTURE"] == "1" else {
            return Result(name: "AirPods の首振り", ok: true, detail: spread)
        }

        // ここからは人が首を振らないと決着しない。
        // どちらに振るかを指示して、返ってきた判定と突き合わせる。
        // 指示しないと「縦に振ったのに no が出た」のか「横に振って正しく no」なのか区別できない。
        let questioner = HeadGestureQuestioner(source: source)
        var rounds: [String] = []
        var allCorrect = true

        for (instruction, expected) in [("縦(うなずく)", HeadGestureResponse.yes), ("横(振る)", .no)] {
            FileHandle.standardOutput.write(
                Data("\n>>> 6 秒以内に首を \(instruction) に振ってください\n".utf8)
            )
            let answer = await questioner.ask(prompt: "自己診断 \(instruction)")
            let correct = answer == expected
            allCorrect = allCorrect && correct
            rounds.append("\(instruction)→\(describe(answer))\(correct ? "" : "（期待: \(describe(expected))）")")
            // 続けて振らせると前の動きを拾ってしまうので、少し空ける。
            try? await Task.sleep(for: .seconds(1))
        }

        return Result(
            name: "AirPods の首振り",
            ok: allCorrect,
            detail: "\(spread) · " + rounds.joined(separator: " / ")
        )
    }

    private static func describe(_ response: HeadGestureResponse) -> String {
        switch response {
        case .yes: return "はい"
        case .no: return "いいえ"
        case .timedOut: return "時間切れ"
        case .unavailable(let reason): return "使えない(\(reason))"
        }
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
