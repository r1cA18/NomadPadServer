import XCTest
@testable import NomadPadServer

final class MouseControllerTests: XCTestCase {

    var controller: MouseController!

    override func setUp() {
        super.setUp()
        controller = MouseController()
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    // MARK: - Special Key Code Tests
    // These exercise MouseController.specialKeyCode directly rather than a copy.

    func testBackspaceCharacterRecognition() {
        // DEL character (0x7F) and BS character (0x08) map to Backspace (0x33)
        XCTAssertEqual(controller.specialKeyCode(for: "\u{7F}"), 0x33)
        XCTAssertEqual(controller.specialKeyCode(for: "\u{08}"), 0x33)
    }

    func testEnterCharacterRecognition() {
        XCTAssertEqual(controller.specialKeyCode(for: "\n"), 0x24)
        XCTAssertEqual(controller.specialKeyCode(for: "\r"), 0x24)
    }

    func testTabCharacterRecognition() {
        XCTAssertEqual(controller.specialKeyCode(for: "\t"), 0x30)
    }

    func testEscapeCharacterRecognition() {
        XCTAssertEqual(controller.specialKeyCode(for: "\u{1B}"), 0x35)
    }

    func testRegularCharacterNotSpecial() {
        let regularChars: [Character] = ["a", "Z", "1", " ", "!", "あ"]
        for char in regularChars {
            XCTAssertNil(controller.specialKeyCode(for: char), "Character '\(char)' should not be special")
        }
    }

    // MARK: - Arrow Key Code Tests

    func testArrowKeyCodes() {
        // These are the standard macOS virtual key codes for arrows
        XCTAssertEqual(MouseController.KeyCode.leftArrow, 0x7B)
        XCTAssertEqual(MouseController.KeyCode.rightArrow, 0x7C)
        XCTAssertEqual(MouseController.KeyCode.downArrow, 0x7D)
        XCTAssertEqual(MouseController.KeyCode.upArrow, 0x7E)
    }

    func testArrowKeyCodesAreInSet() {
        XCTAssertTrue(controller.arrowKeyCodes.contains(MouseController.KeyCode.leftArrow))
        XCTAssertTrue(controller.arrowKeyCodes.contains(MouseController.KeyCode.rightArrow))
        XCTAssertTrue(controller.arrowKeyCodes.contains(MouseController.KeyCode.downArrow))
        XCTAssertTrue(controller.arrowKeyCodes.contains(MouseController.KeyCode.upArrow))
    }

    // MARK: - Modifier Key Code Tests

    func testModifierKeyCodes() {
        XCTAssertEqual(MouseController.KeyCode.control, 0x3B)
        XCTAssertEqual(MouseController.KeyCode.shift, 0x38)
        XCTAssertEqual(MouseController.KeyCode.option, 0x3A)
        XCTAssertEqual(MouseController.KeyCode.command, 0x37)
    }
}

// MARK: - Session Release

final class MouseControllerSessionReleaseTests: XCTestCase {
    private struct Posted: Equatable {
        let type: CGEventType
        let keyCode: Int64
    }

    private final class Recorder {
        private let lock = NSLock()
        private var storage: [Posted] = []

        var events: [Posted] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func record(_ event: CGEvent) {
            lock.lock(); defer { lock.unlock() }
            storage.append(Posted(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode)))
        }
    }

    private var recorder: Recorder!
    private var controller: MouseController!

    override func setUp() {
        super.setUp()
        let recorder = Recorder()
        self.recorder = recorder
        controller = MouseController(postEvent: { event, _ in recorder.record(event) })
    }

    override func tearDown() {
        controller = nil
        recorder = nil
        super.tearDown()
    }

    private func count(_ type: CGEventType, keyCode: Int64? = nil) -> Int {
        recorder.events.filter { $0.type == type && (keyCode == nil || $0.keyCode == keyCode) }.count
    }

    func testReleaseLiftsHeldLeftButton() {
        controller.click(button: .left, action: .down)
        controller.waitForScheduledEvents()

        controller.releaseAllInput()
        controller.waitForScheduledEvents()

        XCTAssertEqual(recorder.events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }

    func testReleaseLiftsHeldKeyAndModifiers() {
        controller.sendKey(keyCode: 0x00, modifiers: [.command, .shift], isDown: true)
        controller.waitForScheduledEvents()
        let before = recorder.events.count

        controller.releaseAllInput()
        controller.waitForScheduledEvents()

        let released = recorder.events.dropFirst(before)
        XCTAssertEqual(released.first, Posted(type: .keyUp, keyCode: 0x00))
        // Then one release per held modifier, by virtual key code.
        XCTAssertEqual(
            Set(released.dropFirst().map(\.keyCode)),
            [Int64(MouseController.KeyCode.command), Int64(MouseController.KeyCode.shift)]
        )
        XCTAssertEqual(released.count, 3)
    }

    func testReleaseWithNothingHeldPostsNothing() {
        controller.click(button: .right, action: .click)
        controller.sendKey(keyCode: 0x00, modifiers: [], isDown: true)
        controller.sendKey(keyCode: 0x00, modifiers: [], isDown: false)
        controller.waitForScheduledEvents()
        let before = recorder.events.count

        controller.releaseAllInput()
        controller.waitForScheduledEvents()

        XCTAssertEqual(recorder.events.count, before)
    }

    func testReleaseDropsQueuedTextFromEndedSession() {
        let text = String(repeating: "a", count: 200)
        controller.typeText(text)
        controller.releaseAllInput()
        controller.waitForScheduledEvents()

        // 200 characters are spaced 5 ms apart, so most were still queued.
        XCTAssertLessThan(count(.keyDown), text.count)
    }

    func testReleaseDuringSynthesizedClickLeavesButtonsBalanced() {
        controller.click(button: .left, action: .click)
        controller.releaseAllInput()
        controller.waitForScheduledEvents()

        XCTAssertEqual(count(.leftMouseDown), count(.leftMouseUp))
    }

    func testInputAfterReleaseIsDelivered() {
        controller.releaseAllInput()
        controller.click(button: .left, action: .click)
        controller.waitForScheduledEvents()

        XCTAssertEqual(recorder.events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }
}
