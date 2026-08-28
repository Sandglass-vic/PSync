import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

/// 场景：A={1,2}  B={2,3}  C={1,3,4}
/// 全局并集应为 {1,2,3,4}，每人只接收自己没有的照片。
final class ABCTransferScenarioTests: XCTestCase {
    private let photo1 = "photo-1"
    private let photo2 = "photo-2"
    private let photo3 = "photo-3"
    private let photo4 = "photo-4"
    private let allPhotos = ["photo-1", "photo-2", "photo-3", "photo-4"]

    private let owners: [String: Set<String>] = [
        "photo-1": ["A", "C"],
        "photo-2": ["A", "B"],
        "photo-3": ["B", "C"],
        "photo-4": ["C"]
    ]

    private let initial: [String: Set<String>] = [
        "A": ["photo-1", "photo-2"],
        "B": ["photo-2", "photo-3"],
        "C": ["photo-1", "photo-3", "photo-4"]
    ]

    func testABCDiffPlanProtocolAndExecution() throws {
        let coordinator = CoordinatorService()
        coordinator.setMembers([
            makeMember("A", confirmed: true),
            makeMember("B", confirmed: true),
            makeMember("C", confirmed: true)
        ])

        XCTAssertTrue(
            coordinator.allConfirmed(members: [
                makeMember("A", confirmed: true),
                makeMember("B", confirmed: true),
                makeMember("C", confirmed: true)
            ]),
            "全员确认后才允许进入传输调度"
        )

        let manifests: [(device: String, photos: [String])] = [
            ("A", [photo1, photo2]),
            ("B", [photo2, photo3]),
            ("C", [photo1, photo3, photo4])
        ]

        var encodedManifests: [ProtocolEnvelope] = []
        for item in manifests {
            let payload = PhotoManifestPayload(photos: item.photos.map { makePhoto($0, owner: item.device) })
            let envelope = try ProtocolEnvelope(
                messageType: .photoManifest,
                deviceId: item.device,
                sessionId: "session-abc",
                payload: payload
            )
            encodedManifests.append(envelope)
            coordinator.handlePhotoManifest(from: item.device, photos: payload.photos)
        }

        XCTAssertTrue(coordinator.allManifestsReceived(expectedCount: 3, receivedCount: encodedManifests.count))

        assertDiff(coordinator, device: "A", expected: [photo3, photo4])
        assertDiff(coordinator, device: "B", expected: [photo1, photo4])
        assertDiff(coordinator, device: "C", expected: [photo2])
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "A"), 2)
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "B"), 2)
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "C"), 1)

        try verifyManifestProtocolRoundTrip(encodedManifests)

        let tasks = coordinator.generateTransferPlan()
        verifyPlanLogic(tasks)

        let planEnvelope = try ProtocolEnvelope(
            messageType: .transferPlan,
            deviceId: "A",
            sessionId: "session-abc",
            payload: TransferPlanPayload(tasks: tasks.map { $0.toPayload() })
        )
        let decodedTasks = try verifyTransferPlanProtocol(planEnvelope, original: tasks)

        let flow = simulateExecution(coordinator: coordinator, tasks: decodedTasks)
        XCTAssertEqual(flow.ownedAfter["A"], Set(allPhotos))
        XCTAssertEqual(flow.ownedAfter["B"], Set(allPhotos))
        XCTAssertEqual(flow.ownedAfter["C"], Set(allPhotos))
        XCTAssertTrue(flow.unmetDependencies.isEmpty, "不应留下未满足依赖的任务")
        XCTAssertTrue(flow.illegalTransfers.isEmpty, "不应出现发给已拥有者或源未拥有的传输")

        let report = renderReport(tasks: decodedTasks, flow: flow)
        print(report)
        add(XCTAttachment(string: report))
    }

    // MARK: - Protocol

    private func verifyManifestProtocolRoundTrip(_ envelopes: [ProtocolEnvelope]) throws {
        for envelope in envelopes {
            var buffer = try ProtocolCodec.encode(envelope)
            XCTAssertEqual(buffer.last, 0x0A, "控制协议使用换行分隔")
            let decoded = try ProtocolCodec.decodeMessages(from: &buffer)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].messageType, .photoManifest)
            XCTAssertEqual(decoded[0].protocolVersion, ProtocolConstants.protocolVersion)
            let payload = try decoded[0].decodePayload(PhotoManifestPayload.self)
            XCTAssertFalse(payload.photos.isEmpty)
        }
    }

    private func verifyTransferPlanProtocol(
        _ envelope: ProtocolEnvelope,
        original: [TransferTask]
    ) throws -> [TransferTask] {
        XCTAssertEqual(envelope.messageType, .transferPlan)

        var buffer = try ProtocolCodec.encode(envelope)
        let decoded = try ProtocolCodec.decodeMessages(from: &buffer)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(decoded[0].messageType, .transferPlan)

        let payload = try decoded[0].decodePayload(TransferPlanPayload.self)
        XCTAssertEqual(payload.tasks.count, original.count)

        let originalKeys = Set(original.map { "\($0.sourceDeviceId)->\($0.destinationDeviceId):\($0.contentHash)" })
        let decodedKeys = Set(payload.tasks.map { "\($0.sourceDeviceId)->\($0.destinationDeviceId):\($0.contentHash)" })
        XCTAssertEqual(decodedKeys, originalKeys)

        return payload.tasks.map { task in
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
    }

    // MARK: - Plan logic

    private func verifyPlanLogic(_ tasks: [TransferTask]) {
        XCTAssertFalse(tasks.isEmpty)

        let destHashKeys = tasks.map { "\($0.destinationDeviceId):\($0.contentHash)" }
        XCTAssertEqual(destHashKeys.count, Set(destHashKeys).count, "同一目的地不应重复接收同一张照片")

        let expectedNeeded: [String: Set<String>] = [
            "A": [photo3, photo4],
            "B": [photo1, photo4],
            "C": [photo2]
        ]

        for (device, needed) in expectedNeeded {
            let received = Set(tasks.filter { $0.destinationDeviceId == device }.map(\.contentHash))
            XCTAssertEqual(received, needed, "\(device) 应收的照片集合不正确")
            let alreadyOwned = initial[device]!
            XCTAssertTrue(received.isDisjoint(with: alreadyOwned), "\(device) 被安排接收自己已有的照片")
        }

        for task in tasks {
            XCTAssertNotEqual(task.sourceDeviceId, task.destinationDeviceId)
            XCTAssertTrue(allPhotos.contains(task.contentHash))
            let legalSources = owners[task.contentHash] ?? []
            XCTAssertTrue(
                legalSources.contains(task.sourceDeviceId),
                "\(task.contentHash) 的源 \(task.sourceDeviceId) 初始并不拥有该照片"
            )
            XCTAssertFalse(
                (initial[task.destinationDeviceId] ?? []).contains(task.contentHash),
                "把 \(task.contentHash) 发给已拥有者 \(task.destinationDeviceId)"
            )
            XCTAssertEqual(task.state, .pending)
            XCTAssertEqual(task.version, 1)
        }

        XCTAssertEqual(tasks.count, 5, "去重后应为 5 条直达任务：A←3,A←4,B←1,B←4,C←2")

        let relayTasks = tasks.filter { !$0.dependencyTransferIds.isEmpty }
        XCTAssertTrue(
            relayTasks.isEmpty,
            "本场景每张缺失照片都有直达源，不应再生成中继副本"
        )
    }

    // MARK: - Execution

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
            XCTAssertLessThan(guardCount, 20, "传输图可能成环")

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
                let destOwned = owned[task.destinationDeviceId, default: []]
                let sourceOwned = owned[task.sourceDeviceId, default: []]
                if destOwned.contains(task.contentHash) {
                    flow.illegalTransfers.append("重复发送 \(task.contentHash) 给 \(task.destinationDeviceId)")
                }
                if !sourceOwned.contains(task.contentHash) {
                    flow.illegalTransfers.append("源 \(task.sourceDeviceId) 执行时仍没有 \(task.contentHash)")
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
        let required = Set(coordinator.registry.computeDiff(for: device).required)
        XCTAssertEqual(required, Set(expected), "\(device) 差分结果不正确")
    }

    private func renderReport(tasks: [TransferTask], flow: ExecutionFlow) -> String {
        var lines: [String] = []
        lines.append("=== A/B/C 照片传输场景报告 ===")
        lines.append("初始持有：")
        lines.append("  A: 照片1, 照片2")
        lines.append("  B: 照片2, 照片3")
        lines.append("  C: 照片1, 照片3, 照片4")
        lines.append("全局并集：照片1–4")
        lines.append("")
        lines.append("差分（应收到）：")
        lines.append("  A 需要 照片3, 照片4")
        lines.append("  B 需要 照片1, 照片4")
        lines.append("  C 需要 照片2")
        lines.append("")
        lines.append("调度计划（\(tasks.count) 条）：")
        for task in tasks.sorted(by: { $0.contentHash < $1.contentHash }) {
            let photo = task.contentHash.replacingOccurrences(of: "photo-", with: "照片")
            let deps = task.dependencyTransferIds.isEmpty ? "直达" : "中继，依赖 \(task.dependencyTransferIds.count) 条前置任务"
            lines.append("  \(task.sourceDeviceId) → \(task.destinationDeviceId)  \(photo)  [\(deps)]")
        }
        lines.append("")
        lines.append("执行顺序：")
        for (index, step) in flow.steps.enumerated() {
            lines.append("  \(index + 1). \(step)")
        }
        lines.append("")
        lines.append("结束后持有：")
        for device in ["A", "B", "C"] {
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
            "photo-3": 3_003,
            "photo-4": 4_004
        ]
        let size = sizeByHash[hash] ?? 1_024
        return PhotoMetadataPayload(
            photoId: "id-\(hash)-\(owner)",
            contentHash: hash,
            fileHash: "file-\(hash)",
            size: size,
            width: 100,
            height: 100,
            format: "JPEG",
            ownerDeviceId: owner
        )
    }

    private func makeMember(_ deviceId: String, confirmed: Bool) -> SharingMember {
        SharingMember(
            deviceId: deviceId,
            userName: deviceId,
            avatarId: 0,
            networkEndpoint: "127.0.0.1",
            controlPort: 8000,
            transferPort: 9000,
            isCoordinator: deviceId == "A",
            confirmed: confirmed
        )
    }
}
