import XCTest
@testable import MacRemoteServer

final class InputControllerTests: XCTestCase {

    // A primary 1920x1080 display with a second 1440x900 display to its right,
    // whose top edge is 100 pt lower, in global display coordinates.
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondary = CGRect(x: 1920, y: 100, width: 1440, height: 900)
    private var displays: [CGRect] { [primary, secondary] }

    func testPointInsideADisplayIsUnchanged() {
        let point = CGPoint(x: 500, y: 300)
        XCTAssertEqual(InputController.clamp(point, to: displays), point)
    }

    func testPointInsideSecondaryDisplayIsUnchanged() {
        let point = CGPoint(x: 2500, y: 600)
        XCTAssertEqual(InputController.clamp(point, to: displays), point)
    }

    func testPointLeftOfEverythingClampsToPrimaryEdge() {
        let clamped = InputController.clamp(CGPoint(x: -50, y: 300), to: displays)
        XCTAssertEqual(clamped, CGPoint(x: 0, y: 300))
    }

    func testPointBelowPrimaryClampsToPrimaryBottom() {
        let clamped = InputController.clamp(CGPoint(x: 500, y: 2000), to: displays)
        XCTAssertEqual(clamped, CGPoint(x: 500, y: primary.maxY - 1))
    }

    func testPointRightOfSecondaryClampsToSecondaryEdge() {
        let clamped = InputController.clamp(CGPoint(x: 4000, y: 600), to: displays)
        XCTAssertEqual(clamped, CGPoint(x: secondary.maxX - 1, y: 600))
    }

    func testPointInGapAboveSecondaryClampsToNearestDisplay() {
        // x is over the secondary display but y is above its top edge, in the
        // area that belongs to no display. Nearest point is the secondary's top edge.
        let clamped = InputController.clamp(CGPoint(x: 2500, y: 50), to: displays)
        XCTAssertEqual(clamped, CGPoint(x: 2500, y: secondary.minY))
    }

    func testCursorCanCrossFromPrimaryToSecondary() {
        // Moving right from the primary's right edge lands on the secondary, not clamped back.
        let clamped = InputController.clamp(CGPoint(x: 1925, y: 500), to: displays)
        XCTAssertEqual(clamped, CGPoint(x: 1925, y: 500))
    }

    func testNoDisplaysLeavesPointUnchanged() {
        let point = CGPoint(x: -100, y: -100)
        XCTAssertEqual(InputController.clamp(point, to: []), point)
    }

    func testSequenceOfDeltasNeverLeavesDisplaysAndNeverJumps() {
        var position = CGPoint(x: 1900, y: 500)
        let deltas = [CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: -600), CGPoint(x: 2000, y: 0), CGPoint(x: 0, y: 5000)]
        for delta in deltas {
            let next = InputController.clamp(CGPoint(x: position.x + delta.x, y: position.y + delta.y), to: displays)
            XCTAssertTrue(displays.contains { $0.contains(next) || $0.insetBy(dx: -1, dy: -1).contains(next) },
                          "\(next) is outside every display")
            // Clamping may snap sideways onto the nearest display, but never
            // further than the requested movement itself.
            XCTAssertLessThanOrEqual(hypot(next.x - position.x, next.y - position.y),
                                     hypot(delta.x, delta.y) + 1)
            position = next
        }
    }

    func testActiveDisplayBoundsReturnsAtLeastOneDisplay() {
        XCTAssertFalse(InputController.activeDisplayBounds().isEmpty)
    }
}
