import Foundation
import UIKit

struct DeviceIdentity: Codable, Sendable, Equatable {
    let deviceId: String
    var userName: String
    var avatarId: Int

    static func loadOrCreate() -> DeviceIdentity {
        let key = "psync.device.identity"
        if let data = UserDefaults.standard.data(forKey: key),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return identity
        }
        let defaultName = UIDevice.current.name
        let avatarId = Int.random(in: 0..<8)
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString,
            userName: defaultName,
            avatarId: avatarId
        )
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return identity
    }

    func save() {
        let key = "psync.device.identity"
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct SharingMember: Identifiable, Equatable, Sendable {
    let deviceId: String
    var userName: String
    var avatarId: Int
    var networkEndpoint: String
    var controlPort: UInt16
    var isCoordinator: Bool
    var confirmed: Bool
    var discoveredAt: Date

    var id: String { deviceId }

    init(from payload: MemberPayload) {
        self.deviceId = payload.deviceId
        self.userName = payload.userName
        self.avatarId = payload.avatarId
        self.networkEndpoint = payload.networkEndpoint
        self.controlPort = payload.controlPort
        self.isCoordinator = payload.isCoordinator
        self.confirmed = payload.confirmed
        self.discoveredAt = Date()
    }

    init(
        deviceId: String,
        userName: String,
        avatarId: Int,
        networkEndpoint: String,
        controlPort: UInt16,
        isCoordinator: Bool,
        confirmed: Bool,
        discoveredAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.userName = userName
        self.avatarId = avatarId
        self.networkEndpoint = networkEndpoint
        self.controlPort = controlPort
        self.isCoordinator = isCoordinator
        self.confirmed = confirmed
        self.discoveredAt = discoveredAt
    }

    func toPayload() -> MemberPayload {
        MemberPayload(
            deviceId: deviceId,
            userName: userName,
            avatarId: avatarId,
            networkEndpoint: networkEndpoint,
            controlPort: controlPort,
            isCoordinator: isCoordinator,
            confirmed: confirmed
        )
    }
}

struct LocalPhoto: Identifiable, Equatable, Sendable {
    let id: String
    let contentHash: String
    let fileHash: String
    let size: Int64
    let width: Int
    let height: Int
    let format: String
    let thumbnailData: Data?
    let fileURL: URL?

    func toMetadata(ownerDeviceId: String) -> PhotoMetadataPayload {
        PhotoMetadataPayload(
            photoId: id,
            contentHash: contentHash,
            fileHash: fileHash,
            size: size,
            width: width,
            height: height,
            format: format,
            ownerDeviceId: ownerDeviceId
        )
    }
}

struct ReceivedPhoto: Identifiable, Equatable, Sendable {
    let id: String
    let contentHash: String
    let thumbnailData: Data?
    let sourceUserName: String
    let sourceDeviceId: String
}

struct GlobalPhotoEntry: Equatable, Sendable {
    let contentHash: String
    var owners: Set<String>
    let size: Int64
    var transferStatus: TransferState
    var requiredBy: Set<String>
    var availableSources: Set<String>
}

struct TransferTask: Identifiable, Equatable, Sendable {
    let transferId: String
    let contentHash: String
    let sourceDeviceId: String
    let destinationDeviceId: String
    let photoSize: Int64
    var state: TransferState
    var version: Int
    var dependencyTransferIds: [String]
    var bytesTransferred: Int64

    var id: String { transferId }

    func toPayload() -> TransferTaskPayload {
        TransferTaskPayload(
            transferId: transferId,
            contentHash: contentHash,
            sourceDeviceId: sourceDeviceId,
            destinationDeviceId: destinationDeviceId,
            photoSize: photoSize,
            state: state,
            version: version,
            dependencyTransferIds: dependencyTransferIds
        )
    }
}

enum SharingPhase: Equatable, Sendable {
    case idle
    case discovering
    case waitingConfirmation
    case syncingMetadata
    case transferring
    case completed
    case failed(String)
}

struct SharingSessionState: Sendable {
    var sessionId: String?
    var joinCode: String?
    var securityCode: String?
    var members: [SharingMember] = []
    var coordinatorDeviceId: String?
    var phase: SharingPhase = .idle
    var photosToReceive: Int = 0
    var photosReceived: Int = 0
    var receivedPhotos: [ReceivedPhoto] = []
    var localPhotos: [LocalPhoto] = []
}
