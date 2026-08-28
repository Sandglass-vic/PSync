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
    let networkEndpoint: String
    let capabilities: [String]
    let controlPort: UInt16

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceId = "device_id"
        case displayName = "display_name"
        case avatarId = "avatar_id"
        case sessionId = "session_id"
        case joinCode
        case networkEndpoint = "network_endpoint"
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
    let transferPort: UInt16

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userName = "user_name"
        case avatarId = "avatar_id"
        case sessionId = "session_id"
        case joinCode
        case networkEndpoint = "network_endpoint"
        case capabilities
        case controlPort = "control_port"
        case transferPort = "transfer_port"
    }
}

struct JoinRequestPayload: Codable, Sendable {
    let device: DeviceInfoPayload
}

struct JoinLeavePayload: Codable, Sendable {
    let deviceId: String
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case reason
    }
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
    let transferPort: UInt16
    let isCoordinator: Bool
    let confirmed: Bool
    let joinedAt: TimeInterval

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userName = "user_name"
        case avatarId = "avatar_id"
        case networkEndpoint = "network_endpoint"
        case controlPort = "control_port"
        case transferPort = "transfer_port"
        case isCoordinator = "is_coordinator"
        case confirmed
        case joinedAt = "joined_at"
    }

    init(
        deviceId: String,
        userName: String,
        avatarId: Int,
        networkEndpoint: String,
        controlPort: UInt16,
        transferPort: UInt16 = 0,
        isCoordinator: Bool,
        confirmed: Bool,
        joinedAt: TimeInterval
    ) {
        self.deviceId = deviceId
        self.userName = userName
        self.avatarId = avatarId
        self.networkEndpoint = networkEndpoint
        self.controlPort = controlPort
        self.transferPort = transferPort
        self.isCoordinator = isCoordinator
        self.confirmed = confirmed
        self.joinedAt = joinedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        userName = try container.decode(String.self, forKey: .userName)
        avatarId = try container.decode(Int.self, forKey: .avatarId)
        networkEndpoint = try container.decode(String.self, forKey: .networkEndpoint)
        controlPort = try container.decode(UInt16.self, forKey: .controlPort)
        transferPort = try container.decodeIfPresent(UInt16.self, forKey: .transferPort) ?? 0
        isCoordinator = try container.decode(Bool.self, forKey: .isCoordinator)
        confirmed = try container.decode(Bool.self, forKey: .confirmed)
        joinedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .joinedAt) ?? 0
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

struct SessionPhasePayload: Codable, Sendable {
    let phase: String
}

struct SessionCompletePayload: Codable, Sendable {
    let deviceId: String
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
    let isLivePhoto: Bool

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case contentHash = "content_hash"
        case fileHash = "file_hash"
        case size
        case width
        case height
        case format
        case ownerDeviceId = "owner_device_id"
        case isLivePhoto = "is_live_photo"
    }

    init(
        photoId: String,
        contentHash: String,
        fileHash: String,
        size: Int64,
        width: Int,
        height: Int,
        format: String,
        ownerDeviceId: String,
        isLivePhoto: Bool = false
    ) {
        self.photoId = photoId
        self.contentHash = contentHash
        self.fileHash = fileHash
        self.size = size
        self.width = width
        self.height = height
        self.format = format
        self.ownerDeviceId = ownerDeviceId
        self.isLivePhoto = isLivePhoto
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photoId = try container.decode(String.self, forKey: .photoId)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        fileHash = try container.decode(String.self, forKey: .fileHash)
        size = try container.decode(Int64.self, forKey: .size)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        format = try container.decode(String.self, forKey: .format)
        ownerDeviceId = try container.decode(String.self, forKey: .ownerDeviceId)
        isLivePhoto = try container.decodeIfPresent(Bool.self, forKey: .isLivePhoto) ?? false
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

/// 数据面帧：`transferId|contentHash|totalSize|pairedVideoSize|stillName|videoName\n` + 字节
enum PhotoTransferFrame {
    struct Header: Equatable, Sendable {
        let transferId: String
        let contentHash: String
        let totalSize: Int64
        let pairedVideoSize: Int64
        let stillFilename: String?
        let pairedVideoFilename: String?
    }

    static func encode(
        transferId: String,
        contentHash: String,
        stillData: Data,
        pairedVideoData: Data = Data(),
        stillFilename: String? = nil,
        pairedVideoFilename: String? = nil
    ) -> Data {
        var body = stillData
        body.append(pairedVideoData)
        let stillName = encodeField(stillFilename ?? "")
        let videoName = encodeField(pairedVideoFilename ?? "")
        var payload = Data(
            "\(transferId)|\(contentHash)|\(body.count)|\(pairedVideoData.count)|\(stillName)|\(videoName)\n".utf8
        )
        payload.append(body)
        return payload
    }

    static func encode(transferId: String, contentHash: String, body: Data) -> Data {
        encode(transferId: transferId, contentHash: contentHash, stillData: body)
    }

    static func parse(_ buffer: Data) -> (header: Header, body: Data)? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        let headerData = buffer[..<newlineIndex]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let parts = header.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let totalSize = Int64(parts[2]) else { return nil }
        let pairedVideoSize: Int64
        if parts.count >= 4, let parsedVideoSize = Int64(parts[3]) {
            pairedVideoSize = parsedVideoSize
        } else {
            pairedVideoSize = 0
        }
        let stillFilename = parts.count >= 5 ? decodeField(String(parts[4])) : nil
        let pairedVideoFilename = parts.count >= 6 ? decodeField(String(parts[5])) : nil
        return (
            Header(
                transferId: String(parts[0]),
                contentHash: String(parts[1]),
                totalSize: totalSize,
                pairedVideoSize: pairedVideoSize,
                stillFilename: stillFilename,
                pairedVideoFilename: pairedVideoFilename
            ),
            Data(buffer[(newlineIndex + 1)...])
        )
    }

    static func splitPayload(_ body: Data, header: Header) -> (still: Data, pairedVideo: Data?) {
        let videoSize = Int(header.pairedVideoSize)
        guard videoSize > 0, body.count >= videoSize else {
            return (body, nil)
        }
        let stillCount = body.count - videoSize
        return (
            Data(body.prefix(stillCount)),
            Data(body.suffix(videoSize))
        )
    }

    private static func encodeField(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func decodeField(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return value.removingPercentEncoding ?? value
    }
}
