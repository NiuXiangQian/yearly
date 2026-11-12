import SwiftUI
import AVKit
import ImageIO
import UniformTypeIdentifiers

// Decoded images stay in bounded memory; processed previews also persist in the app cache.
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
    private static let disk = NativeLocalCache()
    private static let io = DispatchQueue(label: "family.yearly.image-cache", qos: .utility)
    static func image(for key: String, scope: String? = nil) async -> UIImage? {
        if let entry = cache.object(forKey: key as NSString), Date().timeIntervalSince(entry.created) < 120 {
            return entry.image
        }
        guard let scope else { return nil }
        let disk = disk
        let image: UIImage? = await withCheckedContinuation { continuation in
            io.async {
                let image = disk.data(scope: scope, key: key, category: "images").flatMap(UIImage.init(data:))
                continuation.resume(returning: image?.preparingForDisplay())
            }
        }
        if let image { insert(image, for: key) }
        return image
    }

    static func insert(_ image: UIImage, for key: String, scope: String? = nil) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        guard cost > 0, cost <= 32 * 1024 * 1024 else { return }
        cache.setObject(Entry(image), forKey: key as NSString, cost: cost)
        if let scope {
            let disk = disk
            io.async {
                if let data = image.pngData() {
                    disk.insert(data, scope: scope, key: key, category: "images", lifetime: 7 * 24 * 60 * 60)
                }
            }
        }
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
            if attempt == 0, let cached = await NativeImageCache.image(for: cacheKey, scope: session.cacheScope) {
                guard !Task.isCancelled, session.account?.id == owner else { return }
                image = cached; return
            }
            image = nil
            do {
                let resource: NativeMediaResource = try await session.get("/media/\(mediaID)/files/\(fileID)/url?purpose=\(purpose)")
                guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                    throw UploadFailure(message: "预览正在准备。")
                }
                let result = try await NativeMediaNetwork.image(url, maximumDimension: purpose == "thumbnail" ? 512 : 2048)
                try Task.checkCancellation()
                guard session.account?.id == owner else { return }
                NativeImageCache.insert(result, for: cacheKey, scope: session.cacheScope)
                image = result
            } catch { if !Task.isCancelled { failure = friendly(error) } }
        }
        .onDisappear { image = nil }
        .accessibilityLabel(failure.isEmpty ? "影像预览" : failure)
    }
}

struct NativeTimelineView: View {
    @ObservedObject var store: NativeTimelineStore
    var topRequest = 0
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
    @State private var positionBeforePrepend: (day: String, originY: CGFloat)?
    @State private var currentDay = ""
    @State private var pendingRailDay: String?
    @State private var returningToStart = false
    @State private var visibleEndItem: String?
    @State private var collapsedMonths: [String: Bool] = [:]
    @State private var collapseAllMonths = false
    @State private var collapsedEndVisible = false
    @State private var expandedDays: [String: Bool] = [:]
    @State private var expandAllDays = false
    @State private var foldedDayEndVisible = false
    @State private var collapsingDay: String?
    @State private var viewport = NativeTimelineViewport()
    @State private var refreshing = false
    @State private var scrollRevision = 0
    private var timelineScroll: UIScrollView? { viewport.scroll }
    private var dayFrames: [String: CGRect] { viewport.days }
    private var contentHeight: CGFloat { viewport.height }
    @State private var railHeld = false
    @State private var scrubDay: String?
    private var timelineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                timelineContent.coordinateSpace(name: "timeline-content").background(NativeTimelineScrollReader(refresh: refreshTimeline, resolve: { value in
                    viewport.scroll = value
                    restoreReadingPosition()
                    if scrubDay != nil { scrollToDay() }
                    loadMoreIfNeeded()
                }, didScroll: { value in
                    updateReadingDay(value)
                    loadMoreIfNeeded()
                }))
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: NativeTimelineDayPositions.self,
                                           value: NativeTimelineLayout(height: geometry.size.height))
                })
            }
                .id(scrollRevision)
                .onPreferenceChange(NativeTimelineDayPositions.self) { layout in
                    viewport.days = layout.days
                    viewport.height = layout.height
                    restoreReadingPosition()
                    if scrubDay != nil || pendingRailDay != nil { scrollToDay() }
                    if currentDay.isEmpty, let scroll = timelineScroll { updateReadingDay(scroll) }
                    if newerEndVisible { loadMoreIfNeeded() }
                }
                .safeAreaInset(edge: .leading, spacing: 0) {
                    if !store.isFocused && store.railDays.count > 1 {
                        GeometryReader { geometry in
                            NativeTimelineRail(days: store.railDays, current: currentDay, hold: { held in
                                railHeld = held
                                if !held { scrollToDay(); loadMoreIfNeeded() }
                            }, scrub: { day in
                                guard scrubDay != day && currentDay != day else { return }
                                currentDay = day
                                scrubDay = day
                                collapsedMonths[String(day.prefix(7))] = false
                                if dayFrames[day] != nil && store.items.contains(where: { store.groupDay($0) == day }) {
                                    scrollToDay()
                                } else if !store.loading { store.jump(to: day) }
                            }) { day in
                                currentDay = day
                                scrubDay = day
                                collapsedMonths[String(day.prefix(7))] = false
                                if dayFrames[day] != nil && store.items.contains(where: { store.groupDay($0) == day }) {
                                    scrollToDay()
                                } else { store.jump(to: day) }
                            }
                            .frame(height: geometry.size.height)
                        }.frame(width: 44).zIndex(1)
                    }
                }
                .onChange(of: topRequest) { _ in
                    scrubDay = nil
                    pendingRailDay = nil
                    positionBeforePrepend = nil
                    railHeld = false
                    if store.anchorDay != nil {
                        returningToStart = true
                        store.focusOnUploads([])
                    } else {
                        proxy.scrollTo("timeline-start", anchor: .top)
                        if let scroll = timelineScroll {
                            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
                        }
                        currentDay = store.items.first.map(store.groupDay) ?? ""
                    }
                }
                .onChange(of: scrubDay) { day in
                    if let day, dayFrames[day] == nil { proxy.scrollTo("day-\(day)", anchor: .top) }
                }
                .onChange(of: store.items.count) { _ in
                    if let day = scrubDay ?? pendingRailDay, dayFrames[day] == nil {
                        proxy.scrollTo("day-\(day)", anchor: .top)
                    }
                }
                .onChange(of: collapsingDay) { day in
                    guard let day else { return }
                    proxy.scrollTo("day-\(day)", anchor: .top)
                    collapsingDay = nil
                }
                .onChange(of: store.loading) { _ in finishLoading() }
                .onChange(of: store.items.first?.stableID) { _ in
                    if let position = positionBeforePrepend, let first = store.items.first,
                       store.groupDay(first) == position.day { positionBeforePrepend = nil }
                }
        }
    }

    private var timelineContent: some View {
        let groups = store.groupedItems
        let days = store.orderedDays(groups.keys)
        let months = Dictionary(grouping: days) { String($0.prefix(7)) }
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
                    if store.archiveExpanded || store.items.isEmpty {
                        Button("回到最新") { store.focusOnUploads([]) }.font(.subheadline)
                    } else if !store.items.isEmpty {
                        Button("查看完整时间线") { prependNewer(expandingArchive: true) }
                            .font(.subheadline).disabled(store.loading)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.usesUploadOrder ? "上传记录" : "所有回忆").font(.title2.bold())
                    Spacer()
                    Text("\(store.total) 项").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                if store.hasFilters {
                    HStack(alignment: .top, spacing: 10) {
                        Text(filterSummary).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("清除") { store.resetFilters() }
                            .buttonStyle(NativeActionStyle(kind: .quiet, compact: true))
                    }
                }
                if let anchorDay = store.anchorDay {
                    HStack {
                        Text("已定位到 \(anchorDay)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("回到起点") { returningToStart = true; store.focusOnUploads([]) }.font(.caption)
                    }
                }
            }
            if !store.error.isEmpty {
                Label(store.error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red)
                Button("重新加载") { Task { await store.load() } }.buttonStyle(NativeActionStyle())
            }
            if store.items.isEmpty && !store.loading && store.error.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: store.hasFilters ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(NativeTheme.accent)
                    Text(store.hasFilters ? "没有符合条件的影像" : "还没有家庭回忆").font(.headline)
                    Text(store.showingUploads ? "这批影像已移除或暂时无法查看。" : store.hasFilters ? "试试其他上传人、人物或日期范围。" : "从上传页添加第一张照片或视频。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.hasFilters {
                        Button("清除筛选") { store.resetFilters() }.buttonStyle(NativeActionStyle())
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            ForEach(store.orderedDays(months.keys), id: \.self) { month in
                let monthDays = months[month] ?? []
                let closed = monthIsCollapsed(month)
                Section {
                    if !closed {
                        ForEach(monthDays, id: \.self) { day in
                            daySection(day, items: groups[day] ?? [])
                        }
                    }
                } header: {
                    if !store.showingUploads {
                        Button { collapsedMonths[month] = !closed } label: {
                            HStack(spacing: 10) {
                                Image(systemName: closed ? "chevron.right" : "chevron.down").font(.caption)
                                Text(NativeDay.date(month + "-01").map {
                                    $0.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
                                } ?? "拍摄时间未知").font(.headline)
                                Spacer(minLength: 4)
                                Text("\(monthDays.count) 天").font(.caption).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { Rectangle().fill(NativeTheme.line).frame(height: 1) }
                        }
                        .buttonStyle(.plain).disabled(selecting)
                        .accessibilityValue(closed ? "已收起" : "已展开")
                        .accessibilityHint("按月展开或收起回忆")
                    }
                }.id("month-\(month)")
            }
            if store.cursor != nil, store.error.isEmpty, let lastDay = days.last, monthIsCollapsed(String(lastDay.prefix(7))) {
                Color.clear.frame(height: 44)
                    .onAppear { collapsedEndVisible = true; loadMoreIfNeeded() }
                    .onDisappear { collapsedEndVisible = false }
            }
            if store.loading { ProgressView().frame(maxWidth: .infinity) }
        }.padding().id("timeline-start")
    }

    private func monthIsCollapsed(_ month: String) -> Bool {
        !store.showingUploads && !selecting && (collapsedMonths[month] ?? collapseAllMonths)
    }

    private func daySection(_ day: String, items dayItems: [NativeTimelineItem]) -> some View {
        let expanded = selecting || store.isFocused || (expandedDays[day] ?? expandAllDays)
        let visibleItems = expanded ? dayItems : Array(dayItems.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(.tint).frame(width: 7, height: 7)
                Text(day.replacingOccurrences(of: "-", with: "."))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(dayItems.count) 项").font(.caption).foregroundStyle(.secondary)
                if store.showingUploads && NativeDay.date(day) != nil {
                    Button("查看当天全部") { store.showDay(day) }.font(.caption)
                } else if !store.usesUploadOrder && store.session.canEdit {
                    Menu {
                        if NativeDay.date(day) != nil {
                            Button("分享当天", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest(day: day) }
                            Button("上传到当天", systemImage: "plus") { appendToDay(day) }
                            Button("给当天写日记", systemImage: "book") { diaryRequest = NativeDiaryRequest(day: day) }
                        }
                        Button("选择当天已加载的影像", systemImage: "checkmark.circle") { selectLoadedDay(dayItems) }
                        Button("当天设置", systemImage: "slider.horizontal.3") { daySettings = day }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("当天操作")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(visibleItems, id: \.stableID) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            if selecting && item.editable(by: store.session.account) {
                                if let index = chosen.firstIndex(where: { $0.id == item.id }) { chosen.remove(at: index) }
                                else if chosen.count < 200 { chosen.append(item) }
                                else { selectionLimit = true }
                            } else { selectedItem = item }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                if let file = item.primary {
                                    NativeMediaImage(session: store.session, mediaID: item.id, fileID: file.id)
                                        .aspectRatio(4 / 3, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(alignment: .bottomLeading) {
                                            if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Text(title).font(.caption).foregroundStyle(.white).lineLimit(1)
                                                    .padding(.leading, item.media_type == "live_photo" ? 68 : 10)
                                                    .padding(.trailing, item.media_type == "video" ? 44 : 10)
                                                    .padding(.bottom, 10).padding(.top, 24)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                            }
                                        }
                                        .overlay(alignment: .bottomLeading) {
                                            if item.media_type == "live_photo" {
                                                Label("LIVE", systemImage: "livephoto").font(.caption2.bold())
                                                    .padding(5).background(.regularMaterial, in: Capsule()).padding(7)
                                            }
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            if item.media_type == "video" {
                                                Image(systemName: "play.fill").padding(8)
                                                    .background(.regularMaterial, in: Circle()).padding(7)
                                            }
                                        }
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("成长日记").font(.caption2).foregroundStyle(.tint)
                                        Text(item.label).font(.headline).lineLimit(2)
                                        Text(item.content ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                                    .aspectRatio(4 / 3, contentMode: .fit)
                                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                }
                                if item.kind == "media" && store.anchorMediaID == item.id {
                                    Label("当前影像", systemImage: "scope").font(.caption.bold()).foregroundStyle(.tint)
                                }
                            }
                        }.buttonStyle(.plain)
                        .accessibilityLabel(item.label)
                        .disabled(selecting && item.kind != "media")
                        .overlay(alignment: .topTrailing) {
                            if selecting && item.kind == "media" && item.editable(by: store.session.account) {
                                Image(systemName: chosen.contains(where: { $0.id == item.id }) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(.tint).padding(7).background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if !item.editable(by: store.session.account) {
                                Label("已锁定", systemImage: "lock.fill").font(.caption2)
                                    .padding(6).background(.regularMaterial, in: Capsule()).padding(7).allowsHitTesting(false)
                            }
                        }
                        .modifier(MediaReorderGesture(enabled: item.editable(by: store.session.account) && !selecting && !store.isFocused && !store.usesUploadOrder && item.kind == "media", token: dragToken, item: item, store: store))
                        .contextMenu {
                            if item.editable(by: store.session.account) {
                                Button(item.kind == "event" ? "编辑日记" : "编辑影像", systemImage: "square.and.pencil") { editingItem = item }
                                if item.kind == "media" {
                                    Button("分享这项影像", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest(items: [item]) }
                                }
                            }
                        }
                        if item.kind == "media" {
                            Label("上传人 · " + (item.owner_name ?? "未记录"), systemImage: "person.crop.circle")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                                .accessibilityLabel("上传人，" + (item.owner_name ?? "未记录"))
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
                    .onAppear {
                        if item.stableID == store.items.last?.stableID {
                            visibleEndItem = item.stableID
                            loadMoreIfNeeded()
                        }
                    }
                    .onDisappear {
                        if visibleEndItem == item.stableID { visibleEndItem = nil }
                    }
                }
            }
            if dayItems.count > 8 && !selecting && !store.isFocused {
                Button {
                    if expanded {
                        expandedDays[day] = false
                        collapsingDay = day
                    } else { expandedDays[day] = true }
                } label: {
                    Label(expanded ? "收起当天影像" : "展开其余 \(dayItems.count - 8) 项",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderless)
                if !expanded && store.items.last.map(store.groupDay) == day && store.cursor != nil {
                    Color.clear.frame(height: 1)
                        .onAppear { foldedDayEndVisible = true; loadMoreIfNeeded() }
                        .onDisappear { foldedDayEndVisible = false }
                }
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: NativeTimelineDayPositions.self,
                                   value: NativeTimelineLayout(days: [day: geometry.frame(in: .named("timeline-content"))]))
        })
        .id("day-\(day)")
    }

    private func refreshTimeline() async {
        refreshing = true
        scrubDay = nil
        pendingRailDay = nil
        positionBeforePrepend = nil
        returningToStart = false
        async let profiles: Void = store.loadProfiles()
        async let uploaders: Void = store.loadUploaders(refresh: true)
        await store.load(refresh: true)
        _ = await (profiles, uploaders)
        if store.error.isEmpty {
            // Recreate the scroll layout after replacing a paged window. This
            // discards LazyVStack's old height estimates and pull-down offset.
            viewport.days = [:]
            viewport.height = 0
            currentDay = store.items.first.map(store.groupDay) ?? ""
            scrollRevision += 1
        }
        refreshing = false
    }

    private var scrollLayoutReady: Bool {
        guard let scroll = timelineScroll else { return false }
        return contentHeight > 0 && abs(scroll.contentSize.height - contentHeight) < 1
    }

    private func restoreReadingPosition() {
        guard !refreshing, scrollLayoutReady, let position = positionBeforePrepend, let scroll = timelineScroll,
              let frame = dayFrames[position.day], frame.minY != position.originY,
              scroll.contentSize.height >= frame.maxY else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + frame.minY - position.originY), animated: false)
        positionBeforePrepend = nil
    }

    private func updateReadingDay(_ scroll: UIScrollView) {
        guard !railHeld, scrubDay == nil, pendingRailDay == nil, positionBeforePrepend == nil else { return }
        let readingY = scroll.contentOffset.y + scroll.adjustedContentInset.top + 32
        if let frame = dayFrames[currentDay], frame.minY <= readingY && readingY < frame.maxY { return }
        let day = dayFrames.filter { $0.value.minY <= readingY }.max { $0.value.minY < $1.value.minY }?.key
            ?? dayFrames.min { $0.value.minY < $1.value.minY }?.key
        if let day, day != currentDay { currentDay = day }
    }

    private func scrollToDay() {
        guard !refreshing, let scroll = timelineScroll else { return }
        if !railHeld && (scroll.isTracking || scroll.isDecelerating) {
            scrubDay = nil
            pendingRailDay = nil
            return
        }
        guard scrollLayoutReady, let day = scrubDay, let frame = dayFrames[day] else { return }
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let requested = frame.minY - scroll.adjustedContentInset.top
        let target = min(maximum, max(minimum, requested))
        if abs(scroll.contentOffset.y - target) > 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        }
        let layoutReady = scroll.contentSize.height >= frame.maxY
        if !railHeld && (requested <= maximum || store.cursor == nil && layoutReady) { scrubDay = nil }
    }

    private func finishLoading() {
        guard !refreshing, !store.loading, store.error.isEmpty else { return }
        if let day = scrubDay {
            if !store.items.contains(where: { store.groupDay($0) == day }) {
                store.jump(to: day)
                return
            }
            collapsedMonths[String(day.prefix(7))] = false
            pendingRailDay = nil
        } else if returningToStart {
            returningToStart = false
            DispatchQueue.main.async {
                if let scroll = timelineScroll {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
                }
            }
        } else if let day = pendingRailDay, store.items.contains(where: { store.groupDay($0) == day }) {
            pendingRailDay = nil
            collapsedMonths[String(day.prefix(7))] = false
            scrubDay = day
        }
        DispatchQueue.main.async {
            scrollToDay()
            loadMoreIfNeeded()
        }
    }

    private var newerEndVisible: Bool {
        guard let scroll = timelineScroll, let first = store.items.first,
              let frame = dayFrames[store.groupDay(first)] else { return false }
        return frame.minY - scroll.contentOffset.y - scroll.adjustedContentInset.top >= -100
    }

    private func loadMoreIfNeeded() {
        let endVisible = foldedDayEndVisible || collapsedEndVisible || (visibleEndItem != nil && visibleEndItem == store.items.last?.stableID)
        guard !refreshing, scrollLayoutReady, !railHeld, !store.loading,
              positionBeforePrepend == nil, store.error.isEmpty,
              let scroll = timelineScroll,
              scroll.contentOffset.y >= -scroll.adjustedContentInset.top else { return }
        if newerEndVisible && store.hasNewer && scrubDay == nil && pendingRailDay == nil {
            prependNewer()
        } else if endVisible && store.cursor != nil {
            Task {
                await store.load(more: true)
                finishLoading()
            }
        }
    }

    private func prependNewer(expandingArchive: Bool = false) {
        let first = store.items.first?.stableID
        if let frame = dayFrames[currentDay] {
            positionBeforePrepend = (currentDay, frame.minY)
        }
        Task {
            if expandingArchive { await store.expandArchive() }
            else { await store.loadNewer() }
            if store.items.first?.stableID == first { positionBeforePrepend = nil }
            finishLoading()
        }
    }

    private var filterCount: Int {
        (store.uploaderID == nil ? 0 : 1) + (store.selected.isEmpty ? 0 : 1)
            + (store.mediaType.isEmpty ? 0 : 1) + (store.useDateRange ? 1 : 0)
    }
    private var typeLabel: String {
        ["photo": "照片", "live_photo": "实况", "video": "视频"][store.mediaType] ?? "类型"
    }
    private var filterSummary: String {
        var labels: [String] = []
        if let uploader = store.uploaderID { labels.append(store.uploaders.first { $0.id == uploader }?.displayName ?? "上传人 #\(uploader)") }
        labels += store.profiles.filter { store.selected.contains($0.id) }.map(\.label)
        if !store.mediaType.isEmpty { labels.append(typeLabel) }
        if store.useDateRange { labels.append(NativeDay.string(store.startDate) + " 至 " + NativeDay.string(store.endDate)) }
        if !store.search.isEmpty { labels.append("“" + store.search + "”") }
        return labels.joined(separator: " · ")
    }
    private var filtersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showingFilter = true } label: {
                    Label(filterCount == 0 ? "筛选" : "筛选 \(filterCount)", systemImage: "slider.horizontal.3")
                }.buttonStyle(NativeActionStyle(kind: filterCount == 0 ? .secondary : .primary, compact: true))
                if store.uploaders.count > 1 || store.uploaderID != nil {
                    Menu {
                        Picker("上传人", selection: $store.uploaderID) {
                            Text("全部上传人").tag(nil as Int?)
                            ForEach(store.uploaders) { Text($0.displayName).tag(Optional($0.id)) }
                        }
                    } label: {
                        Label(store.uploaders.first { $0.id == store.uploaderID }?.displayName ?? "上传人", systemImage: "person.crop.circle")
                            .lineLimit(1)
                    }.buttonStyle(NativeActionStyle(compact: true)).accessibilityLabel("按上传人筛选")
                }
                Menu {
                    Picker("日期依据", selection: Binding(get: { store.byUpload }, set: store.setUploadOrder)) {
                        Text("按归档日期").tag(false); Text("按上传时间").tag(true)
                    }
                    Picker("时间顺序", selection: $store.ascending) {
                        Text("从新到旧").tag(false); Text("从旧到新").tag(true)
                    }
                } label: {
                    Label(store.byUpload ? "上传时间" : "归档日期", systemImage: store.ascending ? "arrow.up" : "arrow.down")
                }.buttonStyle(NativeActionStyle(compact: true))
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }.background(NativeTheme.background)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isFocused { timelineList.id(store.queryKey) }
                else { timelineList.searchable(text: $store.search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索回忆") }
            }
            .navigationTitle(store.showingUploads ? "刚上传的回忆" : "家庭时光")
            .navigationBarTitleDisplayMode(.inline)
            .background(NativeTheme.background)
            .toolbarBackground(NativeTheme.background, for: .navigationBar)
            .onChange(of: store.uploadedMediaIDs) { _ in
                selecting = false
                chosen = []
            }
            .onChange(of: store.uploaderID) { _ in selecting = false; chosen = [] }
            .onChange(of: store.byUpload) { _ in selecting = false; chosen = [] }
            .onChange(of: store.anchorMediaID) { _ in
                selecting = false
                chosen = []
                positionBeforePrepend = nil
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if store.session.canEdit {
                        Button(selecting ? "取消" : "选择") { selecting.toggle(); chosen = [] }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if store.session.canEdit {
                                Button("创建分享", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest() }
                                Button("回收站", systemImage: "trash") { showingTrash = true }
                            }
                            if !store.showingUploads {
                                Button("展开全部回忆", systemImage: "rectangle.expand.vertical") {
                                    scrubDay = nil; pendingRailDay = nil
                                    collapseAllMonths = false; collapsedMonths = [:]
                                    expandAllDays = true; expandedDays = [:]
                                }.disabled(selecting)
                                Button("收起全部回忆", systemImage: "rectangle.compress.vertical") {
                                    scrubDay = nil; pendingRailDay = nil
                                    collapseAllMonths = true; collapsedMonths = [:]
                                    expandAllDays = false; expandedDays = [:]
                                }.disabled(selecting)
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                        .accessibilityLabel("更多时间线操作")
                }
            }
            .task { await store.loadProfiles(); await store.loadUploaders() }
            .task(id: store.queryKey) {
                pendingRailDay = store.anchorDay
                if store.isFocused || store.anchorDay != nil { await store.loadIfNeeded() }
                else {
                    do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); await store.loadIfNeeded() } catch { }
                }
                if !Task.isCancelled {
                    if store.anchorDay == nil { currentDay = store.railDays.first ?? "" }
                    finishLoading()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !store.isFocused { filtersBar }
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
            .sheet(isPresented: $showingFilter) { NativeTimelineFilters(store: store) }
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
        if store.showingUploads {
            store.focusOnUploads(pages.map(\.id))
        } else if store.anchorMediaID == item.id {
            if !pages.isEmpty { store.locate(pages[min(index, pages.count - 1)], expandingArchive: store.archiveExpanded) }
            else { store.focusOnUploads([]) }
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
    @State private var startedAutomaticPlayback = false
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
                    if item.kind == "media" {
                        Label("上传人 · " + (item.owner_name ?? "未记录"), systemImage: "person.crop.circle")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal).padding(.vertical, 4)
                    }
                    if let pagePosition {
                        HStack(spacing: 16) {
                            Button(action: { if let previous { stop(); previous() } }) { Image(systemName: "chevron.left").padding(8) }
                                .accessibilityLabel("上一项").disabled(previous == nil || savingToPhotos)
                            VStack(spacing: 4) {
                                Text(item.previewDateTime).font(.headline)
                                    .multilineTextAlignment(.center)
                                if pagePosition.day.hasPrefix("上传") {
                                    Text(pagePosition.day).font(.caption).foregroundStyle(.white.opacity(0.75))
                                }
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
                        Button { stop(); showingInfo = true } label: {
                            Image(systemName: item.editable(by: session.account) ? "square.and.pencil" : "info.circle")
                        }.accessibilityLabel(item.editable(by: session.account) ? (item.kind == "event" ? "编辑日记" : "编辑影像") : "查看信息与修改日志")
                        if item.editable(by: session.account) && (item.kind != "event" || NativeDay.date(item.day) != nil) {
                            Button { stop(); showingShare = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(item.kind == "event" ? "分享当天回忆" : "分享这项影像")
                        }
                        Menu {
                            if item.kind == "event" && !item.editable(by: session.account) {
                                Button("查看信息", systemImage: "info.circle") { stop(); showingInfo = true }
                            }
                            if let onLocate {
                                Button("跳到归档位置", systemImage: "scope") { stop(); onLocate(item) }
                            }
                            if item.kind != "event" {
                                Button("保存到相册", systemImage: "square.and.arrow.down") { Task { await saveToPhotos() } }
                                    .disabled(savingToPhotos || deleting)
                                if item.editable(by: session.account) {
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
                startAutomaticPlaybackIfNeeded()
                do {
                    let current: NativeTimelineItem = try await session.get("/media/\(initial.id)")
                    try Task.checkCancellation()
                    detail = current
                    startAutomaticPlaybackIfNeeded()
                } catch { if !Task.isCancelled { message = friendly(error) } }
            }
            .alert("移到回收站？", isPresented: $confirmingDelete) {
                Button("移到回收站", role: .destructive) { Task { await trash() } }
                Button("取消", role: .cancel) {}
            } message: { Text("可以从时间线的回收站恢复这项影像。") }
            .sheet(isPresented: $showingShare) { NativeSharingView(session: session, day: item.day, selectedItems: item.kind == "event" ? nil : [item]) }
            .sheet(isPresented: $showingInfo) {
                if item.kind == "event" {
                    NativeDiaryEditor(session: session, profiles: profiles, existing: item) { Task { await reloadDiary() } }
                } else {
                    NativeMediaInfo(session: session, item: item, profiles: profiles) {
                        onSaved()
                        Task { do { detail = try await session.get("/media/\(initial.id)") } catch { message = friendly(error) } }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                if let ended = notification.object as? AVPlayerItem, ended === player?.currentItem, item.media_type == "live_photo" { stop() }
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

    private func startAutomaticPlaybackIfNeeded() {
        guard !startedAutomaticPlayback, item.media_type == "live_photo", item.motion != nil else { return }
        startedAutomaticPlayback = true
        play()
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
                var resource: NativeMediaResource = try await session.get("/media/\(item.id)/files/\(file.id)/url?purpose=preview")
                while live && resource.url == nil && ["pending", "processing"].contains(resource.status) {
                    message = "动态预览正在准备…"
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    resource = try await session.get("/media/\(item.id)/files/\(file.id)/url?purpose=preview")
                }
                try Task.checkCancellation()
                message = ""
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
