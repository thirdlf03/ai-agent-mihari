import Testing

@testable import MihariCore

@Suite("システム設定のペイン URL")
struct PrivacyPaneTests {

    @Test("すべてのペインが URL を組み立てられる")
    func allPanesBuildURL() {
        for pane in PrivacyPane.allCases {
            #expect(pane.url != nil, "URL を作れない: \(pane.rawValue)")
        }
    }

    @Test("プライバシー設定のスキームとアンカーを使う")
    func urlFormat() {
        #expect(
            PrivacyPane.camera.url?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        )
        #expect(
            PrivacyPane.motion.url?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion"
        )
    }
}
