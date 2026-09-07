import AppKit
import SwiftUI

/// 仕事の詳細パネル。状態と最終結果 → 成果物（版ごとの公開/非公開） → 修正入力 → 折りたたんだ履歴・記憶の順に並べる。
///
/// 成果物の版ごとに:
/// - 公開中は共有 URL を開く / コピーし、「非公開に戻す」で発行済み URL を無効化できる
/// - 非公開は認証付きのアプリ内プレビュー（Room トークンはヘッダだけ）で見られる
/// - 「この版を再公開」は旧版の内容を新しい非公開バージョンとして載せ直す（rollback の改称）
/// - 「この版から修正」は作業ファイルを復元してから指摘の実行に使う（実行中は復元不可）
/// - 版に含まれる Markdown / PDF は文書行として並べ、公開中はプレビュー・ダウンロードできる
///
/// 開いたときに固定した仕事（`jobID`）を最後まで見る。別ジョブの進捗で表示が切り替わらない。
/// 長文・多数の成果物でも操作不能にならないよう、全体をスクロールできる可変サイズにする。
public struct RoomJobDetailView: View {
    @ObservedObject var monitor: RoomJobMonitor
    @StateObject private var model: RoomJobDetailViewModel
    private let onOpenArtifact: (URL) -> Void
    private let onPreviewAuthenticated: (String, String) -> Void

    /// 画面から使う入り口。監視と操作口を差し込む。
    public init(
        monitor: RoomJobMonitor,
        jobID: String,
        onOpenArtifact: @escaping (URL) -> Void = { _ in },
        onPreviewAuthenticated: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.monitor = monitor
        _model = StateObject(wrappedValue: RoomJobDetailViewModel(monitor: monitor, jobID: jobID))
        self.onOpenArtifact = onOpenArtifact
        self.onPreviewAuthenticated = onPreviewAuthenticated
    }

    /// テストから状態を差し込むための入り口。
    init(
        monitor: RoomJobMonitor,
        model: RoomJobDetailViewModel,
        onOpenArtifact: @escaping (URL) -> Void = { _ in },
        onPreviewAuthenticated: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.monitor = monitor
        _model = StateObject(wrappedValue: model)
        self.onOpenArtifact = onOpenArtifact
        self.onPreviewAuthenticated = onPreviewAuthenticated
    }

    /// いま見ている仕事。監視から外れたら `nil`（別の仕事には切り替えない）。
    private var tracked: RoomJobTrackedJob? {
        model.trackedJob
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
                if let opError = tracked?.operationError {
                    Text("操作エラー: \(opError)")
                        .font(.caption)
                        .foregroundStyle(.red)
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
            Text("成果物（版ごとの公開・非公開）")
                .font(.headline)
            // 若い版を上に（最新が先頭）。
            let artifacts = job.artifacts.sorted { ($0.version ?? "") > ($1.version ?? "") }
            if artifacts.isEmpty {
                Text("成果物なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(artifacts, id: \.id) { artifact in
                    artifactRow(artifact, jobID: model.jobID)
                }
            }
        }
    }

    @ViewBuilder
    private func artifactRow(_ artifact: RoomArtifact, jobID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(artifactLabel(artifact))
                    .font(.body)
                    .bold()
                Text(artifact.isPublic ? "公開中" : "非公開")
                    .font(.caption)
                    .foregroundStyle(artifact.isPublic ? Color.green : Color.secondary)
                Spacer()
                if artifact.isPublic, let url = artifact.previewURL {
                    Button("開く") { onOpenArtifact(url) }
                    Button("URL をコピー") { copySharedURL(url) }
                } else if let version = artifact.version {
                    Button("プレビュー") {
                        onPreviewAuthenticated(jobID, version)
                    }
                }
            }
            if let version = artifact.version, !version.isEmpty {
                HStack {
                    Button("この版を再公開") {
                        Task { await model.republish(version: version) }
                    }
                    .disabled(model.isArtifactBusy)
                    if artifact.isPublic {
                        Button("非公開に戻す") {
                            Task { await model.unpublish(version: version) }
                        }
                        .disabled(model.isArtifactBusy)
                    } else {
                        Button("公開する") {
                            Task { await model.publish(version: version) }
                        }
                        .disabled(model.isArtifactBusy)
                    }
                    Spacer()
                    let pinned = model.selectedFixVersion == version
                    Button(pinned ? "修正対象（解除）" : "この版から修正") {
                        model.toggleFixSelection(version: version)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                if model.selectedFixVersion == version {
                    Text("指摘の修正対象は v\(version) に固定。送ると作業ファイルを復元してから実行する")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            documentSection(artifact)
        }
        .padding(6)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    /// 成果物の版に含まれる文書（Markdown / PDF）の行。
    /// 公開中は共有 URL でプレビュー・ダウンロード、非公開は版の認証付きプレビューで見る。
    @ViewBuilder
    private func documentSection(_ artifact: RoomArtifact) -> some View {
        if artifact.documents.isEmpty {
            EmptyView()
        } else {
            ForEach(artifact.documents) { document in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.name)
                            .font(.body)
                        Text(document.kindLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if artifact.isPublic {
                        if let preview = document.previewURL {
                            Button("プレビュー") { onOpenArtifact(preview) }
                        }
                        if let download = document.downloadURL {
                            Button("ダウンロード") { onOpenArtifact(download) }
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private func tempDeploySection(_ job: RoomJobTrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一時デプロイ（外部公開）")
                .font(.headline)
            if job.tempDeploys.isEmpty {
                Text("なし（Worker/DB 付きの確認用・依頼時に許可した仕事だけ）")
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
            if let pinned = model.selectedFixVersion {
                Text("修正対象: v\(pinned)（送ると作業ファイルを復元してから実行する）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.status == .running {
                    Text("実行中は復元できない。終わってから送ってね")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            TextEditor(text: $model.comment)
                .frame(minHeight: 72)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                if model.isSubmittingComment {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(model.selectedFixVersion == nil ? "指摘を送る" : "この版から修正して") {
                    Task { await model.submitComment() }
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

    private func copySharedURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// 詳細パネルの状態。承認・却下・公開切替の二重押しを抑え、失敗だけを知らせる。
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
    @Published public private(set) var isArtifactBusy = false
    /// 指摘の修正対象として固定した版。無ければ `nil`（通常の追記になる）。
    @Published public private(set) var selectedFixVersion: String?

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

    /// 旧バージョンを新しい非公開バージョンとして再公開する。
    /// 公開状態は引き継がないので、URL を出したければ別に「公開する」を押す。
    public func republish(version: String) async {
        guard !isArtifactBusy, !isRollingBack else { return }
        isArtifactBusy = true
        isRollingBack = true
        notice = nil
        didFail = false
        defer {
            isArtifactBusy = false
            isRollingBack = false
        }
        do {
            _ = try await monitor.rollbackArtifact(jobID: jobID, version: version)
            notice = "v\(version) を再公開したよ（新しい非公開の版を置いた）"
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 版を公開し共有 URL を発行する。
    public func publish(version: String) async {
        guard !isArtifactBusy else { return }
        isArtifactBusy = true
        notice = nil
        didFail = false
        defer { isArtifactBusy = false }
        do {
            let manifest = try await monitor.publishArtifact(jobID: jobID, version: version)
            if let url = manifest.previewURL {
                notice = "公開したよ: \(url.absoluteString)"
            } else {
                notice = "公開したよ（URL は更新後に表示）"
            }
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 版を非公開に戻す（その版の発行済み URL を無効化）。
    public func unpublish(version: String) async {
        guard !isArtifactBusy else { return }
        isArtifactBusy = true
        notice = nil
        didFail = false
        defer { isArtifactBusy = false }
        do {
            _ = try await monitor.unpublishArtifact(jobID: jobID, version: version)
            notice = "v\(version) の公開を止めたよ（古い URL は無効にした）"
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 「この版から修正」の対象を選ぶ / 解除する。
    public func toggleFixSelection(version: String) {
        if selectedFixVersion == version {
            selectedFixVersion = nil
        } else {
            selectedFixVersion = version
        }
    }

    /// 指摘を followup する。修正対象が固定されていれば、その版の作業ファイルを
    /// 復元してから実行する（実行中の復元は部屋が 409 で断る＝送らせない）。
    public var canSubmitComment: Bool {
        guard !isSubmittingComment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        if selectedFixVersion != nil, trackedJob?.status == .running {
            return false
        }
        return true
    }

    /// 指摘を送る。修正対象があれば復元 → 追記の順。
    public func submitComment() async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingComment else { return }
        // 実行中の復元は不可（部屋も 409 で断る）。ボタンとここで二重に塞ぐ。
        if selectedFixVersion != nil, trackedJob?.status == .running {
            notice = "実行中は復元できない。終わってから送ってね"
            didFail = true
            return
        }
        isSubmittingComment = true
        notice = nil
        didFail = false
        defer { isSubmittingComment = false }
        do {
            var body = trimmed
            if let pinned = selectedFixVersion {
                // 実行中は canSubmitComment が塞いでいる。復元が済んでから追記して実行する。
                try await monitor.restoreArtifact(jobID: jobID, version: pinned)
                body +=
                    "\n\n修正対象: v\(pinned) の内容。この版の作業ファイルを復元してあるので、それに沿って修正して。"
            } else if let url = latestPublicPreviewURL() {
                body += "\n\n対象プレビュー: \(url.absoluteString)"
            }
            _ = try await monitor.followup(jobID: jobID, body: body)
            comment = ""
            selectedFixVersion = nil
            notice = "指摘を送ったよ（修正対象の版から直す）"
        } catch {
            didFail = true
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 最新の公開中の共有 URL（無ければ nil）。修正対象を固定しない追記の目印に使う。
    private func latestPublicPreviewURL() -> URL? {
        guard let job = trackedJob else { return nil }
        return job.artifacts.last { artifact in
            artifact.isPublic && artifact.previewURL != nil
        }?.previewURL
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
