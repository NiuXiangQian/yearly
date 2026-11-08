import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct NativeAvatarDraft: Transferable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // An avatar is a new, bounded derivative. ImageIO applies orientation
            // without copying the source EXIF or loading the full photo into memory.
            guard let source = CGImageSourceCreateWithURL(received.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                  ] as CFDictionary) else {
                throw UploadFailure(message: "无法读取这张照片，请换一张。")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw UploadFailure(message: "无法生成头像。")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination), encoded.length <= 1024 * 1024 else {
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
        if let cached = NativeImageCache.image(for: cacheKey) {
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
            NativeImageCache.insert(image, for: cacheKey)
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
