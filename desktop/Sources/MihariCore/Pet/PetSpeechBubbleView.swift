import AppKit
import SwiftUI

/// ペットの頭上に出す吹き出しの中身。角丸の板と三角のしっぽを 1 つの形として描く。
///
/// `onAnswer` を渡すと、セリフの下に はい/いいえ のボタン列を出す。
struct PetSpeechBubbleView: View {
    /// 影が切れないようにウィンドウの縁へあける余白(pt)。
    static let margin: CGFloat = 8
    /// 板の角丸半径(pt)。
    static let cornerRadius: CGFloat = 14
    /// しっぽの大きさ(pt)。
    static let tailSize = CGSize(width: 14, height: 9)
    /// はい/いいえ のボタン行に確保する高さ(pt)。
    static let buttonsHeight: CGFloat = 24
    /// セリフとボタン行のあいだの余白(pt)。
    static let buttonsSpacing: CGFloat = 6
    /// はい/いいえ のボタン列に確保する幅(pt)。短い質問でもボタンが切れないようにする。
    static let buttonsRowWidth: CGFloat = 120

    /// 文字を折り返す幅(pt)。
    private static let maxTextWidth: CGFloat = 240
    /// 文字の上下の余白(pt)。
    private static let verticalTextPadding: CGFloat = 9
    /// 文字の左右の余白(pt)。
    private static let horizontalTextPadding: CGFloat = 14
    /// 文字のフォント。SwiftUI 側の `.system(size: 14, weight: .medium)` と揃える。
    private static let textFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    /// セリフに必要なウィンドウ全体の大きさ(pt)を AppKit で測る。
    /// SwiftUI の `fittingSize` は幅を提案せずに測るため高さが大きく出るので、こちらを使う。
    static func windowSize(for text: String, hasButtons: Bool = false) -> CGSize {
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        let textSize = CGSize(width: ceil(bounding.width), height: ceil(bounding.height))
        // 短い質問だと文字幅よりボタン列のほうが広いので、広いほうを内容の幅とする。
        let contentWidth = hasButtons ? max(textSize.width, Self.buttonsRowWidth) : textSize.width
        let buttonsHeight = hasButtons ? Self.buttonsSpacing + Self.buttonsHeight : 0
        return CGSize(
            width: contentWidth + horizontalTextPadding * 2 + margin * 2,
            height: textSize.height + buttonsHeight + verticalTextPadding * 2 + tailSize.height + margin * 2
        )
    }

    /// 表示するセリフ。問いかけのときは質問文。
    let text: String
    /// しっぽを板の下に出すか。ペットの下に吹き出しを出すときは false にして上向きにする。
    let tailAtBottom: Bool
    /// はい/いいえ の回答を受け取るコールバック。nil ならボタンを出さない。
    let onAnswer: ((Bool) -> Void)?

    init(text: String, tailAtBottom: Bool, onAnswer: ((Bool) -> Void)? = nil) {
        self.text = text
        self.tailAtBottom = tailAtBottom
        self.onAnswer = onAnswer
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(.vertical, Self.verticalTextPadding)
            .padding(.horizontal, Self.horizontalTextPadding)
            .padding(tailAtBottom ? .bottom : .top, Self.tailSize.height)
            .background(bubble)
            .padding(Self.margin)
    }

    /// セリフ、問いかけならその下にボタン列。
    @ViewBuilder
    private var content: some View {
        if let onAnswer {
            VStack(spacing: Self.buttonsSpacing) {
                label
                HStack(spacing: 8) {
                    Button("はい") { onAnswer(true) }
                    Button("いいえ") { onAnswer(false) }
                }
                .frame(height: Self.buttonsHeight)
                .frame(minWidth: Self.buttonsRowWidth)
            }
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.maxTextWidth)
    }

    /// 板としっぽ。同じ形に塗りと枠線を重ねる。
    private var bubble: some View {
        let shape = PetSpeechBubbleShape(
            tailAtBottom: tailAtBottom,
            cornerRadius: Self.cornerRadius,
            tailSize: Self.tailSize
        )
        return
            shape
            .fill(plateColor)
            .shadow(radius: 4, y: 2)
            .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }

    /// 板の色。ダークモードではウィンドウの背景色に合わせる。
    private var plateColor: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }
}

/// 角丸の板と三角のしっぽをひと続きに描く吹き出しの形。
struct PetSpeechBubbleShape: Shape {
    /// しっぽを下辺に出すか。false のときは上辺に出す。
    let tailAtBottom: Bool
    /// 板の角丸半径(pt)。
    let cornerRadius: CGFloat
    /// しっぽの大きさ(pt)。
    let tailSize: CGSize

    /// 左上の角から時計回りに、角丸としっぽをつないだ輪郭を描く。
    func path(in rect: CGRect) -> Path {
        let plate = CGRect(
            x: rect.minX,
            y: tailAtBottom ? rect.minY : rect.minY + tailSize.height,
            width: rect.width,
            height: max(rect.height - tailSize.height, 0)
        )
        let radius = min(cornerRadius, min(plate.width, plate.height) / 2)
        let half = tailSize.width / 2

        var path = Path()
        path.move(to: CGPoint(x: plate.minX, y: plate.minY + radius))
        path.addArc(
            center: CGPoint(x: plate.minX + radius, y: plate.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        if !tailAtBottom {
            path.addLine(to: CGPoint(x: plate.midX - half, y: plate.minY))
            path.addLine(to: CGPoint(x: plate.midX, y: plate.minY - tailSize.height))
            path.addLine(to: CGPoint(x: plate.midX + half, y: plate.minY))
        }
        path.addLine(to: CGPoint(x: plate.maxX - radius, y: plate.minY))
        path.addArc(
            center: CGPoint(x: plate.maxX - radius, y: plate.minY + radius),
            radius: radius,
            startAngle: .degrees(270),
            endAngle: .degrees(360),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: plate.maxX, y: plate.maxY - radius))
        path.addArc(
            center: CGPoint(x: plate.maxX - radius, y: plate.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        if tailAtBottom {
            path.addLine(to: CGPoint(x: plate.midX + half, y: plate.maxY))
            path.addLine(to: CGPoint(x: plate.midX, y: plate.maxY + tailSize.height))
            path.addLine(to: CGPoint(x: plate.midX - half, y: plate.maxY))
        }
        path.addLine(to: CGPoint(x: plate.minX + radius, y: plate.maxY))
        path.addArc(
            center: CGPoint(x: plate.minX + radius, y: plate.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
