import SwiftUI

struct NativeTimelineRail: View {
    let days: [String]
    let current: String
    var fraction: CGFloat = 0
    var disabled = false
    let hold: (Bool) -> Void
    let scrub: (String, CGFloat) -> Void
    let select: (String) -> Void
    @State private var dragRatio: CGFloat?
    @State private var moved = false

    private var currentIndex: Int { days.firstIndex(of: current) ?? 0 }

    var body: some View {
        if let first = days.first, let last = days.last {
            VStack(spacing: 18) {
                Text(first.prefix(7).replacingOccurrences(of: "-", with: "."))
                GeometryReader { geometry in
                    let ratio = dragRatio ?? (CGFloat(currentIndex) + fraction) / CGFloat(days.count)
                    let index = min(days.count - 1, Int(ratio * CGFloat(days.count)))
                    let step = max(1, Int(ceil(CGFloat(days.count) * 32 / geometry.size.height)))
                    let count = (days.count - 1) / step + 1
                    let markers = (0..<count).map { tick in
                        count == 1 ? 0 : Int((CGFloat(tick) / CGFloat(count - 1) * CGFloat(days.count - 1)).rounded())
                    }
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.secondary.opacity(0.25))
                            .frame(width: 2, height: geometry.size.height)
                            .position(x: 22, y: geometry.size.height / 2)
                        ForEach(markers, id: \.self) { tick in
                            Circle().fill(.tint).opacity(0.65).frame(width: 6, height: 6)
                                .position(x: 22, y: CGFloat(tick) / CGFloat(days.count) * geometry.size.height)
                        }
                        Circle().fill(.tint).opacity(0.16).frame(width: 24, height: 24)
                            .position(x: 22, y: ratio * geometry.size.height)
                        Circle().fill(.tint).frame(width: 14, height: 14)
                            .position(x: 22, y: ratio * geometry.size.height)
                    }
                    .frame(width: 44, height: geometry.size.height)
                    .overlay(alignment: .topLeading) {
                        if dragRatio != nil {
                            Text(days[index]).font(.system(size: 13, weight: .semibold)).monospacedDigit()
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
                            if moved {
                                let index = min(days.count - 1, Int(valueRatio * CGFloat(days.count)))
                                scrub(days[index], valueRatio * CGFloat(days.count) - CGFloat(index))
                            }
                        }
                        .onEnded { value in
                            if !moved {
                                let index = min(CGFloat(days.count - 1), max(0, value.location.y / geometry.size.height) * CGFloat(days.count))
                                if let nearest = markers.min(by: { abs(CGFloat($0) - index) < abs(CGFloat($1) - index) }) {
                                    select(days[nearest])
                                }
                            }
                            hold(false)
                            dragRatio = nil
                            moved = false
                        })
                    .allowsHitTesting(!disabled)
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

struct NativeTimelineDayFrame: Equatable {
    let visible: CGRect
    let content: CGRect
}

struct NativeTimelineDayPositions: PreferenceKey {
    static var defaultValue: [String: NativeTimelineDayFrame] = [:]
    static func reduce(value: inout [String: NativeTimelineDayFrame], nextValue: () -> [String: NativeTimelineDayFrame]) {
        value.merge(nextValue()) { _, next in next }
    }
}

struct NativeTimelineScrollReader: UIViewRepresentable {
    let resolve: (UIScrollView) -> Void
    final class Coordinator {
        weak var scroll: UIScrollView?
        var observation: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let parent = ancestor {
                if let scroll = parent as? UIScrollView {
                    if context.coordinator.scroll !== scroll {
                        context.coordinator.scroll = scroll
                        context.coordinator.observation = scroll.observe(\.contentSize, options: [.new]) { scroll, _ in
                            DispatchQueue.main.async { resolve(scroll) }
                        }
                    }
                    resolve(scroll)
                    return
                }
                ancestor = parent.superview
            }
        }
    }
}
