import SwiftUI

struct NativeTimelineRail: View {
    let days: [String]
    let current: String
    var disabled = false
    let select: (String) -> Void
    @GestureState private var dragY: CGFloat?

    private var currentIndex: Int { days.firstIndex(of: current) ?? (current == "日期未知" ? days.count - 1 : 0) }
    private func index(at y: CGFloat, height: CGFloat) -> Int {
        Int((min(1, max(0, y / height)) * CGFloat(days.count - 1)).rounded())
    }

    var body: some View {
        if let first = days.first, let last = days.last {
            VStack(spacing: 18) {
                Text(first.prefix(7).replacingOccurrences(of: "-", with: "."))
                GeometryReader { geometry in
                    let selectedIndex = dragY.map { index(at: $0, height: geometry.size.height) } ?? currentIndex
                    let y = days.count > 1 ? CGFloat(selectedIndex) / CGFloat(days.count - 1) * geometry.size.height : 0
                    let tickSpacing = days.count > 1 ? geometry.size.height / CGFloat(days.count - 1) : 0
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.secondary.opacity(0.25))
                            .frame(width: 2, height: geometry.size.height)
                            .position(x: 22, y: geometry.size.height / 2)
                        ForEach(days.indices, id: \.self) { tick in
                            Circle().fill(.tint).opacity(0.65).frame(width: 6, height: 6)
                                .position(x: 22, y: CGFloat(tick) * tickSpacing)
                        }
                        Circle().fill(.tint).opacity(0.16).frame(width: 24, height: 24)
                            .position(x: 22, y: y)
                        Circle().fill(.tint).frame(width: 14, height: 14)
                            .position(x: 22, y: y)
                        if dragY != nil {
                            Text(days[selectedIndex]).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.primary).padding(.horizontal, 12).padding(.vertical, 9)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .fixedSize().offset(x: 44, y: y - 17)
                        }
                    }
                    .frame(width: 44, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($dragY) { value, state, _ in state = value.location.y }
                        .onEnded { value in select(days[index(at: value.location.y, height: geometry.size.height)]) })
                    .allowsHitTesting(!disabled)
                }
                Text(last.prefix(7).replacingOccurrences(of: "-", with: "."))
            }
            .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
            .frame(width: 44).padding(.vertical, 8)
            .opacity(disabled ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("拖动时间轴定位日期")
            .accessibilityValue(days[currentIndex])
            .accessibilityHint("上下拖动预览日期，松手后跳转")
            .accessibilityAdjustableAction { direction in
                guard !disabled else { return }
                let next = direction == .increment ? currentIndex + 1 : currentIndex - 1
                select(days[min(days.count - 1, max(0, next))])
            }
            .disabled(disabled)
        }
    }
}

struct NativeTimelineDayPositions: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, next in next }
    }
}
