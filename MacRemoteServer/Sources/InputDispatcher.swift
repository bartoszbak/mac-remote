import Foundation
import Network

/// Runs every `InputController` call on one serial queue, so pointer traffic never waits
/// behind main-thread UI work and the controller's state is confined to a single queue.
///
/// Also remembers which connections have passed `ServerManager`'s control gate, so the
/// network receive loop can hand high-rate pointer messages straight here without a hop
/// through the main queue. The set is only ever written from the main queue; reads happen
/// on the receive queue, hence the lock.
final class InputDispatcher {

    let controller: InputController
    private let queue = DispatchQueue(label: "com.macremote.input", qos: .userInteractive)
    private let lock = NSLock()
    private var authorized: Set<ObjectIdentifier> = []

    init(controller: InputController) {
        self.controller = controller
    }

    func perform(_ work: @escaping (InputController) -> Void) {
        queue.async { [controller] in work(controller) }
    }

    // MARK: Fast-path authorisation

    func setAuthorized(_ allowed: Bool, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        defer { lock.unlock() }
        if allowed { authorized.insert(id) } else { authorized.remove(id) }
    }

    func revokeAll() {
        lock.lock()
        authorized.removeAll()
        lock.unlock()
    }

    /// Handles `move` and `scroll` for an authorised connection without touching the main
    /// queue. Returns false when the message must take the normal, gated path instead.
    func handlePointerMessage(_ message: RemoteMessage, from connection: NWConnection) -> Bool {
        lock.lock()
        let allowed = authorized.contains(ObjectIdentifier(connection))
        lock.unlock()
        guard allowed else { return false }

        switch message {
        case .move(let dx, let dy):
            perform { $0.moveMouse(dx: dx, dy: dy) }
            return true
        case .scroll(let dx, let dy):
            perform { $0.scroll(dx: dx, dy: dy) }
            return true
        default:
            return false
        }
    }
}
