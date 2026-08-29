import CoreGraphics

/// 顔ランドマークの点群から指標を求める純粋な計算だけを集めたもの。
///
/// Vision フレームワークの型(`VNFaceObservation` など)を一切知らず、`CGPoint` の配列だけを
/// 受け取る。実カメラや実 Vision リクエストなしにテストできるようにするための境界線。
public enum FaceLandmarkGeometry {

    /// 最低限これだけ点が無いと外接矩形として意味を持たない。
    private static let minimumPointCount = 4

    /// 目の輪郭点群から「縦幅 / 横幅」を求める(いわゆる EAR 的な指標)。
    ///
    /// SaboriLab モジュール 11 での検証では、開いた目でおよそ 0.25〜0.5、
    /// 閉じた目で 0.1 前後になっている。
    ///
    /// - Parameter points: 目の輪郭を構成する点(画像座標系)。
    /// - Returns: 縦幅 / 横幅。点が足りない・幅が 0 など計算できない場合は `nil`。
    public static func eyeOpenness(points: [CGPoint]) -> Double? {
        guard points.count >= minimumPointCount else { return nil }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
            let minY = ys.min(), let maxY = ys.max()
        else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0 else { return nil }

        return Double(height / width)
    }

    /// 左右の目の開き具合を平均する。
    ///
    /// 片方しか取れなかった場合はそちらだけを使う(横顔などで片目だけ隠れる状況を想定)。
    /// 両方とも取れなければ `nil` を返し、呼び出し側で「判定材料なし」として扱う。
    public static func averageEyeOpenness(left: Double?, right: Double?) -> Double? {
        let values = [left, right].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

extension FaceLandmarkGeometry {

    /// 鼻が両目の中心からどれだけ左右に寄っているか(顔向きのプロキシ)。
    ///
    /// `VNFaceObservation.yaw` がこの Vision リビジョンでは常に 0 を返すため、
    /// ランドマークの位置関係から顔の向きを推定する代替指標。
    /// 正面顔なら 0、横を向くと鼻が片目側へ寄って絶対値が大きくなる。
    ///
    /// 両目の重心を結ぶ軸に鼻の重心を射影し、目間距離で割って正規化する。
    /// 軸に射影するので、首をかしげて座標系が回転していても値は変わらない。
    ///
    /// - Returns: 右目側へ寄ると正、左目側で負。いずれかの点群が空、
    ///   または両目の重心が一致していれば `nil`。
    public static func noseOffset(
        leftEye: [CGPoint], rightEye: [CGPoint], nose: [CGPoint]
    ) -> Double? {
        guard let left = centroid(of: leftEye),
            let right = centroid(of: rightEye),
            let noseCenter = centroid(of: nose)
        else { return nil }

        let axis = CGPoint(x: right.x - left.x, y: right.y - left.y)
        let distance = (axis.x * axis.x + axis.y * axis.y).squareRoot()
        guard distance > 0 else { return nil }

        let mid = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let toNose = CGPoint(x: noseCenter.x - mid.x, y: noseCenter.y - mid.y)
        // 軸方向の成分だけを取り出し、目間距離で正規化する。
        let projected = (toNose.x * axis.x + toNose.y * axis.y) / distance
        return Double(projected / distance)
    }

    /// 点群の重心。空なら `nil`。
    private static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
