import SwiftUI

/// 仕事一覧の 1 行。状態・題・最新本文・未読完了を載せる。
public struct RoomJobListItem: Identifiable, Equatable, Sendable {
    public let jobID: String
    public let title: String
    public let status: RoomJobStatus
    public let source: String?
    public let latestText: String?
    public let artifactCount: Int
    public let body: String?
    public let createdAt: Date?
    public let unread: Bool

    public var id: String { jobID }

    public init(
        jobID: String,
        title: String,
        status: RoomJobStatus,
        source: String? = nil,
        latestText: String? = nil,
        artifactCount: Int = 0,
        body: String? = nil,
        createdAt: Date? = nil,
        unread: Bool = false
    ) {
        self.jobID = jobID
        self.title = title
        self.status = status
        self.source = source
        self.latestText = latestText
        self.artifactCount = artifactCount
        self.body = body
        self.createdAt = createdAt
        self.unread = unread
    }
}

/// 仕事一覧の状態。`/jobs` のスナップショットを検索・選択・未読完了と結びつける。
@MainActor
public final class RoomJobListViewModel: ObservableObject {
    @Published public private(set) var items: [RoomJobListItem] = []
    @Published public var query = ""
    @Published public private(set) var selectedJobID: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading = false

    private let access: any RoomAccess
    private let readStore: RoomJobReadStoring
    private let monitor: RoomJobMonitor

    public init(access: any RoomAccess, monitor: RoomJobMonitor, readStore: RoomJobReadStoring) {
        self.access = access
        self.monitor = monitor
        self.readStore = readStore
    }

    /// 検索で絞った一覧。本文・題・ID に部分一致。
    public var filteredItems: [RoomJobListItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.title.lowercased().contains(needle)
                || (item.body?.lowercased().contains(needle) ?? false)
                || item.jobID.lowercased().contains(needle)
        }
    }

    /// 未読の完了（完了・失敗・中断）の件数。
    public var unreadCount: Int {
        items.filter(\.unread).count
    }

    /// `/jobs` から一覧を引き直す。再起動後・Discord 作成の仕事もここに載る。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await access.listJobs()
            lastError = nil
            items = details.map(item(from:))
            recomputeUnread()
            merge(monitorJobs: monitor.jobs)
        } catch {
            lastError = (error as? RoomError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 監視中の仕事で一覧を上書きする。別ジョブの進捗で選択は動かさない。
    public func merge(monitorJobs: [RoomJobTrackedJob]) {
        for tracked in monitorJobs {
            if let index = items.firstIndex(where: { $0.jobID == tracked.jobID }) {
                let old = items[index]
                let item = RoomJobListItem(
                    jobID: old.jobID,
                    title: tracked.title,
                    status: tracked.status,
                    source: old.source,
                    latestText: tracked.latestText,
                    artifactCount: tracked.artifacts.count,
                    body: old.body,
                    createdAt: old.createdAt,
                    unread: old.unread
                )
                items[index] = item
            } else {
                items.insert(
                    RoomJobListItem(
                        jobID: tracked.jobID,
                        title: tracked.title,
                        status: tracked.status,
                        latestText: tracked.latestText,
                        artifactCount: tracked.artifacts.count,
                        unread: false
                    ),
                    at: 0
                )
            }
        }
        recomputeUnread()
    }

    /// 選択して開いた仕事を固定する。未読を消す。
    public func select(_ jobID: String) {
        selectedJobID = jobID
        readStore.markRead(jobID)
        recomputeUnread()
    }

    /// その仕事を読んだとして未読を消す。
    public func markRead(_ jobID: String) {
        readStore.markRead(jobID)
        recomputeUnread()
    }

    private func item(from detail: RoomJobDetail) -> RoomJobListItem {
        let status = RoomJobStatus(rawValue: detail.status ?? "") ?? .queued
        return RoomJobListItem(
            jobID: detail.jobID,
            title: detail.title ?? detail.jobID,
            status: status,
            source: detail.source,
            latestText: detail.latestEvent?.text,
            artifactCount: detail.artifacts.count,
            body: detail.body,
            createdAt: detail.createdAt,
            unread: status.isTerminal && !readStore.isRead(detail.jobID)
        )
    }

    private func recomputeUnread() {
        items = items.map { item in
            guard item.status.isTerminal else { return item }
            let unread = !readStore.isRead(item.jobID)
            if unread == item.unread { return item }
            var copy = item
            copy = RoomJobListItem(
                jobID: item.jobID,
                title: item.title,
                status: item.status,
                source: item.source,
                latestText: item.latestText,
                artifactCount: item.artifactCount,
                body: item.body,
                createdAt: item.createdAt,
                unread: unread
            )
            return copy
        }
    }
}

extension RoomJobStatus {
    /// 終端の状態か（完了・失敗・中断）。
    var isTerminal: Bool {
        self == .done || self == .failed || self == .cancelled
    }

    /// 一覧の状態バッジの色。
    var tintColor: Color {
        switch self {
        case .queued: return .gray
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

/// 仕事一覧。待機・実行中・完了・失敗・中断を検索し、選択した仕事を固定して詳細を開く。
public struct RoomJobListView: View {
    @StateObject private var model: RoomJobListViewModel
    @ObservedObject private var monitor: RoomJobMonitor
    private let onOpenJob: (String) -> Void
    private let onOpenRequest: () -> Void

    public init(
        access: any RoomAccess,
        monitor: RoomJobMonitor,
        readStore: RoomJobReadStoring,
        onOpenJob: @escaping (String) -> Void = { _ in },
        onOpenRequest: @escaping () -> Void = {}
    ) {
        _model = StateObject(
            wrappedValue: RoomJobListViewModel(access: access, monitor: monitor, readStore: readStore)
        )
        _monitor = ObservedObject(wrappedValue: monitor)
        self.onOpenJob = onOpenJob
        self.onOpenRequest = onOpenRequest
    }

    /// テストから状態を差し込むための入り口。
    init(
        model: RoomJobListViewModel,
        monitor: RoomJobMonitor,
        onOpenJob: @escaping (String) -> Void = { _ in },
        onOpenRequest: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: model)
        _monitor = ObservedObject(wrappedValue: monitor)
        self.onOpenJob = onOpenJob
        self.onOpenRequest = onOpenRequest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("仕事を検索", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button("更新する") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading)
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.filteredItems) { item in
                        row(item)
                    }
                }
            }
            HStack {
                Button("新しい仕事を頼む…") {
                    onOpenRequest()
                }
                Spacer()
                Text("\(model.filteredItems.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.unreadCount > 0 {
                    Text("未読完了 \(model.unreadCount)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 380)
        .task {
            await model.load()
        }
        .onChange(of: monitor.jobs) { _, jobs in
            model.merge(monitorJobs: jobs)
        }
    }

    private func row(_ item: RoomJobListItem) -> some View {
        Button {
            model.select(item.jobID)
            onOpenJob(item.jobID)
        } label: {
            HStack(spacing: 8) {
                Text(item.status.label)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.status.tintColor.opacity(0.18))
                    .foregroundStyle(item.status.tintColor)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let latest = item.latestText, !latest.isEmpty {
                        Text(latest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if item.artifactCount > 0 {
                    Text("成果物 \(item.artifactCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if item.unread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(
                item.jobID == model.selectedJobID
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
