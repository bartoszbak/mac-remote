import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac usable for a connected phone.
///
/// A network wake (Sleep Proxy or magic packet) is a *dark* wake: the display stays off
/// and the Mac goes back to sleep within about a minute. Declaring user activity turns it
/// into a full wake, and a no-idle-sleep assertion holds it there while a phone is connected.
final class PowerAssertions {

    static let keepAwakeName = "MacRemote: a device is connected" as CFString
    static let activityName = "MacRemote: device connected" as CFString

    private var keepAwakeID: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0

    private(set) var isKeepingAwake = false

    deinit {
        setKeepAwake(false)
        if activityID != 0 { IOPMAssertionRelease(activityID) }
    }

    /// Wakes the display and resets the idle timer, as if someone touched the trackpad.
    @discardableResult
    func declareUserActivity() -> Bool {
        let result = IOPMAssertionDeclareUserActivity(Self.activityName, kIOPMUserActiveLocal, &activityID)
        if result != kIOReturnSuccess {
            print("[Power] Declaring user activity failed: \(result)")
        }
        return result == kIOReturnSuccess
    }

    /// Prevents idle sleep while `keepAwake` is true. Closing a laptop lid still sleeps it.
    func setKeepAwake(_ keepAwake: Bool) {
        guard keepAwake != isKeepingAwake else { return }
        if keepAwake {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     Self.keepAwakeName, &keepAwakeID)
            isKeepingAwake = result == kIOReturnSuccess
            print("[Power] Keeping the Mac awake while a device is connected")
        } else {
            IOPMAssertionRelease(keepAwakeID)
            keepAwakeID = 0
            isKeepingAwake = false
            print("[Power] No devices connected; idle sleep allowed")
        }
    }
}
