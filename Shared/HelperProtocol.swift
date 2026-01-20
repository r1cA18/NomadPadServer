import Foundation

@objc public protocol NomadPadHelperProtocol {
    func moveMouse(deltaX: Double, deltaY: Double, reply: @escaping (Bool) -> Void)
    func click(button: Int, action: Int, reply: @escaping (Bool) -> Void)
    func scroll(deltaX: Double, deltaY: Double, reply: @escaping (Bool) -> Void)
    func sendKey(keyCode: Int, modifiers: Int, isDown: Bool, reply: @escaping (Bool) -> Void)
    func typeText(_ text: String, reply: @escaping (Bool) -> Void)
    func sendSystemShortcut(keyCode: Int, reply: @escaping (Bool) -> Void)
    func ping(reply: @escaping (Bool) -> Void)
}

public let kHelperBundleIdentifier = "com.r1ca18.NomadPadServer.Helper"
public let kHelperMachServiceName = "com.r1ca18.NomadPadServer.Helper"
