import SwiftUI

/// 依頼窓の中身。タイトルは任意で、本文を書いて「頼む」を押す。
///
/// 走っている仕事への「追記」にも同じ窓を使う(タイトル欄を隠して「追記する」になる)。
public struct JobRequestView: View {
    @StateObject private var model: JobRequestViewModel

    /// 新しく仕事を頼む窓。
    public init(client: JobRequestClient, onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in }) {
        _model = StateObject(
            wrappedValue: JobRequestViewModel(client: client, onSubmitted: onSubmitted)
        )
    }

    /// すでに走っている仕事へ追記する窓。
    public init(followupClient: RoomEventClient, jobID: String) {
        _model = StateObject(
            wrappedValue: JobRequestViewModel(followupClient: followupClient, jobID: jobID)
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
                .frame(minHeight: 160)
                .border(Color.secondary.opacity(0.3))
            if !model.isFollowup {
                Toggle("一時デプロイ（外部公開）を許す", isOn: $model.allowExternalPublish)
                    .font(.caption)
                Text(
                    "付けると agent が cloudflare_temp_deploy（約 60 分の外部公開）を"
                        + "使えるようになる。普通の依頼では付けなくてよい"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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
        .frame(width: 440, height: 360)
    }
}

/// 依頼窓の状態。送信中は二重押しさせない。
@MainActor
public final class JobRequestViewModel: ObservableObject {
    @Published public var title = ""
    @Published public var body = ""
    /// 一時デプロイ（外部公開）を許すか。依頼ごとの明示許可。
    @Published public var allowExternalPublish = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var notice: String?
    @Published public private(set) var didSucceed = false

    private let submitClient: JobRequestClient?
    private let followupClient: RoomEventClient?
    private let followupJobID: String?
    private let onSubmitted: @MainActor (String, String) -> Void

    /// 新しく仕事を頼む。
    public init(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
        self.submitClient = client
        self.followupClient = nil
        self.followupJobID = nil
        self.onSubmitted = onSubmitted
    }

    /// 走っている仕事へ追記する。
    public init(followupClient: RoomEventClient, jobID: String) {
        self.submitClient = nil
        self.followupClient = followupClient
        self.followupJobID = jobID
        self.onSubmitted = { _, _ in }
    }

    /// 追記窓か。タイトル欄を隠し、ボタンの文言も変える。
    public var isFollowup: Bool {
        followupJobID != nil
    }

    /// メニューに出る追記先。無い(新規依頼)ときは空文字。
    public var followupLabel: String {
        followupJobID ?? ""
    }

    /// 本文が空のまま送らせない。タイトルは空でよい。
    public var canSubmit: Bool {
        !isSubmitting && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 部屋へ投げる。成功したら本文を空にして、もう 1 件頼めるようにする。
    public func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        notice = nil
        didSucceed = false
        defer { isSubmitting = false }
        do {
            if let followupJobID, let followupClient {
                _ = try await followupClient.followup(jobID: followupJobID, body: body)
                didSucceed = true
                notice = "追記したよ"
                body = ""
            } else if let submitClient {
                let response = try await submitClient.submit(
                    title: title,
                    body: body,
                    allowExternalPublish: allowExternalPublish
                )
                didSucceed = true
                if let jobID = response.jobID, !jobID.isEmpty {
                    notice = "頼んだよ(仕事 \(jobID))"
                    onSubmitted(jobID, Self.resolvedTitle(title: title, body: body))
                } else {
                    notice = "頼んだよ"
                }
                title = ""
                body = ""
                allowExternalPublish = false
            }
        } catch {
            didSucceed = false
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 送信した仕事のタイトル。`JobRequestClient.resolveTitle` と同じ決め方。
    private static func resolvedTitle(title: String, body: String) -> String {
        JobRequestClient.resolveTitle(title: title, body: body)
    }
}
