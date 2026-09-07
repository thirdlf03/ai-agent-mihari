import CommonCrypto
import Foundation

/// Room ↔ Mac の mac-control の線上の約束。
///
/// フレームは `{"type": ...}` の JSON テキストで、`room/src/mihari_room/mac_control/protocol.py`
/// と対にする。位置や数の不整合は hub(Python 側)が検証するので、こちらは約束に素直に従う。
public enum MacControlWire {

    /// 線上のプロトコル版。互換のない変更で上げる。
    public static let protocolVersion = 1
    /// テキスト入力の上限。hub と同じ。
    public static let maxTextChars = 4000

    public enum FrameType: String, Sendable {
        // Room → Mac
        case helloAck = "hello_ack"
        case ping = "ping"
        case controlRequest = "control.request"
        case op = "op"
        case cancelRun = "cancel_run"
        // Mac → Room
        case hello = "hello"
        case pong = "pong"
        case controlDecision = "control.decision"
        case opResult = "op.result"
        case state = "state"
        case displays = "displays"
    }

    public enum OpKind: String, Sendable {
        case capture
        case click
        case doubleClick = "double_click"
        case drag
        case scroll
        case typeText = "type_text"
        case key
        case activateApp = "activate_app"
    }

    public enum StateEvent: String, Sendable {
        case lock
        case unlock
        case quit
        case stop
        case revoke
    }

    public enum Decision: String, Sendable {
        case allow
        case deny
    }
}

/// 表示器 1 台分の画面構成。hello / displays / 撮影結果 / 操作 expected で使う。
public struct MacDisplayInfo: Codable, Equatable, Sendable {
    public var displayID: String
    public var name: String
    public var widthPX: Int
    public var heightPX: Int
    public var scale: Double
    public var bounds: MacRect
    public var layoutToken: String

    enum CodingKeys: String, CodingKey {
        case displayID = "display_id"
        case name
        case widthPX = "width_px"
        case heightPX = "height_px"
        case scale
        case bounds
        case layoutToken = "layout_token"
    }

    public init(
        displayID: String,
        name: String,
        widthPX: Int,
        heightPX: Int,
        scale: Double,
        bounds: MacRect,
        layoutToken: String
    ) {
        self.displayID = displayID
        self.name = name
        self.widthPX = widthPX
        self.heightPX = heightPX
        self.scale = scale
        self.bounds = bounds
        self.layoutToken = layoutToken
    }

    /// 撮影画像のピクセル座標を、メインディスプレイ左上原点の点へ変換する。
    ///
    /// `room/src/mihari_room/mac_control/display.py` の `px_to_point` と同じ式。
    public func point(forPxX xPX: Int, yPX: Int) -> MacPoint {
        MacPoint(
            x: bounds.x + Double(xPX.clamped(0, widthPX - 1)) / scale,
            y: bounds.y + Double(yPX.clamped(0, heightPX - 1)) / scale
        )
    }
}

/// CGDisplayBounds 相当の点。原点はメインディスプレイ左上。
public struct MacRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 点。CGEvent へ渡す前に CGPoint へ写す。
public struct MacPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension MacDisplayInfo {

    /// 表示器の並び（id・解像度・bounds）から画面構成の印を作る。
    ///
    /// hub 側の `display_layout_token` と同じ方式（sha256 の先頭 16 文字）にして、
    /// 撮影結果と操作時点の突き合わせが疎通できるようにする。
    public static func layoutToken(for displays: [MacDisplayInfo]) -> String {
        let rows =
            displays
            .sorted { $0.displayID < $1.displayID }
            .map { display in
                [
                    display.displayID,
                    String(display.widthPX),
                    String(display.heightPX),
                    String(display.scale),
                    String(display.bounds.x),
                    String(display.bounds.y),
                    String(display.bounds.width),
                    String(display.bounds.height),
                ]
                .joined(separator: ":")
            }
            .joined(separator: "\n")
        let digest = sha256Hex(rows)
        return String(digest.prefix(16))
    }

    private static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// 操作の expected（撮影時点の画面構成）。hub が op フレームに載せる。
public struct MacExpectedLayout: Codable, Equatable, Sendable {
    public var displayID: String
    public var widthPX: Int
    public var heightPX: Int
    public var scale: Double
    public var bounds: MacRect
    public var layoutToken: String

    enum CodingKeys: String, CodingKey {
        case displayID = "display_id"
        case widthPX = "width_px"
        case heightPX = "height_px"
        case scale
        case bounds
        case layoutToken = "layout_token"
    }

    /// 撮影画像のピクセル座標を、メインディスプレイ左上原点の点へ変換する。
    public func point(forPxX xPX: Int, yPX: Int) -> MacPoint {
        let x = Double(xPX.clamped(0, widthPX - 1))
        let y = Double(yPX.clamped(0, heightPX - 1))
        return MacPoint(
            x: bounds.x + x / scale,
            y: bounds.y + y / scale
        )
    }
}

/// JSON の数値・文字列を型のまま読むための入れ物。
///
/// 座標は整数で届くが、JSON は整数も浮動小数も number で表現されるため、
/// 片方に寄せずに Double で受けてから整数へ丸める。
public enum MacJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MacJSONValue])
    case object([String: MacJSONValue])

    public func string() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public func int() -> Int? {
        switch self {
        case .number(let value): return Int(value.rounded())
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public func double() -> Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public func stringArray() -> [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { $0.string() }
    }

    public func boolValue() -> Bool? {
        switch self {
        case .bool(let value): return value
        default: return nil
        }
    }
}

extension MacJSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([MacJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: MacJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "読めない JSON 値"
            )
        }
    }
}

extension MacJSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let items): try container.encode(items)
        case .object(let object): try container.encode(object)
        }
    }
}

// MARK: - 届いたフレーム

/// 届いたフレームの型別の入れ物。hub が送るのはこの 5 種だけ。
public enum MacControlIncomingFrame: Sendable {
    case helloAck(deviceID: String)
    case ping(ts: String?)
    case controlRequest(MacControlRequest)
    case op(MacControlOpFrame)
    case cancelRun(runID: String, jobID: String)

    public static func parse(data: Data) throws -> (selfType: MacControlWire.FrameType, frame: MacControlIncomingFrame)?
    {
        let wire = try JSONDecoder().decode(MacControlWireFrame.self, from: data)
        guard let rawType = wire.type, let type = MacControlWire.FrameType(rawValue: rawType) else {
            return nil
        }
        switch type {
        case .helloAck:
            return (type, .helloAck(deviceID: wire.deviceId ?? ""))
        case .ping:
            return (type, .ping(ts: wire.ts))
        case .controlRequest:
            return (
                type,
                .controlRequest(
                    MacControlRequest(
                        requestID: wire.requestId ?? "",
                        jobID: wire.jobId ?? "",
                        runID: wire.runId ?? "",
                        jobTitle: wire.jobTitle ?? "",
                        scope: wire.scope ?? "",
                        note: wire.note ?? ""
                    )
                )
            )
        case .op:
            let expected: MacExpectedLayout?
            if let raw = wire.expected {
                expected = MacExpectedLayout(
                    displayID: raw.displayID ?? "",
                    widthPX: raw.widthPX ?? 0,
                    heightPX: raw.heightPX ?? 0,
                    scale: raw.scale ?? 1,
                    bounds: MacRect(
                        x: raw.bounds?.x ?? 0,
                        y: raw.bounds?.y ?? 0,
                        width: raw.bounds?.width ?? 0,
                        height: raw.bounds?.height ?? 0
                    ),
                    layoutToken: raw.layoutToken ?? ""
                )
            } else {
                expected = nil
            }
            return (
                type,
                .op(
                    MacControlOpFrame(
                        opID: wire.opId ?? "",
                        runID: wire.runId ?? "",
                        jobID: wire.jobId ?? "",
                        kind: MacControlWire.OpKind(rawValue: wire.kind ?? "") ?? .click,
                        params: wire.params ?? [:],
                        expected: expected,
                        sentAt: wire.sentAt ?? ""
                    )
                )
            )
        case .cancelRun:
            return (type, .cancelRun(runID: wire.runId ?? "", jobID: wire.jobId ?? ""))
        default:
            return nil
        }
    }
}

/// 届いた 1 フレーム。フィールドは全部任意にして、type の違いは呼び出し側で読む。
private struct MacControlWireFrame: Decodable {
    let type: String?
    let ts: String?
    let deviceId: String?
    let requestId: String?
    let jobId: String?
    let runId: String?
    let jobTitle: String?
    let scope: String?
    let note: String?
    let opId: String?
    let kind: String?
    let params: [String: MacJSONValue]?
    let expected: MacControlWireExpected?
    let sentAt: String?

    enum CodingKeys: String, CodingKey {
        case type
        case ts
        case deviceId = "device_id"
        case requestId = "request_id"
        case jobId = "job_id"
        case runId = "run_id"
        case jobTitle = "job_title"
        case scope
        case note
        case opId = "op_id"
        case kind
        case params
        case expected
        case sentAt = "sent_at"
    }

    struct MacControlWireExpected: Decodable {
        let displayID: String?
        let widthPX: Int?
        let heightPX: Int?
        let scale: Double?
        let bounds: MacControlWireBounds?
        let layoutToken: String?

        enum CodingKeys: String, CodingKey {
            case displayID = "display_id"
            case widthPX = "width_px"
            case heightPX = "height_px"
            case scale
            case bounds
            case layoutToken = "layout_token"
        }
    }

    struct MacControlWireBounds: Decodable {
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }
}

/// 許可を求める 1 フレーム。
public struct MacControlRequest: Sendable, Equatable {
    public let requestID: String
    public let jobID: String
    public let runID: String
    public let jobTitle: String
    public let scope: String
    public let note: String

    public init(
        requestID: String,
        jobID: String,
        runID: String,
        jobTitle: String,
        scope: String,
        note: String
    ) {
        self.requestID = requestID
        self.jobID = jobID
        self.runID = runID
        self.jobTitle = jobTitle
        self.scope = scope
        self.note = note
    }
}

/// 操作 1 本。
public struct MacControlOpFrame: Sendable {
    public let opID: String
    public let runID: String
    public let jobID: String
    public let kind: MacControlWire.OpKind
    public let params: [String: MacJSONValue]
    public let expected: MacExpectedLayout?
    public let sentAt: String

    public init(
        opID: String,
        runID: String,
        jobID: String,
        kind: MacControlWire.OpKind,
        params: [String: MacJSONValue],
        expected: MacExpectedLayout?,
        sentAt: String
    ) {
        self.opID = opID
        self.runID = runID
        self.jobID = jobID
        self.kind = kind
        self.params = params
        self.expected = expected
        self.sentAt = sentAt
    }

    // MARK: パラメータの読み口（hub が正規化済みの値を送ってくる）
    public var displayID: String? { params["display_id"]?.string() }
    public var xPX: Int? { params["x"]?.int() }
    public var yPX: Int? { params["y"]?.int() }
    public var fromXPX: Int? { params["from_x"]?.int() }
    public var fromYPX: Int? { params["from_y"]?.int() }
    public var toXPX: Int? { params["to_x"]?.int() }
    public var toYPX: Int? { params["to_y"]?.int() }
    public var deltaX: Double? { params["delta_x"]?.double() }
    public var deltaY: Double? { params["delta_y"]?.double() }
    public var text: String? { params["text"]?.string() }
    public var keyName: String? { params["key"]?.string() }
    public var keycode: Int? { params["keycode"]?.int() }
    public var bundleID: String? { params["bundle_id"]?.string() }
    public var appName: String? { params["app_name"]?.string() }
    public var button: String { params["button"]?.string() ?? "left" }
    public var modifiers: [String] { params["modifiers"]?.stringArray() ?? [] }

    /// 操作座標を表に出せる点へ変換する。撮影の expected が要る。
    public func point(fromX: Int? = nil, fromY: Int? = nil, toX: Int? = nil, toY: Int? = nil) -> MacPoint? {
        guard let expected else { return nil }
        let pxX = toX ?? fromX
        let pxY = toY ?? fromY
        guard let pxX, let pxY else { return nil }
        return expected.point(forPxX: pxX, yPX: pxY)
    }
}

// MARK: - 送るフレームの組み立て

public enum MacControlOutgoing {

    /// hello。最初に出す。
    public static func hello(endpoint: MacControlEndpoint, identity: MacControlIdentity, displays: [MacDisplayInfo])
        throws -> String
    {
        try json(
            [
                "type": MacControlWire.FrameType.hello.rawValue,
                "device_id": identity.deviceID,
                "hostname": identity.hostname,
                "app_version": identity.appVersion,
                "os_version": identity.osVersion,
                "displays": displays.map(\.wireDictionary),
            ]
        )
    }

    /// ping への応答。
    public static func pong(ts: String?) throws -> String {
        try json(["type": MacControlWire.FrameType.pong.rawValue, "ts": ts ?? ""])
    }

    /// 許可の回答。既定は拒否。許すのは「この依頼の間だけ」。
    public static func decision(_ decision: MacControlWire.Decision, request: MacControlRequest) throws -> String {
        try json(
            [
                "type": MacControlWire.FrameType.controlDecision.rawValue,
                "request_id": request.requestID,
                "job_id": request.jobID,
                "run_id": request.runID,
                "decision": decision.rawValue,
            ]
        )
    }

    /// 操作の結果。撮影は画像を base64 で載せる。
    public static func opResult(op: MacControlOpFrame, result: MacOpExecutionResult) throws -> String {
        var payload: [String: Any] = [
            "type": MacControlWire.FrameType.opResult.rawValue,
            "op_id": op.opID,
            "run_id": op.runID,
            "kind": op.kind.rawValue,
        ]
        switch result {
        case .success(let value):
            payload["ok"] = true
            let data = try JSONEncoder().encode(value)
            payload["result"] = try JSONSerialization.jsonObject(with: data)
        case .failure(let code, let message):
            payload["ok"] = false
            payload["error"] = ["code": code, "message": message]
        }
        return try json(payload)
    }

    /// 状態の変化（ロック・終了・停止・取り消し）。
    public static func state(_ event: MacControlWire.StateEvent, runID: String = "", message: String = "") throws
        -> String
    {
        var payload: [String: Any] = [
            "type": MacControlWire.FrameType.state.rawValue,
            "event": event.rawValue,
        ]
        if !runID.isEmpty { payload["run_id"] = runID }
        if !message.isEmpty { payload["message"] = message }
        return try json(payload)
    }

    /// 画面構成の変化（アンロック・表示器の抜き差し）。
    public static func displays(_ displays: [MacDisplayInfo]) throws -> String {
        try json(
            [
                "type": MacControlWire.FrameType.displays.rawValue,
                "displays": displays.map(\.wireDictionary),
            ]
        )
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacControlWireError.encodingFailed
        }
        return text
    }
}

public enum MacControlWireError: Error, Sendable {
    case encodingFailed
}

extension MacDisplayInfo {
    /// 線に出す形。
    var wireDictionary: [String: Any] {
        [
            "display_id": displayID,
            "name": name,
            "width_px": widthPX,
            "height_px": heightPX,
            "scale": scale,
            "bounds": ["x": bounds.x, "y": bounds.y, "width": bounds.width, "height": bounds.height],
            "layout_token": layoutToken,
        ]
    }
}

/// 操作の実行結果。op.result の ok / error に写す。
///
/// 成功の値は JSON プレーン（文字列・数値・真偽・入れ子）だけ。`Sendable` を保つため
/// `MacJSONValue` へ正規化して持つ。
public enum MacOpExecutionResult: Sendable {
    case success([String: MacJSONValue])
    case failure(code: String, message: String)

    /// 混在値の辞書（`"width_px": 2880` のような書きやすさ）から作る。
    /// 値が JSON にできない場合は失敗として返す（通常は起きない）。
    public static func makeSuccess(_ object: [String: Any]) -> MacOpExecutionResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode([String: MacJSONValue].self, from: data)
            return .success(decoded)
        } catch {
            return .failure(code: "internal_encoding", message: "操作結果を JSON にできなかった")
        }
    }
}

extension Int {
    fileprivate func clamped(_ lower: Int, _ upper: Int) -> Int {
        Swift.min(Swift.max(self, lower), upper)
    }
}
