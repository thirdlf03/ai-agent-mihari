import AppKit
import Foundation
import IOKit.hidsystem
import os

/// メディアキー(再生 / 一時停止)を OS に直接送る。
///
/// `CGEvent` 経由の `NX_SYSDEFINED` イベントで、Apple Events(オートメーション権限)を経由しない。
/// AppleScript が対象アプリに届かないとき(オートメーション権限が無い、対象が Music/Spotify 以外)の
/// 最終手段として使う。トグル動作(再生中なら止まり、止まっていれば再生される)なので、
/// 「何かを再生中だと確信できるとき」以外には呼ばないこと。誤って再生を始めてしまう。
public protocol MediaKeySending: Sendable {
    /// 再生 / 一時停止キーを 1 回分(押す→離す)送る。
    func sendPlayPauseToggle()
}

/// 実際に `CGEvent` を送る実装。
public struct SystemMediaKeySender: MediaKeySending {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "overlay.mediakey")

    public init() {}

    public func sendPlayPauseToggle() {
        post(keyDown: true)
        post(keyDown: false)
        Self.logger.info("メディアキー(再生/一時停止)を送出した")
    }

    /// `NX_KEYTYPE_PLAY` を持つ `NSEvent(.systemDefined)` を組み立てて `CGEvent` として送る。
    /// data1 の上位 16bit がキー種別、次の 8bit がキー状態(0xa=down, 0xb=up)。
    private func post(keyDown: Bool) {
        let keyState = keyDown ? 0xa : 0xb
        let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | (keyState << 8)

        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: keyDown ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
