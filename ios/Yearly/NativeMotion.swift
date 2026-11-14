import SwiftUI
import UIKit

enum NativeMotion {
    static let spring = Animation.interpolatingSpring(stiffness: 300, damping: 27)
    static let duration = 0.4
}

struct NativeLiquidNavigation: View {
    @Binding var selection: Int
    var showsMemoryReview = false
    let repeatTimeline: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstEdge: CGFloat = 0
    @State private var lastEdge: CGFloat = 0
    @State private var previous = 0
    private var titles: [String] { ["时间线", "上传", "家人", "账号"] + (showsMemoryReview ? ["照片助手"] : []) }
    private var symbols: [String] { ["photo.on.rectangle", "square.and.arrow.up", "person.2", "person.crop.circle"] + (showsMemoryReview ? ["sparkles"] : []) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(titles.count)
            ZStack(alignment: .leading) {
                NativeLiquidCapsule(first: firstEdge, last: lastEdge, cell: width)
                    .fill(NativeTheme.accent.opacity(0.12))
                    .allowsHitTesting(false)
                HStack(spacing: 0) {
                    ForEach(titles.indices, id: \.self) { index in
                        Button {
                            if index == 0 && selection == 0 { repeatTimeline() }
                            selection = index
                        } label: {
                            NativeNavigationLabel(title: titles[index], symbol: symbols[index], selected: selection == index)
                                .frame(maxWidth: .infinity).frame(height: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selection == index ? .isSelected : [])
                    }
                }
            }
        }.frame(height: 60).padding(.horizontal, 8).background(.bar)
            .onAppear { firstEdge = CGFloat(selection); lastEdge = firstEdge; previous = selection }
            .onChange(of: selection) { next in
                let forward = next > previous
                previous = next
                withAnimation(reduceMotion ? nil : NativeMotion.spring) {
                    if forward { lastEdge = CGFloat(next) } else { firstEdge = CGFloat(next) }
                }
                withAnimation(reduceMotion ? nil : NativeMotion.spring.delay(0.055)) {
                    if forward { firstEdge = CGFloat(next) } else { lastEdge = CGFloat(next) }
                }
            }
    }
}

private struct NativeLiquidCapsule: Shape {
    var first: CGFloat
    var last: CGFloat
    let cell: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(first, last) }
        set { first = newValue.first; last = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let compression = min(10, abs(last - first) * 8)
        return Path(roundedRect: CGRect(x: min(first, last) * cell + 5, y: 4 + compression / 2,
                                       width: (abs(last - first) + 1) * cell - 10, height: 50 - compression),
                    cornerRadius: 25)
    }
}

private struct NativeNavigationLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    @State private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 21)).scaleEffect(scale)
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
        }.foregroundStyle(selected ? NativeTheme.accent : Color.secondary)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: selected)
            .task(id: selected) {
                guard selected, !reduceMotion else { scale = 1; return }
                withAnimation(.easeOut(duration: 0.08)) { scale = 0.78 }
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(NativeMotion.spring) { scale = 1 }
            }
    }
}

struct NativeSegmentPages: View {
    let titles: [String]
    let pages: [AnyView]
    @State private var selected = 0
    @State private var position: CGFloat = 0
    @State private var dragging = false
    @State private var dragOrigin: CGFloat = 0
    @State private var settling: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let current = position
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(titles.indices, id: \.self) { index in
                        let emphasis = max(0, 1 - abs(current - CGFloat(index)))
                        Button {
                            settle(on: index)
                        } label: {
                            Text(titles[index]).font(Font(UIFont.systemFont(ofSize: 14, weight: UIFont.Weight(rawValue: UIFont.Weight.regular.rawValue + emphasis * (UIFont.Weight.semibold.rawValue - UIFont.Weight.regular.rawValue)))))
                                .foregroundStyle(NativeTheme.accent.opacity(0.5 + emphasis * 0.5))
                                .frame(maxWidth: .infinity).frame(minHeight: 48)
                        }.buttonStyle(.plain).accessibilityAddTraits(selected == index ? .isSelected : [])
                    }
                }.overlay(alignment: .bottomLeading) {
                    NativeWormUnderline(position: current, count: pages.count).fill(NativeTheme.accent).frame(height: 3)
                }
                HStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        pages[index].frame(width: width).accessibilityHidden(selected != index)
                            .allowsHitTesting(selected == index)
                    }
                }.frame(width: width, alignment: .leading).offset(x: -current * width)
                    .simultaneousGesture(DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if !dragging { settling?.cancel(); dragOrigin = position; dragging = true }
                            position = min(CGFloat(pages.count - 1), max(0, dragOrigin - value.translation.width / max(1, width)))
                        }.onEnded { _ in
                            guard dragging else { return }
                            dragging = false
                            settle(on: min(pages.count - 1, max(0, Int(position.rounded()))))
                        })
            }.clipped()
        }.onDisappear { settling?.cancel() }
    }

    private func settle(on index: Int) {
        settling?.cancel()
        selected = index
        guard !reduceMotion else { position = CGFloat(index); return }
        let origin = position, target = CGFloat(index)
        settling = Task { @MainActor in
            let started = Date.timeIntervalSinceReferenceDate
            while !Task.isCancelled {
                let elapsed = min(1, (Date.timeIntervalSinceReferenceDate - started) / NativeMotion.duration)
                position = elapsed == 1 ? target : origin + (target - origin) * (1 - exp(-7 * elapsed) * cos(10 * elapsed))
                if elapsed == 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
}

private struct NativeWormUnderline: Shape {
    var position: CGFloat
    let count: Int
    var animatableData: CGFloat { get { position } set { position = newValue } }
    func path(in rect: CGRect) -> Path {
        let base = floor(position), fraction = position - base, width = rect.width / CGFloat(count)
        let left = (base + fraction * fraction) * width
        let right = (base + 2 - pow(1 - fraction, 2)) * width
        return Path(roundedRect: CGRect(x: left + 10, y: 0, width: max(0, right - left - 20), height: 3), cornerRadius: 2)
    }
}

private struct NativeSheetDismissKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private extension EnvironmentValues {
    var motionDismiss: (() -> Void)? {
        get { self[NativeSheetDismissKey.self] }
        set { self[NativeSheetDismissKey.self] = newValue }
    }
}
@propertyWrapper struct NativeDismiss: DynamicProperty {
    @Environment(\.dismiss) private var system
    @Environment(\.motionDismiss) private var custom
    var wrappedValue: NativeDismiss { self }
    func callAsFunction() { if let custom { custom() } else { system() } }
}
private struct NativeDismissDisabledKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension View {
    func nativeInteractiveDismissDisabled(_ disabled: Bool) -> some View {
        interactiveDismissDisabled(disabled).preference(key: NativeDismissDisabledKey.self, value: disabled)
    }
    func nativeSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(NativeSheetBridge(presented: isPresented, onDismiss: onDismiss, sheet: { AnyView(content()) }))
    }
    func nativeSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        nativeSheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
private struct NativeSheetBridge: UIViewControllerRepresentable {
    @Binding var presented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.closed = { presented = false; onDismiss?() }
        let content = AnyView(sheet().tint(NativeTheme.accent).environment(\.motionDismiss, { coordinator.host?.dismiss(animated: true) })
            .onPreferenceChange(NativeDismissDisabledKey.self) { coordinator.canDismiss = !$0 })
        if let host = coordinator.host {
            if presented { host.rootView = content }
            else if !host.isBeingDismissed { host.dismiss(animated: true) }
        } else if presented {
            DispatchQueue.main.async {
                guard coordinator.host == nil, controller.view.window != nil else { return }
                let host = UIHostingController(rootView: content)
                host.modalPresentationStyle = .custom
                host.transitioningDelegate = coordinator
                host.view.backgroundColor = UIColor(NativeTheme.background)
                coordinator.host = host
                controller.present(host, animated: true)
            }
        }
    }
    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        weak var host: UIHostingController<AnyView>?
        var closed: (() -> Void)?
        var canDismiss = true
        var interaction: UIPercentDrivenInteractiveTransition?
        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            NativeSheetPresentation(presentedViewController: presented, presenting: presenting, owner: self)
        }
        func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? { NativeSheetAnimator(presenting: true) }
        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? { NativeSheetAnimator(presenting: false) }
        func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? { interaction }
    }
}
private final class NativeSheetPresentation: UIPresentationController, UIGestureRecognizerDelegate {
    let dim = UIView()
    let handle = UIView()
    let owner: NativeSheetBridge.Coordinator
    var backgroundTransform = CGAffineTransform.identity
    var backgroundCornerRadius: CGFloat = 0
    var backgroundClips = false
    init(presentedViewController: UIViewController, presenting: UIViewController?, owner: NativeSheetBridge.Coordinator) {
        self.owner = owner
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        let top = containerView.safeAreaInsets.top + 20
        return CGRect(x: 0, y: top, width: containerView.bounds.width, height: containerView.bounds.height - top)
    }
    override func presentationTransitionWillBegin() {
        guard let containerView, let presentedView else { return }
        let background = presentingViewController.view!
        backgroundTransform = background.transform
        backgroundCornerRadius = background.layer.cornerRadius
        backgroundClips = background.clipsToBounds
        dim.backgroundColor = .black; dim.alpha = 0; dim.frame = containerView.bounds
        containerView.insertSubview(dim, at: 0)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        presentedView.layer.cornerRadius = 24; presentedView.layer.cornerCurve = .continuous; presentedView.clipsToBounds = true
        presentedViewController.additionalSafeAreaInsets.top = 14
        handle.backgroundColor = .tertiaryLabel; handle.layer.cornerRadius = 2.5
        presentedView.addSubview(handle)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self; presentedView.addGestureRecognizer(pan)
    }
    override func containerViewWillLayoutSubviews() {
        presentedView?.frame = frameOfPresentedViewInContainerView
        dim.frame = containerView?.bounds ?? .zero
        handle.frame = CGRect(x: frameOfPresentedViewInContainerView.width / 2 - 18, y: 7, width: 36, height: 5)
    }
    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { dim.removeFromSuperview(); owner.host = nil; owner.closed?() }
        owner.interaction = nil
    }
    @objc private func close() { if owner.canDismiss { presentedViewController.dismiss(animated: true) } }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard owner.canDismiss, let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan.velocity(in: presentedView).y > abs(pan.velocity(in: presentedView).x) else { return false }
        var target = presentedView?.hitTest(pan.location(in: presentedView), with: nil)
        while let view = target, view !== presentedView {
            if view is UIControl { return false }
            if let scroll = view as? UIScrollView, scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 { return false }
            target = view.superview
        }
        return true
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        let height = frameOfPresentedViewInContainerView.height
        let progress = max(0, min(1, pan.translation(in: presentedView).y / height))
        switch pan.state {
        case .began:
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            owner.interaction = interaction
            presentedViewController.dismiss(animated: true)
        case .changed: owner.interaction?.update(progress)
        case .ended:
            if progress > 1 / 3 || (progress * height > 12 && pan.velocity(in: presentedView).y > 800) { owner.interaction?.finish() }
            else { owner.interaction?.cancel() }
        case .cancelled: owner.interaction?.cancel()
        default: break
        }
    }
}
private final class NativeSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    var animator: UIViewPropertyAnimator?
    init(presenting: Bool) { self.presenting = presenting }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0.15 : NativeMotion.duration }
    func animateTransition(using context: UIViewControllerContextTransitioning) { interruptibleAnimator(using: context).startAnimation() }
    func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        if let animator { return animator }
        let controller = context.viewController(forKey: presenting ? .to : .from)!
        let sheet = controller.view!
        let presentation = controller.presentationController as! NativeSheetPresentation
        let background = presentation.presentingViewController.view!
        let frame = presentation.frameOfPresentedViewInContainerView
        if presenting { context.containerView.addSubview(sheet); sheet.frame = frame; sheet.transform = CGAffineTransform(translationX: 0, y: frame.height) }
        let value = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.84) {
            sheet.transform = self.presenting ? .identity : CGAffineTransform(translationX: 0, y: frame.height)
            background.transform = self.presenting && !UIAccessibility.isReduceMotionEnabled ? CGAffineTransform(scaleX: 0.92, y: 0.92) : presentation.backgroundTransform
            background.layer.cornerRadius = self.presenting ? 24 : presentation.backgroundCornerRadius
            background.clipsToBounds = self.presenting || presentation.backgroundClips
            presentation.dim.alpha = self.presenting ? 0.26 : 0
        }
        value.addCompletion { _ in
            context.completeTransition(!context.transitionWasCancelled)
            self.animator = nil
        }
        animator = value
        return value
    }
}
