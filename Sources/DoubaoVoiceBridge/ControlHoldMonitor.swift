import AppKit
import ApplicationServices
import os.log

enum ControlMonitorError: LocalizedError {
    case eventTapUnavailable
    var errorDescription: String? { "无法监听豆包快捷键，请开启“辅助功能”和“输入监控”权限" }
}

enum ShortcutEventFactory {
    static let deviceBits: [UInt16: UInt64] = [59:1,62:0x2000,56:2,60:4,58:0x20,61:0x40,55:8,54:0x10]
    static func modifierFlags(_ codes: [UInt16]) -> CGEventFlags {
        codes.reduce(CGEventFlags()) { flags, code in
            flags.union(VoiceShortcut.modifierFlags[code] ?? []).union(CGEventFlags(rawValue: deviceBits[code] ?? 0))
        }
    }
    static func events(for shortcut: VoiceShortcut, down: Bool) -> [CGEvent] {
        guard let source = CGEventSource(stateID: .privateState) else { return [] }
        var modifiers = down ? [UInt16]() : shortcut.requiredModifierCodes
        var output: [CGEvent] = []
        func append(_ code: UInt16, _ type: CGEventType, _ flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: type != .keyUp) else { return }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            output.append(event)
        }
        if down {
            for code in shortcut.requiredModifierCodes {
                modifiers.append(code)
                append(code, .flagsChanged, modifierFlags(modifiers))
            }
            if !shortcut.isModifier { append(shortcut.keyCode, .keyDown, modifierFlags(modifiers).union(shortcut.logicalFlags)) }
        } else {
            if !shortcut.isModifier { append(shortcut.keyCode, .keyUp, modifierFlags(modifiers).union(shortcut.logicalFlags)) }
            for code in shortcut.requiredModifierCodes.reversed() {
                modifiers.removeAll { $0 == code }
                append(code, .flagsChanged, modifierFlags(modifiers))
            }
        }
        return output
    }
}

// On this keyboard a short physical Fn release is followed by a hardware
// keyDown/keyUp pair with virtual key 179. It is a companion to the Fn tap,
// not a second user gesture. Only consume a pair immediately after a Fn
// release that this monitor actually captured; ordinary Fn use passes through.
struct FnCompanionEventFilter {
    private var downDeadline: TimeInterval?
    private var upDeadline: TimeInterval?

    mutating func arm(afterCapturedReleaseAt now: TimeInterval) {
        downDeadline = now + 0.30
    }

    mutating func shouldSuppress(type: CGEventType, keyCode: UInt16,
                                sourcePID: Int64, marker: Int64,
                                now: TimeInterval) -> Bool {
        if let deadline = downDeadline, now > deadline { downDeadline = nil }
        if let deadline = upDeadline, now > deadline { upDeadline = nil }
        guard keyCode == 179, sourcePID == 0, marker == 0 else { return false }
        if type == .keyDown, downDeadline != nil {
            downDeadline = nil
            upDeadline = now + 0.50
            return true
        }
        if type == .keyUp, upDeadline != nil {
            upDeadline = nil
            return true
        }
        return false
    }
}

final class ControlHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget, Bool) -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    var onConfigurationChange: ((String, Bool) -> Void)?
    private(set) var configuration: DoubaoShortcutConfiguration?
    private var configurationError: String?
    var configurationStatus: String { configuration?.status ?? configurationError ?? "正在读取豆包快捷键…" }
    private let logger = Logger(subsystem: "org.remotedictation.bridge", category: "control")
    private var gesture = HoldGestureState()
    private var trigger: VoiceShortcut?
    private var triggerAllowsHold = false
    private var triggerAllowsTap = false
    private var target: UURemoteTarget?
    private var physicalModifiers = Set<UInt16>()
    private var swallowedUps = Set<UInt16>()
    private var pendingDowns: [CGEvent] = []
    private var neutralizedModifiers: [UInt16] = []
    private var activationWork: DispatchWorkItem?
    private var focusWork: DispatchWorkItem?
    private var tapUpWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?
    private var latchedTimeout: DispatchWorkItem?
    private var focusDeadline = Date.distantPast
    private var emulationShortcut: VoiceShortcut?
    private var nativeTap = false
    private var syntheticStarted = false
    private var syntheticIsDown = false
    private var syntheticStartedAt = Date.distantPast
    private var physicalTriggerStartedAt = Date.distantPast
    private var fnCompanionFilter = FnCompanionEventFilter()
    private var settingsTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activeTapLocation: CGEventTapLocation?
    var isGestureIdle: Bool { gesture.phase == .idle && swallowedUps.isEmpty }

    init(holdThreshold: TimeInterval, targetProvider: @escaping () -> UURemoteTarget?,
         localComposerReady: @escaping () -> Bool, onBegin: @escaping (UURemoteTarget, Bool) -> Void,
         onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.targetProvider = targetProvider
        self.localComposerReady = localComposerReady
        self.onBegin = onBegin
        self.onRelease = onRelease
        self.onCancel = onCancel
    }
    deinit { stop() }
    func start() throws {
        guard eventTap == nil else { return }
        refreshConfiguration()
        let types: [CGEventType] = [.flagsChanged,.keyDown,.keyUp,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { proxy, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ControlHoldMonitor>.fromOpaque(info).takeUnretainedValue().handle(proxy, type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw ControlMonitorError.eventTapUnavailable }
        eventTap = tap; runLoopSource = source; activeTapLocation = .cghidEventTap
        physicalModifiers = Set(VoiceShortcut.modifierFlags.keys.filter { CGEventSource.keyState(.hidSystemState, key: $0) })
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isGestureIdle else { return }
            self.refreshConfiguration()
        }
        logger.notice("HID event tap started; following Doubao shortcuts")
    }
    private func refreshConfiguration() {
        do {
            let updated = try DoubaoShortcutSettings.read()
            if configuration != updated || configurationError != nil {
                configuration = updated; configurationError = nil
                logger.notice("Doubao shortcuts refreshed: \(updated.status, privacy: .public)")
                onConfigurationChange?(updated.status, updated.hold == nil && updated.tap == nil)
            }
        } catch {
            let message = "无法跟随豆包快捷键：\(error.localizedDescription)"
            if configuration != nil || configurationError != message {
                configuration = nil; configurationError = message
                onConfigurationChange?(message, true)
            }
        }
    }
    func cancelGesture() { resetGesture(stopVoice: true) }
    func stop() {
        let active = gesture.phase.isDictating
        resetGesture(stopVoice: true)
        fnCompanionFilter = FnCompanionEventFilter()
        if active { onCancel() }
        settingsTimer?.invalidate(); settingsTimer = nil
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        runLoopSource = nil; eventTap = nil; activeTapLocation = nil
    }
    private func match(_ key: UInt16) -> (VoiceShortcut, Bool, Bool)? {
        guard let configuration else { return nil }
        let hold = configuration.hold?.matches(key: key, physicalModifiers: physicalModifiers) == true
        let tap = configuration.tap?.matches(key: key, physicalModifiers: physicalModifiers) == true
        guard let shortcut = hold ? configuration.hold : (tap ? configuration.tap : nil) else { return nil }
        return (shortcut, hold, tap)
    }
    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.notice("Gesture interrupted: event tap disabled reason=\(type.rawValue, privacy: .public) phase=\(String(describing: self.gesture.phase), privacy: .public)")
            resetGesture(stopVoice: true); onCancel()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            physicalModifiers = Set(VoiceShortcut.modifierFlags.keys.filter { CGEventSource.keyState(.hidSystemState, key: $0) })
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return Unmanaged.passUnretained(event) }
        let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if fnCompanionFilter.shouldSuppress(type: type, keyCode: code,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            marker: event.getIntegerValueField(.eventSourceUserData),
            now: ProcessInfo.processInfo.systemUptime) {
            logger.notice("Consumed companion event following captured Fn release type=\(type.rawValue, privacy: .public)")
            return nil
        }
        // Only log the configured shortcut, never arbitrary typed keys or text.
        if code == configuration?.hold?.keyCode || code == configuration?.tap?.keyCode,
           type == .flagsChanged || type == .keyDown || type == .keyUp {
            logger.notice("Shortcut event type=\(type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) phase=\(String(describing: self.gesture.phase), privacy: .public) trackedDown=\(self.physicalModifiers.contains(code), privacy: .public)")
        }
        var down = type == .keyDown
        let keyEvent = type == .keyDown || type == .keyUp || type == .flagsChanged
        if type == .flagsChanged, VoiceShortcut.modifierFlags[code] != nil {
            if physicalModifiers.contains(code) { physicalModifiers.remove(code); down = false }
            else { physicalModifiers.insert(code); down = true }
        }
        if keyEvent, !down {
            let suppressed = swallowedUps.remove(code) != nil
            let releasesTrigger = trigger.map {
                (code == $0.keyCode || $0.requiredModifierCodes.contains(code)) &&
                (gesture.phase == .pending || gesture.phase == .dictating || gesture.phase == .finishingTap)
            } ?? false
            if type == .flagsChanged, code == 63, suppressed || releasesTrigger {
                fnCompanionFilter.arm(afterCapturedReleaseAt: ProcessInfo.processInfo.systemUptime)
            }
            if releasesTrigger {
                releaseTrigger()
                return nil
            }
            if suppressed { return nil }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
           swallowedUps.contains(code) { return nil }
        if gesture.phase == .latched, type == .flagsChanged, down,
           let trigger, code != trigger.keyCode, trigger.requiredModifierCodes.contains(code) {
            swallowedUps.insert(code)
            return nil
        }
        if keyEvent, down, let matched = match(code) {
            if gesture.phase == .latched, trigger == matched.0 {
                swallowedUps.insert(code)
                _ = gesture.handle(.controlDown(targetAvailable: true))
                return nil
            }
            if gesture.phase == .idle || gesture.phase == .pending {
                if gesture.phase == .idle {
                    guard let target = targetProvider() else { return Unmanaged.passUnretained(event) }
                    self.target = target
                    physicalTriggerStartedAt = Date()
                    _ = gesture.handle(.controlDown(targetAvailable: true))
                }
                capture(matched, event: event, proxy: proxy)
                return nil
            }
        }
        if gesture.phase == .pending {
            restorePendingChord(proxy: proxy)
            return Unmanaged.passUnretained(event)
        }
        if gesture.phase.isDictating {
            if type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .scrollWheel {
                // Source and non-printing key identity diagnose input-method
                // generated control events; never log printable key codes.
                let controlCode = code > 126 || code == 53 ? Int(code) : -1
                logger.notice("Gesture cancelled: unrelated event type=\(type.rawValue, privacy: .public) controlCode=\(controlCode, privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) marker=\(event.getIntegerValueField(.eventSourceUserData), privacy: .public) isTrigger=\(code == self.trigger?.keyCode, privacy: .public) phase=\(String(describing: self.gesture.phase), privacy: .public) syntheticStarted=\(self.syntheticStarted, privacy: .public)")
                resetGesture(stopVoice: true); onCancel()
                // A key used to cancel must not escape as a synthetic shortcut.
                if keyEvent { swallowedUps.insert(code); return nil }
            }
        }
        return Unmanaged.passUnretained(event)
    }
    private func capture(_ matched: (VoiceShortcut, Bool, Bool), event: CGEvent, proxy: CGEventTapProxy) {
        trigger = matched.0; triggerAllowsHold = matched.1; triggerAllowsTap = matched.2
        swallowedUps.insert(matched.0.keyCode)
        if let copy = event.copy() { pendingDowns.append(copy) }
        // Modifiers pressed before a chord may already have reached UU. Release
        // those before local focus changes so the remote does not retain Ctrl etc.
        let buffered = Set(pendingDowns.filter { $0.type == .flagsChanged }.map { UInt16($0.getIntegerValueField(.keyboardEventKeycode)) })
        for code in matched.0.requiredModifierCodes where !buffered.contains(code) && !neutralizedModifiers.contains(code) {
            neutralizedModifiers.append(code); swallowedUps.insert(code)
            let single = VoiceShortcut(keyCode: code, flags: ShortcutEventFactory.modifierFlags([code]).rawValue, display: "")
            post(single, down: false, proxy: proxy)
        }
        activationWork?.cancel()
        if triggerAllowsHold {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.gesture.phase == .pending else { return }
                self.begin(latched: false)
            }
            activationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
        }
    }
    private func releaseTrigger() {
        logger.notice("Shortcut released phase=\(String(describing: self.gesture.phase), privacy: .public) elapsedMS=\(Int(Date().timeIntervalSince(self.physicalTriggerStartedAt) * 1000), privacy: .public) allowsTap=\(self.triggerAllowsTap, privacy: .public)")
        activationWork?.cancel(); activationWork = nil
        if gesture.phase == .pending {
            if triggerAllowsTap { begin(latched: true) }
            else { resetGesture(stopVoice: false) }
        } else if gesture.phase == .dictating || gesture.phase == .finishingTap {
            finish()
        }
    }
    private func begin(latched: Bool) {
        guard let target, targetProvider()?.processIdentifier == target.processIdentifier,
              let configuration else { resetGesture(stopVoice: false); return }
        if latched { _ = gesture.handle(.controlUp) }
        else { _ = gesture.handle(.thresholdReached) }
        logger.notice("Gesture started latched=\(latched, privacy: .public) phase=\(String(describing: self.gesture.phase), privacy: .public)")
        emulationShortcut = configuration.hold ?? configuration.tap
        nativeTap = configuration.hold == nil
        pendingDowns.removeAll(); neutralizedModifiers.removeAll()
        target.captureFocusedWindow()
        onBegin(target, latched)
        focusDeadline = Date().addingTimeInterval(5.5)
        checkLocalFocus()
        if latched {
            let timeout = DispatchWorkItem { [weak self] in self?.finish() }
            latchedTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: timeout)
        }
    }
    private func checkLocalFocus() {
        guard gesture.phase.isDictating, !syntheticStarted, let shortcut = emulationShortcut else { return }
        guard localComposerReady() else {
            if Date() >= focusDeadline { resetGesture(stopVoice: false); onCancel(); return }
            let work = DispatchWorkItem { [weak self] in self?.checkLocalFocus() }
            focusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
            return
        }
        post(shortcut, down: true)
        syntheticStarted = true; syntheticIsDown = true; syntheticStartedAt = Date()
        logger.notice("Synthetic Doubao shortcut started: \(shortcut.display, privacy: .public) nativeTap=\(self.nativeTap, privacy: .public)")
        if nativeTap {
            let up = DispatchWorkItem { [weak self] in
                guard let self, self.syntheticIsDown else { return }
                self.post(shortcut, down: false); self.syntheticIsDown = false
            }
            tapUpWork = up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: up)
        }
    }
    private func finish() {
        guard gesture.phase.isDictating else { return }
        if syntheticStarted, Date().timeIntervalSince(syntheticStartedAt) < 0.22 {
            finishWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            finishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 - Date().timeIntervalSince(syntheticStartedAt), execute: work)
            return
        }
        let started = syntheticStarted
        logger.notice("Gesture finishing phase=\(String(describing: self.gesture.phase), privacy: .public) syntheticStarted=\(started, privacy: .public)")
        resetGesture(stopVoice: true)
        if started { onRelease() } else { onCancel() }
    }
    private func restorePendingChord(proxy: CGEventTapProxy) {
        for code in neutralizedModifiers {
            let single = VoiceShortcut(keyCode: code, flags: ShortcutEventFactory.modifierFlags([code]).rawValue, display: "")
            post(single, down: true, proxy: proxy)
            swallowedUps.remove(code)
        }
        for event in pendingDowns {
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.tapPostEvent(proxy)
            swallowedUps.remove(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        }
        resetGesture(stopVoice: false)
    }
    private func resetGesture(stopVoice: Bool) {
        activationWork?.cancel(); focusWork?.cancel(); tapUpWork?.cancel(); latchedTimeout?.cancel(); finishWork?.cancel()
        activationWork = nil; focusWork = nil; tapUpWork = nil; latchedTimeout = nil; finishWork = nil
        if stopVoice, syntheticStarted, let shortcut = emulationShortcut {
            if syntheticIsDown { post(shortcut, down: false) }
            if nativeTap { post(shortcut, down: true); post(shortcut, down: false) }
        }
        syntheticStarted = false; syntheticIsDown = false
        emulationShortcut = nil; pendingDowns.removeAll(); neutralizedModifiers.removeAll()
        gesture.reset(); target = nil; trigger = nil
    }
    private func post(_ shortcut: VoiceShortcut, down: Bool, proxy: CGEventTapProxy? = nil) {
        for event in ShortcutEventFactory.events(for: shortcut, down: down) {
            if let proxy { event.tapPostEvent(proxy) } else { event.post(tap: .cghidEventTap) }
        }
    }
}
enum SyntheticControlRoute: Equatable {
    case remoteHIDPassthrough
    case localHIDDictation

    var eventTapLocation: CGEventTapLocation {
        switch self {
        case .remoteHIDPassthrough:
            return .cghidEventTap
        case .localHIDDictation:
            // Doubao listens at HID. The local composer must own focus before
            // replaying Control here; session-level events skip its listener.
            return .cghidEventTap
        }
    }
}
