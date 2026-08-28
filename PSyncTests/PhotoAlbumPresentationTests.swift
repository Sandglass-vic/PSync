import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

final class PhotoAlbumPresentationTests: XCTestCase {
    func testLibraryTabDeepLinkPrefersLibraryOverAlbums() {
        let strings = PhotoAlbumPresentation.libraryTabURLCandidates.map(\.absoluteString)
        XCTAssertFalse(strings.isEmpty)
        XCTAssertEqual(strings.first, "photos://library")
        XCTAssertFalse(strings.contains { $0.contains("name=recents") })
        XCTAssertTrue(strings.contains { $0.contains("contentmode?id=photos") })
    }

    func testLibraryCandidatesIncludeFallback() {
        let strings = PhotoAlbumPresentation.libraryTabURLCandidates.map(\.absoluteString)
        XCTAssertTrue(strings.contains("photos-redirect://") || strings.contains { $0.contains("contentmode") })
    }

    func testAllPhotosAliasMatchesLibraryTab() {
        XCTAssertEqual(
            PhotoAlbumPresentation.allPhotosURLCandidates.map(\.absoluteString),
            PhotoAlbumPresentation.libraryTabURLCandidates.map(\.absoluteString)
        )
    }

    func testThumbnailPixelSideAvoidsBlurryLowRes() {
        let side = PhotoAlbumPresentation.thumbnailPixelSide(cellSidePoints: 130, screenScale: 3)
        XCTAssertGreaterThanOrEqual(side, 600)

        let size = PhotoAlbumPresentation.thumbnailTargetSize(cellSidePoints: 130, screenScale: 3)
        XCTAssertEqual(size.width, side)
        XCTAssertEqual(size.height, side)
    }

    func testThumbnailPixelSideScalesWithCellAndScreen() {
        let small = PhotoAlbumPresentation.thumbnailPixelSide(cellSidePoints: 250, screenScale: 2)
        let large = PhotoAlbumPresentation.thumbnailPixelSide(cellSidePoints: 250, screenScale: 3)
        XCTAssertEqual(small, 600)
        XCTAssertEqual(large, 750)
        XCTAssertGreaterThan(large, small)
    }

    func testPreviewInteractionPolicy() {
        XCTAssertTrue(PhotoAlbumPresentation.previewDismissesOnContentTap)
        XCTAssertFalse(PhotoAlbumPresentation.previewShowsCloseButton)
    }

    func testLiveBadgeCopyAndIconSize() {
        XCTAssertEqual(PhotoAlbumPresentation.liveBadgeTitle, "实况")
        XCTAssertEqual(PhotoAlbumPresentation.liveBadgeTitle.count, 2)
        XCTAssertGreaterThanOrEqual(PhotoAlbumPresentation.liveBadgeIconPointSize, 14)
    }

    func testReceivedTabUsesSessionPhotosNotFullAlbum() {
        XCTAssertTrue(PhotoAlbumPresentation.usesSessionReceivedInsteadOfFullAlbum)

        let sessionOnly = [
            ReceivedPhoto(
                id: "1",
                contentHash: "a",
                thumbnailData: nil,
                sourceUserName: "B",
                sourceDeviceId: "b",
                isLivePhoto: true,
                libraryAssetIdentifier: nil
            ),
            ReceivedPhoto(
                id: "2",
                contentHash: "b",
                thumbnailData: nil,
                sourceUserName: "B",
                sourceDeviceId: "b",
                isLivePhoto: false,
                libraryAssetIdentifier: "asset-2"
            )
        ]
        let items = PhotoAlbumPresentation.sessionReceivedItems(from: sessionOnly)
        XCTAssertEqual(items.map(\.id), ["1", "2"])
        XCTAssertEqual(items.count, sessionOnly.count)
    }

    func testSessionPreviewItemCanDescribeLocalLiveResources() {
        let item = SessionPreviewItem(
            id: "local-1",
            isLivePhoto: true,
            thumbnailData: nil,
            libraryAssetIdentifier: "PHAssetID",
            stillFileURL: URL(fileURLWithPath: "/tmp/still.heic"),
            pairedVideoFileURL: URL(fileURLWithPath: "/tmp/video.mov")
        )
        XCTAssertTrue(item.isLivePhoto)
        XCTAssertNotNil(item.libraryAssetIdentifier)
        XCTAssertNotNil(item.pairedVideoFileURL)
    }
}
