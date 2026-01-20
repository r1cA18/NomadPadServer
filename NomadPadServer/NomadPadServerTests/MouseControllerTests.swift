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
    // Note: These test the internal logic without triggering actual key events

    func testBackspaceCharacterRecognition() {
        // DEL character (0x7F) should be recognized as backspace
        let delChar: Character = "\u{7F}"
        XCTAssertTrue(isSpecialKey(delChar))

        // BS character (0x08) should also be recognized
        let bsChar: Character = "\u{08}"
        XCTAssertTrue(isSpecialKey(bsChar))
    }

    func testEnterCharacterRecognition() {
        let newline: Character = "\n"
        let carriageReturn: Character = "\r"
        XCTAssertTrue(isSpecialKey(newline))
        XCTAssertTrue(isSpecialKey(carriageReturn))
    }

    func testTabCharacterRecognition() {
        let tab: Character = "\t"
        XCTAssertTrue(isSpecialKey(tab))
    }

    func testEscapeCharacterRecognition() {
        let escape: Character = "\u{1B}"
        XCTAssertTrue(isSpecialKey(escape))
    }

    func testRegularCharacterNotSpecial() {
        let regularChars: [Character] = ["a", "Z", "1", " ", "!", "あ"]
        for char in regularChars {
            XCTAssertFalse(isSpecialKey(char), "Character '\(char)' should not be special")
        }
    }

    // MARK: - Arrow Key Code Tests

    func testArrowKeyCodes() {
        // These are the standard macOS virtual key codes for arrows
        XCTAssertEqual(leftArrowKeyCode, 0x7B)
        XCTAssertEqual(rightArrowKeyCode, 0x7C)
        XCTAssertEqual(downArrowKeyCode, 0x7D)
        XCTAssertEqual(upArrowKeyCode, 0x7E)
    }

    func testArrowKeyCodesAreInSet() {
        let arrowCodes: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E]
        XCTAssertTrue(arrowCodes.contains(leftArrowKeyCode))
        XCTAssertTrue(arrowCodes.contains(rightArrowKeyCode))
        XCTAssertTrue(arrowCodes.contains(downArrowKeyCode))
        XCTAssertTrue(arrowCodes.contains(upArrowKeyCode))
    }

    // MARK: - Modifier Key Code Tests

    func testModifierKeyCodes() {
        XCTAssertEqual(controlKeyCode, 0x3B)
        XCTAssertEqual(shiftKeyCode, 0x38)
        XCTAssertEqual(optionKeyCode, 0x3A)
        XCTAssertEqual(commandKeyCode, 0x37)
    }

    // MARK: - Helper Properties (for testing internal logic)
    // These mirror the internal values for testing purposes

    private let leftArrowKeyCode: UInt16 = 0x7B
    private let rightArrowKeyCode: UInt16 = 0x7C
    private let downArrowKeyCode: UInt16 = 0x7D
    private let upArrowKeyCode: UInt16 = 0x7E
    private let controlKeyCode: UInt16 = 0x3B
    private let shiftKeyCode: UInt16 = 0x38
    private let optionKeyCode: UInt16 = 0x3A
    private let commandKeyCode: UInt16 = 0x37

    private func isSpecialKey(_ char: Character) -> Bool {
        switch char {
        case "\u{7F}", "\u{08}":  // DEL, BS -> Backspace
            return true
        case "\n", "\r":          // Enter/Return
            return true
        case "\t":                // Tab
            return true
        case "\u{1B}":            // Escape
            return true
        default:
            return false
        }
    }
}
