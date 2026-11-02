import AppKit
import ApplicationServices
import Network

protocol DirectInputDestination {
    var supportsPreview: Bool { get }
    func updatePreview(_ text: String) throws
    func cancelPreview()

    func insert(_ text: String, isActive: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void)
}

extension DirectInputDestination {
    var supportsPreview: Bool { false }
    func updatePreview(_ text: String) throws { throw DirectInputError.message("目标不支持实时更新") }
    func cancelPreview() {}
}

final class DirectInputFocus: DirectInputDestination {
    private let pid: pid_t
    private let element: AXUIElement
    private let window: AXUIElement
    private let isElectron: Bool
    private var replacement: DirectInputReplacement?
    var supportsPreview: Bool { replacement != nil }

    static func capture(isActive: @escaping () -> Bool = { true },
                        completion: @escaping (Result<DirectInputDestination, Error>) -> Void) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            do { completion(.success(try DirectInputFocus())) }
            catch { completion(.failure(error)) }
            return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let originalWindow = copyElement(application, attribute: kAXFocusedWindowAttribute)
        InputFocusPreparation.capture(isCurrent: {
            guard isActive(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
            if let originalWindow {
                guard let current = copyElement(application, attribute: kAXFocusedWindowAttribute) else { return false }
                return CFEqual(originalWindow, current)
            }
            return true
        }, read: { try DirectInputFocus() as DirectInputDestination }, prepare: {
            // Electron documents this application-level switch. It exposes the
            // renderer tree using existing AX permission; it does not grant
            // system permission or enable VoiceOver. Never set it on all apps.
            guard let bundleURL = app.bundleURL,
                  FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) else { return false }
            return AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        }, completion: completion)
    }

    static func printTargetReport() {
        print("accessibility=\(AXIsProcessTrusted())")
        guard let app = NSWorkspace.shared.frontmostApplication else { print("target=none"); return }
        print("target=\(app.bundleIdentifier ?? "unknown")")
        guard let element = focusedElement(pid: app.processIdentifier) else { print("focused_element=missing"); return }
        print("role=\(string(element, attribute: kAXRoleAttribute) ?? "unknown")")
        print("subrole=\(string(element, attribute: kAXSubroleAttribute) ?? "none")")
        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            print("\(attribute)_settable=\(isSettable(element, attribute: attribute))")
        }
        print("selection_readable=\(selectedRange(element) != nil)")
        if let value = string(element, attribute: kAXValueAttribute) {
            print("value_utf16_length=\(value.utf16.count)")
            if let range = selectedRange(element) {
                print("selection_location=\(range.location) selection_length=\(range.length) range_valid=\(UTF16TextRange.isValid(range, in: value))")
            }
        } else { print("value_readable=false") }
        do { print("target_ready=true preview=\(try DirectInputFocus().supportsPreview)") }
        catch { print("target_ready=false reason=\(error.localizedDescription)") }
    }

    init() throws {
        guard AXIsProcessTrusted() else { throw DirectInputError.message("请在 远端 Mac 为接收端开启辅助功能权限") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = Self.focusedElement(pid: app.processIdentifier),
              let window = Self.copyElement(AXUIElementCreateApplication(app.processIdentifier), attribute: kAXFocusedWindowAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(Self.string(element, attribute: kAXRoleAttribute) ?? ""),
              Self.string(element, attribute: kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else {
            throw DirectInputError.message("请先点选 远端 Mac 上的普通文本输入框")
        }
        pid = app.processIdentifier
        self.element = element
        self.window = window
        isElectron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        // Qoder's AX editor changes its reported capabilities after the first
        // insertion, but AX text replacement still does not reach the editor
        // reliably. Keep every session on character input, including nonempty
        // drafts, rather than switching back to AX after one successful round.
        if app.bundleIdentifier != "com.qodercn.app",
           Self.isSettable(element, attribute: kAXSelectedTextAttribute),
           Self.isSettable(element, attribute: kAXSelectedTextRangeAttribute),
           let value = Self.string(element, attribute: kAXValueAttribute),
           value.utf8.count <= 1024 * 1024,
           let range = Self.selectedRange(element) {
            replacement = try? DirectInputReplacement(original: value, selection: range)
        }
    }
    func matches() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = Self.focusedElement(pid: pid),
              let currentWindow = Self.copyElement(AXUIElementCreateApplication(pid), attribute: kAXFocusedWindowAttribute) else { return false }
        return CFEqual(element, current) && CFEqual(window, currentWindow)
    }
    private static func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }
    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private func select(_ range: NSRange) throws {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw DirectInputError.message("输入框无法定位本轮听写范围，已停止更新")
        }
    }
    func updatePreview(_ text: String) throws {
        guard var replacement, matches(),
              let value = Self.string(element, attribute: kAXValueAttribute),
              let selection = Self.selectedRange(element) else {
            throw DirectInputError.message("输入焦点已改变或不支持实时更新")
        }
        let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        guard CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
            throw DirectInputError.message("远端正在使用快捷键，已停止实时更新")
        }
        try replacement.validate(value: value, selection: selection)
        if replacement.preview == text { return }
        try select(replacement.range)
        // Verify selection was accepted before changing any text.
        guard matches(), Self.selectedRange(element) == replacement.range,
              Self.string(element, attribute: kAXValueAttribute) == replacement.expectedValue else {
            throw DirectInputError.message("输入框不支持可靠的文字替换，已停止更新")
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw DirectInputError.message("实时文字写入失败，请检查远端已显示的内容")
        }
        replacement.didWrite(text)
        // Remember the successful write even if the following verification fails.
        self.replacement = replacement
        guard matches(), Self.string(element, attribute: kAXValueAttribute) == replacement.expectedValue else {
            throw DirectInputError.message("输入框修改了文字，已停止实时更新，请检查远端内容")
        }
        try select(replacement.selection)
        guard Self.selectedRange(element) == replacement.selection else {
            throw DirectInputError.message("无法恢复听写光标，已停止实时更新")
        }
    }
    func cancelPreview() {
        guard let replacement, replacement.preview != nil, matches(),
              let value = Self.string(element, attribute: kAXValueAttribute),
              let selection = Self.selectedRange(element),
              (try? replacement.validate(value: value, selection: selection)) != nil else { return }
        do {
            try updatePreview(replacement.originalSelectionText)
            try select(replacement.originalRange)
            self.replacement = try DirectInputReplacement(original: replacement.original, selection: replacement.originalRange)
        } catch { /* Never guess a range after an external edit or focus change. */ }
    }
    func insert(_ text: String, isActive: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        guard isActive(), matches(), CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
            completion(.failure(DirectInputError.message("远端 Mac 输入焦点已改变，已取消输入")))
            return
        }
        if replacement?.preview != nil {
            do { try updatePreview(text); completion(.success(())) }
            catch { completion(.failure(error)) }
            return
        }
        // Replace the current selection directly when the application supports
        // the accessibility text-editing API. This never touches a pasteboard.
        var settable = DarwinBoolean(false)
        // Electron custom editors can advertise writable AXSelectedText while
        // silently ignoring it (Qoder: empty value, selection at offset 1).
        // If we cannot model the actual text range, choose character events
        // before attempting any AX write. Never retry an ambiguous AX write.
        if !(isElectron && replacement == nil),
           AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if result == .success { completion(.success(())); return }
            // Do not retry using another method after an ambiguous write.
            completion(.failure(DirectInputError.message("目标输入框拒绝直接写入，请检查远端内容")))
            return
        }
        do {
            let events = try DirectUnicodeInput.events(for: text)
            post(events, at: 0, isActive: isActive, completion: completion)
        } catch { completion(.failure(error)) }
    }
    private func post(_ events: [(CGEvent, CGEvent)], at index: Int, isActive: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard index < events.count else { completion(.success(())); return }
        let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        guard isActive(), matches(), CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
            completion(.failure(DirectInputError.message("输入过程中焦点或按键状态改变；请检查远端，可能已输入部分文字")))
            return
        }
        events[index].0.postToPid(pid)
        events[index].1.postToPid(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.post(events, at: index + 1, isActive: isActive, completion: completion)
        }
    }
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        copyElement(AXUIElementCreateApplication(pid), attribute: kAXFocusedUIElementAttribute)
    }
    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}

enum DirectUnicodeInput {
    static func chunks(_ text: String) -> [[UniChar]] {
        var result: [[UniChar]] = []
        var chunk: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { result.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    static func events(for text: String) throws -> [(CGEvent, CGEvent)] {
        guard !text.isEmpty, text.utf8.count <= DirectInputCodec.maximumTextBytes,
              let source = CGEventSource(stateID: .privateState) else {
            throw DirectInputError.message("文字为空、过长或无法创建输入事件")
        }
        return try chunks(text).map { units in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw DirectInputError.message("无法创建直接输入事件")
            }
            for event in [down, up] {
                event.flags = []
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            }
            return (down, up)
        }
    }
}

final class DirectInputReceiver {
    var onStatus: ((String, Bool) -> Void)?
    private var listener: NWListener?
    private var peer: DirectInputChannel?
    private var expiration: DispatchWorkItem?
    private var cancelUncommittedPreview: (() -> Void)?
    private let keyProvider: () -> Data?
    private let portProvider: () -> UInt16
    private let focusProvider: (() throws -> DirectInputDestination)?
    var listeningPort: UInt16? {
        guard let listener, case .ready = listener.state else { return nil }
        return listener.port?.rawValue
    }

    init(keyProvider: @escaping () -> Data? = DirectInputSettings.readKey,
         portProvider: @escaping () -> UInt16 = { DirectInputSettings.port },
         focusProvider: (() throws -> DirectInputDestination)? = nil) {
        self.keyProvider = keyProvider
        self.portProvider = portProvider
        self.focusProvider = focusProvider
    }

    func start() throws {
        stop()
        guard let key = keyProvider() else {
            throw DirectInputError.message("请先在菜单栏配置直输配对")
        }
        let parameters = NWParameters.tcp
        let port = portProvider()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStatus?("接收端就绪 · 等待本机豆包输入", false)
            case .failed(let error): self?.onStatus?(error.localizedDescription, true)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, key: key) }
        listener.start(queue: .main)
    }
    func stop() {
        finishPeer()
        listener?.cancel()
        listener = nil
    }
    private func accept(_ connection: NWConnection, key: Data) {
        guard peer == nil else { connection.cancel(); return }
        let channel = DirectInputChannel(connection: connection, key: key)
        peer = channel
        let challenge = UUID()
        var focus: DirectInputDestination?
        var capturingFocus = false
        var committed = false
        var lastSequence = 0
        channel.onReady = { [weak channel] in
            channel?.send(DirectInputMessage(operation: "hello", session: challenge))
        }
        channel.onFailure = { [weak self, weak channel] _ in
            guard let self, let channel, self.peer === channel else { return }
            self.finishPeer()
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            guard message.session == challenge, !committed else { self.finishPeer(); return }
            do {
                switch message.operation {
                case "begin" where focus == nil && !capturingFocus:
                    capturingFocus = true
                    let completed: (Result<DirectInputDestination, Error>) -> Void = { [weak self, weak channel] result in
                        guard let self, let channel, self.peer === channel, !committed else { return }
                        capturingFocus = false
                        switch result {
                        case .success(let destination):
                            focus = destination
                            self.cancelUncommittedPreview = { focus?.cancelPreview() }
                            channel.send(DirectInputMessage(operation: "ready", session: challenge, previewSupported: destination.supportsPreview))
                            self.onStatus?("已锁定输入框 · 等待识别结果", false)
                        case .failure(let error):
                            committed = true
                            self.armExpiration(after: 5)
                            channel.send(DirectInputMessage(operation: "error", session: challenge, error: error.localizedDescription))
                        }
                    }
                    if let provider = self.focusProvider { completed(Result { try provider() }) }
                    else {
                        DirectInputFocus.capture(isActive: { [weak self, weak channel] in
                            guard let self, let channel else { return false }
                            return self.peer === channel && !committed
                        }, completion: completed)
                    }
                case "preview":
                    guard let focus, focus.supportsPreview, let text = message.text,
                          text.utf8.count <= DirectInputCodec.maximumTextBytes,
                          let sequence = message.sequence, sequence > 0, sequence == lastSequence + 1 else {
                        throw DirectInputError.message("实时更新顺序或内容无效")
                    }
                    try focus.updatePreview(text)
                    lastSequence = sequence
                    channel.send(DirectInputMessage(operation: "previewed", session: challenge, sequence: sequence))
                case "commit":
                    guard let focus, let text = message.text, !text.isEmpty,
                          text.utf8.count <= DirectInputCodec.maximumTextBytes else {
                        throw DirectInputError.message("无效的直输会话或文字")
                    }
                    committed = true
                    self.cancelUncommittedPreview = nil
                    self.armExpiration()
                    focus.insert(text, isActive: { [weak self, weak channel] in
                        guard let channel else { return false }
                        return self?.peer === channel
                    }) { [weak self, weak channel] result in
                        let error: String?
                        switch result {
                        case .success: error = nil
                        case .failure(let failure): error = failure.localizedDescription
                        }
                        guard let self, let channel, self.peer === channel else { return }
                        // contentProcessed only confirms local enqueueing. Cancelling
                        // here can discard the receipt inside a port-forwarding relay.
                        // Let the client close after reading it; bound abandoned peers.
                        self.armExpiration(after: 5)
                        channel.send(DirectInputMessage(operation: "accepted", session: challenge, error: error))
                        self.onStatus?(error ?? "文字已提交到目标输入框", error != nil)
                    }
                default: throw DirectInputError.message("直输协议状态异常")
                }
            } catch {
                committed = true
                self.armExpiration(after: 5)
                channel.send(DirectInputMessage(operation: "error", session: challenge, error: error.localizedDescription))
            }
        }
        armExpiration()
        channel.start()
    }
    private func armExpiration(after seconds: TimeInterval = 60) {
        expiration?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finishPeer() }
        expiration = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }
    private func finishPeer() {
        let cancelPreview = cancelUncommittedPreview
        cancelUncommittedPreview = nil
        cancelPreview?()
        expiration?.cancel()
        expiration = nil
        peer?.close()
        peer = nil
    }
}
