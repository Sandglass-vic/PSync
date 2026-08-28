import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

/// 用真实 JPEG 字节做去重：A={1,2} B={2,3}，照片2 两侧像素相同。
final class PhotoDedupWithImageDataTests: XCTestCase {
    func testIdenticalPixelsShareContentHashAndSkipTransfer() throws {
        let jpeg1 = try TestJPEG.make(width: 48, height: 36, red: 0.92, green: 0.18, blue: 0.12)
        let jpeg2 = try TestJPEG.make(width: 48, height: 36, red: 0.12, green: 0.72, blue: 0.22)
        let jpeg3 = try TestJPEG.make(width: 48, height: 36, red: 0.10, green: 0.28, blue: 0.88)

        XCTAssertGreaterThan(jpeg1.count, 100)
        XCTAssertGreaterThan(jpeg2.count, 100)
        XCTAssertGreaterThan(jpeg3.count, 100)

        let hash1 = try PhotoFingerprint.compute(from: jpeg1)
        let hash2A = try PhotoFingerprint.compute(from: jpeg2)
        let hash2B = try PhotoFingerprint.compute(from: jpeg2) // 同一字节副本
        let hash3 = try PhotoFingerprint.compute(from: jpeg3)

        XCTAssertEqual(hash2A.contentHash, hash2B.contentHash, "相同字节应得到相同 contentHash")
        XCTAssertEqual(hash2A.contentHash, hash2A.fileHash)
        XCTAssertNotEqual(hash1.contentHash, hash2A.contentHash)
        XCTAssertNotEqual(hash1.contentHash, hash3.contentHash)
        XCTAssertNotEqual(hash2A.contentHash, hash3.contentHash)

        let coordinator = CoordinatorService()
        coordinator.setMembers([
            makeMember("A", isCoordinator: true),
            makeMember("B", isCoordinator: false)
        ])
        coordinator.handlePhotoManifest(from: "A", photos: [
            makePhoto(hash: hash1.contentHash, size: Int64(jpeg1.count), owner: "A"),
            makePhoto(hash: hash2A.contentHash, size: Int64(jpeg2.count), owner: "A")
        ])
        coordinator.handlePhotoManifest(from: "B", photos: [
            makePhoto(hash: hash2B.contentHash, size: Int64(jpeg2.count), owner: "B"),
            makePhoto(hash: hash3.contentHash, size: Int64(jpeg3.count), owner: "B")
        ])

        XCTAssertEqual(Set(coordinator.registry.computeDiff(for: "A").required), [hash3.contentHash])
        XCTAssertEqual(Set(coordinator.registry.computeDiff(for: "B").required), [hash1.contentHash])
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "A"), 1)
        XCTAssertEqual(coordinator.computePhotosToReceive(for: "B"), 1)

        let tasks = coordinator.generateTransferPlan()
        XCTAssertEqual(tasks.count, 2)

        let keys = Set(tasks.map { "\($0.sourceDeviceId)->\($0.destinationDeviceId):\($0.contentHash)" })
        XCTAssertEqual(keys, [
            "A->B:\(hash1.contentHash)",
            "B->A:\(hash3.contentHash)"
        ])
        XCTAssertFalse(tasks.contains { $0.contentHash == hash2A.contentHash }, "共享照片2不应进入传输计划")
    }

    private func makePhoto(hash: String, size: Int64, owner: String) -> PhotoMetadataPayload {
        PhotoMetadataPayload(
            photoId: "id-\(hash.prefix(8))-\(owner)",
            contentHash: hash,
            fileHash: "file-\(hash.prefix(8))",
            size: size,
            width: 48,
            height: 36,
            format: "JPEG",
            ownerDeviceId: owner
        )
    }

    private func makeMember(_ deviceId: String, isCoordinator: Bool) -> SharingMember {
        SharingMember(
            deviceId: deviceId,
            userName: deviceId,
            avatarId: 0,
            networkEndpoint: "127.0.0.1",
            controlPort: 8000,
            transferPort: 9000,
            isCoordinator: isCoordinator,
            confirmed: true
        )
    }
}

enum TestJPEG {
    static func make(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PhotoFingerprintError.invalidData
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw PhotoFingerprintError.unreadableImage
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoFingerprintError.invalidData
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoFingerprintError.invalidData
        }
        return data as Data
    }
}
