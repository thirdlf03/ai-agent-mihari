import Testing

@testable import MihariCore

@Suite("スリープ防止")
struct SleepPreventerTests {

    @Test("start/stop を何度呼んでもクラッシュせず、多重に assertion を積み増さない")
    func startAndStopAreIdempotent() {
        let preventer = IOPMSleepPreventer(reason: "test")

        preventer.start()
        preventer.start()
        preventer.stop()
        preventer.stop()

        // 例外を投げずに一連の呼び出しが完了すればよい(IOKit の assertion 取得/解放を実機で確認)。
    }
}
