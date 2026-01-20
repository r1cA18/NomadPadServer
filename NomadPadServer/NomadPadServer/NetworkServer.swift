import Dispatch
import Foundation
import Network
import Security

// MARK: - Pending Connection Info
struct PendingConnectionInfo {
    let connection: NWConnection
    let deviceName: String
    let deviceId: String
    let requestTime: Date
}

// MARK: - Connected Client Info
struct ConnectedClientInfo {
    let connection: NWConnection
    let deviceName: String
    let deviceId: String
    let connectedAt: Date
    var lastHeartbeat: Date
}

// MARK: - Network Server Delegate
protocol NetworkServerDelegate: AnyObject {
    func networkServer(_ server: NetworkServer, didReceiveConnectionRequest request: ConnectionRequestMessage, from connection: NWConnection)
    func networkServer(_ server: NetworkServer, clientDidConnect client: ConnectedClientInfo)
    func networkServer(_ server: NetworkServer, clientDidDisconnect deviceName: String, reason: DisconnectReason)
    func networkServer(_ server: NetworkServer, didCancelConnectionRequest deviceId: String, deviceName: String)
}

class NetworkServer {
    private var listener: NWListener?
    private var pendingConnections: [String: PendingConnectionInfo] = [:] // deviceId -> info
    private var connectedClients: [String: ConnectedClientInfo] = [:] // deviceId -> info
    private let queue = DispatchQueue(label: "com.deskpad.server", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let pairingKeyProvider: () -> Data
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let maxFrameSize = 64 * 1024

    // Timeouts
    private let connectionRequestTimeout: TimeInterval = 60.0
    private let heartbeatTimeout: TimeInterval = 15.0
    private var heartbeatCheckTimer: Timer?

    weak var delegate: NetworkServerDelegate?
    var onMessageReceived: ((any RemoteMessage) -> Void)?

    var isClientConnected: Bool {
        readOnQueue { !connectedClients.isEmpty }
    }

    var connectedClientName: String {
        readOnQueue { connectedClients.values.first?.deviceName ?? "Not connected" }
    }

    var connectedClientInfo: ConnectedClientInfo? {
        readOnQueue { connectedClients.values.first }
    }

    init(pairingKeyProvider: @escaping () -> Data) {
        self.pairingKeyProvider = pairingKeyProvider
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
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
                case .failed:
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
            for info in self.pendingConnections.values {
                info.connection.cancel()
            }
            for client in self.connectedClients.values {
                client.connection.cancel()
            }

            self.pendingConnections.removeAll()
            self.connectedClients.removeAll()
            self.receiveBuffers.removeAll()
        }
    }

    // MARK: - Connection Approval

    func approveConnection(deviceId: String) {
        runOnQueue { [weak self] in
            guard let self = self else { return }
            guard let pendingInfo = self.pendingConnections.removeValue(forKey: deviceId) else {
                print("[NetworkServer] No pending connection for deviceId: \(deviceId)")
                return
            }

            // Create connected client info
            let clientInfo = ConnectedClientInfo(
                connection: pendingInfo.connection,
                deviceName: pendingInfo.deviceName,
                deviceId: deviceId,
                connectedAt: Date(),
                lastHeartbeat: Date()
            )

            self.connectedClients[deviceId] = clientInfo

            // Send approval response
            let response = ConnectionResponseMessage(approved: true)
            self.sendControlMessage(response, to: pendingInfo.connection)

            print("[NetworkServer] Approved connection from: \(pendingInfo.deviceName)")

            notifyOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.networkServer(self, clientDidConnect: clientInfo)
            }
        }
    }

    func denyConnection(deviceId: String) {
        runOnQueue { [weak self] in
            guard let self = self else { return }
            guard let pendingInfo = self.pendingConnections.removeValue(forKey: deviceId) else {
                print("[NetworkServer] No pending connection for deviceId: \(deviceId)")
                return
            }

            // Send denial response
            let response = ConnectionResponseMessage(approved: false)
            self.sendControlMessage(response, to: pendingInfo.connection)

            // Close connection after a short delay to ensure message is sent
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                pendingInfo.connection.cancel()
            }

            print("[NetworkServer] Denied connection from: \(pendingInfo.deviceName)")
        }
    }

    func disconnectClient(deviceId: String, reason: DisconnectReason = .userRequested) {
        runOnQueue { [weak self] in
            self?.disconnectClientOnQueue(deviceId: deviceId, reason: reason)
        }
    }

    func disconnectAllClients(reason: DisconnectReason = .serverClosed) {
        runOnQueue { [weak self] in
            guard let self = self else { return }
            let clientIds = Array(self.connectedClients.keys)
            for deviceId in clientIds {
                self.disconnectClientOnQueue(deviceId: deviceId, reason: reason)
            }
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

    private func pendingConnectionEntry(for connection: NWConnection) -> (deviceId: String, info: PendingConnectionInfo)? {
        pendingConnections.first { $0.value.connection === connection }
            .map { (deviceId: $0.key, info: $0.value) }
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

        receiveBuffers[ObjectIdentifier(connection)] = Data()
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
            let length = buffer.prefix(headerSize).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
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
        // Check if already connected
        if connectedClients[request.deviceId] != nil {
            print("[NetworkServer] Device already connected: \(request.deviceName)")
            return
        }

        // PSK validated through TLS - auto-approve all connections
        print("[NetworkServer] PSK validated, auto-approving: \(request.deviceName)")
        autoApproveConnection(request: request, connection: connection)
    }

    private func autoApproveConnection(request: ConnectionRequestMessage, connection: NWConnection) {
        // Create connected client info
        let clientInfo = ConnectedClientInfo(
            connection: connection,
            deviceName: request.deviceName,
            deviceId: request.deviceId,
            connectedAt: Date(),
            lastHeartbeat: Date()
        )

        connectedClients[request.deviceId] = clientInfo

        // Send approval response
        let response = ConnectionResponseMessage(approved: true)
        sendControlMessage(response, to: connection)

        print("[NetworkServer] Auto-approved connection from: \(request.deviceName)")

        notifyOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.networkServer(self, clientDidConnect: clientInfo)
        }
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
        receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))

        // Check pending connections
        if let entry = pendingConnectionEntry(for: connection) {
            pendingConnections.removeValue(forKey: entry.deviceId)
            notifyOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.networkServer(self, didCancelConnectionRequest: entry.deviceId, deviceName: entry.info.deviceName)
            }
            return
        }

        // Check connected clients
        if let entry = connectedClientEntry(for: connection) {
            connectedClients.removeValue(forKey: entry.deviceId)

            notifyOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.networkServer(self, clientDidDisconnect: entry.client.deviceName, reason: .networkError)
            }
        }
    }

    private func timeoutPendingConnection(deviceId: String) {
        guard let pendingInfo = pendingConnections.removeValue(forKey: deviceId) else { return }

        // Send denial due to timeout
        let response = ConnectionResponseMessage(approved: false)
        sendControlMessage(response, to: pendingInfo.connection)

        notifyOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.networkServer(self, didCancelConnectionRequest: deviceId, deviceName: pendingInfo.deviceName)
        }

        queue.asyncAfter(deadline: .now() + 0.5) {
            pendingInfo.connection.cancel()
        }

        print("[NetworkServer] Connection request timed out: \(pendingInfo.deviceName)")
    }

    private func isApprovedConnection(_ connection: NWConnection) -> Bool {
        connectedClientEntry(for: connection) != nil
    }

    private func sendControlMessage(_ message: any ControlMessage, to connection: NWConnection) {
        sendFramed(message.encode(), to: connection) { error in
            if let error = error {
                print("[NetworkServer] Failed to send control message: \(error.localizedDescription)")
            }
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
