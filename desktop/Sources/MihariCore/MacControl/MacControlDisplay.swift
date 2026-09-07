import AppKit
import CoreGraphics
import Foundation

/// いまの画面構成を mac-control の表示器一覧(displays)の形で渡す口。
///
/// テストでは固定の一覧に差し替える。
public protocol MacControlDisplayListing: Sendable {
    func currentDisplays() -> [MacDisplayInfo]
}

/// `CGGetActiveDisplayList` で得た表示器を、hub が期待する形へ写す。
///
/// - display_id: CGDirectDisplayID の文字列
/// - width_px / height_px: バッキングピクセル（Retina は 2 倍）
/// - bounds: CGDisplayBounds 相当の点（原点はメインディスプレイ左上、y は下向き）
/// - scale: ピクセル ÷ 点
/// - layout_token: 表示器の並びから作る画面構成の印
public struct CGMacControlDisplayListing: MacControlDisplayListing {

    public init() {}

    public func currentDisplays() -> [MacDisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)

        let names = NSScreen.screens.reduce(into: [CGDirectDisplayID: String]()) { result, screen in
            guard
                let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")],
                let id = (raw as? NSNumber)?.uint32Value
            else {
                return
            }
            result[id] = screen.localizedName
        }

        var displays: [MacDisplayInfo] = []
        for index in 0..<Int(count) {
            let id = ids[index]
            let bounds = CGDisplayBounds(id)
            let widthPX = Int(CGDisplayPixelsWide(id))
            let heightPX = Int(CGDisplayPixelsHigh(id))
            let rawScale = widthPX > 0 && bounds.width > 0 ? Double(widthPX) / bounds.width : 1.0
            let scale = (rawScale * 100).rounded() / 100
            displays.append(
                MacDisplayInfo(
                    displayID: String(id),
                    name: names[id] ?? "Display \(id)",
                    widthPX: widthPX,
                    heightPX: heightPX,
                    scale: scale,
                    bounds: MacRect(
                        x: Double(bounds.origin.x),
                        y: Double(bounds.origin.y),
                        width: Double(bounds.size.width),
                        height: Double(bounds.size.height)
                    ),
                    layoutToken: ""
                )
            )
        }
        let token = MacDisplayInfo.layoutToken(for: displays)
        return displays.map { display in
            var copy = display
            copy.layoutToken = token
            return copy
        }
    }
}

extension MacDisplayInfo {
    /// CGEvent へ渡す点。
    public var cgPoint: CGPoint {
        CGPoint(x: bounds.x, y: bounds.y)
    }
}
