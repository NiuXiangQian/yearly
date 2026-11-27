import AVKit
import ImageIO
import PhotosUI
import SwiftUI

@MainActor private struct UploadPreviewSource {
    enum Content {
        case image(UIImage)
        case livePhoto(PHLivePhoto)
        case video(AVPlayerItem)
    }

    let item: UploadItem
    let queue: UploadQueue
    let session: NativeSession

    private var hasAccess: Bool {
        item.ownerID == session.account?.id && item.site == session.site.url.absoluteString
    }

    private var photoAsset: PHAsset? {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier], options: nil).firstObject
    }

    func thumbnail(pixels: CGFloat) async -> UIImage? {
        guard hasAccess else { return nil }
        if let url = queue.previewFile(for: item) {
            if item.mediaType == "video" {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: pixels, height: pixels)
                if let frame = try? await generator.image(at: .zero) { return UIImage(cgImage: frame.image) }
            } else if let image = await Self.fileImage(url, pixels: Int(pixels)) {
                return image
            }
        }
        if !Task.isCancelled, let asset = photoAsset {
            let key = "\(item.site)|\(item.ownerID)|upload-photos|\(asset.localIdentifier)|\(Int(pixels))"
            if let image = await NativeImageCache.image(for: key) { return image }
            if let image = await photo(asset, pixels: max(160, pixels), thumbnail: true),
               hasAccess, !Task.isCancelled {
                NativeImageCache.insert(image, for: key)
                return image
            }
        }
        guard let mediaID = archivedMediaID, let scope = session.cacheScope, !Task.isCancelled else { return nil }
        let key = "\(scope)|upload-thumbnail|\(mediaID)"
        if let cached = await NativeImageCache.image(for: key, scope: scope) { return cached }
        guard let url = await archivedURL(mediaID, purpose: "thumbnail"),
              let image = try? await NativeMediaNetwork.image(url, maximumDimension: 160),
              hasAccess, !Task.isCancelled else { return nil }
        NativeImageCache.insert(image, for: key, scope: scope)
        return image
    }

    func content() async -> Content? {
        guard hasAccess, !Task.isCancelled else { return nil }
        if item.mediaType == "live_photo", let asset = photoAsset,
           let live = await livePhoto(asset) { return .livePhoto(live) }
        if Task.isCancelled { return nil }
        if let url = queue.previewFile(for: item) {
            if item.mediaType == "video" {
                if let video = await videoFile(url) { return .video(video) }
            } else {
                if item.mediaType == "live_photo", let motion = queue.previewFile(for: item, role: "live_video"),
                   let video = await videoFile(motion) { return .video(video) }
                if let image = await Self.fileImage(url, pixels: 2048) { return .image(image) }
            }
        }
        if Task.isCancelled { return nil }
        if let asset = photoAsset {
            if item.mediaType == "video" {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                if let video: AVPlayerItem = await photoRequest({ manager, complete in
                    manager.requestPlayerItem(forVideo: asset, options: options, resultHandler: complete)
                }) { return .video(video) }
            } else if let image = await photo(asset, pixels: 2048, thumbnail: false) {
                return .image(image)
            }
        }
        guard let mediaID = archivedMediaID, !Task.isCancelled else { return nil }
        if item.mediaType == "live_photo",
           let url = await archivedURL(mediaID, purpose: "preview", motion: true) {
            return .video(AVPlayerItem(url: url))
        }
        guard let url = await archivedURL(mediaID, purpose: "preview") else { return nil }
        if item.mediaType == "video" { return .video(AVPlayerItem(url: url)) }
        return try? await .image(NativeMediaNetwork.image(url, maximumDimension: 2048))
    }

    private var archivedMediaID: Int? {
        guard item.phase == .complete || item.phase == .skipped else { return nil }
        return item.mediaID
    }

    private func archivedURL(_ id: Int, purpose: String, motion: Bool = false) async -> URL? {
        guard hasAccess, !Task.isCancelled,
              let media: NativeTimelineItem = try? await session.get("/media/\(id)"),
              let file = motion ? media.motion : media.primary,
              let resource: NativeMediaResource = try? await session.get("/media/\(id)/files/\(file.id)/url?purpose=\(purpose)"),
              let url = resource.url, hasAccess, !Task.isCancelled else { return nil }
        return AppConfiguration.httpsURL(url)
    }

    private func photo(_ asset: PHAsset, pixels: CGFloat, thumbnail: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = thumbnail ? .opportunistic : .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await photoRequest(acceptDegraded: thumbnail) { manager, complete in
            manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                                 contentMode: thumbnail ? .aspectFill : .aspectFit, options: options, resultHandler: complete)
        }
    }

    private func livePhoto(_ asset: PHAsset) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await photoRequest { manager, complete in
            manager.requestLivePhoto(for: asset, targetSize: CGSize(width: 2048, height: 2048),
                                     contentMode: .aspectFit, options: options, resultHandler: complete)
        }
    }

    private func photoRequest<Value>(
        acceptDegraded: Bool = false,
        _ start: (PHImageManager, @escaping (Value?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let manager = PHImageManager.default()
        let responses = AsyncStream<Value?> { continuation in
            let request = start(manager) { value, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true, !acceptDegraded || value == nil { return }
                continuation.yield(value)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                DispatchQueue.main.async { manager.cancelImageRequest(request) }
            }
        }
        for await value in responses { return value }
        return nil
    }

    private func videoFile(_ url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        return AVPlayerItem(asset: asset)
    }

    private nonisolated static func fileImage(_ url: URL, pixels: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct UploadTaskThumbnail: View {
    let item: UploadItem
    let queue: UploadQueue
    let session: NativeSession
    private let side: CGFloat = 36
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.mediaType == "video" ? "video" : item.mediaType == "live_photo" ? "livephoto" : "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(NativeTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: "\(item.id)|\(item.isTerminal)|\(item.resources.first?.sha256 ?? "")") {
            let result = await UploadPreviewSource(item: item, queue: queue, session: session).thumbnail(pixels: side * displayScale)
            if !Task.isCancelled { image = result }
        }
    }
}

struct UploadTaskPreview: View {
    let item: UploadItem
    let queue: UploadQueue
    @ObservedObject var session: NativeSession
    @NativeDismiss private var dismiss
    @State private var content: UploadPreviewSource.Content?
    @State private var player: AVPlayer?
    @State private var playerStatus: NSKeyValueObservation?
    @State private var loading = true
    @State private var attempt = 0
    @State private var livePlayback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if case let .image(image) = content {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("照片预览")
                } else if case let .livePhoto(livePhoto) = content {
                    UploadLivePhotoView(photo: livePhoto, playback: livePlayback)
                        .overlay(alignment: .topLeading) {
                            Button { livePlayback += 1 } label: {
                                Label("播放实况", systemImage: "livephoto")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .background(.black.opacity(0.72), in: Capsule())
                            }
                            .padding(12)
                        }
                } else if loading {
                    ProgressView("正在载入预览…")
                } else {
                    VStack(spacing: 16) {
                        Text("暂时无法查看这项影像").multilineTextAlignment(.center)
                        Button("重试预览") { attempt += 1 }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                }
            }
            .foregroundStyle(.white)
            .tint(.white)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task(id: attempt) {
            loading = true
            let loaded = await UploadPreviewSource(item: item, queue: queue, session: session).content()
            guard !Task.isCancelled, item.ownerID == session.account?.id else { return }
            content = loaded
            if case let .video(playback) = loaded {
                let value = AVPlayer(playerItem: playback)
                player = value
                playerStatus = playback.observe(\.status, options: [.initial, .new]) { playback, _ in
                    guard playback.status == .failed else { return }
                    Task { @MainActor in
                        guard player === value else { return }
                        stopPlayback()
                        content = nil
                    }
                }
            }
            loading = false
        }
        .onDisappear(perform: stopPlayback)
        .onChange(of: session.account?.id) { owner in
            if owner != item.ownerID { stopPlayback(); dismiss() }
        }
    }

    private func stopPlayback() {
        playerStatus?.invalidate()
        playerStatus = nil
        player?.pause()
        player = nil
    }
}

private struct UploadLivePhotoView: UIViewRepresentable {
    let photo: PHLivePhoto
    let playback: Int

    final class Coordinator {
        var playback = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = photo
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== photo { view.livePhoto = photo }
        if playback != context.coordinator.playback {
            context.coordinator.playback = playback
            view.startPlayback(with: .full)
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
    }
}
