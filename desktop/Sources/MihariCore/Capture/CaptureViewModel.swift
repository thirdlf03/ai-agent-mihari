import AppKit
import Foundation
import SwiftUI
import os

/// `CaptureView` の状態。
///
/// カメラとスクリーンショットで別々の「撮影中」フラグを持つが、結果(プレビュー・保存先・
/// エラー)は最後に撮った 1 枚を指す共通の状態にまとめている。
@MainActor
public final class CaptureViewModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "capture-view")

    @Published public private(set) var isCapturingPhoto = false
    @Published public private(set) var isCapturingScreenshot = false
    @Published public private(set) var isCapturingIPhone = false
    @Published public private(set) var lastArtifact: CaptureArtifact?
    @Published public private(set) var previewImage: NSImage?
    @Published public private(set) var errorMessage: String?

    private let service: CaptureService
    /// iPhone のスクショを PNG で取ってくる経路。デーモン(Python)経由なので外から差し込む。
    private let iphoneScreenshot: (@Sendable () async throws -> Data)?

    public init(
        service: CaptureService = CaptureService(),
        iphoneScreenshot: (@Sendable () async throws -> Data)? = nil
    ) {
        self.service = service
        self.iphoneScreenshot = iphoneScreenshot
    }

    /// iPhone スクショの経路が配線されているか。ボタンの表示条件に使う。
    public var canCaptureIPhone: Bool { iphoneScreenshot != nil }

    /// カメラで 1 枚撮る。権限が無い・カメラが無いなどの理由で失敗しても例外を投げず、
    /// `errorMessage` に理由を残すだけにする。
    public func capturePhoto() async {
        guard !isCapturingPhoto else { return }
        isCapturingPhoto = true
        defer { isCapturingPhoto = false }
        await runCapture(label: "カメラ撮影") { [service] in try await service.capturePhoto() }
    }

    /// メインディスプレイのスクリーンショットを 1 枚撮る。
    public func captureScreenshot() async {
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        defer { isCapturingScreenshot = false }
        await runCapture(label: "スクリーンショット") { [service] in try await service.captureScreenshot() }
    }

    /// iPhone のスクショを 1 枚取ってくる(iOS 17+ は tunneld の常駐が前提)。
    public func captureIPhoneScreenshot() async {
        guard !isCapturingIPhone else { return }
        guard let iphoneScreenshot else {
            errorMessage = "デーモンに接続していないため、iPhone のスクショを取得できない"
            return
        }
        isCapturingIPhone = true
        defer { isCapturingIPhone = false }
        await runCapture(label: "iPhone スクショ") {
            let data = try await iphoneScreenshot()
            let url = try CaptureFileStore.write(
                data,
                kind: .iphone,
                directory: CaptureFileStore.directory()
            )
            return CaptureArtifact(kind: .iphone, url: url)
        }
    }

    /// 保存済みの画像をローカルから削除する。Discord へ送信し終えたあとに呼ぶ想定。
    public func deleteLastArtifact() {
        guard let artifact = lastArtifact else { return }
        do {
            try artifact.delete()
            Self.logger.info("削除した: \(artifact.url.path, privacy: .public)")
            lastArtifact = nil
            previewImage = nil
        } catch {
            handle(error, label: "削除")
        }
    }

    private func runCapture(label: String, operation: @escaping () async throws -> CaptureArtifact) async {
        errorMessage = nil
        do {
            let artifact = try await operation()
            lastArtifact = artifact
            previewImage = NSImage(contentsOf: artifact.url)
            Self.logger.info("\(label, privacy: .public)を保存した: \(artifact.url.path, privacy: .public)")
        } catch {
            handle(error, label: label)
        }
    }

    private func handle(_ error: Error, label: String) {
        let message = (error as? CaptureError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        Self.logger.error("\(label, privacy: .public)に失敗した: \(message, privacy: .public)")
    }
}
