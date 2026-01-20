import Foundation

// MARK: - Message Types
enum MessageType: UInt8 {
    case mouseMove = 0x01
    case click = 0x02
    case scroll = 0x03
    case key = 0x04
    case text = 0x05
}

// MARK: - Control Message Types (0xF0-0xFF)
enum ControlMessageType: UInt8 {
    case connectionRequest = 0xF0
    case connectionApproved = 0xF1
    case connectionDenied = 0xF2
    case heartbeat = 0xF3
    case heartbeatAck = 0xF4
    case disconnect = 0xF5
}

// MARK: - Disconnect Reason
enum DisconnectReason: UInt8 {
    case userRequested = 0x00
    case serverClosed = 0x01
    case timeout = 0x02
    case networkError = 0x03
    case authenticationFailed = 0x04
}

// MARK: - Click Types
enum ClickButton: UInt8 {
    case left = 0
    case right = 1
    case middle = 2
}

enum ClickAction: UInt8 {
    case down = 0
    case up = 1
    case click = 2
}

// MARK: - Modifier Keys
struct ModifierFlags: OptionSet {
    let rawValue: UInt8

    static let command = ModifierFlags(rawValue: 1 << 0)
    static let option = ModifierFlags(rawValue: 1 << 1)
    static let control = ModifierFlags(rawValue: 1 << 2)
    static let shift = ModifierFlags(rawValue: 1 << 3)
}

// MARK: - Message Protocol
protocol RemoteMessage {
    var type: MessageType { get }
    func encode() -> Data
    static func decode(from data: Data) -> Self?
}

// MARK: - Mouse Move Message
struct MouseMoveMessage: RemoteMessage {
    let type: MessageType = .mouseMove
    let deltaX: Int16
    let deltaY: Int16

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: deltaX.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: deltaY.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> MouseMoveMessage? {
        guard data.count >= 5,
              data[0] == MessageType.mouseMove.rawValue else { return nil }

        let deltaX = Int16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: Int16.self) })
        let deltaY = Int16(bigEndian: data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: Int16.self) })

        return MouseMoveMessage(deltaX: deltaX, deltaY: deltaY)
    }
}

// MARK: - Click Message
struct ClickMessage: RemoteMessage {
    let type: MessageType = .click
    let button: ClickButton
    let action: ClickAction

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(button.rawValue)
        data.append(action.rawValue)
        return data
    }

    static func decode(from data: Data) -> ClickMessage? {
        guard data.count >= 3,
              data[0] == MessageType.click.rawValue,
              let button = ClickButton(rawValue: data[1]),
              let action = ClickAction(rawValue: data[2]) else { return nil }

        return ClickMessage(button: button, action: action)
    }
}

// MARK: - Scroll Message
struct ScrollMessage: RemoteMessage {
    let type: MessageType = .scroll
    let deltaX: Int16
    let deltaY: Int16

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: deltaX.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: deltaY.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> ScrollMessage? {
        guard data.count >= 5,
              data[0] == MessageType.scroll.rawValue else { return nil }

        let deltaX = Int16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: Int16.self) })
        let deltaY = Int16(bigEndian: data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: Int16.self) })

        return ScrollMessage(deltaX: deltaX, deltaY: deltaY)
    }
}

// MARK: - Key Message
struct KeyMessage: RemoteMessage {
    let type: MessageType = .key
    let keyCode: UInt16
    let modifiers: ModifierFlags
    let isDown: Bool

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: keyCode.bigEndian) { Array($0) })
        data.append(modifiers.rawValue)
        data.append(isDown ? 1 : 0)
        return data
    }

    static func decode(from data: Data) -> KeyMessage? {
        guard data.count >= 5,
              data[0] == MessageType.key.rawValue else { return nil }

        let keyCode = UInt16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self) })
        let modifiers = ModifierFlags(rawValue: data[3])
        let isDown = data[4] == 1

        return KeyMessage(keyCode: keyCode, modifiers: modifiers, isDown: isDown)
    }
}

// MARK: - Text Message
struct TextMessage: RemoteMessage {
    let type: MessageType = .text
    let text: String

    static let maxLength = 255

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        let textData = text.data(using: .utf8) ?? Data()
        data.append(UInt8(min(textData.count, Self.maxLength)))
        data.append(textData.prefix(Self.maxLength))
        return data
    }

    static func decode(from data: Data) -> TextMessage? {
        guard data.count >= 2,
              data[0] == MessageType.text.rawValue else { return nil }

        let length = Int(data[1])
        guard data.count >= 2 + length else { return nil }

        let textData = data.subdata(in: 2..<(2 + length))
        guard let text = String(data: textData, encoding: .utf8) else { return nil }

        return TextMessage(text: text)
    }
}

// MARK: - Message Decoder
struct MessageDecoder {
    static func decode(from data: Data) -> (any RemoteMessage)? {
        guard let firstByte = data.first,
              let type = MessageType(rawValue: firstByte) else { return nil }

        switch type {
        case .mouseMove:
            return MouseMoveMessage.decode(from: data)
        case .click:
            return ClickMessage.decode(from: data)
        case .scroll:
            return ScrollMessage.decode(from: data)
        case .key:
            return KeyMessage.decode(from: data)
        case .text:
            return TextMessage.decode(from: data)
        }
    }
}

// MARK: - Service Constants
enum ServiceConstants {
    static let serviceType = "_deskpad._tcp"
    static let serviceDomain = "local."
    static let defaultPort: UInt16 = 54321
}

// MARK: - Control Message Protocol
protocol ControlMessage {
    var controlType: ControlMessageType { get }
    func encode() -> Data
    static func decode(from data: Data) -> Self?
}

// MARK: - Connection Request Message
struct ConnectionRequestMessage: ControlMessage {
    let controlType: ControlMessageType = .connectionRequest
    let deviceName: String
    let deviceId: String

    static let maxNameLength = 64
    static let deviceIdLength = 36 // UUID string length

    init(deviceName: String, deviceId: String) {
        self.deviceName = deviceName
        self.deviceId = deviceId
    }

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)

        // Device name (length prefix + UTF8)
        let nameData = deviceName.data(using: .utf8) ?? Data()
        data.append(UInt8(min(nameData.count, Self.maxNameLength)))
        data.append(nameData.prefix(Self.maxNameLength))

        // Device ID (fixed length UUID)
        let idData = deviceId.data(using: .utf8) ?? Data()
        data.append(idData.prefix(Self.deviceIdLength))

        return data
    }

    static func decode(from data: Data) -> ConnectionRequestMessage? {
        guard data.count >= 2,
              data[0] == ControlMessageType.connectionRequest.rawValue else { return nil }

        let nameLength = Int(data[1])
        guard data.count >= 2 + nameLength + Self.deviceIdLength else { return nil }

        let nameData = data.subdata(in: 2..<(2 + nameLength))
        guard let deviceName = String(data: nameData, encoding: .utf8) else { return nil }

        let idStart = 2 + nameLength
        let idData = data.subdata(in: idStart..<(idStart + Self.deviceIdLength))
        guard let deviceId = String(data: idData, encoding: .utf8) else { return nil }

        return ConnectionRequestMessage(deviceName: deviceName, deviceId: deviceId)
    }
}

// MARK: - Connection Response Message
struct ConnectionResponseMessage: ControlMessage {
    let controlType: ControlMessageType

    init(approved: Bool) {
        self.controlType = approved ? .connectionApproved : .connectionDenied
    }

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)
        return data
    }

    static func decode(from data: Data) -> ConnectionResponseMessage? {
        guard let firstByte = data.first else { return nil }

        if firstByte == ControlMessageType.connectionApproved.rawValue {
            return ConnectionResponseMessage(approved: true)
        } else if firstByte == ControlMessageType.connectionDenied.rawValue {
            return ConnectionResponseMessage(approved: false)
        }

        return nil
    }
}

// MARK: - Heartbeat Message
struct HeartbeatMessage: ControlMessage {
    let controlType: ControlMessageType = .heartbeat
    let timestamp: UInt32

    init(timestamp: UInt32 = UInt32(Date().timeIntervalSince1970)) {
        self.timestamp = timestamp
    }

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> HeartbeatMessage? {
        guard data.count >= 5,
              data[0] == ControlMessageType.heartbeat.rawValue else { return nil }

        let timestamp = UInt32(bigEndian: data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) })
        return HeartbeatMessage(timestamp: timestamp)
    }
}

// MARK: - Heartbeat Ack Message
struct HeartbeatAckMessage: ControlMessage {
    let controlType: ControlMessageType = .heartbeatAck
    let timestamp: UInt32

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> HeartbeatAckMessage? {
        guard data.count >= 5,
              data[0] == ControlMessageType.heartbeatAck.rawValue else { return nil }

        let timestamp = UInt32(bigEndian: data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) })
        return HeartbeatAckMessage(timestamp: timestamp)
    }
}

// MARK: - Disconnect Message
struct DisconnectMessage: ControlMessage {
    let controlType: ControlMessageType = .disconnect
    let reason: DisconnectReason

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)
        data.append(reason.rawValue)
        return data
    }

    static func decode(from data: Data) -> DisconnectMessage? {
        guard data.count >= 2,
              data[0] == ControlMessageType.disconnect.rawValue,
              let reason = DisconnectReason(rawValue: data[1]) else { return nil }

        return DisconnectMessage(reason: reason)
    }
}

// MARK: - Control Message Decoder
struct ControlMessageDecoder {
    static func decode(from data: Data) -> (any ControlMessage)? {
        guard let firstByte = data.first,
              let type = ControlMessageType(rawValue: firstByte) else { return nil }

        switch type {
        case .connectionRequest:
            return ConnectionRequestMessage.decode(from: data)
        case .connectionApproved, .connectionDenied:
            return ConnectionResponseMessage.decode(from: data)
        case .heartbeat:
            return HeartbeatMessage.decode(from: data)
        case .heartbeatAck:
            return HeartbeatAckMessage.decode(from: data)
        case .disconnect:
            return DisconnectMessage.decode(from: data)
        }
    }

    static func isControlMessage(_ data: Data) -> Bool {
        guard let firstByte = data.first else { return false }
        return firstByte >= 0xF0
    }

}
