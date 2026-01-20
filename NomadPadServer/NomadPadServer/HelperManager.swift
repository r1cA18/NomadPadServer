import AppKit

final class HelperManager {
    static let shared = HelperManager()

    private var isHelperReady = false

    private init() {
        // Listen for helper ready notification
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.nomadpad.helper.ready"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[HelperManager] Helper ready")
            self?.isHelperReady = true
        }
    }

    func start() {
        launchHelperIfNeeded()
    }

    func sendSystemShortcut(keyCode: UInt16) {
        ensureHelperRunning()
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.nomadpad.helper.command"),
            object: nil,
            userInfo: ["command": "systemShortcut", "keyCode": Int(keyCode)],
            deliverImmediately: true
        )
    }

    private func ensureHelperRunning() {
        if NSRunningApplication.runningApplications(withBundleIdentifier: kHelperBundleIdentifier).isEmpty {
            launchHelperIfNeeded()
        }
    }

    private func launchHelperIfNeeded() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: kHelperBundleIdentifier).isEmpty {
            print("[HelperManager] Helper already running")
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems")
            .appendingPathComponent("NomadPadHelper.app")

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            print("[HelperManager] Helper app not found at \(helperURL.path)")
            return
        }

        print("[HelperManager] Launching helper from \(helperURL.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { app, error in
            if let error = error {
                print("[HelperManager] Failed to launch helper: \(error)")
            } else {
                print("[HelperManager] Helper launched: \(app?.bundleIdentifier ?? "unknown")")
            }
        }
    }
}
