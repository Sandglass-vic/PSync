import Foundation

enum ProtocolConstants {
    static let protocolVersion = 1
    static let maxMembers = 8
    static let joinCodeLength = 4

    // Bonjour + BLE discovery (iOS, AirDrop-like)
    static let bonjourServiceType = "_psync._tcp"

    // Legacy UDP discovery (unused on iOS)
    static let discoveryPort: UInt16 = 9876
    static let discoveryBroadcastInterval: TimeInterval = 0.5
    static let discoveryTimeout: TimeInterval = 3.0
    static let discoveryDedupeTTL: TimeInterval = 2.0

    // Multicast fallback
    static let multicastGroup = "239.255.77.88"
    static let multicastPort: UInt16 = 9877

    // Transfer
    static let defaultChunkSize = 256 * 1024
    static let maxUploadConnections = 1
    static let maxDownloadConnections = 3
    static let controlMessageTimeout: TimeInterval = 10.0
    static let transferMessageTimeout: TimeInterval = 30.0
    static let coordinatorHeartbeatInterval: TimeInterval = 2.0
    static let coordinatorFailoverTimeout: TimeInterval = 6.0

    // Performance targets
    static let discoveryTargetP95: TimeInterval = 3.0
    static let joinSessionTarget: TimeInterval = 1.0
}

enum MessageType: String, Codable, CaseIterable {
    // Discovery
    case discover
    case advertisement

    // Session
    case joinRequest = "join_request"
    case joinAccept = "join_accept"
    case joinLeave = "join_leave"
    case membershipUpdate = "membership_update"
    case sessionPhase = "session_phase"

    // Security
    case securityCode = "security_code"
    case securityConfirm = "security_confirm"
    case securityStatus = "security_status"

    // Metadata
    case photoManifest = "photo_manifest"
    case photoManifestDiff = "photo_manifest_diff"
    case photoMetadataUpdate = "photo_metadata_update"

    // Scheduling
    case transferRequest = "transfer_request"
    case transferPlan = "transfer_plan"
    case transferAssign = "transfer_assign"
    case transferCancel = "transfer_cancel"
    case transferReassign = "transfer_reassign"

    // Transfer
    case transferStart = "transfer_start"
    case transferChunk = "transfer_chunk"
    case transferComplete = "transfer_complete"
    case transferVerify = "transfer_verify"
    case transferFailed = "transfer_failed"

    // Session lifecycle
    case sessionComplete = "session_complete"
    case sessionFailed = "session_failed"
    case sessionCancel = "session_cancel"

    // Control
    case ack
    case coordinatorHeartbeat = "coordinator_heartbeat"
    case coordinatorElection = "coordinator_election"
    case coordinatorElected = "coordinator_elected"
}

enum TransferState: String, Codable {
    case pending
    case scheduled
    case transferring
    case verified
    case completed
    case failed
    case rescheduled
    case cancelled
}

enum TransferFailureReason: String, Codable {
    case sourceUnavailable = "source_unavailable"
    case destinationUnavailable = "destination_unavailable"
    case connectionTimeout = "connection_timeout"
    case hashMismatch = "hash_mismatch"
    case insufficientStorage = "insufficient_storage"
    case userCancelled = "user_cancelled"
    case sessionCancelled = "session_cancelled"
}
