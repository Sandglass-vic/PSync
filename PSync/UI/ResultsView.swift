import Photos
import PhotosUI
import SwiftUI
import UIKit

struct ResultsView: View {
    @ObservedObject var session: SessionManager

    var body: some View {
        PhotoResultsContent(session: session)
            .navigationTitle("共享结果")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct PhotoResultsContent: View {
    @ObservedObject var session: SessionManager
    /// 0 = 本场已收到，1 = 我共享的
    @State private var selectedTab = 0
    @State private var selectedPreview: SessionPreviewItem?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("已收到").tag(0)
                Text("我共享的").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            PhotosAlbumGrid(items: currentGridItems) { item in
                selectedPreview = previewItem(for: item.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .fullScreenCover(item: $selectedPreview) { item in
            // 有相册资源 ID 时沿用 AlbumAssetPreview（与已收到/相簿一致），避免文件组装实况缩放异常
            if let assetId = item.libraryAssetIdentifier {
                AlbumAssetPreview(
                    item: AlbumAssetItem(id: assetId, isLivePhoto: item.isLivePhoto),
                    onClose: { selectedPreview = nil }
                )
            } else {
                SessionPhotoPreview(item: item) {
                    selectedPreview = nil
                }
            }
        }
    }

    private var currentGridItems: [GridPhotoItem] {
        switch selectedTab {
        case 1:
            return session.sessionState.localPhotos.map { photo in
                GridPhotoItem(
                    id: photo.id,
                    thumbnailData: photo.thumbnailData,
                    sourceLabel: "我",
                    isLivePhoto: photo.isLivePhoto
                )
            }
        default:
            // 仅本场 receivedPhotos，不读取整个 PSync 相簿
            return PhotoAlbumPresentation.sessionReceivedItems(from: session.sessionState.receivedPhotos)
                .map { photo in
                    GridPhotoItem(
                        id: photo.id,
                        thumbnailData: photo.thumbnailData,
                        sourceLabel: photo.sourceUserName,
                        isLivePhoto: photo.isLivePhoto
                    )
                }
        }
    }

    private func previewItem(for id: String) -> SessionPreviewItem? {
        if selectedTab == 1,
           let photo = session.sessionState.localPhotos.first(where: { $0.id == id }) {
            return SessionPreviewItem(
                id: photo.id,
                isLivePhoto: photo.isLivePhoto,
                thumbnailData: photo.thumbnailData,
                libraryAssetIdentifier: photo.assetLocalIdentifier,
                stillFileURL: photo.fileURL ?? session.stillFileURL(forContentHash: photo.contentHash),
                pairedVideoFileURL: photo.pairedVideoURL
                    ?? session.pairedVideoFileURL(forContentHash: photo.contentHash)
            )
        }
        if let photo = session.sessionState.receivedPhotos.first(where: { $0.id == id }) {
            return SessionPreviewItem(
                id: photo.id,
                isLivePhoto: photo.isLivePhoto,
                thumbnailData: photo.thumbnailData,
                libraryAssetIdentifier: photo.libraryAssetIdentifier,
                stillFileURL: session.stillFileURL(forContentHash: photo.contentHash),
                pairedVideoFileURL: session.pairedVideoFileURL(forContentHash: photo.contentHash)
            )
        }
        return nil
    }
}

struct GridPhotoItem: Identifiable {
    let id: String
    let thumbnailData: Data?
    var sourceLabel: String? = nil
    let isLivePhoto: Bool
}

struct SessionPreviewItem: Identifiable, Equatable {
    let id: String
    let isLivePhoto: Bool
    let thumbnailData: Data?
    let libraryAssetIdentifier: String?
    let stillFileURL: URL?
    let pairedVideoFileURL: URL?
}

/// 与系统「照片」一致的三列正方形网格：1pt 间距、无圆角。
struct PhotosAlbumGrid: View {
    let items: [GridPhotoItem]
    var onSelect: ((GridPhotoItem) -> Void)? = nil

    private let columnCount = 3
    private let spacing: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let cellSize = cellSideLength(for: geometry.size.width)

            if items.isEmpty {
                emptyState
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(cellSize), spacing: spacing),
                            count: columnCount
                        ),
                        spacing: spacing
                    ) {
                        ForEach(items) { item in
                            Button {
                                onSelect?(item)
                            } label: {
                                PhotosGridCell(item: item)
                                    .frame(width: cellSize, height: cellSize)
                            }
                            .buttonStyle(.plain)
                            .disabled(onSelect == nil)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无照片")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func cellSideLength(for width: CGFloat) -> CGFloat {
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        return floor((width - totalSpacing) / CGFloat(columnCount))
    }
}

struct PhotosGridCell: View {
    let item: GridPhotoItem

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let data = item.thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.isLivePhoto ? "livephoto" : "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isLivePhoto || !(item.sourceLabel ?? "").isEmpty {
                    HStack(spacing: 3) {
                        if item.isLivePhoto {
                            Image(systemName: "livephoto")
                        }
                        if let sourceLabel = item.sourceLabel, !sourceLabel.isEmpty {
                            Text(sourceLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
                    .padding(4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// 统一预览：支持相册 PHAsset 实况，或本地 still+video 文件组装实况。
struct SessionPhotoPreview: View {
    let item: SessionPreviewItem
    let onClose: () -> Void

    @State private var stillImage: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if item.isLivePhoto, let livePhoto {
                    LivePhotoPreviewRepresentable(livePhoto: livePhoto, onTap: dismissIfAllowed)
                } else if let stillImage {
                    Image(uiImage: stillImage)
                        .resizable()
                        .scaledToFit()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissIfAllowed)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let data = item.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .onTapGesture(perform: dismissIfAllowed)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))
                        .onTapGesture(perform: dismissIfAllowed)
                }
            }

            if item.isLivePhoto {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "livephoto")
                            .font(.system(size: PhotoAlbumPresentation.liveBadgeIconPointSize, weight: .semibold))
                        Text(PhotoAlbumPresentation.liveBadgeTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .task(id: item.id) {
            await loadPreview()
        }
    }

    private func dismissIfAllowed() {
        guard PhotoAlbumPresentation.previewDismissesOnContentTap else { return }
        onClose()
    }

    private func loadPreview() async {
        isLoading = true
        defer { isLoading = false }

        if let assetId = item.libraryAssetIdentifier {
            async let stillTask = PhotoLibraryImporter.requestFullImage(for: assetId)
            if item.isLivePhoto {
                async let liveTask = PhotoLibraryImporter.requestLivePhoto(for: assetId)
                let (still, live) = await (stillTask, liveTask)
                stillImage = still
                livePhoto = live
                if live != nil { return }
            } else {
                stillImage = await stillTask
                livePhoto = nil
                return
            }
        }

        if item.isLivePhoto,
           let stillURL = item.stillFileURL,
           let videoURL = item.pairedVideoFileURL {
            livePhoto = await PhotoLibraryImporter.requestLivePhoto(
                stillURL: stillURL,
                pairedVideoURL: videoURL
            )
        }

        if stillImage == nil, let stillURL = item.stillFileURL,
           let data = try? Data(contentsOf: stillURL) {
            stillImage = UIImage(data: data)
        }
        if stillImage == nil, let data = item.thumbnailData {
            stillImage = UIImage(data: data)
        }
    }
}
