import AppKit
import Foundation

/// control.request への回答（allow / deny）を決める口。
///
/// 既定は拒否で、許すのは「この依頼の間だけ」。hub 側でも同じ制約を強制しているので、
/// ここはあくまで人間に確認する役割。テストでは固定の回答を返すスタブに差し替える。
public protocol MacControlPermissionDeciding: Sendable {
    func decide(request: MacControlRequest) async -> MacControlWire.Decision
}

/// `NSAlert` で人間に確認する実装。
@MainActor
public final class AlertMacControlPermissionDecider: MacControlPermissionDeciding {

    public init() {}

    public func decide(request: MacControlRequest) async -> MacControlWire.Decision {
        let alert = NSAlert()
        let title = request.jobTitle.isEmpty ? "この依頼" : request.jobTitle
        alert.messageText = "「\(title)」が Mac の操作を求めています"
        alert.informativeText = [
            request.note,
            "許可すると、この依頼専用に本体の撮影・クリック・入力などの操作を実行します。"
                + "依頼の中断・Mac のロック・アプリ終了で失効します。",
            "操作のたびに許可するわけではありません（依頼ごとに一度）。",
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "この依頼の間だけ許可")
        alert.addButton(withTitle: "拒否")
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            response = await alert.runSheetModal(for: window)
        } else {
            // 何もウィンドウが無い極端な状態。シートに乗せられないので、その場でモーダルを回す。
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn ? .allow : .deny
    }
}

extension NSAlert {
    /// シートで出して、閉じたときの応答を待つ。
    func runSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
