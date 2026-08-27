import XCTest
@testable import PSync

final class DeviceDeduplicatorTests: XCTestCase {
    func testDedupeWithinTTL() {
        let dedup = DeviceDeduplicator(ttl: 2.0)
        XCTAssertTrue(dedup.shouldProcess(deviceId: "D1", sessionId: "S1"))
        XCTAssertFalse(dedup.shouldProcess(deviceId: "D1", sessionId: "S1"))
        XCTAssertTrue(dedup.shouldProcess(deviceId: "D1", sessionId: "S2"))
        XCTAssertTrue(dedup.shouldProcess(deviceId: "D2", sessionId: "S1"))
    }

    func testReset() {
        let dedup = DeviceDeduplicator(ttl: 2.0)
        _ = dedup.shouldProcess(deviceId: "D1", sessionId: "S1")
        dedup.reset()
        XCTAssertTrue(dedup.shouldProcess(deviceId: "D1", sessionId: "S1"))
    }
}
