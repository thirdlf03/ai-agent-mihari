import Foundation

/// room ↔ desktop の voice Realtime 契約（`docs/voice-realtime-contract.md`）。
enum VoiceRealtimeProtocol {
    static let protocolVersion = 1

    enum EventType {
        static let sessionReady = "session.ready"
        static let historySync = "history.sync"
        static let inputAudio = "input.audio"
        static let inputImage = "input.image"
        static let userText = "user.text"
        static let assistantText = "assistant.text"
        static let assistantToolCall = "assistant.tool_call"
        static let error = "error"
        static let sessionClosed = "session.closed"
    }
}

/// `POST /voice/sessions` の応答。
struct VoiceSessionCreateResponse: Decodable, Equatable, Sendable {
    let sessionID: String
    let model: String
    let status: String
    let protocolVersion: Int
    let streamPath: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case model
        case status
        case protocolVersion = "protocol_version"
        case streamPath = "stream_path"
    }
}

/// `GET /voice/sessions/{id}` の応答。
struct VoiceSessionStatusResponse: Decodable, Equatable, Sendable {
    let sessionID: String
    let model: String
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case model
        case status
        case error
    }

    var isReconnectable: Bool {
        switch status {
        case "created", "streaming":
            return true
        default:
            return false
        }
    }
}

/// `history.sync` の 1 行。マイク音声は含めない。
struct VoiceHistorySyncEntry: Equatable, Sendable {
    let role: String
    let text: String
    let timestamp: Date
    let kind: String
    let toolName: String
    let toolArguments: String

    static func parse(from raw: [String: Any]) -> VoiceHistorySyncEntry? {
        guard let role = raw["role"] as? String else { return nil }
        let text = raw["text"] as? String ?? ""
        let ts: Double
        if let value = raw["ts"] as? Double {
            ts = value
        } else if let value = raw["ts"] as? NSNumber {
            ts = value.doubleValue
        } else {
            ts = 0
        }
        return VoiceHistorySyncEntry(
            role: role,
            text: text,
            timestamp: Date(timeIntervalSince1970: ts),
            kind: raw["kind"] as? String ?? "text",
            toolName: raw["tool_name"] as? String ?? "",
            toolArguments: raw["tool_arguments"] as? String ?? ""
        )
    }

    /// 会話 UI 用の 1 行に写す。room の履歴が正。
    func asConversationMessage() -> VoiceConversationMessage? {
        switch role {
        case "user":
            guard !text.isEmpty else { return nil }
            return VoiceConversationMessage(role: .user, text: text, timestamp: timestamp)
        case "assistant":
            if kind == "tool_call" {
                let label = toolName.isEmpty ? "（名前なし）" : toolName
                return VoiceConversationMessage(
                    role: .system,
                    text: "ツール呼び出し: \(label)",
                    timestamp: timestamp
                )
            }
            guard !text.isEmpty else { return nil }
            return VoiceConversationMessage(role: .assistant, text: text, timestamp: timestamp)
        default:
            return nil
        }
    }
}

/// room → client の 1 フレーム。
enum VoiceIncomingFrame: Equatable, Sendable {
    case sessionReady(sessionID: String, model: String)
    case historySync(messages: [VoiceHistorySyncEntry])
    case userText(text: String)
    case assistantText(delta: String, text: String, done: Bool)
    case assistantToolCall(name: String, callID: String, arguments: String)
    case error(code: String, message: String)
    case sessionClosed(reason: String)
    case unknown(type: String)

    static func parse(data: Data) -> VoiceIncomingFrame? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return nil
        }
        switch type {
        case VoiceRealtimeProtocol.EventType.sessionReady:
            return .sessionReady(
                sessionID: json["session_id"] as? String ?? "",
                model: json["model"] as? String ?? ""
            )
        case VoiceRealtimeProtocol.EventType.historySync:
            let rawMessages = json["messages"] as? [[String: Any]] ?? []
            let messages = rawMessages.compactMap(VoiceHistorySyncEntry.parse(from:))
            return .historySync(messages: messages)
        case VoiceRealtimeProtocol.EventType.userText:
            return .userText(text: json["text"] as? String ?? "")
        case VoiceRealtimeProtocol.EventType.assistantText:
            return .assistantText(
                delta: json["delta"] as? String ?? "",
                text: json["text"] as? String ?? "",
                done: json["done"] as? Bool ?? false
            )
        case VoiceRealtimeProtocol.EventType.assistantToolCall:
            return .assistantToolCall(
                name: json["name"] as? String ?? "",
                callID: json["call_id"] as? String ?? "",
                arguments: json["arguments"] as? String ?? ""
            )
        case VoiceRealtimeProtocol.EventType.error:
            return .error(
                code: json["code"] as? String ?? "voice_error",
                message: json["message"] as? String ?? "不明なエラー"
            )
        case VoiceRealtimeProtocol.EventType.sessionClosed:
            return .sessionClosed(reason: json["reason"] as? String ?? "")
        default:
            return .unknown(type: type)
        }
    }
}

/// client → room の outbound フレームを組み立てる。
enum VoiceOutgoingFrame {
    static func inputAudio(
        pcm16: Data,
        commit: Bool,
        createResponse: Bool
    ) throws -> String {
        let payload: [String: Any] = [
            "type": VoiceRealtimeProtocol.EventType.inputAudio,
            "audio_base64": pcm16.base64EncodedString(),
            "commit": commit,
            "create_response": createResponse,
        ]
        return try encode(payload)
    }

    /// マウスがあるディスプレイ 1 枚を room へ送る `input.image`。
    static func inputImage(
        png: Data,
        prompt: String,
        createResponse: Bool = true,
        mediaType: String = "image/png"
    ) throws -> String {
        let payload: [String: Any] = [
            "type": VoiceRealtimeProtocol.EventType.inputImage,
            "image_base64": png.base64EncodedString(),
            "media_type": mediaType,
            "prompt": prompt,
            "create_response": createResponse,
        ]
        return try encode(payload)
    }

    private static func encode(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceSessionError.encodingFailed
        }
        return text
    }
}

/// 会話履歴の 1 行。マイク音声ファイルは保存しない。
public struct VoiceConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    public let id: UUID
    public let role: Role
    /// `user.text` の文字起こしでプレースホルダを書き換えるため var にする。
    public var text: String
    public let timestamp: Date
    /// 画面送信時のサムネイル（PNG）。音声ファイルは保存しない。
    public let imageThumbnailPNG: Data?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        imageThumbnailPNG: Data? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.imageThumbnailPNG = imageThumbnailPNG
    }
}

/// 仕事が `waiting_for_input` のとき、会話 UI に出す質問。
public struct VoicePendingQuestion: Equatable, Sendable, Identifiable {
    public let jobID: String
    public let questionID: String
    public let prompt: String
    public let choices: [String]
    public let multiSelect: Bool

    public var id: String { questionID }

    public init(
        jobID: String,
        questionID: String,
        prompt: String,
        choices: [String] = [],
        multiSelect: Bool = false
    ) {
        self.jobID = jobID
        self.questionID = questionID
        self.prompt = prompt
        self.choices = choices
        self.multiSelect = multiSelect
    }

    init(room: RoomPendingQuestion, jobID: String) {
        self.jobID = jobID
        self.questionID = room.id
        self.prompt = room.question
        self.choices = room.choices ?? []
        self.multiSelect = room.multiSelect
    }
}

/// voice セッション API の失敗。
enum VoiceSessionError: Error, Equatable, Sendable {
    case invalidURL
    case requestFailed(status: Int, message: String)
    case encodingFailed
    case notReady
}

extension VoiceSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL を組み立てられない"
        case .requestFailed(let status, let message):
            return status == 0 ? message : "部屋がエラーを返した (\(status)): \(message)"
        case .encodingFailed:
            return "フレームを組み立てられない"
        case .notReady:
            return "セッションが準備できていない"
        }
    }
}
