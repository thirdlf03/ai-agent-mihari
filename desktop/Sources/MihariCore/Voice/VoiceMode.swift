import Foundation

/// セリフの音声をどこから持ってくるか。
public enum VoiceMode: String, Sendable, CaseIterable, Identifiable {
    /// アプリに同封した .m4a を鳴らす。VOICEVOX が無くても喋る。
    case bundled
    /// その場で VOICEVOX に合成させる。セリフも bridge の LLM に作らせる。
    case live

    public var id: String { rawValue }

    /// 画面とメニューに出す説明。
    public var label: String {
        switch self {
        case .bundled: return "同封の音声を使う"
        case .live: return "VOICEVOX でその場で生成(live)"
        }
    }
}

/// いまどちらの音声モードかを持つ。切り替えは再起動なしで効く。
///
/// 決め方は 環境変数 `MIHARI_VOICE_MODE` > `UserDefaults` の `voiceMode` > 既定(`bundled`)。
/// 環境変数を付けて起動している間は、メニューから切り替えても次の起動でまた環境変数に戻る。
@MainActor
public final class VoiceModeStore: ObservableObject {

    /// 起動時にモードを上書きする環境変数。
    public static let environmentKey = "MIHARI_VOICE_MODE"
    /// 選んだモードを覚えておく `UserDefaults` のキー。
    public static let defaultsKey = "voiceMode"

    @Published public private(set) var mode: VoiceMode

    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.mode = Self.initialMode(defaults: defaults, environment: environment)
    }

    /// モードを切り替えて覚える。
    public func set(_ mode: VoiceMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }

    /// 起動時のモードを決める。環境変数 > 保存値 > 既定の順。
    static func initialMode(defaults: UserDefaults, environment: [String: String]) -> VoiceMode {
        if let raw = environment[environmentKey], let mode = VoiceMode(rawValue: raw) {
            return mode
        }
        if let raw = defaults.string(forKey: defaultsKey), let mode = VoiceMode(rawValue: raw) {
            return mode
        }
        return .bundled
    }
}
