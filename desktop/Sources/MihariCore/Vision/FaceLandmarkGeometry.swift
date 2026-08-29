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
