import Foundation

struct ProtocolEnvelope: Codable, Sendable {
    let protocolVersion: Int
    let messageType: MessageType
    let messageId: String
    let sessionId: String?
    let deviceId: String
    let sequenceNumber: Int
    let timestamp: TimeInterval
    let payload: Data

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageType = "message_type"
        case messageId = "message_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case sequenceNumber = "sequence_number"
        case timestamp
        case payload
    }

    init(
        messageType: MessageType,
        deviceId: String,
        sessionId: String? = nil,
        sequenceNumber: Int = 0,
        payload: Encodable
    ) throws {
        self.protocolVersion = ProtocolConstants.protocolVersion
        self.messageType = messageType
        self.messageId = UUID().uuidString
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.sequenceNumber = sequenceNumber
        self.timestamp = Date().timeIntervalSince1970
        self.payload = try JSONEncoder.psync.encode(payload)
    }

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.psync.decode(T.self, from: payload)
    }
}

struct DiscoveryAdvertisementPayload: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let deviceId: String
    let displayName: String
    let avatarId: Int
    let sessionId: String
    let joinCode: String
    let capabilities: [String]
    let controlPort: UInt16

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceId = "device_id"
        case displayName = "display_name"
        case avatarId = "avatar_id"
        case sessionId = "session_id"
        case joinCode
        case capabilities
        case controlPort = "control_port"
    }
}

struct DeviceInfoPayload: Codable, Sendable, Equatable {
    let deviceId: String
    let userName: String
    let avatarId: Int
    let sessionId: String
    let joinCode: String
    let networkEndpoint: String
    let capabilities: [String]
    let controlPort: UInt16

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userName = "user_name"
        case avatarId = "avatar_id"
        case sessionId = "session_id"
        case joinCode
        case networkEndpoint = "network_endpoint"
        case capabilities
        case controlPort = "control_port"
    }
}

struct JoinRequestPayload: Codable, Sendable {
    let device: DeviceInfoPayload
}

struct JoinAcceptPayload: Codable, Sendable {
    let accepted: Bool
    let coordinatorDeviceId: String
    let members: [MemberPayload]
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case accepted
        case coordinatorDeviceId = "coordinator_device_id"
        case members
        case reason
    }
}

struct MemberPayload: Codable, Sendable, Equatable, Identifiable {
    let deviceId: String
    let userName: String
    let avatarId: Int
    let networkEndpoint: String
    let controlPort: UInt16
    let isCoordinator: Bool
    let confirmed: Bool

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userName = "user_name"
        case avatarId = "avatar_id"
        case networkEndpoint = "network_endpoint"
        case controlPort = "control_port"
        case isCoordinator = "is_coordinator"
        case confirmed
    }
}

struct MembershipUpdatePayload: Codable, Sendable {
    let members: [MemberPayload]
    let securityCode: String

    enum CodingKeys: String, CodingKey {
        case members
        case securityCode = "security_code"
    }
}

struct SecurityCodePayload: Codable, Sendable {
    let securityCode: String

    enum CodingKeys: String, CodingKey {
        case securityCode = "security_code"
    }
}

struct SecurityConfirmPayload: Codable, Sendable {
    let confirmed: Bool
}

struct PhotoManifestPayload: Codable, Sendable {
    let photos: [PhotoMetadataPayload]
}

struct PhotoMetadataPayload: Codable, Sendable, Equatable {
    let photoId: String
    let contentHash: String
    let fileHash: String
    let size: Int64
    let width: Int
    let height: Int
    let format: String
    let ownerDeviceId: String

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case contentHash = "content_hash"
        case fileHash = "file_hash"
        case size
        case width
        case height
        case format
        case ownerDeviceId = "owner_device_id"
    }
}

struct GlobalPhotoEntryPayload: Codable, Sendable, Equatable {
    let contentHash: String
    let owners: [String]
    let size: Int64
    let transferStatus: TransferState
    let requiredBy: [String]
    let availableSources: [String]

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case owners
        case size
        case transferStatus = "transfer_status"
        case requiredBy = "required_by"
        case availableSources = "available_sources"
    }
}

struct TransferPlanPayload: Codable, Sendable {
    let tasks: [TransferTaskPayload]
}

struct TransferTaskPayload: Codable, Sendable, Equatable {
    let transferId: String
    let contentHash: String
    let sourceDeviceId: String
    let destinationDeviceId: String
    let photoSize: Int64
    let state: TransferState
    let version: Int
    let dependencyTransferIds: [String]

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case contentHash = "content_hash"
        case sourceDeviceId = "source_device_id"
        case destinationDeviceId = "destination_device_id"
        case photoSize = "photo_size"
        case state
        case version
        case dependencyTransferIds = "dependency_transfer_ids"
    }
}

struct TransferAssignPayload: Codable, Sendable {
    let task: TransferTaskPayload
}

struct TransferStartPayload: Codable, Sendable {
    let transferId: String
    let contentHash: String
    let totalSize: Int64
    let chunkSize: Int

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case contentHash
        case totalSize = "total_size"
        case chunkSize = "chunk_size"
    }
}

struct TransferChunkPayload: Codable, Sendable {
    let transferId: String
    let chunkIndex: Int
    let offset: Int64
    let data: Data
    let isLast: Bool

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case chunkIndex = "chunk_index"
        case offset
        case data
        case isLast = "is_last"
    }
}

struct TransferCompletePayload: Codable, Sendable {
    let transferId: String
    let contentHash: String
    let fileHash: String

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case contentHash
        case fileHash = "file_hash"
    }
}

struct TransferVerifyPayload: Codable, Sendable {
    let transferId: String
    let verified: Bool
    let receivedHash: String

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case verified
        case receivedHash = "received_hash"
    }
}

struct TransferFailedPayload: Codable, Sendable {
    let transferId: String
    let reason: TransferFailureReason
}

struct AckPayload: Codable, Sendable {
    let ackMessageId: String

    enum CodingKeys: String, CodingKey {
        case ackMessageId = "ack_message_id"
    }
}

extension JSONEncoder {
    static let psync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let psync: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

enum ProtocolCodec {
    static func encode(_ envelope: ProtocolEnvelope) throws -> Data {
        var data = try JSONEncoder.psync.encode(envelope)
        data.append(0x0A) // newline delimiter
        return data
    }

    static func decodeMessages(from buffer: inout Data) throws -> [ProtocolEnvelope] {
        var envelopes: [ProtocolEnvelope] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(0...newlineIndex)
            if line.isEmpty { continue }
            let envelope = try JSONDecoder.psync.decode(ProtocolEnvelope.self, from: line)
            envelopes.append(envelope)
        }
        return envelopes
    }
}
