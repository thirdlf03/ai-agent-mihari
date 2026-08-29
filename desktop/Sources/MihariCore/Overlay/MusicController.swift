import AppKit
import Foundation
import os

/// AppleScript で制御する対象のメディアプレイヤー。
public enum MediaPlayerKind: String, CaseIterable, Sendable {
    case music
    case spotify

    /// `tell application "..."` に入れるアプリ名。
    var scriptName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    /// 起動確認に使う bundle id。
    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
}

/// AppleScript 1 回分の実行結果。`NSAppleScript.executeAndReturnError` の戻り値を素通しする。
public struct AppleScriptOutcome: Sendable, Equatable {
    public let value: String?
    public let errorNumber: Int?

    public init(value: String? = nil, errorNumber: Int? = nil) {
        self.value = value
        self.errorNumber = errorNumber
    }

    public var succeeded: Bool { errorNumber == nil }

    /// オートメーション権限が未許可 / 拒否のときの AppleEvent エラー番号。
    public static let automationNotPermitted = -1743
}

/// AppleScript を実行する層。テストでは実際に `NSAppleScript` を動かさず、ここを差し替える。
public protocol AppleScriptRunning: Sendable {
    func run(_ source: String) -> AppleScriptOutcome
}

/// `NSAppleScript` を同期実行する実装。
public struct SystemAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String) -> AppleScriptOutcome {
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptOutcome(errorNumber: nil)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            return AppleScriptOutcome(errorNumber: number ?? -1)
        }
        return AppleScriptOutcome(value: descriptor.stringValue)
    }
}

/// 音楽を止めた結果。解除後に再開するかどうかの判断と、ログ表示に使う。
public enum MusicStopOutcome: Sendable, Equatable {
    /// AppleScript で特定のプレイヤーを一時停止できた。
    case stoppedViaAppleScript(player: MediaPlayerKind)
    /// AppleScript では止められず、メディアキー送出にフォールバックした。
    case stoppedViaMediaKey
    /// 再生中のものが見当たらなかった(止める必要がなかった)。
    case nothingWasPlaying
    /// 再生状況を確認できず、止められなかった(主にオートメーション権限が未許可)。
    case couldNotStop(reason: String)

    /// ログとオーバーレイの画面に出す一言。
    public var summary: String {
        switch self {
        case .stoppedViaAppleScript(let player):
            return "\(player.scriptName) を AppleScript で止めた"
        case .stoppedViaMediaKey:
            return "AppleScript が届かなかったため、メディアキーで止めた"
        case .nothingWasPlaying:
            return "再生中のものはなかった"
        case .couldNotStop(let reason):
            return "止められなかった: \(reason)"
        }
    }
}

/// 音楽を止める / 再開する。
public protocol MusicControlling: Sendable {
    /// いま再生中のプレイヤーを、**止めずに**返す。
    ///
    /// サボり判定の材料に使う。音楽を流しっぱなしで手が止まっているのか、
    /// そもそも何も鳴っていないのかで、当たり方を変えるため。
    func nowPlaying() async -> NowPlaying

    /// 再生中の Music / Spotify を止める。例外は投げず、結果を outcome として返す。
    func stopPlaying() async -> MusicStopOutcome
    /// `stopPlaying()` が返した outcome をもとに、止めた分だけ再開する。
    func resumePlaying(_ outcome: MusicStopOutcome) async
}

/// いま何が鳴っているか。
///
/// 「鳴っていない」と「分からない」を区別する。オートメーション権限が無いと
/// 状態そのものが取れないので、それを「鳴っていない」と混ぜると、
/// 権限を許可していない人には説教が一切出なくなってしまう。
public enum NowPlaying: Equatable, Sendable {
    /// このプレイヤーが再生中。
    case playing(MediaPlayerKind)
    /// どのプレイヤーも再生していないと確認できた。
    case silent
    /// 確認できなかった(主にオートメーション権限が未許可)。
    case undetermined(reason: String)

    /// 音楽が鳴っていると確信できるか。
    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// 画面やログに出す一言。
    public var label: String {
        switch self {
        case .playing(let player): return "\(player.scriptName) が再生中"
        case .silent: return "何も鳴っていない"
        case .undetermined: return "確認できない（オートメーション権限）"
        }
    }
}

/// `findPlayingPlayer()` の結果。「再生中がいない」と「分からなかった」を区別する。
/// 分からなかった(主にオートメーション権限が未許可)ときにメディアキーを誤発火させないため。
private enum PlayerQuery {
    case found(MediaPlayerKind)
    case noneConfirmedPlaying
    case undetermined(reason: String)
}

/// AppleScript で Music / Spotify を止め、届かなければメディアキーにフォールバックする実装。
///
/// 手順:
/// 1. 起動中の Music / Spotify それぞれに `player state` を聞き、`playing` を探す。
/// 2. 再生中のプレイヤーが見つかったら `pause` を送る。これが失敗したときに限り、
///    「見つかったのに止められなかった」とみなしてメディアキーへフォールバックする。
/// 3. 誰も再生していないと確認できたとき、およびオートメーション権限が無くて
///    状態そのものが分からないときは、メディアキーを送らない。
///    メディアキーはトグルなので、確信がないのに送ると逆に再生を始めてしまう。
public struct AppleScriptMusicController: MusicControlling {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "overlay.music")

    private let runner: AppleScriptRunning
    private let mediaKeySender: MediaKeySending
    private let isRunning: @Sendable (String) -> Bool

    public init(
        runner: AppleScriptRunning = SystemAppleScriptRunner(),
        mediaKeySender: MediaKeySending = SystemMediaKeySender(),
        isRunning: @escaping @Sendable (String) -> Bool = AppleScriptMusicController.isBundleRunning
    ) {
        self.runner = runner
        self.mediaKeySender = mediaKeySender
        self.isRunning = isRunning
    }

    public static func isBundleRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func nowPlaying() async -> NowPlaying {
        switch findPlayingPlayer() {
        case .found(let player): return .playing(player)
        case .noneConfirmedPlaying: return .silent
        case .undetermined(let reason): return .undetermined(reason: reason)
        }
    }

    public func stopPlaying() async -> MusicStopOutcome {
        switch findPlayingPlayer() {
        case .noneConfirmedPlaying:
            Self.logger.info("再生中の Music / Spotify は見つからなかった")
            return .nothingWasPlaying

        case .undetermined(let reason):
            Self.logger.error("再生状況を確認できなかった: \(reason, privacy: .public)")
            return .couldNotStop(reason: reason)

        case .found(let playing):
            let pauseResult = runner.run("tell application \"\(playing.scriptName)\" to pause")
            if pauseResult.succeeded {
                Self.logger.info("\(playing.scriptName, privacy: .public) を pause した")
                return .stoppedViaAppleScript(player: playing)
            }
            Self.logger.error(
                "\(playing.scriptName, privacy: .public) の pause に失敗した(errorNumber=\(pauseResult.errorNumber ?? -1, privacy: .public))。メディアキーにフォールバックする"
            )
            mediaKeySender.sendPlayPauseToggle()
            return .stoppedViaMediaKey
        }
    }

    public func resumePlaying(_ outcome: MusicStopOutcome) async {
        switch outcome {
        case .stoppedViaAppleScript(let player):
            let result = runner.run("tell application \"\(player.scriptName)\" to play")
            Self.logger.info("\(player.scriptName, privacy: .public) の再開: 成功=\(result.succeeded, privacy: .public)")
        case .stoppedViaMediaKey:
            mediaKeySender.sendPlayPauseToggle()
            Self.logger.info("メディアキーで再開した")
        case .nothingWasPlaying, .couldNotStop:
            break
        }
    }

    /// 起動中のプレイヤーのうち、`player state` が `playing` のものを探す。
    /// 問い合わせ自体が失敗したプレイヤーがいたら `.undetermined` を返し、以降は探さない。
    private func findPlayingPlayer() -> PlayerQuery {
        for player in MediaPlayerKind.allCases where isRunning(player.bundleID) {
            let state = runner.run("tell application \"\(player.scriptName)\" to player state as text")
            guard state.succeeded else {
                return .undetermined(reason: Self.describe(errorNumber: state.errorNumber, player: player))
            }
            if state.value == "playing" {
                return .found(player)
            }
        }
        return .noneConfirmedPlaying
    }

    private static func describe(errorNumber: Int?, player: MediaPlayerKind) -> String {
        if errorNumber == AppleScriptOutcome.automationNotPermitted {
            return "\(player.scriptName) を操作する権限(オートメーション)が無い"
        }
        return "\(player.scriptName) の状態を取得できなかった(errorNumber=\(errorNumber.map(String.init) ?? "不明"))"
    }
}
