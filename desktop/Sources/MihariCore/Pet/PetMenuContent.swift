import SwiftUI

/// ペットの右クリックメニューと、メニューバーの「ペット」メニューで共有する中身。
///
/// 上半分（監視・在席・休憩・設定）はアプリ側の `PetMenuActions` を呼び、
/// 下半分（しゃべる・しまう・見た目）は `PetController` を直接操作する。
public struct PetMenuContent<Actions: PetMenuActions>: View {
    @ObservedObject public var actions: Actions
    public let pet: PetController

    public init(actions: Actions, pet: PetController) {
        self.actions = actions
        self.pet = pet
    }

    public var body: some View {
        Button(actions.isWatching ? "監視を止める" : "監視を再開する") {
            if actions.isWatching {
                actions.stopWatching()
            } else {
                actions.startWatching()
            }
        }
        Button("在席スタンプを押す") {
            actions.stampAttendance()
        }
        Button(actions.isOnBreak ? "休憩を終える" : "休憩する(15 分)") {
            if actions.isOnBreak {
                actions.endBreak()
            } else {
                actions.startBreak()
            }
        }

        Divider()

        Button("Discord 設定…") {
            actions.openDiscordSettings()
        }
        Button("権限の確認…") {
            actions.openPermissions()
        }

        Divider()

        Button("しゃべる") {
            pet.say(.greeting)
        }
        Button(pet.isAwake ? "しまう" : "起こす") {
            if pet.isAwake {
                pet.conceal()
            } else {
                pet.reveal()
            }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        Menu("ペット") {
            ForEach(pet.pets) { candidate in
                Toggle(candidate.displayName, isOn: petBinding(for: candidate))
            }
        }
        Menu("サイズ") {
            ForEach(PetScale.allCases) { item in
                Toggle(item.label, isOn: scaleBinding(for: item))
            }
        }
        Toggle("声を出す", isOn: voiceBinding)
    }

    private func petBinding(for candidate: PetDefinition) -> Binding<Bool> {
        Binding(
            get: { pet.currentPet?.id == candidate.id },
            set: { isOn in
                guard isOn else { return }
                pet.select(pet: candidate)
            }
        )
    }

    private func scaleBinding(for item: PetScale) -> Binding<Bool> {
        Binding(
            get: { pet.scale == item.rawValue },
            set: { isOn in
                guard isOn else { return }
                pet.setScale(item.rawValue)
            }
        )
    }

    private var voiceBinding: Binding<Bool> {
        Binding(
            get: { pet.isVoiceEnabled },
            set: { pet.setVoiceEnabled($0) }
        )
    }
}
