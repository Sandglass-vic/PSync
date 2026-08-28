import Foundation

/// Coordinator 服务 - 中心化 Metadata + Scheduling
final class CoordinatorService: @unchecked Sendable {
    let registry = GlobalPhotoRegistry()
    let scheduler: TransferScheduler
    private var members: [SharingMember] = []
    private var memberConfirmations: [String: Bool] = [:]
    private var heartbeatTimer: Timer?
    private let lock = NSLock()

    init() {
        scheduler = TransferScheduler(registry: registry)
    }

    func setMembers(_ members: [SharingMember]) {
        lock.lock()
        self.members = members
        lock.unlock()
    }

    func handlePhotoManifest(from deviceId: String, photos: [PhotoMetadataPayload]) {
        registry.ingestManifest(from: deviceId, photos: photos)
    }

    func allManifestsReceived(expectedCount: Int, receivedCount: Int) -> Bool {
        receivedCount >= expectedCount
    }

    func generateTransferPlan() -> [TransferTask] {
        lock.lock()
        let memberIds = members.map(\.deviceId)
        lock.unlock()
        return scheduler.generatePlan(members: memberIds)
    }

    func computePhotosToReceive(for deviceId: String) -> Int {
        registry.computeDiff(for: deviceId).required.count
    }

    func handleConfirmation(from deviceId: String, confirmed: Bool) {
        lock.lock()
        memberConfirmations[deviceId] = confirmed
        lock.unlock()
    }

    func allConfirmed(members: [SharingMember]) -> Bool {
        guard !members.isEmpty else { return false }
        return members.allSatisfy(\.confirmed)
    }

    func resetConfirmations() {
        lock.lock()
        memberConfirmations.removeAll()
        for i in members.indices {
            members[i].confirmed = false
        }
        lock.unlock()
    }

    func reset() {
        registry.reset()
        scheduler.reset()
        lock.lock()
        members.removeAll()
        memberConfirmations.removeAll()
        lock.unlock()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}

/// Coordinator 选举与 Failover
enum CoordinatorElection {
    /// 默认：Session 创建者担任 Coordinator
    static func initialCoordinator(creatorDeviceId: String) -> String {
        creatorDeviceId
    }

    /// Failover：选择 deviceId 字典序最小的在线成员
    static func electNewCoordinator(from members: [SharingMember], excluding excludedId: String) -> String? {
        members
            .filter { $0.deviceId != excludedId }
            .sorted { $0.deviceId < $1.deviceId }
            .first?
            .deviceId
    }
}
