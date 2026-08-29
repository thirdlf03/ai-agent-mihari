import AppKit
import SwiftUI

/// ペットのコマ画像を表示し、ドラッグ・クリック・右クリックメニューを受け付けるビュー。
struct PetView: View {
    @Environment(PetController.self) private var pet

    /// ドラッグ開始時点の、マウス位置からウィンドウ原点までのずれ(スクリーン座標)。
    @State private var dragAnchor: CGSize?
    /// ドラッグ開始時点のマウス位置(スクリーン座標)。クリックとの区別に使う。
    @State private var dragStartLocation: CGPoint?
    /// ダブルクリック待ちの単発クリック処理。
    @State private var pendingClick: Task<Void, Never>?

    /// この距離(pt)より動かなければクリックとして扱う。
    private static let clickThreshold: CGFloat = 3

    var body: some View {
        frameImage
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .contextMenu { contextMenuItems }
            .help(pet.currentPet?.displayName ?? "ペット")
    }

    @ViewBuilder
    private var frameImage: some View {
        if let frame = pet.currentFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    /// ウィンドウを動かすドラッグ。ウィンドウ自体が動くと相対座標が当てにならないので、
    /// スクリーン座標のマウス位置を直接見る。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                guard let anchor = dragAnchor else {
                    let origin = pet.windowOrigin
                    dragAnchor = CGSize(width: mouse.x - origin.x, height: mouse.y - origin.y)
                    dragStartLocation = mouse
                    pet.beginDrag()
                    return
                }
                pet.moveWindow(to: CGPoint(x: mouse.x - anchor.width, y: mouse.y - anchor.height))
            }
            .onEnded { _ in
                let mouse = NSEvent.mouseLocation
                let start = dragStartLocation ?? mouse
                let moved = hypot(mouse.x - start.x, mouse.y - start.y)
                dragAnchor = nil
                dragStartLocation = nil
                pet.endDrag()
                if moved < Self.clickThreshold {
                    handleClick()
                }
            }
    }

    /// クリックを 1 回目・2 回目で振り分ける。ダブルクリックの猶予のあいだ単発クリックを保留する。
    private func handleClick() {
        if let pendingClick {
            pendingClick.cancel()
            self.pendingClick = nil
            pet.jump()
            return
        }

        pendingClick = Task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            pendingClick = nil
            pet.wave()
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("しゃべる") {
            pet.say(.greeting)
        }
        Button("しまう") {
            pet.tuckAway()
        }
        Divider()
        PetChoiceMenus(pet: pet)
        Divider()
        Button("アプリを表示") {
            pet.showMainWindow()
        }
    }
}

/// ペットの切り替えとサイズ変更のサブメニュー。メインメニューと右クリックメニューで共有する。
struct PetChoiceMenus: View {
    let pet: PetController

    var body: some View {
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
}
