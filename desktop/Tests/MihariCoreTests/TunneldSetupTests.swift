import Foundation
import Testing

@testable import MihariCore

@Suite("tunneld の登録スクリプト生成")
struct TunneldSetupTests {

    @Test("install スクリプトを管理者権限で実行する AppleScript を組み立てる")
    func buildsAdminInstallScript() {
        let source = TunneldSetup.installScript(bridgeDirectory: "/repo/bridge")
        #expect(
            source == "do shell script \"/repo/bridge/scripts/install_tunneld_daemon.sh\" with administrator privileges"
        )
    }

    @Test("パスの引用符とバックスラッシュをエスケープする")
    func escapesQuotesInPath() {
        let source = TunneldSetup.installScript(bridgeDirectory: #"/we"ird\path"#)
        // AppleScript リテラルの中では、引用符は \" に、バックスラッシュは \\ になる。
        #expect(source.contains(#""/we\"ird\\path/scripts/install_tunneld_daemon.sh""#))
    }
}

@Suite("tunneld の状態モデル")
@MainActor
struct TunneldModelTests {

    private final class RunnerStub: AppleScriptRunning, @unchecked Sendable {
        var outcome = AppleScriptOutcome(value: "ok")
        var sources: [String] = []
        func run(_ source: String) -> AppleScriptOutcome {
            sources.append(source)
            return outcome
        }
    }

    private func makeModel(
        probeResults: [Bool],
        runner: RunnerStub = RunnerStub()
    ) -> TunneldModel {
        let box = ProbeBox(results: probeResults)
        return TunneldModel(
            probe: { await box.next() },
            runner: runner,
            locator: DaemonLocator(
                environment: ["DEVICE_BRIDGE_DIR": "/repo/bridge"],
                isExecutable: { _ in true },
                directoryExists: { _ in true }
            ),
            settleDelay: .zero
        )
    }

    /// 呼ばれるたびに用意した結果を順に返す。
    private actor ProbeBox {
        private var results: [Bool]
        init(results: [Bool]) { self.results = results }
        func next() -> Bool { results.isEmpty ? false : results.removeFirst() }
    }

    @Test("到達できれば running になる")
    func reachableBecomesRunning() async {
        let model = makeModel(probeResults: [true])
        await model.refresh()
        #expect(model.status == .running)
    }

    @Test("到達できなければ notRunning になる")
    func unreachableBecomesNotRunning() async {
        let model = makeModel(probeResults: [false])
        await model.refresh()
        #expect(model.status == .notRunning)
    }

    @Test("登録が成功して到達できるようになれば running")
    func installSuccessBecomesRunning() async {
        let runner = RunnerStub()
        let model = makeModel(probeResults: [true], runner: runner)
        await model.install()
        #expect(model.status == .running)
        #expect(runner.sources.first?.contains("with administrator privileges") == true)
    }

    @Test("パスワード入力をキャンセルしたら notRunning のままメッセージを出す")
    func cancelKeepsNotRunning() async {
        let runner = RunnerStub()
        runner.outcome = AppleScriptOutcome(errorNumber: -128)
        let model = makeModel(probeResults: [], runner: runner)
        await model.install()
        #expect(model.status == .notRunning)
        #expect(model.message?.contains("キャンセル") == true)
    }

    @Test("実行に失敗したらエラー番号入りのメッセージを出す")
    func failureShowsError() async {
        let runner = RunnerStub()
        runner.outcome = AppleScriptOutcome(errorNumber: -10004)
        let model = makeModel(probeResults: [], runner: runner)
        await model.install()
        #expect(model.status == .notRunning)
        #expect(model.message?.contains("-10004") == true)
    }
}
