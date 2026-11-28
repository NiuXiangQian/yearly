import AVFoundation
import CoreImage
import Photos
import SwiftUI
import Vision

struct NativeStickerRequest: Identifiable {
    let id = UUID()
    let items: [NativeTimelineItem]
}

private struct StickerSuggestions: Decodable {
    struct Item: Decodable {
        let media_id: Int
        let frame_seconds: Double?
        let captions: [String]
    }
    let items: [Item]
}

private struct StickerEligibility: Decodable { let ok: Bool }

private extension NativeTimelineItem {
    var stickerMotion: NativeMediaFile? { media_type == "video" ? primary : motion }
}

private struct StickerFrame: Identifiable {
    let seconds: Double?
    let image: UIImage
    var id: Double { seconds ?? -1 }
}

private struct StickerDraft: Identifiable {
    let id: Int
    var image: UIImage
    var seconds: Double?
    var caption = ""
    var suggestions: [String] = []
    var cutout: UIImage?
    var zoom = 1.0
    var x = 0.0
    var y = 0.0
}

private struct StickerArtwork: View {
    let draft: StickerDraft
    let size: CGFloat

    var body: some View {
        let side = size * 0.87
        let photo = Image(uiImage: draft.cutout ?? draft.image).resizable()
        let crop = RoundedRectangle(cornerRadius: side * 0.18)
        ZStack(alignment: .bottom) {
            Group {
                if draft.cutout != nil {
                    photo.scaledToFit()
                        .frame(width: side, height: side)
                        .scaleEffect(draft.zoom)
                        .offset(x: side * draft.x / 2, y: side * draft.y / 2)
                } else {
                    let dimensions = draft.image.size
                    let scale = max(side / dimensions.width, side / dimensions.height) * draft.zoom
                    let width = dimensions.width * scale
                    let height = dimensions.height * scale
                    photo.frame(width: width, height: height)
                        .offset(x: (width - side) * draft.x / 2, y: (height - side) * draft.y / 2)
                        .frame(width: side, height: side)
                        .clipShape(crop)
                        .overlay { crop.strokeBorder(.white, lineWidth: size * 0.012) }
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .padding(.bottom, size * 0.065)
            if !draft.caption.isEmpty {
                Text(draft.caption)
                    .font(.system(size: size * 0.112, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.07, green: 0.13, blue: 0.22))
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .padding(.horizontal, size * 0.042)
                    .padding(.vertical, size * 0.013)
                    .background(.white, in: RoundedRectangle(cornerRadius: size * 0.035))
                    .padding(.horizontal, size * 0.06)
                    .padding(.bottom, size * 0.038)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
struct NativeStickerPackView: View {
    @ObservedObject var session: NativeSession
    let items: [NativeTimelineItem]
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [StickerDraft] = []
    @State private var busy = false
    @State private var working = ""
    @State private var message = ""
    @State private var retryAI = false
    @State private var selected: StickerDraft?
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("宝宝日常").font(.title2.bold())
                    Text("\(drafts.count) 张").foregroundStyle(.secondary)
                    if !working.isEmpty { ProgressView(working).font(.subheadline) }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(drafts) { draft in
                            Button { selected = draft } label: {
                                GeometryReader { proxy in
                                    StickerArtwork(draft: draft, size: proxy.size.width)
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "pencil").font(.footnote).padding(8)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(draft.caption.isEmpty ? "编辑表情" : "编辑表情，\(draft.caption)")
                        }
                    }
                    .disabled(busy)
                    if !busy && (drafts.isEmpty || retryAI) {
                        Button(drafts.isEmpty ? "重试加载" : "AI 挑帧配字") {
                            Task {
                                if drafts.isEmpty { await prepare() } else { await recommend() }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                .padding()
            }
            .background(NativeTheme.background)
            .navigationTitle("宝宝表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    Text("保存整套").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || drafts.isEmpty)
                .padding()
                .background(.regularMaterial)
            }
            .task { await prepare() }
            .sheet(item: $selected) { draft in
                if let source = items.first(where: { $0.id == draft.id }) {
                    NativeStickerEditor(session: session, source: source, initial: draft, onDone: { edited in
                        if let index = drafts.firstIndex(where: { $0.id == edited.id }) { drafts[index] = edited }
                    }, onRemove: {
                        drafts.removeAll { $0.id == draft.id }
                    })
                }
            }
        }
        .tint(NativeTheme.accent)
    }

    private func prepare() async {
        guard !busy else { return }
        busy = true
        working = "正在加载素材…"
        message = ""
        defer { busy = false; working = "" }
        do {
            try await validateStickerSources(items.map(\.id), session: session)
            var loaded: [StickerDraft] = []
            for item in items {
                try Task.checkCancellation()
                if let image = try? await loadStickerCover(item, session: session) {
                    loaded.append(StickerDraft(id: item.id, image: image))
                }
            }
            try Task.checkCancellation()
            drafts = loaded
            if drafts.isEmpty { throw UploadFailure(message: "影像预览还未就绪，请稍后重试。") }
            await applySuggestions()
            if drafts.count < items.count && message.isEmpty {
                message = "部分影像预览还未就绪，已显示可用的素材。"
            }
        } catch is CancellationError {
        } catch {
            message = stickerMessage(error)
        }
    }

    private func recommend() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; working = "" }
        await applySuggestions()
    }

    private func applySuggestions() async {
        working = "正在挑表情和配字…"
        message = ""
        retryAI = false
        do {
            let suggestions: StickerSuggestions = try await session.post(
                "/sticker-packs/suggestions", json: ["media_ids": drafts.map(\.id)]
            )
            try Task.checkCancellation()
            for item in suggestions.items {
                guard let index = drafts.firstIndex(where: { $0.id == item.media_id }),
                      let source = items.first(where: { $0.id == item.media_id }) else { continue }
                var draft = drafts[index]
                let image: UIImage?
                if let time = item.frame_seconds, let motion = source.stickerMotion,
                   let url = try? await stickerPreviewURL(source.id, motion.id, session: session) {
                    image = try? await stickerFrame(stickerGenerator(url), time: time).image
                } else if item.frame_seconds == nil {
                    image = draft.seconds == nil ? draft.image : (try? await loadStickerCover(source, session: session))
                } else {
                    image = nil
                }
                try Task.checkCancellation()
                guard let image else { continue }
                draft.image = image
                draft.seconds = item.frame_seconds
                draft.suggestions = item.captions
                if draft.caption.isEmpty { draft.caption = item.captions.first ?? "" }
                draft.cutout = nil
                if #available(iOS 17, *) { draft.cutout = await stickerCutout(image) }
                drafts[index] = draft
            }
            if suggestions.items.isEmpty { message = "点开任意素材，可以自己选帧和配字。" }
        } catch is CancellationError {
        } catch {
            retryAI = true
            message = "\(stickerMessage(error)) 也可以手动选帧和配字。"
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        working = "正在保存表情包…"
        defer { busy = false; working = "" }
        do {
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                throw UploadFailure(message: "请在设置中允许 Yearly 添加照片。")
            }
            try await validateStickerSources(drafts.map(\.id), session: session)
            let images = try drafts.map { try stickerPNG($0) }
            try await PHPhotoLibrary.shared().performChanges {
                for (index, data) in images.enumerated() {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "宝宝日常-\(index + 1).png"
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
                }
            }
            message = "已保存 \(images.count) 张表情到系统相册。"
        } catch {
            message = stickerMessage(error)
        }
    }
}

@MainActor
private struct NativeStickerEditor: View {
    @ObservedObject var session: NativeSession
    let source: NativeTimelineItem
    let initial: StickerDraft
    let onDone: (StickerDraft) -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StickerDraft
    @State private var frames: [StickerFrame] = []
    @State private var loadingFrames = false
    @State private var frameError = false
    @State private var endTime = 0.0
    @State private var seekTime = 0.0
    @State private var editingCrop = false
    @State private var busy = false
    @State private var message = ""
    @State private var sharing: URL?

    init(session: NativeSession, source: NativeTimelineItem, initial: StickerDraft,
         onDone: @escaping (StickerDraft) -> Void, onRemove: @escaping () -> Void) {
        self.session = session
        self.source = source
        self.initial = initial
        self.onDone = onDone
        self.onRemove = onRemove
        _draft = State(initialValue: initial)
        _seekTime = State(initialValue: initial.seconds ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    GeometryReader { proxy in
                        StickerArtwork(draft: draft, size: proxy.size.width)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .background(alignment: .center) {
                        Canvas { context, size in
                            let square = CGFloat(12)
                            for row in 0..<Int(ceil(size.height / square)) {
                                for column in 0..<Int(ceil(size.width / square)) where (row + column).isMultiple(of: 2) {
                                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                                    context.fill(Path(rect), with: .color(NativeTheme.line))
                                }
                            }
                        }
                        .background(NativeTheme.surface)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    if source.stickerMotion != nil { frameStrip }
                    NativeFormField(title: "配字") {
                        TextField("输入配字", text: $draft.caption)
                            .onChange(of: draft.caption) { if $0.count > 12 { draft.caption = String($0.prefix(12)) } }
                    }
                    if !draft.suggestions.isEmpty {
                        HStack {
                            ForEach(draft.suggestions, id: \.self) { caption in
                                Button(caption) { draft.caption = caption }
                                    .buttonStyle(.bordered).frame(minHeight: 44)
                            }
                        }
                    }
                    DisclosureGroup(isExpanded: $editingCrop) {
                        VStack(alignment: .leading) {
                            Text("缩放")
                            Slider(value: $draft.zoom, in: 1...2.5).accessibilityLabel("缩放")
                            Text("水平位置")
                            Slider(value: $draft.x, in: -1...1).accessibilityLabel("水平位置")
                            Text("垂直位置")
                            Slider(value: $draft.y, in: -1...1).accessibilityLabel("垂直位置")
                        }
                    } label: { Label("裁切", systemImage: "crop").frame(minHeight: 44) }
                    if #available(iOS 17, *) {
                        Button(draft.cutout == nil ? "自动抠图" : "用圆角照片") {
                            if draft.cutout != nil { draft.cutout = nil } else { Task { await cutout() } }
                        }
                        .frame(minHeight: 44)
                    }
                    if busy { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button("从整套移除", role: .destructive) { onRemove(); dismiss() }
                        .frame(minHeight: 44).disabled(busy)
                }
                .padding()
            }
            .background(NativeTheme.background)
            .navigationTitle("编辑表情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(draft); dismiss() }.disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await share() }
                } label: {
                    Label("分享单张", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered).disabled(busy)
                .padding()
                .background(.regularMaterial)
            }
            .task { await loadFrames() }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { presented in
                if !presented, let url = sharing {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    sharing = nil
                }
            })) {
                if let sharing { StickerShareSheet(url: sharing) }
            }
        }
        .tint(NativeTheme.accent)
    }

    private var frameStrip: some View {
        let isVideo = source.media_type == "video"
        let title = isVideo ? "视频选帧" : "实况选帧"
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if loadingFrames { ProgressView("正在读取动态预览…") }
            if frameError {
                Button("重试读取动态预览") { Task { await loadFrames() } }.frame(minHeight: 44)
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(frames) { frame in
                        Button {
                            selectFrame(frame)
                            seekTime = min(endTime, frame.seconds ?? 0)
                        } label: {
                            Image(uiImage: frame.image).resizable().scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(draft.seconds == frame.seconds ? NativeTheme.accent : .clear, lineWidth: 3)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(frame.seconds.map { String(format: "%.1f 秒", $0) } ?? "封面")
                        .accessibilityAddTraits(draft.seconds == frame.seconds ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(busy)
            if isVideo && endTime > 0 {
                Slider(value: $seekTime, in: 0...endTime)
                    .accessibilityLabel("视频位置")
                    .accessibilityValue(String(format: "%.1f 秒", seekTime))
                    .disabled(busy)
                HStack {
                    Text(String(format: "%.1f 秒", seekTime)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("取这一帧") { Task { await captureFrame() } }
                        .frame(minHeight: 44).disabled(busy)
                }
                .font(.subheadline)
            }
        }
    }

    private func loadFrames() async {
        guard !loadingFrames, let motion = source.stickerMotion else { return }
        loadingFrames = true
        frameError = false
        defer { loadingFrames = false }
        do {
            let cover = initial.seconds == nil ? initial.image : try? await loadStickerCover(source, session: session)
            frames = cover.map { [StickerFrame(seconds: nil, image: $0)] } ?? []
            if let seconds = initial.seconds {
                frames.append(StickerFrame(seconds: seconds, image: initial.image))
            }
            let url = try await stickerPreviewURL(source.id, motion.id, session: session)
            let generator = stickerGenerator(url)
            let duration = try await generator.asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw UploadFailure(message: "动态预览暂不可用。") }
            endTime = max(0, duration - 0.1)
            seekTime = min(seekTime, endTime)
            for index in 0..<5 {
                try Task.checkCancellation()
                let time = endTime * Double(index) / 4
                if frames.contains(where: { $0.seconds.map { abs($0 - time) < 0.025 } ?? false }) { continue }
                if let frame = try? await stickerFrame(generator, time: time) { frames.append(frame) }
            }
            frames.sort { $0.id < $1.id }
            frameError = !frames.contains { $0.seconds != nil }
        } catch is CancellationError {
        } catch {
            frameError = true
        }
    }

    private func selectFrame(_ frame: StickerFrame) {
        draft.image = frame.image
        draft.seconds = frame.seconds
        draft.cutout = nil
        message = ""
    }

    private func captureFrame() async {
        guard !busy, let motion = source.stickerMotion else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await stickerPreviewURL(source.id, motion.id, session: session)
            selectFrame(try await stickerFrame(stickerGenerator(url), time: seekTime))
        } catch {
            message = "这个位置暂时取不到画面，可以移动进度后重试。"
        }
    }

    @available(iOS 17, *)
    private func cutout() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        draft.cutout = await stickerCutout(draft.image)
        message = draft.cutout == nil ? "这张照片的主体边缘不够清楚，可以用圆角照片样式。" : ""
    }

    private func share() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await validateStickerSources([source.id], session: session)
            let image = try stickerPNG(draft)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                let file = directory.appendingPathComponent("宝宝表情.png")
                try image.write(to: file, options: .atomic)
                sharing = file
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch {
            message = stickerMessage(error)
        }
    }
}

private struct StickerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
private func validateStickerSources(_ ids: [Int], session: NativeSession) async throws {
    let query = ids.map { "media_ids=\($0)" }.joined(separator: "&")
    let result: StickerEligibility = try await session.get("/sticker-packs/eligibility?" + query)
    guard result.ok else { throw UploadFailure(message: "部分影像当前不允许分享。") }
}

@MainActor
private func stickerPreviewURL(_ media: Int, _ file: Int, purpose: String = "preview", session: NativeSession) async throws -> URL {
    let resource: NativeMediaResource = try await session.get("/media/\(media)/files/\(file)/url?purpose=\(purpose)")
    guard let url = resource.url.flatMap(AppConfiguration.httpsURL) else {
        throw UploadFailure(message: resource.message ?? "影像预览还未就绪。")
    }
    return url
}

@MainActor
private func loadStickerCover(_ item: NativeTimelineItem, session: NativeSession) async throws -> UIImage {
    guard let file = item.primary else { throw UploadFailure(message: "找不到影像预览。") }
    if item.media_type == "video" {
        if let url = try? await stickerPreviewURL(item.id, file.id, purpose: "thumbnail", session: session),
           let poster = try? await NativeMediaNetwork.image(url, maximumDimension: 480) {
            return poster
        }
        try Task.checkCancellation()
        let video = try await stickerPreviewURL(item.id, file.id, session: session)
        return try await stickerFrame(stickerGenerator(video), time: 0).image
    }
    let url = try await stickerPreviewURL(item.id, file.id, session: session)
    return try await NativeMediaNetwork.image(url, maximumDimension: 768)
}

private func stickerGenerator(_ url: URL) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 768, height: 768)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
    return generator
}

private func stickerFrame(_ generator: AVAssetImageGenerator, time: Double) async throws -> StickerFrame {
    let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 1000))
    return StickerFrame(seconds: time, image: UIImage(cgImage: image))
}

@available(iOS 17, *)
private func stickerCutout(_ photo: UIImage) async -> UIImage? {
    guard let image = photo.cgImage else { return nil }
    return await Task.detached(priority: .userInitiated) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let foreground = request.results?.first, foreground.allInstances.count == 1 else { return nil }
            let buffer = try foreground.generateScaledMaskForImage(forInstances: foreground.allInstances, from: handler)
            let input = CIImage(cgImage: image)
            let mask = CIImage(cvPixelBuffer: buffer)
            let extent = input.extent
            let clear = CIImage(color: .clear).cropped(to: extent)
            let white = CIImage(color: .white).cropped(to: extent)
            let spread = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(extent.width, extent.height) * 0.012])
            let border = white.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: spread
            ])
            let result = input.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: border, kCIInputMaskImageKey: mask
            ])
            return CIContext().createCGImage(result, from: extent).map { UIImage(cgImage: $0) }
        } catch {
            return nil
        }
    }.value
}

@MainActor
private func stickerPNG(_ draft: StickerDraft) throws -> Data {
    let renderer = ImageRenderer(content: StickerArtwork(draft: draft, size: 512))
    renderer.scale = 1
    guard let data = renderer.uiImage?.pngData() else {
        throw UploadFailure(message: "表情图片生成失败，请重试。")
    }
    return data
}

private func stickerMessage(_ error: Error) -> String {
    if let error = error as? NativeAPIError { return error.message }
    if let error = error as? UploadFailure { return error.message }
    return "这次操作未完成，请重试。"
}
