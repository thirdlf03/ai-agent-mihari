import AVFoundation
import CoreMotion
import IOKit.hidsystem
import Testing

@testable import MihariCore

@Suite("権限の生の値から状態への翻訳")
struct PermissionStateMapperTests {

    @Test("AVAuthorizationStatus は authorized だけを許可として扱う")
    func authorizationMapping() {
        #expect(PermissionStateMapper.from(authorization: .authorized).grant == .granted)
        #expect(PermissionStateMapper.from(authorization: .denied).grant == .denied)
        #expect(PermissionStateMapper.from(authorization: .restricted).grant == .denied)
        #expect(PermissionStateMapper.from(authorization: .notDetermined).grant == .undetermined)
    }

    @Test("画面収録の false は拒否ではなく未決定に倒す")
    func screenRecordingMapping() {
        #expect(PermissionStateMapper.fromScreenRecording(preflight: true).grant == .granted)
        // CGPreflightScreenCaptureAccess は未決定と拒否を区別できないため、false を denied にしてはいけない。
        #expect(PermissionStateMapper.fromScreenRecording(preflight: false).grant == .undetermined)
    }

    @Test("IOHIDAccessType の 3 状態を取り違えない")
    func hidAccessMapping() {
        #expect(PermissionStateMapper.from(hidAccess: kIOHIDAccessTypeGranted).grant == .granted)
        #expect(PermissionStateMapper.from(hidAccess: kIOHIDAccessTypeDenied).grant == .denied)
        #expect(PermissionStateMapper.from(hidAccess: kIOHIDAccessTypeUnknown).grant == .undetermined)
    }

    @Test("CMAuthorizationStatus は authorized だけを許可として扱う")
    func motionMapping() {
        #expect(PermissionStateMapper.from(motion: .authorized).grant == .granted)
        #expect(PermissionStateMapper.from(motion: .denied).grant == .denied)
        #expect(PermissionStateMapper.from(motion: .restricted).grant == .denied)
        #expect(PermissionStateMapper.from(motion: .notDetermined).grant == .undetermined)
    }

    @Test("オートメーションは対象アプリ未起動を拒否と誤読しない")
    func automationMapping() {
        #expect(PermissionStateMapper.fromAutomation(status: noErr).grant == .granted)
        #expect(PermissionStateMapper.fromAutomation(status: OSStatus(errAEEventNotPermitted)).grant == .denied)
        #expect(
            PermissionStateMapper.fromAutomation(status: OSStatus(errAEEventWouldRequireUserConsent)).grant
                == .undetermined
        )
        // Music を閉じているだけで赤く出さない。
        #expect(PermissionStateMapper.fromAutomation(status: OSStatus(procNotFound)).grant == .undetermined)
    }

    @Test("翻訳結果には必ず生の値の説明が入る")
    func detailIsNeverEmpty() {
        #expect(!PermissionStateMapper.from(authorization: .authorized).detail.isEmpty)
        #expect(!PermissionStateMapper.fromAutomation(status: OSStatus(-12345)).detail.isEmpty)
    }
}
