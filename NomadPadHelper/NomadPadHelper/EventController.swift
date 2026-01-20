import Foundation
import CoreGraphics
import Carbon.HIToolbox
import ApplicationServices

final class EventController {
    private var isLeftButtonDown = false

    private enum HelperClickButton: UInt8 {
        case left = 0
        case right = 1
        case middle = 2
    }

    private enum HelperClickAction: UInt8 {
        case down = 0
        case up = 1
        case click = 2
    }

    private struct HelperModifierFlags: OptionSet {
        let rawValue: UInt8

        static let command = HelperModifierFlags(rawValue: 1 << 0)
        static let option = HelperModifierFlags(rawValue: 1 << 1)
        static let control = HelperModifierFlags(rawValue: 1 << 2)
        static let shift = HelperModifierFlags(rawValue: 1 << 3)
    }

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

    init() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    private var currentPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveMouse(deltaX: Double, deltaY: Double) {
        let position = currentPosition
        let newPosition = CGPoint(x: position.x + deltaX, y: position.y + deltaY)

        if isLeftButtonDown {
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

        CGWarpMouseCursorPosition(newPosition)

        let moveEvent = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved,
            mouseCursorPosition: newPosition,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
    }

    func click(button: Int, action: Int) {
        guard let button = HelperClickButton(rawValue: UInt8(clamping: button)),
              let action = HelperClickAction(rawValue: UInt8(clamping: action)) else { return }

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

    private func buttonTypes(for button: HelperClickButton) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case .left:
            return (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            return (.right, .rightMouseDown, .rightMouseUp)
        case .middle:
            return (.center, .otherMouseDown, .otherMouseUp)
        }
    }

    func scroll(deltaX: Double, deltaY: Double) {
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

    func sendKey(keyCode: Int, modifiers: Int, isDown: Bool) {
        let keyCodeValue = UInt16(clamping: keyCode)
        let modifierFlags = HelperModifierFlags(rawValue: UInt8(clamping: modifiers))

        if modifierFlags.contains(.control) && arrowKeyCodes.contains(keyCodeValue) {
            if isDown {
                _ = sendSystemShortcut(keyCode: keyCodeValue)
            }
            return
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let flags = buildEventFlags(from: modifierFlags)

        if !modifierFlags.isEmpty && isDown {
            sendModifierKeys(modifierFlags, isDown: true, source: eventSource)
        }

        let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodeValue, keyDown: isDown)
        keyEvent?.flags = flags
        keyEvent?.post(tap: .cgSessionEventTap)

        if !modifierFlags.isEmpty && !isDown {
            sendModifierKeys(modifierFlags, isDown: false, source: eventSource)
        }
    }

    func typeText(_ text: String) {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        for char in text {
            if let keyCode = specialKeyCode(for: char) {
                let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
                let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
                downEvent?.post(tap: .cgSessionEventTap)
                upEvent?.post(tap: .cgSessionEventTap)
            } else {
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
        case "\u{7F}", "\u{08}":
            return 0x33
        case "\n", "\r":
            return 0x24
        case "\t":
            return 0x30
        case "\u{1B}":
            return 0x35
        default:
            return nil
        }
    }

    func sendSystemShortcut(keyCode: UInt16) -> Bool {
        guard let systemEventsKeyCode = appleScriptKeyCode(for: keyCode) else { return false }
        if sendAppleScriptControlKey(code: systemEventsKeyCode) {
            return true
        }
        sendControlArrowSequence(keyCode: keyCode)
        return false
    }

    private func appleScriptKeyCode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case KeyCode.leftArrow:
            return 123
        case KeyCode.rightArrow:
            return 124
        case KeyCode.downArrow:
            return 125
        case KeyCode.upArrow:
            return 126
        default:
            return nil
        }
    }

    private func sendAppleScriptControlKey(code: Int) -> Bool {
        let script = "tell application \"System Events\" to key code \(code) using control down"
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            print("[EventController] AppleScript failed: \(errorInfo)")
            return false
        }
        return true
    }

    private func sendControlArrowSequence(keyCode: UInt16) {
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

    private func buildEventFlags(from modifiers: HelperModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    private func sendModifierKeys(_ modifiers: HelperModifierFlags, isDown: Bool, source: CGEventSource?) {
        let modifierMap: [(HelperModifierFlags, UInt16, CGEventFlags)] = [
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
