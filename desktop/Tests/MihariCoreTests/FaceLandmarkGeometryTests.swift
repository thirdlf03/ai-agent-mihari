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

@Suite("鼻の左右オフセット(顔向きプロキシ)")
struct NoseOffsetTests {

    /// 両目の中心を (40,100)・(60,100) に置いた正面顔。
    private let leftEye: [CGPoint] = [
        CGPoint(x: 35, y: 98), CGPoint(x: 45, y: 98),
        CGPoint(x: 45, y: 102), CGPoint(x: 35, y: 102),
    ]
    private let rightEye: [CGPoint] = [
        CGPoint(x: 55, y: 98), CGPoint(x: 65, y: 98),
        CGPoint(x: 65, y: 102), CGPoint(x: 55, y: 102),
    ]

    @Test("正面顔(鼻が両目の中央)なら 0")
    func frontFaceIsZero() throws {
        let nose: [CGPoint] = [CGPoint(x: 50, y: 88), CGPoint(x: 50, y: 92)]
        let offset = try #require(
            FaceLandmarkGeometry.noseOffset(leftEye: leftEye, rightEye: rightEye, nose: nose)
        )
        #expect(abs(offset) < 0.0001)
    }

    @Test("鼻が右目側へ寄ると正、寄りの比率が値になる")
    func shiftTowardRightEyeIsPositive() throws {
        // 鼻の重心 x=55。両目の中心 50 から右へ 5、目間距離 20 → 0.25。
        let nose: [CGPoint] = [CGPoint(x: 55, y: 88), CGPoint(x: 55, y: 92)]
        let offset = try #require(
            FaceLandmarkGeometry.noseOffset(leftEye: leftEye, rightEye: rightEye, nose: nose)
        )
        #expect(abs(offset - 0.25) < 0.0001)
    }

    @Test("鼻が左目側へ寄ると負")
    func shiftTowardLeftEyeIsNegative() throws {
        let nose: [CGPoint] = [CGPoint(x: 45, y: 88), CGPoint(x: 45, y: 92)]
        let offset = try #require(
            FaceLandmarkGeometry.noseOffset(leftEye: leftEye, rightEye: rightEye, nose: nose)
        )
        #expect(abs(offset - (-0.25)) < 0.0001)
    }

    @Test("首をかしげても(座標系が回転しても)値は変わらない")
    func rollInvariant() throws {
        // 正面顔一式を 90 度回転: (x,y) -> (-y,x)。鼻は右目側へ 0.25 寄せてある。
        let rotate = { (p: CGPoint) in CGPoint(x: -p.y, y: p.x) }
        let offset = try #require(
            FaceLandmarkGeometry.noseOffset(
                leftEye: leftEye.map(rotate),
                rightEye: rightEye.map(rotate),
                nose: [CGPoint(x: 55, y: 88), CGPoint(x: 55, y: 92)].map(rotate)
            )
        )
        #expect(abs(offset - 0.25) < 0.0001)
    }

    @Test("点が 1 つも無い部位があれば nil")
    func emptyRegionReturnsNil() {
        #expect(
            FaceLandmarkGeometry.noseOffset(
                leftEye: [],
                rightEye: rightEye,
                nose: [CGPoint(x: 50, y: 90)]
            ) == nil
        )
        #expect(
            FaceLandmarkGeometry.noseOffset(
                leftEye: leftEye,
                rightEye: rightEye,
                nose: []
            ) == nil
        )
    }

    @Test("両目の中心が同じ点なら nil(ゼロ除算を避ける)")
    func coincidentEyesReturnsNil() {
        let eye: [CGPoint] = [CGPoint(x: 50, y: 100)]
        #expect(
            FaceLandmarkGeometry.noseOffset(
                leftEye: eye,
                rightEye: eye,
                nose: [CGPoint(x: 50, y: 90)]
            ) == nil
        )
    }
}

@Suite("鼻の縦オフセット(顔ピッチのプロキシ)")
struct NoseDropTests {

    /// 両目の中心を (40,100)・(60,100) に置いた正面顔。
    private let leftEye: [CGPoint] = [
        CGPoint(x: 35, y: 98), CGPoint(x: 45, y: 98),
        CGPoint(x: 45, y: 102), CGPoint(x: 35, y: 102),
    ]
    private let rightEye: [CGPoint] = [
        CGPoint(x: 55, y: 98), CGPoint(x: 65, y: 98),
        CGPoint(x: 65, y: 102), CGPoint(x: 55, y: 102),
    ]

    @Test("両目の線から鼻までの距離を目間距離で正規化する")
    func normalizedPerpendicularDistance() throws {
        // 鼻の重心は目の線から 10 下(y=90)。目間距離 20 → -0.5。
        let nose: [CGPoint] = [CGPoint(x: 50, y: 88), CGPoint(x: 50, y: 92)]
        let drop = try #require(
            FaceLandmarkGeometry.noseDrop(leftEye: leftEye, rightEye: rightEye, nose: nose)
        )
        #expect(abs(drop - (-0.5)) < 0.0001)
    }

    @Test("首をかしげても(座標系が回転しても)値は変わらない")
    func rollInvariant() throws {
        let rotate = { (p: CGPoint) in CGPoint(x: -p.y, y: p.x) }
        let drop = try #require(
            FaceLandmarkGeometry.noseDrop(
                leftEye: leftEye.map(rotate),
                rightEye: rightEye.map(rotate),
                nose: [CGPoint(x: 50, y: 88), CGPoint(x: 50, y: 92)].map(rotate)
            )
        )
        #expect(abs(drop - (-0.5)) < 0.0001)
    }

    @Test("左右に寄っても縦の値は変わらない(横オフセットと独立)")
    func independentOfHorizontalShift() throws {
        let nose: [CGPoint] = [CGPoint(x: 55, y: 88), CGPoint(x: 55, y: 92)]
        let drop = try #require(
            FaceLandmarkGeometry.noseDrop(leftEye: leftEye, rightEye: rightEye, nose: nose)
        )
        #expect(abs(drop - (-0.5)) < 0.0001)
    }

    @Test("点が 1 つも無い部位があれば nil")
    func emptyRegionReturnsNil() {
        #expect(
            FaceLandmarkGeometry.noseDrop(
                leftEye: [],
                rightEye: rightEye,
                nose: [CGPoint(x: 50, y: 90)]
            ) == nil
        )
    }

    @Test("両目の中心が同じ点なら nil(ゼロ除算を避ける)")
    func coincidentEyesReturnsNil() {
        let eye: [CGPoint] = [CGPoint(x: 50, y: 100)]
        #expect(
            FaceLandmarkGeometry.noseDrop(
                leftEye: eye,
                rightEye: eye,
                nose: [CGPoint(x: 50, y: 90)]
            ) == nil
        )
    }
}
