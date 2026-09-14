import AppKit
import Foundation

/// Mac 制御の `hand_off_file` を、ペットの「手渡し」カットインへ橋渡しする。
///
/// `MacControlCenter.handoffPresenter` に差し込まれる実体。
/// いま出ているペットの `cutin/deliver.png`（無ければ `reach.png`）でカットインを出し、
/// 帯にはファイル名と Finder アイコンのチップを載せ、セリフ `fileHandoff` を言わせる。
/// ペットがしまわれていても出せるよう、先に `reveal()` で表に出す。
@MainActor
public final class PetFileHandoffPresenter: MacFileHandoffPresenting {

    private let cutIn: any AttendanceCutInPresenting
    private let pet: PetController
    /// カットインを出しておく時間(秒)。過ぎたら自動で引っ込める。
    private let holdSeconds: TimeInterval
    /// 自動で引っ込める仕事。次の手渡しが来たら張り直す。
    private var dismissTask: Task<Void, Never>?

    /// - Parameters:
    ///   - cutIn: カットインの出し手。アプリでは `AttendanceCutInPresenter`。
    ///   - pet: ペットの制御。現在のペットと画面をここから引く。
    ///   - holdSeconds: カットインを出しておく時間。
    public init(
        cutIn: any AttendanceCutInPresenting,
        pet: PetController,
        holdSeconds: TimeInterval = 4
    ) {
        self.cutIn = cutIn
        self.pet = pet
        self.holdSeconds = holdSeconds
    }

    public func presentFile(at url: URL, label: String?) async -> Bool {
        guard let definition = pet.currentPet else { return false }
        guard definition.fileHandoffImageURL != nil else { return false }

        // しまっていたら表に出す。カットインは別窓だが、渡す本人が見えた方が演出として成立つ。
        pet.reveal()

        let chip = AttendanceFileChip(
            name: label?.isEmpty == false ? label! : url.lastPathComponent,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
        cutIn.presentFile(chip, of: definition, on: pet.currentScreen)
        pet.say(.fileHandoff)

        dismissTask?.cancel()
        dismissTask = Task { [weak self, holdSeconds] in
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled else { return }
            self?.cutIn.dismiss()
        }
        return true
    }
}
