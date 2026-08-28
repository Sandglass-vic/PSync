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

/// 照片指纹：去重只认文件字节 SHA-256（`contentHash` == `fileHash`）。
enum PhotoFingerprint {
    static func compute(from data: Data) throws -> (contentHash: String, fileHash: String, width: Int, height: Int, format: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoFingerprintError.unreadableImage
        }

        let fileHash = SHA256.hash(data: data).hexString
        let format = imageFormat(from: source)
        let (width, height) = imageDimensions(from: source)

        // 去重主键 = 字节哈希，跨设备稳定；不要求像素近似
        return (fileHash, fileHash, width, height, format)
    }

    static func verifyContent(data: Data, expectedContentHash: String) throws -> Bool {
        SHA256.hash(data: data).hexString == expectedContentHash
    }

    static func verifyFile(data: Data, expectedFileHash: String) -> Bool {
        SHA256.hash(data: data).hexString == expectedFileHash
    }

    struct ImageFileDescriptor: Sendable {
        let fileExtension: String
        let uniformTypeIdentifier: String
    }

    static func fileDescriptor(for data: Data) -> ImageFileDescriptor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return nil
        }
        return descriptor(forUniformType: type)
    }

    static func fileDescriptor(forFileAt url: URL) -> ImageFileDescriptor? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return fileDescriptor(for: data)
    }

    /// MakerApple key 17 是 Live Photo 的 content identifier
    static func isLivePhoto(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [AnyHashable: Any]
        else { return false }
        return makerApple[17] != nil || makerApple["17"] != nil
    }

    private static func imageDimensions(from source: CGImageSource) -> (width: Int, height: Int) {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int
            if let width, let height {
                return (width, height)
            }
        }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return (image.width, image.height)
        }
        return (0, 0)
    }

    private static func descriptor(forUniformType type: String) -> ImageFileDescriptor? {
        let normalized = type.lowercased()
        if normalized.contains("heic") || normalized.contains("heif") {
            return ImageFileDescriptor(fileExtension: "heic", uniformTypeIdentifier: UTType.heic.identifier)
        }
        if normalized.contains("jpeg") || normalized.contains("jpg") {
            return ImageFileDescriptor(fileExtension: "jpg", uniformTypeIdentifier: UTType.jpeg.identifier)
        }
        if normalized.contains("png") {
            return ImageFileDescriptor(fileExtension: "png", uniformTypeIdentifier: UTType.png.identifier)
        }
        if normalized.contains("gif") {
            return ImageFileDescriptor(fileExtension: "gif", uniformTypeIdentifier: UTType.gif.identifier)
        }
        if normalized.contains("webp") {
            return ImageFileDescriptor(fileExtension: "webp", uniformTypeIdentifier: UTType.webP.identifier)
        }
        return ImageFileDescriptor(fileExtension: "jpg", uniformTypeIdentifier: type)
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
