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

    /// 「今後は確認せず許可する」が選ばれたことを覚えておく `UserDefaults` のキー。
    /// ペットメニューの「Mac 操作を常に許可」が同じキーを反転させて解除できる。
    public static let alwaysAllowKey = "macControlAlwaysAllow"

    private let defaults: UserDefaults
    /// アラートを出して応答を返す口。テストではアラートを出さずに応答と
    /// suppression の状態を差し替える。
    private let runAlert: @MainActor (NSAlert) async -> NSApplication.ModalResponse

    /// - Parameters:
    ///   - defaults: 常時許可の保存先。テストでは隔離した suite を渡す。
    ///   - runAlert: アラートの出し方。nil ならシート / モーダルで実際に出す。
    public init(
        defaults: UserDefaults = .standard,
        runAlert: (@MainActor (NSAlert) async -> NSApplication.ModalResponse)? = nil
    ) {
        self.defaults = defaults
        self.runAlert = runAlert ?? Self.presentAlert
    }

    public func decide(request: MacControlRequest) async -> MacControlWire.Decision {
        // 以前「今後は確認せず許可する」が選ばれていれば、確認を出さずに許す。
        if defaults.bool(forKey: Self.alwaysAllowKey) {
            return .allow
        }

        let alert = makeAlert(for: request)
        let response = await runAlert(alert)
        guard response == .alertSecondButtonReturn else { return .deny }
        // 「この依頼の間だけ許可」+「今後は確認せず許可する」のときだけ覚える。
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: Self.alwaysAllowKey)
        }
        return .allow
    }

    private func makeAlert(for request: MacControlRequest) -> NSAlert {
        let alert = NSAlert()
        let title = request.jobTitle.isEmpty ? "この依頼" : request.jobTitle
        alert.messageText = "「\(title)」が Mac の操作を求めています"
        alert.informativeText = [
            request.note,
            "許可すると、この依頼専用に本体の撮影・クリック・入力などの操作と、"
                + "許可フォルダ内のファイル検索・参照・受け渡しの演出を実行します。"
                + "依頼の中断・Mac のロック・アプリ終了で失効します。",
            "操作のたびに許可するわけではありません（依頼ごとに一度）。",
        ].joined(separator: "\n\n")
        // 第1ボタンが Return の既定なので、拒否を先に置く。
        alert.addButton(withTitle: "拒否")
        alert.addButton(withTitle: "この依頼の間だけ許可")
        alert.alertStyle = .warning
        // 「今後は確認せず許可する」チェック。許可と一緒に押されたときだけ覚える。
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "今後は確認せず許可する"
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return alert
    }

    private static func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return await alert.runSheetModal(for: window)
        }
        // 何もウィンドウが無い極端な状態。シートに乗せられないので、その場でモーダルを回す。
        return alert.runModal()
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
