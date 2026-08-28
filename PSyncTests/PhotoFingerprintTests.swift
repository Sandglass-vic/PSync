import XCTest
@testable import PSync

final class PhotoFingerprintTests: XCTestCase {
    func testSameBytesProduceSameContentHash() throws {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        let data = image.jpegData(compressionQuality: 0.9)!
        let hash1 = try PhotoFingerprint.compute(from: data)
        let hash2 = try PhotoFingerprint.compute(from: data)

        XCTAssertEqual(hash1.contentHash, hash2.contentHash)
        XCTAssertEqual(hash1.contentHash, hash1.fileHash, "去重主键应为字节哈希")
    }

    func testDifferentBytesProduceDifferentHash() throws {
        let size = CGSize(width: 50, height: 50)

        UIGraphicsBeginImageContext(size)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let blue = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        UIGraphicsBeginImageContext(size)
        UIColor.green.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let green = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        let blueHash = try PhotoFingerprint.compute(from: blue.jpegData(compressionQuality: 0.9)!)
        let greenHash = try PhotoFingerprint.compute(from: green.jpegData(compressionQuality: 0.9)!)

        XCTAssertNotEqual(blueHash.contentHash, greenHash.contentHash)
    }

    func testVerifyContentMatchesFileBytes() throws {
        let size = CGSize(width: 30, height: 30)
        UIGraphicsBeginImageContext(size)
        UIColor.orange.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        let data = image.pngData()!
        let result = try PhotoFingerprint.compute(from: data)
        let verified = try PhotoFingerprint.verifyContent(data: data, expectedContentHash: result.contentHash)
        XCTAssertTrue(verified)
    }
}
