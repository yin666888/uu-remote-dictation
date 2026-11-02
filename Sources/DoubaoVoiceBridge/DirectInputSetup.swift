import AppKit

final class DirectInputSetup: NSWindowController {
    var onSave: (() -> Void)?
    private let portField = NSTextField()
    private let keyField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = DirectInputSettings.isReceiver ? "远控直输接收端 · 配对" : "远控直输 · 配对"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let title = NSTextField(wrappingLabelWithString: DirectInputSettings.isReceiver
            ? "在 远端 Mac 上运行。只接收已配对设备的文字，写入当前输入框。"
            : "在本机使用豆包说话，文字直接输入 远端 Mac，不使用剪贴板。")
        let instructions = NSTextField(wrappingLabelWithString: "两端填写相同的 64 位配对码。可在任一端生成，再手动传到另一端。UU 映射：本地端口 → 远端 Mac 的 127.0.0.1:<接收端口>。端口需与各端设置对应。")
        let portLabel = NSTextField(labelWithString: DirectInputSettings.isReceiver ? "接收端口" : "UU 本地映射端口")
        let keyLabel = NSTextField(labelWithString: "配对码")
        portField.stringValue = DirectInputSettings.port == 0 ? "" : String(DirectInputSettings.port)
        portField.placeholderString = "请填写自己的端口"
        keyField.placeholderString = "64 位十六进制配对码"
        if let key = DirectInputSettings.readKey() { keyField.stringValue = key.map { String(format: "%02x", $0) }.joined() }
        let generate = NSButton(title: "生成配对码…", target: self, action: #selector(generateKey))
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        let stack = NSStackView(views: [title, instructions, portLabel, portField, keyLabel, keyField, generate, status, save])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
                portField.widthAnchor.constraint(equalToConstant: 160),
                keyField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        window.setContentSize(NSSize(width: 580, height: 365))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func generateKey() {
        do {
            let key = try DirectInputSettings.newKey().map { String(format: "%02x", $0) }.joined()
            keyField.stringValue = key
            let alert = NSAlert()
            alert.messageText = "新配对码（保存后生效）"
            alert.informativeText = "把下面的配对码填到另一台电脑。此窗口关闭后，配对码将隐藏。"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 48))
            field.stringValue = key
            field.isEditable = false
            field.isSelectable = true
            alert.accessoryView = field
            alert.addButton(withTitle: "完成")
            alert.runModal()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func saveSettings() {
        guard let port = UInt16(portField.stringValue), port > 0,
              let key = DirectInputCodec.key(from: keyField.stringValue) else {
            status.stringValue = "请输入 1–65535 的端口和完整的 64 位配对码"
            return
        }
        do {
            try DirectInputSettings.saveKey(key)
            UserDefaults.standard.set(Int(port), forKey: "directInputPort")
            status.stringValue = "已保存。请确认两端配对码和 UU 映射配置一致。"
            onSave?()
        } catch { status.stringValue = error.localizedDescription }
    }
}
