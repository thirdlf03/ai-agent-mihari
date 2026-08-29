import Foundation

@testable import MihariCore

extension DetectionThresholds {
    /// 本番想定の値。既定値は一時的に縮めてあるので、テストはこちらを使う。
    static let production = DetectionThresholds(suspectSeconds: 120, confirmSeconds: 300, gazeWatchSeconds: 60)
}
