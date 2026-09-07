import AppKit
import SwiftUI

/// 依頼窓の中身。タイトルは任意で、本文を書いて「頼む」を押す。
///
/// 走っている仕事への「追記」にも同じ窓を使う(タイトル欄を隠して「追記する」になる)。
/// ディスプレイ・ウィンドウを選んでスクショを撮り、添付確認・削除を経て送る（#22）。
/// スクショはバイト列（base64）で部屋へ送られ、成果物の公開対象にはならない。
public struct JobRequestView: View {
    @StateObject private var model: JobRequestViewModel

    /// 新しく仕事を頼む窓。
    public init(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in },
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
        VStack(alignment: .leading, spacing: 12) {
            if model.isFollowup {
                Text("追記する(仕事 \(model.followupLabel))")
                    .font(.headline)
            } else {
                // タイトルは任意。空なら本文の先頭行から作る。
                TextField("タイトル(空なら本文の先頭行から作る)", text: $model.title)
                    .textFieldStyle(.roundedBorder)
            }
            Text(model.isFollowup ? "追記の内容" : "ないよう")
                .font(.headline)
            TextEditor(text: $model.body)
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.3))

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
        .frame(width: 480, height: 460)
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

            if !model.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            VStack(spacing: 2) {
                                Image(nsImage: NSImage(data: attachment.pngData) ?? NSImage())
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 96, height: 60)
                                    .background(Color.black.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(attachment.sourceTitle)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Button("削除") {
                                    model.removeAttachment(attachment)
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
}

/// 依頼窓の状態。送信中は二重押しさせない。
@MainActor
public final class JobRequestViewModel: ObservableObject {
    @Published public var title = ""
    @Published public var body = ""
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var notice: String?
    @Published public private(set) var didSucceed = false

    // スクショ（#22）
    @Published public private(set) var attachments: [ScreenshotAttachment] = []
    @Published public private(set) var screenshotTargets: [ScreenshotTarget] = []
    @Published public private(set) var isLoadingTargets = false
    @Published public private(set) var isCapturingScreenshot = false
    @Published public var captureErrorMessage: String?

    private let submitClient: JobRequestClient?
    private let followupClient: RoomEventClient?
    private let followupJobID: String?
    private let onSubmitted: @MainActor (String, String) -> Void
    private let listTargets: @Sendable () async throws -> [ScreenshotTarget]
    private let capture: @Sendable (ScreenshotTarget) async throws -> ScreenshotCapture

    /// 新しく仕事を頼む。
    public init(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in },
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
        self.onSubmitted = onSubmitted
        self.listTargets = listTargets
        self.capture = capture
    }

    /// 走っている仕事へ追記する。
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

    /// 選んだ対象を 1 枚撮って添付へ足す。失敗は落とさず理由を表示する。
    public func captureScreenshot(target: ScreenshotTarget) async {
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        captureErrorMessage = nil
        defer { isCapturingScreenshot = false }
        do {
            let shot = try await capture(target)
            attachments.append(ScreenshotAttachment(capture: shot))
        } catch {
            captureErrorMessage =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 添付を外す。送信前なら何度でも戻せる。
    public func removeAttachment(_ attachment: ScreenshotAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// 部屋へ投げる。成功したら本文と添付を空にして、もう 1 件頼めるようにする。
    public func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        notice = nil
        didSucceed = false
        defer { isSubmitting = false }
        let payloads = attachments.map { ScreenshotUploadPayload(attachment: $0) }
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
                body = ""
                attachments = []
            } else if let submitClient {
                let response = try await submitClient.submit(
                    title: title,
                    body: body,
                    screenshots: payloads
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
                title = ""
                body = ""
                attachments = []
            }
        } catch {
            didSucceed = false
            // 送信に失敗したときは添付を残す（本文も残る）。撮り直させない。
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 送信した仕事のタイトル。`JobRequestClient.resolveTitle` と同じ決め方。
    private static func resolvedTitle(title: String, body: String) -> String {
        JobRequestClient.resolveTitle(title: title, body: body)
    }
}
