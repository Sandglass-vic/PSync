import Foundation

enum GroupCompletionAction: Equatable, Sendable {
    /// 本机或对端尚未齐员，必须保持网络
    case keepNetwork
    /// 协调者确认全员完成，可以广播 group_complete 并择机停网
    case settleGroup
}

/// 群组收发完成屏障：本机完成 ≠ 会话结束，全员完成才允许一起退出。
struct GroupCompletionBarrier: Equatable, Sendable {
    private(set) var completedMemberIds: Set<String> = []
    private(set) var hasAnnouncedLocalComplete = false
    private(set) var hasSettledGroup = false

    var completedMemberCount: Int { completedMemberIds.count }

    mutating func reset() {
        self = GroupCompletionBarrier()
    }

    /// 本机收发完成后调用。协调者在全员齐时才返回 `.settleGroup`。
    mutating func markLocalComplete(
        deviceId: String,
        isCoordinator: Bool,
        memberIds: Set<String>
    ) -> GroupCompletionAction {
        hasAnnouncedLocalComplete = true
        completedMemberIds.insert(deviceId)
        return evaluate(isCoordinator: isCoordinator, memberIds: memberIds)
    }

    /// 收到其他成员的 `session_complete`。
    mutating func markPeerComplete(
        deviceId: String,
        isCoordinator: Bool,
        memberIds: Set<String>
    ) -> GroupCompletionAction {
        completedMemberIds.insert(deviceId)
        return evaluate(isCoordinator: isCoordinator, memberIds: memberIds)
    }

    /// 成员中途离开后，用剩余成员重新评估是否可以收尾。
    mutating func removeMember(
        deviceId: String,
        isCoordinator: Bool,
        memberIds: Set<String>
    ) -> GroupCompletionAction {
        completedMemberIds.remove(deviceId)
        return evaluate(isCoordinator: isCoordinator, memberIds: memberIds)
    }

    /// 非协调者收到 `group_complete` 后标记已收尾。
    mutating func applyRemoteGroupComplete() {
        hasSettledGroup = true
    }

    private mutating func evaluate(
        isCoordinator: Bool,
        memberIds: Set<String>
    ) -> GroupCompletionAction {
        guard isCoordinator, !hasSettledGroup else { return .keepNetwork }
        guard !memberIds.isEmpty, memberIds.isSubset(of: completedMemberIds) else {
            return .keepNetwork
        }
        hasSettledGroup = true
        return .settleGroup
    }
}

enum GroupExitPolicy {
    static func isLocalTransferFinished(_ phase: SharingPhase) -> Bool {
        switch phase {
        case .awaitingGroupSync, .completed:
            return true
        default:
            return false
        }
    }

    /// 全员同步并停网后，结果页可视为已结算（分享 UI 仍可停留至用户返回）。
    static func isGroupSettled(phase: SharingPhase, isTransferNetworkActive: Bool) -> Bool {
        phase == .completed && !isTransferNetworkActive
    }

    /// 本机已完成但仍在协助他人时，禁止提前退出。
    static func shouldBlockEarlyExit(phase: SharingPhase, isTransferNetworkActive: Bool) -> Bool {
        isLocalTransferFinished(phase) && !isGroupSettled(phase: phase, isTransferNetworkActive: isTransferNetworkActive)
    }

    static func shouldKeepNetwork(phase: SharingPhase, isSharing: Bool, hasSettledGroup: Bool) -> Bool {
        isSharing && !hasSettledGroup && phase != .idle
    }
}
