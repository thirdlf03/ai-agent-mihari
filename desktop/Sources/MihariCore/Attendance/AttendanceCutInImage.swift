import Foundation

/// 在席スタンプの演出で出すカットイン 1 枚。
///
/// raw value はそのままファイル名(拡張子なし)で、ペットのディレクトリの
/// `cutin/<rawValue>.png` を指す。3 枚揃っているペットだけがカットインを出せる。
public enum AttendanceCutInImage: String, CaseIterable, Sendable {
    /// 指を差し出して待っている。Touch ID の入力待ちのあいだ出す。
    case reach
    /// 指が触れた。認証に成功したときに出す。
    case touched
    /// 空振り。認証に失敗・キャンセルしたときに出す。
    case failed
}
