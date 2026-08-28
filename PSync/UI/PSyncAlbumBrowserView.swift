import Photos
import PhotosUI
import SwiftUI
import UIKit

// MARK: - In-app PSync album (Photos framework)

/// 从系统「PSync」自定义相簿读取 PHAsset，三列网格 + 点击预览（含实况）。
struct PSyncAlbumLibraryView: View {
    var reloadToken: Int = 0
    @StateObject private var model = PSyncAlbumLibraryModel()
    @State private var selectedItem: AlbumAssetItem?

    private let spacing: CGFloat = 1
    private let columnCount = 3

    var body: some View {
        GeometryReader { geometry in
            let cellSize = floor((geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))

            Group {
                switch model.loadState {
                case .loading:
                    ProgressView("正在加载「PSync」相簿…")
                        .frame(width: geometry.size.width, height: geometry.size.height)
                case .unavailable:
                    emptyMessage(
                        title: "无法访问照片",
                        systemImage: "exclamationmark.triangle",
                        detail: "请在设置中允许 PSync 访问完整照片图库"
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                case .empty:
                    emptyMessage(
                        title: "「PSync」相簿为空",
                        systemImage: "photo.on.rectangle.angled",
                        detail: "收到的照片会保存在这里"
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                case .ready:
                    ScrollView {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(cellSize), spacing: spacing),
                                count: columnCount
                            ),
                            spacing: spacing
                        ) {
                            ForEach(model.items) { item in
                                Button {
                                    selectedItem = item
                                } label: {
                                    AlbumAssetCell(item: item, cellSidePoints: cellSize)
                                        .frame(width: cellSize, height: cellSize)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task(id: reloadToken) {
            await model.load()
        }
        .onAppear {
            model.startObserving()
        }
        .onDisappear {
            model.stopObserving()
        }
        .fullScreenCover(item: $selectedItem) { item in
            AlbumAssetPreview(item: item) {
                selectedItem = nil
            }
        }
    }

    private func emptyMessage(title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

@MainActor
final class PSyncAlbumLibraryModel: NSObject, ObservableObject {
    enum LoadState {
        case loading
        case ready
        case empty
        case unavailable
    }

    @Published var items: [AlbumAssetItem] = []
    @Published var loadState: LoadState = .loading

    private var observerRegistered = false

    override init() {
        super.init()
    }

    func load() async {
        loadState = items.isEmpty ? .loading : loadState
        guard await PhotoLibraryImporter.requestAuthorizationIfNeeded() else {
            loadState = .unavailable
            return
        }
        guard let album = PhotoLibraryImporter.pSyncAlbum() else {
            items = []
            loadState = .empty
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: album, options: options)
        var loaded: [AlbumAssetItem] = []
        loaded.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            loaded.append(
                AlbumAssetItem(
                    id: asset.localIdentifier,
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
                )
            )
        }
        items = loaded
        loadState = loaded.isEmpty ? .empty : .ready
    }

    func startObserving() {
        guard !observerRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }

    func stopObserving() {
        guard observerRegistered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        observerRegistered = false
    }
}

extension PSyncAlbumLibraryModel: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            await load()
        }
    }
}

struct AlbumAssetItem: Identifiable, Equatable {
    let id: String
    let isLivePhoto: Bool
}

struct AlbumAssetCell: View {
    let item: AlbumAssetItem
    var cellSidePoints: CGFloat = 160
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isLivePhoto {
                    Image(systemName: "livephoto")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
                        .padding(4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: "\(item.id)-\(Int(cellSidePoints))") {
                let scale = UIScreen.main.scale
                image = await PhotoLibraryImporter.requestThumbnail(
                    for: item.id,
                    cellSidePoints: cellSidePoints,
                    screenScale: scale
                )
            }
    }
}

struct AlbumAssetPreview: View {
    let item: AlbumAssetItem
    let onClose: () -> Void

    @State private var stillImage: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if item.isLivePhoto, let livePhoto {
                    LivePhotoPreviewRepresentable(
                        livePhoto: livePhoto,
                        onTap: dismissIfAllowed
                    )
                } else if let stillImage {
                    Image(uiImage: stillImage)
                        .resizable()
                        .scaledToFit()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissIfAllowed)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
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
            isLoading = true
            async let stillTask = PhotoLibraryImporter.requestFullImage(for: item.id)
            if item.isLivePhoto {
                async let liveTask = PhotoLibraryImporter.requestLivePhoto(for: item.id)
                let (still, live) = await (stillTask, liveTask)
                stillImage = still
                livePhoto = live
            } else {
                stillImage = await stillTask
                livePhoto = nil
            }
            isLoading = false
        }
    }

    private func dismissIfAllowed() {
        guard PhotoAlbumPresentation.previewDismissesOnContentTap else { return }
        onClose()
    }
}

struct LivePhotoPreviewRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.isMuted = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        view.isUserInteractionEnabled = true
        context.coordinator.view = view
        DispatchQueue.main.async {
            view.startPlayback(with: .full)
        }
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        context.coordinator.onTap = onTap
        if uiView.livePhoto !== livePhoto {
            uiView.livePhoto = livePhoto
            uiView.startPlayback(with: .full)
        }
        context.coordinator.view = uiView
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        weak var view: PHLivePhotoView?

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            onTap()
        }
    }
}

/// 兼容旧入口：以 sheet 形式浏览「PSync」相簿。
struct PSyncAlbumBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PSyncAlbumLibraryView()
                .navigationTitle("PSync")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
