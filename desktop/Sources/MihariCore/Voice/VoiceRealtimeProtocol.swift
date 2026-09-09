import Foundation

/// room ↔ desktop の voice Realtime 契約（`docs/voice-realtime-contract.md`）。
enum VoiceRealtimeProtocol {
    static let protocolVersion = 1

    enum EventType {
        static let sessionReady = "session.ready"
        static let inputAudio = "input.audio"
        static let inputImage = "input.image"
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

/// room → client の 1 フレーム。
enum VoiceIncomingFrame: Equatable, Sendable {
    case sessionReady(sessionID: String, model: String)
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

/// client → room の `input.audio` を組み立てる。
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
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceSessionError.encodingFailed
        }
        return text
    }
}

/// 会話履歴の 1 行。マイク音声ファイルは保存しない。
struct VoiceConversationMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
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
