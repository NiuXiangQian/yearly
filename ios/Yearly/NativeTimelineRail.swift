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
                            Text(day).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.primary).padding(.horizontal, 12).padding(.vertical, 9)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .fixedSize().offset(x: 44, y: ratio * geometry.size.height - 17)
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

struct NativeTimelineScrollReader: UIViewRepresentable {
    let resolve: (UIScrollView) -> Void
    let didScroll: (UIScrollView) -> Void
    final class Coordinator {
        weak var scroll: UIScrollView?
        var layoutObservation: NSKeyValueObservation?
        var scrollObservation: NSKeyValueObservation?
        var resolve: (UIScrollView) -> Void
        var didScroll: (UIScrollView) -> Void
        init(resolve: @escaping (UIScrollView) -> Void, didScroll: @escaping (UIScrollView) -> Void) {
            self.resolve = resolve
            self.didScroll = didScroll
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(resolve: resolve, didScroll: didScroll) }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.resolve = resolve
        coordinator.didScroll = didScroll
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let parent = ancestor {
                if let scroll = parent as? UIScrollView {
                    guard coordinator.scroll !== scroll else { return }
                    coordinator.scroll = scroll
                    coordinator.layoutObservation = scroll.observe(\.contentSize, options: [.new]) { [weak coordinator] scroll, _ in
                        DispatchQueue.main.async { coordinator?.resolve(scroll) }
                    }
                    coordinator.scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak coordinator] scroll, _ in
                        coordinator?.didScroll(scroll)
                    }
                    coordinator.resolve(scroll)
                    return
                }
                ancestor = parent.superview
            }
        }
    }
}
