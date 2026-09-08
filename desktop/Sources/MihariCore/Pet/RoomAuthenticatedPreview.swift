import AppKit
import Foundation
import SwiftUI
import WebKit

/// 非公開版を desktop 内で認証付きプレビューする仕組み。
///
/// 部屋 API は私的ネットワーク上にあり、`X-Mihari-Token` ヘッダが要る。
/// ブラウザ（NSWorkspace）ではヘッダを付けられないので、アプリ内の WKWebView で
/// 専用スキーム（`mihari-preview://`）を使う。HTML 内の相対リンク（画像・CSS・
/// JS・PDF）はすべて同じスキームで読み込まれ、その都度ヘッダ付きで部屋へ取りに行く。
/// Room トークンは URL にも HTML にも載らない。
public enum RoomAuthenticatedPreview {
    /// アプリ内プレビューの URL スキーム。
    public static let scheme = "mihari-preview"
}

/// 認証付きで部屋のファイルを取りに行く口。純粋な部品なので単体テストできる。
public struct RoomPreviewFetcher: Sendable {
    /// 部屋 API の原点（私的ネットワーク）。
    public let baseURL: URL
    /// `X-Mihari-Token` ヘッダにだけ載せる。URL には載せない。
    public let token: String
    public let session: URLSession
    /// いま開いている版。他の仕事・他の版・API への中継はしない。
    public let jobID: String
    public let version: String

    public init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        jobID: String,
        version: String
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.jobID = jobID
        self.version = version
    }

    /// このプレビューが中継してよいパスか。他ジョブの API を開くプロキシにしない。
    public func allowsPath(_ path: String) -> Bool {
        let prefix = "/jobs/\(jobID)/artifacts/\(version)/files"
        if path.contains("..") { return false }
        return path == prefix || path == prefix + "/" || path.hasPrefix(prefix + "/")
    }

    /// アプリ内ページの URL。`/jobs/<id>/artifacts/<v>/files/` をそのまま写す。
    public func pageURL(jobID: String, version: String) -> URL? {
        var components = URLComponents()
        components.scheme = RoomAuthenticatedPreview.scheme
        components.host = "room"
        components.path = "/jobs/\(jobID)/artifacts/\(version)/files/"
        return components.url
    }

    /// アプリ内スキームの URL を、ヘッダ付きの部屋 API への要求へ写す。
    ///
    /// パスはそのまま（例 `mihari-preview://room/jobs/.. /files/app.css` →
    /// `GET <baseURL>/jobs/.. /files/app.css`）。トークンはヘッダにしか置かない。
    /// 開いている版の files 配下以外は中継しない。
    public func request(forScheme schemeURL: URL) -> URLRequest? {
        let path = schemeURL.path
        guard allowsPath(path), let url = URL(string: path, relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 30
        return request
    }
}

/// `mihari-preview://` を実際の部屋 API へ中継する WKURLSchemeHandler。
/// WebKit は相対リソースもこのスキームで読み込むので、認証ヘッダを毎回付けられる。
public final class RoomAuthenticatedURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let fetcher: RoomPreviewFetcher
    /// 停止要求に備えて、いま流している要求を覚えておく。
    @MainActor private var inFlight: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(fetcher: RoomPreviewFetcher) {
        self.fetcher = fetcher
    }

    @MainActor
    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let request = fetcher.request(forScheme: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let identifier = ObjectIdentifier(task)
        let work = Task { @MainActor [fetcher] in
            do {
                let (data, response) = try await fetcher.session.data(for: request)
                try Task.checkCancellation()
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let headers =
                    (response as? HTTPURLResponse)?.allHeaderFields.map {
                        (String(describing: $0.key), String(describing: $0.value))
                    }
                    .reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
                    ?? [:]
                guard
                    let schemeResponse = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )
                else {
                    task.didFailWithError(URLError(.cannotParseResponse))
                    return
                }
                task.didReceive(schemeResponse)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
            inFlight[identifier] = nil
        }
        inFlight[identifier] = work
    }

    @MainActor
    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        inFlight.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

/// 非公開版の認証付きプレビュー窓。公開済み URL は従来どおりブラウザで開く。
/// プレビュー HTML 内からの追記（CSP 緩和）はせず、窓下部のネイティブ入力から followup する。
@MainActor
public final class RoomArtifactPreviewWindowController {
    /// アプリ全体で 1 つのプレビュー窓。開き直しても同じ窓を使う。
    public static let shared = RoomArtifactPreviewWindowController()

    private var window: NSWindow?

    public init() {}

    /// 指定版の成果物をアプリ内で認証付きプレビューする。
    public func show(client: RoomEventClient, jobID: String, version: String, title: String) {
        let fetcher = client.previewFetcher(jobID: jobID, version: version)
        guard let pageURL = fetcher.pageURL(jobID: jobID, version: version) else { return }
        let viewModel = RoomArtifactPreviewViewModel(client: client, jobID: jobID, version: version)
        let content = RoomArtifactPreviewView(
            viewModel: viewModel,
            fetcher: fetcher,
            pageURL: pageURL
        )
        if let window {
            window.contentViewController = NSHostingController(rootView: AnyView(content))
            window.title = title
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AnyView(content))
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
    }

    /// テストから窓の有無を見るための入り口。
    var isVisibleForTesting: Bool {
        window?.isVisible ?? false
    }
}
