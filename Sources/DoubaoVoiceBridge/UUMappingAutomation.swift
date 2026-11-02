import AppKit
import ApplicationServices

// UU currently exposes desktop state through its CLI but not port mapping.
// This adapter only operates an existing, explicitly configured mapping rule.
// It does not create mappings, edit addresses, or infer the target from focus.
final class UUMappingAutomation {
    var onStatus: ((String, Bool) -> Void)?
    var isIdle: () -> Bool = { true }
    private let session: UUSessionMonitor
    private let targetName: String
    private let ruleID: String
    private var timer: Timer?
    private var original: UURemoteTarget?
    private var openedWindow: AXUIElement?
    private var step = 0
    private var deadline: Date?
    private var retryAfter = Date.distantPast
    private var ready = false
    private var startingPID: pid_t?
    private var health = UUMappingHealth()
    private var probing = false
    private var probeGeneration = UUID()
    private var lastProbeStarted = Date.distantPast

    init(targetID: String, targetName: String, ruleID: String) {
        session = UUSessionMonitor(targetID: targetID)
        self.targetName = targetName
        self.ruleID = ruleID
    }

    func start() {
        session.onChange = { [weak self] active in
            guard let self else { return }
            if !active {
                self.finish(restore: false)
                self.ready = false
                self.health = UUMappingHealth()
                self.probeGeneration = UUID()
                self.probing = false
                self.lastProbeStarted = .distantPast
            }
            self.tick()
        }
        session.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session.onChange = nil
        session.stop()
        probeGeneration = UUID()
        finish(restore: false)
    }

    private func tick() {
        guard session.isControlling, isIdle(), AXIsProcessTrusted(),
              !targetName.isEmpty, !ruleID.isEmpty,
              Date() >= retryAfter,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.uuRemoteBundleIdentifier).first else { return }
        refreshHealth(processID: app.processIdentifier)
        switch health.decision(processID: app.processIdentifier, at: Date()) {
        case .healthy:
            if !ready { onStatus?("语音映射已就绪", false) }
            ready = true
            finish()
            return // Crucially, do not even inspect/raise hidden UU windows.
        case .wait:
            return
        case .recover:
            ready = false
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let windows = Self.elements(root, kAXWindowsAttribute)
        if let mapping = windows.first(where: { Self.string($0, kAXIdentifierAttribute) == "PortMappingWindow" && self.matchesTarget($0) }) {
            let nodes = Self.descendants(mapping)
            let switches = nodes.filter { Self.string($0, kAXIdentifierAttribute) == ruleID && [0, 1].contains(Self.number($0, kAXValueAttribute) ?? -1) }
            guard switches.count == 1, let toggle = switches.first else {
                fail("UU 映射规则已改变，请重新配置自动连接")
                return
            }
            if Self.number(toggle, kAXValueAttribute) == 1 {
                if nodes.contains(where: { Self.label($0) == "成功" }) {
                    // UI success is advisory. Only the process-owned listener
                    // probe can finish recovery and return the original focus.
                    return
                }
                // A switch can be enabled while the connection is still being
                // established. Wait; do not toggle it repeatedly or duplicate it.
                if let deadline, Date() > deadline { fail("UU 映射暂未连接成功，请检查 UU 的映射窗口") }
                return
            }
            ready = false
            guard app.isActive, isIdle() else { return }
            beginIfNeeded(app)
            openedWindow = mapping
            guard Self.raise(mapping), Self.click(toggle, in: mapping, app: app) else {
                fail("无法自动启用 UU 映射，请检查映射窗口")
                return
            }
            step = 4
            return
        }

        ready = false
        // Never interrupt work in another application to drive UU's interface.
        // A newly opened desktop window naturally makes UU active.
        guard app.isActive else { finish(restore: false); return }
        beginIfNeeded(app)
        guard startingPID == app.processIdentifier else { finish(restore: false); return }
        if let deadline, Date() > deadline { fail("UU 自动映射未完成，可在 UU 中手动打开端口映射") ; return }
        // Once we requested the mapping window, wait for it; repeatedly raising
        // the main page here used to fight with the remote desktop window.
        if step >= 3 { return }

        // The main window has the device sidebar. Find it structurally rather
        // than relying on an untitled window or the window list's order.
        let main = windows.first { window in
            let labels = Self.descendants(window).map(Self.label)
            return labels.contains("我的设备") && labels.contains("全部设备")
        }
        guard let main else {
            if step == 0 {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &raw) == .success,
                   let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                    let bar = unsafeBitCast(raw, to: AXUIElement.self)
                    if let item = Self.descendants(bar).first(where: { Self.string($0, kAXIdentifierAttribute) == "showMainWindow" }),
                       AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { step = 1; return }
                }
                // Reopening UU through LaunchServices is the supported app
                // action for showing its main window. It does not connect to a
                // different device or change the signed-in account.
                if let url = app.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                    step = 1
                }
            }
            return
        }
        if step < 2 {
            guard Self.raise(main) else { fail("无法打开 UU 设备列表") ; return }
            openedWindow = main
        } else if !Self.isFocused(main, app: app) {
            // The user switched UU windows during setup. Yield instead of
            // pulling the main page back in front of the user's remote desktop.
            finish(restore: false)
            retryAfter = Date().addingTimeInterval(30)
            return
        }
        let nodes = Self.descendants(main)
        if step < 2 {
            guard let sidebar = nodes.first(where: {
                Self.string($0, kAXRoleAttribute) == kAXScrollAreaRole && Self.descendants($0).contains(where: { Self.label($0) == "我的设备" })
            }) else { fail("UU 设备列表结构已改变，已停止自动操作") ; return }
            let targets = Self.descendants(sidebar).filter { Self.label($0) == targetName }
            guard targets.count == 1, let target = targets.first,
                  Self.click(target, in: main, app: app) else { fail("UU 中找不到唯一的目标设备") ; return }
            step = 2
            return
        }
        if step == 2 {
            // Verify the selected device in the toolbar before opening its
            // mapping window. A sidebar click alone is not confirmation.
            guard let toolbar = nodes.first(where: { Self.string($0, kAXRoleAttribute) == kAXToolbarRole }),
                  Self.descendants(toolbar).contains(where: { Self.label($0) == targetName }),
                  let entry = nodes.first(where: { Self.label($0) == "端口映射" }),
                  Self.click(entry, in: main, app: app) else { fail("无法确认 UU 当前选中的设备") ; return }
            step = 3
        }
    }

    private func matchesTarget(_ window: AXUIElement) -> Bool {
        let labels = Self.descendants(window).map(Self.label)
        return (labels.contains(targetName) && labels.contains("映射列表")) || labels.contains {
            $0.hasPrefix(targetName + " ") && $0.contains("映射列表")
        }
    }
    private func beginIfNeeded(_ app: NSRunningApplication) {
        guard deadline == nil else { return }
        original = UURemoteTarget(application: app)
        original?.captureFocusedWindow()
        startingPID = app.processIdentifier
        deadline = Date().addingTimeInterval(12)
        step = 0
        onStatus?("正在恢复 UU 语音映射…", false)
    }
    private func finish(restore: Bool = true) {
        if restore, let original, original.application.isActive {
            let app = original.application
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let current = Self.raw(root, kAXFocusedWindowAttribute), CFGetTypeID(current) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(current, to: AXUIElement.self)
                let isOurWindow = openedWindow.map { CFEqual($0, window) } ?? false
                let isRequestedMapping = step >= 3 && Self.string(window, kAXIdentifierAttribute) == "PortMappingWindow" && matchesTarget(window)
                if isOurWindow || isRequestedMapping { original.activateOriginalWindow() }
            }
        }
        original = nil
        openedWindow = nil
        deadline = nil
        startingPID = nil
        step = 0
    }
    private func fail(_ message: String) {
        finish()
        retryAfter = Date().addingTimeInterval(30)
        onStatus?(message, true)
    }
    private func refreshHealth(processID: pid_t) {
        guard !probing, Date().timeIntervalSince(lastProbeStarted) >= 1 else { return }
        probing = true
        lastProbeStarted = Date()
        let token = probeGeneration
        let port = DirectInputSettings.port
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = UUMappingListenerProbe.query(processID: processID, port: port)
            DispatchQueue.main.async {
                guard let self, self.probeGeneration == token else { return }
                self.probing = false
                self.health.observe(value, processID: processID, at: Date())
            }
        }
    }
    private static func isFocused(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard app.isActive,
              let current = raw(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return false }
        return CFEqual(current, window)
    }
    private static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? { raw(element, attribute) as? String }
    private static func number(_ element: AXUIElement, _ attribute: String) -> Int? { (raw(element, attribute) as? NSNumber)?.intValue }
    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] { raw(element, attribute) as? [AXUIElement] ?? [] }
    private static func label(_ element: AXUIElement) -> String {
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = string(element, attribute), !value.isEmpty { return value }
        }
        return ""
    }
    private static func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func visit(_ item: AXUIElement, _ depth: Int) {
            guard depth < 16, result.count < 1200 else { return }
            result.append(item)
            for child in elements(item, kAXChildrenAttribute) { visit(child, depth + 1) }
        }
        visit(root, 0)
        return result
    }
    private static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }
    private static func click(_ element: AXUIElement, in window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard app.isActive else { return false }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        // UU exposes some links as static text without AXPress. The user has
        // requested this UI automation; derive the point from this exact
        // element, never hard-code screen coordinates or click another app.
        guard let p = raw(element, kAXPositionAttribute), let s = raw(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let current = raw(root, kAXFocusedWindowAttribute), CFEqual(current, window), app.isActive else { return false }
        point.x += size.width / 2
        point.y += size.height / 2
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
