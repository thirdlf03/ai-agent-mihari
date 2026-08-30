import Foundation
import Testing

@testable import MihariCore

@Suite("起動からの終了ロック")
struct QuitTimeLockTests {

    @Test("ロックしていなければ、いつでも解除済み")
    func unlockedByDefault() {
        let lock = QuitTimeLock()

        #expect(lock.isUnlocked())
        #expect(lock.remainingDescription() == nil)
    }

    @Test("ロック直後は解除されていない")
    func lockedImmediatelyAfterLocking() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)

        lock.lock(for: 4, from: now)

        #expect(!lock.isUnlocked(now: now))
    }

    @Test("ロック時間ちょうどで解除される")
    func unlocksExactlyAtTheDeadline() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(lock.isUnlocked(now: now.addingTimeInterval(3600)))
    }

    @Test("ロック時間の1秒前はまだ解除されていない")
    func staysLockedOneSecondBeforeTheDeadline() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(!lock.isUnlocked(now: now.addingTimeInterval(3600 - 1)))
    }

    @Test("残り時間の表示は時間と分を含む")
    func remainingDescriptionIncludesHoursAndMinutes() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 2.5, from: now)

        let description = lock.remainingDescription(now: now.addingTimeInterval(3600 + 600))

        #expect(description == "あと1時間20分")
    }

    @Test("残り1時間未満は分だけの表示になる")
    func remainingDescriptionOmitsHoursWhenUnderOne() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        let description = lock.remainingDescription(now: now.addingTimeInterval(3600 - 300))

        #expect(description == "あと5分")
    }

    @Test("解除済みなら残り時間の表示は無い")
    func remainingDescriptionIsNilWhenUnlocked() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(lock.remainingDescription(now: now.addingTimeInterval(3600)) == nil)
    }
}
