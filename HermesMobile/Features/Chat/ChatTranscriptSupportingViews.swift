import SwiftUI
import UIKit

struct ChatScrollMetrics: Equatable {
    let distanceFromBottom: CGFloat
    let isUserInteracting: Bool
}

struct ChatScrollObserver: UIViewRepresentable {
    let isStreaming: Bool
    let prependScrollPositionController: ChatPrependScrollPositionController?
    let onMetrics: @MainActor (ChatScrollMetrics) -> Void

    init(
        isStreaming: Bool,
        prependScrollPositionController: ChatPrependScrollPositionController? = nil,
        onMetrics: @escaping @MainActor (ChatScrollMetrics) -> Void
    ) {
        self.isStreaming = isStreaming
        self.prependScrollPositionController = prependScrollPositionController
        self.onMetrics = onMetrics
    }

    private var metricContext: MetricContext {
        MetricContext(isStreaming: isStreaming)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            metricContext: metricContext,
            prependScrollPositionController: prependScrollPositionController,
            onMetrics: onMetrics
        )
    }

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onMetrics = onMetrics
        context.coordinator.prependScrollPositionController = prependScrollPositionController
        uiView.coordinator = context.coordinator
        context.coordinator.updateMetricContext(metricContext)

        context.coordinator.attachIfNeeded(from: uiView, delivery: .deferred)
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        uiView.coordinator = nil
        coordinator.detach()
    }

    struct MetricContext: Equatable {
        let isStreaming: Bool
    }

    @MainActor
    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.prependScrollPositionController?.handleLayoutTick()
            coordinator?.reportMetrics(delivery: .deferred)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        enum MetricDelivery {
            case immediate
            case deferred
        }

        var onMetrics: @MainActor (ChatScrollMetrics) -> Void

        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var metricContext: MetricContext
        private var lastMetrics: ChatScrollMetrics?
        private var pendingMetrics: ChatScrollMetrics?
        private var hasScheduledMetricDelivery = false
        var prependScrollPositionController: ChatPrependScrollPositionController? {
            didSet {
                guard oldValue !== prependScrollPositionController else { return }
                oldValue?.detach()
                if let scrollView {
                    prependScrollPositionController?.attach(to: scrollView)
                }
            }
        }

        init(
            metricContext: MetricContext,
            prependScrollPositionController: ChatPrependScrollPositionController?,
            onMetrics: @escaping @MainActor (ChatScrollMetrics) -> Void
        ) {
            self.metricContext = metricContext
            self.prependScrollPositionController = prependScrollPositionController
            self.onMetrics = onMetrics
        }

        func updateMetricContext(_ newContext: MetricContext) {
            guard metricContext != newContext else { return }

            metricContext = newContext
            lastMetrics = nil
        }

        func attachIfNeeded(from view: UIView, delivery: MetricDelivery) {
            guard let scrollView = enclosingScrollView(for: view) else { return }

            guard scrollView !== self.scrollView else {
                prependScrollPositionController?.attach(to: scrollView)
                reportMetrics(delivery: delivery)
                return
            }

            observations.removeAll()
            lastMetrics = nil
            self.scrollView = scrollView
            prependScrollPositionController?.attach(to: scrollView)

            observations = [
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedMetrics(for: self)
                },
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedMetrics(for: self)
                }
            ]

            reportMetrics(delivery: delivery)
        }

        func detach() {
            observations.removeAll()
            prependScrollPositionController?.detach()
            lastMetrics = nil
            pendingMetrics = nil
            hasScheduledMetricDelivery = false
            scrollView = nil
        }

        func reportMetrics(delivery: MetricDelivery) {
            guard let scrollView else { return }

            let inset = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
            guard visibleHeight > 0 else { return }

            let currentOffset = scrollView.contentOffset.y + inset.top
            let maximumOffset = scrollView.contentSize.height - visibleHeight
            let distanceFromBottom = max(0, maximumOffset - currentOffset)
            let metrics = ChatScrollMetrics(
                distanceFromBottom: distanceFromBottom,
                isUserInteracting: scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
            )
            guard metrics != lastMetrics else { return }

            lastMetrics = metrics

            switch delivery {
            case .immediate:
                onMetrics(metrics)
            case .deferred:
                pendingMetrics = metrics
                guard !hasScheduledMetricDelivery else { return }

                hasScheduledMetricDelivery = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let metrics = self.pendingMetrics
                        self.pendingMetrics = nil
                        self.hasScheduledMetricDelivery = false
                        guard let metrics, self.lastMetrics == metrics else { return }
                        self.onMetrics(metrics)
                    }
                }
            }
        }

        nonisolated private static func reportObservedMetrics(for coordinator: Coordinator?) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak coordinator] in
                    MainActor.assumeIsolated {
                        coordinator?.reportMetrics(delivery: .deferred)
                    }
                }
                return
            }

            MainActor.assumeIsolated {
                coordinator?.reportMetrics(delivery: .deferred)
            }
        }

        private func enclosingScrollView(for view: UIView) -> UIScrollView? {
            var current = view.superview

            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }

                current = candidate.superview
            }

            return nil
        }
    }
}

/// Hosted tests assign this before constructing `ChatTranscriptView` so
/// `@State toolExpansionByGroupID` starts with the hoisted expansion map.
/// Production leaves it empty.
enum ChatTranscriptToolExpansionSeed {
    static var values: [String: Bool] = [:]
}

/// SwiftUI `.accessibilityIdentifier` is not copied onto UIKit views for
/// LazyVStack rows in-process. This probe is the UIView the prepend controller
/// and hosted tests walk. Optional `onActivate` / `isExpanded` let hosted tests
/// toggle and read tool-group expansion without relying on SwiftUI Button
/// actions or accessibility hints, which also never land on UIKit here.
final class TranscriptIdentifierProbeView: UIView {
    var onActivate: (() -> Void)?
    var isExpanded: Bool? {
        didSet {
            accessibilityValue = isExpanded.map { $0 ? "expanded" : "collapsed" }
        }
    }
}

struct TranscriptUIKitIdentifierProbe: UIViewRepresentable {
    let identifier: String
    var isExpanded: Bool? = nil
    var onActivate: (() -> Void)? = nil

    func makeUIView(context: Context) -> TranscriptIdentifierProbeView {
        let view = TranscriptIdentifierProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TranscriptIdentifierProbeView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TranscriptIdentifierProbeView) {
        view.accessibilityIdentifier = identifier
        view.isExpanded = isExpanded
        view.onActivate = onActivate
    }
}

/// Keeps the reader's exact vertical position while older transcript rows are
/// inserted above it. `ScrollViewProxy.scrollTo(_:anchor:)` can only align a row
/// to a coarse anchor; aligning the previous first row to `.top` loses the
/// intra-row offset and, under `LazyVStack`, can target an unrealized row.
///
/// Capture records the topmost visible `transcript.row.<renderID>` and its
/// intra-row offset. Restore locks to `clamp(rowMinY + intraRowOffsetY)` using
/// real UIKit `contentOffset` / `contentSize` and layout ticks — not eager
/// content-height delta and not a 1s ownership window.
@MainActor
final class ChatPrependScrollPositionController {
    enum RestoreResult: Equatable {
        case armed
        case userCancelled
        case failed
    }

    static let rowAccessibilityPrefix = "transcript.row."
    /// Reversible internal: consecutive stable layout ticks that release the hard lock.
    static let stableLayoutTickCount = 3

    private weak var scrollView: UIScrollView?
    private var contentSizeObservation: NSKeyValueObservation?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var isApplyingCompensation = false
    private var generation: UInt64 = 0
    private var capturedOffsetY: CGFloat?
    private var isHardLocked = false
    private var isSoftWatching = false
    private var consecutiveStableTicks = 0
    private var lastAnchorHeight: CGFloat?

    private(set) var capturedAnchorRenderID: String?
    private(set) var capturedIntraRowOffsetY: CGFloat = 0
    private(set) var needsRealizationProbe = false

    static func accessibilityIdentifier(forRenderID renderID: String) -> String {
        rowAccessibilityPrefix + renderID
    }

    func attach(to scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        cancelPreservation()
        self.scrollView = scrollView
    }

    func detach() {
        cancelPreservation()
        scrollView = nil
    }

    @discardableResult
    func capture() -> Bool {
        cancelPreservation()
        guard let scrollView else { return false }
        guard let row = topmostVisibleRow(in: scrollView) else { return false }

        let frameInContent = row.view.convert(row.view.bounds, to: scrollView)
        generation += 1
        capturedAnchorRenderID = row.renderID
        capturedIntraRowOffsetY = scrollView.contentOffset.y - frameInContent.minY
        capturedOffsetY = scrollView.contentOffset.y
        return true
    }

    /// Arms restore for the captured generation. User movement during the
    /// in-flight load is `.userCancelled` and must not fall through to `scrollTo`.
    @discardableResult
    func restoreAfterPrepend() -> RestoreResult {
        guard let scrollView,
              capturedAnchorRenderID != nil,
              let capturedOffsetY
        else {
            cancelPreservation()
            return .failed
        }

        if isUserMoving(scrollView) || abs(scrollView.contentOffset.y - capturedOffsetY) > 1 {
            cancelPreservation()
            return .userCancelled
        }

        needsRealizationProbe = findRow(renderID: capturedAnchorRenderID, in: scrollView) == nil
        isHardLocked = true
        isSoftWatching = true
        consecutiveStableTicks = 0
        lastAnchorHeight = nil

        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            Self.handleObservedContentSizeChange(for: self)
        }
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            Self.handleObservedUserMovement(for: self, scrollView: scrollView)
        }

        applyRestore(fromLayoutTick: false)
        return .armed
    }

    func cancelPreservation() {
        contentSizeObservation = nil
        contentOffsetObservation = nil
        capturedAnchorRenderID = nil
        capturedIntraRowOffsetY = 0
        capturedOffsetY = nil
        needsRealizationProbe = false
        isHardLocked = false
        isSoftWatching = false
        consecutiveStableTicks = 0
        lastAnchorHeight = nil
        isApplyingCompensation = false
    }

    func handleLayoutTick() {
        applyRestore(fromLayoutTick: true)
    }

    func markRealizationProbeUsed() {
        needsRealizationProbe = false
    }

    nonisolated static func clampedOffsetY(
        targetY: CGFloat,
        adjustedInset: UIEdgeInsets,
        contentSizeHeight: CGFloat,
        boundsHeight: CGFloat
    ) -> CGFloat {
        let minimumY = -adjustedInset.top
        let maximumY = max(
            minimumY,
            contentSizeHeight - boundsHeight + adjustedInset.bottom
        )
        return min(max(targetY, minimumY), maximumY)
    }

    nonisolated private static func handleObservedContentSizeChange(
        for controller: ChatPrependScrollPositionController?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak controller] in
                MainActor.assumeIsolated {
                    controller?.applyRestore(fromLayoutTick: false)
                }
            }
            return
        }

        MainActor.assumeIsolated {
            controller?.applyRestore(fromLayoutTick: false)
        }
    }

    nonisolated private static func handleObservedUserMovement(
        for controller: ChatPrependScrollPositionController?,
        scrollView: UIScrollView
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak controller, weak scrollView] in
                MainActor.assumeIsolated {
                    guard let scrollView else { return }
                    controller?.cancelIfUserIsMoving(scrollView)
                }
            }
            return
        }

        MainActor.assumeIsolated {
            controller?.cancelIfUserIsMoving(scrollView)
        }
    }

    private func cancelIfUserIsMoving(_ scrollView: UIScrollView) {
        guard !isApplyingCompensation, isUserMoving(scrollView) else { return }
        cancelPreservation()
    }

    private func isUserMoving(_ scrollView: UIScrollView) -> Bool {
        scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
    }

    private func applyRestore(fromLayoutTick: Bool) {
        guard isHardLocked || isSoftWatching, let scrollView, generation > 0 else { return }
        guard !isUserMoving(scrollView) else {
            cancelPreservation()
            return
        }
        guard let anchorID = capturedAnchorRenderID,
              let row = findRow(renderID: anchorID, in: scrollView)
        else { return }

        needsRealizationProbe = false
        let frameInContent = row.convert(row.bounds, to: scrollView)
        let targetY = Self.clampedOffsetY(
            targetY: frameInContent.minY + capturedIntraRowOffsetY,
            adjustedInset: scrollView.adjustedContentInset,
            contentSizeHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height
        )

        if abs(scrollView.contentOffset.y - targetY) > 0.5 {
            isApplyingCompensation = true
            var offset = scrollView.contentOffset
            offset.y = targetY
            scrollView.setContentOffset(offset, animated: false)
            isApplyingCompensation = false
            consecutiveStableTicks = 0
            lastAnchorHeight = frameInContent.height
            return
        }

        guard fromLayoutTick, isHardLocked else { return }

        if let lastAnchorHeight, abs(lastAnchorHeight - frameInContent.height) < 0.5 {
            consecutiveStableTicks += 1
        } else {
            consecutiveStableTicks = 0
        }
        lastAnchorHeight = frameInContent.height
        if consecutiveStableTicks >= Self.stableLayoutTickCount {
            isHardLocked = false
            isSoftWatching = true
        }
    }

    private func topmostVisibleRow(in scrollView: UIScrollView) -> (view: UIView, renderID: String)? {
        let visibleRect = scrollView.bounds
        var best: (view: UIView, minY: CGFloat, renderID: String)?
        enumerateRows(in: scrollView) { view, renderID, frameInContent in
            guard frameInContent.intersects(visibleRect) else { return }
            if best == nil || frameInContent.minY < best!.minY {
                best = (view, frameInContent.minY, renderID)
            }
        }
        return best.map { ($0.view, $0.renderID) }
    }

    private func findRow(renderID: String?, in scrollView: UIScrollView) -> UIView? {
        guard let renderID else { return nil }
        var match: UIView?
        enumerateRows(in: scrollView) { view, id, _ in
            if match == nil, id == renderID {
                match = view
            }
        }
        return match
    }

    private func enumerateRows(
        in root: UIView,
        visit: (UIView, String, CGRect) -> Void
    ) {
        if let identifier = root.accessibilityIdentifier,
           identifier.hasPrefix(Self.rowAccessibilityPrefix) {
            let renderID = String(identifier.dropFirst(Self.rowAccessibilityPrefix.count))
            if !renderID.isEmpty, let scrollView {
                visit(root, renderID, root.convert(root.bounds, to: scrollView))
            }
        }
        for subview in root.subviews {
            enumerateRows(in: subview, visit: visit)
        }
    }
}

/// Pins a subtree to left-to-right regardless of the surrounding chat layout
/// direction, so code, math, data tables, tool-call bodies, file paths, and
/// images never render mirrored inside an RTL message (issue #259). A fixed
/// `layoutDirection` also isolates the subtree's bidi resolution from the parent
/// paragraph direction.
///
/// Forcing LTR also changes how the *parent* resolves this view's
/// `.leading`/`.trailing` alignment guides: an LTR child inside an RTL
/// `VStack(alignment: .leading)` reports its leading edge as its physical left,
/// so the RTL parent — which pins `.leading` to its right edge — would hug or push
/// a narrower-than-container child off the wrong side. When the parent is RTL we
/// remap the guides back to the parent's expectation; in LTR (the default) the
/// guide closures return the unmodified values, so it is a no-op.
private struct ForcedLeftToRightModifier: ViewModifier {
    @Environment(\.layoutDirection) private var parentDirection

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, .leftToRight)
            .alignmentGuide(.leading) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.trailing] : dimensions[.leading]
            }
            .alignmentGuide(.trailing) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.leading] : dimensions[.trailing]
            }
    }
}

extension View {
    func forcedLeftToRight() -> some View {
        modifier(ForcedLeftToRightModifier())
    }
}

struct ChatVerticalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatVerticalScrollAxisGuardView {
        ChatVerticalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: ChatVerticalScrollAxisGuardView, context: Context) {
        // The transcript flips wholesale under the chat RTL toggle (#259); read
        // the resolved direction here so the guard pins the horizontal offset to
        // the layout-direction-aware leading edge (folds in #139).
        uiView.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        uiView.attachToNearestScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: ChatVerticalScrollAxisGuardView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
final class ChatVerticalScrollAxisGuardView: UIView {
    private weak var guardedScrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    /// Whether the guarded transcript is laid out right-to-left (#259). Drives
    /// which physical edge the horizontal offset rests against; re-clamps on change.
    var isRightToLeft = false {
        didSet {
            guard oldValue != isRightToLeft else { return }
            clampHorizontalOffset()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview != nil else {
            detach()
            return
        }

        attachToNearestScrollViewIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToNearestScrollViewIfNeeded()
    }

    func attachToNearestScrollViewIfNeeded() {
        guard let scrollView = enclosingScrollView() else { return }

        guard scrollView !== guardedScrollView else {
            clampHorizontalOffset()
            return
        }

        observations.removeAll()
        guardedScrollView = scrollView
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true

        observations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            // Under RTL the pinned rest offset depends on contentSize.width, so a
            // width change (a wide table/streaming code block loading) must re-clamp
            // immediately instead of waiting for the next offset/bounds change (#259).
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            }
        ]

        clampHorizontalOffset()
    }

    func detach() {
        observations.removeAll()
        guardedScrollView = nil
    }

    private func enclosingScrollView() -> UIScrollView? {
        sequence(first: superview, next: { $0?.superview })
            .first { $0 is UIScrollView } as? UIScrollView
    }

    private func clampHorizontalOffset() {
        guard let scrollView = guardedScrollView else { return }

        let pinnedX = Self.pinnedHorizontalOffsetX(
            isRightToLeft: isRightToLeft,
            adjustedInset: scrollView.adjustedContentInset,
            contentSize: scrollView.contentSize,
            boundsSize: scrollView.bounds.size
        )
        guard abs(scrollView.contentOffset.x - pinnedX) > 0.5 else { return }

        var offset = scrollView.contentOffset
        offset.x = pinnedX
        scrollView.setContentOffset(offset, animated: false)
    }

    /// The horizontal content offset the transcript should rest at, pinned to the
    /// layout-direction-aware *leading* edge so the vertical-only transcript never
    /// drifts sideways (#130) under either direction (#139/#259).
    ///
    /// LTR leading is the physical left, so it rests at `-left inset` exactly as
    /// before — this branch is byte-for-byte the prior behavior. RTL leading is
    /// the physical right, so it rests at the content's trailing edge
    /// (`contentSize.width + right inset - viewport width`), clamped to never fall
    /// below the LTR minimum. When the transcript has no horizontal overflow and
    /// no horizontal inset — its normal case — both branches resolve to `0`.
    nonisolated static func pinnedHorizontalOffsetX(
        isRightToLeft: Bool,
        adjustedInset: UIEdgeInsets,
        contentSize: CGSize,
        boundsSize: CGSize
    ) -> CGFloat {
        let leftEdge = -adjustedInset.left
        guard isRightToLeft else { return leftEdge }

        let rightEdge = contentSize.width + adjustedInset.right - boundsSize.width
        return max(leftEdge, rightEdge)
    }

    nonisolated private static func clampObservedHorizontalOffset(for guardView: ChatVerticalScrollAxisGuardView?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak guardView] in
                MainActor.assumeIsolated {
                    guardView?.clampHorizontalOffset()
                }
            }
            return
        }

        MainActor.assumeIsolated {
            guardView?.clampHorizontalOffset()
        }
    }
}

struct AssistantTypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isBreathing = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 16, height: 16)
            .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.16 : 0.86))
            .opacity(reduceMotion ? 0.75 : (isBreathing ? 0.95 : 0.55))
            .padding(.leading, 4)
            .padding(.vertical, 8)
            .accessibilityLabel("Hermex is preparing a response")
            .onAppear {
                updateBreathingAnimation()
            }
            .onChange(of: reduceMotion) {
                updateBreathingAnimation()
            }
    }

    private var dotColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.78)
    }

    private func updateBreathingAnimation() {
        guard let animation = ChatMotion.typingIndicator(reduceMotion: reduceMotion) else {
            isBreathing = false
            return
        }

        isBreathing = false
        withAnimation(animation) {
            isBreathing = true
        }
    }
}

struct BottomComposerMaterialFade: View {
    @Environment(\.colorScheme) private var colorScheme

    let composerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Rectangle()
                    .fill(.bar)

                if colorScheme == .dark {
                    Rectangle()
                        .fill(Color.black.opacity(0.58))
                }
            }
            .frame(height: max(96, composerHeight + 34))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.18), location: 0.18),
                        .init(color: .black.opacity(0.72), location: 0.46),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StreamRecoveryStatusView: View {
    let state: ActiveStreamRecoveryState

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle:
            return String(localized: "Stream active")
        case .checking:
            return String(localized: "Checking stream")
        case .reconnecting:
            return String(localized: "Reconnecting stream")
        }
    }
}

struct ChatTranscriptLoadingSkeletonView: View {
    private let rows = ChatTranscriptSkeletonRowConfiguration.loadingRows

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(rows) { row in
                    ChatTranscriptLoadingSkeletonRow(configuration: row)
                }

                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.top, 16)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }
}

private struct ChatTranscriptLoadingSkeletonRow: View {
    let configuration: ChatTranscriptSkeletonRowConfiguration

    var body: some View {
        switch configuration.role {
        case .assistant:
            assistantRow
        case .user:
            userRow
        }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(configuration.lines) { line in
                skeletonLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private var userRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(configuration.lines) { line in
                    skeletonLine(line)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemFill))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private func skeletonLine(_ line: ChatTranscriptSkeletonLine) -> some View {
        Text(verbatim: line.text)
            .font(.body)
            .lineLimit(1)
            .frame(maxWidth: line.maxWidth, alignment: configuration.role == .user ? .trailing : .leading)
    }
}

private struct ChatTranscriptSkeletonRowConfiguration: Identifiable {
    enum Role {
        case assistant
        case user
    }

    let id: String
    let role: Role
    let lines: [ChatTranscriptSkeletonLine]

    static let loadingRows: [ChatTranscriptSkeletonRowConfiguration] = [
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-intro",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a1", text: "Reviewing the latest project context and open tasks.", maxWidth: 320),
                ChatTranscriptSkeletonLine(id: "a2", text: "Checking recent sessions before continuing.", maxWidth: 260)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "user-question",
            role: .user,
            lines: [
                ChatTranscriptSkeletonLine(id: "u1", text: "Summarize the changes from the last run.", maxWidth: 280)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-response",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a3", text: "The current branch has focused UI polish in progress.", maxWidth: 330),
                ChatTranscriptSkeletonLine(id: "a4", text: "Validation is queued after the loading states are updated.", maxWidth: 300),
                ChatTranscriptSkeletonLine(id: "a5", text: "No server changes are required for this slice.", maxWidth: 240)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "user-followup",
            role: .user,
            lines: [
                ChatTranscriptSkeletonLine(id: "u2", text: "Keep the existing empty and error states.", maxWidth: 260)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-outro",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a6", text: "Using static placeholders that match the transcript rhythm.", maxWidth: 340),
                ChatTranscriptSkeletonLine(id: "a7", text: "Rows are noninteractive while data loads.", maxWidth: 245)
            ]
        )
    ]
}

private struct ChatTranscriptSkeletonLine: Identifiable {
    let id: String
    let text: String
    let maxWidth: CGFloat
}

struct ChatOfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)

            Text("Offline — viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

struct PinnedLocalNoticeStack: View {
    let notices: [String]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.green)

                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notices.joined(separator: "\n"))
    }
}
