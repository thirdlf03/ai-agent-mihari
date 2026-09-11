import AppKit
import Foundation
import ScreenCaptureKit
import os

/// システムの対象選びが前面を奪っているあいだ、依頼窓を他アプリの後ろへ落とさない。
///
/// ピッカーは別プロセスの UI なので、出すと依頼窓がキーを失い、選んだアプリの後ろへ回る。
/// 選んでいる間だけ浮かべ、終わったら元の階層に戻して手前へ出す。
@MainActor
struct ScreenshotPickerAnchor {
    private weak var window: NSWindow?
    private let originalLevel: NSWindow.Level
    private let originalHidesOnDeactivate: Bool

    init?(window: NSWindow?) {
        guard let window else { return nil }
        self.window = window
        self.originalLevel = window.level
        self.originalHidesOnDeactivate = window.hidesOnDeactivate
        window.hidesOnDeactivate = false
        window.level = .floating
        window.orderFrontRegardless()
    }

    /// 階層を元に戻し、依頼窓をキーにして手前へ出す。
    func restore() {
        guard let window else { return }
        window.level = originalLevel
        window.hidesOnDeactivate = originalHidesOnDeactivate
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// システムの画面共有ピッカーで対象を選び、1 枚だけ撮って終わる。
///
/// ストリームは開始しない。選んだ瞬間に `SCScreenshotManager` で撮ってピッカーを閉じるので、
/// 画面収録が走り続ける体験にはならない。
public enum SystemScreenshotPicker {

    /// システムの対象選び UI を出し、選ばれた画面またはウィンドウを 1 枚撮る。
    ///
    /// 選ばずに閉じたら `CancellationError` を投げる（呼び出し側はエラー表示しない）。
    public static func pick(
        checkPermission: @Sendable () -> PermissionState = { PermissionChecker.check(.screenRecording) }
    ) async throws -> ScreenshotCapture {
        let permission = checkPermission()
        guard permission.grant == .granted else {
            throw CaptureError.screenRecordingPermissionNotGranted(detail: permission.detail)
        }
        return try await SystemScreenshotPickerCoordinator.shared.pick()
    }
}

/// ピッカーの観測は Objective-C プロトコルなので NSObject 配下に置く。
/// コールバックはメイン以外から来るので、継続の受け渡しだけロックで守る。
final class SystemScreenshotPickerCoordinator: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    static let shared = SystemScreenshotPickerCoordinator()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScreenshotCapture, Error>?
    private let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "screenshot-picker")
    /// 対象選びのあいだ依頼窓を浮かべておく。メインスレッドからだけ触る。
    private var anchor: ScreenshotPickerAnchor?

    func pick() async throws -> ScreenshotCapture {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if self.continuation != nil {
                lock.unlock()
                continuation.resume(throwing: CaptureError.screenCaptureFailed(reason: "すでに画面を選んでいる"))
                return
            }
            self.continuation = continuation
            lock.unlock()
            Task { @MainActor in
                self.presentPicker()
            }
        }
    }

    @MainActor
    private func presentPicker() {
        anchor = ScreenshotPickerAnchor(window: Self.frontWindow())
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        config.allowsChangingSelectedContent = false
        config.excludedWindowIDs = NSApp.windows.map(\.windowNumber)
        picker.defaultConfiguration = config
        picker.maximumStreamCount = 1
        picker.isActive = true
        picker.present()
        logger.info("システムの対象選びを出した")
    }

    /// ボタンを押した依頼窓。キーを失っていてもタイトルで拾う。
    @MainActor
    private static func frontWindow() -> NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return window
        }
        return NSApp.windows.first { $0.title == "仕事を頼む" || $0.title == "追記する" }
    }

    private func deactivatePicker() {
        Task { @MainActor in
            let picker = SCContentSharingPicker.shared
            picker.isActive = false
            picker.remove(self)
            // システムの対象選びが閉じきる前に手前へ出すと、また後ろへ回される。
            try? await Task.sleep(for: .milliseconds(80))
            let anchor = self.anchor
            self.anchor = nil
            anchor?.restore()
        }
    }

    private func resume(_ result: Result<ScreenshotCapture, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        logger.info("対象選びを閉じた（撮らない）")
        deactivatePicker()
        resume(.failure(CancellationError()))
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        logger.info("対象が決まったので 1 枚撮る")
        // 撮り終わるまでピッカーは閉じない。先に inactive にするとフィルタが無効になることがある。
        let box = ContentFilterBox(filter: filter)
        Task {
            defer { self.deactivatePicker() }
            do {
                let capture = try await ScreenshotCaptureService.capturePNG(filter: box.filter)
                self.resume(.success(capture))
            } catch {
                self.resume(.failure(error))
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        logger.error("対象選びを出せなかった: \(error.localizedDescription, privacy: .public)")
        deactivatePicker()
        resume(.failure(CaptureError.screenCaptureFailed(reason: error.localizedDescription)))
    }
}

/// `SCContentFilter` を非同期境界へ渡すための箱。フィルタ自体は Sendable ではない。
private struct ContentFilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}
