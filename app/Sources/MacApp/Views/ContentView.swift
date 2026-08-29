import SwiftUI

/// デバイス一覧と選択中デバイスの詳細を保持するビューモデル。
@Observable
final class DeviceListModel {
    var devices: [DeviceSummary] = []
    var selectedUDID: String?
    var info: DeviceInfo?
    var isLoading = false
    var errorMessage: String?

    private let bridge = DeviceBridge()

    /// デバイス一覧を取得し直す。
    @MainActor
    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
}

struct ContentView: View {
    @State private var model = DeviceListModel()

    var body: some View {
        HSplitView {
            deviceList
                .frame(minWidth: 240)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .task {
            await model.reload()
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("デバイス")
                    .font(.headline)
                Spacer()
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
