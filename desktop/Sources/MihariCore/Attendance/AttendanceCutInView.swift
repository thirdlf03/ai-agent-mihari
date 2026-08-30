import AppKit
import SwiftUI

/// カットインの表示状態。`AttendanceCutInPresenter` が書き換え、`AttendanceCutInView` が映す。
///
/// 出るときのスライドインはビュー自身が `onAppear` で始める。状態を作った直後に
/// 動かすと初期状態が一度も描かれず、アニメーションにならないため。
/// ここで持つのは、出したあとに外から変えるもの(絵・フラッシュ・退場)だけ。
@Observable
@MainActor
final class AttendanceCutInModel {
    /// いま出している絵。
    var image: NSImage?
    /// いま出している絵の種類。文字の出し方をこれで決める。
    var kind: AttendanceCutInImage
    /// 退場中か。true にすると画面の外へ滑っていく。
    var isLeaving = false
    /// 白フラッシュを出しているか。成功したときだけ true にする。
    var isFlashing = false
    /// 「視差効果を減らす」設定。true のあいだはスライドも点滅もしない。
    let isReduceMotionEnabled: Bool

    init(image: NSImage, kind: AttendanceCutInImage, isReduceMotionEnabled: Bool) {
        self.image = image
        self.kind = kind
        self.isReduceMotionEnabled = isReduceMotionEnabled
    }
}

/// カットインの中身。正方形いっぱいに絵を出し、絵の透明な左側に「TOUCH」を重ねる。
struct AttendanceCutInView: View {
    /// スライドインのばね。
    static let entranceAnimation: Animation = .spring(response: 0.45, dampingFraction: 0.8)
    /// 「視差効果を減らす」ときのフェードにかける時間(秒)。
    static let fadeDuration: TimeInterval = 0.25
    /// 白フラッシュの最大の濃さ。
    static let flashPeakOpacity: Double = 0.9
    /// 白フラッシュが消えるまでの時間(秒)。
    static let flashDuration: TimeInterval = 0.35
    /// 点滅 1 周期の長さ(秒)。
    static let blinkPeriod: TimeInterval = 0.5

    /// 文字を置く帯の左端(ビュー幅に対する割合)。絵の左 36% は透明なのでそこに収める。
    private static let captionMinXRatio: CGFloat = 0.03
    /// 文字を置く帯の幅(ビュー幅に対する割合)。
    private static let captionWidthRatio: CGFloat = 0.30
    /// 文字を置く帯の上端(ビュー高さに対する割合)。
    private static let captionMinYRatio: CGFloat = 0.36
    /// 文字を置く帯の高さ(ビュー高さに対する割合)。
    private static let captionHeightRatio: CGFloat = 0.16
    /// 文字の大きさ(ビュー高さに対する割合)。帯に収まらなければ縮めて 1 行に収める。
    private static let captionFontRatio: CGFloat = 0.12

    let model: AttendanceCutInModel

    /// スライドインし終えたか。`onAppear` で true にして、そこだけをアニメーションさせる。
    @State private var hasEntered = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                }

                if let caption = Self.caption(for: model.kind) {
                    AttendanceCutInCaption(
                        text: caption,
                        fontSize: size.height * Self.captionFontRatio,
                        blinks: model.kind == .reach && !model.isReduceMotionEnabled
                    )
                    .frame(
                        width: size.width * Self.captionWidthRatio,
                        height: size.height * Self.captionHeightRatio
                    )
                    .offset(
                        x: size.width * Self.captionMinXRatio,
                        y: size.height * Self.captionMinYRatio
                    )
                    // 絵が差し替わったら、点滅の状態も作り直す。
                    .id(model.kind)
                }

                if model.isFlashing {
                    AttendanceCutInFlash()
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .offset(x: xOffset(width: size.width))
            .opacity(stageOpacity)
            .onAppear {
                withAnimation(
                    model.isReduceMotionEnabled ? .easeOut(duration: Self.fadeDuration) : Self.entranceAnimation
                ) {
                    hasEntered = true
                }
            }
        }
    }

    /// 画面の右外へどれだけずらすか。「視差効果を減らす」ときはずらさず、濃さだけで出し入れする。
    private func xOffset(width: CGFloat) -> CGFloat {
        guard !model.isReduceMotionEnabled else { return 0 }
        if model.isLeaving { return width }
        return hasEntered ? 0 : width
    }

    /// 「視差効果を減らす」ときのフェード用の濃さ。それ以外では常に不透明。
    private var stageOpacity: Double {
        guard model.isReduceMotionEnabled else { return 1 }
        if model.isLeaving { return 0 }
        return hasEntered ? 1 : 0
    }

    /// 絵に重ねる文字。空振りのときは何も出さない。
    static func caption(for kind: AttendanceCutInImage) -> String? {
        switch kind {
        case .reach: return "TOUCH"
        case .touched: return "OK"
        case .failed: return nil
        }
    }
}

/// 絵に重ねる文字。指を待っているあいだだけ点滅する。
private struct AttendanceCutInCaption: View {
    /// 文字の色。
    private static let color = Color(red: 0.95, green: 0.55, blue: 0.70)
    /// 点滅で薄くなったときの濃さ。
    private static let dimmedOpacity: Double = 0.35

    let text: String
    let fontSize: CGFloat
    let blinks: Bool

    @State private var isDimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(Self.color)
            .shadow(color: .white.opacity(0.9), radius: fontSize * 0.10)
            .shadow(color: .white.opacity(0.6), radius: fontSize * 0.30)
            .opacity(isDimmed ? Self.dimmedOpacity : 1)
            .onAppear {
                guard blinks else { return }
                withAnimation(
                    .easeInOut(duration: AttendanceCutInView.blinkPeriod / 2).repeatForever(autoreverses: true)
                ) {
                    isDimmed = true
                }
            }
    }
}

/// 成功した瞬間の白フラッシュ。出た直後から消えるだけの使い切りのビュー。
private struct AttendanceCutInFlash: View {
    @State private var opacity = AttendanceCutInView.flashPeakOpacity

    var body: some View {
        Color.white
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: AttendanceCutInView.flashDuration)) {
                    opacity = 0
                }
            }
    }
}
