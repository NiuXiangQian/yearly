import SwiftUI
import AVKit
import ImageIO
import UniformTypeIdentifiers

// Memory-only, scoped to account/site. Nothing is written to a shared disk cache.
@MainActor enum NativeImageCache {
    private final class Entry: NSObject {
        let image: UIImage
        let created = Date()
        init(_ image: UIImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>()
        value.totalCostLimit = 32 * 1024 * 1024
        value.countLimit = 100
        return value
    }()
    static func image(for key: String) -> UIImage? {
        guard let entry = cache.object(forKey: key as NSString) else { return nil }
        let age = Date().timeIntervalSince(entry.created)
        guard age >= 0, age < 120 else {
            cache.removeObject(forKey: key as NSString); return nil
        }
        return entry.image
    }
    static func insert(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        guard cost > 0, cost <= 32 * 1024 * 1024 else { return }
        cache.setObject(Entry(image), forKey: key as NSString, cost: cost)
    }
    static func clear() { cache.removeAllObjects() }
}

// Signed media never receives the account Cookie or CSRF token. No shared disk cache.
enum NativeMediaNetwork {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: UploadRedirectPolicy(), delegateQueue: nil)
    }()
    static func image(_ url: URL, maximumDimension: Int) async throws -> UIImage {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw UploadFailure(message: "图片预览暂时不可用，请重试。") }
        return UIImage(cgImage: bitmap)
    }
}

struct NativeMediaImage: View {
    @ObservedObject var session: NativeSession
    let mediaID: Int
    let fileID: Int
    var purpose = "thumbnail"
    @State private var image: UIImage?
    @State private var failure = ""
    @State private var attempt = 0
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if !failure.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Button("重试预览") { attempt += 1 }
                }.font(.caption)
            } else { ProgressView() }
        }
        .task(id: "\(mediaID)-\(fileID)-\(purpose)-\(attempt)") {
            let owner = session.account?.id
            let cacheKey = "\(session.site.url.absoluteString)|\(owner ?? -1)|\(mediaID)|\(fileID)|\(purpose)"
            failure = ""
            if attempt == 0, let cached = NativeImageCache.image(for: cacheKey) { image = cached; return }
            image = nil
            do {
                let resource: NativeMediaResource = try await session.get("/media/\(mediaID)/files/\(fileID)/url?purpose=\(purpose)")
                guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                    throw UploadFailure(message: "预览正在准备。")
                }
                let result = try await NativeMediaNetwork.image(url, maximumDimension: purpose == "thumbnail" ? 512 : 2048)
                try Task.checkCancellation()
                guard session.account?.id == owner else { return }
                NativeImageCache.insert(result, for: cacheKey)
                image = result
            } catch { if !Task.isCancelled { failure = friendly(error) } }
        }
        .accessibilityLabel(failure.isEmpty ? "影像预览" : failure)
    }
}

struct NativeTimelineView: View {
    @ObservedObject var store: NativeTimelineStore
    let appendToDay: (String) -> Void
    @State private var showingFilter = false
    @State private var shareRequest: NativeShareRequest?
    @State private var selecting = false
    @State private var chosen: [NativeTimelineItem] = []
    @State private var selectionLimit = false
    @State private var selectedItem: NativeTimelineItem?
    @State private var dragToken = UUID().uuidString
    @State private var showingTrash = false
    @State private var editingItem: NativeTimelineItem?
    @State private var daySettings: String?
    @State private var batchEdit = false
    @State private var diaryRequest: NativeDiaryRequest?
    @State private var positionBeforePrepend: String?
    private var timelineList: some View {
        ScrollViewReader { proxy in
            ScrollView { timelineContent }
                .onChange(of: store.items.first?.stableID) { first in
                    guard let id = positionBeforePrepend, first != id,
                          let item = store.items.first(where: { $0.stableID == id }) else { return }
                    positionBeforePrepend = nil
                    // Lay out the lazy day section first, then place the original card in view.
                    proxy.scrollTo("day-\(store.groupDay(item))", anchor: .top)
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: item.id == store.anchorMediaID && item.kind == "media" ? .center : .top)
                    }
                }
        }
    }

    private var timelineContent: some View {
        let groups = Dictionary(grouping: store.items, by: store.groupDay)
        let days = store.orderedDays(groups.keys)
        return LazyVStack(alignment: .leading, spacing: 22) {
            if store.showingUploads {
                HStack {
                    Text("按归档日期查看刚上传的影像").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("返回时间线") { store.focusOnUploads([]) }.font(.subheadline)
                }
            } else if store.anchorMediaID != nil {
                HStack {
                    Label(store.archiveExpanded ? "完整时间线" : "归档位置", systemImage: "scope").foregroundStyle(.tint)
                    Spacer()
                    if store.archiveExpanded {
                        Button("回到最新") { store.focusOnUploads([]) }.font(.subheadline)
                    } else if !store.items.isEmpty {
                        Button("查看完整时间线") { showNewer(expanding: true) }
                            .font(.subheadline).disabled(store.loading)
                    }
                }
                if store.hasNewer {
                    Button { showNewer(expanding: false) } label: {
                        Label("加载较新的回忆", systemImage: "arrow.up")
                    }.frame(maxWidth: .infinity).disabled(store.loading)
                }
            } else {
                Picker("查看方式", selection: Binding(get: { store.byUpload }, set: store.setUploadOrder)) {
                    Text("按归档日期").tag(false)
                    Text("按上传时间").tag(true)
                }.pickerStyle(.segmented)
                Picker("影像类型", selection: $store.mediaType) {
                    Text("全部").tag(""); Text("照片").tag("photo")
                    Text("实况").tag("live_photo"); Text("视频").tag("video")
                }.pickerStyle(.segmented)
                HStack {
                    Text(store.usesUploadOrder ? "\(store.total) 项已上传影像" : "\(store.total) 份家庭回忆").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if store.hasFilters { Button("清除筛选") { store.resetFilters() }.font(.caption) }
                }
            }
            if !store.error.isEmpty {
                Text(store.error).foregroundStyle(.red)
                Button("重新加载") { Task { await store.load() } }
            }
            if store.items.isEmpty && !store.loading && store.error.isEmpty {
                if store.showingUploads { Text("这批影像已移除或暂时无法查看。") }
                else if store.usesUploadOrder && !store.hasFilters { Text("还没有已上传的影像。") }
                else { Text(store.hasFilters ? "没有符合条件的回忆，试试其他关键词或日期。" : "还没有回忆，去上传页珍藏第一张照片吧。") }
            }
            ForEach(days, id: \.self) { day in
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(groups[day] ?? [], id: \.stableID) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    if selecting {
                                        if let index = chosen.firstIndex(where: { $0.id == item.id }) { chosen.remove(at: index) }
                                        else if chosen.count < 200 { chosen.append(item) }
                                        else { selectionLimit = true }
                                    } else { selectedItem = item }
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        if let file = item.primary {
                                            NativeMediaImage(session: store.session, mediaID: item.id, fileID: file.id)
                                                .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay(alignment: .bottomLeading) {
                                                    if item.media_type == "live_photo" { Label("LIVE", systemImage: "livephoto").font(.caption2.bold()).padding(5).background(.regularMaterial, in: Capsule()).padding(7) }
                                                    if item.media_type == "video" { Image(systemName: "play.fill").padding(8).background(.regularMaterial, in: Circle()).padding(7) }
                                                }
                                        } else {
                                            Image(systemName: "book.closed").frame(maxWidth: .infinity).frame(height: 150).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                        }
                                        Text(item.label).font(.caption).lineLimit(2)
                                        if item.kind == "media" && store.anchorMediaID == item.id {
                                            Label("当前影像", systemImage: "scope").font(.caption.bold()).foregroundStyle(.tint)
                                        }
                                    }
                                }.buttonStyle(.plain)
                                .disabled(selecting && item.kind != "media")
                                .overlay(alignment: .topTrailing) {
                                    if selecting && item.kind == "media" {
                                        Image(systemName: chosen.contains(where: { $0.id == item.id }) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(.tint).padding(7).background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                                    }
                                }
                                .modifier(MediaReorderGesture(enabled: store.session.canEdit && !selecting && !store.isFocused && !store.usesUploadOrder && item.kind == "media", token: dragToken, item: item, store: store))
                                .contextMenu {
                                    if store.session.canEdit {
                                        Button(item.kind == "event" ? "编辑日记" : "编辑影像", systemImage: "square.and.pencil") { editingItem = item }
                                        if item.kind == "media" {
                                            Button("分享这项影像", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest(items: [item]) }
                                        }
                                    }
                                }
                                if store.usesUploadOrder && !selecting {
                                    if let date = item.uploadDate {
                                        Text("上传于 \(date.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Button { store.locate(item) } label: {
                                        Label("跳到归档 · \(item.day)", systemImage: "arrow.turn.down.right")
                                            .font(.caption)
                                    }.buttonStyle(.borderless)
                                }
                            }
                            .id(item.stableID)
                        }
                    }
                } header: {
                    HStack {
                        Text(day).font(.title3.bold())
                        Spacer()
                        if store.showingUploads && NativeDay.date(day) != nil {
                            Button("查看当天全部") { store.showDay(day) }.font(.caption)
                        } else if !store.usesUploadOrder && store.session.canEdit {
                            Menu {
                                if NativeDay.date(day) != nil {
                                    Button("分享当天", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest(day: day) }
                                    Button("上传到当天", systemImage: "plus") { appendToDay(day) }
                                    Button("给当天写日记", systemImage: "book") { diaryRequest = NativeDiaryRequest(day: day) }
                                }
                                Button("选择当天已加载的影像", systemImage: "checkmark.circle") { selectLoadedDay(groups[day] ?? []) }
                                Button("当天设置", systemImage: "slider.horizontal.3") { daySettings = day }
                            } label: { Label("当天操作", systemImage: "ellipsis.circle").font(.caption) }
                        }
                    }
                }.id("day-\(day)")
            }
            if store.loading { ProgressView().frame(maxWidth: .infinity) }
            if store.cursor != nil {
                Button(store.archiveExpanded ? "加载较早的回忆" : "加载更多回忆") { Task { await store.load(more: true) } }
                    .frame(maxWidth: .infinity).disabled(store.loading)
            }
        }.padding()
    }

    private func showNewer(expanding: Bool) {
        let first = store.items.first?.stableID
        positionBeforePrepend = first
        Task {
            if expanding { await store.expandArchive() }
            else { await store.loadNewer() }
            if store.items.first?.stableID == first { positionBeforePrepend = nil }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isFocused { timelineList.id(store.queryKey) }
                else { timelineList.searchable(text: $store.search, prompt: "搜索标题、批次、备注或地点") }
            }
            .navigationTitle(store.showingUploads ? "刚上传的回忆" : "家庭时光")
            .onChange(of: store.uploadedMediaIDs) { _ in
                selecting = false
                chosen = []
            }
            .onChange(of: store.byUpload) { _ in selecting = false; chosen = [] }
            .onChange(of: store.anchorMediaID) { _ in
                selecting = false
                chosen = []
                positionBeforePrepend = nil
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if store.session.canEdit {
                            Button { showingTrash = true } label: { Image(systemName: "trash") }.accessibilityLabel("回收站")
                            Button(selecting ? "取消" : "选择") { selecting.toggle(); chosen = [] }
                            Button { shareRequest = NativeShareRequest() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享与管理") }
                        if !store.isFocused {
                            Button { showingFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("人物、日期与排序")
                        }
                    }
                }
            }
            .refreshable { await store.loadProfiles(); await store.load() }
            .task { await store.loadProfiles() }
            .task(id: store.queryKey) {
                if store.isFocused { await store.loadIfNeeded() }
                else {
                    do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); await store.loadIfNeeded() } catch { }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text("已选 \(chosen.count) / 200 项")
                        Spacer()
                        Menu("更多操作") {
                            Button("批量整理", systemImage: "slider.horizontal.3") { batchEdit = true }
                            Button("用所选影像写日记", systemImage: "book") {
                                diaryRequest = NativeDiaryRequest(day: chosen.first?.day, items: chosen)
                            }
                        }.disabled(chosen.isEmpty)
                        Button("分享所选") { shareRequest = NativeShareRequest(items: chosen) }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                    }.padding().background(.regularMaterial)
                }
            }
            .alert("一次最多选择 200 项", isPresented: $selectionLimit) { Button("知道了", role: .cancel) { } }
            .sheet(item: $shareRequest) { request in
                NativeSharingView(session: store.session, day: request.day, selectedItems: request.items)
            }
            .sheet(isPresented: $showingFilter) {
                NavigationStack {
                    List {
                        Section("时间与排序") {
                            Toggle("从早到晚", isOn: $store.ascending)
                            Toggle("按日期范围查找", isOn: $store.useDateRange)
                            if store.useDateRange {
                                DatePicker("开始日期", selection: $store.startDate, displayedComponents: .date)
                                DatePicker("结束日期", selection: $store.endDate, displayedComponents: .date)
                                Text(store.usesUploadOrder ? "按上传日期查找，包含结束当天。" : "按归档日期查找，包含结束当天。未知日期不在日期范围中。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("清除所有筛选") { store.resetFilters() }
                        Button("所有家人") { store.selected = [] }
                        ForEach(store.profiles) { profile in
                            Toggle(profile.label, isOn: Binding(get: { store.selected.contains(profile.id) }, set: { if $0 { store.selected.insert(profile.id) } else { store.selected.remove(profile.id) } }))
                        }
                    }.navigationTitle("筛选与排序")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingFilter = false } } }
                }
            }
            .sheet(isPresented: $showingTrash) { NativeMediaTrash(store: store) }
            .sheet(item: $editingItem) { item in
                if item.kind == "event" {
                    NativeDiaryEditor(session: store.session, profiles: store.profiles, existing: item) { Task { await store.load() } }
                } else {
                    NativeMediaInfo(session: store.session, item: item, profiles: store.profiles) { Task { await store.load() } }
                }
            }
            .sheet(item: $diaryRequest) { request in
                NativeDiaryEditor(session: store.session, profiles: store.profiles, request: request) {
                    chosen = []
                    selecting = false
                    Task { await store.load() }
                }
            }
            .sheet(isPresented: Binding(get: { daySettings != nil }, set: { if !$0 { daySettings = nil } })) {
                if let day = daySettings { NativeDaySettings(store: store, day: day) }
            }
            .sheet(isPresented: $batchEdit) {
                NativeBatchMediaEditor(store: store, items: chosen) {
                    chosen = []
                    selecting = false
                }
            }
            .fullScreenCover(item: $selectedItem) { item in
                NativeMediaPager(store: store, initial: item)
            }
        }
    }

    private func selectLoadedDay(_ items: [NativeTimelineItem]) {
        let media = items.filter { $0.kind == "media" }
        guard !media.isEmpty else { return }
        chosen = Array(media.prefix(200))
        selecting = true
        selectionLimit = media.count > 200
    }
}

private struct MediaReorderGesture: ViewModifier {
    let enabled: Bool
    let token: String
    let item: NativeTimelineItem
    let store: NativeTimelineStore
    @State private var targeted = false

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(object: "\(token):\(item.id)" as NSString) }
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: targeted ? 2 : 0).allowsHitTesting(false) }
                .onDrop(of: [UTType.plainText], isTargeted: $targeted, perform: { (providers: [NSItemProvider]) -> Bool in
                    guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        guard let value = value as? String, value.hasPrefix(token + ":"),
                              let id = Int(value.dropFirst(token.count + 1)) else { return }
                        Task { @MainActor in
                            guard let source = store.items.first(where: { $0.kind == "media" && $0.id == id }) else { return }
                            await store.reorder(source, relativeTo: item)
                        }
                    }
                    return true
                })
        } else { content }
    }
}

struct NativePreviewPosition {
    let day: String
    let withinDay: String
    let overall: String
}

private struct NativeMediaPager: View {
    @ObservedObject var store: NativeTimelineStore
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [NativeTimelineItem]
    @State private var selection: String
    @State private var uploadTotal: Int
    @State private var uploadDayTotals: [String: Int] = [:]
    @State private var paging = false
    @State private var pendingStep: Int?

    init(store: NativeTimelineStore, initial: NativeTimelineItem) {
        self.store = store
        let media = store.mediaPages(store.items)
        _pages = State(initialValue: initial.kind == "event" || !media.contains(where: { $0.stableID == initial.stableID }) ? [initial] : media)
        _selection = State(initialValue: initial.stableID)
        _uploadTotal = State(initialValue: store.total)
    }

    var body: some View {
        let activeIndex = pages.firstIndex { $0.stableID == selection }
        let activeItem = activeIndex.map { pages[$0] }
        Group {
            if let activeIndex, let item = activeItem {
                NativeMediaDetail(
                    session: store.session, initial: item, profiles: store.profiles,
                    pagePosition: item.kind == "media" ? position(at: activeIndex) : nil,
                    previous: activeIndex > 0 || store.hasNewer && item.kind == "media" ? { move(-1) } : nil,
                    next: activeIndex + 1 < pages.count || store.cursor != nil && item.kind == "media" ? { move(1) } : nil,
                    onSaved: { Task { await store.load() } },
                    onDeleted: { remove(item) },
                    onLocate: store.usesUploadOrder ? { current in dismiss(); store.locate(current) } : nil
                ).id(item.stableID)
            }
        }
        .background(.black)
        .task(id: selection) {
            guard let activeIndex, activeItem?.kind == "media" else { return }
            if activeIndex >= pages.count - 2, store.cursor != nil { await extend(1) }
            else if activeIndex <= 1, store.hasNewer { await extend(-1) }
        }
        .task(id: activeItem.map(store.groupDay)) {
            guard store.usesUploadOrder, let activeItem, activeItem.kind == "media" else { return }
            let day = store.groupDay(activeItem)
            guard uploadDayTotals[day] == nil, store.cursor != nil,
                  pages.last.map(store.groupDay) == day else { return }
            if let count = try? await store.uploadDayTotal(day), !Task.isCancelled {
                uploadDayTotals[day] = count
            }
        }
    }

    private func position(at index: Int) -> NativePreviewPosition {
        let item = pages[index]
        let day = store.groupDay(item)
        let heading = day.replacingOccurrences(of: "-", with: ".")
        if let position = item.media_position {
            return NativePreviewPosition(day: heading,
                                         withinDay: "当天 \(position.day_index) / \(position.day_total)",
                                         overall: "全部 \(position.index) / \(position.total)")
        }
        let sameDay = pages.filter { store.groupDay($0) == day }
        let dayIndex = (sameDay.firstIndex { $0.stableID == item.stableID } ?? 0) + 1
        let completeBefore = store.anchorMediaID == nil || store.archiveExpanded && !store.hasNewer
        let wholeDay = (completeBefore || pages.first.map(store.groupDay) != day) &&
                       (store.cursor == nil || pages.last.map(store.groupDay) != day)
        let dayTotal = uploadDayTotals[day] ?? (wholeDay ? sameDay.count : nil)
        let overall = store.usesUploadOrder && uploadTotal >= pages.count
            ? "全部 \(index + 1) / \(uploadTotal)"
            : "\(completeBefore && store.cursor == nil ? "全部" : "已加载") \(index + 1) / \(pages.count)"
        return NativePreviewPosition(day: store.usesUploadOrder ? "上传 · \(heading)" : heading,
                                     withinDay: dayTotal.map { "当天 \(dayIndex) / \($0)" } ?? "当天已加载 \(dayIndex) / \(sameDay.count)",
                                     overall: overall)
    }

    private func move(_ step: Int) {
        if selectAdjacent(step) { pendingStep = nil; return }
        pendingStep = step
        Task { await extend(step) }
    }

    @discardableResult
    private func selectAdjacent(_ step: Int) -> Bool {
        guard let index = pages.firstIndex(where: { $0.stableID == selection }),
              pages.indices.contains(index + step) else { return false }
        selection = pages[index + step].stableID
        return true
    }

    private func extend(_ step: Int) async {
        guard !paging else { return }
        paging = true
        defer {
            paging = false
            if let pendingStep {
                self.pendingStep = nil
                selectAdjacent(pendingStep)
            }
        }
        while !Task.isCancelled && (step > 0 ? store.cursor != nil : store.hasNewer) {
            let edge = (step > 0 ? store.items.last : store.items.first)?.stableID
            if step > 0 { await store.load(more: true) }
            else { await store.loadNewer() }
            guard !Task.isCancelled else { return }
            let known = Set(pages.map(\.stableID))
            let added = store.items.filter { $0.kind == "media" && !known.contains($0.stableID) }
            if !added.isEmpty {
                pages = store.mediaPages(step > 0 ? pages + added : added + pages)
                return
            }
            if (step > 0 ? store.items.last : store.items.first)?.stableID == edge { return }
        }
    }

    private func remove(_ item: NativeTimelineItem) {
        guard let index = pages.firstIndex(where: { $0.stableID == item.stableID }) else { return }
        pages.remove(at: index)
        if let position = item.media_position {
            for offset in pages.indices {
                let sameDay = store.groupDay(pages[offset]) == store.groupDay(item)
                pages[offset].media_position?.remove(position, sameDay: sameDay)
            }
        } else if store.usesUploadOrder {
            uploadTotal -= 1
            uploadDayTotals[store.groupDay(item)]? -= 1
        }
        if pages.isEmpty { dismiss() }
        else { selection = pages[min(index, pages.count - 1)].stableID }
        Task { await store.load() }
    }
}

struct NativeMediaDetail: View {
    @ObservedObject var session: NativeSession
    let initial: NativeTimelineItem
    let profiles: [UploadProfile]
    let pagePosition: NativePreviewPosition?
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let onSaved: () -> Void
    let onDeleted: () -> Void
    let onLocate: ((NativeTimelineItem) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: NativeTimelineItem?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var message = ""
    @State private var observation: NSKeyValueObservation?
    @State private var playbackTask: Task<Void, Never>?
    @State private var showingInfo = false
    @State private var showingShare = false
    @State private var zoom = 1.0
    @State private var imageScale = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero
    @State private var confirmingDelete = false
    @State private var savingToPhotos = false
    @State private var deleting = false
    private var item: NativeTimelineItem { detail ?? initial }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    if item.kind == "event" {
                        ScrollView { Text(item.content ?? "").frame(maxWidth: .infinity, alignment: .leading).padding() }.foregroundStyle(.white)
                    } else if let player {
                        VideoPlayer(player: player).onDisappear { player.pause() }
                            .overlay {
                                if item.media_type == "live_photo" {
                                    Button(action: play) { Color.clear.contentShape(Rectangle()) }
                                        .buttonStyle(.plain).accessibilityLabel("从头播放实况照片")
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if item.media_type == "live_photo" { liveBadge }
                            }
                    } else if let file = item.primary {
                        NativeMediaImage(session: session, mediaID: item.id, fileID: file.id, purpose: item.media_type == "video" ? "thumbnail" : "preview")
                            .scaleEffect(zoom).offset(offset)
                            .gesture(DragGesture().onChanged { value in
                                offset = CGSize(width: dragOrigin.width + value.translation.width, height: dragOrigin.height + value.translation.height)
                            }.onEnded { _ in dragOrigin = offset }, including: zoom > 1 ? .all : .subviews)
                            .simultaneousGesture(MagnificationGesture().onChanged { zoom = min(4, max(1, imageScale * $0)) }.onEnded { _ in
                                imageScale = zoom
                                if zoom == 1 { offset = .zero; dragOrigin = .zero }
                            })
                            .clipped()
                            .onTapGesture { if item.media_type == "live_photo" { play() } }
                            .overlay(alignment: .topLeading) {
                                if item.media_type == "live_photo" { liveBadge }
                            }
                            .overlay {
                                if item.media_type == "video" { videoPlayControl }
                            }
                    } else if item.media_type == "video" {
                        Color.black.overlay { videoPlayControl }
                    } else {
                        Spacer(minLength: 0)
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.white).padding(.horizontal) }
                    if loading && item.media_type != "video" {
                        ProgressView("正在准备预览…").tint(.white).foregroundStyle(.white)
                    }
                    if let pagePosition {
                        HStack(spacing: 16) {
                            Button(action: { if let previous { stop(); previous() } }) { Image(systemName: "chevron.left").padding(8) }
                                .accessibilityLabel("上一项").disabled(previous == nil || savingToPhotos)
                            VStack(spacing: 4) {
                                Text(pagePosition.day).font(.headline)
                                ViewThatFits {
                                    HStack(spacing: 12) { Text(pagePosition.withinDay); Text(pagePosition.overall) }
                                    VStack(spacing: 2) { Text(pagePosition.withinDay); Text(pagePosition.overall) }
                                }.font(.caption).foregroundStyle(.white.opacity(0.75))
                            }
                            .monospacedDigit().accessibilityElement(children: .combine)
                            Button(action: { if let next { stop(); next() } }) { Image(systemName: "chevron.right").padding(8) }
                                .accessibilityLabel("下一项").disabled(next == nil || savingToPhotos)
                        }
                        .foregroundStyle(.white)
                        .padding(.bottom, zoom != 1 ? 0 : 8)
                    }
                    if zoom != 1 {
                        Button("适应屏幕") { resetZoom() }.padding(.bottom).foregroundStyle(.white)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { value in
                let x = value.translation.width
                let y = value.translation.height
                guard zoom == 1, !savingToPhotos, !deleting,
                      abs(x) > 48, abs(x) > abs(y) * 1.5 else { return }
                if let navigate = x < 0 ? next : previous { stop(); navigate() }
            })
            .disabled(deleting)
            .navigationTitle(item.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { stop(); dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if item.kind != "event" || session.canEdit {
                            Button { stop(); showingInfo = true } label: {
                                Image(systemName: session.canEdit ? "square.and.pencil" : "info.circle")
                            }.accessibilityLabel(item.kind == "event" ? "编辑日记" : session.canEdit ? "编辑影像" : "查看影像信息")
                        }
                        if session.canEdit && (item.kind != "event" || NativeDay.date(item.day) != nil) {
                            Button { stop(); showingShare = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(item.kind == "event" ? "分享当天回忆" : "分享这项影像")
                        }
                        Menu {
                            if item.kind == "event" && !session.canEdit {
                                Button("查看信息", systemImage: "info.circle") { stop(); showingInfo = true }
                            }
                            if let onLocate {
                                Button("跳到归档位置", systemImage: "scope") { stop(); onLocate(item) }
                            }
                            if item.kind != "event" {
                                Button("保存到相册", systemImage: "square.and.arrow.down") { Task { await saveToPhotos() } }
                                    .disabled(savingToPhotos || deleting)
                                if session.canEdit {
                                    Button("移到回收站", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                                        .disabled(savingToPhotos || deleting)
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("影像操作")
                    }
                }
            }
            .task {
                guard initial.kind != "event" else { return }
                if initial.media_type == "live_photo" { play() }
                do {
                    let current: NativeTimelineItem = try await session.get("/media/\(initial.id)")
                    try Task.checkCancellation()
                    detail = current
                } catch { if !Task.isCancelled { message = friendly(error) } }
            }
            .alert("移到回收站？", isPresented: $confirmingDelete) {
                Button("移到回收站", role: .destructive) { Task { await trash() } }
                Button("取消", role: .cancel) {}
            } message: { Text("可以从时间线的回收站恢复这项影像。") }
            .sheet(isPresented: $showingShare) { NativeSharingView(session: session, day: item.day, selectedItems: item.kind == "event" ? nil : [item]) }
            .sheet(isPresented: $showingInfo) {
                if item.kind == "event" && session.canEdit {
                    NativeDiaryEditor(session: session, profiles: profiles, existing: item) { Task { await reloadDiary() } }
                } else {
                    NativeMediaInfo(session: session, item: item, profiles: profiles) {
                        onSaved()
                        Task { do { detail = try await session.get("/media/\(initial.id)") } catch { message = friendly(error) } }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                if let ended = notification.object as? AVPlayerItem, ended === player?.currentItem, item.motion != nil { stop() }
            }
            .onDisappear { stop() }
            .onChange(of: scenePhase) { if $0 != .active { stop() } }
        }
    }
    private func reloadDiary() async {
        do {
            var updated: NativeTimelineItem = try await session.get("/events/\(initial.id)")
            updated.kind = "event"
            detail = updated
            onSaved()
        } catch let error as NativeAPIError where error.status == 404 { onDeleted() }
        catch { message = friendly(error) }
    }

    private func resetZoom() {
        zoom = 1
        imageScale = 1
        offset = .zero
        dragOrigin = .zero
    }

    private func saveToPhotos() async {
        guard !savingToPhotos, !deleting else { return }
        stop()
        savingToPhotos = true
        message = "正在下载原件并保存到相册…"
        defer { savingToPhotos = false }
        do {
            try await NativePhotoExport.save(item, session: session)
            message = item.media_type == "live_photo" ? "实况照片已保存到系统相册。" : "原件已保存到系统相册。"
        } catch { message = friendly(error) }
    }

    private func trash() async {
        guard !deleting, !savingToPhotos else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await session.write("/media/\(initial.id)", method: "DELETE", json: [:])
            stop()
            onDeleted()
        } catch { message = friendly(error) }
    }

    private var liveBadge: some View {
        Button(action: play) {
            Label("LIVE", systemImage: "livephoto").padding(8).background(.regularMaterial, in: Capsule())
        }.buttonStyle(.plain).padding().accessibilityLabel("从头播放实况照片")
    }

    @ViewBuilder private var videoPlayControl: some View {
        if loading {
            ProgressView()
                .tint(.white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.64), in: Circle())
                .accessibilityLabel("正在准备视频")
        } else {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .offset(x: 2)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.64), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放视频")
            .disabled(savingToPhotos)
        }
    }

    private func stop() {
        observation?.invalidate(); observation = nil
        playbackTask?.cancel(); playbackTask = nil
        let hadPlayer = player != nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; loading = false
        if hadPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func play() {
        guard !savingToPhotos, !deleting else { return }
        let live = item.media_type == "live_photo"
        guard let file = live ? item.motion : item.primary else {
            message = live ? "实况照片缺少配对资源。" : "影像原件不可用。"
            return
        }
        stop(); message = ""; loading = true
        playbackTask = Task {
            do {
                let resource: NativeMediaResource = try await session.get("/media/\(item.id)/files/\(file.id)/url?purpose=preview")
                try Task.checkCancellation()
                guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                    throw UploadFailure(message: resource.status == "failed" ? "动态预览生成失败，请稍后重试。原件已安全保存。" : "动态预览正在生成，请稍后再试。")
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                // AVPlayer receives only the backend's signed media URL, never login headers.
                let value = AVPlayer(url: url)
                value.isMuted = false; value.volume = 1
                player = value
                observation = value.currentItem?.observe(\.status, options: [.new]) { playbackItem, _ in
                    if playbackItem.status == .failed {
                        Task { @MainActor in
                            guard player === value else { return }
                            stop()
                            message = live ? "播放失败，请点 LIVE 重试。" : "播放失败，请点播放图标重试。"
                        }
                    }
                }
                value.play()
            } catch { if !Task.isCancelled { message = friendly(error) } }
            if !Task.isCancelled { loading = false }
        }
    }
}
