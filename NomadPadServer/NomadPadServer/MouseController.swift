import AppKit
import CoreGraphics
import Carbon.HIToolbox
import ApplicationServices
import CoreAudio
import Foundation

/// Controls mouse, keyboard, and system shortcuts on macOS
class MouseController {

    // MARK: - Properties

    private var currentPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // Buttons and keys this controller has pressed but not yet released, plus a
    // generation that invalidates scheduled events. Both are only touched on
    // eventQueue. releaseAllInput() uses them to end a session cleanly.
    private var pressedButtons: Set<ClickButton> = []
    private var pressedKeys: [UInt16: ModifierFlags] = [:]
    private var inputGeneration = 0
    private var isLeftButtonDown: Bool { pressedButtons.contains(.left) }
    private var lastCompletedClick: CompletedClick?

    private let clickDownUpDelay: TimeInterval = 0.045
    private let typeCharInterval: TimeInterval = 0.005
    private let controlArrowKeyDelay: TimeInterval = 0.05
    private let controlArrowReleaseDelay: TimeInterval = 0.03
    private let doubleClickInterval: TimeInterval = 0.35
    private let doubleClickMovementTolerance: CGFloat = 6.0
    private let volumeFallbackStep: CGFloat = 12
    private var volumeFallbackAccumulator: CGFloat = 0

    // Invoked whenever the system output volume or mute state changes, so the
    // connected Remote can mirror the current value. Delivered off the main
    // thread; callers marshal as needed.
    var onVolumeStatusChanged: ((_ volume: Float, _ muted: Bool) -> Void)?

    // Listener blocks kept alive so they can be removed. AudioObject listener
    // removal requires the exact block that was registered.
    private var monitoredDeviceID: AudioDeviceID?
    private var deviceVolumeListener: AudioObjectPropertyListenerBlock?
    private var deviceMuteListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    // All CGEvent posting runs on this serial queue to keep it off the main
    // thread and to preserve the order of incoming input events. Delays between
    // steps are expressed with a running deadline rather than blocking sleeps.
    private let eventQueue = DispatchQueue(label: "com.r1ca18.nomadpad.input", qos: .userInteractive)
    private var scheduleCursor = DispatchTime.now()

    typealias EventPoster = (CGEvent, CGEventTapLocation) -> Void
    private let postEvent: EventPoster

    private struct CompletedClick {
        let button: ClickButton
        let position: CGPoint
        let timestamp: Date
        let clickState: Int64
    }

    // Shared storage so the paired down/up steps of a synthesized click agree
    // on the position and click state computed when the button went down.
    private final class ClickContext {
        var position: CGPoint = .zero
        var clickState: Int64 = 1
    }

    // Shared state across the scheduled steps of a Control+Arrow sequence. Once
    // AppleScript handles the shortcut, the remaining CGEvent steps are skipped.
    private final class ControlArrowContext {
        var handled = false
        var source: CGEventSource?
    }

    // MARK: - Key Codes

    // Exposed (internal) so tests can verify the real values instead of
    // duplicating them.
    enum KeyCode {
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let downArrow: UInt16 = 0x7D
        static let upArrow: UInt16 = 0x7E
        static let control: UInt16 = 0x3B
        static let shift: UInt16 = 0x38
        static let option: UInt16 = 0x3A
        static let command: UInt16 = 0x37
    }

    let arrowKeyCodes: Set<UInt16> = [
        KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow
    ]

    // MARK: - Initialization

    init(postEvent: @escaping EventPoster = { $0.post(tap: $1) }) {
        self.postEvent = postEvent
        if !AXIsProcessTrusted() {
            print("[MouseController] WARNING: Accessibility permission not granted")
        }
    }

    // MARK: - Event Scheduling

    /// Schedules `work` on the serial event queue. `leadDelay` is the gap after
    /// the previously scheduled event, letting sequences keep their spacing
    /// without blocking. Reserving the deadline at call time (rather than when
    /// the prior step runs) keeps later events ordered after earlier ones.
    private func scheduleEvent(leadDelay: TimeInterval = 0, _ work: @escaping () -> Void) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            let generation = self.inputGeneration
            let now = DispatchTime.now()
            if self.scheduleCursor < now {
                self.scheduleCursor = now
            }
            self.scheduleCursor = self.scheduleCursor + leadDelay
            self.eventQueue.asyncAfter(deadline: self.scheduleCursor) { [weak self] in
                // Events scheduled before releaseAllInput() belong to an ended session.
                guard let self, self.inputGeneration == generation else { return }
                work()
            }
        }
    }

    // MARK: - Mouse Movement

    func moveMouse(deltaX: CGFloat, deltaY: CGFloat) {
        scheduleEvent { [weak self] in
            guard let self = self else { return }
            let position = self.currentPosition
            let newPosition = CGPoint(x: position.x + deltaX, y: position.y + deltaY)

            if self.isLeftButtonDown {
                // Drag mode - move cursor then send drag event
                CGWarpMouseCursorPosition(newPosition)
                let dragEvent = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: .leftMouseDragged,
                    mouseCursorPosition: newPosition,
                    mouseButton: .left
                )
                self.configureMouseEvent(dragEvent, clickState: 1, pressure: 1.0)
                self.post(dragEvent, .cghidEventTap)
                return
            }

            // Normal move - warp position and post move event for hover effects
            CGWarpMouseCursorPosition(newPosition)

            // Post mouse move event to trigger hover effects and unhide cursor
            let moveEvent = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .mouseMoved,
                mouseCursorPosition: newPosition,
                mouseButton: .left
            )
            self.post(moveEvent, .cghidEventTap)
        }
    }

    // MARK: - Click

    func click(button: ClickButton, action: ClickAction) {
        let (cgButton, downType, upType) = buttonTypes(for: button)

        switch action {
        case .down:
            scheduleEvent { [weak self] in
                guard let self = self else { return }
                self.pressedButtons.insert(button)
                self.lastCompletedClick = nil
                let position = self.currentPosition
                let event = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: downType,
                    mouseCursorPosition: position,
                    mouseButton: cgButton
                )
                self.configureMouseEvent(event, clickState: 1, pressure: button == .left ? 1.0 : 0.0)
                self.post(event, .cghidEventTap)
            }

        case .up:
            scheduleEvent { [weak self] in
                guard let self = self else { return }
                self.pressedButtons.remove(button)
                self.lastCompletedClick = nil
                self.postButtonUp(button, at: self.currentPosition, source: CGEventSource(stateID: .hidSystemState))
            }

        case .click:
            let context = ClickContext()
            scheduleEvent { [weak self] in
                guard let self = self else { return }
                let position = self.currentPosition
                let clickState = self.resolvedClickState(for: button, at: position)
                context.position = position
                context.clickState = clickState
                let downEvent = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: downType,
                    mouseCursorPosition: position,
                    mouseButton: cgButton
                )
                self.pressedButtons.insert(button)
                self.configureMouseEvent(downEvent, clickState: clickState, pressure: button == .left ? 1.0 : 0.0)
                self.post(downEvent, .cghidEventTap)
            }
            scheduleEvent(leadDelay: clickDownUpDelay) { [weak self] in
                guard let self = self else { return }
                let upEvent = CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: upType,
                    mouseCursorPosition: context.position,
                    mouseButton: cgButton
                )
                self.configureMouseEvent(upEvent, clickState: context.clickState, pressure: 0.0)
                self.post(upEvent, .cghidEventTap)
                self.lastCompletedClick = CompletedClick(
                    button: button,
                    position: context.position,
                    timestamp: Date(),
                    clickState: context.clickState
                )
                self.pressedButtons.remove(button)
            }
        }
    }

    private func buttonTypes(for button: ClickButton) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case .left:
            return (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            return (.right, .rightMouseDown, .rightMouseUp)
        case .middle:
            return (.center, .otherMouseDown, .otherMouseUp)
        }
    }

    private func resolvedClickState(for button: ClickButton, at position: CGPoint) -> Int64 {
        guard let lastCompletedClick else { return 1 }
        guard lastCompletedClick.button == button else { return 1 }
        guard Date().timeIntervalSince(lastCompletedClick.timestamp) <= doubleClickInterval else { return 1 }

        let distance = hypot(
            position.x - lastCompletedClick.position.x,
            position.y - lastCompletedClick.position.y
        )
        guard distance <= doubleClickMovementTolerance else { return 1 }

        return min(lastCompletedClick.clickState + 1, 2)
    }

    private func configureMouseEvent(_ event: CGEvent?, clickState: Int64, pressure: Double) {
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.setDoubleValueField(.mouseEventPressure, value: pressure)
        event?.flags = []
    }

    // MARK: - Scroll

    func scroll(deltaX: CGFloat, deltaY: CGFloat, modifiers: ModifierFlags = []) {
        scheduleEvent { [weak self] in
            guard let self = self else { return }
            let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: Int32(deltaX),
                wheel3: 0
            )
            scrollEvent?.flags = self.buildEventFlags(from: modifiers)
            self.post(scrollEvent, .cghidEventTap)
        }
    }

    // MARK: - Volume

    func adjustVolume(delta: CGFloat) {
        scheduleEvent { [weak self] in
            guard let self = self else { return }
            if let deviceID = self.defaultOutputDeviceID(),
               let currentVolume = self.outputVolumeScalar(for: deviceID) {
                let nextVolume = min(max(currentVolume + Float32(delta) * 0.003, 0), 1)
                if self.setOutputVolumeScalar(nextVolume, for: deviceID) {
                    self.volumeFallbackAccumulator = 0
                    return
                }
            }

            self.volumeFallbackAccumulator += delta

            while abs(self.volumeFallbackAccumulator) >= self.volumeFallbackStep {
                let isIncreasing = self.volumeFallbackAccumulator > 0
                self.postVolumeKey(isIncreasing: isIncreasing)
                self.volumeFallbackAccumulator += isIncreasing ? -self.volumeFallbackStep : self.volumeFallbackStep
            }
        }
    }

    private func postVolumeKey(isIncreasing: Bool) {
        postSystemDefinedKey(keyCode: isIncreasing ? 0 : 1)
    }

    /// Posts a system-defined key press (down then up) using the same NSEvent
    /// pattern as the volume keys. Used for volume and media transport keys.
    private func postSystemDefinedKey(keyCode: Int32) {
        for keyState: Int32 in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((keyCode << 16) | (keyState << 8)),
                data2: -1
            )
            post(event?.cgEvent, .cghidEventTap)
        }
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func outputVolumeScalar(for deviceID: AudioDeviceID) -> Float32? {
        if let masterVolume = volumeScalar(for: deviceID, channel: kAudioObjectPropertyElementMain) {
            return masterVolume
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        let volumes = channels.compactMap { volumeScalar(for: deviceID, channel: $0) }
        guard !volumes.isEmpty else { return nil }

        return volumes.reduce(0, +) / Float32(volumes.count)
    }

    @discardableResult
    private func setOutputVolumeScalar(_ volume: Float32, for deviceID: AudioDeviceID) -> Bool {
        if setVolumeScalar(volume, for: deviceID, channel: kAudioObjectPropertyElementMain) {
            return true
        }

        let leftSet = setVolumeScalar(volume, for: deviceID, channel: AudioObjectPropertyElement(1))
        let rightSet = setVolumeScalar(volume, for: deviceID, channel: AudioObjectPropertyElement(2))
        return leftSet || rightSet
    }

    private func volumeScalar(for deviceID: AudioDeviceID, channel: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(channel: channel)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }

        return volume
    }

    private func setVolumeScalar(_ volume: Float32, for deviceID: AudioDeviceID, channel: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(channel: channel)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var newVolume = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newVolume) == noErr
    }

    private func volumeAddress(channel: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }

    // MARK: - Absolute Volume / Mute

    /// Sets the system output volume to an absolute scalar (0.0-1.0). The
    /// property listener re-broadcasts the applied value, so no manual status
    /// emit is needed here.
    func setVolume(_ value: Float) {
        scheduleEvent { [weak self] in
            guard let self, let deviceID = self.defaultOutputDeviceID() else { return }
            let clamped = min(max(value, 0), 1)
            self.setOutputVolumeScalar(clamped, for: deviceID)
        }
    }

    func toggleMute() {
        scheduleEvent { [weak self] in
            guard let self, let deviceID = self.defaultOutputDeviceID() else { return }
            let current = self.outputMuted(for: deviceID) ?? false
            self.setOutputMuted(!current, for: deviceID)
            // Mute changes do not always fire the scalar listener, so emit the
            // resulting status explicitly.
            self.emitVolumeStatus(for: deviceID)
        }
    }

    /// Reads the current output volume and mute state. Returns nil when no
    /// default output device is available.
    func currentVolumeStatus() -> (volume: Float, muted: Bool)? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        let volume = outputVolumeScalar(for: deviceID) ?? 0
        let muted = outputMuted(for: deviceID) ?? false
        return (volume, muted)
    }

    private func emitVolumeStatus(for deviceID: AudioDeviceID) {
        let volume = outputVolumeScalar(for: deviceID) ?? 0
        let muted = outputMuted(for: deviceID) ?? false
        onVolumeStatusChanged?(volume, muted)
    }

    private func muteAddress(channel: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }

    private func outputMuted(for deviceID: AudioDeviceID) -> Bool? {
        let channels: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2)
        ]
        for channel in channels {
            var address = muteAddress(channel: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }

            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else { continue }
            return muted != 0
        }
        return nil
    }

    @discardableResult
    private func setOutputMuted(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        let channels: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2)
        ]
        var didSet = false
        for channel in channels {
            var address = muteAddress(channel: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }

            var isSettable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }

            var value: UInt32 = muted ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                didSet = true
                // The master mute usually covers the device; stop once it takes.
                if channel == kAudioObjectPropertyElementMain { break }
            }
        }
        return didSet
    }

    // MARK: - Volume / Mute Monitoring

    /// Starts observing output volume and mute changes on the current default
    /// output device, re-attaching when the default device changes.
    func startVolumeMonitoring() {
        scheduleEvent { [weak self] in
            guard let self else { return }
            self.attachDefaultDeviceListener()
            self.attachDeviceListeners(for: self.defaultOutputDeviceID())
        }
    }

    private func attachDefaultDeviceListener() {
        guard defaultDeviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.detachDeviceListeners()
            self.attachDeviceListeners(for: self.defaultOutputDeviceID())
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            eventQueue,
            block
        )
    }

    private func attachDeviceListeners(for deviceID: AudioDeviceID?) {
        guard let deviceID else { return }
        monitoredDeviceID = deviceID

        let onChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.emitVolumeStatus(for: deviceID)
        }

        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        deviceVolumeListener = onChange
        AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddr, eventQueue, onChange)

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        deviceMuteListener = onChange
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, eventQueue, onChange)

        // Emit the current value for the freshly attached device.
        emitVolumeStatus(for: deviceID)
    }

    private func detachDeviceListeners() {
        guard let deviceID = monitoredDeviceID else { return }

        if let listener = deviceVolumeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, eventQueue, listener)
        }
        if let listener = deviceMuteListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, eventQueue, listener)
        }

        deviceVolumeListener = nil
        deviceMuteListener = nil
        monitoredDeviceID = nil
    }

    // MARK: - Media Transport

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h, defined locally
    // because those macros are not imported into Swift.
    private enum MediaKeyCode {
        static let play: Int32 = 16    // NX_KEYTYPE_PLAY
        static let next: Int32 = 17    // NX_KEYTYPE_NEXT
        static let previous: Int32 = 18 // NX_KEYTYPE_PREVIOUS
    }

    func sendMediaCommand(_ command: MediaCommand) {
        let keyCode: Int32
        switch command {
        case .playPause: keyCode = MediaKeyCode.play
        case .next: keyCode = MediaKeyCode.next
        case .previous: keyCode = MediaKeyCode.previous
        }
        scheduleEvent { [weak self] in
            self?.postSystemDefinedKey(keyCode: keyCode)
        }
    }

    // MARK: - Brightness (DisplayServices, private API)

    func setBrightness(_ value: Float) {
        guard let setFn = Self.displayServices.setBrightness else { return }
        scheduleEvent {
            let clamped = min(max(value, 0), 1)
            _ = setFn(CGMainDisplayID(), clamped)
        }
    }

    /// Reads the current main-display brightness. Returns nil when the private
    /// symbol is unavailable or the read fails, so the caller can hide the
    /// brightness control instead of showing a wrong value.
    func currentBrightness() -> Float? {
        guard let getFn = Self.displayServices.getBrightness else { return nil }
        var brightness: Float = 0
        guard getFn(CGMainDisplayID(), &brightness) == 0 else { return nil }
        return brightness
    }

    // MARK: - Sleep

    /// Puts the Mac to sleep. Uses the public System Events AppleScript path
    /// (same mechanism as the Spaces shortcut) because IOPMSleepSystem needs a
    /// privileged root IOKit connection this user-level app does not have.
    func sleepSystem() {
        scheduleEvent { [weak self] in
            self?.runSleepAppleScript()
        }
    }

    private func runSleepAppleScript() {
        let script = "tell application \"System Events\" to sleep"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            print("[MouseController] Sleep AppleScript failed: \(errorInfo)")
        }
    }

    // MARK: - Keyboard

    func sendKey(keyCode: UInt16, modifiers: ModifierFlags, isDown: Bool) {
        // Control+Arrow needs special handling for Spaces switching
        if modifiers.contains(.control) && arrowKeyCodes.contains(keyCode) {
            if isDown {
                sendControlArrowSequence(keyCode: keyCode)
            }
            return
        }

        scheduleEvent { [weak self] in
            guard let self = self else { return }
            let eventSource = CGEventSource(stateID: .hidSystemState)
            let flags = self.buildEventFlags(from: modifiers)

            // Send modifier keys for modified key presses
            if !modifiers.isEmpty && isDown {
                self.sendModifierKeys(modifiers, isDown: true, source: eventSource)
            }

            // Send main key event
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown)
            keyEvent?.flags = flags
            self.post(keyEvent, .cgSessionEventTap)
            if isDown {
                self.pressedKeys[keyCode] = modifiers
            } else {
                self.pressedKeys[keyCode] = nil
            }

            // Release modifier keys
            if !modifiers.isEmpty && !isDown {
                self.sendModifierKeys(modifiers, isDown: false, source: eventSource)
            }
        }
    }

    func typeText(_ text: String) {
        for char in text {
            scheduleEvent(leadDelay: typeCharInterval) { [weak self] in
                guard let self = self else { return }
                let eventSource = CGEventSource(stateID: .hidSystemState)

                // Handle special keys
                if let keyCode = self.specialKeyCode(for: char) {
                    // Send as key event
                    let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
                    let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
                    self.post(downEvent, .cgSessionEventTap)
                    self.post(upEvent, .cgSessionEventTap)
                } else {
                    // Use Unicode string approach for regular characters
                    let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                    let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)

                    var unichar = [UniChar](String(char).utf16)
                    downEvent?.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
                    upEvent?.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)

                    self.post(downEvent, .cgSessionEventTap)
                    self.post(upEvent, .cgSessionEventTap)
                }
            }
        }
    }

    // Exposed (internal) so tests exercise this logic directly.
    func specialKeyCode(for char: Character) -> UInt16? {
        switch char {
        case "\u{7F}", "\u{08}":  // DEL, BS -> Backspace
            return 0x33
        case "\n", "\r":          // Enter/Return
            return 0x24
        case "\t":                // Tab
            return 0x30
        case "\u{1B}":            // Escape
            return 0x35
        default:
            return nil
        }
    }

    // MARK: - System Shortcuts (Spaces/Mission Control)

    private func sendControlArrowSequence(keyCode: UInt16) {
        let context = ControlArrowContext()
        let appleScriptCode = appleScriptKeyCode(for: keyCode)

        // Try AppleScript first (most reliable for Spaces switching); fall back
        // to a spaced-out CGEvent sequence only if it did not handle the key.
        scheduleEvent { [weak self] in
            guard let self = self else { return }
            if let appleScriptCode, self.sendAppleScriptControlKey(code: appleScriptCode) {
                context.handled = true
                return
            }

            let eventSource = CGEventSource(stateID: .combinedSessionState)
            context.source = eventSource
            let controlDown = CGEvent(keyboardEventSource: eventSource, virtualKey: KeyCode.control, keyDown: true)
            controlDown?.flags = .maskControl
            self.post(controlDown, .cgSessionEventTap)
            self.pressedKeys[KeyCode.control] = []
        }

        scheduleEvent(leadDelay: controlArrowKeyDelay) { [weak self] in
            guard let self, !context.handled else { return }
            let keyDown = CGEvent(keyboardEventSource: context.source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = .maskControl
            self.post(keyDown, .cgSessionEventTap)
            self.pressedKeys[keyCode] = []
        }

        scheduleEvent(leadDelay: controlArrowKeyDelay) { [weak self] in
            guard let self, !context.handled else { return }
            let keyUp = CGEvent(keyboardEventSource: context.source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = .maskControl
            self.post(keyUp, .cgSessionEventTap)
            self.pressedKeys[keyCode] = nil
        }

        scheduleEvent(leadDelay: controlArrowReleaseDelay) { [weak self] in
            guard let self, !context.handled else { return }
            let controlUp = CGEvent(keyboardEventSource: context.source, virtualKey: KeyCode.control, keyDown: false)
            self.post(controlUp, .cgSessionEventTap)
            self.pressedKeys[KeyCode.control] = nil
        }
    }

    private func appleScriptKeyCode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case KeyCode.leftArrow: return 123
        case KeyCode.rightArrow: return 124
        case KeyCode.downArrow: return 125
        case KeyCode.upArrow: return 126
        default: return nil
        }
    }

    private func sendAppleScriptControlKey(code: Int) -> Bool {
        let script = "tell application \"System Events\" to key code \(code) using control down"
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            print("[MouseController] AppleScript failed: \(errorInfo)")
            return false
        }
        return true
    }

    // MARK: - Session Release

    /// Ends the current input session: drops events that were scheduled but
    /// not yet posted, and releases any button or key still held down so a
    /// dropped connection cannot leave a drag or modifier stuck on the Mac.
    func releaseAllInput() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.inputGeneration &+= 1
            self.scheduleCursor = DispatchTime.now()
            self.lastCompletedClick = nil

            let source = CGEventSource(stateID: .hidSystemState)
            for (keyCode, modifiers) in self.pressedKeys {
                self.post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false), .cgSessionEventTap)
                self.sendModifierKeys(modifiers, isDown: false, source: source)
            }
            self.pressedKeys.removeAll()

            let position = self.currentPosition
            for button in self.pressedButtons {
                self.postButtonUp(button, at: position, source: source)
            }
            self.pressedButtons.removeAll()
        }
    }

    // MARK: - Helpers

    #if DEBUG
    /// Blocks until every event scheduled so far has run or been dropped.
    /// Used by tests that inject a recording EventPoster. Never call it from
    /// eventQueue.
    func waitForScheduledEvents() {
        var deadline = DispatchTime.now()
        eventQueue.sync { deadline = scheduleCursor }
        let done = DispatchSemaphore(value: 0)
        eventQueue.asyncAfter(deadline: deadline + .milliseconds(10)) { done.signal() }
        done.wait()
    }
    #endif

    private func postButtonUp(_ button: ClickButton, at position: CGPoint, source: CGEventSource?) {
        let (cgButton, _, upType) = buttonTypes(for: button)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: upType,
            mouseCursorPosition: position,
            mouseButton: cgButton
        )
        configureMouseEvent(event, clickState: 1, pressure: 0.0)
        post(event, .cghidEventTap)
    }

    private func post(_ event: CGEvent?, _ tap: CGEventTapLocation) {
        guard let event else { return }
        postEvent(event, tap)
    }


    private func buildEventFlags(from modifiers: ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    private func sendModifierKeys(_ modifiers: ModifierFlags, isDown: Bool, source: CGEventSource?) {
        let modifierMap: [(ModifierFlags, UInt16, CGEventFlags)] = [
            (.control, KeyCode.control, .maskControl),
            (.shift, KeyCode.shift, .maskShift),
            (.option, KeyCode.option, .maskAlternate),
            (.command, KeyCode.command, .maskCommand)
        ]

        for (flag, keyCode, eventFlag) in modifierMap {
            if modifiers.contains(flag) {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
                if isDown { event?.flags = eventFlag }
                self.post(event, .cgSessionEventTap)
            }
        }
    }

    // MARK: - DisplayServices Bridge

    // DisplayServices is a private framework, loaded once for the process
    // lifetime. Missing symbols leave the function pointers nil so brightness
    // features degrade gracefully instead of crashing.
    private static let displayServices = DisplayServicesBridge()

    final class DisplayServicesBridge {
        typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

        let setBrightness: SetBrightnessFn?
        let getBrightness: GetBrightnessFn?

        init() {
            let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
            guard let handle = dlopen(path, RTLD_LAZY) else {
                setBrightness = nil
                getBrightness = nil
                return
            }

            if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightness = unsafeBitCast(symbol, to: SetBrightnessFn.self)
            } else {
                setBrightness = nil
            }

            if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(symbol, to: GetBrightnessFn.self)
            } else {
                getBrightness = nil
            }
        }
    }

}
