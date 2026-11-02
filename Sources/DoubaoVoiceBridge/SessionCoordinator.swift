import AppKit

final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case finalizing
        case delivering
        case failed
    }

    var onSessionEnded: (() -> Void)?
    var onStatusChange: ((String, Bool) -> Void)?

    private let panel = ComposerPanelController()
    private let delivery = DirectInputClient()
    private var attemptID = UUID()
    private(set) var state: State = .idle
    private var target: UURemoteTarget?
    private var deliveryAwaitingCleanup = false
    private var allowsManualCommitAfterTimeout = false

    var canBegin: Bool {
        (state == .idle || state == .failed) && !deliveryAwaitingCleanup
    }

    var isLocalComposerReady: Bool {
        state == .listening && panel.isReadyForLocalDictation
    }

    init() {
        panel.onCommit = { [weak self] text in self?.send(text: text) }
        panel.onCancel = { [weak self] in self?.cancel() }
        // Gesture completion is owned by the shortcut monitor, not a hardcoded Control release.
        panel.onTranscriptTimeout = { [weak self] in self?.handleTranscriptTimeout() }
        panel.onPreview = { [weak self] text in
            guard let self, self.state == .listening || self.state == .finalizing else { return }
            self.delivery.updatePreview(text)
        }
        delivery.onSessionFailure = { [weak self] error in
            guard let self, self.state == .listening || self.state == .finalizing else { return }
            self.state = .failed
            self.onSessionEnded?()
            self.panel.showError("\(error.localizedDescription)。已停止实时更新；请检查远端后按 Esc 重试")
            self.onStatusChange?(error.localizedDescription, true)
        }
    }

    func begin(target: UURemoteTarget, latched: Bool = false) {
        guard (state == .idle || state == .failed), !deliveryAwaitingCleanup else {
            onStatusChange?("正在处理上次输入，请稍候…", false)
            return
        }
        self.target = target
        allowsManualCommitAfterTimeout = false
        state = .connecting
        let attempt = UUID()
        attemptID = attempt
        onStatusChange?("正在连接 远端 Mac 直输接收端…", false)
        delivery.begin { [weak self] result in
            guard let self, self.attemptID == attempt, self.state == .connecting else { return }
            switch result {
            case .success:
                self.state = .listening
                self.panel.begin(targetDescription: "豆包直输 · 远端 Mac", compact: true)
                self.onStatusChange?(latched ? "正在听写…再按语音快捷键结束发送，Esc 取消" : "正在听写…松开语音快捷键直接输入", false)
            case .failure(let error):
                self.state = .failed
                self.onSessionEnded?()
                self.panel.begin(targetDescription: "直输连接失败", compact: true)
                self.panel.showError("\(error.localizedDescription)。按 Esc 返回后重试")
                self.onStatusChange?(error.localizedDescription, true)
            }
        }
    }

    func controlReleased() {
        guard state == .listening else { return }
        state = .finalizing
        panel.waitForFinalTranscript()
        onStatusChange?("正在完成识别…", false)
    }

    func cancelFromMonitor() {
        // A physical key release must not erase a connection error before it
        // can be read. Esc in the panel still dismisses it explicitly.
        guard state != .failed else { return }
        cancel()
    }

    func cancel() {
        guard state != .idle, state != .delivering else { return }
        onSessionEnded?()
        let target = self.target
        self.target = nil
        attemptID = UUID()
        delivery.cancel()
        state = .idle
        panel.hide()
        target?.activateOriginalWindow()
        onStatusChange?("就绪 · 跟随豆包的语音快捷键", false)
    }

    func prepareForTermination() {
        delivery.cancel()
    }

    private func send(text: String) {
        guard state == .listening || state == .finalizing || (state == .failed && allowsManualCommitAfterTimeout),
              let target else { return }
        allowsManualCommitAfterTimeout = false
        state = .delivering
        onSessionEnded?()
        deliveryAwaitingCleanup = true
        panel.showSending()
        onStatusChange?("正在直接输入到 远端 Mac…", false)

        guard !target.isTerminated, target.stillMatchesFocusedWindow() else {
            deliveryAwaitingCleanup = false
            state = .failed
            panel.showError("UU 窗口已改变，请取消并重新听写")
            delivery.cancel()
            return
        }
        panel.hide()
        target.activateOriginalWindow()
        delivery.commit(text: text) { [weak self] result in
            guard let self else { return }
            self.deliveryAwaitingCleanup = false
            switch result {
            case .success:
                self.panel.hide()
                self.target = nil
                self.state = .idle
                self.onStatusChange?("文字已提交到 远端 Mac 输入框", false)
            case .failure(let error):
                self.state = .failed
                self.panel.showError("\(error.localizedDescription)。文字保留，请检查远端后按 Esc 重新听写")
                self.onStatusChange?(error.localizedDescription, true)
            }
        }
    }

    private func handleTranscriptTimeout() {
        state = .failed
        if panel.currentText().isEmpty {
            panel.showError("没有识别到文字。按 Esc 返回 UU 后可重试")
            onStatusChange?("没有识别到文字，请重试", true)
        } else {
            allowsManualCommitAfterTimeout = true
            panel.showError("豆包语音输入法尚未完成识别，确认文字后按回车发送，或按 Esc 取消")
            onStatusChange?("识别超时，等待手动确认", true)
        }
    }
}
