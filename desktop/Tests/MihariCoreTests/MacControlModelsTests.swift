import Foundation
import Testing

@testable import MihariCore

/// 線上の約束（JSON フレームの形・数値の丸め・画面構成の印）を、部屋側の実装
/// （`room/src/mihari_room/mac_control/`）と突き合わせて確かめる。
@Suite("Mac control の線上の約束")
struct MacControlModelsTests {

    private func parse(_ json: String) throws -> MacControlIncomingFrame {
        let data = Data(json.utf8)
        let parsed = try MacControlIncomingFrame.parse(data: data)
        return try #require(parsed?.frame)
    }

    @Test("hello_ack が読める")
    func helloAck() throws {
        let frame = try parse(#"{"type":"hello_ack","device_id":"mac-abc","protocol":1}"#)
        guard case .helloAck(let deviceID) = frame else {
            Issue.record("helloAck のはず: \(frame)")
            return
        }
        #expect(deviceID == "mac-abc")
    }

    @Test("ping が読めて、pong が返せる")
    func pingPong() throws {
        let frame = try parse(#"{"type":"ping","ts":"2024-01-01T00:00:00Z"}"#)
        guard case .ping(let ts) = frame else {
            Issue.record("ping のはず: \(frame)")
            return
        }
        let pong = try MacControlOutgoing.pong(ts: ts)
        let pongObject = try #require(try JSONSerialization.jsonObject(with: Data(pong.utf8)) as? [String: Any])
        #expect(pongObject["type"] as? String == "pong")
        #expect(pongObject["ts"] as? String == "2024-01-01T00:00:00Z")
    }

    @Test("control.request が読める")
    func controlRequest() throws {
        let frame = try parse(
            #"{"type":"control.request","request_id":"r1","job_id":"job-1","run_id":"run-1","job_title":"画面を触って","scope":"whole_mac","note":"この依頼の間…"}"#
        )
        guard case .controlRequest(let request) = frame else {
            Issue.record("controlRequest のはず: \(frame)")
            return
        }
        #expect(request.requestID == "r1")
        #expect(request.jobID == "job-1")
        #expect(request.runID == "run-1")
        #expect(request.jobTitle == "画面を触って")
        #expect(request.scope == "whole_mac")
    }

    @Test("click の op が読めて、座標は整数へ丸まる")
    func opClick() throws {
        let frame = try parse(
            #"""
            {"type":"op","op_id":"op-1","run_id":"run-1","job_id":"job-1","kind":"click",
             "params":{"display_id":"1001","x":120.0,"y":340,"button":"left","modifiers":[]},
             "expected":{"display_id":"1001","width_px":2880,"height_px":1800,"scale":2.0,
                         "bounds":{"x":0,"y":0,"width":1440,"height":900},"layout_token":"tok-abc"},
             "sent_at":"2024-01-01T00:00:00Z"}
            """#
        )
        guard case .op(let op) = frame else {
            Issue.record("op のはず: \(frame)")
            return
        }
        #expect(op.opID == "op-1")
        #expect(op.kind == .click)
        #expect(op.displayID == "1001")
        #expect(op.xPX == 120)
        #expect(op.yPX == 340)
        #expect(op.button == "left")
        #expect(op.expected?.widthPX == 2880)
        #expect(op.expected?.scale == 2.0)
        // 撮影画像のピクセル → メインディスプレイ左上原点の点。
        let point = op.expected?.point(forPxX: 120, yPX: 340)
        #expect(point == MacPoint(x: 60, y: 170))
    }

    @Test("type_text の op が読めて、パラメータを取り出せる")
    func opTypeText() throws {
        let frame = try parse(
            #"{"type":"op","op_id":"op-2","run_id":"run-1","job_id":"job-1","kind":"type_text","params":{"text":"こんにちは"}}"#
        )
        guard case .op(let op) = frame else {
            Issue.record("op のはず: \(frame)")
            return
        }
        #expect(op.kind == .typeText)
        #expect(op.text == "こんにちは")
    }

    @Test("cancel_run が読めて、実行中操作の取り消しに使える")
    func cancelRun() throws {
        let frame = try parse(
            #"{"type":"cancel_run","run_id":"run-1","job_id":"job-1","reason":"user cancelled"}"#
        )
        guard case .cancelRun(let runID, let jobID) = frame else {
            Issue.record("cancelRun のはず: \(frame)")
            return
        }
        #expect(runID == "run-1")
        #expect(jobID == "job-1")
    }

    @Test("未知のフレームは無視してよい")
    func unknownFrame() throws {
        let data = Data(#"{"type":"future_frame","maybe":true}"#.utf8)
        let parsed = try MacControlIncomingFrame.parse(data: data)
        #expect(parsed == nil)
    }

    @Test("hello が部屋の約束どおりの形で出る")
    func helloEncoding() throws {
        let endpoint = MacControlEndpoint(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "secret")
        let identity = MacControlIdentity(
            deviceID: "mac-abc",
            hostname: "my-mac",
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.0"
        )
        let displays = [
            MacDisplayInfo(
                displayID: "1",
                name: "Color LCD",
                widthPX: 2880,
                heightPX: 1800,
                scale: 2.0,
                bounds: MacRect(x: 0, y: 0, width: 1440, height: 900),
                layoutToken: "tok"
            )
        ]
        let text = try MacControlOutgoing.hello(endpoint: endpoint, identity: identity, displays: displays)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "hello")
        #expect(object["device_id"] as? String == "mac-abc")
        #expect(object["hostname"] as? String == "my-mac")
        let wireDisplays = try #require(object["displays"] as? [[String: Any]])
        #expect(wireDisplays.first?["display_id"] as? String == "1")
        #expect(wireDisplays.first?["width_px"] as? Int == 2880)
        let bounds = try #require(wireDisplays.first?["bounds"] as? [String: Any])
        #expect(bounds["width"] as? Double == 1440)
    }

    @Test("control.decision が部屋の約束どおりの形で出る")
    func decisionEncoding() throws {
        let request = MacControlRequest(
            requestID: "r1",
            jobID: "job-1",
            runID: "run-1",
            jobTitle: "画面を触って",
            scope: "whole_mac",
            note: "note"
        )
        let text = try MacControlOutgoing.decision(.allow, request: request)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "control.decision")
        #expect(object["request_id"] as? String == "r1")
        #expect(object["run_id"] as? String == "run-1")
        #expect(object["decision"] as? String == "allow")
    }

    @Test("撮影の op.result に画像が base64 で載る")
    func opResultCaptureEncoding() throws {
        let op = MacControlOpFrame(
            opID: "op-1",
            runID: "run-1",
            jobID: "job-1",
            kind: .capture,
            params: [:],
            expected: nil,
            sentAt: ""
        )
        let result = MacOpExecutionResult.makeSuccess(
            [
                "display_id": "1001",
                "width_px": 2,
                "height_px": 2,
                "scale": 1.0,
                "image_base64": "aGk=",
            ]
        )
        let text = try MacControlOutgoing.opResult(op: op, result: result)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "op.result")
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["image_base64"] as? String == "aGk=")
    }

    @Test("失敗の op.result は error だけを載せる")
    func opResultFailureEncoding() throws {
        let op = MacControlOpFrame(
            opID: "op-1",
            runID: "run-1",
            jobID: "job-1",
            kind: .click,
            params: [:],
            expected: nil,
            sentAt: ""
        )
        let text = try MacControlOutgoing.opResult(
            op: op,
            result: .failure(code: "permission.accessibility", message: "権限が無い")
        )
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "permission.accessibility")
    }

    @Test("画面構成の印は表示器の並びだけで決まる")
    func layoutTokenIsStable() {
        let displaysA = [
            MacDisplayInfo(
                displayID: "1",
                name: "A",
                widthPX: 2880,
                heightPX: 1800,
                scale: 2.0,
                bounds: MacRect(x: 0, y: 0, width: 1440, height: 900),
                layoutToken: ""
            ),
            MacDisplayInfo(
                displayID: "2",
                name: "B",
                widthPX: 2560,
                heightPX: 1440,
                scale: 2.0,
                bounds: MacRect(x: 1440, y: 0, width: 1280, height: 720),
                layoutToken: ""
            ),
        ]
        let displaysB = displaysA.reversed().map { display in
            var copy = display
            copy.name = "違う名前（印には不要）"
            return copy
        }
        let tokenA = MacDisplayInfo.layoutToken(for: displaysA)
        let tokenB = MacDisplayInfo.layoutToken(for: displaysB)
        #expect(tokenA == tokenB)
        #expect(tokenA.count == 16)
        // 解像度が変わると印も変わる。
        var changed = displaysA
        changed[0].widthPX = 1440
        #expect(MacDisplayInfo.layoutToken(for: changed) != tokenA)
    }

    @Test("撮影画像の端を越えた座標は表示器の中へ丸める")
    func pointClampsToDisplay() {
        let display = MacDisplayInfo(
            displayID: "1",
            name: "A",
            widthPX: 100,
            heightPX: 50,
            scale: 1.0,
            bounds: MacRect(x: 0, y: 0, width: 100, height: 50),
            layoutToken: ""
        )
        #expect(display.point(forPxX: 90, yPX: 40) == MacPoint(x: 90, y: 40))
        // 端点は画像の外に飛ばさない。
        let point = display.point(forPxX: 99_999, yPX: 99_999)
        #expect(point.x <= 99.999)
        #expect(point.y <= 49.999)
    }
}
