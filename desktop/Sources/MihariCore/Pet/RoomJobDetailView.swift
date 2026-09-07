import SwiftUI

/// 仕事の詳細パネル。状態と最終結果 → 成果物 → 修正入力 → 折りたたんだ履歴・記憶の順に並べる。
///
/// 開いたときに固定した仕事（`jobID`）を最後まで見る。別ジョブの進捗で表示が切り替わらない。
/// 長文・多数の成果物でも操作不能にならないよう、全体をスクロールできる可変サイズにする。
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

    /// 固定した仕事だけを見る。消えても別ジョブへ表示を切り替えない。
    private var tracked: RoomJobTrackedJob? {
        monitor.jobs.first { $0.jobID == model.jobID }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let job = tracked {
                    statusSection(job)
                    Divider()
                    artifactSection(job)
                    tempDeploySection(job)
                    Divider()
                    commentSection(job)
                    Divider()
                    historySection(job)
                    memorySection(job)
                } else {
                    Text("仕事を追っていない")
                        .font(.headline)
                    Text("一覧から選ぶか、依頼窓から頼むとここに表示されるよ")
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
        }
        .frame(minWidth: 400, minHeight: 420)
        .task {
            await model.refresh()
        }
    }

    // MARK: - 状態と最終結果

    @ViewBuilder
    private func statusSection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title)
                .font(.headline)
            Text("状態: \(job.status.label)\(phaseSuffix(job))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let latest = job.latestText, !latest.isEmpty {
                Text(latest)
                    .font(.body)
                    .textSelection(.enabled)
            }
            if let error = job.lastError {
                Text("配信エラー: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func phaseSuffix(_ job: RoomJobTrackedJob) -> String {
        guard let phase = job.phase else { return "" }
        return " ・ \(phase.label)"
    }

    // MARK: - 成果物

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

    // MARK: - 修正入力

    @ViewBuilder
    private func commentSection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修正を伝える")
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

    // MARK: - 折りたたみ（履歴・記憶）

    @ViewBuilder
    private func historySection(_ job: RoomJobTrackedJob) -> some View {
        DisclosureGroup {
            if job.history.isEmpty {
                Text("履歴なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(job.history.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.kind?.label ?? "出来事")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let phase = entry.phase {
                                Text(phase.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.text)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: {
            Text("履歴(\(job.history.count))")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func memorySection(_ job: RoomJobTrackedJob) -> some View {
        DisclosureGroup {
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
        } label: {
            Text("記憶(\(job.pendingMemoryCount)件待ち)")
                .font(.headline)
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
/// 固定した仕事（`jobID`）へ修正を送るので、別ジョブの進捗で対象は変わらない。
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

    /// 記憶の一覧を引き直す。詳細・候補イベント・決定後の更新口。
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await monitor.refreshMemory(jobID: jobID)
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

extension RoomEventKind {
    /// 履歴 1 件の見出し。
    var label: String {
        switch self {
        case .speech: return "発言"
        case .log: return "記録"
        case .summary: return "まとめ"
        case .file: return "成果物"
        case .cancelled: return "中断"
        case .memoryCandidate: return "記憶候補"
        case .tempDeploy: return "一時デプロイ"
        }
    }
}
