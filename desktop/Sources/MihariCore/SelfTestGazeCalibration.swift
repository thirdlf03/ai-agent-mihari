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
        defer { monitor.stop() }
        // 露出が落ち着くまで待つ。
        try? await Task.sleep(for: .seconds(2))

        // 「見る」を毎回挟み、フェーズ間で指標がちゃんと復帰するかも見る。
        let cycle: [GazePhase] = [.look, .phone, .look, .side, .look, .leave]
        var samples: [GazePhase: [GazeSample]] = [:]
        for phase in cycle + cycle {
            emit("\n>>> 次: \(phase.rawValue)（2 秒後に計測開始）\n")
            try? await Task.sleep(for: .seconds(2))
            emit(">>> 3 秒間そのまま: \(phase.rawValue)\n")
            let collected = await collect(from: monitor, seconds: 3)
            samples[phase, default: []].append(contentsOf: collected)
        }

        emit("\n" + report(samples))
        return Result(name: "視線の分離", ok: true, detail: verdictLine(samples))
    }

    /// バッファリングで指示が遅れて出ないよう、標準出力へ直接書く。
    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// 指定秒数のあいだ、新しいフレームが来るたびに記録する。
    private static func collect(from monitor: GazeMonitor, seconds: TimeInterval) async -> [GazeSample] {
        var collected: [GazeSample] = []
        var lastSeen: Date?
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let observation = monitor.observation
            // 同じフレームを二重に数えない。
            guard let updatedAt = observation.updatedAt, updatedAt != lastSeen else { continue }
            lastSeen = updatedAt
            collected.append(
                GazeSample(
                    state: observation.state,
                    eyeOpenness: observation.eyeOpenness,
                    noseOffset: observation.noseOffset,
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
            lines.append("  yaw " + rangeText(list.compactMap(\.yaw)))
        }
        lines.append(String(repeating: "-", count: 60))
        lines.append(contentsOf: recommendations(samples))
        return lines.joined(separator: "\n") + "\n"
    }

    /// 「見る」を基準に、離す側のフェーズごとに分離できる指標を推定する。
    private static func recommendations(_ samples: [GazePhase: [GazeSample]]) -> [String] {
        guard let look = samples[.look], !look.isEmpty else {
            return ["基準になる「画面を見る」が測れておらず、推奨を出せない"]
        }
        let lookEAR = look.compactMap(\.eyeOpenness)
        let lookNose = look.compactMap { $0.noseOffset.map(abs) }

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
            // 顔が写ったままなら、指標の分離を探す。
            let awayEAR = away.compactMap(\.eyeOpenness)
            let awayNose = away.compactMap { $0.noseOffset.map(abs) }
            if let earMax = awayEAR.max(), let earMin = lookEAR.min(), earMax < earMin {
                lines.append(
                    String(
                        format: "  %@ → 目の開きで分離できる(しきい値 %.3f を推奨)",
                        phase.rawValue, (earMax + earMin) / 2))
            } else if let noseMin = awayNose.min(), let noseMax = lookNose.max(), noseMin > noseMax {
                lines.append(
                    String(
                        format: "  %@ → |鼻オフセット|で分離できる(しきい値 %.3f を推奨)",
                        phase.rawValue, (noseMin + noseMax) / 2))
            } else {
                lines.append("  \(phase.rawValue) → どの指標でも「見る」と重なっていて分離できない")
            }
        }
        return lines
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
