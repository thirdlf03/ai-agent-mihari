import Foundation
import Testing

@testable import MihariCore

@Suite("同封セリフ")
struct BundledVoiceLinesTests {

    /// `lines.json` の形。同封分と突き合わせるために、ソースの方を直に読む。
    private struct Document: Decodable {
        let speaker: Int
        let kinds: [String: [String]]
    }

    /// リポジトリの `Resources/voice/lines.json`。同封したバンドルではなく、原本を読む。
    private func sourceDocument() throws -> Document {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MihariCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // desktop
            .appendingPathComponent("Sources/MihariCore/Resources/voice/lines.json")
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }

    @Test("どの区分にも 1 本以上ある")
    func everyKindHasLines() {
        for kind in BundledVoiceKind.allCases {
            #expect(!BundledVoiceLines.shared.lines(for: kind).isEmpty, "\(kind.rawValue) が空")
        }
    }

    @Test("同封分は lines.json と同じ本数・同じ並び")
    func bundledLinesMatchTheSource() throws {
        let document = try sourceDocument()

        #expect(BundledVoiceLines.shared.speaker == document.speaker)
        // lines.json に書いたキーは、すべて区分として扱えること。
        #expect(Set(document.kinds.keys) == Set(BundledVoiceKind.allCases.map(\.rawValue)))
        for kind in BundledVoiceKind.allCases {
            #expect(BundledVoiceLines.shared.lines(for: kind) == document.kinds[kind.rawValue])
        }
    }

    @Test("全セリフに音声ファイルがある")
    func everyLineHasAudio() {
        // 足りなければ scripts/generate_voice_lines.py を流し直す。
        for kind in BundledVoiceKind.allCases {
            for index in BundledVoiceLines.shared.lines(for: kind).indices {
                #expect(
                    BundledVoiceLines.shared.audio(for: kind, at: index) != nil,
                    "\(kind.rawValue)/\(String(format: "%02d", index)).m4a が無い"
                )
            }
        }
    }

    @Test("選んだセリフと音声はずれない")
    func pickedLineAndAudioMatch() {
        for kind in BundledVoiceKind.allCases {
            let picked = BundledVoiceLines.shared.pick(kind)
            #expect(picked != nil)
            guard let picked else { continue }
            #expect(BundledVoiceLines.shared.lines(for: kind).contains(picked.text))
            #expect(picked.audio == BundledVoiceLines.shared.audio(for: kind, text: picked.text))
        }
    }

    @Test("lines.json に無い文には音声が付かない")
    func unknownTextHasNoAudio() {
        // speech.json で差し替えたセリフは、吹き出しだけになる。
        #expect(BundledVoiceLines.shared.audio(for: .greeting, text: "これは同封していないセリフ") == nil)
    }

    @Test("ペットのひとりごとは lines.json から作る")
    func petLinesComeFromTheSameFile() {
        for kind in PetSpeechLines.Kind.allCases {
            let candidates = BundledVoiceLines.shared.lines(for: kind.bundled)
            let line = PetSpeechLines.builtIn.randomLine(for: kind)
            #expect(line != nil, "\(kind.rawValue) のセリフが無い")
            #expect(candidates.contains(line ?? ""))
        }
    }

    @Test("検知の区分は fallback.py と同じ順で決まる")
    func detectionKindFollowsTheSameOrder() {
        // 寝ている > 席にいない > iPhone 操作中 > 当たりの強さ、の順に当てはめる。
        #expect(
            BundledVoiceKind.forDetection(vision: .sleeping, iphone: .active, escalation: .expose) == .sleeping
        )
        #expect(
            BundledVoiceKind.forDetection(vision: .absent, iphone: .active, escalation: .expose) == .absent
        )
        #expect(
            BundledVoiceKind.forDetection(vision: .unknown, iphone: .active, escalation: .expose) == .iphoneActive
        )
        #expect(
            BundledVoiceKind.forDetection(vision: .lookingAway, iphone: .idle, escalation: .nudge) == .nudge
        )
        #expect(
            BundledVoiceKind.forDetection(vision: .unknown, iphone: .unreachable, escalation: .warn) == .warn
        )
        #expect(
            BundledVoiceKind.forDetection(vision: .unknown, iphone: .idle, escalation: .expose) == .expose
        )
    }

    @Test("説教の固定文言は sermon の 1 本目")
    @MainActor
    func fallbackSermonIsTheFirstBundledLine() {
        #expect(OverlayModel.fallbackSermonLine == BundledVoiceLines.shared.lines(for: .sermon).first)
    }
}
