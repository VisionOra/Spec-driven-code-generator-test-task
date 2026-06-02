import Foundation

struct WireMessage: Codable {
    let id: String
    let fromUser: String
    let to: String
    let text: String
    let timestamp: Int64
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case fromUser = "from"
        case to
        case text
        case timestamp
        case status
    }
}

enum QueuedStatus: String, Codable {
    case pending
    case sending
    case sent
    case failed
}

struct QueuedMessage: Codable {
    let localId: String
    var serverId: String?
    let toUser: String
    let text: String
    let queuedAt: Int64
    var status: QueuedStatus
}

struct RegisterResponse: Codable {
    let userId: String
    let username: String
}

struct LoginResponse: Codable {
    let userId: String
    let username: String
    let sessionId: String
}

struct SendResponse: Codable {
    let id: String
    let timestamp: Int64
}

struct MessagesResponse: Codable {
    let messages: [WireMessage]
    let serverTimestamp: Int64
}
