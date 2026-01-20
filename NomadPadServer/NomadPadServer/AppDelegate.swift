import AppKit
import SwiftUI
import Network
import Security
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var networkServer: NetworkServer?
    private var mouseController: MouseController?
    private let helperManager = HelperManager.shared

    // Connection state for UI updates
    @Published var isConnected = false
    @Published var connectedClientName = "Not connected"
    @Published var connectedAt: Date?

    private let pairingManager = PairingManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        helperManager.start()
        setupMenuBar()
        setupServer()
        checkAccessibilityPermission()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateMenuBarIcon(connected: false)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        updatePopover()
    }

    private func updateMenuBarIcon(connected: Bool) {
        guard let button = statusItem?.button else { return }

        let symbolName = connected ? "hand.point.up.left.fill" : "hand.point.up.left"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NomadPad")

        // Tint the icon based on connection state
        if connected {
            image?.isTemplate = false
            if let tintedImage = image?.tinted(with: .systemGreen) {
                button.image = tintedImage
            } else {
                button.image = image
            }
        } else {
            image?.isTemplate = true
            button.image = image
        }
    }

    private func updatePopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusView(
                isConnected: Binding(
                    get: { [weak self] in self?.isConnected ?? false },
                    set: { _ in }
                ),
                clientName: Binding(
                    get: { [weak self] in self?.connectedClientName ?? "Not connected" },
                    set: { _ in }
                ),
                connectedAt: Binding(
                    get: { [weak self] in self?.connectedAt },
                    set: { _ in }
                ),
                pairingManager: pairingManager,
                onDisconnect: { [weak self] in self?.disconnectClient() },
                onQuit: { [weak self] in self?.quit() }
            )
        )
        self.popover = popover
    }

    private func setupServer() {
        mouseController = MouseController()
        networkServer = NetworkServer(pairingKeyProvider: { [weak self] in
            self?.pairingManager.pairingKey ?? Data()
        })
        networkServer?.delegate = self
        networkServer?.onMessageReceived = { [weak self] message in
            self?.handleMessage(message)
        }
        pairingManager.onPairingReset = { [weak self] in
            guard let self = self else { return }
            self.networkServer?.stop()
            self.networkServer?.start()
        }
        networkServer?.start()
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: any RemoteMessage) {
        switch message {
        case let move as MouseMoveMessage:
            mouseController?.moveMouse(deltaX: CGFloat(move.deltaX), deltaY: CGFloat(move.deltaY))
        case let click as ClickMessage:
            mouseController?.click(button: click.button, action: click.action)
        case let scroll as ScrollMessage:
            mouseController?.scroll(deltaX: CGFloat(scroll.deltaX), deltaY: CGFloat(scroll.deltaY))
        case let key as KeyMessage:
            mouseController?.sendKey(keyCode: key.keyCode, modifiers: key.modifiers, isDown: key.isDown)
        case let text as TextMessage:
            mouseController?.typeText(text.text)
        default:
            break
        }
    }

    // MARK: - Connection Management

    private func disconnectClient() {
        if let client = networkServer?.connectedClientInfo {
            networkServer?.disconnectClient(deviceId: client.deviceId, reason: .userRequested)
        }
    }

    private func updateConnectionState(connected: Bool, clientName: String? = nil, connectedAt: Date? = nil) {
        self.isConnected = connected
        self.connectedClientName = clientName ?? "Not connected"
        self.connectedAt = connectedAt

        updateMenuBarIcon(connected: connected)
        updatePopover()
    }

    // MARK: - Accessibility

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()

        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = """
                    NomadPadServer needs accessibility permission to control mouse clicks.

                    1. Open System Settings
                    2. Go to Privacy & Security > Accessibility
                    3. Enable NomadPadServer
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    private func quit() {
        networkServer?.stop()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NetworkServerDelegate

extension AppDelegate: NetworkServerDelegate {
    func networkServer(_ server: NetworkServer, didReceiveConnectionRequest request: ConnectionRequestMessage, from connection: NWConnection) {
        // All connections are auto-approved via PSK validation
        // This delegate method is kept for protocol conformance but won't be called
    }

    func networkServer(_ server: NetworkServer, clientDidConnect client: ConnectedClientInfo) {
        updateConnectionState(connected: true, clientName: client.deviceName, connectedAt: client.connectedAt)
    }

    func networkServer(_ server: NetworkServer, clientDidDisconnect deviceName: String, reason: DisconnectReason) {
        updateConnectionState(connected: false)

        // Show notification for unexpected disconnections
        if reason == .timeout || reason == .networkError {
            showDisconnectionNotification(deviceName: deviceName, reason: reason)
        }
    }

    func networkServer(_ server: NetworkServer, didCancelConnectionRequest deviceId: String, deviceName: String) {
        // No longer needed since we auto-approve all connections
    }

    private func showDisconnectionNotification(deviceName: String, reason: DisconnectReason) {
        let content = UNMutableNotificationContent()
        content.title = "Device Disconnected"

        switch reason {
        case .timeout:
            content.body = "\(deviceName) disconnected due to timeout."
        case .networkError:
            content.body = "\(deviceName) disconnected due to network error."
        default:
            content.body = "\(deviceName) disconnected."
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Status View

struct StatusView: View {
    @Binding var isConnected: Bool
    @Binding var clientName: String
    @Binding var connectedAt: Date?
    @ObservedObject var pairingManager: PairingManager
    let onDisconnect: () -> Void
    let onQuit: () -> Void

    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var connectionDuration: String {
        guard let connectedAt = connectedAt else { return "" }
        let interval = Date().timeIntervalSince(connectedAt)
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Connection status card
            HStack {
                ZStack {
                    Circle()
                        .fill(isConnected ? Color.green.opacity(0.2) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: isConnected ? "wifi" : "wifi.slash")
                        .font(.system(size: 20))
                        .foregroundColor(isConnected ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isConnected ? "Connected" : "Waiting for connection...")
                        .font(.headline)
                    Text(clientName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if isConnected, let _ = connectedAt {
                        Text("Duration: \(connectionDuration)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .onReceive(timer) { _ in
                // Force view update for connection duration
            }

            // Pairing QR code section
            VStack(spacing: 8) {
                Text("Scan to Connect")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let qrImage = pairingManager.qrCodeImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .background(Color.white)
                        .cornerRadius(8)
                }

                Text(pairingManager.displayCode)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Button("Copy") {
                        pairingManager.copyCodeToPasteboard()
                    }
                    .buttonStyle(.plain)
                    .help("Copy pairing code")

                    Button("Regenerate") {
                        pairingManager.regenerate()
                    }
                    .buttonStyle(.plain)
                    .help("Generate a new pairing code")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Disconnect button (only shown when connected)
            if isConnected {
                Button(action: onDisconnect) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Disconnect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Spacer()

            // Quit button
            Button("Quit NomadPad") {
                onQuit()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - NSImage Extension

extension NSImage {
    func tinted(with color: NSColor) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let size = self.size
        let rect = NSRect(origin: .zero, size: size)

        let newImage = NSImage(size: size)
        newImage.lockFocus()

        color.set()
        rect.fill(using: .sourceAtop)

        let context = NSGraphicsContext.current?.cgContext
        context?.draw(cgImage, in: rect)

        color.set()
        rect.fill(using: .sourceAtop)

        newImage.unlockFocus()

        return newImage
    }
}

// MARK: - Pairing Manager (PSK)

final class PairingManager: ObservableObject {
    static let shared = PairingManager()
    static let keySize = 32

    @Published private(set) var displayCode: String = ""
    @Published private(set) var qrCodeImage: NSImage?
    private(set) var pairingKey: Data = Data()
    var onPairingReset: (() -> Void)?

    private let service = "com.nomadpad.pairing"
    private let account = "psk"

    private init() {
        if let stored = load(), stored.count == Self.keySize {
            pairingKey = stored
        } else {
            pairingKey = generateKey()
            save(pairingKey)
        }
        updateDisplayCode()
    }

    func regenerate() {
        pairingKey = generateKey()
        save(pairingKey)
        updateDisplayCode()
        onPairingReset?()
    }

    func copyCodeToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayCode, forType: .string)
    }

    private func updateDisplayCode() {
        let code = Base32.encode(pairingKey)
        displayCode = formatCode(code)
        qrCodeImage = generateQRCode(from: code)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for better quality
        let scale = 8.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.keySize)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func formatCode(_ code: String) -> String {
        var parts: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let next = code.index(index, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            parts.append(String(code[index..<next]))
            index = next
        }
        return parts.joined(separator: "-")
    }

    private func save(_ data: Data) {
        let query = keychainQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func load() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var buffer = 0
        var bitsLeft = 0
        var output = ""

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1F
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1F
            output.append(alphabet[index])
        }

        return output
    }
}
