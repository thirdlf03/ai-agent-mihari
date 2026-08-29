import MihariCore
import SwiftUI

@main
struct MihariApp: App {

    init() {
        // MIHARI_SELFTEST=1 で起動すると、実機でしか確かめられない経路を通して結果を出し、終了する。
        // 画面を出さずに済ませたいので、ウィンドウを作る前にここで分岐する。
        guard SelfTest.isRequested else { return }
        Task { @MainActor in
            let ok = await SelfTest.run()
            exit(ok ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup("Mihari") {
            RootView()
        }
        .defaultSize(width: 940, height: 720)
    }
}
