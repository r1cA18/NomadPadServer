import XCTest
@testable import NomadPadServer

final class ProtocolTests: XCTestCase {

    // MARK: - MouseMoveMessage Tests

    func testMouseMoveMessageEncodeDecodeRoundTrip() {
        let original = MouseMoveMessage(deltaX: 100, deltaY: -50)
        let encoded = original.encode()
        let decoded = MouseMoveMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.deltaX, 100)
        XCTAssertEqual(decoded?.deltaY, -50)
    }

    func testMouseMoveMessageEncodedFormat() {
        let message = MouseMoveMessage(deltaX: 256, deltaY: 512)
        let encoded = message.encode()

        XCTAssertEqual(encoded.count, 5)
        XCTAssertEqual(encoded[0], MessageType.mouseMove.rawValue)
    }

    func testMouseMoveMessageDecodeInvalidData() {
        // Too short
        let shortData = Data([0x01, 0x00])
        XCTAssertNil(MouseMoveMessage.decode(from: shortData))

        // Wrong type
        let wrongType = Data([0x02, 0x00, 0x64, 0xFF, 0xCE])
        XCTAssertNil(MouseMoveMessage.decode(from: wrongType))
    }

    // MARK: - ClickMessage Tests

    func testClickMessageEncodeDecodeRoundTrip() {
        let original = ClickMessage(button: .right, action: .click)
        let encoded = original.encode()
        let decoded = ClickMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.button, .right)
        XCTAssertEqual(decoded?.action, .click)
    }

    func testClickMessageAllButtons() {
        let buttons: [ClickButton] = [.left, .right, .middle]
        let actions: [ClickAction] = [.down, .up, .click]

        for button in buttons {
            for action in actions {
                let original = ClickMessage(button: button, action: action)
                let decoded = ClickMessage.decode(from: original.encode())
                XCTAssertEqual(decoded?.button, button)
                XCTAssertEqual(decoded?.action, action)
            }
        }
    }

    func testClickMessageDecodeInvalidData() {
        // Invalid button
        let invalidButton = Data([0x02, 0x05, 0x00])
        XCTAssertNil(ClickMessage.decode(from: invalidButton))

        // Invalid action
        let invalidAction = Data([0x02, 0x00, 0x05])
        XCTAssertNil(ClickMessage.decode(from: invalidAction))
    }

    // MARK: - ScrollMessage Tests

    func testScrollMessageEncodeDecodeRoundTrip() {
        let original = ScrollMessage(deltaX: -30, deltaY: 45)
        let encoded = original.encode()
        let decoded = ScrollMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.deltaX, -30)
        XCTAssertEqual(decoded?.deltaY, 45)
    }

    func testScrollMessageNegativeValues() {
        let original = ScrollMessage(deltaX: -32768, deltaY: 32767)
        let decoded = ScrollMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.deltaX, -32768)
        XCTAssertEqual(decoded?.deltaY, 32767)
    }

    // MARK: - KeyMessage Tests

    func testKeyMessageEncodeDecodeRoundTrip() {
        let original = KeyMessage(keyCode: 0x7B, modifiers: [.control], isDown: true)
        let encoded = original.encode()
        let decoded = KeyMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.keyCode, 0x7B)
        XCTAssertTrue(decoded?.modifiers.contains(.control) ?? false)
        XCTAssertEqual(decoded?.isDown, true)
    }

    func testKeyMessageMultipleModifiers() {
        let original = KeyMessage(keyCode: 0x00, modifiers: [.command, .shift, .option], isDown: false)
        let decoded = KeyMessage.decode(from: original.encode())

        XCTAssertTrue(decoded?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.shift) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.option) ?? false)
        XCTAssertFalse(decoded?.modifiers.contains(.control) ?? true)
    }

    func testKeyMessageNoModifiers() {
        let original = KeyMessage(keyCode: 0x31, modifiers: [], isDown: true)
        let decoded = KeyMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.modifiers.rawValue, 0)
    }

    // MARK: - TextMessage Tests

    func testTextMessageEncodeDecodeRoundTrip() {
        let original = TextMessage(text: "Hello")
        let encoded = original.encode()
        let decoded = TextMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.text, "Hello")
    }

    func testTextMessageUnicode() {
        let original = TextMessage(text: "こんにちは🎉")
        let decoded = TextMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.text, "こんにちは🎉")
    }

    func testTextMessageEmpty() {
        let original = TextMessage(text: "")
        let decoded = TextMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.text, "")
    }

    func testTextMessageSpecialCharacters() {
        let original = TextMessage(text: "\u{7F}")  // Backspace
        let decoded = TextMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.text, "\u{7F}")
    }

    // MARK: - MessageDecoder Tests

    func testMessageDecoderMouseMove() {
        let original = MouseMoveMessage(deltaX: 10, deltaY: 20)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is MouseMoveMessage)
    }

    func testMessageDecoderClick() {
        let original = ClickMessage(button: .left, action: .click)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is ClickMessage)
    }

    func testMessageDecoderScroll() {
        let original = ScrollMessage(deltaX: 5, deltaY: -5)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is ScrollMessage)
    }

    func testMessageDecoderKey() {
        let original = KeyMessage(keyCode: 0x00, modifiers: [], isDown: true)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is KeyMessage)
    }

    func testMessageDecoderText() {
        let original = TextMessage(text: "test")
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is TextMessage)
    }

    func testMessageDecoderInvalidType() {
        let invalidData = Data([0xFF, 0x00, 0x00])
        let decoded = MessageDecoder.decode(from: invalidData)

        XCTAssertNil(decoded)
    }

    func testMessageDecoderEmptyData() {
        let decoded = MessageDecoder.decode(from: Data())
        XCTAssertNil(decoded)
    }

    // MARK: - ModifierFlags Tests

    func testModifierFlagsOptionSet() {
        var flags: ModifierFlags = []
        XCTAssertEqual(flags.rawValue, 0)

        flags.insert(.command)
        XCTAssertTrue(flags.contains(.command))
        XCTAssertEqual(flags.rawValue, 1)

        flags.insert(.control)
        XCTAssertTrue(flags.contains(.command))
        XCTAssertTrue(flags.contains(.control))
    }

    func testModifierFlagsAllModifiers() {
        let allFlags: ModifierFlags = [.command, .option, .control, .shift]
        XCTAssertEqual(allFlags.rawValue, 0b1111)
    }
}
