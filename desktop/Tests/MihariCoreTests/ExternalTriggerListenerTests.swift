import Foundation
import Testing
import notify

@testable import MihariCore

@Suite("外部トリガー(Darwin 通知)の購読")
struct ExternalTriggerListenerTests {

    @Test("通知が届いたらハンドラを呼ぶ")
    func firesHandlerOnNotification() async {
        let name = "com.thirdlf03.mihari.test.\(UUID().uuidString)"
        let listener = ExternalTriggerListener()
        await confirmation("通知でハンドラが呼ばれる") { fired in
            listener.listen(name: name, queue: .global()) { fired() }
            notify_post(name)
            try? await Task.sleep(for: .milliseconds(300))
        }
        listener.stop()
    }

    @Test("stop したら以後の通知は届かない")
    func stopCancelsSubscription() async {
        let name = "com.thirdlf03.mihari.test.\(UUID().uuidString)"
        let listener = ExternalTriggerListener()
        await confirmation("届かない", expectedCount: 0) { fired in
            listener.listen(name: name, queue: .global()) { fired() }
            listener.stop()
            notify_post(name)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
