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

/// 同じ演出を誰が呼んだか。**変わるのはセリフの区分だけ**で、絵も動きも共通にする。
enum AttendanceCeremonyVariant: Equatable, Sendable {
    /// メニューの「在席スタンプを押す」。押せば履歴が増え、5 分の猶予が付く。
    case stamp
    /// 疑い 1 の Touch ID チェック。`onPhone` は iPhone を触っているか。
    /// 成功しても履歴は増やさず、猶予も付けない。
    case suspect(onPhone: Bool)
}

/// 在席スタンプ(Touch ID)の演出の台本。
///
/// 「指を差し出す → ユーザーが Touch ID に指を置く = 指を合わせる」という見立てで、
/// 開幕と結末の 2 手順だけを持つ。
enum AttendanceCeremonyScript {

    /// 開幕。指を差し出して Touch ID の入力を待つ。
    static func opening(_ variant: AttendanceCeremonyVariant = .stamp) -> AttendanceCeremonyStep {
        AttendanceCeremonyStep(
            kind: openingKind(variant),
            animation: .waiting,
            cutInImage: .reach
        )
    }

    /// 結末。認証の結末で喜ぶか取り乱すかが変わる。
    ///
    /// - Parameters:
    ///   - outcome: `AttendanceModel.stamp()` / `verify()` が返した結末。
    ///   - variant: どちらから呼ばれた演出か。セリフの区分だけが変わる。
    static func closing(
        _ outcome: AttendanceStampOutcome,
        variant: AttendanceCeremonyVariant = .stamp
    ) -> AttendanceCeremonyStep {
        switch outcome {
        case .stamped:
            return AttendanceCeremonyStep(
                kind: variant == .stamp ? .stampTouched : .suspectTouched,
                animation: .jumping,
                cutInImage: .touched
            )
        case .timedOut:
            // 待ちぼうけは空振りと同じ絵・同じ動きで、セリフだけ変える。
            return AttendanceCeremonyStep(
                kind: variant == .stamp ? .stampTimeout : .suspectTimeout,
                animation: .failed,
                cutInImage: .failed
            )
        case .failed, .unavailable:
            return AttendanceCeremonyStep(
                kind: variant == .stamp ? .stampMissed : .suspectMissed,
                animation: .failed,
                cutInImage: .failed
            )
        }
    }

    /// 開幕のセリフの区分。疑いのときだけ、iPhone を触っているかで言い方を変える。
    private static func openingKind(_ variant: AttendanceCeremonyVariant) -> PetSpeechLines.Kind {
        switch variant {
        case .stamp: return .stampReach
        case .suspect(let onPhone): return onPhone ? .suspectReachPhone : .suspectReach
        }
    }
}
