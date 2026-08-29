import Foundation
import Testing

@testable import MihariCore

@Suite("吹き出しの表示時間の決定ロジック")
struct PetBubbleDurationPolicyTests {

    @Test("短いセリフでも最低表示時間を下回らない")
    func neverGoesBelowMinimum() {
        let duration = PetBubbleDurationPolicy.duration(for: "え")
        #expect(duration == PetBubbleDurationPolicy.minimumSeconds)
    }

    @Test("空文字でも最低表示時間は確保する")
    func emptyLineStillGetsMinimum() {
        #expect(PetBubbleDurationPolicy.duration(for: "") == PetBubbleDurationPolicy.minimumSeconds)
    }

    @Test("長いセリフは上限で頭打ちになる")
    func clampsToMaximum() {
        let longLine = String(repeating: "サボるな", count: 50)
        #expect(PetBubbleDurationPolicy.duration(for: longLine) == PetBubbleDurationPolicy.maximumSeconds)
    }

    @Test("上限にも下限にも触れない長さでは文字数に比例する")
    func scalesWithCharacterCountInMiddleRange() {
        let line = String(repeating: "あ", count: 20)
        let expected = Double(line.count) * PetBubbleDurationPolicy.secondsPerCharacter
        #expect(PetBubbleDurationPolicy.duration(for: line) == expected)
        #expect(expected > PetBubbleDurationPolicy.minimumSeconds)
        #expect(expected < PetBubbleDurationPolicy.maximumSeconds)
    }
}
