import Foundation
import UIKit

/// Stable identity this phone presents to Macs. The ID is generated once per install.
enum DeviceIdentity {
    private static let key = "deviceIdentity.id"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static var name: String {
        UIDevice.current.name
    }
}
