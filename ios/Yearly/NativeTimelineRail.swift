import SwiftUI

struct NativeTimelineRail: View {
    let days: [String]
    let current: String
    var disabled = false
    let hold: (Bool) -> Void
    let scrub: (String) -> Void
    let select: (String) -> Void
    @State private var dragRatio: CGFloat?
    @GestureState private var dragging = false
    @State private var scale = NativeTimelineScale(days: [])
    @State private var markers: [String] = []

    private var currentIndex: Int { days.firstIndex(of: current) ?? 0 }

    var body: some View {
        if let first = days.first {
            let ratio = dragRatio ?? scale.ratio(for: current)
            let day = scale.nearest(to: ratio) ?? first
            VStack(spacing: 12) {
                Text(day.prefix(4))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NativeTheme.accent)
                    .frame(width: 44, height: 24)
                    .background(NativeTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("timeline-rail-year")
                GeometryReader { geometry in
                    let trackHeight = max(0, geometry.size.height - 32)
                    let currentY = 16 + ratio * trackHeight
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.secondary.opacity(0.20))
                            .frame(width: 1.5, height: trackHeight)
                            .position(x: 39, y: geometry.size.height / 2)
                        ForEach(Array(markers.enumerated()), id: \.element) { index, marker in
                            let markerY = 16 + scale.ratio(for: marker) * trackHeight
                            Circle().fill(NativeTheme.accent.opacity(0.55)).frame(width: 5, height: 5)
                                .position(x: 39, y: markerY)
                            if abs(markerY - currentY) > 26 {
                                VStack(spacing: 2) {
                                    if index == 0 || marker.prefix(4) != markers[index - 1].prefix(4) {
                                        Text(marker.prefix(4)).font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                    }
                                    Text(marker.dropFirst(5).replacingOccurrences(of: "-", with: "."))
                                        .font(.system(size: 9)).foregroundStyle(NativeTheme.secondaryText)
                                }
                                .monospacedDigit().frame(width: 32, alignment: .trailing)
                                .position(x: 16, y: markerY)
                            }
                        }
                        Circle().fill(NativeTheme.accent.opacity(0.14)).frame(width: 18, height: 18)
                            .position(x: 39, y: currentY)
                        Circle().fill(NativeTheme.accent).frame(width: 9, height: 9)
                            .position(x: 39, y: currentY)
                        Text(day.dropFirst(5).replacingOccurrences(of: "-", with: "."))
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(NativeTheme.accent).frame(width: 34, height: 22)
                            .background(NativeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            .position(x: 17, y: currentY)
                    }
                    .frame(width: 44, height: geometry.size.height)
                    .overlay(alignment: .topLeading) {
                        if dragRatio != nil {
                            let badgeHeight: CGFloat = 32
                            let top = min(max(0, currentY - badgeHeight - 12),
                                          max(0, geometry.size.height - badgeHeight))
                            Text(day.replacingOccurrences(of: "-", with: "."))
                                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 12).frame(height: badgeHeight)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                                .fixedSize()
                                .padding(.leading, geometry.size.width + 16)
                                .offset(y: top)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 6)
                        .updating($dragging) { _, dragging, _ in dragging = true }
                        .onChanged { value in
                            if dragRatio == nil { hold(true) }
                            let valueRatio = min(1, max(0, (value.location.y - 16) / max(1, trackHeight)))
                            dragRatio = valueRatio
                            if let day = scale.nearest(to: valueRatio) { scrub(day) }
                        }
                        .exclusively(before: SpatialTapGesture()
                            .onEnded { value in
                                let ratio = min(1, max(0, (value.location.y - 16) / max(1, trackHeight)))
                                if let nearest = markers.min(by: { abs(scale.ratio(for: $0) - ratio) < abs(scale.ratio(for: $1) - ratio) }) {
                                    select(nearest)
                                }
                            }))
                    .onChange(of: dragging) { active in
                        if !active {
                            dragRatio = nil
                            hold(false)
                        }
                    }
                    .allowsHitTesting(!disabled)
                    .onAppear {
                        scale = NativeTimelineScale(days: days)
                        markers = scale.markers(height: trackHeight)
                    }
                    .onChange(of: days) { days in
                        scale = NativeTimelineScale(days: days)
                        markers = scale.markers(height: trackHeight)
                    }
                    .onChange(of: trackHeight) { height in markers = scale.markers(height: height) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("拖动时间轴定位日期")
                .accessibilityValue(day)
                .accessibilityHint("拖动连续浏览，点击跳到日期节点")
                .accessibilityAdjustableAction { direction in
                    guard !disabled else { return }
                    let next = direction == .increment ? currentIndex + 1 : currentIndex - 1
                    select(days[min(days.count - 1, max(0, next))])
                }
            }
            .frame(width: 44).padding(.vertical, 8)
            .transaction { $0.animation = nil }
        }
    }
}

struct NativeTimelineLayout: Equatable {
    var days: [String: CGRect] = [:]
    var height: CGFloat = 0
}

struct NativeTimelineDayPositions: PreferenceKey {
    static var defaultValue = NativeTimelineLayout()
    static func reduce(value: inout NativeTimelineLayout, nextValue: () -> NativeTimelineLayout) {
        let next = nextValue()
        value.days.merge(next.days) { _, next in next }
        value.height = max(value.height, next.height)
    }
}

// Geometry and UIKit references do not drive SwiftUI rendering on every scroll tick.
final class NativeTimelineViewport {
    weak var scroll: UIScrollView?
    var days: [String: CGRect] = [:]
    var height: CGFloat = 0
}

struct NativeTimelineScrollReader: UIViewRepresentable {
    let refresh: () async -> Void
    let resolve: (UIScrollView) -> Void
    let didScroll: (UIScrollView) -> Void
    final class Coordinator: NSObject {
        let refreshControl = UIRefreshControl()
        var refresh: () async -> Void
        var refreshTask: Task<Void, Never>?
        weak var scroll: UIScrollView?
        var layoutObservation: NSKeyValueObservation?
        var scrollObservation: NSKeyValueObservation?
        var scrollUpdateQueued = false
        var resolve: (UIScrollView) -> Void
        var didScroll: (UIScrollView) -> Void
        init(refresh: @escaping () async -> Void, resolve: @escaping (UIScrollView) -> Void, didScroll: @escaping (UIScrollView) -> Void) {
            self.refresh = refresh
            self.resolve = resolve
            self.didScroll = didScroll
            super.init()
            refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        }
        @objc private func refreshRequested() {
            guard refreshTask == nil else { return }
            refreshTask = Task { @MainActor in
                await refresh()
                refreshControl.endRefreshing()
                refreshTask = nil
            }
        }
    }
    final class Probe: UIView {
        var attach: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach?(self) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(refresh: refresh, resolve: resolve, didScroll: didScroll) }
    func makeUIView(context: Context) -> UIView {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        (view as? Probe)?.attach = nil
        coordinator.refreshTask?.cancel()
        if coordinator.scroll?.refreshControl === coordinator.refreshControl {
            coordinator.scroll?.refreshControl = nil
        }
        coordinator.layoutObservation = nil
        coordinator.scrollObservation = nil
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.refresh = refresh
        coordinator.resolve = resolve
        coordinator.didScroll = didScroll
        let attach: (UIView) -> Void = { view in
            DispatchQueue.main.async { [weak view] in
                guard let view = view as? Probe, view.attach != nil else { return }
                var ancestor = view.superview
                while let parent = ancestor {
                    if let scroll = parent as? UIScrollView {
                        if scroll.refreshControl !== coordinator.refreshControl {
                            scroll.refreshControl = coordinator.refreshControl
                        }
                        guard coordinator.scroll !== scroll else { return }
                        coordinator.scroll = scroll
                        scroll.alwaysBounceVertical = true
                        coordinator.layoutObservation = scroll.observe(\.contentSize, options: [.new]) { [weak coordinator] scroll, _ in
                            DispatchQueue.main.async { coordinator?.resolve(scroll) }
                        }
                        coordinator.scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak coordinator] scroll, _ in
                            guard let coordinator, !coordinator.scrollUpdateQueued else { return }
                            coordinator.scrollUpdateQueued = true
                            DispatchQueue.main.async { [weak coordinator] in
                                guard let coordinator else { return }
                                coordinator.scrollUpdateQueued = false
                                coordinator.didScroll(scroll)
                            }
                        }
                        coordinator.resolve(scroll)
                        return
                    }
                    ancestor = parent.superview
                }
            }
        }
        (view as? Probe)?.attach = attach
        attach(view)
    }
}
