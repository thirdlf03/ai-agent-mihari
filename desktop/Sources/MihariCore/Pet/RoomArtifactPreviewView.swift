import AppKit
import SwiftUI
import WebKit

/// 認証付きプレビュー + ネイティブの「ここ直して」バー。
/// プレビュー HTML は CSP で API に繋げないので、追記は desktop 側で行う。
struct RoomArtifactPreviewView: View {
    @ObservedObject var viewModel: RoomArtifactPreviewViewModel
    let fetcher: RoomPreviewFetcher
    let pageURL: URL

    var body: some View {
        VStack(spacing: 0) {
            RoomAuthenticatedWebView(fetcher: fetcher, pageURL: pageURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            followupBar
        }
    }

    private var followupBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ここ直して")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "直してほしいところを短く書いて",
                    text: $viewModel.feedback,
                    axis: .vertical
                )
                .lineLimit(1 ... 3)
                .textFieldStyle(.roundedBorder)
                if viewModel.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("送る") {
                    Task { await viewModel.submitFeedback() }
                }
                .disabled(!viewModel.canSubmit)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            if viewModel.isOverCharacterLimit {
                Text("280 文字以内にしてね")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let notice = viewModel.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(viewModel.didFail ? .red : .green)
            }
        }
        .padding(12)
    }
}

/// `mihari-preview://` の WKWebView。スキームハンドラとナビゲーション制御を抱える。
struct RoomAuthenticatedWebView: NSViewRepresentable {
    let fetcher: RoomPreviewFetcher
    let pageURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fetcher: fetcher)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.schemeHandler,
            forURLScheme: RoomAuthenticatedPreview.scheme
        )
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    /// スキーム中継の寿命を WebView と揃える。外部 http(s) はブラウザで開く。
    final class Coordinator: NSObject, WKNavigationDelegate {
        let schemeHandler: RoomAuthenticatedURLSchemeHandler

        init(fetcher: RoomPreviewFetcher) {
            schemeHandler = RoomAuthenticatedURLSchemeHandler(fetcher: fetcher)
            super.init()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == RoomAuthenticatedPreview.scheme || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
