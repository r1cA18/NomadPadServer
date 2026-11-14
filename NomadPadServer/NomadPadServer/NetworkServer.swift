import Dispatch
import Foundation
import Network
import Security

// MARK: - Connected Client Info
struct ConnectedClientInfo {
    let connection: NWConnection
    let deviceName: String
    let deviceId: String
    let deviceToken: String
    let connectedAt: Date
    var lastHeartbeat: Date
}

struct ControllerIdentity: Equatable {
    let deviceId: String
    let deviceToken: String
}

// Details presented to the user when a new device asks to connect for the
// first time.
struct ConnectionApprovalRequest {
    let deviceName: String
    let deviceId: String
    let hasDeviceToken: Bool
}

enum ConnectionAdmissionDecision: Equatable {
    case approveNew
    case replaceExisting
    case denyNew

    static func resolve(
        request: ControllerIdentity,
        active: ControllerIdentity?
    ) -> ConnectionAdmissionDecision {
        guard let active else { return .approveNew }
        return active == request ? .replaceExisting : .denyNew
    }
}

// Lifecycle state of the Bonjour/TCP listener, surfaced to the UI so a
// failure to accept connections is visible instead of silent.
enum ServerListenerState: Equatable {
    case starting
    case running
    case failed(String)
}

// MARK: - Network Server Delegate
protocol NetworkServerDelegate: AnyObject {
    // Posted to main before the new session can deliver any input, so work
    // done here is ordered ahead of that session's first message.
    func networkServerWillStartSession(_ server: NetworkServer)
    func networkServer(_ server: NetworkServer, clientDidConnect client: ConnectedClientInfo)
    func networkServer(_ server: NetworkServer, clientDidDisconnect deviceName: String, reason: DisconnectReason)
}

class NetworkServer {
    private var listener: NWListener?
    private var connectedClients: [String: ConnectedClientInfo] = [:] // deviceId -> info
    private let queue = DispatchQueue(label: "com.r1ca18.nomadpad.server", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let pairingKeyProvider: () -> Data
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var handshakeTimeoutWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let maxFrameSize = 64 * 1024

    // Timeouts
    private let connectionRequestTimeout: TimeInterval = 10.0
    private let heartbeatTimeout: TimeInterval = 15.0
    private var heartbeatCheckTimer: Timer?

    weak var delegate: NetworkServerDelegate?
    var onMessageReceived: ((any RemoteMessage) -> Void)?

    // Invoked on the main thread when a device that has not been approved
    // before requests a connection. The completion must be called with the
    // user's decision.
    var connectionApprovalHandler: ((ConnectionApprovalRequest, @escaping (Bool) -> Void) -> Void)?

    // Invoked on the main thread whenever the listener's lifecycle state
    // changes so the menu bar UI can reflect it.
    var onListenerStateChanged: ((ServerListenerState) -> Void)?

    // A device approval prompt is in flight. While set, further connection
    // requests are denied so only one prompt can be pending at a time.
    private var isAwaitingApproval = false

    private let approvedTokensDefaultsKey = "com.r1ca18.nomadpad.approvedDeviceTokens"

    var connectedClientInfo: ConnectedClientInfo? {
        readOnQueue { connectedClients.values.first }
    }

    init(pairingKeyProvider: @escaping () -> Data) {
        self.pairingKeyProvider = pairingKeyProvider
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        notifyListenerState(.starting)
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true

            let tlsOptions = NWProtocolTLS.Options()
            configureTLS(options: tlsOptions)

            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: ServiceConstants.defaultPort))

            // Advertise via Bonjour
            let serviceName = Host.current().localizedName ?? "Mac"
            listener?.service = NWListener.Service(
                name: serviceName,
                type: ServiceConstants.serviceType
            )

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.notifyListenerState(.running)
                case .waiting(let error):
                    self?.notifyListenerState(.failed(error.localizedDescription))
                case .failed(let error):
                    self?.notifyListenerState(.failed(error.localizedDescription))
                    self?.listener?.cancel()
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: queue)

            // Start heartbeat check timer
            startHeartbeatCheckTimer()

        } catch {
            print("[NetworkServer] Failed to start: \(error.localizedDescription)")
            notifyListenerState(.failed(error.localizedDescription))
        }
    }

    private func notifyListenerState(_ state: ServerListenerState) {
        notifyOnMain { [weak self] in
            self?.onListenerStateChanged?(state)
        }
    }

    func stop() {
        stopHeartbeatCheckTimer()

        runOnQueueSync { [weak self] in
            guard let self = self else { return }

            // Send disconnect message to all connected clients
            for client in self.connectedClients.values {
                self.sendControlMessage(DisconnectMessage(reason: .serverClosed), to: client.connection)
            }

            self.listener?.cancel()

            // Cancel all connections
            for client in self.connectedClients.values {
                client.connection.cancel()
            }
            for workItem in self.handshakeTimeoutWorkItems.values {
                workItem.cancel()
            }

            self.connectedClients.removeAll()
            self.receiveBuffers.removeAll()
            self.handshakeTimeoutWorkItems.removeAll()
        }
    }

    func disconnectClient(deviceId: String, reason: DisconnectReason = .userRequested) {
        runOnQueue { [weak self] in
            self?.disconnectClientOnQueue(deviceId: deviceId, reason: reason)
        }
    }

    private func disconnectClientOnQueue(deviceId: String, reason: DisconnectReason) {
        guard let client = connectedClients.removeValue(forKey: deviceId) else { return }

        // Send disconnect message
        let disconnectMsg = DisconnectMessage(reason: reason)
        sendControlMessage(disconnectMsg, to: client.connection)

        // Close connection after a short delay
        queue.asyncAfter(deadline: .now() + 0.5) {
            client.connection.cancel()
        }

        notifyOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.networkServer(self, clientDidDisconnect: client.deviceName, reason: reason)
        }
    }

    private func runOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private func runOnQueueSync(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.sync(execute: block)
        }
    }

    private func readOnQueue<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }

    private func notifyOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func connectedClientEntry(for connection: NWConnection) -> (deviceId: String, client: ConnectedClientInfo)? {
        connectedClients.first { $0.value.connection === connection }
            .map { (deviceId: $0.key, client: $0.value) }
    }

    // MARK: - Private Methods

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveData(on: connection)
            case .failed, .cancelled:
                self?.handleConnectionClosed(connection)
            default:
                break
            }
        }

        let connectionKey = ObjectIdentifier(connection)
        receiveBuffers[connectionKey] = Data()
        scheduleHandshakeTimeout(for: connection)
        connection.start(queue: queue)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxFrameSize) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.appendAndProcess(data, from: connection)
            }

            if isComplete || error != nil {
                self.handleConnectionClosed(connection)
                return
            }

            if connection.state == .ready {
                self.receiveData(on: connection)
            }
        }
    }

    private func appendAndProcess(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = receiveBuffers[key] ?? Data()
        buffer.append(data)

        let headerSize = 4
        while buffer.count >= headerSize {
            let length = buffer.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            }
            if length == 0 || length > UInt32(maxFrameSize) {
                connection.cancel()
                receiveBuffers[key] = Data()
                return
            }

            let totalSize = headerSize + Int(length)
            guard buffer.count >= totalSize else { break }

            let payload = buffer.subdata(in: headerSize..<totalSize)
            buffer.removeSubrange(0..<totalSize)
            handleReceivedPayload(payload, from: connection)
        }

        receiveBuffers[key] = buffer
    }

    private func handleReceivedPayload(_ data: Data, from connection: NWConnection) {
        if ControlMessageDecoder.isControlMessage(data) {
            handleControlMessage(data, from: connection)
            return
        }

        if isApprovedConnection(connection),
           let message = MessageDecoder.decode(from: data) {
            notifyOnMain { [weak self] in
                self?.onMessageReceived?(message)
            }
        } else if !isApprovedConnection(connection) {
            connection.cancel()
        }
    }

    private func handleControlMessage(_ data: Data, from connection: NWConnection) {
        guard let controlMessage = ControlMessageDecoder.decode(from: data) else { return }

        switch controlMessage {
        case let request as ConnectionRequestMessage:
            handleConnectionRequest(request, from: connection)

        case let heartbeat as HeartbeatMessage:
            handleHeartbeat(heartbeat, from: connection)

        case let disconnect as DisconnectMessage:
            handleDisconnect(disconnect, from: connection)

        default:
            break
        }
    }

    private func handleConnectionRequest(_ request: ConnectionRequestMessage, from connection: NWConnection) {
        cancelHandshakeTimeout(for: connection)

        let requestIdentity = ControllerIdentity(
            deviceId: request.deviceId,
            deviceToken: request.deviceToken
        )
        let activeClient = connectedClients.values.first
        let activeIdentity = activeClient.map {
            ControllerIdentity(deviceId: $0.deviceId, deviceToken: $0.deviceToken)
        }

        // A prompt for another device is already open. Deny the request instead
        // of opening a second, competing prompt.
        if isAwaitingApproval {
            print("[NetworkServer] Denying controller while an approval prompt is pending: \(request.deviceName)")
            denyConnectionRequest(on: connection)
            return
        }

        switch ConnectionAdmissionDecision.resolve(request: requestIdentity, active: activeIdentity) {
        case .approveNew:
            if isApprovedDevice(token: request.deviceToken) {
                print("[NetworkServer] TLS handshake authenticated known controller, approving: \(request.deviceName)")
                approveConnectionRequest(request, on: connection, replacing: nil)
            } else {
                print("[NetworkServer] TLS handshake authenticated new controller, requesting user approval: \(request.deviceName)")
                requestUserApproval(request, on: connection, replacing: nil)
            }
        case .replaceExisting:
            guard let activeClient else {
                approveConnectionRequest(request, on: connection, replacing: nil)
                return
            }
            print("[NetworkServer] Replacing active controller for: \(request.deviceName)")
            approveConnectionRequest(request, on: connection, replacing: activeClient)
        case .denyNew:
            print("[NetworkServer] Denying additional controller while another device is active: \(request.deviceName)")
            denyConnectionRequest(on: connection)
        }
    }

    private func approveConnectionRequest(
        _ request: ConnectionRequestMessage,
        on connection: NWConnection,
        replacing previousClient: ConnectedClientInfo?
    ) {
        let clientInfo = ConnectedClientInfo(
            connection: connection,
            deviceName: request.deviceName,
            deviceId: request.deviceId,
            deviceToken: request.deviceToken,
            connectedAt: Date(),
            lastHeartbeat: Date()
        )

        // Input is forwarded to main only after the slot below is reserved, so
        // posting this first keeps it ahead of the new session's input.
        notifyOnMain { [weak self] in
            guard let self else { return }
            self.delegate?.networkServerWillStartSession(self)
        }

        // Reserve the single active slot synchronously on the serial queue.
        // Doing this before the response is sent prevents a second connection
        // request processed in between from also being admitted.
        if let previousClient {
            connectedClients.removeValue(forKey: previousClient.deviceId)
        }
        connectedClients = [request.deviceId: clientInfo]

        let response = ConnectionResponseMessage(approved: true)
        sendControlMessage(response, to: connection) { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                // Roll back the reservation if the approval could not be delivered.
                self.connectedClients.removeValue(forKey: request.deviceId)
                connection.cancel()
                return
            }

            previousClient?.connection.cancel()

            print("[NetworkServer] Approved connection from: \(request.deviceName)")

            self.notifyOnMain { [weak self] in
                guard let self else { return }
                self.delegate?.networkServer(self, clientDidConnect: clientInfo)
            }
        }
    }

    private func denyConnectionRequest(on connection: NWConnection) {
        let response = ConnectionResponseMessage(approved: false)
        sendControlMessage(response, to: connection) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.2) {
                connection.cancel()
            }
        }
    }

    // MARK: - First-time Device Approval

    private func requestUserApproval(
        _ request: ConnectionRequestMessage,
        on connection: NWConnection,
        replacing previousClient: ConnectedClientInfo?
    ) {
        guard let approvalHandler = connectionApprovalHandler else {
            // No approval UI is wired up. The TLS PSK already gates access, so
            // fall back to admitting the controller rather than locking out.
            print("[NetworkServer] No approval handler set, admitting controller: \(request.deviceName)")
            rememberDevice(token: request.deviceToken)
            approveConnectionRequest(request, on: connection, replacing: previousClient)
            return
        }

        isAwaitingApproval = true
        let approvalRequest = ConnectionApprovalRequest(
            deviceName: request.deviceName,
            deviceId: request.deviceId,
            hasDeviceToken: !request.deviceToken.isEmpty
        )

        notifyOnMain { [weak self] in
            approvalHandler(approvalRequest) { approved in
                self?.runOnQueue {
                    guard let self else { return }
                    self.isAwaitingApproval = false

                    if approved {
                        self.rememberDevice(token: request.deviceToken)
                        self.approveConnectionRequest(request, on: connection, replacing: previousClient)
                    } else {
                        print("[NetworkServer] User denied controller: \(request.deviceName)")
                        self.denyConnectionRequest(on: connection)
                    }
                }
            }
        }
    }

    private func isApprovedDevice(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return approvedTokens().contains(token)
    }

    private func rememberDevice(token: String) {
        // Legacy clients send no token and cannot be remembered, so they are
        // prompted on every connection.
        guard !token.isEmpty else { return }
        var tokens = approvedTokens()
        guard !tokens.contains(token) else { return }
        tokens.insert(token)
        UserDefaults.standard.set(Array(tokens), forKey: approvedTokensDefaultsKey)
    }

    private func approvedTokens() -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: approvedTokensDefaultsKey) ?? []
        return Set(stored)
    }

    // MARK: - Heartbeat

    private func handleHeartbeat(_ heartbeat: HeartbeatMessage, from connection: NWConnection) {
        // Find the client by connection
        guard let entry = connectedClientEntry(for: connection) else { return }
        var updatedClient = entry.client
        updatedClient.lastHeartbeat = Date()
        connectedClients[entry.deviceId] = updatedClient

        // Send heartbeat acknowledgment (encrypted if ready)
        let ack = HeartbeatAckMessage(timestamp: heartbeat.timestamp)
        sendControlMessage(ack, to: connection)
    }

    private func handleDisconnect(_ disconnect: DisconnectMessage, from connection: NWConnection) {
        guard let entry = connectedClientEntry(for: connection) else { return }
        connectedClients.removeValue(forKey: entry.deviceId)
        connection.cancel()

        notifyOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.networkServer(self, clientDidDisconnect: entry.client.deviceName, reason: disconnect.reason)
        }
    }

    private func handleConnectionClosed(_ connection: NWConnection) {
        let connectionKey = ObjectIdentifier(connection)
        receiveBuffers.removeValue(forKey: connectionKey)
        cancelHandshakeTimeout(for: connection)

        if let entry = connectedClientEntry(for: connection) {
            connectedClients.removeValue(forKey: entry.deviceId)

            notifyOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.networkServer(self, clientDidDisconnect: entry.client.deviceName, reason: .networkError)
            }
        }
    }

    private func isApprovedConnection(_ connection: NWConnection) -> Bool {
        connectedClientEntry(for: connection) != nil
    }

    // Sends a data-plane message (e.g. volume/brightness status) to the single
    // approved client. No-op when no client is connected.
    func sendMessage(_ message: any RemoteMessage) {
        runOnQueue { [weak self] in
            guard let self, let client = self.connectedClients.values.first else { return }
            self.sendFramed(message.encode(), to: client.connection) { _ in }
        }
    }

    private func sendControlMessage(_ message: any ControlMessage, to connection: NWConnection) {
        sendControlMessage(message, to: connection) { _ in }
    }

    private func sendControlMessage(
        _ message: any ControlMessage,
        to connection: NWConnection,
        completion: @escaping (NWError?) -> Void
    ) {
        sendFramed(message.encode(), to: connection) { error in
            if let error = error {
                print("[NetworkServer] Failed to send control message: \(error.localizedDescription)")
            }
            completion(error)
        }
    }

    private func sendFramed(_ payload: Data, to connection: NWConnection, completion: @escaping (NWError?) -> Void) {
        var data = Data()
        var length = UInt32(payload.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    // MARK: - TLS Configuration (PSK)

    private func configureTLS(options: NWProtocolTLS.Options) {
        let psk = pairingKeyProvider()
        let identityHint = dispatchData(from: Data("NomadPad".utf8))
        let pskData = dispatchData(from: psk)

        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, pskData, identityHint)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(options.securityProtocolOptions, identityHint)
    }

    private func dispatchData(from data: Data) -> dispatch_data_t {
        data.withUnsafeBytes { buffer in
            DispatchData(bytes: buffer) as dispatch_data_t
        }
    }

    private func scheduleHandshakeTimeout(for connection: NWConnection) {
        let connectionKey = ObjectIdentifier(connection)
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard !self.isApprovedConnection(connection) else { return }

            print("[NetworkServer] Closing idle connection before controller identity was established")
            connection.cancel()
        }

        handshakeTimeoutWorkItems[connectionKey]?.cancel()
        handshakeTimeoutWorkItems[connectionKey] = workItem
        queue.asyncAfter(deadline: .now() + connectionRequestTimeout, execute: workItem)
    }

    private func cancelHandshakeTimeout(for connection: NWConnection) {
        let connectionKey = ObjectIdentifier(connection)
        handshakeTimeoutWorkItems[connectionKey]?.cancel()
        handshakeTimeoutWorkItems.removeValue(forKey: connectionKey)
    }

    // MARK: - Heartbeat Check

    private func startHeartbeatCheckTimer() {
        notifyOnMain { [weak self] in
            self?.heartbeatCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.checkHeartbeatTimeouts()
            }
        }
    }

    private func stopHeartbeatCheckTimer() {
        notifyOnMain { [weak self] in
            self?.heartbeatCheckTimer?.invalidate()
            self?.heartbeatCheckTimer = nil
        }
    }

    private func checkHeartbeatTimeouts() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let now = Date()
            var timedOutClients: [String] = []

            for (deviceId, client) in self.connectedClients {
                if now.timeIntervalSince(client.lastHeartbeat) > self.heartbeatTimeout {
                    timedOutClients.append(deviceId)
                }
            }

            for deviceId in timedOutClients {
                self.disconnectClient(deviceId: deviceId, reason: .timeout)
            }
        }
    }
}
