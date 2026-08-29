import Foundation

/// `device-bridge list` が返すデバイス 1 件分の情報。
struct DeviceSummary: Codable, Identifiable, Hashable {
    let udid: String
    let connectionType: String
    /// Wi-Fi 経由で見つかった場合の接続先 IP。USB の場合は nil。
    let host: String?

    var id: String { udid }
}

/// `device-bridge list` のレスポンス全体。
struct DeviceListResponse: Codable {
    let devices: [DeviceSummary]
}

/// `device-bridge info --udid <UDID>` のレスポンス。
struct DeviceInfo: Codable, Hashable {
    let udid: String
    let deviceName: String
    let productType: String
    let productVersion: String
    let buildVersion: String
    let connectionType: String
    /// Wi-Fi 経由で取得した場合の接続先 IP。USB の場合は nil。
    let host: String?
}
