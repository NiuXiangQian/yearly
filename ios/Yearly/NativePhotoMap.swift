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

    var cameraRegion: MKCoordinateRegion {
        let latitude = min(85, max(-85, (south + north) / 2))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: Self.longitude(west + longitudeSpan / 2)),
            span: MKCoordinateSpan(latitudeDelta: min(170, max(0.008, (north - south) * 1.27)),
                                  longitudeDelta: min(360, max(0.008, longitudeSpan * 1.22)))
        )
    }

    var query: [URLQueryItem] {
        [URLQueryItem(name: "south", value: String(south)), URLQueryItem(name: "west", value: String(west)),
         URLQueryItem(name: "north", value: String(north)), URLQueryItem(name: "east", value: String(east))]
    }
}

private struct NativeMapGroup: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let count: Int
    let latitude: Double
    let longitude: Double
    let bounds: NativeMapBounds
    let next_level: NativeMapLevel

    var title: String { name ?? "附近影像" }
    var accessibilityTitle: String { "\(title)，\(count) 项影像" }
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
}

private struct NativeMapSelection {
    let group: NativeMapGroup
    let level: NativeMapLevel
    let viewport: NativeMapViewport?

    var query: [URLQueryItem] {
        (viewport?.bounds.query ?? []) + [URLQueryItem(name: "level", value: level.rawValue),
                                          URLQueryItem(name: "group", value: group.id)]
    }
}

private struct NativeMapRequest: Hashable {
    let path: String
    let revision: Int
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

    func loadGallery(_ request: NativeMapRequest, more: Bool = false, debounce: Bool = false) async {
        if more {
            guard galleryRequest == request, !galleryLoading, items.count < total else { return }
        } else {
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
            items += page.items.filter { !existing.contains($0.id) }.map { item in
                var media = item
                media.kind = "media"
                return media
            }
            total = page.total
            loadedPage = page.page
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
    @State private var showingFilter = false
    @State private var showingUnlocated = false
    @State private var expanded = false
    @State private var preview: NativeTimelineItem?
    @State private var revision = 0

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

    private var summaryRequest: NativeMapRequest { request("/media/map", extra: viewport?.query ?? []) }

    private var galleryRequest: NativeMapRequest {
        let scope = URLQueryItem(name: "scope", value: showingUnlocated ? "unlocated" : "map")
        let query = showingUnlocated ? [] : selectedGroup?.query ?? viewport?.bounds.query ?? []
        return request("/media/map/items", extra: [scope] + query)
    }

    private var galleryTitle: String {
        if showingUnlocated { return "无坐标" }
        return selectedGroup?.group.title ?? (viewport == nil ? "全部地点" : "当前地图范围")
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.3
            if wide {
                HStack(spacing: 0) {
                    map.frame(width: geometry.size.width * 0.58)
                    gallery(alwaysExpanded: true)
                }
            } else {
                VStack(spacing: 0) {
                    map.frame(height: geometry.size.height * (expanded ? 0.42 : 0.57))
                    gallery(alwaysExpanded: false)
                }
            }
        }
        .navigationTitle("照片地图").navigationBarTitleDisplayMode(.inline)
        .background(NativeTheme.background)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingFilter = true
                } label: {
                    Label("筛选", systemImage: filters.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
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
        .task(id: galleryRequest) {
            await results.loadGallery(galleryRequest, debounce: viewport != nil && !showingUnlocated && selectedGroup == nil)
        }
        .onChange(of: filterQuery) { _ in
            results.clearSummary()
            showOverview()
        }
        .onReceive(results.session.uploadsChanged) { _ in revision += 1 }
        .fullScreenCover(item: $preview) { item in
            NativeMediaDetail(session: results.session, initial: item, profiles: filters.profiles,
                              pagePosition: nil, previous: nil, next: nil,
                              onSaved: refreshAfterEdit, onDeleted: refreshAfterEdit, onLocate: nil)
        }
    }

    private var map: some View {
        let groups = results.summary(for: summaryRequest)?.groups ?? []
        return NativeMapCanvas(groups: groups, camera: camera, onSelect: selectGroup) { bounds, level in
            let next = NativeMapViewport(bounds: bounds, level: level)
            guard viewport != next else { return }
            viewport = next
            if level == nil { selectedGroup = nil; showingUnlocated = false }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if viewport != nil || selectedGroup != nil {
                    Button("显示全部", action: showOverview).buttonStyle(NativeActionStyle(compact: true))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                }
                if !groups.isEmpty {
                    Menu {
                        ForEach(groups) { group in
                            Button(group.accessibilityTitle) { selectGroup(group) }
                        }
                    } label: {
                        Label("地点列表", systemImage: "list.bullet")
                    }
                    .buttonStyle(NativeActionStyle(compact: true))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                }
            }.padding(12)
        }
        .overlay(alignment: .topLeading) {
            if results.mapLoading {
                ProgressView().padding(12).background(.regularMaterial, in: Circle())
                    .accessibilityLabel("正在读取地图地点").padding(12)
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

    private func gallery(alwaysExpanded: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { galleryHeading; Spacer(minLength: 8); unlocatedButton }
                    VStack(alignment: .leading) { galleryHeading; unlocatedButton }
                }

                if !results.galleryError.isEmpty {
                    Text(results.galleryError).font(.footnote).foregroundStyle(NativeTheme.secondaryText)
                    Button("重试影像") {
                        let more = !results.items.isEmpty
                        Task { await results.loadGallery(galleryRequest, more: more) }
                    }.buttonStyle(NativeActionStyle())
                }
                if results.items.isEmpty {
                    if results.galleryLoading {
                        ProgressView("正在读取影像…")
                    } else if results.galleryError.isEmpty {
                        Text(showingUnlocated ? "筛选范围内的影像都有坐标。" :
                                (viewport == nil ? "筛选范围内没有带坐标的影像。" : "当前地图范围没有影像。"))
                            .font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
                    }
                } else {
                    let showAll = alwaysExpanded || expanded
                    let visible = showAll ? results.items : Array(results.items.prefix(3))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: showAll ? 84 : 76), spacing: 8)], spacing: 12) {
                        ForEach(visible) { item in mediaTile(item) }
                    }
                    if results.total > 3 && !alwaysExpanded {
                        Button(expanded ? "收起影像" : "查看全部影像") { expanded.toggle() }
                            .buttonStyle(NativeActionStyle(compact: true))
                    }
                    if showAll && results.items.count < results.total {
                        Button(results.galleryLoading ? "正在加载…" : "加载更多") {
                            Task { await results.loadGallery(galleryRequest, more: true) }
                        }.buttonStyle(NativeActionStyle(compact: true)).disabled(results.galleryLoading)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NativeTheme.surface)
    }

    private var galleryHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(galleryTitle).font(.headline).accessibilityAddTraits(.isHeader)
            if !results.galleryLoading || !results.items.isEmpty {
                Text("\(results.total) 项影像").font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
            }
        }
    }

    private var unlocatedButton: some View {
        Button(showingUnlocated ? "返回地图影像" : "无坐标 \(results.unlocated)") {
            showingUnlocated.toggle()
            if !showingUnlocated { selectedGroup = nil }
        }.buttonStyle(NativeActionStyle(compact: true))
    }

    private func mediaTile(_ item: NativeTimelineItem) -> some View {
        Button { preview = item } label: {
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

    private func selectGroup(_ group: NativeMapGroup) {
        guard let summary = results.summary(for: summaryRequest) else { return }
        showingUnlocated = false
        selectedGroup = NativeMapSelection(group: group, level: summary.level, viewport: viewport)
        if summary.level == .local && group.bounds.longitudeSpan < 0.002 && group.bounds.north - group.bounds.south < 0.002 {
            return
        }
        camera = NativeMapCamera(bounds: group.bounds, reportLevel: group.next_level)
    }

    private func showOverview() {
        selectedGroup = nil
        showingUnlocated = false
        viewport = nil
        revision += 1
    }

    private func refreshAfterEdit() {
        selectedGroup = nil
        revision += 1
        onMediaChanged()
    }
}

private final class NativeMapAnnotation: NSObject, MKAnnotation {
    let group: NativeMapGroup
    var coordinate: CLLocationCoordinate2D { group.coordinate }
    var title: String? { group.title }
    var subtitle: String? { "\(group.count) 项影像" }

    init(group: NativeMapGroup) { self.group = group }
}

private struct NativeMapCanvas: UIViewRepresentable {
    let groups: [NativeMapGroup]
    let camera: NativeMapCamera?
    let onSelect: (NativeMapGroup) -> Void
    let onMove: (NativeMapBounds, NativeMapLevel?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.pointOfInterestFilter = .excludingAll
        view.showsCompass = false
        view.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "media")
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onMove = onMove
        coordinator.updateGroups(groups, in: view)
        if let camera, coordinator.cameraID != camera.id { coordinator.move(camera, in: view) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: ((NativeMapGroup) -> Void)?
        var onMove: ((NativeMapBounds, NativeMapLevel?) -> Void)?
        var cameraID: UUID?
        private var changingCamera = false
        private var ready = false
        private var annotations: [String: NativeMapAnnotation] = [:]

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
        }

        func move(_ camera: NativeMapCamera, in view: MKMapView) {
            cameraID = camera.id
            changingCamera = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.cameraID == camera.id else { return }
                view.setRegion(camera.bounds.cameraRegion, animated: false)
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.cameraID == camera.id else { return }
                    if let level = camera.reportLevel, let bounds = NativeMapBounds(visibleRect: view.visibleMapRect) {
                        self.onMove?(bounds, level)
                    }
                    self.changingCamera = false
                    self.ready = true
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard ready, !changingCamera, let bounds = NativeMapBounds(visibleRect: mapView.visibleMapRect) else { return }
            onMove?(bounds, nil)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? NativeMapAnnotation,
                  let marker = mapView.dequeueReusableAnnotationView(withIdentifier: "media", for: annotation) as? MKMarkerAnnotationView else { return nil }
            marker.glyphText = String(annotation.group.count)
            marker.markerTintColor = UIColor(NativeTheme.accent)
            marker.glyphTintColor = UIColor(NativeTheme.onAccent)
            marker.titleVisibility = annotation.group.name == nil ? .hidden : .visible
            marker.subtitleVisibility = .hidden
            marker.canShowCallout = false
            marker.accessibilityLabel = annotation.group.accessibilityTitle
            return marker
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? NativeMapAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onSelect?(annotation.group)
        }
    }
}
