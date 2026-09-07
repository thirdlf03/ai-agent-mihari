import Foundation

/// mac-control の接続先と、この Mac の名乗り（device_id ほか）。
///
/// 接続先は既存の依頼窓・部屋購読と同じ環境変数(`MIHARI_ROOM_URL` / `MIHARI_ROOM_TOKEN`)で決める。
/// VPS なら https、手元なら http が入るので、WebSocket の URL へ写し替える。
public struct MacControlEndpoint: Sendable, Equatable {

    public let baseURL: URL
    public let token: String

    public static func fromEnvironment() -> MacControlEndpoint {
        MacControlEndpoint(
            baseURL: JobRequestClient.defaultBaseURL,
            token: JobRequestClient.defaultToken()
        )
    }

    /// `ws://host:port/ws/mac-control` を作る。
    public var socketURL: URL? {
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("ws/mac-control"),
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        return components.url
    }
}

/// この Mac の名乗り。hello フレームに載せる。
///
/// device_id は接続を張り直しても同じ端末だと分かるよう、永続化した ID を使う。
/// 再インストールすると変わってよい（そのときは新しい端末として扱われる）。
public struct MacControlIdentity: Sendable, Equatable {

    public let deviceID: String
    public let hostname: String
    public let appVersion: String
    public let osVersion: String

    /// device_id を覚えておく UserDefaults のキー。
    public static let deviceIDDefaultsKey = "macControl.deviceID"

    public static func make(defaults: UserDefaults = .standard) -> MacControlIdentity {
        let deviceID: String
        if let saved = defaults.string(forKey: deviceIDDefaultsKey), !saved.isEmpty {
            deviceID = saved
        } else {
            deviceID = "mac-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            defaults.set(deviceID, forKey: deviceIDDefaultsKey)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return MacControlIdentity(
            deviceID: deviceID,
            hostname: ProcessInfo.processInfo.hostName,
            appVersion: "\(version) (\(build))",
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }

    public init(deviceID: String, hostname: String, appVersion: String, osVersion: String) {
        self.deviceID = deviceID
        self.hostname = hostname
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}
