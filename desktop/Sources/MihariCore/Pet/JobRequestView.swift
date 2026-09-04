import SwiftUI

/// 依頼窓の中身。タイトルは任意で、本文を書いて「頼む」を押す。
public struct JobRequestView: View {
    @StateObject private var model: JobRequestViewModel

    public init(client: JobRequestClient) {
        _model = StateObject(wrappedValue: JobRequestViewModel(client: client))
    }

    /// テストから状態を差し込むための入り口。
    init(model: JobRequestViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // タイトルは任意。空なら本文の先頭行から作る。
            TextField("タイトル(空なら本文の先頭行から作る)", text: $model.title)
                .textFieldStyle(.roundedBorder)
            Text("ないよう")
                .font(.headline)
            TextEditor(text: $model.body)
                .frame(minHeight: 160)
                .border(Color.secondary.opacity(0.3))
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
                Button("頼む") {
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
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var notice: String?
    @Published public private(set) var didSucceed = false

    private let client: JobRequestClient

    public init(client: JobRequestClient) {
        self.client = client
    }

    /// 本文が空のまま「頼む」は押させない。タイトルは空でよい。
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
            let response = try await client.submit(title: title, body: body)
            didSucceed = true
            if let jobID = response.jobID, !jobID.isEmpty {
                notice = "頼んだよ(仕事 \(jobID))"
            } else {
                notice = "頼んだよ"
            }
            title = ""
            body = ""
        } catch {
            didSucceed = false
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
