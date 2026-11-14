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

    // MARK: - ModifiedScrollMessage Tests

    func testModifiedScrollMessageEncodeDecodeRoundTrip() {
        let original = ModifiedScrollMessage(deltaX: -8, deltaY: 40, modifiers: [.command, .shift])
        let decoded = ModifiedScrollMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.deltaX, -8)
        XCTAssertEqual(decoded?.deltaY, 40)
        XCTAssertTrue(decoded?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.shift) ?? false)
    }

    // MARK: - VolumeMessage Tests

    func testVolumeMessageEncodeDecodeRoundTrip() {
        let original = VolumeMessage(delta: 42)
        let encoded = original.encode()
        let decoded = VolumeMessage.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.delta, 42)
    }

    func testVolumeMessageNegativeValue() {
        let original = VolumeMessage(delta: -15)
        let decoded = VolumeMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.delta, -15)
    }

    // MARK: - v3.0 System Integration Messages

    func testVolumeSetMessageEncodeDecodeRoundTrip() {
        let original = VolumeSetMessage(value: 0.42)
        let encoded = original.encode()
        let decoded = VolumeSetMessage.decode(from: encoded)

        XCTAssertEqual(encoded.count, 5)
        XCTAssertEqual(encoded[0], MessageType.volumeSet.rawValue)
        XCTAssertEqual(decoded?.value, 0.42)
    }

    func testVolumeSetMessageDecodeRejectsTruncatedPayload() {
        XCTAssertNil(VolumeSetMessage.decode(from: Data([MessageType.volumeSet.rawValue, 0x00, 0x00])))
        XCTAssertNil(VolumeSetMessage.decode(from: Data([MessageType.click.rawValue, 0x00, 0x00, 0x00, 0x00])))
    }

    func testBrightnessSetMessageEncodeDecodeRoundTrip() {
        let original = BrightnessSetMessage(value: 0.75)
        let decoded = BrightnessSetMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.value, 0.75)
    }

    func testMuteToggleMessageEncodeDecodeRoundTrip() {
        let encoded = MuteToggleMessage().encode()
        XCTAssertEqual(encoded, Data([MessageType.muteToggle.rawValue]))
        XCTAssertNotNil(MuteToggleMessage.decode(from: encoded))
    }

    func testMuteToggleMessageDecodeRejectsWrongType() {
        XCTAssertNil(MuteToggleMessage.decode(from: Data([MessageType.sleepCommand.rawValue])))
        XCTAssertNil(MuteToggleMessage.decode(from: Data()))
    }

    func testMediaCommandMessageEncodeDecodeRoundTrip() {
        for command in [MediaCommand.playPause, .next, .previous] {
            let decoded = MediaCommandMessage.decode(from: MediaCommandMessage(command: command).encode())
            XCTAssertEqual(decoded?.command, command)
        }
    }

    func testMediaCommandMessageDecodeRejectsUnknownCommand() {
        XCTAssertNil(MediaCommandMessage.decode(from: Data([MessageType.mediaCommand.rawValue, 0x63])))
        XCTAssertNil(MediaCommandMessage.decode(from: Data([MessageType.mediaCommand.rawValue])))
    }

    func testSleepCommandMessageEncodeDecodeRoundTrip() {
        let encoded = SleepCommandMessage().encode()
        XCTAssertEqual(encoded, Data([MessageType.sleepCommand.rawValue]))
        XCTAssertNotNil(SleepCommandMessage.decode(from: encoded))
    }

    func testVolumeStatusMessageEncodeDecodeRoundTrip() {
        let muted = VolumeStatusMessage.decode(from: VolumeStatusMessage(value: 0.3, muted: true).encode())
        XCTAssertEqual(muted?.value, 0.3)
        XCTAssertEqual(muted?.muted, true)

        let unmuted = VolumeStatusMessage.decode(from: VolumeStatusMessage(value: 0.9, muted: false).encode())
        XCTAssertEqual(unmuted?.value, 0.9)
        XCTAssertEqual(unmuted?.muted, false)
    }

    func testVolumeStatusMessageDecodeRejectsTruncatedPayload() {
        XCTAssertNil(VolumeStatusMessage.decode(from: Data([MessageType.volumeStatus.rawValue, 0x00, 0x00, 0x00, 0x00])))
    }

    func testBrightnessStatusMessageEncodeDecodeRoundTrip() {
        let decoded = BrightnessStatusMessage.decode(from: BrightnessStatusMessage(value: 0.6).encode())
        XCTAssertEqual(decoded?.value, 0.6)
    }

    func testMessageDecoderDispatchesV3Messages() {
        XCTAssertTrue(MessageDecoder.decode(from: VolumeSetMessage(value: 0.5).encode()) is VolumeSetMessage)
        XCTAssertTrue(MessageDecoder.decode(from: BrightnessSetMessage(value: 0.5).encode()) is BrightnessSetMessage)
        XCTAssertTrue(MessageDecoder.decode(from: MuteToggleMessage().encode()) is MuteToggleMessage)
        XCTAssertTrue(MessageDecoder.decode(from: MediaCommandMessage(command: .next).encode()) is MediaCommandMessage)
        XCTAssertTrue(MessageDecoder.decode(from: SleepCommandMessage().encode()) is SleepCommandMessage)
        XCTAssertTrue(MessageDecoder.decode(from: VolumeStatusMessage(value: 0.5, muted: false).encode()) is VolumeStatusMessage)
        XCTAssertTrue(MessageDecoder.decode(from: BrightnessStatusMessage(value: 0.5).encode()) is BrightnessStatusMessage)
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

    func testTextMessageTruncatesUnicodeAtCharacterBoundary() {
        let character = "👨‍👩‍👧‍👦"
        let text = String(repeating: character, count: 20)
        let decoded = TextMessage.decode(from: TextMessage(text: text).encode())

        XCTAssertNotNil(decoded)
        XCTAssertLessThanOrEqual(decoded?.text.utf8.count ?? .max, TextMessage.maxLength)
        XCTAssertEqual(decoded?.text, String(text.prefix(decoded?.text.count ?? 0)))
    }

    func testTextMessageChunkedPreservesLongText() {
        let samples = [
            String(repeating: "a", count: 300),
            String(repeating: "日本語", count: 100),
            String(repeating: "\u{1F600}", count: 100),
            String(repeating: "👨‍👩‍👧‍👦e\u{301}\n", count: 40)
        ]

        for text in samples {
            let messages = TextMessage.chunked(text)
            XCTAssertGreaterThan(messages.count, 1)
            var restored = ""
            for message in messages {
                let encoded = message.encode()
                XCTAssertLessThanOrEqual(encoded.count - 2, TextMessage.maxLength)
                restored += TextMessage.decode(from: encoded)?.text ?? "<decode failed>"
            }
            XCTAssertEqual(restored, text)
        }
    }

    func testTextMessageChunkedKeepsShortTextInOneMessage() {
        XCTAssertEqual(TextMessage.chunked("Hello").map(\.text), ["Hello"])
        XCTAssertTrue(TextMessage.chunked("").isEmpty)
    }

    func testTextMessageChunkedSplitsOversizedCharacterByScalar() {
        let text = "a" + String(repeating: "\u{301}", count: 200)
        let messages = TextMessage.chunked(text)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.text).joined().unicodeScalars.count, text.unicodeScalars.count)
        XCTAssertTrue(messages.allSatisfy { $0.text.utf8.count <= TextMessage.maxLength })
    }

    // MARK: - ConnectionRequestMessage Tests

    func testConnectionRequestMessageEncodeDecodeRoundTrip() {
        let original = ConnectionRequestMessage(
            deviceName: "iPhone",
            deviceId: "12345678-1234-1234-1234-1234567890AB",
            deviceToken: String(repeating: "b", count: ConnectionRequestMessage.deviceTokenLength)
        )
        let decoded = ConnectionRequestMessage.decode(from: original.encode())

        XCTAssertEqual(decoded?.deviceName, original.deviceName)
        XCTAssertEqual(decoded?.deviceId, original.deviceId)
        XCTAssertEqual(decoded?.deviceToken, original.deviceToken)
    }

    func testConnectionRequestMessageTruncatesUnicodeNameAtCharacterBoundary() {
        let deviceName = String(repeating: "家族のiPhone👨‍👩‍👧‍👦", count: 10)
        let message = ConnectionRequestMessage(
            deviceName: deviceName,
            deviceId: "12345678-1234-1234-1234-1234567890AB",
            deviceToken: String(repeating: "b", count: ConnectionRequestMessage.deviceTokenLength)
        )

        let decoded = ConnectionRequestMessage.decode(from: message.encode())

        XCTAssertNotNil(decoded)
        XCTAssertTrue(deviceName.hasPrefix(decoded?.deviceName ?? ""))
        XCTAssertLessThanOrEqual(decoded?.deviceName.utf8.count ?? .max, ConnectionRequestMessage.maxNameLength)
    }

    func testConnectionRequestMessageDecodesLegacyPayloadWithoutDeviceToken() {
        var legacyPayload = ConnectionRequestMessage(
            deviceName: "Legacy iPhone",
            deviceId: "12345678-1234-1234-1234-1234567890AB",
            deviceToken: String(repeating: "a", count: ConnectionRequestMessage.deviceTokenLength)
        ).encode()
        legacyPayload.removeLast(ConnectionRequestMessage.deviceTokenLength)

        let decoded = ConnectionRequestMessage.decode(from: legacyPayload)

        XCTAssertEqual(decoded?.deviceName, "Legacy iPhone")
        XCTAssertEqual(decoded?.deviceId, "12345678-1234-1234-1234-1234567890AB")
        XCTAssertEqual(decoded?.deviceToken, "")
    }

    func testConnectionAdmissionDecisionAllowsFirstController() {
        let request = ControllerIdentity(deviceId: "device-1", deviceToken: "token-1")
        XCTAssertEqual(ConnectionAdmissionDecision.resolve(request: request, active: nil), .approveNew)
    }

    func testConnectionAdmissionDecisionReplacesSameController() {
        let request = ControllerIdentity(deviceId: "device-1", deviceToken: "token-1")
        let active = ControllerIdentity(deviceId: "device-1", deviceToken: "token-1")
        XCTAssertEqual(ConnectionAdmissionDecision.resolve(request: request, active: active), .replaceExisting)
    }

    func testConnectionAdmissionDecisionDeniesDifferentController() {
        let request = ControllerIdentity(deviceId: "device-2", deviceToken: "token-2")
        let active = ControllerIdentity(deviceId: "device-1", deviceToken: "token-1")
        XCTAssertEqual(ConnectionAdmissionDecision.resolve(request: request, active: active), .denyNew)
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

    func testMessageDecoderModifiedScroll() {
        let original = ModifiedScrollMessage(deltaX: 0, deltaY: 40, modifiers: .command)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is ModifiedScrollMessage)
    }

    func testMessageDecoderVolume() {
        let original = VolumeMessage(delta: 3)
        let decoded = MessageDecoder.decode(from: original.encode())

        XCTAssertTrue(decoded is VolumeMessage)
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
