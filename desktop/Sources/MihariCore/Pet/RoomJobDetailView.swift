import SwiftUI

/// 仕事の詳細パネル。進捗・成果物と、承認待ちの記憶の候補を並べる。
///
/// 記憶の候補は本文そのままを見せ、承認・却下のボタンを持つ。決定は API が成功してから
/// 一覧を引き直すまで約束しない(成功前に「保存した」とは言わない)。
public struct RoomJobDetailView: View {
    @ObservedObject var monitor: RoomJobMonitor
    @StateObject private var model: RoomJobDetailViewModel
    private let onOpenArtifact: (URL) -> Void

    /// 画面から使う入り口。監視と操作口を差し込む。
    public init(
        monitor: RoomJobMonitor,
        jobID: String,
        onOpenArtifact: @escaping (URL) -> Void = { _ in }
    ) {
        self.monitor = monitor
        _model = StateObject(wrappedValue: RoomJobDetailViewModel(monitor: monitor, jobID: jobID))
        self.onOpenArtifact = onOpenArtifact
    }

    /// テストから状態を差し込むための入り口。
    init(monitor: RoomJobMonitor, model: RoomJobDetailViewModel, onOpenArtifact: @escaping (URL) -> Void = { _ in }) {
        self.monitor = monitor
        _model = StateObject(wrappedValue: model)
        self.onOpenArtifact = onOpenArtifact
    }

    /// いま見ている仕事。監視から外れたら `nil`（別の仕事には切り替えない）。
    private var tracked: RoomJobTrackedJob? {
        model.trackedJob
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = tracked {
                Text(job.title)
                    .font(.headline)
                Text("状態: \(job.status.label)\(phaseSuffix(job))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let latest = job.latestText, !latest.isEmpty {
                    Text("進捗: \(latest)")
                        .font(.body)
                }
                if let error = job.lastError {
                    Text("配信エラー: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let opError = job.operationError {
                    Text("操作エラー: \(opError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Divider()
                memorySection(job)
                Divider()
                artifactSection(job)
                tempDeploySection(job)
                Divider()
                commentSection(job)
            } else {
                Text("仕事を追っていない")
                    .font(.headline)
                Text("依頼窓から頼むか、再起動後に拾い直すまで待ってね")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(model.didFail ? .red : .green)
            }
            HStack {
                Spacer()
                Button("更新する") {
                    Task { await model.refresh() }
                }
                .disabled(model.isRefreshing)
            }
        }
        .padding()
        .frame(width: 480, height: 640)
        .task {
            await model.refresh()
        }
    }

    private func phaseSuffix(_ job: RoomJobTrackedJob) -> String {
        guard let phase = job.phase else { return "" }
        return " ・ \(phase.label)"
    }

    @ViewBuilder
    private func memorySection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("記憶の候補(\(job.pendingMemoryCount)件待ち)")
                .font(.headline)
            if let error = job.memoryError {
                Text("記憶の一覧エラー: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            let pending = job.memories.filter(\.isPending)
            if pending.isEmpty {
                Text("承認待ちなし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pending) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.target.isEmpty ? "記憶" : candidate.target)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(candidate.content)
                            .font(.body)
                            .textSelection(.enabled)
                        HStack {
                            Spacer()
                            if model.busyIDs.contains(candidate.candidateID) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("承認する") {
                                Task { await model.approve(candidateID: candidate.candidateID) }
                            }
                            .disabled(model.busyIDs.contains(candidate.candidateID))
                            Button("却下する") {
                                Task { await model.reject(candidateID: candidate.candidateID) }
                            }
                            .disabled(model.busyIDs.contains(candidate.candidateID))
                        }
                    }
                    .padding(8)
                    .border(Color.secondary.opacity(0.3))
                }
            }
            let decided = job.memories.filter { !$0.isPending }
            if !decided.isEmpty {
                Text("決定済み \(decided.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func artifactSection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("成果物")
                .font(.headline)
            let openable = job.artifacts.filter {
                guard let scheme = $0.previewURL?.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
            if openable.isEmpty {
                Text("成果物なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(openable) { artifact in
                    HStack {
                        Text(artifactLabel(artifact))
                            .font(.body)
                        Spacer()
                        if let url = artifact.previewURL {
                            Button("開く") { onOpenArtifact(url) }
                        }
                        if let version = artifact.version, !version.isEmpty {
                            Button("これに戻す") {
                                Task { await model.rollback(version: version) }
                            }
                            .disabled(model.isRollingBack)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tempDeploySection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一時デプロイ")
                .font(.headline)
            if job.tempDeploys.isEmpty {
                Text("なし（Worker/DB 付きの確認用）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(job.tempDeploys) { deploy in
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = deploy.previewURL {
                            HStack {
                                Text(url.host ?? "workers.dev")
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                Button("開く") { onOpenArtifact(url) }
                            }
                        }
                        if let claim = deploy.claimURL {
                            Button("アカウントを引き継ぐ") { onOpenArtifact(claim) }
                        }
                        Text("claim はあなただけ。Forum には出していないよ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commentSection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("指摘して直す")
                .font(.headline)
            TextEditor(text: $model.comment)
                .frame(minHeight: 72)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("指摘を送る") {
                    Task { await model.submitComment(previewURL: latestPreviewURL(job)) }
                }
                .disabled(!model.canSubmitComment)
            }
        }
    }

    private func artifactLabel(_ artifact: RoomArtifact) -> String {
        if let version = artifact.version, !version.isEmpty {
            return "v\(version)"
        }
        if let kind = artifact.kind, !kind.isEmpty {
            return kind
        }
        return "成果物"
    }

    private func latestPreviewURL(_ job: RoomJobTrackedJob) -> URL? {
        job.artifacts.last(where: { artifact in
            let scheme = artifact.previewURL?.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        })?.previewURL
    }
}

/// 詳細パネルの状態。承認・却下の二重押しを抑え、失敗だけを知らせる。
@MainActor
public final class RoomJobDetailViewModel: ObservableObject {
    /// 見ている仕事の ID。
    public let jobID: String
    @Published public private(set) var notice: String?
    @Published public private(set) var didFail = false
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public private(set) var isRefreshing = false
    @Published public var comment = ""
    @Published public private(set) var isRollingBack = false
    @Published public private(set) var isSubmittingComment = false

    private let monitor: RoomJobMonitor

    public init(monitor: RoomJobMonitor, jobID: String) {
        self.monitor = monitor
        self.jobID = jobID
    }

    /// いま見ている仕事。監視から外れたら `nil`。対象が消えたら別の仕事を
    /// 代わりに見せない。
    public var trackedJob: RoomJobTrackedJob? {
        monitor.jobs.first { $0.jobID == jobID }
    }

    /// 状態・成果物・記憶の候補をまとめて引き直す。詳細の状態を正とする。
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await monitor.refreshArtifacts(jobID: jobID)
    }

    /// 候補を承認する。API が成功するまで結果を約束しない。
    public func approve(candidateID: String) async {
        await decide(candidateID: candidateID, approved: true)
    }

    /// 候補を却下する。API が成功するまで結果を約束しない。
    public func reject(candidateID: String) async {
        await decide(candidateID: candidateID, approved: false)
    }

    /// 旧バージョンを新しい token として再公開する。
    public func rollback(version: String) async {
        guard !isRollingBack else { return }
        isRollingBack = true
        notice = nil
        didFail = false
        defer { isRollingBack = false }
        do {
            _ = try await monitor.rollbackArtifact(jobID: jobID, version: version)
            notice = "戻したよ（新しい URL を置いた）"
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var canSubmitComment: Bool {
        !isSubmittingComment
            && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 指摘を followup する。対象プレビュー URL があれば追記する。
    public func submitComment(previewURL: URL?) async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingComment else { return }
        isSubmittingComment = true
        notice = nil
        didFail = false
        defer { isSubmittingComment = false }
        var body = trimmed
        if let previewURL {
            body += "\n\n対象プレビュー: \(previewURL.absoluteString)"
        }
        do {
            _ = try await monitor.followup(jobID: jobID, body: body)
            comment = ""
            notice = "指摘を送ったよ"
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func decide(candidateID: String, approved: Bool) async {
        guard !busyIDs.contains(candidateID) else { return }
        busyIDs.insert(candidateID)
        notice = nil
        didFail = false
        defer { busyIDs.remove(candidateID) }
        do {
            if approved {
                try await monitor.approveMemory(jobID: jobID, candidateID: candidateID)
                notice = "承認したよ(一覧を引き直した)"
            } else {
                try await monitor.rejectMemory(jobID: jobID, candidateID: candidateID)
                notice = "却下したよ(一覧を引き直した)"
            }
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
