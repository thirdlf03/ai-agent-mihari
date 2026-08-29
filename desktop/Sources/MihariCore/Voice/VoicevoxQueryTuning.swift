import Foundation

/// VOICEVOX の `audio_query` が返したクエリを書き換えて、棒読みを和らげる。
///
/// 既定のままだと抑揚が乏しく機械的に聞こえるので、少し速く・抑揚を強めにして、
/// 前後の無音と句読点の間を詰める。bridge 側(`voicevox.py` の `VoiceTuning`)と同じ値を使い、
/// どちらの経路で喋っても声の印象を揃える。
struct VoicevoxQueryTuning {
    /// 話す速さ。1.0 が既定。
    let speed: Double
    /// 抑揚の強さ。大きいほど高低の差がつく。
    let intonation: Double
    /// 声の高さ。話者の印象を変えたくないので既定のまま。
    let pitch: Double
    /// 発話前の無音(秒)。
    let prePhoneme: Double
    /// 発話後の無音(秒)。
    let postPhoneme: Double
    /// 句読点などの間の倍率。1.0 未満で間が詰まる。
    let pauseLength: Double

    /// 読み上げに使う調整値。
    static let standard = VoicevoxQueryTuning(
        speed: 1.1,
        intonation: 1.3,
        pitch: 0.0,
        prePhoneme: 0.05,
        postPhoneme: 0.05,
        pauseLength: 0.9
    )

    /// クエリの JSON に調整値を載せて返す。`accent_phrases` などその他のキーはそのまま残す。
    ///
    /// トップレベルが辞書でなければ手を加えずに返す。読み上げを止める理由にはしない。
    /// `pauseLengthScale` を知らない古いエンジンもあるが、VOICEVOX ENGINE は知らないキーを
    /// 無視するので付けたままで構わない。
    func apply(to query: Data) throws -> Data {
        let parsed = try JSONSerialization.jsonObject(with: query)
        guard var object = parsed as? [String: Any] else { return query }

        object["speedScale"] = speed
        object["intonationScale"] = intonation
        object["pitchScale"] = pitch
        object["prePhonemeLength"] = prePhoneme
        object["postPhonemeLength"] = postPhoneme
        object["pauseLengthScale"] = pauseLength

        return try JSONSerialization.data(withJSONObject: object)
    }
}
