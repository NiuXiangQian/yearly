import MapKit
import SwiftUI

private enum NativeMapLevel: String, Decodable, Hashable { case country, region, local }

private struct NativeMapBounds: Decodable, Hashable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    static let world = Self(south: -85, west: -180, north: 85, east: 180)

    private static func longitude(_ value: Double) -> Double {
        let wrapped = (value + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }

    init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    init?(visibleRect rect: MKMapRect) {
        let worldWidth = MKMapSize.world.width
        guard !rect.isNull, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { return nil }
        north = MKMapPoint(x: 0, y: max(0, rect.minY)).coordinate.latitude
        south = MKMapPoint(x: 0, y: min(worldWidth, rect.maxY)).coordinate.latitude
        if rect.width >= worldWidth {
            west = -180
            east = 180
        } else {
            west = Self.longitude(rect.minX / worldWidth * 360 - 180)
            east = Self.longitude(rect.maxX / worldWidth * 360 - 180)
        }
        guard south < north else { return nil }
    }

    var longitudeSpan: Double { east >= west ? east - west : east - west + 360 }

    func cameraRegion(padded: Bool) -> MKCoordinateRegion {
        let latitude = min(85, max(-85, (south + north) / 2))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: Self.longitude(west + longitudeSpan / 2)),
            span: MKCoordinateSpan(latitudeDelta: min(170, max(0.008, (north - south) * (padded ? 1.27 : 1))),
                                  longitudeDelta: min(360, max(0.008, longitudeSpan * (padded ? 1.34 : 1))))
        )
    }

    var query: [URLQueryItem] {
        [URLQueryItem(name: "south", value: String(south)), URLQueryItem(name: "west", value: String(west)),
         URLQueryItem(name: "north", value: String(north)), URLQueryItem(name: "east", value: String(east))]
    }
}

private struct NativeMapCover: Decodable, Hashable {
    let media_id: Int
    let file_id: Int
    let media_type: String
    let title: String
}

private struct NativeMapGroup: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let count: Int
    let latitude: Double
    let longitude: Double
    let bounds: NativeMapBounds
    let next_level: NativeMapLevel
    let covers: [NativeMapCover]?

    var title: String { name ?? "附近影像" }
    var accessibilityTitle: String { "\(title)，\(count) 项影像" }
    var thumbnails: [NativeMapCover] { covers ?? [] }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: min(85.051128, max(-85.051128, latitude)), longitude: longitude)
    }
}

private struct NativeMapSummary: Decodable {
    let level: NativeMapLevel
    let bounds: NativeMapBounds?
    let groups: [NativeMapGroup]
    let unlocated_total: Int?
}

private struct NativeMapPage: Decodable {
    let items: [NativeTimelineItem]
    let total: Int
    let page: Int
    let page_size: Int

    var mediaItems: [NativeTimelineItem] {
        items.map { item in
            var media = item
            media.kind = "media"
            return media
        }
    }
}

private struct NativeMapViewport: Hashable {
    let bounds: NativeMapBounds
    let level: NativeMapLevel?

    var query: [URLQueryItem] {
        bounds.query + (level.map { [URLQueryItem(name: "level", value: $0.rawValue)] } ?? [])
    }
}

private struct NativeMapCamera: Equatable {
    let id = UUID()
    let bounds: NativeMapBounds
    let reportLevel: NativeMapLevel?
    var padded = true
}

private enum NativeMapPanel: Hashable { case places, media }

private enum NativeMapTray: Int, CaseIterable { case compact, regular, expanded }

private struct NativeMapSelection {
    let group: NativeMapGroup
    let level: NativeMapLevel
    let viewport: NativeMapViewport?

    var canDrillDown: Bool {
        level != .local || group.bounds.longitudeSpan >= 0.002 || group.bounds.north - group.bounds.south >= 0.002
    }

    var query: [URLQueryItem] {
        (viewport?.bounds.query ?? []) + [URLQueryItem(name: "level", value: level.rawValue),
                                          URLQueryItem(name: "group", value: group.id)]
    }
}

private struct NativeMapRequest: Hashable {
    let path: String
    let revision: Int
}

private struct NativeMapPreviewRequest {
    let group: NativeMapGroup
    let request: NativeMapRequest
}

private struct NativeMapPreviewSource: Identifiable {
    let id: Int
    let page: NativeMapPage
    let request: NativeMapRequest
}

@MainActor
private final class NativeMapResults: ObservableObject {
    let session: NativeSession
    @Published private(set) var summary: NativeMapSummary?
    @Published private(set) var unlocated = 0
    @Published private(set) var mapLoading = false
    @Published private(set) var mapError = ""
    @Published private(set) var items: [NativeTimelineItem] = []
    @Published private(set) var total = 0
    @Published private(set) var galleryLoading = false
    @Published private(set) var galleryError = ""
    private var mapRequest: NativeMapRequest?
    private var loadedMapRequest: NativeMapRequest?
    private var unlocatedRevision: Int?
    private var galleryRequest: NativeMapRequest?
    private var loadedPage = 0
    private var pageSize = 30
    var nextPage: Int? { loadedPage > 0 && loadedPage * pageSize < total ? loadedPage + 1 : nil }
    var gallerySnapshot: NativeMapPage {
        NativeMapPage(items: items, total: total, page: loadedPage, page_size: pageSize)
    }

    init(session: NativeSession) { self.session = session }

    func loadMap(_ request: NativeMapRequest, debounce: Bool) async -> NativeMapSummary? {
        mapRequest = request
        mapLoading = true
        mapError = ""
        defer { if mapRequest == request { mapLoading = false } }
        do {
            if debounce { try await Task.sleep(nanoseconds: 250_000_000) }
            let includeTotal = debounce && unlocatedRevision != request.revision
            let path = request.path + (includeTotal ? "&include_unlocated=true" : "")
            let snapshot: NativeMapSummary = try await session.get(path, refresh: true)
            guard mapRequest == request, !Task.isCancelled else { return nil }
            loadedMapRequest = request
            summary = snapshot
            if let unlocated = snapshot.unlocated_total {
                self.unlocated = unlocated
                unlocatedRevision = request.revision
            }
            return snapshot
        } catch {
            if mapRequest == request && !Task.isCancelled { mapError = friendly(error) }
            return nil
        }
    }

    func summary(for request: NativeMapRequest) -> NativeMapSummary? {
        loadedMapRequest == request ? summary : nil
    }

    func hasGallery(for request: NativeMapRequest) -> Bool { galleryRequest == request }

    func loadGallery(_ request: NativeMapRequest, more: Bool = false, debounce: Bool = false) async {
        if more {
            guard galleryRequest == request, !galleryLoading, nextPage != nil else { return }
        } else {
            if galleryRequest == request, loadedPage > 0, galleryError.isEmpty { return }
            galleryRequest = request
            items = []
            total = 0
            loadedPage = 0
        }
        galleryLoading = true
        galleryError = ""
        defer { if galleryRequest == request { galleryLoading = false } }
        do {
            if debounce { try await Task.sleep(nanoseconds: 250_000_000) }
            let page: NativeMapPage = try await session.get(request.path + "&page=\(loadedPage + 1)", refresh: true)
            guard galleryRequest == request, !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            items += page.mediaItems.filter { !existing.contains($0.id) }
            pageSize = page.page_size
            loadedPage = page.page
            total = page.total
        } catch {
            if galleryRequest == request && !Task.isCancelled { galleryError = friendly(error) }
        }
    }

    func clearSummary() {
        summary = nil
        unlocated = 0
    }
}

struct NativePhotoMap: View {
    let onMediaChanged: () -> Void
    @StateObject private var filters: NativeTimelineStore
    @StateObject private var results: NativeMapResults
    @State private var viewport: NativeMapViewport?
    @State private var selectedGroup: NativeMapSelection?
    @State private var camera: NativeMapCamera?
    @State private var trail: [NativeMapViewport?] = []
    @State private var panel: NativeMapPanel = .places
    @State private var showingFilter = false
    @State private var showingUnlocated = false
    @State private var tray: NativeMapTray = .regular
    @GestureState private var trayDrag: CGFloat = 0
    @State private var preview: NativeMapPreviewSource?
    @State private var pendingPreview: NativeMapPreviewRequest?
    @State private var revision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(timeline: NativeTimelineStore, onMediaChanged: @escaping () -> Void) {
        let draft = NativeTimelineStore(session: timeline.session)
        draft.profiles = timeline.profiles
        draft.uploaders = timeline.uploaders
        draft.uploaderID = timeline.uploaderID
        draft.selected = timeline.selected
        draft.mediaType = timeline.mediaType
        if !timeline.usesUploadOrder {
            draft.useDateRange = timeline.useDateRange
            draft.startDate = timeline.startDate
            draft.endDate = timeline.endDate
        }
        _filters = StateObject(wrappedValue: draft)
        _results = StateObject(wrappedValue: NativeMapResults(session: timeline.session))
        self.onMediaChanged = onMediaChanged
    }

    private var filterQuery: [URLQueryItem] {
        var query = filters.selected.sorted().map { URLQueryItem(name: "child_id", value: String($0)) }
        if let owner = filters.uploaderID { query.append(URLQueryItem(name: "owner_id", value: String(owner))) }
        if !filters.mediaType.isEmpty { query.append(URLQueryItem(name: "media_type", value: filters.mediaType)) }
        if filters.useDateRange {
            query.append(URLQueryItem(name: "start", value: NativeDay.string(filters.startDate)))
            query.append(URLQueryItem(name: "end", value: NativeDay.following(filters.endDate)))
        }
        return query
    }

    private func request(_ path: String, extra: [URLQueryItem]) -> NativeMapRequest {
        var components = URLComponents()
        components.queryItems = filterQuery + extra
        return NativeMapRequest(path: path + "?" + (components.percentEncodedQuery ?? ""), revision: revision)
    }

    private var summaryRequest: NativeMapRequest {
        request("/media/map", extra: (viewport?.query ?? []) + [URLQueryItem(name: "include_covers", value: "true")])
    }

    private var galleryRequest: NativeMapRequest {
        let scope = URLQueryItem(name: "scope", value: showingUnlocated ? "unlocated" : "map")
        let query = showingUnlocated ? [] : selectedGroup?.query ?? viewport?.bounds.query ?? []
        return request("/media/map/items", extra: [scope] + query)
    }

    private var summary: NativeMapSummary? { results.summary(for: summaryRequest) }

    private var galleryTitle: String {
        if showingUnlocated { return "无坐标影像" }
        return selectedGroup?.group.title ?? (viewport == nil ? "全部地图影像" : "当前范围影像")
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let wide = size.width > size.height * 1.3
            let extent = trayExtent(size: size, wide: wide)
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                map.frame(width: wide ? size.width - extent : size.width,
                          height: wide ? size.height : size.height - extent)
                trayView(wide: wide)
                    .frame(width: wide ? extent : size.width, height: wide ? size.height : extent)
                    .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("照片地图").navigationBarTitleDisplayMode(.inline)
        .background(NativeTheme.background)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingFilter = true
                } label: {
                    Text(filters.hasFilters ? "筛选中" : "筛选")
                }
                .accessibilityHint("按人物、归档日期或影像类型筛选")
                .accessibilityIdentifier("photo-map-filters")
            }
        }
        .nativeSheet(isPresented: $showingFilter) { NativeTimelineFilters(store: filters) }
        .task { await filters.loadProfiles(); await filters.loadUploaders() }
        .task(id: summaryRequest) {
            let request = summaryRequest
            let overview = viewport == nil
            if let summary = await results.loadMap(request, debounce: !overview), request == summaryRequest, overview {
                camera = NativeMapCamera(bounds: summary.bounds ?? .world, reportLevel: nil)
            }
        }
        .task(id: panel == .media && tray != .compact ? galleryRequest : nil) {
            guard panel == .media && tray != .compact else { return }
            await results.loadGallery(galleryRequest, debounce: viewport != nil && !showingUnlocated && selectedGroup == nil)
        }
        .task(id: pendingPreview?.request) {
            guard let pending = pendingPreview else { return }
            do {
                let page: NativeMapPage = try await results.session.get(pending.request.path, refresh: true)
                guard !Task.isCancelled, pendingPreview?.request == pending.request else { return }
                if let initial = page.items.first {
                    preview = NativeMapPreviewSource(id: initial.id, page: page, request: pending.request)
                } else {
                    selectGroup(pending.group)
                }
            } catch {
                guard !Task.isCancelled, pendingPreview?.request == pending.request else { return }
                selectGroup(pending.group)
            }
            pendingPreview = nil
        }
        .onChange(of: filterQuery) { _ in
            results.clearSummary()
            showOverview()
        }
        .onReceive(results.session.uploadsChanged) { _ in revision += 1 }
        .fullScreenCover(item: $preview) { source in
            NativeMapMediaPreview(session: results.session, profiles: filters.profiles,
                                  source: source, onChanged: refreshAfterEdit)
        }
    }

    private var map: some View {
        NativeMapCanvas(session: results.session, groups: summary?.groups ?? [], selectedID: selectedGroup?.group.id,
                        camera: camera, onSelect: selectMarker, onExplore: exploreMap) { bounds, level in
            let next = NativeMapViewport(bounds: bounds, level: level)
            guard viewport != next else { return }
            viewport = next
            if level == nil && panel == .places { selectedGroup = nil }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if !trail.isEmpty {
                    Button("返回上一级", action: goBack)
                        .buttonStyle(NativeActionStyle(compact: true))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                }
                if viewport != nil || !trail.isEmpty {
                    Button("显示全部", action: showOverview).buttonStyle(NativeActionStyle(compact: true))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                }
            }.padding(12)
        }
        .overlay(alignment: .topLeading) {
            if results.mapLoading || pendingPreview != nil {
                ProgressView().padding(12).background(.regularMaterial, in: Circle())
                    .accessibilityLabel(pendingPreview == nil ? "正在读取地图地点" : "正在打开影像").padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if !results.mapError.isEmpty {
                VStack(spacing: 6) {
                    Text(results.mapError).font(.footnote)
                    Button("重试地图") { revision += 1 }.buttonStyle(NativeActionStyle(compact: true))
                }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(12)
            }
        }
    }

    private func trayExtent(size: CGSize, wide: Bool) -> CGFloat {
        let axis = wide ? size.width : size.height
        let compact = min(wide ? 124 : 60, axis * (wide ? 0.28 : 0.20))
        let regular = axis * (wide ? 0.42 : 0.49)
        let expanded = axis * (wide ? 0.58 : 0.73)
        let resting: CGFloat
        switch tray {
        case .compact: resting = compact
        case .regular: resting = regular
        case .expanded: resting = expanded
        }
        return min(expanded, max(compact, resting - trayDrag))
    }

    private func setTray(_ value: NativeMapTray) {
        guard value != tray else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.23)) { tray = value }
    }

    private func trayDragGesture(wide: Bool) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($trayDrag) { value, state, _ in
                state = wide ? value.translation.width : value.translation.height
            }
            .onEnded { value in
                let offset = wide ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                if abs(offset) > 30 { stepTray(offset < 0 ? 1 : -1) }
            }
    }

    private func stepTray(_ increment: Int) {
        let cases = NativeMapTray.allCases
        setTray(cases[min(cases.count - 1, max(0, tray.rawValue + increment))])
    }

    private func trayView(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if tray == .compact {
                Button {
                    setTray(.regular)
                } label: {
                    Label(panel == .places ? "查看地点" : "查看影像", systemImage: wide ? "chevron.left" : "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativeTheme.accent)
                .accessibilityIdentifier("photo-map-open-tray")
                .simultaneousGesture(trayDragGesture(wide: wide))
            } else {
                Button {
                    setTray(.compact)
                } label: {
                    Image(systemName: wide ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(NativeTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起地点和影像")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: stepTray(1)
                    case .decrement: stepTray(-1)
                    @unknown default: break
                    }
                }
                .simultaneousGesture(trayDragGesture(wide: wide))
                browser
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            Picker("地图浏览方式", selection: $panel) {
                Text("地点").tag(NativeMapPanel.places)
                Text("影像").tag(NativeMapPanel.media)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("photo-map-panel")
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if panel == .places {
                        places
                    } else {
                        gallery
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(panel == .places ? "places" : galleryRequest.path)
        }
        .background(NativeTheme.surface)
    }

    @ViewBuilder
    private var places: some View {
        ViewThatFits(in: .horizontal) {
            HStack { placesHeading; Spacer(minLength: 8); unlocatedButton }
            VStack(alignment: .leading) { placesHeading; unlocatedButton }
        }
        if let summary {
            if summary.groups.isEmpty {
                Text(viewport == nil ? "筛选范围内没有带坐标的影像。" : "当前地图范围没有影像。")
                    .font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(summary.groups) { group in
                        Button { selectGroup(group) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle").foregroundStyle(NativeTheme.accent)
                                Text(group.title).font(.body.weight(.medium))
                                Spacer(minLength: 8)
                                Text("\(group.count) 项").font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
                                Image(systemName: "chevron.right").font(.caption)
                                    .foregroundStyle(NativeTheme.secondaryText)
                            }.frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(group.accessibilityTitle)
                        .accessibilityIdentifier("photo-map-place-\(group.id)")
                        Divider()
                    }
                }
            }
        } else if results.mapError.isEmpty {
            ProgressView("正在读取地点…")
        }
    }

    private var placesHeading: some View {
        Text(viewport == nil ? "全部地点" : "当前范围地点").font(.headline).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var gallery: some View {
        ViewThatFits(in: .horizontal) {
            HStack { galleryHeading; Spacer(minLength: 8); galleryAction }
            VStack(alignment: .leading) { galleryHeading; galleryAction }
        }
        if let selection = selectedGroup, !showingUnlocated {
            ViewThatFits(in: .horizontal) {
                HStack { selectionActions(selection) }
                VStack(alignment: .leading) { selectionActions(selection) }
            }
        }
        if !results.hasGallery(for: galleryRequest) {
            ProgressView("正在读取影像…")
        } else {
            if !results.galleryError.isEmpty {
                Text(results.galleryError).font(.footnote).foregroundStyle(NativeTheme.secondaryText)
                Button("重试影像") {
                    Task { await results.loadGallery(galleryRequest, more: !results.items.isEmpty) }
                }.buttonStyle(NativeActionStyle(compact: true))
            }
            if results.items.isEmpty {
                if results.galleryLoading {
                    ProgressView("正在读取影像…")
                } else if results.galleryError.isEmpty {
                    Text(showingUnlocated ? "筛选范围内的影像都有坐标。" : "此范围内没有影像。")
                        .font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 12) {
                    ForEach(results.items) { item in mediaTile(item) }
                    if let next = results.nextPage, results.galleryError.isEmpty {
                        Button(results.galleryLoading ? "正在加载…" : "加载更多") {
                            Task { await results.loadGallery(galleryRequest, more: true) }
                        }
                        .buttonStyle(NativeActionStyle(compact: true)).disabled(results.galleryLoading)
                        .task(id: next) { await results.loadGallery(galleryRequest, more: true) }
                    }
                }
            }
        }
    }

    private var galleryHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(galleryTitle).font(.headline).accessibilityAddTraits(.isHeader)
            if results.hasGallery(for: galleryRequest) && (!results.galleryLoading || !results.items.isEmpty) {
                Text("\(results.total) 项影像").font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
            } else if let count = selectedGroup?.group.count {
                Text("\(count) 项影像").font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var galleryAction: some View {
        if showingUnlocated {
            Button("返回地图影像") { showingUnlocated = false }
                .buttonStyle(NativeActionStyle(compact: true))
        } else {
            Button(tray == .expanded ? "收起影像" : "展开影像") {
                setTray(tray == .expanded ? .regular : .expanded)
            }.buttonStyle(NativeActionStyle(compact: true))
        }
    }

    private var unlocatedButton: some View {
        Button("无坐标 \(results.unlocated)") {
            showingUnlocated = true
            selectedGroup = nil
            panel = .media
        }
        .buttonStyle(NativeActionStyle(compact: true))
        .accessibilityIdentifier("photo-map-unlocated")
    }

    @ViewBuilder
    private func selectionActions(_ selection: NativeMapSelection) -> some View {
        if selection.canDrillDown {
            Button("放大看地点") { drillDown(selection) }
                .buttonStyle(NativeActionStyle(kind: .primary, compact: true))
                .accessibilityIdentifier("photo-map-drill-down")
        }
        Button("查看当前范围") { selectedGroup = nil }
            .buttonStyle(NativeActionStyle(kind: .quiet, compact: true))
    }

    private func mediaTile(_ item: NativeTimelineItem) -> some View {
        Button {
            preview = NativeMapPreviewSource(id: item.id, page: results.gallerySnapshot, request: galleryRequest)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(NativeTheme.background)
                    .aspectRatio(1.25, contentMode: .fit)
                    .overlay {
                        if let primary = item.primary {
                            NativeMediaImage(session: results.session, mediaID: item.id, fileID: primary.id)
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        if item.media_type == "video" || item.media_type == "live_photo" {
                            Image(systemName: item.media_type == "video" ? "play.fill" : "livephoto")
                                .font(.caption).foregroundStyle(.white).padding(5)
                                .background(.black.opacity(0.6), in: Capsule()).padding(5)
                        }
                    }
                Text(item.label).font(.caption).lineLimit(1)
                Text(item.day).font(.caption2).foregroundStyle(NativeTheme.secondaryText)
                if let place = item.location_name, !place.isEmpty {
                    Text(place).font(.caption2).foregroundStyle(NativeTheme.secondaryText).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("查看 \(item.label)，\(item.day)")
    }

    private func exploreMap() {
        pendingPreview = nil
        setTray(.compact)
    }

    private func selectMarker(_ group: NativeMapGroup) {
        if !group.thumbnails.isEmpty, let summary {
            let selection = NativeMapSelection(group: group, level: summary.level, viewport: viewport)
            let query = [URLQueryItem(name: "scope", value: "map")] + selection.query
            pendingPreview = NativeMapPreviewRequest(group: group, request: request("/media/map/items", extra: query))
        } else {
            selectGroup(group)
        }
    }

    private func selectGroup(_ group: NativeMapGroup) {
        guard let summary else { return }
        pendingPreview = nil
        showingUnlocated = false
        selectedGroup = NativeMapSelection(group: group, level: summary.level, viewport: viewport)
        panel = .media
        if tray == .compact { setTray(.regular) }
    }

    private func drillDown(_ selection: NativeMapSelection) {
        trail.append(viewport)
        panel = .places
        selectedGroup = nil
        setTray(.compact)
        camera = NativeMapCamera(bounds: selection.group.bounds, reportLevel: selection.group.next_level)
    }

    private func goBack() {
        guard !trail.isEmpty else { return }
        let prior = trail.removeLast()
        selectedGroup = nil
        showingUnlocated = false
        panel = .places
        viewport = prior
        if let prior {
            camera = NativeMapCamera(bounds: prior.bounds, reportLevel: nil, padded: false)
        }
    }

    private func showOverview() {
        pendingPreview = nil
        trail.removeAll()
        selectedGroup = nil
        showingUnlocated = false
        panel = .places
        setTray(.regular)
        viewport = nil
        revision += 1
    }

    private func refreshAfterEdit() {
        revision += 1
        onMediaChanged()
    }
}

private struct NativeMapMediaPreview: View {
    let session: NativeSession
    let profiles: [UploadProfile]
    let onChanged: () -> Void
    private let request: NativeMapRequest
    @NativeDismiss private var dismiss
    @State private var items: [NativeTimelineItem]
    @State private var index: Int
    @State private var page: Int
    @State private var pageSize: Int
    @State private var total: Int
    @State private var paging = false
    @State private var advanceWhenReady = false
    @State private var pageError = ""
    @State private var showingPageError = false

    init(session: NativeSession, profiles: [UploadProfile], source: NativeMapPreviewSource,
         onChanged: @escaping () -> Void) {
        self.session = session
        self.profiles = profiles
        self.onChanged = onChanged
        request = source.request
        _items = State(initialValue: source.page.mediaItems)
        _index = State(initialValue: source.page.items.firstIndex(where: { $0.id == source.id }) ?? 0)
        _page = State(initialValue: source.page.page)
        _pageSize = State(initialValue: source.page.page_size)
        _total = State(initialValue: source.page.total)
    }

    private var hasMore: Bool { page * pageSize < total }

    var body: some View {
        let item = items[index]
        let position = NativePreviewPosition(day: item.day, withinDay: "地图影像", overall: "\(index + 1) / \(max(total, items.count))")
        NativeMediaDetail(session: session, initial: item, profiles: profiles, pagePosition: position,
                          previous: index > 0 ? { index -= 1 } : nil,
                          next: index + 1 < items.count || hasMore ? advance : nil,
                          onSaved: onChanged, onDeleted: { onChanged(); dismiss() }, onLocate: nil)
            .id(item.stableID)
            .preferredColorScheme(.dark)
            .task(id: item.id) {
                if index >= items.count - 3, hasMore { await loadMore() }
            }
            .alert("无法加载下一页", isPresented: $showingPageError) {
                Button("重试", action: advance)
                Button("取消", role: .cancel) {}
            } message: { Text(pageError) }
    }

    private func advance() {
        if index + 1 < items.count {
            index += 1
        } else {
            advanceWhenReady = true
            Task { await loadMore() }
        }
    }

    private func loadMore() async {
        guard hasMore, !paging else { return }
        paging = true
        defer { paging = false; advanceWhenReady = false }
        do {
            while hasMore && !Task.isCancelled {
                let response: NativeMapPage = try await session.get(request.path + "&page=\(page + 1)", refresh: true)
                try Task.checkCancellation()
                let known = Set(items.map(\.id))
                let added = response.mediaItems.filter { !known.contains($0.id) }
                items += added
                page = response.page
                pageSize = response.page_size
                total = response.total
                if !added.isEmpty { break }
            }
            if advanceWhenReady, index + 1 < items.count { index += 1 }
        } catch {
            if advanceWhenReady && !Task.isCancelled {
                pageError = friendly(error)
                showingPageError = true
            }
        }
    }
}

private final class NativeMapAnnotation: NSObject, MKAnnotation {
    let group: NativeMapGroup
    var coordinate: CLLocationCoordinate2D { group.coordinate }
    var title: String? { group.title }
    var subtitle: String? { "\(group.count) 项影像" }

    init(group: NativeMapGroup) { self.group = group }
}

private final class NativeMapPhotoAnnotationView: MKAnnotationView {
    private let pointer = CAShapeLayer()
    private let pointerHeight: CGFloat = 8

    func configure(with covers: [NativeMapCover], count: Int, session: NativeSession) {
        let cardWidth: CGFloat = 52
        let cardHeight: CGFloat = 46
        let overlap: CGFloat = 30
        let width = cardWidth + CGFloat(covers.count - 1) * (cardWidth - overlap)
        let height = cardHeight + pointerHeight
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        centerOffset = CGPoint(x: 0, y: -height / 2)
        collisionMode = .rectangle
        let contents = UIHostingConfiguration {
            VStack(spacing: 0) {
                HStack(spacing: -overlap) {
                    ForEach(covers.indices, id: \.self) { index in
                        let cover = covers[index]
                        NativeMediaImage(session: session, mediaID: cover.media_id, fileID: cover.file_id,
                                         contentMode: .fill, showsStatus: false)
                            .frame(width: cardWidth, height: cardHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2) }
                            .overlay(alignment: .bottomLeading) {
                                if cover.media_type != "photo" {
                                    Image(systemName: cover.media_type == "video" ? "play.fill" : "livephoto")
                                        .font(.caption2).foregroundStyle(.white).padding(3)
                                        .background(.black.opacity(0.78), in: Circle()).padding(4)
                                }
                            }
                            .zIndex(Double(covers.count - index))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if count > 1 {
                        Text(String(count)).font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.black.opacity(0.82), in: Capsule())
                            .padding(4)
                        }
                }
                Color.clear.frame(height: pointerHeight)
            }
            .accessibilityHidden(true)
        }.margins(.all, 0).makeContentView()
        contents.frame = bounds
        contents.isUserInteractionEnabled = false
        contents.accessibilityElementsHidden = true
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(contents)
        pointer.frame = bounds
        pointer.fillColor = UIColor.white.cgColor
        layer.addSublayer(pointer)
        positionPointer(shift: 0)
    }

    func keepCardInside(_ map: MKMapView) {
        guard let annotation else { return }
        let projected = map.convert(annotation.coordinate, toPointTo: map)
        let padding = bounds.width / 2 + 3
        let maxX = map.bounds.width
        guard projected.x.isFinite, (0...maxX).contains(projected.x), maxX >= padding * 2 else { return }
        let shift = min(max(projected.x, padding), maxX - padding) - projected.x
        if abs(shift - centerOffset.x) > 0.5 { positionPointer(shift: shift) }
    }

    private func positionPointer(shift: CGFloat) {
        centerOffset = CGPoint(x: shift, y: -bounds.height / 2)
        let tip = bounds.midX - shift
        let base = min(max(tip, 7), bounds.maxX - 7)
        let top = bounds.maxY - pointerHeight
        let path = CGMutablePath()
        path.move(to: CGPoint(x: base - 7, y: top))
        path.addLine(to: CGPoint(x: base + 7, y: top))
        path.addLine(to: CGPoint(x: tip, y: bounds.maxY))
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.path = path
        CATransaction.commit()
    }
}

private struct NativeMapCanvas: UIViewRepresentable {
    let session: NativeSession
    let groups: [NativeMapGroup]
    let selectedID: String?
    let camera: NativeMapCamera?
    let onSelect: (NativeMapGroup) -> Void
    let onExplore: () -> Void
    let onMove: (NativeMapBounds, NativeMapLevel?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.pointOfInterestFilter = .excludingAll
        view.showsCompass = false
        view.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "media-count")
        view.register(NativeMapPhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: "media-cover")
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onExplore = onExplore
        coordinator.onMove = onMove
        coordinator.updateSelection(selectedID, in: view)
        coordinator.updateGroups(groups, in: view)
        if let camera, coordinator.cameraID != camera.id { coordinator.move(camera, in: view) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let session: NativeSession
        var onSelect: ((NativeMapGroup) -> Void)?
        var onExplore: (() -> Void)?
        var onMove: ((NativeMapBounds, NativeMapLevel?) -> Void)?
        var cameraID: UUID?
        private var changingCamera = false
        private var ready = false
        private var reportedSize: CGSize?
        private var exploring = false
        private var viewportReport: Task<Void, Never>?
        private var annotations: [String: NativeMapAnnotation] = [:]
        private var selectedID: String?
        private var photoAnnotations: [NativeMapAnnotation] = []

        init(session: NativeSession) { self.session = session }

        func updateSelection(_ id: String?, in view: MKMapView) {
            guard selectedID != id else { return }
            let previous = selectedID
            selectedID = id
            for key in [previous, id].compactMap({ $0 }) {
                guard let annotation = annotations[key], let marker = view.view(for: annotation) else { continue }
                style(marker, for: annotation.group)
            }
        }

        func updateGroups(_ groups: [NativeMapGroup], in view: MKMapView) {
            let active = Set(groups.map(\.id))
            for id in annotations.keys.filter({ !active.contains($0) }) {
                if let old = annotations.removeValue(forKey: id) { view.removeAnnotation(old) }
            }
            for group in groups where annotations[group.id]?.group != group {
                if let old = annotations[group.id] { view.removeAnnotation(old) }
                let annotation = NativeMapAnnotation(group: group)
                annotations[group.id] = annotation
                view.addAnnotation(annotation)
            }
            photoAnnotations = groups.compactMap { $0.thumbnails.isEmpty ? nil : annotations[$0.id] }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            for annotation in photoAnnotations {
                (mapView.view(for: annotation) as? NativeMapPhotoAnnotationView)?.keepCardInside(mapView)
            }
        }

        func move(_ camera: NativeMapCamera, in view: MKMapView) {
            cameraID = camera.id
            changingCamera = true
            exploring = false
            viewportReport?.cancel()
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.cameraID == camera.id else { return }
                view.setRegion(camera.bounds.cameraRegion(padded: camera.padded), animated: false)
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.cameraID == camera.id else { return }
                    if let level = camera.reportLevel, let bounds = NativeMapBounds(visibleRect: view.visibleMapRect) {
                        self.onMove?(bounds, level)
                    }
                    self.reportedSize = view.bounds.size
                    self.changingCamera = false
                    self.ready = true
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard ready, !changingCamera, reportedSize == mapView.bounds.size else { return }
            exploring = true
            viewportReport?.cancel()
            DispatchQueue.main.async { [weak self] in self?.onExplore?() }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard ready, !changingCamera else { return }
            let size = mapView.bounds.size
            let resized = reportedSize != size
            reportedSize = size
            guard exploring || !resized else { return }
            exploring = false
            viewportReport?.cancel()
            // Read the viewport after the drawer finishes making room for the map.
            viewportReport = Task { @MainActor [weak self, weak mapView] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, let mapView,
                      let bounds = NativeMapBounds(visibleRect: mapView.visibleMapRect) else { return }
                self.onMove?(bounds, nil)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? NativeMapAnnotation else { return nil }
            let group = annotation.group
            let marker: MKAnnotationView
            if !group.thumbnails.isEmpty,
               let photo = mapView.dequeueReusableAnnotationView(withIdentifier: "media-cover", for: annotation) as? NativeMapPhotoAnnotationView {
                photo.configure(with: group.thumbnails, count: group.count, session: session)
                photo.keepCardInside(mapView)
                marker = photo
            } else {
                marker = mapView.dequeueReusableAnnotationView(withIdentifier: "media-count", for: annotation)
            }
            style(marker, for: group)
            return marker
        }

        private func style(_ marker: MKAnnotationView, for group: NativeMapGroup) {
            let isSelected = group.id == selectedID
            if let count = marker as? MKMarkerAnnotationView {
                count.glyphText = isSelected ? nil : String(group.count)
                count.glyphImage = isSelected ? UIImage(systemName: "checkmark") : nil
                count.markerTintColor = UIColor(NativeTheme.accent)
                count.glyphTintColor = UIColor(NativeTheme.onAccent)
                count.titleVisibility = group.name == nil && !isSelected ? .hidden : .visible
                count.subtitleVisibility = .hidden
            }
            marker.displayPriority = isSelected ? .required : .defaultHigh
            marker.canShowCallout = false
            marker.isAccessibilityElement = true
            if let cover = group.thumbnails.first, group.count == 1, !cover.title.isEmpty {
                marker.accessibilityLabel = "预览 \(cover.title)"
            } else if !group.thumbnails.isEmpty {
                marker.accessibilityLabel = "预览\(group.title)，\(group.count) 项影像"
            } else {
                marker.accessibilityLabel = group.accessibilityTitle
            }
            marker.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? NativeMapAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onSelect?(annotation.group)
        }
    }
}
