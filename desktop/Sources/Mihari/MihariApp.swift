import MihariCore
import SwiftUI

@main
struct MihariApp: App {
    @NSApplicationDelegateAdaptor(MihariAppDelegate.self) private var delegate

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
        // Mihari の本体はデスクトップのペットなので、起動しても普通はウィンドウを出さない。
        // WindowGroup は宣言しただけで起動時に開いてしまうため、自動で開かない Settings だけを置き、
        // 実ウィンドウは MihariAppDelegate 側で必要になったときだけ作る。
        Settings { EmptyView() }
            .commands {
                // Settings シーンが足す「設定…」の項目は、開いても空なので消す。
                CommandGroup(replacing: .appSettings) {}
                CommandMenu("ペット") {
                    PetMenuContent(
                        actions: delegate.coordinator,
                        presenter: delegate.coordinator.pet
                    )
                }
            }
    }
}
