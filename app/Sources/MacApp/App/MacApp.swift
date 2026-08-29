import AppKit
import SwiftUI

@main
struct MacApp: App {
    @State private var pet = PetController()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pet)
                .onAppear {
                    pet.applyLaunchState()
                }
        }
        .commands {
            CommandMenu("ペット") {
                Button(pet.isAwake ? "ペットをしまう" : "ペットを起こす") {
                    pet.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("しゃべる") {
                    pet.say(.greeting)
                }

                Divider()

                PetChoiceMenus(pet: pet)
            }
        }
    }
}
