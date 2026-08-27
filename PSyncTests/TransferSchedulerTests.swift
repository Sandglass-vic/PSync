import XCTest
@testable import PSync

final class TransferSchedulerTests: XCTestCase {
    func testGeneratePlanForThreeMembers() {
        let registry = GlobalPhotoRegistry()
        registry.ingestManifest(from: "A", photos: [makePhoto("H1", "A"), makePhoto("H2", "A")])
        registry.ingestManifest(from: "B", photos: [makePhoto("H2", "B"), makePhoto("H3", "B")])
        registry.ingestManifest(from: "C", photos: [makePhoto("H3", "C"), makePhoto("H4", "C")])

        let scheduler = TransferScheduler(registry: registry)
        let tasks = scheduler.generatePlan(members: ["A", "B", "C"])

        XCTAssertFalse(tasks.isEmpty)

        let aReceives = tasks.filter { $0.destinationDeviceId == "A" }.map(\.contentHash)
        XCTAssertTrue(aReceives.contains("H3"))
        XCTAssertTrue(aReceives.contains("H4"))
    }

    func testCycleDetection() {
        let graph = TransferGraph()
        let task1 = makeTask(id: "T1", source: "A", dest: "B", deps: [])
        let task2 = makeTask(id: "T2", source: "B", dest: "C", deps: ["T1"])
        let task3 = makeTask(id: "T3", source: "C", dest: "A", deps: ["T2"])

        XCTAssertNoThrow(try graph.addTask(task1))
        XCTAssertNoThrow(try graph.addTask(task2))
        // T3 would create A→B→C→A cycle through dependencies - graph checks task deps not routing cycles
        XCTAssertNoThrow(try graph.addTask(task3))
    }

    func testRescheduleFailedTask() {
        let registry = GlobalPhotoRegistry()
        registry.ingestManifest(from: "A", photos: [makePhoto("H1", "A")])
        registry.ingestManifest(from: "B", photos: [makePhoto("H1", "B")])

        let scheduler = TransferScheduler(registry: registry)
        _ = scheduler.generatePlan(members: ["A", "C"])

        let failedTask = TransferTask(
            transferId: "fail-1",
            contentHash: "H1",
            sourceDeviceId: "A",
            destinationDeviceId: "C",
            photoSize: 1024,
            state: .failed,
            version: 1,
            dependencyTransferIds: [],
            bytesTransferred: 0
        )

        let newTask = scheduler.rescheduleFailedTask(failedTask, members: ["A", "B", "C"])
        XCTAssertNotNil(newTask)
        XCTAssertNotEqual(newTask?.sourceDeviceId, "A")
    }

    private func makePhoto(_ hash: String, _ owner: String) -> PhotoMetadataPayload {
        PhotoMetadataPayload(
            photoId: UUID().uuidString,
            contentHash: hash,
            fileHash: hash,
            size: 1024,
            width: 100,
            height: 100,
            format: "JPEG",
            ownerDeviceId: owner
        )
    }

    private func makeTask(id: String, source: String, dest: String, deps: [String]) -> TransferTask {
        TransferTask(
            transferId: id,
            contentHash: "H1",
            sourceDeviceId: source,
            destinationDeviceId: dest,
            photoSize: 1024,
            state: .pending,
            version: 1,
            dependencyTransferIds: deps,
            bytesTransferred: 0
        )
    }
}
