import XCTest
@testable import MacRemoteServer

final class MessageFrameTests: XCTestCase {

    func testLengthPrefixIsBigEndianAndMatchesPayload() throws {
        let frame = try MessageFrame.encode(RemoteMessage.ping)
        XCTAssertGreaterThan(frame.count, 4)
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), frame.count - 4)
    }

    func testRemoteMessageRoundTrip() throws {
        let messages: [RemoteMessage] = [
            .move(dx: 1.5, dy: -2.25),
            .click(button: .right),
            .scroll(dx: 0, dy: 12),
            .key(code: 36, down: true, flags: 0x100000),
            .media(action: .playPause),
            .system(action: .lock),
            .startScreenStream(quality: .high),
            .unlock(signature: Data([1, 2, 3]))
        ]
        for message in messages {
            let frame = try MessageFrame.encode(message)
            let decoded = try MessageFrame.decode(frame.dropFirst(4), as: RemoteMessage.self)
            XCTAssertEqual(try json(of: decoded), try json(of: message))
        }
    }

    func testServerMessageRoundTrip() throws {
        let frame = ScreenFrame(data: Data([0, 0, 0, 1, 0x65]), width: 1280, height: 720, timestamp: 42, isKeyFrame: true)
        let messages: [ServerMessage] = [
            .connected(screenWidth: 1920, screenHeight: 1080, unlockChallenge: Data([9]), unlockAvailable: true),
            .pong,
            .error(message: "boom"),
            .appList(apps: [AppInfo(name: "Safari", bundleId: "com.apple.Safari", icon: nil)]),
            .screenFrame(frame: frame),
            .unlockResult(success: false, message: "no")
        ]
        for message in messages {
            let encoded = try MessageFrame.encode(message)
            let decoded = try MessageFrame.decode(encoded.dropFirst(4), as: ServerMessage.self)
            XCTAssertEqual(try json(of: decoded), try json(of: message))
        }
    }

    /// JSON key order is not stable, so compare parsed objects rather than bytes.
    private func json<T: Encodable>(of value: T) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testGarbageFailsToDecode() {
        XCTAssertThrowsError(try MessageFrame.decode(Data("not json".utf8), as: RemoteMessage.self))
    }
}
