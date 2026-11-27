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
    var size: CGFloat? = 48
    var cornerRadius: CGFloat?
    var draft: UIImage?
    @State private var remote: UIImage?
    @State private var loadedID: Int?

    private var shape: AnyShape {
        if let cornerRadius { return AnyShape(RoundedRectangle(cornerRadius: cornerRadius)) }
        return AnyShape(Circle())
    }

    var body: some View {
        shape.fill(color.opacity(0.20))
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                if let image = draft ?? (loadedID == mediaID ? remote : nil) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if pet {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: (size ?? 120) * 0.34))
                        .foregroundStyle(cornerRadius == nil ? color : .primary)
                } else {
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1).uppercased())
                        .font(.system(size: (size ?? 120) * 0.36, weight: .semibold))
                        .foregroundStyle(cornerRadius == nil ? color : .primary)
                }
            }
            .clipShape(shape)
            .accessibilityHidden(true)
            .task(id: mediaID) {
                remote = nil
                loadedID = nil
                guard let mediaID,
                      let image = try? await NativeFamilyAvatarImage.load(session: session, mediaID: mediaID, fullSize: false)
                else { return }
                remote = image
                loadedID = mediaID
            }
    }
}

@MainActor private enum NativeFamilyAvatarImage {
    static func load(session: NativeSession, mediaID: Int, fullSize: Bool) async throws -> UIImage {
        guard let account = session.account?.id else { throw CancellationError() }
        let scope = session.cacheScope
        let purpose = fullSize ? "preview" : "thumbnail"
        let key = "avatar|\(session.site.url.absoluteString)|\(account)|\(mediaID)|\(purpose)"
        if let cached = await NativeImageCache.image(for: key, scope: scope) {
            try Task.checkCancellation()
            guard session.account?.id == account else { throw CancellationError() }
            return cached
        }

        let media: NativeTimelineItem = try await session.get("/media/\(mediaID)")
        guard let file = media.files?.first(where: { $0.file_role == "preview" }) ?? media.primary else {
            throw UploadFailure(message: "头像暂时无法查看。")
        }
        let resource: NativeMediaResource = try await session.get("/media/\(mediaID)/files/\(file.id)/url?purpose=\(purpose)")
        guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
            throw UploadFailure(message: "头像预览暂时不可用。")
        }
        let image = try await NativeMediaNetwork.image(url, maximumDimension: fullSize ? 2048 : 480)
        try Task.checkCancellation()
        guard session.account?.id == account else { throw CancellationError() }
        NativeImageCache.insert(image, for: key, scope: scope)
        return image
    }
}

struct NativeFamilyAvatarViewer: View {
    let session: NativeSession
    let mediaID: Int
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error = ""
    @State private var attempt = 0
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    zoomable(image)
                } else if !error.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button("重试") { error = ""; attempt += 1 }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                    }.padding(24)
                } else {
                    ProgressView("正在加载头像…")
                }
            }
            .navigationTitle("\(name)的头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if image != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: toggleZoom) {
                            Image(systemName: zoom > 1 ? "minus.magnifyingglass" : "plus.magnifyingglass")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(zoom > 1 ? "适应屏幕" : "放大头像")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .task(id: attempt) {
            do {
                image = try await NativeFamilyAvatarImage.load(session: session, mediaID: mediaID, fullSize: true)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { self.error = friendly(error) }
            }
        }
    }

    private func zoomable(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
            let base = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            let scale = boundedZoom(zoom * pinch)
            let position = boundedOffset(
                CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                base: base, viewport: viewport, scale: scale
            )
            Image(uiImage: image)
                .resizable()
                .frame(width: base.width, height: base.height)
                .scaleEffect(scale)
                .offset(position)
                .frame(width: viewport.width, height: viewport.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = boundedOffset(
                            CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                            base: base, viewport: viewport, scale: zoom
                        )
                    }, including: scale > 1 ? .all : .none)
                .simultaneousGesture(MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        zoom = boundedZoom(zoom * value)
                        offset = boundedOffset(offset, base: base, viewport: viewport, scale: zoom)
                    })
                .onTapGesture(count: 2, perform: toggleZoom)
                .onChange(of: viewport) { _ in offset = .zero }
                .accessibilityLabel("头像照片")
        }
    }

    private func toggleZoom() {
        zoom = zoom > 1 ? 1 : 2
        offset = .zero
    }

    private func boundedZoom(_ scale: CGFloat) -> CGFloat { min(4, max(1, scale)) }

    private func boundedOffset(_ position: CGSize, base: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        let x = max(0, (base.width * scale - viewport.width) / 2)
        let y = max(0, (base.height * scale - viewport.height) / 2)
        return CGSize(width: min(x, max(-x, position.width)), height: min(y, max(-y, position.height)))
    }
}

struct NativeFamilyPhotoSearch: View {
    let session: NativeSession
    let selectedID: Int?
    let select: (Int) -> Void
    @NativeDismiss private var dismiss
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var loadedQuery: String?
    @State private var items: [NativeTimelineItem] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error = ""
    @State private var generation = 0
    private var hasMore: Bool { page * 30 < total }

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
                                if let remark = item.remark, !remark.isEmpty {
                                    Text(remark).font(.caption).foregroundStyle(Color.secondary).lineLimit(2)
                                }
                                Text(item.day).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if item.id == selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }.foregroundStyle(Color.primary)
                    }
                }
                if loading { ProgressView("正在查找照片…") }
                else if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                    Button("重试") { Task { await load(more: page > 0) } }
                } else if items.isEmpty && !hasMore {
                    Text("没有符合条件的照片。").foregroundStyle(.secondary)
                }
                if !loading && error.isEmpty && hasMore {
                    Button("加载更多") { Task { await load(more: true) } }
                }
            }
            .navigationTitle("从时间线选头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(NativeTheme.accent)
                        .accessibilityHidden(true).padding(.leading, 12)
                    TextField("搜索照片标题、批次或备注", text: $query, prompt: NativeTheme.inputPrompt("搜索照片标题、批次或备注"))
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($queryFocused).submitLabel(.search)
                        .padding(.trailing, 8)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(NativeTheme.secondaryText)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("清空头像搜索")
                    }
                }
                .frame(minHeight: 48)
                .nativeInputSurface(focused: queryFocused)
                .padding(.horizontal).padding(.vertical, 8).background(.bar)
            }
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
                URLQueryItem(name: "page", value: String(requestedPage)),
                URLQueryItem(name: "page_size", value: "30"),
                URLQueryItem(name: "q", value: term),
            ]
            let result: NativeTimelinePage = try await session.get("/media?" + (query.percentEncodedQuery ?? ""))
            guard generation == ticket, !Task.isCancelled else { return }
            let known = Set(items.map(\.id))
            items += result.items.filter { ($0.media_type == "photo" || $0.media_type == "live_photo") && !known.contains($0.id) }
            page = requestedPage
            total = result.total
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
    @NativeDismiss private var dismiss
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
