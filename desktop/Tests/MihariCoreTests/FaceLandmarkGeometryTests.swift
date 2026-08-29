import CoreGraphics
import Testing

@testable import MihariCore

@Suite("顔ランドマーク点群の幾何計算")
struct FaceLandmarkGeometryTests {

    @Test("縦幅 / 横幅の比を計算する")
    func computesHeightOverWidth() {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 4), CGPoint(x: 0, y: 4),
        ]
        #expect(FaceLandmarkGeometry.eyeOpenness(points: points) == 0.4)
    }

    @Test("点が3個以下なら計算できず nil")
    func tooFewPointsReturnsNil() {
        let points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        #expect(FaceLandmarkGeometry.eyeOpenness(points: points) == nil)
    }

    @Test("横幅が 0 なら nil(ゼロ除算を避ける)")
    func zeroWidthReturnsNil() {
        let points: [CGPoint] = [
            CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 1), CGPoint(x: 5, y: 2), CGPoint(x: 5, y: 3),
        ]
        #expect(FaceLandmarkGeometry.eyeOpenness(points: points) == nil)
    }

    @Test("左右の平均を取る")
    func averagesLeftAndRight() throws {
        // 浮動小数点の丸め誤差があるため、許容誤差付きで比較する。
        let average = try #require(FaceLandmarkGeometry.averageEyeOpenness(left: 0.2, right: 0.4))
        #expect(abs(average - 0.3) < 0.0001)
    }

    @Test("片方だけ取れた場合はそちらだけを使う")
    func usesOnlyAvailableSide() {
        #expect(FaceLandmarkGeometry.averageEyeOpenness(left: nil, right: 0.4) == 0.4)
        #expect(FaceLandmarkGeometry.averageEyeOpenness(left: 0.2, right: nil) == 0.2)
    }

    @Test("両方とも取れなければ nil")
    func nilWhenBothMissing() {
        #expect(FaceLandmarkGeometry.averageEyeOpenness(left: nil, right: nil) == nil)
    }
}
