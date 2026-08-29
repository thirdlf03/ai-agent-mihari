import Foundation

/// 撮影画像を一時ディレクトリへ書き出すためのファイル名・保存先の組み立て。
///
/// カメラ / スクリーンショット共通で使うので、ファイル名の形式(種類-日時-ランダム値.png)を
/// ここに一本化する。ロジックが純粋関数なので単体テストで固定できる。
public enum CaptureFileStore {

    /// ファイル名に付ける日時のフォーマット。秒まで含めれば連射しても衝突しない。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// ファイル名の末尾に付けるランダム値の桁数。同一秒内の連射でも衝突しないようにするだけなので短くてよい。
    private static let randomSuffixLength = 8

    /// 撮影画像専用の一時ディレクトリ。呼び出し元の一時ディレクトリ配下にまとめる。
    public static func directory(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent("com.thirdlf03.mihari.capture", isDirectory: true)
    }

    /// `種類-日時-ランダム値.png` 形式のファイル名を組み立てる。
    public static func fileName(
        kind: CaptureKind,
        date: Date = Date(),
        randomSuffix: () -> String = { UUID().uuidString }
    ) -> String {
        let suffix = String(randomSuffix().prefix(randomSuffixLength))
        return "\(kind.rawValue)-\(timestampFormatter.string(from: date))-\(suffix).png"
    }

    /// PNG データをディレクトリへ書き出し、保存先の URL を返す。
    /// ディレクトリが無ければ作る。
    @discardableResult
    public static func write(
        _ data: Data,
        kind: CaptureKind,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.fileWriteFailed(reason: error.localizedDescription)
        }

        let url = directory.appendingPathComponent(fileName(kind: kind))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.fileWriteFailed(reason: error.localizedDescription)
        }
        return url
    }
}
