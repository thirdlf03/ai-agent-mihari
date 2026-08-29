import Foundation
import Testing

@testable import MihariCore

@Suite("読み上げクエリの調整")
struct VoicevoxQueryTuningTests {

    private func tuned(_ object: [String: Any]) throws -> [String: Any] {
        let query = try JSONSerialization.data(withJSONObject: object)
        let applied = try VoicevoxQueryTuning.standard.apply(to: query)
        return try #require(try JSONSerialization.jsonObject(with: applied) as? [String: Any])
    }

    @Test("調整値がクエリに載る")
    func overwritesTheTuningKeys() throws {
        let object = try tuned(["speedScale": 1.0, "intonationScale": 1.0])

        let tuning = VoicevoxQueryTuning.standard
        #expect(object["speedScale"] as? Double == tuning.speed)
        #expect(object["intonationScale"] as? Double == tuning.intonation)
        #expect(object["pitchScale"] as? Double == tuning.pitch)
        #expect(object["prePhonemeLength"] as? Double == tuning.prePhoneme)
        #expect(object["postPhonemeLength"] as? Double == tuning.postPhoneme)
        #expect(object["pauseLengthScale"] as? Double == tuning.pauseLength)
    }

    @Test("調整に関係ないキーは残る")
    func keepsTheOtherKeys() throws {
        let object = try tuned([
            "accent_phrases": [["moras": []]],
            "outputSamplingRate": 24_000,
        ])

        let phrases = object["accent_phrases"] as? [[String: Any]]
        #expect(phrases?.count == 1)
        #expect(object["outputSamplingRate"] as? Int == 24_000)
    }

    @Test("辞書でない JSON はそのまま返す")
    func passesThroughNonObjectJSON() throws {
        let query = try JSONSerialization.data(withJSONObject: [1, 2, 3])

        let applied = try VoicevoxQueryTuning.standard.apply(to: query)

        #expect(applied == query)
    }
}
