import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

/// 覆盖「本机完成不得提前退出 / 全员齐后才 settle」屏障。
final class GroupCompletionBarrierTests: XCTestCase {
    private let deviceA = "device-A"
    private let deviceB = "device-B"
    private let deviceC = "device-C"

    private var membersAB: Set<String> {
        [deviceA, deviceB]
    }

    func testBFinishesFirstDoesNotSettleWhileAStillReceiving() {
        var barrier = GroupCompletionBarrier()

        // B 只有 1 张且已收齐；A 还差一张。协调者 A 尚未完成本机收发。
        let action = barrier.markLocalComplete(
            deviceId: deviceB,
            isCoordinator: false,
            memberIds: membersAB
        )

        XCTAssertEqual(action, .keepNetwork)
        XCTAssertFalse(barrier.hasSettledGroup)
        XCTAssertTrue(barrier.hasAnnouncedLocalComplete)
        XCTAssertEqual(barrier.completedMemberCount, 1)
        XCTAssertTrue(GroupExitPolicy.shouldKeepNetwork(
            phase: .awaitingGroupSync,
            isSharing: true,
            hasSettledGroup: barrier.hasSettledGroup
        ))
        XCTAssertTrue(GroupExitPolicy.shouldBlockEarlyExit(
            phase: .awaitingGroupSync,
            isTransferNetworkActive: true
        ))
        XCTAssertFalse(GroupExitPolicy.isGroupSettled(
            phase: .awaitingGroupSync,
            isTransferNetworkActive: true
        ))
    }

    func testCoordinatorDoesNotSettleUntilEveryMemberReportsComplete() {
        var barrier = GroupCompletionBarrier()

        let afterB = barrier.markPeerComplete(
            deviceId: deviceB,
            isCoordinator: true,
            memberIds: membersAB
        )
        XCTAssertEqual(afterB, .keepNetwork)
        XCTAssertFalse(barrier.hasSettledGroup)

        let afterA = barrier.markLocalComplete(
            deviceId: deviceA,
            isCoordinator: true,
            memberIds: membersAB
        )
        XCTAssertEqual(afterA, .settleGroup)
        XCTAssertTrue(barrier.hasSettledGroup)
    }

    func testNonCoordinatorCannotSettleEvenIfItSeesAllCompletes() {
        var barrier = GroupCompletionBarrier()

        _ = barrier.markLocalComplete(
            deviceId: deviceB,
            isCoordinator: false,
            memberIds: membersAB
        )
        let action = barrier.markPeerComplete(
            deviceId: deviceA,
            isCoordinator: false,
            memberIds: membersAB
        )

        XCTAssertEqual(action, .keepNetwork)
        XCTAssertFalse(barrier.hasSettledGroup)

        barrier.applyRemoteGroupComplete()
        XCTAssertTrue(barrier.hasSettledGroup)
        XCTAssertTrue(GroupExitPolicy.isGroupSettled(phase: .completed, isTransferNetworkActive: false))
        XCTAssertFalse(GroupExitPolicy.shouldBlockEarlyExit(phase: .completed, isTransferNetworkActive: false))
    }

    func testThreeMembersRequireAllThreeBeforeSettle() {
        var barrier = GroupCompletionBarrier()
        let members = Set([deviceA, deviceB, deviceC])

        XCTAssertEqual(
            barrier.markLocalComplete(deviceId: deviceA, isCoordinator: true, memberIds: members),
            .keepNetwork
        )
        XCTAssertEqual(
            barrier.markPeerComplete(deviceId: deviceB, isCoordinator: true, memberIds: members),
            .keepNetwork
        )
        XCTAssertEqual(
            barrier.markPeerComplete(deviceId: deviceC, isCoordinator: true, memberIds: members),
            .settleGroup
        )
    }

    func testLeavingMemberUnblocksRemainingGroup() {
        var barrier = GroupCompletionBarrier()
        let members = Set([deviceA, deviceB, deviceC])

        _ = barrier.markLocalComplete(deviceId: deviceA, isCoordinator: true, memberIds: members)
        _ = barrier.markPeerComplete(deviceId: deviceB, isCoordinator: true, memberIds: members)

        let afterLeave = barrier.removeMember(
            deviceId: deviceC,
            isCoordinator: true,
            memberIds: [deviceA, deviceB]
        )
        XCTAssertEqual(afterLeave, .settleGroup)
        XCTAssertFalse(barrier.completedMemberIds.contains(deviceC))
    }

    func testSettleIsIdempotent() {
        var barrier = GroupCompletionBarrier()
        _ = barrier.markLocalComplete(deviceId: deviceA, isCoordinator: true, memberIds: membersAB)
        XCTAssertEqual(
            barrier.markPeerComplete(deviceId: deviceB, isCoordinator: true, memberIds: membersAB),
            .settleGroup
        )
        XCTAssertEqual(
            barrier.markPeerComplete(deviceId: deviceB, isCoordinator: true, memberIds: membersAB),
            .keepNetwork
        )
        XCTAssertTrue(barrier.hasSettledGroup)
    }

    func testLocalCompleteIsIdempotentAnnouncement() {
        var barrier = GroupCompletionBarrier()
        _ = barrier.markLocalComplete(deviceId: deviceB, isCoordinator: false, memberIds: membersAB)
        let second = barrier.markLocalComplete(
            deviceId: deviceB,
            isCoordinator: false,
            memberIds: membersAB
        )
        XCTAssertEqual(second, .keepNetwork)
        XCTAssertEqual(barrier.completedMemberCount, 1)
    }

    func testResetClearsBarrierState() {
        var barrier = GroupCompletionBarrier()
        _ = barrier.markLocalComplete(deviceId: deviceA, isCoordinator: true, memberIds: membersAB)
        _ = barrier.markPeerComplete(deviceId: deviceB, isCoordinator: true, memberIds: membersAB)
        XCTAssertTrue(barrier.hasSettledGroup)

        barrier.reset()
        XCTAssertFalse(barrier.hasSettledGroup)
        XCTAssertFalse(barrier.hasAnnouncedLocalComplete)
        XCTAssertEqual(barrier.completedMemberCount, 0)
    }

    func testExitPolicyKeepsNetworkDuringCoordinatorSettleWindow() {
        // 协调者已把 phase 设为 completed，但传输网络尚未停
        XCTAssertTrue(GroupExitPolicy.isLocalTransferFinished(.completed))
        XCTAssertTrue(GroupExitPolicy.shouldBlockEarlyExit(phase: .completed, isTransferNetworkActive: true))
        XCTAssertFalse(GroupExitPolicy.isGroupSettled(phase: .completed, isTransferNetworkActive: true))
        XCTAssertFalse(GroupExitPolicy.shouldBlockEarlyExit(phase: .transferring, isTransferNetworkActive: true))
    }

    func testSessionCompleteMessageIsNotGroupComplete() throws {
        let sessionComplete = try ProtocolEnvelope(
            messageType: .sessionComplete,
            deviceId: deviceB,
            sessionId: "session-ab",
            payload: SessionCompletePayload(deviceId: deviceB)
        )
        XCTAssertEqual(sessionComplete.messageType, .sessionComplete)
        let completePayload = try sessionComplete.decodePayload(SessionCompletePayload.self)
        XCTAssertEqual(completePayload.deviceId, deviceB)

        let groupComplete = try ProtocolEnvelope(
            messageType: .sessionPhase,
            deviceId: deviceA,
            sessionId: "session-ab",
            payload: SessionPhasePayload(phase: "group_complete")
        )
        XCTAssertEqual(groupComplete.messageType, .sessionPhase)
        let phasePayload = try groupComplete.decodePayload(SessionPhasePayload.self)
        XCTAssertEqual(phasePayload.phase, "group_complete")
        XCTAssertNotEqual(sessionComplete.messageType, groupComplete.messageType)
    }
}
