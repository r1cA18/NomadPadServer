import Foundation
import AppKit

let service = HelperService()

// Listen for commands via DistributedNotification
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.nomadpad.helper.command"),
    object: nil,
    queue: .main
) { notification in
    guard let userInfo = notification.userInfo,
          let command = userInfo["command"] as? String else {
        return
    }

    switch command {
    case "systemShortcut":
        if let keyCode = userInfo["keyCode"] as? Int {
            _ = service.eventController.sendSystemShortcut(keyCode: UInt16(keyCode))
        }
    case "ping":
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.nomadpad.helper.pong"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    default:
        break
    }
}

// Notify that helper is ready
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("com.nomadpad.helper.ready"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)

print("[NomadPadHelper] Helper started, listening for commands")

RunLoop.main.run()
