import Testing

@testable import MihariCore

@Suite("presentationOptions の組み合わせ検証")
struct OverlayPresentationPolicyTests {

    @Test("説教オーバーレイの固定値は常に有効な組み合わせ")
    func sermonOptionsAreValid() {
        #expect(
            OverlayPresentationPolicy.invalidCombinationReasons(in: OverlayPresentationPolicy.sermonOptions).isEmpty
        )
    }

    @Test("解除時に戻す空集合は常に有効")
    func dismissedIsAlwaysValid() {
        #expect(OverlayPresentationPolicy.invalidCombinationReasons(in: OverlayPresentationPolicy.dismissed).isEmpty)
    }

    @Test("hideMenuBar だけでは hideDock が無いので無効")
    func hideMenuBarRequiresHideDock() {
        let reasons = OverlayPresentationPolicy.invalidCombinationReasons(in: [.hideMenuBar])
        #expect(!reasons.isEmpty)
    }

    @Test("autoHideDock と hideDock は同時に指定できない")
    func autoHideDockAndHideDockAreExclusive() {
        let reasons = OverlayPresentationPolicy.invalidCombinationReasons(in: [.autoHideDock, .hideDock])
        #expect(!reasons.isEmpty)
    }

    @Test("disableProcessSwitching だけでは hideDock も autoHideDock も無いので無効")
    func disableProcessSwitchingRequiresDockControl() {
        let reasons = OverlayPresentationPolicy.invalidCombinationReasons(in: [.disableProcessSwitching])
        #expect(!reasons.isEmpty)
    }
}
