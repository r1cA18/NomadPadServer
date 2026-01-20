import Foundation

final class HelperService: NSObject, NomadPadHelperProtocol {
    let eventController = EventController()

    func moveMouse(deltaX: Double, deltaY: Double, reply: @escaping (Bool) -> Void) {
        eventController.moveMouse(deltaX: deltaX, deltaY: deltaY)
        reply(true)
    }

    func click(button: Int, action: Int, reply: @escaping (Bool) -> Void) {
        eventController.click(button: button, action: action)
        reply(true)
    }

    func scroll(deltaX: Double, deltaY: Double, reply: @escaping (Bool) -> Void) {
        eventController.scroll(deltaX: deltaX, deltaY: deltaY)
        reply(true)
    }

    func sendKey(keyCode: Int, modifiers: Int, isDown: Bool, reply: @escaping (Bool) -> Void) {
        eventController.sendKey(keyCode: keyCode, modifiers: modifiers, isDown: isDown)
        reply(true)
    }

    func typeText(_ text: String, reply: @escaping (Bool) -> Void) {
        eventController.typeText(text)
        reply(true)
    }

    func sendSystemShortcut(keyCode: Int, reply: @escaping (Bool) -> Void) {
        let success = eventController.sendSystemShortcut(keyCode: UInt16(clamping: keyCode))
        reply(success)
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}
