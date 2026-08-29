import Foundation
import Testing

@testable import MihariCore

@Suite("発話の要求と応答")
struct SpeechRequestTests {

    private func encode(_ request: SpeechRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Python 側のキー名(snake_case)で送る")
    func usesSnakeCaseKeys() throws {
        let json = try encode(
            SpeechRequest(
                idleSeconds: 300,
                escalation: .expose,
                frontmostApp: "Safari",
                iphone: .active,
                vision: .sleeping
            )
        )
        #expect(json["idle_seconds"] as? Int == 300)
        #expect(json["frontmost_app"] as? String == "Safari")
        #expect(json["escalation"] as? String == "expose")
        #expect(json["iphone"] as? String == "active")
        #expect(json["vision"] as? String == "sleeping")
    }

    @Test("よそ見のラベルは looking_away として送る")
    func lookingAwayIsSnakeCase() throws {
        let json = try encode(SpeechRequest(idleSeconds: 0, vision: .lookingAway))
        #expect(json["vision"] as? String == "looking_away")
    }

    @Test("負の無操作秒数は 0 に丸める")
    func clampsNegativeIdleSeconds() {
        // デーモンは負の値を 422 で弾く。手前で丸めて無駄な往復をしない。
        #expect(SpeechRequest(idleSeconds: -10).idleSeconds == 0)
    }

    @Test("既定値は「応答なし・見立てなし・軽め」")
    func defaults() {
        let request = SpeechRequest(idleSeconds: 60)
        #expect(request.escalation == .nudge)
        #expect(request.iphone == .unreachable)
        #expect(request.vision == .unknown)
        #expect(request.frontmostApp == nil)
    }
}

@Suite("デーモンから返るセリフ")
struct SpokenLineTests {

    private func decode(_ json: String) throws -> SpokenLine {
        try JSONDecoder().decode(SpokenLine.self, from: Data(json.utf8))
    }

    @Test("音声つきの応答を読む")
    func decodesWithAudio() throws {
        let base64 = Data("RIFF".utf8).base64EncodedString()
        let line = try decode(
            #"{"text":"やあ","from_llm":true,"fallback_reason":null,"audio":"\#(base64)","audio_error":null}"#
        )
        #expect(line.text == "やあ")
        #expect(line.fromLLM)
        #expect(line.audioData == Data("RIFF".utf8))
    }

    @Test("VOICEVOX が落ちていてもセリフは読める")
    func decodesWithoutAudio() throws {
        let line = try decode(
            #"{"text":"やあ","from_llm":false,"fallback_reason":"キー未設定","audio":null,"audio_error":"繋がらない"}"#
        )
        #expect(line.audioData == nil)
        #expect(line.audioError == "繋がらない")
        #expect(line.fallbackReason == "キー未設定")
        #expect(line.fromLLM == false)
    }

    @Test("壊れた base64 は音声なしとして扱う")
    func brokenBase64IsTreatedAsNoAudio() throws {
        let line = try decode(
            #"{"text":"やあ","from_llm":true,"fallback_reason":null,"audio":"@@@","audio_error":null}"#
        )
        #expect(line.audioData == nil)
    }
}

@Suite("セリフと声の使用可否")
struct VoiceStatusTests {

    private func status(llm: Bool, voicevox: Bool) -> VoiceStatus {
        VoiceStatus(
            llmConfigured: llm,
            llmModel: "claude-haiku-4-5",
            voicevoxURL: "http://127.0.0.1:50021",
            voicevoxSpeaker: 1,
            voicevoxReachable: voicevox,
            cachedAudio: 0
        )
    }

    @Test("両方揃っていれば使えると出す")
    func bothReady() {
        #expect(status(llm: true, voicevox: true).summary == "セリフも声も使える")
    }

    @Test("欠けている方を名指しする")
    func namesWhatIsMissing() {
        // 「なぜ喋らないのか」が分からないと直しようがないので、原因を文面に出す。
        #expect(status(llm: false, voicevox: true).summary.contains("ANTHROPIC_API_KEY"))
        #expect(status(llm: true, voicevox: false).summary.contains("VOICEVOX"))
        let neither = status(llm: false, voicevox: false).summary
        #expect(neither.contains("API キー") && neither.contains("VOICEVOX"))
    }
}
