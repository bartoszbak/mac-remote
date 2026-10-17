import SwiftUI
import UIKit

/// Raw multitouch surface. Feeds `TrackpadGestureEngine`, coalesces pointer deltas to one
/// message per display frame, runs scroll momentum after a fling, and plays haptics.
final class TrackpadTouchView: UIView {

    /// Receives actions ready to send to the Mac. Pointer moves arrive at most once per frame.
    var onAction: ((TrackpadAction) -> Void)?
    var hapticsEnabled = true

    var configuration: TrackpadGestureEngine.Configuration {
        get { engine.configuration }
        set {
            if engine.configuration != newValue {
                engine.configuration = newValue
            }
        }
    }

    private let engine = TrackpadGestureEngine()
    private var displayLink: CADisplayLink?
    private var lastTickTime: CFTimeInterval = 0
    private var pendingMove = CGVector.zero
    private var momentum: CGVector?

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Momentum decays by this factor every 1/60 s.
    private let momentumDecayPerFrame = 0.92
    /// Below this scaled speed (units per second) momentum stops.
    private let momentumStopSpeed = 30.0
    private let momentumStartSpeed = 40.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        engine.onAction = { [weak self] action in
            self?.handle(action)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            engine.reset()
            momentum = nil
            stopDisplayLink()
        }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        momentum = nil
        prepareHaptics()
        engine.touchesBegan(samples(touches), at: timestamp(touches))
        startDisplayLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        engine.touchesMoved(samples(touches), at: timestamp(touches))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        engine.touchesEnded(touches.map(\.hash), at: timestamp(touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        engine.touchesCancelled(touches.map(\.hash), at: timestamp(touches))
    }

    private func samples(_ touches: Set<UITouch>) -> [TrackpadTouchSample] {
        touches.map { TrackpadTouchSample(id: $0.hash, location: $0.location(in: self)) }
    }

    private func timestamp(_ touches: Set<UITouch>) -> TimeInterval {
        touches.first?.timestamp ?? CACurrentMediaTime()
    }

    // MARK: - Engine output

    private func handle(_ action: TrackpadAction) {
        switch action {
        case .move(let dx, let dy):
            pendingMove.dx += dx
            pendingMove.dy += dy

        case .scrollEnded(let vx, let vy):
            if hypot(vx, vy) >= momentumStartSpeed {
                momentum = CGVector(dx: vx, dy: vy)
                startDisplayLink()
            }

        case .click, .doubleClick:
            flushMoves()
            haptic(lightImpact)
            onAction?(action)

        case .rightClick:
            flushMoves()
            haptic(mediumImpact)
            onAction?(action)

        case .dragBegan, .dragEnded:
            flushMoves()
            haptic(rigidImpact)
            onAction?(action)

        case .zoom:
            if hapticsEnabled { selectionFeedback.selectionChanged() }
            onAction?(action)

        case .scroll:
            onAction?(action)
        }
    }

    private func flushMoves() {
        guard pendingMove != .zero else { return }
        let move = pendingMove
        pendingMove = .zero
        onAction?(.move(dx: move.dx, dy: move.dy))
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTickTime = CACurrentMediaTime()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(now - lastTickTime, 0)
        lastTickTime = now

        engine.tick(at: now)
        flushMoves()

        if var velocity = momentum {
            let decay = pow(momentumDecayPerFrame, dt * 60)
            velocity.dx *= decay
            velocity.dy *= decay
            if hypot(velocity.dx, velocity.dy) < momentumStopSpeed {
                momentum = nil
            } else {
                momentum = velocity
                onAction?(.scroll(dx: velocity.dx * dt, dy: velocity.dy * dt))
            }
        }

        if !engine.hasActiveTouches && momentum == nil {
            stopDisplayLink()
        }
    }

    // MARK: - Haptics

    private func prepareHaptics() {
        guard hapticsEnabled else { return }
        lightImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
    }

    private func haptic(_ generator: UIImpactFeedbackGenerator) {
        guard hapticsEnabled else { return }
        generator.impactOccurred()
    }
}

/// SwiftUI wrapper around `TrackpadTouchView`.
struct TrackpadSurface: UIViewRepresentable {
    var configuration: TrackpadGestureEngine.Configuration
    var hapticsEnabled: Bool
    var onAction: (TrackpadAction) -> Void

    func makeUIView(context: Context) -> TrackpadTouchView {
        let view = TrackpadTouchView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TrackpadTouchView) {
        view.configuration = configuration
        view.hapticsEnabled = hapticsEnabled
        view.onAction = onAction
    }
}

#Preview("Trackpad surface") {
    TrackpadSurface(configuration: .init(), hapticsEnabled: true) { action in
        print("[Preview] \(action)")
    }
    .background(Color(.systemGray6))
    .ignoresSafeArea()
}
