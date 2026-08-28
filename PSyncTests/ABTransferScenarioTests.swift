import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

/// 场景：A={1,2}  B={2,3}
/// 照片2 双方已有，只应互传缺失的 1 和 3。
final class ABTransferScenarioTests: XCTestCase {
    private let photo1 = "photo-1"
    private let photo2 = "photo-2"
    private let photo3 = "photo-3"
    private let allPhotos = ["photo-1", "photo-2", "photo-3"]

    private let owners: [String: Set<String>] = [
        "photo-1": ["A"],
        "photo-2": ["A", "B"],
        "photo-3": ["B"]
    ]

    private let initial: [String: Set<String>] = [
        "A": ["photo-1", "photo-2"],
        "B": ["photo-2", "photo-3"]
    ]

    func testABDiffPlanProtocolAndExecution() throws {
        let coordinator = CoordinatorService()
        coordinator.setMembers([
            makeMember("A", confirmed: true, isCoordinator: true),
            makeMember("B", confirmed: true, isCoordinator: false)
        ])

        XCTAssertTrue(
            coordinator.allConfirmed(members: [
                makeMember("A", confirmed: true, isCoordinator: true),
                makeMember("B", confirmed: true, isCoordinator: false)
            ])
        )

        let manifests: [(device: String, photos: [String])] = [
            ("A", [photo1, photo2]),
            ("B", [photo2, photo3])
        ]

        var encodedManifests: [ProtocolEnvelope] = []
        for item in manifests {
            let payload = PhotoManifestPayload(photos: item.photos.map { makePhoto($0, owner: item.device) })
            let envelope = try ProtocolEnvelope(
                messageType: .photoManifest,
                deviceId: item.device,
                sessionId: "session-ab",
                payload: payload
            )
            encodedManifests.append(envelope)
            coordinator.handlePhotoManifest(from: item.device, photos: payload.photos)
        }

        XCTAssertTrue(coordinator.allManifestsReceived(expectedCount: 2, receivedCount: encodedManifests.count))
        assertDiff(coordinator, device: "A", expected: [photo3])
        assertDiff(coordinator, device: "B", expected: [photo1])
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "A"), 1)
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "B"), 1)

        for envelope in encodedManifests {
            var buffer = try ProtocolCodec.encode(envelope)
            XCTAssertEqual(buffer.last, 0x0A)
            let decoded = try ProtocolCodec.decodeMessages(from: &buffer)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].messageType, .photoManifest)
            _ = try decoded[0].decodePayload(PhotoManifestPayload.self)
        }

        let tasks = coordinator.generateTransferPlan()
        verifyPlan(tasks)

        let planEnvelope = try ProtocolEnvelope(
            messageType: .transferPlan,
            deviceId: "A",
            sessionId: "session-ab",
            payload: TransferPlanPayload(tasks: tasks.map { $0.toPayload() })
        )
        var planBuffer = try ProtocolCodec.encode(planEnvelope)
        let decodedPlan = try ProtocolCodec.decodeMessages(from: &planBuffer)
        XCTAssertEqual(decodedPlan.count, 1)
        XCTAssertEqual(decodedPlan[0].messageType, .transferPlan)
        let planPayload = try decodedPlan[0].decodePayload(TransferPlanPayload.self)
        XCTAssertEqual(planPayload.tasks.count, tasks.count)

        let decodedTasks = planPayload.tasks.map { task in
            TransferTask(
                transferId: task.transferId,
                contentHash: task.contentHash,
                sourceDeviceId: task.sourceDeviceId,
                destinationDeviceId: task.destinationDeviceId,
                photoSize: task.photoSize,
                state: task.state,
                version: task.version,
                dependencyTransferIds: task.dependencyTransferIds,
                bytesTransferred: 0
            )
        }

        let flow = simulateExecution(coordinator: coordinator, tasks: decodedTasks)
        XCTAssertEqual(flow.ownedAfter["A"], Set(allPhotos))
        XCTAssertEqual(flow.ownedAfter["B"], Set(allPhotos))
        XCTAssertTrue(flow.unmetDependencies.isEmpty)
        XCTAssertTrue(flow.illegalTransfers.isEmpty)

        let report = renderReport(tasks: decodedTasks, flow: flow)
        print(report)
        add(XCTAttachment(string: report))
    }

    private func verifyPlan(_ tasks: [TransferTask]) {
        XCTAssertEqual(tasks.count, 2, "去重后应为 2 条：A→B 照片1，B→A 照片3")

        let destHashKeys = tasks.map { "\($0.destinationDeviceId):\($0.contentHash)" }
        XCTAssertEqual(destHashKeys.count, Set(destHashKeys).count)

        XCTAssertEqual(Set(tasks.filter { $0.destinationDeviceId == "A" }.map(\.contentHash)), [photo3])
        XCTAssertEqual(Set(tasks.filter { $0.destinationDeviceId == "B" }.map(\.contentHash)), [photo1])
        XCTAssertFalse(tasks.contains { $0.contentHash == photo2 }, "双方已有照片2，不应传输")

        for task in tasks {
            XCTAssertNotEqual(task.sourceDeviceId, task.destinationDeviceId)
            XCTAssertTrue((owners[task.contentHash] ?? []).contains(task.sourceDeviceId))
            XCTAssertFalse((initial[task.destinationDeviceId] ?? []).contains(task.contentHash))
            XCTAssertTrue(task.dependencyTransferIds.isEmpty)
            XCTAssertEqual(task.state, .pending)
        }
    }

    private struct ExecutionFlow {
        var steps: [String] = []
        var ownedAfter: [String: Set<String>] = [:]
        var unmetDependencies: [String] = []
        var illegalTransfers: [String] = []
    }

    private func simulateExecution(coordinator: CoordinatorService, tasks: [TransferTask]) -> ExecutionFlow {
        var flow = ExecutionFlow()
        var owned = initial
        var remaining = tasks
        var completedIds = Set<String>()
        var guardCount = 0

        while !remaining.isEmpty {
            guardCount += 1
            XCTAssertLessThan(guardCount, 20)

            let ready = remaining.filter { task in
                task.dependencyTransferIds.allSatisfy(completedIds.contains)
            }
            if ready.isEmpty {
                flow.unmetDependencies = remaining.map {
                    "\($0.sourceDeviceId)->\($0.destinationDeviceId):\($0.contentHash)"
                }
                break
            }

            for task in ready.sorted(by: { $0.contentHash < $1.contentHash }) {
                if owned[task.destinationDeviceId, default: []].contains(task.contentHash) {
                    flow.illegalTransfers.append("重复发送 \(task.contentHash) 给 \(task.destinationDeviceId)")
                }
                if !owned[task.sourceDeviceId, default: []].contains(task.contentHash) {
                    flow.illegalTransfers.append("源 \(task.sourceDeviceId) 没有 \(task.contentHash)")
                }

                coordinator.scheduler.markCompleted(
                    task.transferId,
                    contentHash: task.contentHash,
                    deviceId: task.destinationDeviceId
                )
                owned[task.destinationDeviceId, default: []].insert(task.contentHash)
                completedIds.insert(task.transferId)
                remaining.removeAll { $0.transferId == task.transferId }

                let photoName = task.contentHash.replacingOccurrences(of: "photo-", with: "照片")
                flow.steps.append(
                    "\(task.sourceDeviceId) → \(task.destinationDeviceId) 发送\(photoName)（\(task.photoSize) bytes）"
                )
            }
        }

        flow.ownedAfter = owned
        return flow
    }

    private func assertDiff(_ coordinator: CoordinatorService, device: String, expected: [String]) {
        XCTAssertEqual(Set(coordinator.registry.computeDiff(for: device).required), Set(expected))
    }

    private func renderReport(tasks: [TransferTask], flow: ExecutionFlow) -> String {
        var lines: [String] = []
        lines.append("=== A/B 照片传输场景报告 ===")
        lines.append("初始持有：")
        lines.append("  A: 照片1, 照片2")
        lines.append("  B: 照片2, 照片3")
        lines.append("全局并集：照片1–3")
        lines.append("")
        lines.append("差分（应收到）：")
        lines.append("  A 需要 照片3")
        lines.append("  B 需要 照片1")
        lines.append("  照片2 双方已有，跳过")
        lines.append("")
        lines.append("调度计划（\(tasks.count) 条）：")
        for task in tasks.sorted(by: { $0.contentHash < $1.contentHash }) {
            let photo = task.contentHash.replacingOccurrences(of: "photo-", with: "照片")
            lines.append("  \(task.sourceDeviceId) → \(task.destinationDeviceId)  \(photo)  [直达]")
        }
        lines.append("")
        lines.append("执行顺序：")
        for (index, step) in flow.steps.enumerated() {
            lines.append("  \(index + 1). \(step)")
        }
        lines.append("")
        lines.append("结束后持有：")
        for device in ["A", "B"] {
            let photos = (flow.ownedAfter[device] ?? []).sorted().map {
                $0.replacingOccurrences(of: "photo-", with: "照片")
            }.joined(separator: ", ")
            lines.append("  \(device): \(photos)")
        }
        return lines.joined(separator: "\n")
    }

    private func makePhoto(_ hash: String, owner: String) -> PhotoMetadataPayload {
        let sizeByHash: [String: Int64] = [
            "photo-1": 1_001,
            "photo-2": 2_002,
            "photo-3": 3_003
        ]
        return PhotoMetadataPayload(
            photoId: "id-\(hash)-\(owner)",
            contentHash: hash,
            fileHash: "file-\(hash)",
            size: sizeByHash[hash] ?? 1_024,
            width: 100,
            height: 100,
            format: "JPEG",
            ownerDeviceId: owner
        )
    }

    private func makeMember(_ deviceId: String, confirmed: Bool, isCoordinator: Bool) -> SharingMember {
        SharingMember(
            deviceId: deviceId,
            userName: deviceId,
            avatarId: 0,
            networkEndpoint: "127.0.0.1",
            controlPort: 8000,
            transferPort: 9000,
            isCoordinator: isCoordinator,
            confirmed: confirmed
        )
    }
}
