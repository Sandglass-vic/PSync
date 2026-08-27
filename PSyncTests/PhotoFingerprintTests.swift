import XCTest
@testable import PSync

final class PhotoFingerprintTests: XCTestCase {
    func testSameImageProducesSameContentHash() throws {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image1 = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image2 = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        let data1 = image1.jpegData(compressionQuality: 0.9)!
        let data2 = image2.jpegData(compressionQuality: 0.9)!

        let hash1 = try PhotoFingerprint.compute(from: data1)
        let hash2 = try PhotoFingerprint.compute(from: data2)

        XCTAssertEqual(hash1.contentHash, hash2.contentHash)
    }

    func testDifferentImagesProduceDifferentHash() throws {
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

    func testVerifyContent() throws {
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
