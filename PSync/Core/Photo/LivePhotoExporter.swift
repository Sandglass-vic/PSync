import Foundation
import Photos

enum LivePhotoExporter {
    struct ExportResult: Sendable {
        let stillData: Data
        let stillURL: URL
        let stillFilename: String
        let pairedVideoURL: URL?
        let pairedVideoFilename: String?
        let isLivePhoto: Bool
    }

    static func export(fromLocalIdentifier localIdentifier: String) async -> ExportResult? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        do {
            let stillResource = try resource(for: asset, preferredTypes: [.photo, .fullSizePhoto])
            let stillFilename = sanitizeFilename(stillResource.originalFilename)
            let stillExt = fileExtension(from: stillFilename) ?? "heic"
            let stillURL = temporaryURL(prefix: "0", filename: stillFilename.isEmpty ? "photo.\(stillExt)" : stillFilename)
            try await writeResource(stillResource, to: stillURL)
            let stillData = try Data(contentsOf: stillURL)

            var pairedVideoURL: URL?
            var pairedVideoFilename: String?
            // 优先读成对视频资源；不依赖 mediaSubtypes，避免漏传实况
            if let videoResource = try? resource(
                for: asset,
                preferredTypes: [.pairedVideo, .fullSizePairedVideo]
            ) {
                let videoName = sanitizeFilename(videoResource.originalFilename)
                let videoExt = fileExtension(from: videoName) ?? "MOV"
                let videoURL = temporaryURL(
                    prefix: "1",
                    filename: videoName.isEmpty ? "video.\(videoExt)" : videoName
                )
                try await writeResource(videoResource, to: videoURL)
                pairedVideoURL = videoURL
                pairedVideoFilename = videoName.isEmpty ? "video.\(videoExt)" : videoName
            }

            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "L",
                location: "LivePhotoExporter.export",
                message: "export_result",
                data: [
                    "isLiveSubtype": asset.mediaSubtypes.contains(.photoLive),
                    "hasPairedVideo": pairedVideoURL != nil,
                    "stillBytes": stillData.count,
                    "stillName": stillFilename,
                    "videoName": pairedVideoFilename ?? ""
                ],
                runId: "post-fix"
            )
            // #endregion

            return ExportResult(
                stillData: stillData,
                stillURL: stillURL,
                stillFilename: stillFilename.isEmpty ? "photo.\(stillExt)" : stillFilename,
                pairedVideoURL: pairedVideoURL,
                pairedVideoFilename: pairedVideoFilename,
                isLivePhoto: pairedVideoURL != nil
            )
        } catch {
            print("[LivePhoto] export failed: \(error)")
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "L",
                location: "LivePhotoExporter.export",
                message: "export_failed",
                data: ["error": String(describing: error)],
                runId: "post-fix"
            )
            // #endregion
            return nil
        }
    }

    private static func resource(
        for asset: PHAsset,
        preferredTypes: [PHAssetResourceType]
    ) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        for type in preferredTypes {
            if let match = resources.first(where: { $0.type == type }) {
                return match
            }
        }
        throw LivePhotoExportError.missingResource
    }

    private static func fileExtension(from filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    private static func sanitizeFilename(_ filename: String) -> String {
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        var component = (normalized as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        component = component.replacingOccurrences(of: "/", with: "_")
        component = component.replacingOccurrences(of: "\0", with: "")
        if component.isEmpty || component == "." || component == ".." {
            return ""
        }
        return String(component.prefix(120))
    }

    private static func writeResource(_ resource: PHAssetResource, to destination: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func temporaryURL(prefix: String, filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)-\(filename)")
    }
}

enum LivePhotoExportError: Error {
    case missingResource
}
