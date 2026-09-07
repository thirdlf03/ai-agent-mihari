import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 入力例の種類。押すと本文にサンプルを入れる。
public enum JobRequestExample: String, CaseIterable, Sendable, Identifiable {
    case research
    case summarize
    case build
    case lookAtScreen

    public var id: String { rawValue }

    /// ボタンの見出し。
    public var title: String {
        switch self {
        case .research: return "調べる"
        case .summarize: return "まとめる"
        case .build: return "作る"
        case .lookAtScreen: return "画面を見て"
        }
    }

    /// 本文へ入れるサンプル文。実際の依頼はここから書き換えてもらう。
    public var prompt: String {
        switch self {
        case .research:
            return "調べてほしいことを書いて。\n例: 〇〇の最新情報を調べて"
        case .summarize:
            return "まとめてほしいことを書いて。\n例: この資料を要点つきでまとめて"
        case .build:
            return "作ってほしいものを書いて。\n例: 〇〇の Web ページを作って"
        case .lookAtScreen:
            return "画面を見てほしいことを書いて。\n例: いまの画面を確認して次にやることを教えて"
        }
    }
}

/// 依頼窓の中身。主入力は「何をしてほしい？」。タイトルは本文から自動生成しつつ任意編集できる。
///
/// 走っている仕事への「追記」にも同じ窓を使う(タイトル欄を隠して「追記する」になる)。
/// 添付は送信前のプレビューと削除ができ、上限・形式は追加時に検証する。本文・添付・設定は
/// 下書きとしてローカル保存し、失敗時は保持、成功時は消して当該ジョブの詳細を開く。
/// ディスプレイ・ウィンドウを選んでスクショを撮り、添付確認・削除を経て送る（#22）。
/// スクショはバイト列（base64）で部屋へ送られ、成果物の公開対象にはならない。
public struct JobRequestView: View {
    @StateObject private var model: JobRequestViewModel
    @State private var showFileImporter = false

    /// 新しく仕事を頼む窓。
    public init(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in },
        draftStore: (any JobRequestDraftStoring)? = DiskJobRequestDraftStore(),
        listTargets: @escaping @Sendable () async throws -> [ScreenshotTarget] = {
            try await ScreenshotCaptureService.availableTargets()
        },
        capture: @escaping @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture = {
            try await ScreenshotCaptureService.capturePNG(of: $0)
        }
    ) {
        _model = StateObject(
            wrappedValue: JobRequestViewModel(
                client: client,
                onSubmitted: onSubmitted,
                draftStore: draftStore,
                listTargets: listTargets,
                capture: capture
            )
        )
    }

    /// すでに走っている仕事へ追記する窓。
    public init(
        followupClient: RoomEventClient,
        jobID: String,
        listTargets: @escaping @Sendable () async throws -> [ScreenshotTarget] = {
            try await ScreenshotCaptureService.availableTargets()
        },
        capture: @escaping @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture = {
            try await ScreenshotCaptureService.capturePNG(of: $0)
        }
    ) {
        _model = StateObject(
            wrappedValue: JobRequestViewModel(
                followupClient: followupClient,
                jobID: jobID,
                listTargets: listTargets,
                capture: capture
            )
        )
    }

    /// テストから状態を差し込むための入り口。
    init(model: JobRequestViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.isFollowup {
                    Text("追記する(仕事 \(model.followupLabel))")
                        .font(.headline)
                    Text("追記の内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: bodyBinding)
                        .frame(minHeight: 160)
                        .border(Color.secondary.opacity(0.3))
                } else {
                    newJobInput
                }
                screenshotSection
                if let notice = model.notice {
                    Text(notice)
                        .foregroundStyle(model.didSucceed ? .green : .red)
                }
                HStack {
                    Spacer()
                    if model.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(model.isFollowup ? "追記する" : "頼む") {
                        Task {
                            await model.submit()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    /// 新規依頼の入力。主入力・入力例・タイトル・添付の順。
    @ViewBuilder
    private var newJobInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 主入力「何をしてほしい？」
            ZStack(alignment: .topLeading) {
                if model.body.isEmpty {
                    Text("何をしてほしい？")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: bodyBinding)
                    .frame(minHeight: 130)
                    .border(Color.secondary.opacity(0.3))
            }
            // 入力例
            HStack(spacing: 8) {
                Text("例:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(JobRequestExample.allCases) { example in
                    Button(example.title) {
                        model.applyExample(example)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            // タイトル（自動生成・任意編集）
            HStack(spacing: 8) {
                TextField("タイトル(空なら本文から自動)", text: titleBinding)
                    .textFieldStyle(.roundedBorder)
                Button(model.autoTitle ? "自動" : "自動にする") {
                    model.enableAutoTitle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            if model.supportsAttachments {
                attachmentsSection
            }
        }
    }

    /// スクショの添付欄。撮影対象を選ぶメニューと、撮った分の確認・削除。
    @ViewBuilder
    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("スクショ")
                    .font(.headline)
                Spacer()
                if model.isLoadingTargets {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    if model.screenshotTargets.isEmpty {
                        Text("対象が見つからない")
                    } else {
                        ForEach(model.screenshotTargets) { target in
                            Button(target.title) {
                                Task {
                                    await model.captureScreenshot(target: target)
                                }
                            }
                        }
                    }
                } label: {
                    Label("スクショを撮る", systemImage: "camera.viewfinder")
                }
                .disabled(model.isLoadingTargets || model.isCapturingScreenshot)
            }

            if model.isCapturingScreenshot {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("撮影中…")
                        .font(.caption)
                }
            }

            if let message = model.captureErrorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if model.messageMentionsPermission {
                        Button("画面収録の設定を開く") {
                            PrivacyPane.screenCapture.open()
                        }
                        .font(.caption)
                    }
                }
            }

            if !model.screenshots.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.screenshots) { shot in
                            VStack(spacing: 2) {
                                Image(nsImage: NSImage(data: shot.pngData) ?? NSImage())
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 96, height: 60)
                                    .background(Color.black.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(shot.sourceTitle)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Button("削除") {
                                    model.removeScreenshot(shot)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            .frame(width: 108)
                        }
                    }
                }
            }
        }
        .task {
            await model.loadScreenshotTargets()
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("添付(\(model.attachments.count)/\(JobAttachmentLimit.maxCount))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("ファイルを選ぶ…") {
                    showFileImporter = true
                }
                .font(.caption)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                add(urls: urls)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                // ドラッグ＆ドロップ。各プロバイダから非同期に URL を取り出し、添付に足す。
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            Task { @MainActor in
                                await self.model.addAttachment(at: url)
                            }
                        }
                    }
                }
                return true
            }
            if let error = model.attachmentError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: attachment))
                        .foregroundStyle(.secondary)
                    Text(attachment.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.formattedSize(attachment.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("削除") {
                        model.removeAttachment(at: index)
                    }
                    .font(.caption)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func add(urls: [URL]) {
        Task {
            for url in urls {
                await model.addAttachment(at: url)
            }
        }
    }

    /// 添付で選べる形式。追加時の検証は `JobAttachmentLimit` 側でも行う。
    private var allowedContentTypes: [UTType] {
        ["png", "jpg", "jpeg", "pdf", "md", "markdown", "txt"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    private func iconName(for attachment: JobAttachment) -> String {
        switch attachment.fileExtension {
        case "png", "jpg", "jpeg": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.plaintext"
        case "txt": return "doc.text"
        default: return "paperclip"
        }
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var titleBinding: Binding<String> {
        Binding(get: { model.title }, set: { model.setTitle($0) })
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { model.body }, set: { model.setBody($0) })
    }
}

/// 依頼窓の状態。送信中は二重押しさせない。下書きはローカルに保持する。
@MainActor
public final class JobRequestViewModel: ObservableObject {
    @Published public var title = ""
    @Published public var body = ""
    /// タイトルを本文から自動で作り続けるか。手入力で off になる。
    @Published public var autoTitle = true
    @Published public private(set) var attachments: [JobAttachment] = []
    @Published public private(set) var attachmentError: String?
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var notice: String?
    @Published public private(set) var didSucceed = false
    /// 部屋が添付に対応しているか。旧バックエンドでは添付 UI を出さない。
    @Published public private(set) var supportsAttachments = true

    // スクショ（#22）
    @Published public private(set) var screenshots: [ScreenshotAttachment] = []
    @Published public private(set) var screenshotTargets: [ScreenshotTarget] = []
    @Published public private(set) var isLoadingTargets = false
    @Published public private(set) var isCapturingScreenshot = false
    @Published public var captureErrorMessage: String?

    private let submitClient: JobRequestClient?
    private let followupClient: RoomEventClient?
    private let followupJobID: String?
    private let draftStore: (any JobRequestDraftStoring)?
    private let onSubmitted: @MainActor (String, String) -> Void
    private let listTargets: @Sendable () async throws -> [ScreenshotTarget]
    private let capture: @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture
    /// 添付それぞれの元パス。下書きの復元に使う（in-memory の添付は nil）。
    private var attachmentPaths: [URL?] = []

    /// 新しく仕事を頼む。下書きを復元し、部屋の対応機能を確認する。
    public init(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in },
        draftStore: (any JobRequestDraftStoring)? = nil,
        listTargets: @escaping @Sendable () async throws -> [ScreenshotTarget] = {
            try await ScreenshotCaptureService.availableTargets()
        },
        capture: @escaping @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture = {
            try await ScreenshotCaptureService.capturePNG(of: $0)
        }
    ) {
        self.submitClient = client
        self.followupClient = nil
        self.followupJobID = nil
        self.draftStore = draftStore
        self.onSubmitted = onSubmitted
        self.listTargets = listTargets
        self.capture = capture
        restoreDraft()
        refreshCapabilities()
    }

    /// 走っている仕事へ追記する。ファイル添付は追記側（別 Issue）の責務なのでここでは扱わない。
    /// スクショは追記でも撮って送れる（#22）。
    public init(
        followupClient: RoomEventClient,
        jobID: String,
        listTargets: @escaping @Sendable () async throws -> [ScreenshotTarget] = {
            try await ScreenshotCaptureService.availableTargets()
        },
        capture: @escaping @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture = {
            try await ScreenshotCaptureService.capturePNG(of: $0)
        }
    ) {
        self.submitClient = nil
        self.followupClient = followupClient
        self.followupJobID = jobID
        self.draftStore = nil
        self.onSubmitted = { _, _ in }
        self.listTargets = listTargets
        self.capture = capture
    }

    /// 追記窓か。タイトル欄を隠し、ボタンの文言も変える。
    public var isFollowup: Bool {
        followupJobID != nil
    }

    /// メニューに出る追記先。無い(新規依頼)ときは空文字。
    public var followupLabel: String {
        followupJobID ?? ""
    }

    /// 本文が空のまま送らせない。タイトルは空でよい。スクショだけでは送らせない。
    public var canSubmit: Bool {
        !isSubmitting && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// エラー文言が権限まわりかを示す。設定を開くボタンの表示条件。
    public var messageMentionsPermission: Bool {
        (captureErrorMessage ?? "").contains("権限")
    }

    /// 撮影対象の一覧を読み込む。権限が無ければ理由を表示するだけ。
    public func loadScreenshotTargets() async {
        guard !isLoadingTargets, screenshotTargets.isEmpty else { return }
        isLoadingTargets = true
        defer { isLoadingTargets = false }
        do {
            screenshotTargets = try await listTargets()
            captureErrorMessage = nil
        } catch {
            captureErrorMessage =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 選んだ対象を 1 枚撮ってスクショへ足す。失敗は落とさず理由を表示する。
    public func captureScreenshot(target: ScreenshotTarget) async {
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        captureErrorMessage = nil
        defer { isCapturingScreenshot = false }
        do {
            let shot = try await capture(target)
            screenshots.append(ScreenshotAttachment(capture: shot))
        } catch {
            captureErrorMessage =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// スクショを外す。送信前なら何度でも戻せる。
    public func removeScreenshot(_ screenshot: ScreenshotAttachment) {
        screenshots.removeAll { $0.id == screenshot.id }
    }

    // MARK: - 入力の更新

    /// 本文を更新する。自動タイトルが有効なら先頭行でタイトルも追従する。
    public func setBody(_ value: String) {
        body = value
        if autoTitle && !isFollowup {
            title = JobRequestClient.resolveTitle(title: "", body: value)
        }
        persistDraft()
    }

    /// タイトルを手入力で更新する。手入力したら自動生成は止める。
    public func setTitle(_ value: String) {
        title = value
        if !isFollowup {
            autoTitle = false
        }
        persistDraft()
    }

    /// 自動タイトルを再度有効にする。本文の先頭行から作り直す。
    public func enableAutoTitle() {
        autoTitle = true
        if !isFollowup {
            title = JobRequestClient.resolveTitle(title: "", body: body)
        }
        persistDraft()
    }

    /// 入力例を本文に入れ、タイトルを自動生成に戻す。
    public func applyExample(_ example: JobRequestExample) {
        guard !isFollowup else { return }
        body = example.prompt
        autoTitle = true
        title = JobRequestClient.resolveTitle(title: "", body: body)
        persistDraft()
    }

    // MARK: - 添付

    /// ファイルを添付する。上限・形式に反すれば拒否して理由を出す。
    public func addAttachment(at url: URL) async {
        attachmentError = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "\(url.lastPathComponent) を読めなかったよ"
            return
        }
        let attachment = JobAttachment(fileName: url.lastPathComponent, data: data)
        let proposed = attachments + [attachment]
        if let error = JobAttachmentLimit.validate(proposed) {
            attachmentError = error.errorDescription
            return
        }
        attachments = proposed
        attachmentPaths.append(url)
        persistDraft()
    }

    /// データだけの添付（テスト・ドラッグ直）。元パスが無いので下書き復元には残らない。
    public func addAttachment(_ attachment: JobAttachment) {
        attachmentError = nil
        let proposed = attachments + [attachment]
        if let error = JobAttachmentLimit.validate(proposed) {
            attachmentError = error.errorDescription
            return
        }
        attachments = proposed
        attachmentPaths.append(nil)
        persistDraft()
    }

    /// 添付を取り除く。
    public func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        if attachmentPaths.indices.contains(index) {
            attachmentPaths.remove(at: index)
        }
        attachmentError = nil
        persistDraft()
    }

    // MARK: - 送信

    /// 部屋へ投げる。成功したら下書きを消して、もう 1 件頼めるようにする。
    /// 失敗したら下書きは保持する。二重押しは `isSubmitting` で防ぐ。
    /// 送信に失敗したときはスクショも残す（撮り直させない）。
    public func submit() async {
        guard canSubmit else { return }
        if !isFollowup, let error = JobAttachmentLimit.validate(attachments) {
            notice = error.errorDescription
            didSucceed = false
            persistDraft()
            return
        }
        isSubmitting = true
        notice = nil
        didSucceed = false
        defer { isSubmitting = false }
        let payloads = screenshots.map { ScreenshotUploadPayload(attachment: $0) }
        do {
            if let followupJobID, let followupClient {
                _ = try await followupClient.followup(
                    jobID: followupJobID,
                    body: body,
                    screenshots: payloads
                )
                didSucceed = true
                notice =
                    payloads.isEmpty
                    ? "追記したよ"
                    : "追記したよ(スクショ \(payloads.count) 枚)"
                resetAfterSubmit(clearDraft: false)
            } else if let submitClient {
                let response = try await submitClient.submit(
                    title: title,
                    body: body,
                    screenshots: payloads,
                    attachments: attachments
                )
                didSucceed = true
                if let jobID = response.jobID, !jobID.isEmpty {
                    notice =
                        payloads.isEmpty
                        ? "頼んだよ(仕事 \(jobID))"
                        : "頼んだよ(仕事 \(jobID)、スクショ \(payloads.count) 枚)"
                    onSubmitted(jobID, Self.resolvedTitle(title: title, body: body))
                } else {
                    notice =
                        payloads.isEmpty ? "頼んだよ" : "頼んだよ(スクショ \(payloads.count) 枚)"
                }
                resetAfterSubmit(clearDraft: true)
            }
        } catch {
            didSucceed = false
            // 送信に失敗したときは添付を残す（本文も残る）。撮り直させない。
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // 失敗時は下書きを保持して、次に開き直しても続きから書けるようにする。
            persistDraft()
        }
    }

    private func resetAfterSubmit(clearDraft: Bool) {
        title = ""
        body = ""
        attachments = []
        attachmentPaths = []
        screenshots = []
        if clearDraft {
            draftStore?.clear()
        } else {
            persistDraft()
        }
    }

    /// 送信した仕事のタイトル。`JobRequestClient.resolveTitle` と同じ決め方。
    private static func resolvedTitle(title: String, body: String) -> String {
        JobRequestClient.resolveTitle(title: title, body: body)
    }

    // MARK: - 下書き

    /// 起動時に下書きを復元する。本文・タイトル・添付（元ファイルがあれば）を戻す。
    private func restoreDraft() {
        guard let draftStore else { return }
        guard let draft = try? draftStore.load() else { return }
        body = draft.body
        title = draft.title
        autoTitle = draft.autoTitle
        attachments = draft.attachments.compactMap { item in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.storedPath)) else {
                return nil
            }
            return JobAttachment(fileName: item.fileName, data: data)
        }
        attachmentPaths = draft.attachments.map { item in
            URL(fileURLWithPath: item.storedPath)
        }
        // 設定は今のところ自動タイトルのみ。
        if let raw = draft.settings["autoTitle"] {
            autoTitle = raw != "false"
        }
    }

    private func persistDraft() {
        guard let draftStore, !isFollowup else { return }
        let draft = JobRequestDraft(
            body: body,
            title: title,
            autoTitle: autoTitle,
            attachments: zip(attachments, attachmentPaths).compactMap { attachment, path in
                guard let path else { return nil }
                return DraftAttachment(
                    fileName: attachment.fileName,
                    storedPath: path.path,
                    size: attachment.size,
                    fileExtension: attachment.fileExtension ?? ""
                )
            },
            settings: ["autoTitle": autoTitle ? "true" : "false"]
        )
        try? draftStore.save(draft)
    }

    private func refreshCapabilities() {
        guard let submitClient, !isFollowup else { return }
        Task { [weak self] in
            let caps = await submitClient.fetchCapabilities()
            guard let self, !self.isFollowup else { return }
            self.supportsAttachments = caps?.supportsAttachments ?? false
        }
    }
}
