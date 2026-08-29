import Foundation

/// 視線しきい値のキャリブレーション計測。
///
/// 「画面を見る → 目を離す」を指示に従って繰り返し、そのあいだの生指標
/// (顔検出の成否 / 目の開き / 鼻の左右オフセット / yaw)をフェーズごとに集計する。
/// **どの指標なら「見ている」と「見ていない」を分離できるか**を実測で確かめ、
/// しきい値の根拠にするための道具。判定ロジック自体は変更しない。
///
/// 使い方:
/// ```sh
/// MIHARI_SELFTEST=1 MIHARI_SELFTEST_GAZE=1 ./Mihari.app/Contents/MacOS/Mihari
/// ```
extension SelfTest {

    /// 計測する 1 フェーズの種類。
    private enum GazePhase: String, CaseIterable {
        case look = "画面を見る"
        case phone = "スマホを見る(下を向く)"
        case side = "横を向く(画面から視線を外す)"
        case leave = "席を立つ・画面外に消える"
    }

    /// 1 フレーム分の記録。
    private struct GazeSample {
        let state: GazeState
        let eyeOpenness: Double?
        let noseOffset: Double?
        let noseDrop: Double?
        let yaw: Double?

        /// 顔(ランドマーク)が取れたか。指標が 1 つでも出ていれば取れている。
        var faceDetected: Bool { eyeOpenness != nil || noseOffset != nil }
    }

    /// `MIHARI_SELFTEST_GAZE=1` を付けたときだけ実行する。
    @MainActor
    static func gazeCalibration() async -> Result {
        guard ProcessInfo.processInfo.environment["MIHARI_SELFTEST_GAZE"] == "1" else {
            return Result(name: "視線の分離", ok: true, detail: "省略（MIHARI_SELFTEST_GAZE=1 で測る）")
        }

        let monitor = GazeMonitor()
        monitor.start()

        // フレームが流れ始めるまで待つ(露出の安定待ちを兼ねる)。
        // 1 枚も来ないままフェーズを回すと 70 秒無駄にするので、来なければ即失敗にする。
        guard await waitForFirstFrame(monitor, timeoutSeconds: 10) else {
            await monitor.stopAndWait()
            return Result(
                name: "視線の分離",
                ok: false,
                detail: "カメラからフレームが 1 枚も来ない。直前のカメラ解放との競合か、カメラが使えない"
            )
        }

        // 「見る」を毎回挟み、フェーズ間で指標がちゃんと復帰するかも見る。
        let cycle: [GazePhase] = [.look, .phone, .look, .side, .look, .leave]
        var samples: [GazePhase: [GazeSample]] = [:]
        for phase in cycle + cycle {
            emit("\n>>> 次: \(phase.rawValue)（2 秒後に計測開始）\n")
            try? await Task.sleep(for: .seconds(2))
            emit(">>> 3 秒間そのまま: \(phase.rawValue)\n")
            // 動作へ移る途中のフレームが混ざると分布が汚れるので、最初の 1 秒は捨てる。
            let collected = await collect(from: monitor, seconds: 4, discardFirstSeconds: 1)
            samples[phase, default: []].append(contentsOf: collected)
        }

        // 後続のテストが同じカメラを開き直す可能性があるので、解放を待ってから返す。
        await monitor.stopAndWait()

        emit("\n" + report(samples))
        return Result(name: "視線の分離", ok: true, detail: verdictLine(samples))
    }

    /// 最初のフレームが解析されるまで待つ。時間内に来なければ `false`。
    private static func waitForFirstFrame(
        _ monitor: GazeMonitor, timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if monitor.observation.updatedAt != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// バッファリングで指示が遅れて出ないよう、標準出力へ直接書く。
    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// 指定秒数のあいだ、新しいフレームが来るたびに記録する。
    /// `discardFirstSeconds` のあいだのフレームは、動作の途中とみなして捨てる。
    private static func collect(
        from monitor: GazeMonitor, seconds: TimeInterval, discardFirstSeconds: TimeInterval = 0
    ) async -> [GazeSample] {
        var collected: [GazeSample] = []
        var lastSeen: Date?
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let observation = monitor.observation
            // 同じフレームを二重に数えない。
            guard let updatedAt = observation.updatedAt, updatedAt != lastSeen else { continue }
            lastSeen = updatedAt
            guard Date().timeIntervalSince(start) >= discardFirstSeconds else { continue }
            collected.append(
                GazeSample(
                    state: observation.state,
                    eyeOpenness: observation.eyeOpenness,
                    noseOffset: observation.noseOffset,
                    noseDrop: observation.noseDrop,
                    yaw: observation.yawRadians
                ))
        }
        return collected
    }

    // MARK: - 集計

    /// フェーズごとの実測値と、分離できる指標の見立てを人が読める形にする。
    private static func report(_ samples: [GazePhase: [GazeSample]]) -> String {
        var lines = ["視線キャリブレーション結果", String(repeating: "-", count: 60)]
        for phase in GazePhase.allCases {
            let list = samples[phase] ?? []
            guard !list.isEmpty else {
                lines.append("\(phase.rawValue): フレームが取れなかった")
                continue
            }
            let faceRate = Double(list.filter(\.faceDetected).count) / Double(list.count)
            lines.append(String(format: "%@ (%d フレーム)", phase.rawValue, list.count))
            lines.append(String(format: "  顔検出率 %3.0f%%", faceRate * 100))
            lines.append("  目の開き " + rangeText(list.compactMap(\.eyeOpenness)))
            lines.append("  鼻オフセット " + rangeText(list.compactMap(\.noseOffset)))
            lines.append("  |鼻オフセット| " + rangeText(list.compactMap { $0.noseOffset.map(abs) }))
            lines.append("  鼻の縦(ピッチ) " + rangeText(list.compactMap(\.noseDrop)))
            lines.append("  yaw " + rangeText(list.compactMap(\.yaw)))
        }
        lines.append(String(repeating: "-", count: 60))
        lines.append(contentsOf: recommendations(samples))
        return lines.joined(separator: "\n") + "\n"
    }

    /// 「見る」を基準に、離す側のフェーズごとに分離できる指標を推定する。
    ///
    /// min/max の比較だと外れ値 1 つ(振り向き途中の残りなど)で分離が消えるので、
    /// 「離す側の四分位(25%)が、見る側のほぼ全体(95%)より外側にあるか」で判定する。
    private static func recommendations(_ samples: [GazePhase: [GazeSample]]) -> [String] {
        guard let look = samples[.look], !look.isEmpty else {
            return ["基準になる「画面を見る」が測れておらず、推奨を出せない"]
        }
        let lookEAR = look.compactMap(\.eyeOpenness)
        let lookNose = look.compactMap { $0.noseOffset.map(abs) }
        let lookDrop = look.compactMap(\.noseDrop)
        let dropBaseline = quantile(lookDrop, 0.5)

        var lines: [String] = ["推奨:"]
        for phase in [GazePhase.phone, .side, .leave] {
            guard let away = samples[phase], !away.isEmpty else { continue }
            let faceRate = Double(away.filter(\.faceDetected).count) / Double(away.count)
            if faceRate < 0.3 {
                lines.append(
                    String(
                        format: "  %@ → 顔検出率 %.0f%% に落ちる。現行の「顔なし=見ていない」で拾える",
                        phase.rawValue, faceRate * 100))
                continue
            }

            // 顔が写ったままなら、指標ごとに分離を探す。
            var separable: [String] = []

            // 目の開き: 離す側が下に離れる。
            let awayEAR = away.compactMap(\.eyeOpenness)
            if let awayHigh = quantile(awayEAR, 0.75), let lookLow = quantile(lookEAR, 0.05),
                awayHigh < lookLow
            {
                separable.append(String(format: "目の開き(しきい値 %.3f)", (awayHigh + lookLow) / 2))
            }

            // |鼻オフセット|: 離す側が上に離れる。
            let awayNose = away.compactMap { $0.noseOffset.map(abs) }
            if let awayLow = quantile(awayNose, 0.25), let lookHigh = quantile(lookNose, 0.95),
                awayLow > lookHigh
            {
                separable.append(String(format: "|鼻オフセット|(しきい値 %.3f)", (awayLow + lookHigh) / 2))
            }

            // 鼻の縦: 「見る」の中央値を基準に、そこからの乖離が上に離れるか。
            if let baseline = dropBaseline {
                let lookDeviation = lookDrop.map { abs($0 - baseline) }
                let awayDeviation = away.compactMap(\.noseDrop).map { abs($0 - baseline) }
                if let awayLow = quantile(awayDeviation, 0.25),
                    let lookHigh = quantile(lookDeviation, 0.95),
                    awayLow > lookHigh
                {
                    separable.append(
                        String(
                            format: "鼻の縦の乖離(基準 %.3f から %.3f 以上ずれたら)",
                            baseline, (awayLow + lookHigh) / 2))
                }
            }

            if separable.isEmpty {
                lines.append("  \(phase.rawValue) → どの指標でも「見る」と重なっていて分離できない")
            } else {
                lines.append("  \(phase.rawValue) → " + separable.joined(separator: " / ") + " で分離できる")
            }
        }
        return lines
    }

    /// 分位点。q は 0.0〜1.0。値が無ければ nil。
    private static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * q)
        return sorted[index]
    }

    /// 自己診断の一覧に載せる一行。詳細は標準出力のレポートで見る。
    private static func verdictLine(_ samples: [GazePhase: [GazeSample]]) -> String {
        let counts = GazePhase.allCases.map { phase in
            "\(phase.rawValue) \(samples[phase]?.count ?? 0)"
        }
        return "計測完了(フレーム数: " + counts.joined(separator: " / ") + ")。詳細は上のレポート"
    }

    /// min / 中央値 / max を 1 行にする。値が無ければ「—」。
    private static func rangeText(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—(取れず)" }
        let sorted = values.sorted()
        return String(
            format: "min %.3f / 中央 %.3f / max %.3f",
            sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
    }
}
