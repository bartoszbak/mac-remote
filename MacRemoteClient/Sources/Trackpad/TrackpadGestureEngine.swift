import CoreGraphics
import Foundation

/// What the trackpad wants the Mac to do. Produced by `TrackpadGestureEngine`.
enum TrackpadAction: Equatable {
    case move(dx: Double, dy: Double)
    case click
    case doubleClick
    case rightClick
    case scroll(dx: Double, dy: Double)
    /// Two-finger scroll lifted with residual velocity, in scaled points per second.
    case scrollEnded(velocityX: Double, velocityY: Double)
    case dragBegan
    case dragEnded
    /// Positive steps zoom in, negative steps zoom out.
    case zoom(steps: Int)
}

/// One finger's position at a moment in time. `id` must be stable for the life of the touch.
struct TrackpadTouchSample {
    let id: Int
    let location: CGPoint
}

/// Turns raw multitouch samples into trackpad actions.
///
/// Pure logic with no UIKit dependency so it can be driven from tests. Gestures:
/// - one finger: move; quick tap = click; quick second tap = double-click
/// - tap, then press-and-hold or move = drag
/// - two fingers: drag = scroll, quick tap = right-click, pinch = zoom
/// - three fingers: drag with the primary button held
final class TrackpadGestureEngine {

    struct Configuration: Equatable {
        /// User multiplier on pointer movement. 1.0 is the default speed.
        var sensitivity: Double = 1.0
        var tapToClick = true
        /// A quick two-finger tap sends a right click.
        var twoFingerRightClick = true
        var naturalScrolling = true

        var tapMaxDuration: TimeInterval = 0.25
        var tapMaxMovement: CGFloat = 12
        var doubleTapInterval: TimeInterval = 0.3
        var doubleTapMaxDistance: CGFloat = 48
        /// Points of two-finger travel before the gesture is locked as a scroll or a pinch.
        var twoFingerLockDistance: CGFloat = 14
        /// Scroll units sent per point of finger travel.
        var scrollScale: Double = 0.2
        /// Change in finger distance that produces one zoom step.
        var pinchStepDistance: CGFloat = 50
    }

    var configuration = Configuration()
    var onAction: ((TrackpadAction) -> Void)?

    var hasActiveTouches: Bool { !touches.isEmpty }
    var isDragging: Bool { phase == .dragging || phase == .threeFingerDrag }

    private struct TouchState {
        let start: CGPoint
        let startTime: TimeInterval
        var location: CGPoint
        var time: TimeInterval
        var travelled: CGFloat = 0
    }

    private enum Phase {
        case idle
        case pointer
        case dragging
        /// Two fingers down, not yet known whether this is a tap, a scroll or a pinch.
        case twoFinger
        case scrolling
        case pinching
        case threeFingerDrag
        /// Gesture is over but fingers are still down; ignore them until all lift.
        case waitForLift
    }

    private var touches: [Int: TouchState] = [:]
    /// Touch ids in the order they landed. The first one is the primary finger.
    private var order: [Int] = []
    private var phase: Phase = .idle
    private var gestureStart: TimeInterval = 0
    private var pointerMoved = false
    /// The current touch landed right after a tap, so it may become a double-click or a drag.
    private var secondTap = false
    private var lastTapTime: TimeInterval = -.infinity
    private var lastTapLocation: CGPoint = .zero
    private var pendingRightClick = false

    private var lastCentroid: CGPoint = .zero
    private var lastCentroidTime: TimeInterval = 0
    private var lastPinchDistance: CGFloat = 0
    private var centroidTravel: CGFloat = 0
    private var pinchTravel: CGFloat = 0
    private var pinchAccumulator: CGFloat = 0
    private var scrollVelocity = CGVector.zero

    // MARK: - Touch input

    func touchesBegan(_ samples: [TrackpadTouchSample], at time: TimeInterval) {
        for sample in samples where touches[sample.id] == nil {
            touches[sample.id] = TouchState(start: sample.location,
                                            startTime: time,
                                            location: sample.location,
                                            time: time)
            order.append(sample.id)
        }

        switch touches.count {
        case 1:
            guard let location = samples.first?.location else { return }
            gestureStart = time
            pointerMoved = false
            pendingRightClick = false
            secondTap = configuration.tapToClick
                && time - lastTapTime < configuration.doubleTapInterval
                && distance(location, lastTapLocation) < configuration.doubleTapMaxDistance
            phase = .pointer

        case 2:
            if phase == .pointer {
                phase = .twoFinger
                resetTwoFingerTracking(at: time)
            }

        case 3:
            switch phase {
            case .pointer, .twoFinger, .scrolling, .pinching:
                phase = .threeFingerDrag
                lastCentroid = centroid(ofFirst: 3)
                lastCentroidTime = time
                emit(.dragBegan)
            default:
                break
            }

        default:
            if phase == .threeFingerDrag {
                emit(.dragEnded)
            }
            if phase != .dragging {
                phase = .waitForLift
            }
        }
    }

    func touchesMoved(_ samples: [TrackpadTouchSample], at time: TimeInterval) {
        let primaryID = order.first
        let previousPrimary = primaryID.flatMap { touches[$0] }
        let movedPrimary = samples.contains { $0.id == primaryID }

        for sample in samples {
            guard var state = touches[sample.id] else { continue }
            state.travelled += distance(state.location, sample.location)
            state.location = sample.location
            state.time = time
            touches[sample.id] = state
        }

        switch phase {
        case .pointer, .dragging:
            guard movedPrimary,
                  let id = primaryID,
                  let previous = previousPrimary,
                  let current = touches[id] else { return }

            let dx = current.location.x - previous.location.x
            let dy = current.location.y - previous.location.y
            if current.travelled > configuration.tapMaxMovement {
                if phase == .pointer && secondTap && !pointerMoved {
                    phase = .dragging
                    emit(.dragBegan)
                }
                pointerMoved = true
            }
            let gain = accelerationGain(distance: hypot(dx, dy), dt: current.time - previous.time)
            emit(.move(dx: Double(dx) * gain, dy: Double(dy) * gain))

        case .twoFinger, .scrolling, .pinching:
            guard touches.count >= 2 else { return }
            let newCentroid = centroid(ofFirst: 2)
            let newDistance = pinchDistance()
            let dx = newCentroid.x - lastCentroid.x
            let dy = newCentroid.y - lastCentroid.y
            let dd = newDistance - lastPinchDistance
            let dt = time - lastCentroidTime
            lastCentroid = newCentroid
            lastPinchDistance = newDistance
            lastCentroidTime = time
            centroidTravel += hypot(dx, dy)
            pinchTravel += abs(dd)

            if phase == .twoFinger {
                guard max(centroidTravel, pinchTravel) >= configuration.twoFingerLockDistance else { return }
                phase = pinchTravel > centroidTravel * 1.5 ? .pinching : .scrolling
            }

            if phase == .scrolling {
                let sign = configuration.naturalScrolling ? -1.0 : 1.0
                let sx = Double(dx) * configuration.scrollScale * sign
                let sy = Double(dy) * configuration.scrollScale * sign
                emit(.scroll(dx: sx, dy: sy))
                if dt > 0 {
                    // Light smoothing so a jittery last sample does not define the fling.
                    scrollVelocity = CGVector(dx: 0.6 * (sx / dt) + 0.4 * scrollVelocity.dx,
                                              dy: 0.6 * (sy / dt) + 0.4 * scrollVelocity.dy)
                }
            } else {
                pinchAccumulator += dd
                let steps = Int((pinchAccumulator / configuration.pinchStepDistance).rounded(.towardZero))
                if steps != 0 {
                    pinchAccumulator -= CGFloat(steps) * configuration.pinchStepDistance
                    emit(.zoom(steps: steps))
                }
            }

        case .threeFingerDrag:
            guard touches.count >= 3 else { return }
            let newCentroid = centroid(ofFirst: 3)
            let dx = newCentroid.x - lastCentroid.x
            let dy = newCentroid.y - lastCentroid.y
            let dt = time - lastCentroidTime
            lastCentroid = newCentroid
            lastCentroidTime = time
            let gain = accelerationGain(distance: hypot(dx, dy), dt: dt)
            emit(.move(dx: Double(dx) * gain, dy: Double(dy) * gain))

        case .idle, .waitForLift:
            break
        }
    }

    func touchesEnded(_ ids: [Int], at time: TimeInterval) {
        finish(ids, at: time, cancelled: false)
    }

    func touchesCancelled(_ ids: [Int], at time: TimeInterval) {
        finish(ids, at: time, cancelled: true)
    }

    /// Call once per display frame. Promotes a held second tap into a drag.
    func tick(at time: TimeInterval) {
        if phase == .pointer, secondTap, !pointerMoved,
           time - gestureStart > configuration.tapMaxDuration {
            phase = .dragging
            emit(.dragBegan)
        }
    }

    /// Drops all state and releases any held button.
    func reset() {
        if isDragging {
            emit(.dragEnded)
        }
        touches.removeAll()
        order.removeAll()
        phase = .idle
        secondTap = false
        pendingRightClick = false
    }

    // MARK: - Gesture completion

    private func finish(_ ids: [Int], at time: TimeInterval, cancelled: Bool) {
        let liftedPrimary = ids.contains { $0 == order.first }
        let primaryStart = order.first.flatMap { touches[$0]?.start }
        for id in ids {
            touches[id] = nil
            order.removeAll { $0 == id }
        }
        let duration = time - gestureStart
        let quick = duration <= configuration.tapMaxDuration
        let quickTwoFinger = duration <= configuration.tapMaxDuration * 1.4

        if touches.isEmpty {
            switch phase {
            case .pointer:
                if !cancelled, configuration.tapToClick, !pointerMoved, quick {
                    if secondTap {
                        emit(.doubleClick)
                        lastTapTime = -.infinity
                    } else {
                        emit(.click)
                        lastTapTime = time
                        lastTapLocation = primaryStart ?? .zero
                    }
                }
            case .dragging, .threeFingerDrag:
                emit(.dragEnded)
            case .twoFinger:
                if !cancelled, quickTwoFinger, configuration.twoFingerRightClick {
                    emit(.rightClick)
                }
            case .scrolling:
                if !cancelled {
                    emit(.scrollEnded(velocityX: scrollVelocity.dx, velocityY: scrollVelocity.dy))
                }
            case .waitForLift:
                if pendingRightClick, !cancelled, quickTwoFinger, configuration.twoFingerRightClick {
                    emit(.rightClick)
                }
            case .pinching, .idle:
                break
            }
            phase = .idle
            secondTap = false
            pendingRightClick = false
            return
        }

        // Some fingers remain down.
        switch phase {
        case .dragging:
            if liftedPrimary {
                emit(.dragEnded)
                phase = .waitForLift
            }
        case .twoFinger:
            pendingRightClick = !cancelled && quickTwoFinger
            phase = .waitForLift
        case .scrolling:
            if !cancelled {
                emit(.scrollEnded(velocityX: scrollVelocity.dx, velocityY: scrollVelocity.dy))
            }
            phase = .waitForLift
        case .pinching:
            phase = .waitForLift
        case .threeFingerDrag:
            if touches.count < 3 {
                emit(.dragEnded)
                phase = .waitForLift
            }
        case .pointer, .idle, .waitForLift:
            break
        }
    }

    // MARK: - Helpers

    private func resetTwoFingerTracking(at time: TimeInterval) {
        lastCentroid = centroid(ofFirst: 2)
        lastCentroidTime = time
        lastPinchDistance = pinchDistance()
        centroidTravel = 0
        pinchTravel = 0
        pinchAccumulator = 0
        scrollVelocity = .zero
    }

    /// Slow movements map close to 1:1 for precision; fast flicks travel further.
    private func accelerationGain(distance: CGFloat, dt: TimeInterval) -> Double {
        let speed = dt > 0 ? Double(distance) / dt : 0 // points per second
        let t = min(max(speed / 1500, 0), 1)
        let curve = t * t * (3 - 2 * t) // smoothstep
        return configuration.sensitivity * 1.2 * (1 + 1.5 * curve)
    }

    private func centroid(ofFirst count: Int) -> CGPoint {
        let points = order.prefix(count).compactMap { touches[$0]?.location }
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n,
                       y: points.map(\.y).reduce(0, +) / n)
    }

    private func pinchDistance() -> CGFloat {
        guard order.count >= 2,
              let a = touches[order[0]],
              let b = touches[order[1]] else { return 0 }
        return distance(a.location, b.location)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func emit(_ action: TrackpadAction) {
        onAction?(action)
    }
}
