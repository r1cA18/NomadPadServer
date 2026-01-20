import CoreGraphics
import Carbon.HIToolbox
import ApplicationServices
import Foundation

/// Controls mouse, keyboard, and system shortcuts on macOS
class MouseController {

    // MARK: - Properties

    private var currentPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private var isLeftButtonDown = false

    // MARK: - Key Codes

    private enum KeyCode {
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let downArrow: UInt16 = 0x7D
        static let upArrow: UInt16 = 0x7E
        static let control: UInt16 = 0x3B
        static let shift: UInt16 = 0x38
        static let option: UInt16 = 0x3A
        static let command: UInt16 = 0x37
    }

    private let arrowKeyCodes: Set<UInt16> = [
        KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow
    ]

    // MARK: - Initialization

    init() {
        if !AXIsProcessTrusted() {
            print("[MouseController] WARNING: Accessibility permission not granted")
        }
    }

    // MARK: - Mouse Movement

    func moveMouse(deltaX: CGFloat, deltaY: CGFloat) {
        let position = currentPosition
        let newPosition = CGPoint(x: position.x + deltaX, y: position.y + deltaY)

        if isLeftButtonDown {
            // Drag mode - move cursor then send drag event
            CGWarpMouseCursorPosition(newPosition)
            let dragEvent = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .leftMouseDragged,
                mouseCursorPosition: newPosition,
                mouseButton: .left
            )
            dragEvent?.post(tap: .cghidEventTap)
            return
        }

        // Normal move - warp position and post move event for hover effects
        CGWarpMouseCursorPosition(newPosition)

        // Post mouse move event to trigger hover effects and unhide cursor
        let moveEvent = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved,
            mouseCursorPosition: newPosition,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Click

    func click(button: ClickButton, action: ClickAction) {
        let position = currentPosition
        let eventSource = CGEventSource(stateID: .hidSystemState)

        let (cgButton, downType, upType) = buttonTypes(for: button)

        switch action {
        case .down:
            if button == .left { isLeftButtonDown = true }
            let event = CGEvent(mouseEventSource: eventSource, mouseType: downType,
                              mouseCursorPosition: position, mouseButton: cgButton)
            event?.post(tap: .cgSessionEventTap)

        case .up:
            if button == .left { isLeftButtonDown = false }
            let event = CGEvent(mouseEventSource: eventSource, mouseType: upType,
                              mouseCursorPosition: position, mouseButton: cgButton)
            event?.post(tap: .cgSessionEventTap)

        case .click:
            let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: downType,
                                   mouseCursorPosition: position, mouseButton: cgButton)
            let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: upType,
                                 mouseCursorPosition: position, mouseButton: cgButton)
            downEvent?.post(tap: .cgSessionEventTap)
            usleep(10000)
            upEvent?.post(tap: .cgSessionEventTap)
            if button == .left { isLeftButtonDown = false }
        }
    }

    private func buttonTypes(for button: ClickButton) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case .left:
            return (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            return (.right, .rightMouseDown, .rightMouseUp)
        case .middle:
            return (.center, .otherMouseDown, .otherMouseUp)
        }
    }

    // MARK: - Scroll

    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        )
        scrollEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func sendKey(keyCode: UInt16, modifiers: ModifierFlags, isDown: Bool) {
        // Control+Arrow needs special handling for Spaces switching
        if modifiers.contains(.control) && arrowKeyCodes.contains(keyCode) {
            if isDown {
                sendControlArrowSequence(keyCode: keyCode)
            }
            return
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let flags = buildEventFlags(from: modifiers)

        // Send modifier keys for modified key presses
        if !modifiers.isEmpty && isDown {
            sendModifierKeys(modifiers, isDown: true, source: eventSource)
        }

        // Send main key event
        let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown)
        keyEvent?.flags = flags
        keyEvent?.post(tap: .cgSessionEventTap)

        // Release modifier keys
        if !modifiers.isEmpty && !isDown {
            sendModifierKeys(modifiers, isDown: false, source: eventSource)
        }
    }

    func typeText(_ text: String) {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        for char in text {
            // Handle special keys
            let keyCode: UInt16? = specialKeyCode(for: char)

            if let keyCode = keyCode {
                // Send as key event
                let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
                let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
                downEvent?.post(tap: .cgSessionEventTap)
                upEvent?.post(tap: .cgSessionEventTap)
            } else {
                // Use Unicode string approach for regular characters
                let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)

                var unichar = [UniChar](String(char).utf16)
                downEvent?.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
                upEvent?.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)

                downEvent?.post(tap: .cgSessionEventTap)
                upEvent?.post(tap: .cgSessionEventTap)
            }

            usleep(5000)
        }
    }

    private func specialKeyCode(for char: Character) -> UInt16? {
        switch char {
        case "\u{7F}", "\u{08}":  // DEL, BS -> Backspace
            return 0x33
        case "\n", "\r":          // Enter/Return
            return 0x24
        case "\t":                // Tab
            return 0x30
        case "\u{1B}":            // Escape
            return 0x35
        default:
            return nil
        }
    }

    // MARK: - System Shortcuts (Spaces/Mission Control)

    private func sendControlArrowSequence(keyCode: UInt16) {
        // Try AppleScript first (most reliable for Spaces switching)
        if let appleScriptCode = appleScriptKeyCode(for: keyCode) {
            if sendAppleScriptControlKey(code: appleScriptCode) {
                return
            }
        }

        // Fallback to CGEvent
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        let controlDown = CGEvent(keyboardEventSource: eventSource, virtualKey: KeyCode.control, keyDown: true)
        controlDown?.flags = .maskControl
        controlDown?.post(tap: .cgSessionEventTap)

        usleep(50000)

        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskControl
        keyDown?.post(tap: .cgSessionEventTap)

        usleep(50000)

        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskControl
        keyUp?.post(tap: .cgSessionEventTap)

        usleep(30000)

        let controlUp = CGEvent(keyboardEventSource: eventSource, virtualKey: KeyCode.control, keyDown: false)
        controlUp?.post(tap: .cgSessionEventTap)
    }

    private func appleScriptKeyCode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case KeyCode.leftArrow: return 123
        case KeyCode.rightArrow: return 124
        case KeyCode.downArrow: return 125
        case KeyCode.upArrow: return 126
        default: return nil
        }
    }

    private func sendAppleScriptControlKey(code: Int) -> Bool {
        let script = "tell application \"System Events\" to key code \(code) using control down"
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            print("[MouseController] AppleScript failed: \(errorInfo)")
            return false
        }
        return true
    }

    // MARK: - Helpers

    private func buildEventFlags(from modifiers: ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    private func sendModifierKeys(_ modifiers: ModifierFlags, isDown: Bool, source: CGEventSource?) {
        let modifierMap: [(ModifierFlags, UInt16, CGEventFlags)] = [
            (.control, KeyCode.control, .maskControl),
            (.shift, KeyCode.shift, .maskShift),
            (.option, KeyCode.option, .maskAlternate),
            (.command, KeyCode.command, .maskCommand)
        ]

        for (flag, keyCode, eventFlag) in modifierMap {
            if modifiers.contains(flag) {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
                if isDown { event?.flags = eventFlag }
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }

}
