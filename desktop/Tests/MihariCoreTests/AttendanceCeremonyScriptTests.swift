import Foundation
import Testing

@testable import MihariCore

/// 在席スタンプの演出の台本を固定する。セリフ・動き・カットインの絵の対応が崩れると気づけるようにする。
@Suite("在席スタンプの演出の台本")
struct AttendanceCeremonyScriptTests {

    @Test("開幕は待ちの動きで指を差し出し、reach のカットインを出す")
    func openingReachesOut() {
        let step = AttendanceCeremonyScript.opening
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

    @Test("台本のセリフはすべて同封セリフから引ける")
    func everyStepHasBundledLines() {
        let steps = [
            AttendanceCeremonyScript.opening,
            AttendanceCeremonyScript.closing(.stamped),
            AttendanceCeremonyScript.closing(.failed),
            AttendanceCeremonyScript.closing(.timedOut),
        ]
        for step in steps {
            #expect(
                !BundledVoiceLines.shared.lines(for: step.kind.bundled).isEmpty,
                "\(step.kind.rawValue) のセリフが無い"
            )
        }
    }
}
