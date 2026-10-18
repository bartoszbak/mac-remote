import SwiftUI
import UIKit

/// Raw multitouch surface. Feeds `TrackpadGestureEngine`, coalesces pointer deltas to one
/// message per display frame, runs scroll momentum after a fling, plays haptics, and draws
/// a ripple where a click happens.
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
    /// Where each finger of the current gesture first touched down; clicks ripple from here.
    private var gestureStartPoints: [Int: CGPoint] = [:]

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
        if !engine.hasActiveTouches { gestureStartPoints.removeAll() }
        for touch in touches { gestureStartPoints[touch.hash] = touch.location(in: self) }
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

        case .click:
            flushMoves()
            haptic(lightImpact)
            showRipple(.click)
            onAction?(action)

        case .doubleClick:
            flushMoves()
            haptic(lightImpact)
            showRipple(.doubleClick)
            onAction?(action)

        case .rightClick:
            flushMoves()
            haptic(mediumImpact)
            showRipple(.rightClick)
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

    // MARK: - Click ripple

    private enum RippleKind { case click, doubleClick, rightClick }

    /// Middle of the fingers that started the gesture: one finger for a click, two for a
    /// right click.
    private var gestureCentroid: CGPoint? {
        guard !gestureStartPoints.isEmpty else { return nil }
        let points = Array(gestureStartPoints.values)
        let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private func showRipple(_ kind: RippleKind) {
        guard let center = gestureCentroid else { return }
        switch kind {
        case .click:
            addRipple(at: center, radius: 36)
        case .doubleClick:
            addRipple(at: center, radius: 36)
            addRipple(at: center, radius: 36, delay: 0.12)
        case .rightClick:
            addRipple(at: center, radius: 54, lineWidth: 2.5)
            addRipple(at: center, radius: 32, delay: 0.08)
        }
    }

    /// One expanding, fading ring with a soft fill. Reduce Motion gets a plain fade.
    private func addRipple(at point: CGPoint, radius: CGFloat, lineWidth: CGFloat = 2, delay: CFTimeInterval = 0) {
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
        ring.position = point
        ring.fillColor = UIColor.white.withAlphaComponent(0.10).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = lineWidth
        ring.opacity = 0
        layer.addSublayer(ring)

        let duration: CFTimeInterval = 0.55
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.12, 1]

        let group = CAAnimationGroup()
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        if UIAccessibility.isReduceMotionEnabled {
            group.animations = [fade]
        } else {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 1.0
            let thin = CABasicAnimation(keyPath: "lineWidth")
            thin.fromValue = lineWidth * 2
            thin.toValue = lineWidth * 0.5
            group.animations = [grow, fade, thin]
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
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
