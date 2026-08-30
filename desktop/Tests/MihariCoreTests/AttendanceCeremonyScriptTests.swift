import Foundation
import Testing

@testable import MihariCore

/// Touch ID の演出の台本を固定する。セリフ・動き・カットインの絵の対応が崩れると気づけるようにする。
@Suite("Touch ID の演出の台本")
struct AttendanceCeremonyScriptTests {

    @Test("開幕は待ちの動きで指を差し出し、reach のカットインを出す")
    func openingReachesOut() {
        let step = AttendanceCeremonyScript.opening()
        #expect(step.kind == .stampReach)
        #expect(step.animation == .waiting)
        #expect(step.cutInImage == .reach)
    }

    @Test("スタンプが増えたら跳ねて、touched のカットインに差し替える")
    func closingOnStampedIsHappy() {
        let step = AttendanceCeremonyScript.closing(.stamped)
        #expect(step.kind == .stampTouched)
        #expect(step.animation == .jumping)
        #expect(step.cutInImage == .touched)
    }

    @Test("認証に失敗したら落ち込んで、failed のカットインに差し替える")
    func closingOnMissIsUpset() {
        let step = AttendanceCeremonyScript.closing(.failed)
        #expect(step.kind == .stampMissed)
        #expect(step.animation == .failed)
        #expect(step.cutInImage == .failed)
    }

    @Test("認証を出せなかったときも空振りと同じ扱いにする")
    func closingOnUnavailableIsTheSameAsMiss() {
        #expect(AttendanceCeremonyScript.closing(.unavailable) == AttendanceCeremonyScript.closing(.failed))
    }

    @Test("時間切れは空振りと同じ絵・同じ動きで、セリフだけ変える")
    func closingOnTimeoutKeepsTheMissLook() {
        let step = AttendanceCeremonyScript.closing(.timedOut)
        #expect(step.kind == .stampTimeout)
        #expect(step.animation == .failed)
        #expect(step.cutInImage == .failed)
    }

    @Test("結末は成否で必ず違うものになる")
    func closingDiffersByOutcome() {
        #expect(AttendanceCeremonyScript.closing(.stamped) != AttendanceCeremonyScript.closing(.failed))
        #expect(AttendanceCeremonyScript.closing(.timedOut) != AttendanceCeremonyScript.closing(.failed))
    }

    // MARK: - 疑い 1 の Touch ID チェック

    @Test("疑い 1 は絵も動きも同じで、セリフの区分だけが変わる")
    func suspectVariantOnlyChangesTheLines() {
        let stamp = AttendanceCeremonyScript.opening(.stamp)
        let suspect = AttendanceCeremonyScript.opening(.suspect(onPhone: false))

        #expect(suspect.kind == .suspectReach)
        #expect(suspect.animation == stamp.animation)
        #expect(suspect.cutInImage == stamp.cutInImage)
    }

    @Test("iPhone を触っているときは、疑い 1 の言い方が変わる")
    func suspectOnPhoneHasItsOwnLine() {
        #expect(AttendanceCeremonyScript.opening(.suspect(onPhone: true)).kind == .suspectReachPhone)
    }

    @Test("疑い 1 の結末は 成功 / 空振り / 時間切れ で言い分ける")
    func suspectClosingKinds() {
        let variant = AttendanceCeremonyVariant.suspect(onPhone: false)
        #expect(AttendanceCeremonyScript.closing(.stamped, variant: variant).kind == .suspectTouched)
        #expect(AttendanceCeremonyScript.closing(.failed, variant: variant).kind == .suspectMissed)
        #expect(AttendanceCeremonyScript.closing(.unavailable, variant: variant).kind == .suspectMissed)
        #expect(AttendanceCeremonyScript.closing(.timedOut, variant: variant).kind == .suspectTimeout)
    }

    @Test("台本のセリフはすべて同封セリフから引ける")
    func everyStepHasBundledLines() {
        let variant = AttendanceCeremonyVariant.suspect(onPhone: false)
        let steps: [AttendanceCeremonyStep] = [
            AttendanceCeremonyScript.opening(),
            AttendanceCeremonyScript.opening(.suspect(onPhone: false)),
            AttendanceCeremonyScript.opening(.suspect(onPhone: true)),
            AttendanceCeremonyScript.closing(.stamped),
            AttendanceCeremonyScript.closing(.failed),
            AttendanceCeremonyScript.closing(.timedOut),
            AttendanceCeremonyScript.closing(.stamped, variant: variant),
            AttendanceCeremonyScript.closing(.failed, variant: variant),
            AttendanceCeremonyScript.closing(.timedOut, variant: variant),
        ]
        for step in steps {
            #expect(
                !BundledVoiceLines.shared.lines(for: step.kind.bundled).isEmpty,
                "\(step.kind.rawValue) のセリフが無い"
            )
        }
    }
}
