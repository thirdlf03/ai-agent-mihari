import SwiftUI

/// デバイス一覧と選択中デバイスの詳細を保持するビューモデル。
@Observable
final class DeviceListModel {
    var devices: [DeviceSummary] = []
    var selectedUDID: String?
    var info: DeviceInfo?
    var isLoading = false
    var errorMessage: String?

    /// 一覧の取得状況を外へ知らせるコールバック。nil はステータス無しを表す。
    var onStatusChange: ((PetStatus?) -> Void)?

    private let bridge = DeviceBridge()

    /// デバイス一覧を取得し直す。
    @MainActor
    func reload() async {
        isLoading = true
        errorMessage = nil
        onStatusChange?(.running)
        defer { isLoading = false }

        let previousCount = devices.count

        do {
            devices = try await bridge.listDevices()
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) {
                await loadInfo(udid: selectedUDID)
            } else {
                self.selectedUDID = devices.first?.udid
                info = nil
                if let udid = self.selectedUDID {
                    await loadInfo(udid: udid)
                }
            }
        } catch {
            devices = []
            info = nil
            selectedUDID = nil
            errorMessage = error.localizedDescription
        }

        notifyReloadResult(previousCount: previousCount)
    }

    /// 選択されたデバイスの詳細を取得する。
    @MainActor
    func select(udid: String) async {
        selectedUDID = udid
        await loadInfo(udid: udid)
    }

    @MainActor
    private func loadInfo(udid: String) async {
        errorMessage = nil
        do {
            info = try await bridge.deviceInfo(udid: udid)
        } catch {
            info = nil
            errorMessage = error.localizedDescription
        }
    }

    /// 取得結果をステータスに変換して通知する。デバイスが増えたときだけ完了を知らせる。
    @MainActor
    private func notifyReloadResult(previousCount: Int) {
        if errorMessage != nil {
            onStatusChange?(.blocked)
        } else if devices.count > previousCount {
            onStatusChange?(.ready)
        } else {
            onStatusChange?(nil)
        }
    }
}

struct ContentView: View {
    @Environment(PetController.self) private var pet
    @State private var model = DeviceListModel()
    @State private var blockedResetTask: Task<Void, Never>?

    /// 失敗をペットに見せておく時間(秒)。
    private static let blockedDisplaySeconds = 5.0

    var body: some View {
        HSplitView {
            deviceList
                .frame(minWidth: 240)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .task {
            model.onStatusChange = { status in
                apply(status: status)
            }
            await model.reload()
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("デバイス")
                    .font(.headline)
                Spacer()
                Button(pet.isAwake ? "ペットをしまう" : "ペットを起こす") {
                    pet.toggle()
                }
                Button("更新") {
                    Task { await model.reload() }
                }
                .disabled(model.isLoading)
            }
            .padding(12)

            Divider()

            if model.isLoading && model.devices.isEmpty {
                centered { ProgressView() }
            } else if model.devices.isEmpty {
                centered {
                    Text("デバイスが見つかりません")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(model.devices, selection: selectionBinding) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.udid)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.connectionLabel(type: device.connectionType, host: device.host))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(device.udid)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("デバイス情報")
                .font(.headline)

            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.isLoading {
                ProgressView()
            }

            if let info = model.info {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    infoRow("UDID", info.udid)
                    infoRow("デバイス名", info.deviceName)
                    infoRow("機種", info.productType)
                    infoRow("OS バージョン", info.productVersion)
                    infoRow("ビルド", info.buildVersion)
                    infoRow("接続", info.connectionType)
                    if let host = info.host {
                        infoRow("ホスト", host)
                    }
                }
            } else if model.errorMessage == nil && !model.isLoading {
                Text("デバイスを選択してください")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一覧の状態をペットに反映する。失敗表示は一定時間で自動的に解除する。
    private func apply(status: PetStatus?) {
        blockedResetTask?.cancel()
        blockedResetTask = nil

        guard let status else {
            pet.clearStatus()
            return
        }

        pet.setStatus(status)
        guard status == .blocked else { return }

        blockedResetTask = Task {
            try? await Task.sleep(for: .seconds(Self.blockedDisplaySeconds))
            guard !Task.isCancelled else { return }
            pet.clearStatus()
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedUDID },
            set: { udid in
                guard let udid else { return }
                Task { await model.select(udid: udid) }
            }
        )
    }

    /// 一覧に出す接続種別のラベル。Wi-Fi のように接続先があれば併記する。
    private static func connectionLabel(type: String, host: String?) -> String {
        guard let host else { return type }
        return "\(type) · \(host)"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
