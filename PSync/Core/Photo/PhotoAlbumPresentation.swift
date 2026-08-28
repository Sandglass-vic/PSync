import CoreGraphics
import Foundation

/// 系统「照片」深链与结果页预览相关的可测规则。
enum PhotoAlbumPresentation {
    /// 打开系统「照片 → 图库」页（不是「相簿」页）。
    static var libraryTabURLCandidates: [URL] {
        [
            "photos://library",
            "photos-navigation://contentmode?id=photos",
            "photos-navigation://album?name=photo-library",
            "photos-redirect://"
        ].compactMap(URL.init(string:))
    }

    /// 兼容旧名。
    static var allPhotosURLCandidates: [URL] { libraryTabURLCandidates }

    /// 网格缩略图像素边长：按格子逻辑边长 × 屏密度，并设下限避免发糊。
    static func thumbnailPixelSide(cellSidePoints: CGFloat, screenScale: CGFloat) -> CGFloat {
        let scale = max(screenScale, 2)
        let requested = cellSidePoints * scale
        return max(requested, 600)
    }

    static func thumbnailTargetSize(cellSidePoints: CGFloat, screenScale: CGFloat) -> CGSize {
        let side = thumbnailPixelSide(cellSidePoints: cellSidePoints, screenScale: screenScale)
        return CGSize(width: side, height: side)
    }

    /// 预览页：点击内容关闭，不展示独立关闭按钮。
    static var previewDismissesOnContentTap: Bool { true }
    static var previewShowsCloseButton: Bool { false }

    static let liveBadgeIconPointSize: CGFloat = 15
    static let liveBadgeTitle = "实况"

    /// 「已收到」只展示本场 `receivedPhotos`，不直接读取整个 PSync 相簿。
    static func sessionReceivedItems(from photos: [ReceivedPhoto]) -> [ReceivedPhoto] {
        photos
    }

    static var usesSessionReceivedInsteadOfFullAlbum: Bool { true }
}
