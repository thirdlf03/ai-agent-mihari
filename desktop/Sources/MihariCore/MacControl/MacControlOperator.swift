import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 操作の実行口。撮影・クリック・ドラッグ・スクロール・入力・キー・アプリ切り替え。
///
/// 汎用 Computer Use ではなく、hub が許可と画面構成を検証してから送ってきた操作だけを実行する。
/// テストでは固定の応答を返すスタブに差し替える。
public protocol MacControlOperating: Sendable {
    /// 操作を 1 本実行する。例外はキャンセル(CancellationError)以外は握らず、
    /// 失敗も `MacOpExecutionResult.failure` として返す。
    func execute(op: MacControlOpFrame) async throws -> MacOpExecutionResult
}

/// ファイルの「手渡し」演出を出す口。
///
/// `AppCoordinator` が `PetFileHandoffPresenter`（ペットのカットイン）を差し込む。
/// 未設定でも `hand_off_file` は失敗にせず、Finder での表示だけを結果に返す。
public protocol MacFileHandoffPresenting: Sendable {
    /// ファイルを手渡す演出を出す。出せたら true。
    /// ペットがいない・カットイン画像が無いなどで出せなければ false。
    func presentFile(at url: URL, label: String?) async -> Bool
}

/// CGEvent / ScreenCaptureKit を使う実装主体。
public struct CGEventMacControlOperator: MacControlOperating {

    private let capture: MacControlCapturePerforming
    private let displays: MacControlDisplayListing
    /// ファイル系 op が触れてよい範囲。`MIHARI_MAC_SEARCH_DIRS` で上書きできる。
    private let filePolicy: MacFileAccessPolicy
    /// 手渡しファイルを束ねるステージ。短い窓で届いた分を1フォルダに集めて開く。
    private let handoffStage: MacHandoffStage
    /// 手渡し演出の出し手。`MacControlCenter` があとから差し込む。
    public var handoffPresenter: (any MacFileHandoffPresenting)? {
        didSet { handoffStage.presenter = handoffPresenter }
    }
    private let accessibilityIsTrusted: @Sendable () -> Bool
    private let screenRecordingIsGranted: @Sendable () -> Bool

    public init(
        capture: MacControlCapturePerforming = ScreenCaptureKitMacControlCapture(),
        displays: MacControlDisplayListing = CGMacControlDisplayListing(),
        filePolicy: MacFileAccessPolicy = MacFileAccessPolicy(),
        handoffPresenter: (any MacFileHandoffPresenting)? = nil,
        handoffStage: MacHandoffStage = MacHandoffStage(),
        accessibilityIsTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        screenRecordingIsGranted: @escaping @Sendable () -> Bool = {
            PermissionChecker.check(.screenRecording).grant == .granted
        }
    ) {
        self.capture = capture
        self.displays = displays
        self.filePolicy = filePolicy
        self.handoffStage = handoffStage
        self.handoffPresenter = handoffPresenter
        handoffStage.presenter = handoffPresenter
        self.accessibilityIsTrusted = accessibilityIsTrusted
        self.screenRecordingIsGranted = screenRecordingIsGranted
    }

    public func execute(op: MacControlOpFrame) async throws -> MacOpExecutionResult {
        switch op.kind {
        case .capture:
            return try await performCapture(op: op)
        case .click, .doubleClick:
            guard let point = op.point(fromX: op.xPX, fromY: op.yPX) else {
                return .failure(code: "missing_display_layout", message: "撮影情報が無い。mac_capture で撮り直して")
            }
            if let failure = ensureAccessibility() { return failure }
            return PointPosting.performClick(
                at: point,
                button: op.button,
                double: op.kind == .doubleClick,
                modifiers: op.modifiers
            )
        case .drag:
            guard let from = op.point(fromX: op.fromXPX, fromY: op.fromYPX),
                let to = op.point(toX: op.toXPX, toY: op.toYPX)
            else {
                return .failure(code: "missing_display_layout", message: "撮影情報が無い。mac_capture で撮り直して")
            }
            if let failure = ensureAccessibility() { return failure }
            return PointPosting.performDrag(from: from, to: to, button: op.button, modifiers: op.modifiers)
        case .scroll:
            return PointPosting.performScroll(
                deltaX: op.deltaX,
                deltaY: op.deltaY,
                at: op.xPX == nil && op.yPX == nil ? nil : op.point(fromX: op.xPX, fromY: op.yPX)
            )
        case .typeText:
            guard let text = op.text, !text.isEmpty else {
                return .failure(code: "invalid_params", message: "text が空")
            }
            guard text.count <= MacControlWire.maxTextChars else {
                return .failure(code: "invalid_params", message: "text が長すぎる（上限 \(MacControlWire.maxTextChars) 文字）")
            }
            if let failure = ensureAccessibility() { return failure }
            return try await KeyboardPosting.typeText(text)
        case .key:
            let keycode: Int
            if let given = op.keycode {
                keycode = given
            } else if let name = op.keyName, let mapped = KeyboardPosting.keycode(forName: name) {
                keycode = Int(mapped)
            } else {
                return .failure(code: "invalid_params", message: "key が未対応: \(op.keyName ?? "")")
            }
            if let failure = ensureAccessibility() { return failure }
            return KeyboardPosting.pressKey(keycode: keycode, modifiers: op.modifiers)
        case .activateApp:
            return await AppActivation.activate(bundleID: op.bundleID, appName: op.appName)
        case .findFiles:
            return await performFindFiles(op: op)
        case .fetchFile:
            return performFetchFile(op: op)
        case .handOffFile:
            return await performHandOffFile(op: op)
        case .unsupported:
            // 知らない kind を click などへ倒さず、そのまま失敗として返す。
            return .failure(code: "unsupported_op", message: "未知の操作種別: \(op.rawKind)")
        }
    }

    /// 許可フォルダ内でファイルを探す。`dirs` の指定は許可ルートの内側に絞る。
    private func performFindFiles(op: MacControlOpFrame) async -> MacOpExecutionResult {
        guard let query = op.query, !query.isEmpty else {
            return .failure(code: "invalid_params", message: "query が空")
        }
        let scope = op.searchScope ?? "name"
        guard scope == "name" || scope == "content" else {
            return .failure(code: "invalid_params", message: "scope は name / content だけ")
        }
        let limit = min(max(op.searchLimit ?? 10, 1), 50)
        do {
            let dirs = try filePolicy.resolveSearchDirs(param: op.searchDirs)
            let entries = await MacLocalFileSearch.find(query: query, scope: scope, dirs: dirs, limit: limit)
            return .makeSuccess([
                "files": entries.map(\.dictionary),
                "count": entries.count,
            ])
        } catch let error as MacFileSearchError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: "execution_failed", message: error.localizedDescription)
        }
    }

    /// 許可フォルダ内のファイルを読んで部屋へ返す。大きいものは `max_bytes` で切って truncated を立てる。
    private func performFetchFile(op: MacControlOpFrame) -> MacOpExecutionResult {
        guard let rawPath = op.filePath, !rawPath.isEmpty else {
            return .failure(code: "invalid_params", message: "path が空")
        }
        let maxBytes = min(max(op.maxBytes ?? 8_388_608, 1), 16_777_216)
        let url = MacFileAccessPolicy.fileURL(for: rawPath)
        guard filePolicy.allows(url) else {
            return .failure(
                code: MacFileSearchError.pathNotAllowed.code,
                message: MacFileSearchError.pathNotAllowed.message
            )
        }
        do {
            return .makeSuccess(try MacLocalFileSearch.fetchFile(url: url, maxBytes: maxBytes))
        } catch let error as MacFileSearchError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: "execution_failed", message: error.localizedDescription)
        }
    }

    /// 許可フォルダ内のファイルをステージへ積み、バッチの flush を待って結果を返す。
    /// 連続して届く複数ファイルは1フォルダにまとまり、Finder が開くのも
    /// カットインもバッチごとに1回。演出を出す側が未接続でも失敗にはしない。
    private func performHandOffFile(op: MacControlOpFrame) async -> MacOpExecutionResult {
        guard let rawPath = op.filePath, !rawPath.isEmpty else {
            return .failure(code: "invalid_params", message: "path が空")
        }
        let url = MacFileAccessPolicy.normalize(MacFileAccessPolicy.fileURL(for: rawPath))
        guard filePolicy.allows(url) else {
            return .failure(
                code: MacFileSearchError.pathNotAllowed.code,
                message: MacFileSearchError.pathNotAllowed.message
            )
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return .failure(
                code: MacFileSearchError.fileNotFound.code,
                message: MacFileSearchError.fileNotFound.message
            )
        }
        let key = op.jobID.isEmpty ? "misc" : op.jobID
        let outcomes = await handoffStage.add(
            MacHandoffStage.Entry(url: url, label: op.handOffLabel, key: key)
        ).value
        let outcome =
            outcomes[key]
            ?? MacHandoffStage.Outcome(
                directory: nil,
                presented: false,
                error: "handoff batch missing"
            )
        if let error = outcome.error {
            return .failure(code: "execution_failed", message: error)
        }
        return .makeSuccess([
            "revealed": outcome.directory != nil,
            "presented": outcome.presented,
        ])
    }

    /// アクセシビリティ権限が無ければ failure を返す。CGEvent の送出に要る。
    private func ensureAccessibility() -> MacOpExecutionResult? {
        guard !accessibilityIsTrusted() else { return nil }
        return .failure(
            code: "permission.accessibility",
            message: "アクセシビリティ権限が無い。システム設定のプライバシーで許可してからもう一度"
        )
    }

    private func performCapture(op: MacControlOpFrame) async throws -> MacOpExecutionResult {
        guard screenRecordingIsGranted() else {
            return .failure(
                code: "permission.screen_recording",
                message: "画面収録権限が無い。システム設定のプライバシーで許可してからもう一度"
            )
        }
        let current = displays.currentDisplays()
        guard let display = resolveDisplay(op.displayID, in: current) else {
            return .failure(code: "display_not_found", message: "表示器 \(op.displayID ?? "") が見つからない")
        }
        let png: Data
        let image: CGImage
        do {
            (image, png) = try await capture.captureDisplayPNG(
                displayID: UInt32(display.displayID) ?? CGMainDisplayID()
            )
        } catch {
            return .failure(code: "execution_failed", message: "撮影に失敗した: \(error.localizedDescription)")
        }
        return .makeSuccess(
            [
                "display_id": display.displayID,
                "width_px": image.width,
                "height_px": image.height,
                "scale": display.scale,
                "bounds": [
                    "x": display.bounds.x,
                    "y": display.bounds.y,
                    "width": display.bounds.width,
                    "height": display.bounds.height,
                ],
                "layout_token": display.layoutToken,
                "image_base64": png.base64EncodedString(),
            ]
        )
    }

    /// display_id 省略時はメインディスプレイ（bounds 原点 0,0）優先。hub 側の resolve_display と同じ。
    private func resolveDisplay(_ displayID: String?, in displays: [MacDisplayInfo]) -> MacDisplayInfo? {
        guard !displays.isEmpty else { return nil }
        if let displayID, !displayID.isEmpty {
            return displays.first { $0.displayID == displayID }
        }
        return displays.first { $0.bounds.x == 0 && $0.bounds.y == 0 } ?? displays.first
    }
}

/// 画面撮影の実体。`SCShareableContent` が要るため非同期。
public protocol MacControlCapturePerforming: Sendable {
    func captureDisplayPNG(displayID: CGDirectDisplayID) async throws -> (CGImage, Data)
}

/// ScreenCaptureKit で表示器を 1 枚撮る。`ScreenshotCaptureService` と同じ方式。
public struct ScreenCaptureKitMacControlCapture: MacControlCapturePerforming {

    public init() {}

    public func captureDisplayPNG(displayID: CGDirectDisplayID) async throws -> (CGImage, Data) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw MacControlCaptureError.captureFailed(reason: error.localizedDescription)
        }
        guard
            let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
        else {
            throw MacControlCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true
        configuration.captureResolution = .best
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw MacControlCaptureError.captureFailed(reason: error.localizedDescription)
        }
        let png = try CaptureImageCodec.pngData(from: image)
        return (image, png)
    }
}

public enum MacControlCaptureError: Error, Sendable {
    case noDisplay
    case captureFailed(reason: String)
}

// MARK: - マウス

private enum PointPosting {

    static func performClick(
        at point: MacPoint,
        button: String,
        double: Bool,
        modifiers: [String]
    ) -> MacOpExecutionResult {
        let cgButton = mouseButton(button)
        let types = mouseTypes(cgButton)
        for _ in 0..<(double ? 2 : 1) {
            move(to: point, flags: flags(modifiers))
            post(types.down, at: point, button: cgButton, flags: flags(modifiers))
            Thread.sleep(forTimeInterval: 0.05)
            post(types.up, at: point, button: cgButton, flags: flags(modifiers))
            if double { Thread.sleep(forTimeInterval: 0.08) }
        }
        return .makeSuccess(["ok": true])
    }

    static func performDrag(
        from: MacPoint,
        to: MacPoint,
        button: String,
        modifiers: [String]
    ) -> MacOpExecutionResult {
        let cgButton = mouseButton(button)
        let types = mouseTypes(cgButton)
        move(to: from, flags: flags(modifiers))
        post(types.down, at: from, button: cgButton, flags: flags(modifiers))
        // 飛ばさずにゆっくり引く。速すぎるとアプリが追いつかない。
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = MacPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            )
            post(types.drag, at: point, button: cgButton, flags: flags(modifiers))
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.05)
        post(types.up, at: to, button: cgButton, flags: flags(modifiers))
        return .makeSuccess(["ok": true])
    }

    static func performScroll(deltaX: Double?, deltaY: Double?, at point: MacPoint?) -> MacOpExecutionResult {
        let source = CGEventSource(stateID: .hidSystemState)
        let wheel1 = Int32(deltaY?.rounded() ?? 0)
        let wheel2 = Int32(deltaX?.rounded() ?? 0)
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 2,
                wheel1: wheel1,
                wheel2: wheel2,
                wheel3: 0
            )
        else {
            return .failure(code: "execution_failed", message: "スクロールイベントを作れなかった")
        }
        if let point {
            event.location = CGPoint(x: point.x, y: point.y)
        }
        event.post(tap: .cghidEventTap)
        return .makeSuccess(["ok": true])
    }

    private static func move(to point: MacPoint, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: .left
        )?
        .tap(flags: flags)
        .post(tap: .cghidEventTap)
    }

    private static func post(_ type: CGEventType, at point: MacPoint, button: CGMouseButton, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: button
        )?
        .tap(flags: flags)
        .post(tap: .cghidEventTap)
    }

    private static func mouseButton(_ name: String) -> CGMouseButton {
        switch name {
        case "right": return .right
        case "middle": return .center
        default: return .left
        }
    }

    private static func mouseTypes(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch button {
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .center: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        }
    }

    private static func flags(_ modifiers: [String]) -> CGEventFlags {
        KeyboardPosting.flags(modifiers)
    }
}

extension CGEvent {
    /// 修飾キーを載せる。
    fileprivate func tap(flags: CGEventFlags) -> CGEvent {
        self.flags = flags
        return self
    }
}

// MARK: - キーボード

private enum KeyboardPosting {

    static func typeText(_ text: String) async throws -> MacOpExecutionResult {
        let source = CGEventSource(stateID: .hidSystemState)
        var processed = 0
        for scalar in text.unicodeScalars {
            try Task.checkCancellation()
            var chars = [UniChar(scalar.value)]
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            up?.post(tap: .cghidEventTap)
            processed += 1
            if processed % 20 == 0 {
                // 長文でアプリが追いつけるように、ときどき休む。
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        return .makeSuccess(["ok": true, "chars": text.count])
    }

    static func pressKey(keycode: Int, modifiers: [String]) -> MacOpExecutionResult {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = Self.flags(modifiers)
        let code = CGKeyCode(UInt16(keycode))
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        return .makeSuccess(["ok": true, "keycode": keycode])
    }

    static func keycode(forName name: String) -> CGKeyCode? {
        switch name {
        case "return": return CGKeyCode(kVK_Return)
        case "escape": return CGKeyCode(kVK_Escape)
        case "tab": return CGKeyCode(kVK_Tab)
        case "space": return CGKeyCode(kVK_Space)
        case "delete": return CGKeyCode(kVK_Delete)
        case "forward_delete": return CGKeyCode(kVK_ForwardDelete)
        case "up": return CGKeyCode(kVK_UpArrow)
        case "down": return CGKeyCode(kVK_DownArrow)
        case "left": return CGKeyCode(kVK_LeftArrow)
        case "right": return CGKeyCode(kVK_RightArrow)
        case "home": return CGKeyCode(kVK_Home)
        case "end": return CGKeyCode(kVK_End)
        case "page_up": return CGKeyCode(kVK_PageUp)
        case "page_down": return CGKeyCode(kVK_PageDown)
        case "command": return CGKeyCode(kVK_Command)
        case "shift": return CGKeyCode(kVK_Shift)
        case "control": return CGKeyCode(kVK_Control)
        case "option": return CGKeyCode(kVK_Option)
        case "caps_lock": return CGKeyCode(kVK_CapsLock)
        case "fn": return CGKeyCode(kVK_Function)
        default: return nil
        }
    }

    static func flags(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in modifiers {
            switch name {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "control": flags.insert(.maskControl)
            case "option": flags.insert(.maskAlternate)
            case "caps_lock": flags.insert(.maskAlphaShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}

// MARK: - アプリ切り替え

private enum AppActivation {

    static func activate(bundleID: String?, appName: String?) async -> MacOpExecutionResult {
        if let bundleID, !bundleID.isEmpty {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
                return .makeSuccess(["ok": true, "bundle_id": bundleID])
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return .failure(code: "app_not_found", message: "アプリ \(bundleID) が見つからない")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            } catch {
                return .failure(
                    code: "app_not_found",
                    message: "アプリ \(bundleID) を開けなかった: \(error.localizedDescription)"
                )
            }
            return .makeSuccess(["ok": true, "bundle_id": bundleID])
        }
        guard let appName, !appName.isEmpty else {
            return .failure(code: "invalid_params", message: "bundle_id / app_name のどちらかは要る")
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }) {
            app.activate()
            return .makeSuccess(["ok": true, "app_name": appName])
        }
        let url = URL(fileURLWithPath: "/Applications/\(appName).app")
        guard NSWorkspace.shared.open(url) else {
            return .failure(code: "app_not_found", message: "アプリ \(appName) が見つからない")
        }
        return .makeSuccess(["ok": true, "app_name": appName])
    }
}
