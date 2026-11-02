import AppKit
import ApplicationServices
import notify
import os.log

enum LatencyDefaultsMigration {
    static let legacyPasteDelay: TimeInterval = 0.9

    static func replacementPasteDelay(for storedValue: Any?) -> TimeInterval? {
        guard let storedValue else { return UURemoteDelivery.defaultPasteDelay }

        let numericValue: Double?
        if let number = storedValue as? NSNumber {
            numericValue = number.doubleValue
        } else if let string = storedValue as? String {
            numericValue = Double(string)
        } else {
            numericValue = nil
        }

        guard let numericValue,
              abs(numericValue - legacyPasteDelay) < 0.000_1 else {
            return nil
        }
        return UURemoteDelivery.defaultPasteDelay
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let uuRemoteBundleIdentifier = "com.netease.uuremote"
    private static let latencyDefaultsMigrationKey = "didMigrateLatencyDefaultsV23"

    private let logger = Logger(subsystem: "org.remotedictation.bridge", category: "app")
    private let coordinator = SessionCoordinator()
    private let receiver = DirectInputReceiver()
    private var setup: DirectInputSetup?
    private var monitor: ControlHoldMonitor?
    private var mappingAutomation: UUMappingAutomation?
    private var statusItem: NSStatusItem?
    private var statusText = "正在启动…"
    private var statusIsError = false
    private var permissionRetryTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observedUURemotePID: pid_t?
    private var eventTapNotificationTokens: [Int32] = []
    private var tapOrderAuditWorkItem: DispatchWorkItem?
    private var tapOrderAuditTimer: Timer?
    private var tapReinstallTimes: [Date] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "pasteDelay": UURemoteDelivery.defaultPasteDelay,
            "restoreClipboard": true,
            "autoPasteUU": true,
            "controlHoldThreshold": 0.18
        ])
        UserDefaults.standard.set(true, forKey: "autoPasteUU")
        migrateLatencyDefaultsIfNeeded()

        configureStatusItem()
        coordinator.onStatusChange = { [weak self] text, isError in
            self?.setStatus(text, isError: isError)
        }

        if DirectInputSettings.isReceiver {
            receiver.onStatus = { [weak self] text, error in self?.setStatus(text, isError: error) }
            ReceiverAutoStart.prepareOnLaunch()
            startReceiver()
            if DirectInputSettings.readKey() == nil || DirectInputSettings.port == 0 { openDirectInputSetup() }
            return
        }
        if DirectInputSettings.readKey() == nil || DirectInputSettings.port == 0 { openDirectInputSetup() }

        let monitor = ControlHoldMonitor(
            holdThreshold: UserDefaults.standard.double(forKey: "controlHoldThreshold"),
            targetProvider: { [weak self] in
                guard let self, self.coordinator.canBegin else { return nil }
                return self.currentUURemoteTarget()
            },
            localComposerReady: { [weak self] in
                self?.coordinator.isLocalComposerReady ?? false
            },
            onBegin: { [weak self] target, latched in self?.coordinator.begin(target: target, latched: latched) },
            onRelease: { [weak self] in self?.coordinator.controlReleased() },
            onCancel: { [weak self] in self?.coordinator.cancelFromMonitor() }
        )
        monitor.onConfigurationChange = { [weak self] text, error in self?.setStatus(text, isError: error) }
        self.monitor = monitor
        coordinator.onSessionEnded = { [weak monitor] in monitor?.cancelGesture() }
        observeUURemoteLifecycle()
        observeEventTapChanges()
        startMonitorOrRequestPermissions(promptIfNeeded: true)
        configureMappingAutomation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver.stop()
        mappingAutomation?.stop()
        monitor?.stop()
        coordinator.prepareForTermination()
        permissionRetryTimer?.invalidate()
        tapOrderAuditWorkItem?.cancel()
        tapOrderAuditTimer?.invalidate()
        for token in eventTapNotificationTokens {
            notify_cancel(token)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "远控听写")
            button.toolTip = "远控听写"
        }
        statusItem = item
        rebuildMenu()
    }

    private func migrateLatencyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.latencyDefaultsMigrationKey) else { return }

        // Preserve deliberate custom settings. Only migrate the exact value
        // shipped by v2.2 to the faster, measured default.
        if let replacement = LatencyDefaultsMigration.replacementPasteDelay(
            for: defaults.object(forKey: "pasteDelay")
        ) {
            defaults.set(replacement, forKey: "pasteDelay")
        }
        defaults.set(true, forKey: Self.latencyDefaultsMigrationKey)
    }

    private func setStatus(_ text: String, isError: Bool) {
        logger.notice("Status error=\(isError, privacy: .public): \(text, privacy: .public)")
        statusText = text
        statusIsError = isError
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if statusIsError {
            status.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(status)

        let instruction = NSMenuItem(title: "本机豆包识别 · 远端 Mac 直接输入", action: nil, keyEquivalent: "")
        instruction.isEnabled = false
        menu.addItem(instruction)
        menu.addItem(.separator())

        let manual = NSMenuItem(title: "手动打开听写框", action: #selector(openComposerManually), keyEquivalent: "")
        manual.target = self
        if !DirectInputSettings.isReceiver { menu.addItem(manual) }

        let setup = NSMenuItem(title: "配置直输配对…", action: #selector(openDirectInputSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let permissions = NSMenuItem(title: "检查 / 开启所需权限…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        if DirectInputSettings.isReceiver {
            let autoStart = NSMenuItem(title: "开机自启", action: #selector(toggleReceiverAutoStart), keyEquivalent: "")
            autoStart.state = ReceiverAutoStart.isEnabled ? .on : .off
            autoStart.target = self
            menu.addItem(autoStart)
        }
        if !DirectInputSettings.isReceiver, UserDefaults.standard.string(forKey: "uuAutoMappingTargetID") != nil {
            let automatic = NSMenuItem(title: "连接 UU 时自动恢复语音映射", action: #selector(toggleMappingAutomation), keyEquivalent: "")
            automatic.state = UserDefaults.standard.bool(forKey: "uuAutoMappingEnabled") ? .on : .off
            automatic.target = self
            menu.addItem(automatic)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出远控听写", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func currentUURemoteTarget() -> UURemoteTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.uuRemoteBundleIdentifier,
              !frontmost.isTerminated else {
            return nil
        }
        return UURemoteTarget(application: frontmost)
    }

    @objc private func openComposerManually() {
        guard let target = currentUURemoteTarget() else {
            setStatus("请先点回 UU 远控，再使用豆包语音快捷键", isError: true)
            return
        }
        target.captureFocusedWindow()
        coordinator.begin(target: target)
    }

    private func startReceiver() {
        do {
            guard DirectInputSettings.port > 0 else { throw DirectInputError.message("请先配置自己的接收端口和配对码") }
            try receiver.start()
        }
        catch { setStatus(error.localizedDescription, isError: true) }
    }

    @objc private func openDirectInputSetup() {
        if setup == nil {
            setup = DirectInputSetup()
            setup?.onSave = { [weak self] in
                guard let self else { return }
                if DirectInputSettings.isReceiver { self.startReceiver() }
            }
        }
        setup?.present()
    }

    @objc private func toggleReceiverAutoStart() {
        ReceiverAutoStart.setEnabled(!ReceiverAutoStart.isEnabled)
        rebuildMenu()
    }

    private func configureMappingAutomation() {
        mappingAutomation?.stop()
        mappingAutomation = nil
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "uuAutoMappingEnabled"),
              let target = defaults.string(forKey: "uuAutoMappingTargetID"), !target.isEmpty,
              let name = defaults.string(forKey: "uuAutoMappingTargetName"), !name.isEmpty,
              let rule = defaults.string(forKey: "uuAutoMappingRuleID"), !rule.isEmpty else { return }
        let automatic = UUMappingAutomation(targetID: target, targetName: name, ruleID: rule)
        automatic.isIdle = { [weak self] in self?.coordinator.canBegin == true && self?.monitor?.isGestureIdle == true }
        automatic.onStatus = { [weak self] text, error in self?.setStatus(text, isError: error) }
        mappingAutomation = automatic
        automatic.start()
    }

    @objc private func toggleMappingAutomation() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "uuAutoMappingEnabled"), forKey: "uuAutoMappingEnabled")
        configureMappingAutomation()
        rebuildMenu()
    }

    @objc private func openPermissions() {
        requestRequiredPermissions(forceOpenSettings: true)
    }

    private func requestRequiredPermissions(forceOpenSettings: Bool = false) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        let inputGranted = DirectInputSettings.isReceiver || CGRequestListenEventAccess()

        if forceOpenSettings || !accessibilityGranted {
            openSystemSettings(anchor: "Privacy_Accessibility")
        } else if !inputGranted {
            openSystemSettings(anchor: "Privacy_ListenEvent")
        }
    }

    private func startMonitorOrRequestPermissions(promptIfNeeded: Bool) {
        guard let monitor, monitor.activeTapLocation == nil else { return }
        do {
            try monitor.start()
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            setStatus(monitor.configurationStatus, isError: monitor.configuration == nil)
        } catch {
            logger.error("Unable to start control monitor: \(error.localizedDescription, privacy: .public)")
            setStatus("需要开启辅助功能与输入监控权限", isError: true)
            if promptIfNeeded {
                requestRequiredPermissions()
            }
            if permissionRetryTimer == nil {
                permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.startMonitorOrRequestPermissions(promptIfNeeded: false)
                }
            }
        }
    }

    private func observeUURemoteLifecycle() {
        observedUURemotePID = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.uuRemoteBundleIdentifier
        }?.processIdentifier

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == Self.uuRemoteBundleIdentifier else { return }
                let pid = application.processIdentifier
                let delay = UURemoteActivationAudit.delay(
                    previousPID: self.observedUURemotePID,
                    activatedPID: pid
                )
                self.observedUURemotePID = pid
                self.scheduleTapOrderAudit(after: delay)
            }
            workspaceObservers.append(observer)
        }
    }

    private func observeEventTapChanges() {
        for name in [
            "com.apple.coregraphics.eventTapAdded",
            "com.apple.coregraphics.eventTapRemoved"
        ] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                self?.scheduleTapOrderAudit(after: 0.08)
            }
            if status == NOTIFY_STATUS_OK {
                eventTapNotificationTokens.append(token)
            } else {
                logger.error("Unable to observe event-tap changes (status=\(status, privacy: .public))")
            }
        }

        tapOrderAuditTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.auditTapOrder()
        }
    }

    private func scheduleTapOrderAudit(after delay: TimeInterval) {
        tapOrderAuditWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.auditTapOrder() }
        tapOrderAuditWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func auditTapOrder() {
        guard let monitor, monitor.activeTapLocation != nil, monitor.isGestureIdle,
              let uuRemote = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == Self.uuRemoteBundleIdentifier && !$0.isTerminated
              }) else { return }

        let taps = Self.installedEventTaps()
        let bridgePID = ProcessInfo.processInfo.processIdentifier
        let inputMethodPIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.bytedance.inputmethod.doubaoime"
        }.map(\.processIdentifier))
        guard UURemoteTapOrder.needsReinstall(
            taps: taps,
            bridgePID: bridgePID,
            uuRemotePID: uuRemote.processIdentifier,
            otherKeyboardPIDs: inputMethodPIDs
        ) else { return }

        let now = Date()
        tapReinstallTimes.removeAll { now.timeIntervalSince($0) > 5.0 }
        guard tapReinstallTimes.count < 3 else {
            logger.error("Tap-order contention detected; deferring to the low-frequency audit")
            return
        }
        tapReinstallTimes.append(now)
        logger.notice("UU or Doubao keyboard tap moved ahead; reinstalling local head tap")
        monitor.stop()
        startMonitorOrRequestPermissions(promptIfNeeded: false)
    }

    private static func installedEventTaps() -> [InstalledEventTap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return [] }
        let capacity = max(count + 8, 32)
        let buffer = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
        defer { buffer.deallocate() }

        var filled = capacity
        guard CGGetEventTapList(capacity, buffer, &filled) == .success else { return [] }
        return (0..<Int(filled)).map { InstalledEventTap(buffer[$0]) }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

struct InstalledEventTap: Equatable {
    let processIdentifier: pid_t
    let location: UInt32
    let options: UInt32
    let eventMask: CGEventMask
    let isEnabled: Bool

    init(
        processIdentifier: pid_t,
        location: UInt32,
        options: UInt32,
        eventMask: CGEventMask,
        isEnabled: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.location = location
        self.options = options
        self.eventMask = eventMask
        self.isEnabled = isEnabled
    }

    init(_ information: CGEventTapInformation) {
        self.init(
            processIdentifier: information.tappingProcess,
            location: information.tapPoint.rawValue,
            options: information.options.rawValue,
            eventMask: information.eventsOfInterest,
            isEnabled: information.enabled
        )
    }
}

enum UURemoteTapOrder {
    private static let keyboardMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
    }

    static func needsReinstall(
        taps: [InstalledEventTap],
        bridgePID: pid_t,
        uuRemotePID: pid_t,
        otherKeyboardPIDs: Set<pid_t> = []
    ) -> Bool {
        let relevant = taps.enumerated().filter { _, tap in
            tap.isEnabled &&
                tap.location == CGEventTapLocation.cghidEventTap.rawValue &&
                tap.options == CGEventTapOptions.defaultTap.rawValue &&
                (tap.eventMask & keyboardMask) != 0
        }
        let competitors = otherKeyboardPIDs.union([uuRemotePID])
        guard let uuIndex = relevant.first(where: { competitors.contains($0.element.processIdentifier) })?.offset else {
            return false
        }
        guard let bridgeIndex = relevant.first(where: { $0.element.processIdentifier == bridgePID })?.offset else {
            return true
        }
        return uuIndex < bridgeIndex
    }
}

enum UURemoteActivationAudit {
    static func delay(previousPID: pid_t?, activatedPID: pid_t) -> TimeInterval {
        previousPID == activatedPID ? 0.25 : 0.8
    }
}
