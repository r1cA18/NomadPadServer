import Foundation

private extension Data {
    func readBigEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T? {
        guard offset >= 0, count >= offset + MemoryLayout<T>.size else { return nil }
        return withUnsafeBytes { bytes in
            T(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: type))
        }
    }
}

private extension String {
    func utf8Prefix(maxByteCount: Int) -> Data {
        var result = Data()
        for character in self {
            let characterData = Data(String(character).utf8)
            guard result.count + characterData.count <= maxByteCount else { break }
            result.append(characterData)
        }
        return result
    }
}

// MARK: - Message Types
enum MessageType: UInt8 {
    case mouseMove = 0x01
    case click = 0x02
    case scroll = 0x03
    case key = 0x04
    case text = 0x05
    case volume = 0x06
    case modifiedScroll = 0x07
    // v3.0 system integration (iOS -> Mac)
    case volumeSet = 0x08
    case brightnessSet = 0x09
    case muteToggle = 0x0A
    case mediaCommand = 0x0B
    case sleepCommand = 0x0C
    // v3.0 system integration (Mac -> iOS)
    case volumeStatus = 0x0D
    case brightnessStatus = 0x0E
}

// MARK: - Media Commands
enum MediaCommand: UInt8 {
    case playPause = 2
    case next = 4
    case previous = 5
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

        guard let deltaX = data.readBigEndian(at: 1, as: Int16.self),
              let deltaY = data.readBigEndian(at: 3, as: Int16.self) else { return nil }

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

        guard let deltaX = data.readBigEndian(at: 1, as: Int16.self),
              let deltaY = data.readBigEndian(at: 3, as: Int16.self) else { return nil }

        return ScrollMessage(deltaX: deltaX, deltaY: deltaY)
    }
}

// MARK: - Modified Scroll Message
struct ModifiedScrollMessage: RemoteMessage {
    let type: MessageType = .modifiedScroll
    let deltaX: Int16
    let deltaY: Int16
    let modifiers: ModifierFlags

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: deltaX.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: deltaY.bigEndian) { Array($0) })
        data.append(modifiers.rawValue)
        return data
    }

    static func decode(from data: Data) -> ModifiedScrollMessage? {
        guard data.count >= 6,
              data[0] == MessageType.modifiedScroll.rawValue else { return nil }

        guard let deltaX = data.readBigEndian(at: 1, as: Int16.self),
              let deltaY = data.readBigEndian(at: 3, as: Int16.self) else { return nil }
        let modifiers = ModifierFlags(rawValue: data[5])

        return ModifiedScrollMessage(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
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

        guard let keyCode = data.readBigEndian(at: 1, as: UInt16.self) else { return nil }
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
        let textData = text.utf8Prefix(maxByteCount: Self.maxLength)
        data.append(UInt8(textData.count))
        data.append(textData)
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

    /// Splits `text` into messages that each fit the wire limit, so long input
    /// arrives in order without truncation. Chunks break between Characters;
    /// only a single Character larger than the limit is split by scalar.
    static func chunked(_ text: String) -> [TextMessage] {
        var messages: [TextMessage] = []
        var current = ""
        var currentBytes = 0

        func append(_ piece: String, bytes: Int) {
            if currentBytes + bytes > maxLength {
                messages.append(TextMessage(text: current))
                current = ""
                currentBytes = 0
            }
            current.append(piece)
            currentBytes += bytes
        }

        for character in text {
            let bytes = String(character).utf8.count
            if bytes <= maxLength {
                append(String(character), bytes: bytes)
            } else {
                for scalar in character.unicodeScalars {
                    append(String(scalar), bytes: String(scalar).utf8.count)
                }
            }
        }
        if !current.isEmpty {
            messages.append(TextMessage(text: current))
        }
        return messages
    }
}

// MARK: - Volume Message
struct VolumeMessage: RemoteMessage {
    let type: MessageType = .volume
    let delta: Int16

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: delta.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> VolumeMessage? {
        guard data.count >= 3,
              data[0] == MessageType.volume.rawValue else { return nil }

        guard let delta = data.readBigEndian(at: 1, as: Int16.self) else { return nil }
        return VolumeMessage(delta: delta)
    }
}

// MARK: - Volume Set Message
struct VolumeSetMessage: RemoteMessage {
    let type: MessageType = .volumeSet
    let value: Float

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> VolumeSetMessage? {
        guard data.count >= 5,
              data[0] == MessageType.volumeSet.rawValue,
              let bits = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }

        return VolumeSetMessage(value: Float(bitPattern: bits))
    }
}

// MARK: - Brightness Set Message
struct BrightnessSetMessage: RemoteMessage {
    let type: MessageType = .brightnessSet
    let value: Float

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> BrightnessSetMessage? {
        guard data.count >= 5,
              data[0] == MessageType.brightnessSet.rawValue,
              let bits = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }

        return BrightnessSetMessage(value: Float(bitPattern: bits))
    }
}

// MARK: - Mute Toggle Message
struct MuteToggleMessage: RemoteMessage {
    let type: MessageType = .muteToggle

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        return data
    }

    static func decode(from data: Data) -> MuteToggleMessage? {
        guard data.count >= 1,
              data[0] == MessageType.muteToggle.rawValue else { return nil }

        return MuteToggleMessage()
    }
}

// MARK: - Media Command Message
struct MediaCommandMessage: RemoteMessage {
    let type: MessageType = .mediaCommand
    let command: MediaCommand

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(command.rawValue)
        return data
    }

    static func decode(from data: Data) -> MediaCommandMessage? {
        guard data.count >= 2,
              data[0] == MessageType.mediaCommand.rawValue,
              let command = MediaCommand(rawValue: data[1]) else { return nil }

        return MediaCommandMessage(command: command)
    }
}

// MARK: - Sleep Command Message
struct SleepCommandMessage: RemoteMessage {
    let type: MessageType = .sleepCommand

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        return data
    }

    static func decode(from data: Data) -> SleepCommandMessage? {
        guard data.count >= 1,
              data[0] == MessageType.sleepCommand.rawValue else { return nil }

        return SleepCommandMessage()
    }
}

// MARK: - Volume Status Message
struct VolumeStatusMessage: RemoteMessage {
    let type: MessageType = .volumeStatus
    let value: Float
    let muted: Bool

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) })
        data.append(muted ? 1 : 0)
        return data
    }

    static func decode(from data: Data) -> VolumeStatusMessage? {
        guard data.count >= 6,
              data[0] == MessageType.volumeStatus.rawValue,
              let bits = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }
        let muted = data[5] == 1

        return VolumeStatusMessage(value: Float(bitPattern: bits), muted: muted)
    }
}

// MARK: - Brightness Status Message
struct BrightnessStatusMessage: RemoteMessage {
    let type: MessageType = .brightnessStatus
    let value: Float

    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) })
        return data
    }

    static func decode(from data: Data) -> BrightnessStatusMessage? {
        guard data.count >= 5,
              data[0] == MessageType.brightnessStatus.rawValue,
              let bits = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }

        return BrightnessStatusMessage(value: Float(bitPattern: bits))
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
        case .volume:
            return VolumeMessage.decode(from: data)
        case .modifiedScroll:
            return ModifiedScrollMessage.decode(from: data)
        case .volumeSet:
            return VolumeSetMessage.decode(from: data)
        case .brightnessSet:
            return BrightnessSetMessage.decode(from: data)
        case .muteToggle:
            return MuteToggleMessage.decode(from: data)
        case .mediaCommand:
            return MediaCommandMessage.decode(from: data)
        case .sleepCommand:
            return SleepCommandMessage.decode(from: data)
        case .volumeStatus:
            return VolumeStatusMessage.decode(from: data)
        case .brightnessStatus:
            return BrightnessStatusMessage.decode(from: data)
        }
    }
}

// MARK: - Service Constants
enum ServiceConstants {
    // Kept for compatibility with released Server and Remote builds.
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
    let deviceToken: String

    static let maxNameLength = 64
    static let deviceIdLength = 36 // UUID string length
    static let deviceTokenLength = 64 // 32 random bytes encoded as hex

    init(deviceName: String, deviceId: String, deviceToken: String = "") {
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.deviceToken = deviceToken
    }

    func encode() -> Data {
        var data = Data()
        data.append(controlType.rawValue)

        // Device name (length prefix + UTF8)
        let nameData = deviceName.utf8Prefix(maxByteCount: Self.maxNameLength)
        data.append(UInt8(nameData.count))
        data.append(nameData)

        // Device ID (fixed length UUID)
        let idData = deviceId.data(using: .utf8) ?? Data()
        data.append(idData.prefix(Self.deviceIdLength))

        // Device token (fixed length hex string)
        let tokenData = deviceToken.data(using: .utf8) ?? Data()
        data.append(tokenData.prefix(Self.deviceTokenLength))

        return data
    }

    static func decode(from data: Data) -> ConnectionRequestMessage? {
        guard data.count >= 2,
              data[0] == ControlMessageType.connectionRequest.rawValue else { return nil }

        let nameLength = Int(data[1])
        guard nameLength <= Self.maxNameLength,
              data.count >= 2 + nameLength + Self.deviceIdLength else { return nil }

        let nameData = data.subdata(in: 2..<(2 + nameLength))
        guard let deviceName = String(data: nameData, encoding: .utf8) else { return nil }

        let idStart = 2 + nameLength
        let idData = data.subdata(in: idStart..<(idStart + Self.deviceIdLength))
        guard let deviceId = String(data: idData, encoding: .utf8) else { return nil }

        let tokenStart = idStart + Self.deviceIdLength
        let deviceToken: String
        if data.count >= tokenStart + Self.deviceTokenLength {
            let tokenData = data.subdata(in: tokenStart..<(tokenStart + Self.deviceTokenLength))
            guard let decodedToken = String(data: tokenData, encoding: .utf8) else { return nil }
            deviceToken = decodedToken
        } else {
            // Released clients did not include a device token.
            deviceToken = ""
        }

        return ConnectionRequestMessage(deviceName: deviceName, deviceId: deviceId, deviceToken: deviceToken)
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

        guard let timestamp = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }
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

        guard let timestamp = data.readBigEndian(at: 1, as: UInt32.self) else { return nil }
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
