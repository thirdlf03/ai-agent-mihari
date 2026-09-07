import AppKit
import Combine
import Foundation

/// 依頼単位で Mac 全体を撮影・操作する取りまとめ役（Mac 側）。
///
/// - Room の `/ws/mac-control` へ認証付き WebSocket を張る（発信は Mac 側）。
/// - hello / displays / state を上げ、control.request には人間への確認を挟んで答える。
/// - op は hub が検証したものだけを 1 本ずつ実行し、op.result を返す。
/// - ロック・ロック解除・終了は state として即座に部屋へ伝える（許可の失効は hub 側）。
/// - 切れたら指数バックオフで張り直す。既定はオフ（依頼が来て Mac 側で許すまで何もしない）。
@MainActor
public final class MacControlCenter: ObservableObject {

    /// 接続中か。メニューや状態表示に使う。
    @Published public private(set) var isConnected = false
    /// 状態の 1 行表示（接続 / 許可 / 操作中など）。
    @Published public private(set) var statusText = "未接続"

    public struct Dependencies {
        public var endpoint: MacControlEndpoint
        public var identity: MacControlIdentity
        public var factory: any MacControlSocketFactory
        public var `operator`: any MacControlOperating
        public var decider: any MacControlPermissionDeciding
        public var displayListing: any MacControlDisplayListing

        public init(
            endpoint: MacControlEndpoint,
            identity: MacControlIdentity,
            factory: any MacControlSocketFactory,
            `operator`: any MacControlOperating,
            decider: any MacControlPermissionDeciding,
            displayListing: any MacControlDisplayListing
        ) {
            self.endpoint = endpoint
            self.identity = identity
            self.factory = factory
            self.operator = `operator`
            self.decider = decider
            self.displayListing = displayListing
        }

        /// 実機の構成（アプリ本体から使う）。
        @MainActor public static func makeDefault() -> Dependencies {
            Dependencies(
                endpoint: .fromEnvironment(),
                identity: .make(),
                factory: WebSocketMacControlSocketFactory(),
                operator: CGEventMacControlOperator(),
                decider: AlertMacControlPermissionDecider(),
                displayListing: CGMacControlDisplayListing()
            )
        }
    }

    /// 実行中の操作。一度に 1 本（hub が保証）。
    private struct ActiveOp {
        let runID: String
        let task: Task<Void, Never>
    }

    private let deps: Dependencies
    private var runTask: Task<Void, Never>?
    private var currentSocket: (any MacControlSocket)?
    private var activeOp: ActiveOp?
    /// 操作中の常設表示。アプリ本体から差し込む（未設定なら表示しない）。
    public var operationIndicator: (any MacControlOperationIndicating)?
    /// 再接続の待ち秒数（成功するたび 1 秒に戻す）。
    private var backoffSeconds: TimeInterval = 1
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    /// 緊急停止のショートカット（⌘⇧⎋）。
    private var emergencyHotkeyMonitor: Any?

    /// アプリ本体は実機の構成で作る。テストは差し替えた Dependencies を渡す。
    public convenience init() {
        self.init(deps: Dependencies.makeDefault())
    }

    public init(deps: Dependencies) {
        self.deps = deps
    }

    // MARK: - 起動 / 停止

    /// 接続を張り始める。何度呼んでも 1 回しか効かない。
    public func start() {
        guard runTask == nil else { return }
        observeScreenLock()
        installEmergencyHotkey()
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 止める。接続と実行中の操作をすべて片付ける。
    public func stop() {
        runTask?.cancel()
        runTask = nil
        activeOp?.task.cancel()
        activeOp = nil
        let socket = currentSocket
        currentSocket = nil
        if let socket {
            Task { await socket.close() }
        }
        removeScreenLockObservers()
        removeEmergencyHotkey()
        operationIndicator?.hide()
        isConnected = false
        statusText = "停止"
    }

    /// 緊急停止。実行中の操作を止め、部屋へその旨を伝える（許可は失効して再許可が要る）。
    ///
    /// 操作の成否は hub 側で「結果不明」として扱われるので、こちらからは何も送り直さない。
    public func emergencyStop() {
        activeOp?.task.cancel()
        activeOp = nil
        operationIndicator?.hide()
        statusText = "緊急停止（許可は失効した）"
        sendState(.stop, message: "ユーザーが緊急停止した")
    }

    /// 終了時に部屋へ「アプリが終了する」を伝える。best-effort。
    /// 通信できなくても TCP 切断で hub が同じ失効を起こすので、待たない。
    public func sendQuit() {
        guard let socket = currentSocket else { return }
        Task { [socket] in
            if let text = try? MacControlOutgoing.state(.quit, message: "アプリ終了") {
                try? await socket.send(text)
            }
        }
    }

    /// いま繋がっている Mac であることを確認するために、表示器の一覧を返す。
    /// テストではこの値をそのまま hello に載せる。
    public func currentDisplays() -> [MacDisplayInfo] {
        deps.displayListing.currentDisplays()
    }

    // MARK: - 接続ループ

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                let socket = try await deps.factory.makeSocket(endpoint: deps.endpoint)
                currentSocket = socket
                let hello = try MacControlOutgoing.hello(
                    endpoint: deps.endpoint,
                    identity: deps.identity,
                    displays: deps.displayListing.currentDisplays()
                )
                try await socket.send(hello)
                while !Task.isCancelled {
                    guard let text = try await socket.receive() else { break }
                    await handle(text: text, socket: socket)
                    backoffSeconds = 1
                }
            } catch is CancellationError {
                break
            } catch {
                statusText = "接続に失敗した（再試行を待つ）"
            }
            let previous = currentSocket
            currentSocket = nil
            if let previous {
                Task { await previous.close() }
            }
            if isConnected {
                isConnected = false
                statusText = "再接続を待つ…"
            }
            let delay = backoffSeconds
            backoffSeconds = min(backoffSeconds * 2, 30)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handle(text: String, socket: any MacControlSocket) async {
        guard let data = text.data(using: .utf8),
            let parsed = try? MacControlIncomingFrame.parse(data: data)
        else {
            // 未知のフレームは無視してよい。
            return
        }
        switch parsed.frame {
        case .helloAck:
            isConnected = true
            statusText = "接続"

        case .ping(let ts):
            if let pong = try? MacControlOutgoing.pong(ts: ts) {
                try? await socket.send(pong)
            }

        case .controlRequest(let request):
            // 依頼 1 回につき 1 度、人間に確認する。既定は拒否。
            let decision = await deps.decider.decide(request: request)
            statusText = decision == .allow ? "操作を許可（この依頼の間だけ）" : "操作を拒否"
            if let text = try? MacControlOutgoing.decision(decision, request: request) {
                try? await socket.send(text)
            }

        case .op(let op):
            execute(op: op, socket: socket)

        case .cancelRun(let runID, _):
            if let active = activeOp, active.runID == runID {
                active.task.cancel()
                activeOp = nil
                // 結果は hub 側で未知扱いになり、こちらは送らない（自動再送もしない）。
            }
        }
    }

    /// 操作 1 本を実行する。hub は一度に 1 本しか送らない。
    private func execute(op: MacControlOpFrame, socket: any MacControlSocket) {
        // 前の操作が残っていたら畳む（hub が保証するので通常は無い）。
        activeOp?.task.cancel()
        statusText = "操作を実行中: \(op.kind.rawValue)"
        operationIndicator?.show(summary: describeForIndicator(op)) { [weak self] in
            Task { @MainActor [weak self] in self?.emergencyStop() }
        }
        let task = Task { [deps, weak self] in
            let result: MacOpExecutionResult
            defer { self?.operationIndicator?.hide() }
            do {
                result = try await deps.`operator`.execute(op: op)
            } catch is CancellationError {
                // 依頼の中断・アプリ停止。実行途中で止めたので結果不明。
                result = .failure(code: "canceled", message: "依頼の中断で止めた（結果は不明）")
            } catch {
                result = .failure(code: "execution_failed", message: error.localizedDescription)
            }
            if let text = try? MacControlOutgoing.opResult(op: op, result: result) {
                try? await socket.send(text)
            }
        }
        activeOp = ActiveOp(runID: op.runID, task: task)
    }

    /// 常設表示に出す短い説明。秘密（入力文そのまま）は載せない。
    private func describeForIndicator(_ op: MacControlOpFrame) -> String {
        var parts = [op.kind.rawValue]
        if let displayID = op.displayID { parts.append("表示器 \(displayID)") }
        if let x = op.xPX, let y = op.yPX { parts.append("x=\(x) y=\(y)") }
        if op.kind == .typeText { parts.append("文字入力") }
        return parts.joined(separator: " ")
    }

    // MARK: - 画面のロック / アンロック

    /// ロック中は hub が操作を拒否する（許可が失効する）。アンロック時は再許可が要る。
    ///
    /// AppKit には画面ロックの公開通知がないため、"com.apple.screenIsLocked" を
    /// DistributedNotificationCenter で受け取る（macOS が配る連邦通知）。
    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        lockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.operationIndicator?.hide()
                self?.sendState(.lock)
            }
        }
        unlockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendStateAfterUnlock() }
        }
    }

    private func removeScreenLockObservers() {
        let center = DistributedNotificationCenter.default()
        if let lockObserver {
            center.removeObserver(lockObserver)
            self.lockObserver = nil
        }
        if let unlockObserver {
            center.removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
    }

    /// 緊急停止のグローバルショートカット（⌘⇧⎋）を張る。
    ///
    /// 画面を他のアプリが握っていても止められるよう、受動監視だけで検知する。
    private func installEmergencyHotkey() {
        guard emergencyHotkeyMonitor == nil else { return }
        emergencyHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]),
                event.keyCode == Self.emergencyStopKeyCode
            else {
                return
            }
            Task { @MainActor [weak self] in self?.emergencyStop() }
        }
    }

    private func removeEmergencyHotkey() {
        if let emergencyHotkeyMonitor {
            NSEvent.removeMonitor(emergencyHotkeyMonitor)
            self.emergencyHotkeyMonitor = nil
        }
    }

    /// 緊急停止に使うキー（⎋ / Escape）。修飾キー付きでないと誤爆するので、
    /// 単体では何も起こらない。
    private static let emergencyStopKeyCode: UInt16 = 53

    /// ロック / アンロックの状態を部屋へ送る。テストからも直接呼べるよう internal。
    func sendState(_ event: MacControlWire.StateEvent, message: String = "") {
        guard let socket = currentSocket else { return }
        Task { [socket] in
            if let text = try? MacControlOutgoing.state(event, message: message) {
                try? await socket.send(text)
            }
        }
    }

    /// アンロック直後は画面構成も変わりうるので、state と displays の両方を送る。
    func sendStateAfterUnlock() {
        guard let socket = currentSocket else { return }
        Task { [socket, deps] in
            if let unlock = try? MacControlOutgoing.state(.unlock) {
                try? await socket.send(unlock)
            }
            if let displays = try? MacControlOutgoing.displays(deps.displayListing.currentDisplays()) {
                try? await socket.send(displays)
            }
        }
    }
}
