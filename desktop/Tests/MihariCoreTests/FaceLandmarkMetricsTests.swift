import Foundation
import Testing

@testable import MihariCore

@Suite("顔ランドマークの指標")
struct FaceLandmarkMetricsTests {

    @Test("yaw をラジアンから度数に変換する")
    func convertsYawToDegrees() {
        let metrics = FaceLandmarkMetrics(leftEyeOpenness: nil, rightEyeOpenness: nil, yawRadians: .pi / 2)
        #expect(abs((metrics.yawDegrees ?? 0) - 90) < 0.0001)
    }

    @Test("yaw が取れなければ度数も nil")
    func nilYawStaysNil() {
        let metrics = FaceLandmarkMetrics(leftEyeOpenness: 0.3, rightEyeOpenness: 0.3, yawRadians: nil)
        #expect(metrics.yawDegrees == nil)
    }

    @Test("左右の平均は FaceLandmarkGeometry に委譲する")
    func averageDelegatesToGeometry() throws {
        let metrics = FaceLandmarkMetrics(leftEyeOpenness: 0.2, rightEyeOpenness: 0.4, yawRadians: nil)
        // 浮動小数点の丸め誤差があるため、許容誤差付きで比較する。
        let average = try #require(metrics.averageEyeOpenness)
        #expect(abs(average - 0.3) < 0.0001)
    }
}
