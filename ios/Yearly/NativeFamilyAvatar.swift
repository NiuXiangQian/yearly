import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct NativeAvatarDraft: Transferable, Identifiable {
    let id = UUID()
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // A bounded editing preview; the Photos original is never modified.
            guard let source = CGImageSourceCreateWithURL(received.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                  ] as CFDictionary) else {
                throw UploadFailure(message: "无法读取这张照片，请换一张。")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw UploadFailure(message: "无法生成头像。")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw UploadFailure(message: "无法生成符合大小限制的头像。")
            }
            return NativeAvatarDraft(jpeg: encoded as Data)
        }
    }
}

struct NativeFamilyAvatar: View {
    let session: NativeSession
    let mediaID: Int?
    let name: String
    let pet: Bool
    let color: Color
    var size: CGFloat = 48
    var draft: UIImage?
    @State private var remote: UIImage?
    @State private var loadedID: Int?

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.2))
            if let image = draft ?? (loadedID == mediaID ? remote : nil) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if pet {
                Image(systemName: "pawprint.fill").font(.system(size: size * 0.34)).foregroundStyle(color)
            } else {
                Text(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1).uppercased())
                    .font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: mediaID) { await load() }
    }

    private func load() async {
        remote = nil
        loadedID = nil
        guard let mediaID, let account = session.account?.id else { return }
        let cacheKey = "avatar|\(session.site.url.absoluteString)|\(account)|\(mediaID)"
        if let cached = await NativeImageCache.image(for: cacheKey, scope: session.cacheScope) {
            guard !Task.isCancelled, session.account?.id == account else { return }
            remote = cached
            loadedID = mediaID
            return
        }
        do {
            let media: NativeTimelineItem = try await session.get("/media/\(mediaID)")
            guard let file = media.files?.first(where: { $0.file_role == "preview" }) ?? media.primary else { return }
            let resource: NativeMediaResource = try await session.get("/media/\(mediaID)/files/\(file.id)/url?purpose=thumbnail")
            guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else { return }
            let image = try await NativeMediaNetwork.image(url, maximumDimension: 256)
            try Task.checkCancellation()
            guard session.account?.id == account else { return }
            NativeImageCache.insert(image, for: cacheKey, scope: session.cacheScope)
            remote = image
            loadedID = mediaID
        } catch { /* Initials are also the fallback for unavailable avatars. */ }
    }
}

struct NativeFamilyPhotoSearch: View {
    let session: NativeSession
    let selectedID: Int?
    let select: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loadedQuery: String?
    @State private var items: [NativeTimelineItem] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error = ""
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button {
                        select(item.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            if let file = item.primary {
                                NativeMediaImage(session: session, mediaID: item.id, fileID: file.id)
                                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.primary?.original_filename ?? "照片")
                                    .lineLimit(1)
                                Text(item.day).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.id == selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }.foregroundStyle(.primary)
                    }
                }
                if loading { ProgressView("正在查找照片…") }
                else if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                    Button("重试") { Task { await load(more: page > 0) } }
                } else if items.isEmpty {
                    Text("没有符合条件的照片。").foregroundStyle(.secondary)
                } else if items.count < total {
                    Button("加载更多") { Task { await load(more: true) } }
                }
            }
            .navigationTitle("从时间线选头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .searchable(text: $query, prompt: "搜索照片标题、批次或备注")
            .task(id: query) { await load(debounce: true) }
        }
    }

    private func load(more: Bool = false, debounce: Bool = false) async {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if more && (loading || loadedQuery != term) { return }
        generation += 1
        let ticket = generation
        let requestedPage = more ? page + 1 : 1
        loading = true
        error = ""
        if !more { items = []; page = 0 }
        defer { if generation == ticket { loading = false } }
        do {
            if debounce && !term.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
            var query = URLComponents()
            query.queryItems = [
                URLQueryItem(name: "media_type", value: "photo"),
                URLQueryItem(name: "page", value: String(requestedPage)),
                URLQueryItem(name: "page_size", value: "30"),
                URLQueryItem(name: "q", value: term),
            ]
            let result: NativeTimelinePage = try await session.get("/media?" + (query.percentEncodedQuery ?? ""))
            guard generation == ticket, !Task.isCancelled else { return }
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            page = requestedPage
            total = result.items.isEmpty ? items.count : result.total
            loadedQuery = term
        } catch {
            if generation == ticket, !Task.isCancelled { self.error = friendly(error) }
        }
    }
}

// Crop only the display copy. The source stays in Photos or in the timeline.
struct NativeAvatarCropView: View {
    private let image: UIImage?
    let save: (NativeAvatarDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var initialZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var initialOffset: CGSize = .zero
    @State private var error = ""

    init(source: NativeAvatarDraft, save: @escaping (NativeAvatarDraft) -> Void) {
        image = UIImage(data: source.jpeg)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            if let image {
                GeometryReader { geometry in
                    let side = min(geometry.size.width - 48, 300, max(120, geometry.size.height - 330))
                    let base = side / min(image.size.width, image.size.height)
                    ScrollView {
                        VStack(spacing: 16) {
                            Spacer(minLength: 8)
                            Image(uiImage: image).resizable()
                                .frame(width: image.size.width * base * zoom, height: image.size.height * base * zoom)
                                .offset(offset)
                                .frame(width: side, height: side)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                                .contentShape(Circle())
                                .gesture(DragGesture().onChanged { value in
                                    offset = bounded(CGSize(width: initialOffset.width + value.translation.width,
                                                            height: initialOffset.height + value.translation.height), image: image, side: side)
                                }.onEnded { _ in initialOffset = offset })
                                .simultaneousGesture(MagnificationGesture().onChanged { value in
                                    zoom = min(5, max(1, initialZoom * value))
                                    offset = bounded(offset, image: image, side: side)
                                }.onEnded { _ in initialZoom = zoom; initialOffset = offset })
                                .accessibilityLabel("头像圆形预览，可拖动调整位置")
                            Text("拖动调整位置，双指缩放")
                                .font(.headline)
                            HStack {
                                Image(systemName: "minus.magnifyingglass")
                                Slider(value: $zoom, in: 1...5, onEditingChanged: { editing in
                                    if !editing { initialZoom = zoom }
                                }).accessibilityLabel("头像缩放")
                                Image(systemName: "plus.magnifyingglass")
                            }.padding(.horizontal, 28)
                            Button("重置位置与缩放") { zoom = 1; initialZoom = 1; offset = .zero; initialOffset = .zero }
                            Text("仅生成头像副本，来源照片保留原样。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
                            Spacer(minLength: 8)
                            Button {
                                let format = UIGraphicsImageRendererFormat()
                                format.scale = 1
                                format.opaque = true
                                let output = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
                                    let ratio = 512 / side
                                    let size = CGSize(width: image.size.width * base * zoom, height: image.size.height * base * zoom)
                                    image.draw(in: CGRect(x: ((side - size.width) / 2 + offset.width) * ratio,
                                                          y: ((side - size.height) / 2 + offset.height) * ratio,
                                                          width: size.width * ratio, height: size.height * ratio))
                                }
                                if let jpeg = output.jpegData(compressionQuality: 0.85) {
                                    save(NativeAvatarDraft(jpeg: jpeg)); dismiss()
                                } else { error = "无法生成头像，请重新选择照片。" }
                            } label: { Text("使用此头像").frame(maxWidth: .infinity) }
                                .buttonStyle(NativeActionStyle(kind: .primary)).padding(.horizontal, 24)
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                            .frame(minHeight: geometry.size.height)
                            .onChange(of: zoom) { _ in
                                offset = bounded(offset, image: image, side: side)
                                initialOffset = offset
                            }
                    }
                }
                .background(NativeTheme.background)
                .navigationTitle("调整头像").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            }
        }
    }

    private func bounded(_ value: CGSize, image: UIImage, side: CGFloat) -> CGSize {
        let scale = side / min(image.size.width, image.size.height) * zoom
        let x = max(0, (image.size.width * scale - side) / 2)
        let y = max(0, (image.size.height * scale - side) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
}
