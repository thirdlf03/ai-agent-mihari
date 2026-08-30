import Foundation

/// 在席スタンプの演出 1 手順ぶん。セリフ・ペットの動き・カットインの絵をひとまとめにする。
///
/// 画面には触れない純粋な値なので、演出の中身はこの型だけを見ればわかる。
/// 実際に喋らせたり絵を出したりするのは `AppCoordinator` の役目。
struct AttendanceCeremonyStep: Equatable, Sendable {
    /// 喋らせるセリフの区分。本文は同封セリフ(`lines.json`)から引く。
    let kind: PetSpeechLines.Kind
    /// ペットに 1 回だけ再生させるアニメーション。
    let animation: PetAnimation
    /// 出すカットインの絵。nil ならカットインは動かさない。
    let cutInImage: AttendanceCutInImage?
}

/// 在席スタンプ(Touch ID)の演出の台本。
///
/// 「指を差し出す → ユーザーが Touch ID に指を置く = 指を合わせる」という見立てで、
/// 開幕と結末の 2 手順だけを持つ。
enum AttendanceCeremonyScript {

    /// 開幕。指を差し出して Touch ID の入力を待つ。
    static var opening: AttendanceCeremonyStep {
        AttendanceCeremonyStep(
            kind: .stampReach,
            animation: .waiting,
            cutInImage: .reach
        )
    }

    /// 結末。認証の結末で喜ぶか取り乱すかが変わる。
    ///
    /// - Parameter outcome: `AttendanceModel.stamp()` が返した結末。
    static func closing(_ outcome: AttendanceStampOutcome) -> AttendanceCeremonyStep {
        switch outcome {
        case .stamped:
            return AttendanceCeremonyStep(
                kind: .stampTouched,
                animation: .jumping,
                cutInImage: .touched
            )
        case .timedOut:
            // 待ちぼうけは空振りと同じ絵・同じ動きで、セリフだけ変える。
            return AttendanceCeremonyStep(
                kind: .stampTimeout,
                animation: .failed,
                cutInImage: .failed
            )
        case .failed, .unavailable:
            return AttendanceCeremonyStep(
                kind: .stampMissed,
                animation: .failed,
                cutInImage: .failed
            )
        }
    }
}
