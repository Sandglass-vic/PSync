import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoFingerprintError: Error, LocalizedError {
    case unreadableImage
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取照片"
        case .invalidData: return "无效的照片数据"
        }
    }
}

/// 基于像素内容的 Photo Content Fingerprint
/// 将图片缩放到固定尺寸、转灰度后计算 SHA-256，用于判断像素内容是否一致
enum PhotoFingerprint {
    static let fingerprintSize = 16

    static func compute(from data: Data) throws -> (contentHash: String, fileHash: String, width: Int, height: Int, format: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotoFingerprintError.unreadableImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let format = imageFormat(from: source)

        let fileHash = SHA256.hash(data: data).hexString
        let contentHash = try computeContentHash(from: cgImage)

        return (contentHash, fileHash, width, height, format)
    }

    static func computeContentHash(from cgImage: CGImage) throws -> String {
        let size = fingerprintSize
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw PhotoFingerprintError.invalidData
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let pixelData = context.data else {
            throw PhotoFingerprintError.invalidData
        }

        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: size * size)
        let pixelBytes = Data(bytes: buffer, count: size * size)
        return SHA256.hash(data: pixelBytes).hexString
    }

    static func verifyContent(data: Data, expectedContentHash: String) throws -> Bool {
        let result = try compute(from: data)
        return result.contentHash == expectedContentHash
    }

    static func verifyFile(data: Data, expectedFileHash: String) -> Bool {
        SHA256.hash(data: data).hexString == expectedFileHash
    }

    private static func imageFormat(from source: CGImageSource) -> String {
        guard let type = CGImageSourceGetType(source) as String? else { return "unknown" }
        if type.contains("heic") || type.contains("heif") { return "HEIC" }
        if type.contains("jpeg") || type.contains("jpg") { return "JPEG" }
        if type.contains("png") { return "PNG" }
        return type
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
