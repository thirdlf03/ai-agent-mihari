import AppKit
import SwiftUI
import os

/// 在席スタンプのカットインの表示 / 差し替え / 解除を担う層。
///
/// `NSPanel` の生成と配置はここに閉じ込め、`AppCoordinator` からは絵の名前だけを渡す。
@MainActor
public protocol AttendanceCutInPresenting: AnyObject {
    /// カットインを出す。`pet` の `cutin/` から絵を読み、`screen` の右下に密着させる。
    func present(_ image: AttendanceCutInImage, of pet: PetDefinition, on screen: NSScreen?)

    /// 出しているカットインの絵を差し替える。`flash` を true にすると白く光らせる。
    func swap(to image: AttendanceCutInImage, flash: Bool)

    /// カットインを画面の外へ滑らせて閉じる。
    func dismiss()
}

/// `NSPanel` + SwiftUI によるカットインの実装。
@MainActor
public final class AttendanceCutInPresenter: AttendanceCutInPresenting {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "attendance.cutin")

    /// 画面の高さに対するカットインの一辺の割合。
    private static let sideRatio: CGFloat = 0.5
    /// カットインの一辺の上限(pt)。大きな画面でも出過ぎないようにする。
    private static let maxSide: CGFloat = 900
    /// 閉じるときのスライドアウトにかける時間(秒)。
    private static let exitDuration: TimeInterval = 0.3

    private var window: AttendanceCutInWindow?
    private var model: AttendanceCutInModel?
    /// 絵の置き場所を引くための、いま出しているペット。
    private var pet: PetDefinition?
    /// スライドアウトし終えてからウィンドウを片付ける仕事。次の表示が来たら取り消す。
    private var exitTask: Task<Void, Never>?

    public init() {}

    public func present(_ image: AttendanceCutInImage, of pet: PetDefinition, on screen: NSScreen?) {
        guard let nsImage = Self.loadImage(image, of: pet) else {
            Self.logger.error("カットインの画像を読めないので演出を出さない: \(image.rawValue, privacy: .public)")
            return
        }
        guard let frame = Self.frame(on: screen) else {
            Self.logger.error("表示できる画面が無いのでカットインを出さない")
            return
        }

        // 前の表示が残っていれば、待たずに片付けてから出し直す。
        exitTask?.cancel()
        exitTask = nil
        tearDown()

        self.pet = pet
        let model = AttendanceCutInModel(
            image: nsImage,
            kind: image,
            isReduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        self.model = model

        let panel = AttendanceCutInWindow()
        window = panel
        panel.setFrame(frame, display: false)
        let hostingView = NSHostingView(rootView: AttendanceCutInView(model: model))
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView
        panel.orderFrontRegardless()
    }

    public func swap(to image: AttendanceCutInImage, flash: Bool) {
        guard let model, let pet, let nsImage = Self.loadImage(image, of: pet) else { return }
        model.image = nsImage
        model.kind = image
        if flash { model.isFlashing = true }
    }

    public func dismiss() {
        guard let model else { return }
        let duration = model.isReduceMotionEnabled ? AttendanceCutInView.fadeDuration : Self.exitDuration
        withAnimation(.easeIn(duration: duration)) {
            model.isLeaving = true
        }
        exitTask?.cancel()
        exitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.exitTask = nil
            self?.tearDown()
        }
    }

    /// ウィンドウを閉じて、次の表示に持ち越さないよう状態を捨てる。
    private func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        model = nil
        pet = nil
    }

    private static func loadImage(_ image: AttendanceCutInImage, of pet: PetDefinition) -> NSImage? {
        guard let url = pet.cutInImageURL(image) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 表示する矩形。指定された画面(取れなければ主画面)の visibleFrame の右下に密着させる。
    private static func frame(on screen: NSScreen?) -> CGRect? {
        guard let bounds = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let side = min(bounds.height * sideRatio, maxSide)
        guard side > 0 else { return nil }
        return CGRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: side)
    }
}
