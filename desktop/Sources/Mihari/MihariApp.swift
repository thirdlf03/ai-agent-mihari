import MihariCore
import SwiftUI

@main
struct MihariApp: App {
    var body: some Scene {
        WindowGroup("Mihari") {
            RootView()
        }
        .defaultSize(width: 940, height: 720)
    }
}
