import Foundation
import Photos
import UIKit

enum PhotoLibraryImporter {
    static let albumTitle = "PSync"

    static func requestAuthorizationIfNeeded() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return true
        }
        guard current == .notDetermined else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// 与旧项目一致：同一 `PHAssetCreationRequest` 内加入 `.photo` + `.pairedVideo`
    static func importReceivedPhoto(
        from stillURL: URL,
        stillFilename: String?,
        pairedVideoURL: URL?,
        pairedVideoFilename: String?,
        isLivePhoto: Bool
    ) async throws -> String {
        guard await requestAuthorizationIfNeeded() else {
            throw PhotoImportError.notAuthorized
        }

        let baseName = matchingBaseName(
            stillFilename: stillFilename,
            videoFilename: pairedVideoFilename,
            stillURL: stillURL
        )

        let stillName = resolveFilename(
            preferred: stillFilename,
            fallbackBase: baseName,
            url: stillURL,
            defaultExt: "heic"
        )
        let importStillURL = try stagedCopy(of: stillURL, filename: stillName)

        var importVideoURL: URL?
        if isLivePhoto, let pairedVideoURL, FileManager.default.fileExists(atPath: pairedVideoURL.path) {
            let videoName = resolveFilename(
                preferred: pairedVideoFilename,
                fallbackBase: baseName,
                url: pairedVideoURL,
                defaultExt: "MOV"
            )
            importVideoURL = try stagedCopy(of: pairedVideoURL, filename: videoName)
        }

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "L",
            location: "PhotoLibraryImporter.importReceivedPhoto",
            message: "import_begin",
            data: [
                "isLivePhoto": isLivePhoto,
                "hasVideo": importVideoURL != nil,
                "stillName": stillName,
                "videoName": importVideoURL?.lastPathComponent ?? ""
            ],
            runId: "post-fix"
        )
        // #endregion

        let album = try await albumCollection()
        let createdID = CreatedIdentifiers()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let creation = PHAssetCreationRequest.forAsset()

                    let stillOptions = PHAssetResourceCreationOptions()
                    stillOptions.originalFilename = stillName
                    stillOptions.shouldMoveFile = false
                    creation.addResource(with: .photo, fileURL: importStillURL, options: stillOptions)

                    if let importVideoURL {
                        let videoOptions = PHAssetResourceCreationOptions()
                        videoOptions.originalFilename = importVideoURL.lastPathComponent
                        videoOptions.shouldMoveFile = false
                        creation.addResource(
                            with: .pairedVideo,
                            fileURL: importVideoURL,
                            options: videoOptions
                        )
                    }

                    if let placeholder = creation.placeholderForCreatedAsset {
                        createdID.append(placeholder.localIdentifier)
                        if let album,
                           let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                            albumRequest.addAssets([placeholder] as NSArray)
                        }
                    }
                } completionHandler: { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: importStillURL)
            if let importVideoURL {
                try? FileManager.default.removeItem(at: importVideoURL)
            }
            throw error
        }

        guard let identifier = createdID.snapshot().first else {
            throw PhotoImportError.missingAssetIdentifier
        }

        // 导入已完成，清理 staging 副本（会话临时文件仍保留供预览回退）
        try? FileManager.default.removeItem(at: importStillURL)
        if let importVideoURL {
            try? FileManager.default.removeItem(at: importVideoURL)
        }

        return identifier
    }

    private static func matchingBaseName(
        stillFilename: String?,
        videoFilename: String?,
        stillURL: URL
    ) -> String {
        if let stillFilename, !stillFilename.isEmpty {
            return (stillFilename as NSString).deletingPathExtension
        }
        if let videoFilename, !videoFilename.isEmpty {
            return (videoFilename as NSString).deletingPathExtension
        }
        return (stillURL.deletingPathExtension().lastPathComponent)
    }

    private static func resolveFilename(
        preferred: String?,
        fallbackBase: String,
        url: URL,
        defaultExt: String
    ) -> String {
        if let preferred, !preferred.isEmpty {
            return sanitizeFilename(preferred)
        }
        let ext = url.pathExtension.isEmpty ? defaultExt : url.pathExtension
        return sanitizeFilename("\(fallbackBase).\(ext)")
    }

    private static func sanitizeFilename(_ filename: String) -> String {
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        var component = (normalized as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        component = component.replacingOccurrences(of: "/", with: "_")
        component = component.replacingOccurrences(of: "\0", with: "")
        if component.isEmpty || component == "." || component == ".." {
            return "psync-asset"
        }
        return String(component.prefix(120))
    }

    private static func stagedCopy(of fileURL: URL, filename: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)-\(filename)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }

    private static func albumCollection() async throws -> PHAssetCollection? {
        if let existing = findAlbum() { return existing }

        var placeholder: PHObjectPlaceholder?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumTitle)
                placeholder = request.placeholderForCreatedAssetCollection
            } completionHandler: { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        if let identifier = placeholder?.localIdentifier {
            let fetched = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier],
                options: nil
            )
            if let collection = fetched.firstObject { return collection }
        }
        return findAlbum()
    }

    private static func findAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: options
        ).firstObject
    }

    static func pSyncAlbum() -> PHAssetCollection? {
        findAlbum()
    }

    /// 应用内「PSync」相簿由 `PSyncAlbumLibraryView` 通过 Photos 框架展示。

    /// 打开系统「照片」的「图库」页。
    @MainActor
    static func openSystemPhotosHome() {
        Task {
            for url in PhotoAlbumPresentation.libraryTabURLCandidates {
                if await openURL(url) { return }
            }
        }
    }

    @MainActor
    static func revealLatestInSystemPhotos(assetLocalIdentifier: String?) {
        openSystemPhotosHome()
    }

    static func requestLivePhoto(for localIdentifier: String) async -> PHLivePhoto? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        // 按屏尺寸请求，避免全像素实况在预览里异常放大
        let scale = await MainActor.run { UIScreen.main.scale }
        let bounds = await MainActor.run { UIScreen.main.bounds.size }
        let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                if degraded { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: livePhoto)
            }
        }
    }

    /// 用静图 + 成对视频文件组装实况（无相册 ID 时的回退预览）。
    static func requestLivePhoto(stillURL: URL, pairedVideoURL: URL) async -> PHLivePhoto? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let bounds = await MainActor.run { UIScreen.main.bounds.size }
        let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHLivePhoto.request(
                withResourceFileURLs: [stillURL, pairedVideoURL],
                placeholderImage: nil,
                targetSize: targetSize,
                contentMode: .aspectFit
            ) { livePhoto, info in
                let cancelled = (info[PHLivePhotoInfoErrorKey] as? Error) != nil
                    || ((info[PHImageCancelledKey] as? Bool) ?? false)
                let degraded = (info[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                if degraded { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: livePhoto)
            }
        }
    }

    static func requestThumbnail(
        for localIdentifier: String,
        cellSidePoints: CGFloat = 160,
        screenScale: CGFloat = 3
    ) async -> UIImage? {
        let target = PhotoAlbumPresentation.thumbnailTargetSize(
            cellSidePoints: cellSidePoints,
            screenScale: screenScale
        )
        return await requestImage(
            for: localIdentifier,
            targetSize: target,
            contentMode: .aspectFill,
            deliveryMode: .highQualityFormat,
            resizeMode: .exact
        )
    }

    static func requestFullImage(for localIdentifier: String) async -> UIImage? {
        await requestImage(
            for: localIdentifier,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat,
            resizeMode: .none
        )
    }

    private static func requestImage(
        for localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode
    ) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = resizeMode
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                // 始终等到非 degraded，避免网格缩略图发糊
                if isDegraded { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    @MainActor
    private static func openURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private static func albumUUID(from localIdentifier: String) -> String {
        String(localIdentifier.split(separator: "/").first ?? Substring(localIdentifier))
    }
}

enum PhotoImportError: LocalizedError {
    case notAuthorized
    case unsupportedFormat
    case missingAssetIdentifier

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "没有照片库写入权限"
        case .unsupportedFormat:
            return "不支持的照片格式"
        case .missingAssetIdentifier:
            return "照片导入失败"
        }
    }
}

private final class CreatedIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
