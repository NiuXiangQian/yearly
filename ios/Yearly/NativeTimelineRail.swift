import SwiftUI

struct NativeTimelineRail: View {
    let days: [String]
    let current: String
    var disabled = false
    let hold: (Bool) -> Void
    let scrub: (String) -> Void
    let select: (String) -> Void
    @State private var dragRatio: CGFloat?
    @State private var moved = false
    @State private var scale = NativeTimelineScale(days: [])
    @State private var markers: [String] = []

    private var currentIndex: Int { days.firstIndex(of: current) ?? 0 }

    var body: some View {
        if let first = days.first, let last = days.last {
            VStack(spacing: 18) {
                Text(first.prefix(7).replacingOccurrences(of: "-", with: "."))
                GeometryReader { geometry in
                    let ratio = dragRatio ?? scale.ratio(for: current)
                    let day = scale.nearest(to: ratio) ?? first
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.secondary.opacity(0.25))
                            .frame(width: 2, height: geometry.size.height)
                            .position(x: 22, y: geometry.size.height / 2)
                        ForEach(markers, id: \.self) { marker in
                            Circle().fill(.tint).opacity(0.65).frame(width: 6, height: 6)
                                .position(x: 22, y: scale.ratio(for: marker) * geometry.size.height)
                        }
                        Circle().fill(.tint).opacity(0.16).frame(width: 24, height: 24)
                            .position(x: 22, y: ratio * geometry.size.height)
                        Circle().fill(.tint).frame(width: 14, height: 14)
                            .position(x: 22, y: ratio * geometry.size.height)
                    }
                    .frame(width: 44, height: geometry.size.height)
                    .overlay(alignment: .topLeading) {
                        if dragRatio != nil {
                            let badgeHeight: CGFloat = 32
                            let top = min(max(0, ratio * geometry.size.height - badgeHeight - 12),
                                          max(0, geometry.size.height - badgeHeight))
                            Text(day.replacingOccurrences(of: "-", with: "."))
                                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12).frame(height: badgeHeight)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                                .fixedSize()
                                .padding(.leading, geometry.size.width + 32)
                                .offset(y: top)
                                .allowsHitTesting(false)
                        } else {
                            Text(day.dropFirst(5).replacingOccurrences(of: "-", with: "."))
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit().foregroundStyle(.tint)
                                .frame(width: 40).padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .position(x: 22, y: ratio * geometry.size.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragRatio == nil { moved = false; hold(true) }
                            let valueRatio = min(1, max(0, value.location.y / geometry.size.height))
                            dragRatio = valueRatio
                            if abs(value.translation.height) > 6 { moved = true }
                            if moved, let day = scale.nearest(to: valueRatio) { scrub(day) }
                        }
                        .onEnded { value in
                            if !moved {
                                let ratio = min(1, max(0, value.location.y / geometry.size.height))
                                if let nearest = markers.min(by: { abs(scale.ratio(for: $0) - ratio) < abs(scale.ratio(for: $1) - ratio) }) {
                                    select(nearest)
                                }
                            }
                            hold(false)
                            dragRatio = nil
                            moved = false
                        })
                    .allowsHitTesting(!disabled)
                    .onAppear {
                        scale = NativeTimelineScale(days: days)
                        markers = scale.markers(height: geometry.size.height)
                    }
                    .onChange(of: days) { days in
                        scale = NativeTimelineScale(days: days)
                        markers = scale.markers(height: geometry.size.height)
                    }
                    .onChange(of: geometry.size.height) { height in markers = scale.markers(height: height) }
                }
                Text(last.prefix(7).replacingOccurrences(of: "-", with: "."))
            }
            .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
            .frame(width: 44).padding(.vertical, 8)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("拖动时间轴定位日期")
            .accessibilityValue(days[currentIndex])
            .accessibilityHint("拖动连续浏览，点击跳到日期节点")
            .accessibilityAdjustableAction { direction in
                guard !disabled else { return }
                let next = direction == .increment ? currentIndex + 1 : currentIndex - 1
                select(days[min(days.count - 1, max(0, next))])
            }
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
    func makeUIView(context: Context) -> UIView { Probe() }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        (view as? Probe)?.attach = nil
        coordinator.refreshTask?.cancel()
        coordinator.scroll?.refreshControl = nil
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.refresh = refresh
        coordinator.resolve = resolve
        coordinator.didScroll = didScroll
        let attach: (UIView) -> Void = { view in
            DispatchQueue.main.async {
                var ancestor = view.superview
                while let parent = ancestor {
                    if let scroll = parent as? UIScrollView {
                        guard coordinator.scroll !== scroll else { coordinator.resolve(scroll); return }
                        coordinator.scroll = scroll
                        scroll.alwaysBounceVertical = true
                        scroll.refreshControl = coordinator.refreshControl
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
