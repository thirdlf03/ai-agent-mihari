import SwiftUI

/// アプリのルート。権限オンボーディングとデーモンの状態をタブで並べる。
public struct RootView: View {
    @StateObject private var permissions = PermissionsModel()
    @StateObject private var daemon = DaemonController()

    public init() {}

    public var body: some View {
        TabView {
            OnboardingView(model: permissions)
                .tabItem { Label("権限", systemImage: "lock.shield") }
            DaemonView(controller: daemon)
                .tabItem { Label("デーモン", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 880, minHeight: 560)
        .task {
            // アプリが立ち上がったらデーモンも立ち上げる。以降の機能は全部これに乗る。
            await daemon.start()
        }
        .onDisappear {
            daemon.stop()
        }
    }
}
