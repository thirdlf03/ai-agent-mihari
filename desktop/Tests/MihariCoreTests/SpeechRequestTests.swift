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
        #expect(request.iphoneApp == nil)
        #expect(request.screenshotPNG == nil)
    }

    @Test("iPhone で開いているアプリは iphone_app に乗せる")
    func encodesIPhoneApp() throws {
        let json = try encode(SpeechRequest(idleSeconds: 0, iphone: .active, iphoneApp: "YouTube"))
        #expect(json["iphone_app"] as? String == "YouTube")
    }

    @Test("iPhone のアプリが分からなければキーごと出さない")
    func omitsIPhoneAppKeyWhenNil() throws {
        // 古いデーモンには無いキーなので、空文字を送って「不明」を上書きしない。
        let json = try encode(SpeechRequest(idleSeconds: 0, iphone: .active))
        #expect(json["iphone_app"] == nil)
    }

    @Test("スクショは screenshot_png に base64 で乗せる")
    func encodesScreenshotAsBase64() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let json = try encode(SpeechRequest(idleSeconds: 0, screenshotPNG: png))
        #expect(json["screenshot_png"] as? String == png.base64EncodedString())
    }

    @Test("スクショが無ければキーごと出さない")
    func omitsScreenshotKeyWhenNil() throws {
        // 空文字を送ると向こうが「読めない画像が来た」と扱ってしまう。キーごと落とす。
        let json = try encode(SpeechRequest(idleSeconds: 0))
        #expect(json["screenshot_png"] == nil)
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

    @Test("読み取れた画面を読む")
    func decodesScreenReading() throws {
        let line = try decode(
            #"{"text":"YouTube 見てるでしょ","from_llm":true,"audio":null,"screen":{"app":"YouTube","activity":"動画を見ている","category":"slacking"},"screen_error":null}"#
        )
        #expect(line.screen?.app == "YouTube")
        #expect(line.screen?.activity == "動画を見ている")
        #expect(line.screen?.category == "slacking")
        #expect(line.screenError == nil)
    }

    @Test("読めなかった理由も読む")
    func decodesScreenError() throws {
        let line = try decode(
            #"{"text":"やあ","from_llm":true,"audio":null,"screen":null,"screen_error":"キー未設定"}"#
        )
        #expect(line.screen == nil)
        #expect(line.screenError == "キー未設定")
    }

    @Test("画面のフィールドが無い応答も読める")
    func decodesWithoutScreenFields() throws {
        // 古いデーモンに繋いだだけで喋れなくなるのは困る。
        let line = try decode(#"{"text":"やあ","from_llm":true,"audio":null}"#)
        #expect(line.text == "やあ")
        #expect(line.screen == nil)
        #expect(line.screenError == nil)
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
