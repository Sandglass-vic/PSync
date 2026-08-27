import XCTest
@testable import PSync

final class DiffCalculatorTests: XCTestCase {
    func testPhotosToReceive() {
        let global: Set<String> = ["H1", "H2", "H3", "H4"]
        let owned: Set<String> = ["H1", "H2"]
        let needed = DiffCalculator.photosToReceive(globalHashes: global, ownedHashes: owned)
        XCTAssertEqual(needed, ["H3", "H4"])
    }

    func testGlobalPhotoRegistryDiff() {
        let registry = GlobalPhotoRegistry()
        registry.ingestManifest(from: "A", photos: [
            makePhoto(hash: "H1", owner: "A"),
            makePhoto(hash: "H2", owner: "A")
        ])
        registry.ingestManifest(from: "B", photos: [
            makePhoto(hash: "H2", owner: "B"),
            makePhoto(hash: "H3", owner: "B")
        ])
        registry.ingestManifest(from: "C", photos: [
            makePhoto(hash: "H3", owner: "C"),
            makePhoto(hash: "H4", owner: "C")
        ])

        let aNeeded = registry.computeDiff(for: "A").required.sorted()
        let bNeeded = registry.computeDiff(for: "B").required.sorted()
        let cNeeded = registry.computeDiff(for: "C").required.sorted()

        XCTAssertEqual(aNeeded, ["H3", "H4"])
        XCTAssertEqual(bNeeded, ["H1", "H4"])
        XCTAssertEqual(cNeeded, ["H1", "H2"])
    }

    private func makePhoto(hash: String, owner: String) -> PhotoMetadataPayload {
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
}
