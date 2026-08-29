import Foundation
import Testing

@testable import MihariCore

@Suite("在席スタンプの猶予期間判定")
struct AttendanceGraceTests {

    private func stamp(secondsAgo: TimeInterval, from now: Date) -> AttendanceStamp {
        AttendanceStamp(stampedAt: now.addingTimeInterval(-secondsAgo), biometryTypeText: "Touch ID")
    }

    @Test("スタンプが1件もなければ経過秒数は nil で、猶予期間中でもない")
    func noStampsMeansNoGrace() {
        let now = Date()
        #expect(AttendanceGrace.secondsSinceLastStamp(stamps: [], now: now) == nil)
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: [], now: now) == false)
        #expect(AttendanceGrace.remainingGraceSeconds(stamps: [], now: now) == 0)
    }

    @Test("押した直後は猶予期間中で、残り時間はほぼ猶予いっぱいになる")
    func justStampedIsWithinGrace() {
        let now = Date()
        let stamps = [stamp(secondsAgo: 0, from: now)]
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now, gracePeriod: 300) == true)
        #expect(AttendanceGrace.remainingGraceSeconds(stamps: stamps, now: now, gracePeriod: 300) == 300)
    }

    @Test("猶予期間ちょうどで経過した瞬間は猶予期間外として扱う(境界)")
    func exactlyAtGracePeriodBoundaryIsOutside() {
        let now = Date()
        let stamps = [stamp(secondsAgo: 300, from: now)]
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now, gracePeriod: 300) == false)
        #expect(AttendanceGrace.remainingGraceSeconds(stamps: stamps, now: now, gracePeriod: 300) == 0)
    }

    @Test("猶予期間の1秒手前はまだ猶予期間中")
    func justBeforeBoundaryIsStillWithinGrace() {
        let now = Date()
        let stamps = [stamp(secondsAgo: 299, from: now)]
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now, gracePeriod: 300) == true)
        #expect(AttendanceGrace.remainingGraceSeconds(stamps: stamps, now: now, gracePeriod: 300) == 1)
    }

    @Test("猶予期間を過ぎていれば猶予期間外で、残り秒数は0")
    func afterGracePeriodIsOutside() {
        let now = Date()
        let stamps = [stamp(secondsAgo: 301, from: now)]
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now, gracePeriod: 300) == false)
        #expect(AttendanceGrace.remainingGraceSeconds(stamps: stamps, now: now, gracePeriod: 300) == 0)
    }

    @Test("複数のスタンプがあれば、並び順に関係なく最新のものを基準にする")
    func picksLatestStampRegardlessOfOrder() {
        let now = Date()
        let stamps = [
            stamp(secondsAgo: 300, from: now),
            stamp(secondsAgo: 10, from: now),
            stamp(secondsAgo: 3600, from: now),
        ]
        let elapsed = AttendanceGrace.secondsSinceLastStamp(stamps: stamps, now: now)
        #expect(elapsed != nil)
        #expect(abs((elapsed ?? -1) - 10) < 0.001)
        #expect(AttendanceGrace.isWithinGracePeriod(stamps: stamps, now: now, gracePeriod: 300) == true)
    }

    @Test("既定の猶予期間は5分(300秒)")
    func defaultGracePeriodIsFiveMinutes() {
        #expect(AttendanceGrace.defaultGracePeriod == 300)
    }
}
