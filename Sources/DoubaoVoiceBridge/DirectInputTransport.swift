import Foundation
import Network
import os.log

final class DirectInputChannel {
    var onMessage: ((DirectInputMessage) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onReady: (() -> Void)?
    private let connection: NWConnection
    private let key: Data
    private var framer = DirectInputFramer()
    private var closed = false

    init(connection: NWConnection, key: Data) {
        self.connection = connection
        self.key = key
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let error): self.fail(error)
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ message: DirectInputMessage, completion: (() -> Void)? = nil) {
        guard !closed else { return }
        do {
            let frame = try DirectInputCodec.encode(message, key: key)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(error) } else { completion?() }
            })
        } catch { fail(error) }
    }
    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onReady = nil
        onMessage = nil
        onFailure = nil
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for frame in try self.framer.append(data) {
                        self.onMessage?(try DirectInputCodec.decode(frame, key: self.key))
                        if self.closed { return }
                    }
                }
                if let error { self.fail(error) }
                else if complete { self.fail(DirectInputError.message("直输连接已断开")) }
                else { self.receive() }
            } catch { self.fail(DirectInputError.message("配对码不一致或数据校验失败")) }
        }
    }
    private func fail(_ error: Error) {
        guard !closed else { return }
        let callback = onFailure
        close()
        callback?(error)
    }
}

final class DirectInputClient {
    private let logger = Logger(subsystem: "org.remotedictation.bridge", category: "stream")
    var onSessionFailure: ((Error) -> Void)?
    private(set) var supportsPreview = false
    private var pendingPreview: String?
    private var previewWork: DispatchWorkItem?
    private var previewTimeout: DispatchWorkItem?
    private var previewSequence = 0
    private var awaitingPreview: Int?
    private var queuedCommit: String?

    private var channel: DirectInputChannel?
    private var session: UUID?
    private enum Phase { case idle, waitingHello, waitingReady, ready, waitingAcceptance }
    private var phase = Phase.idle
    private let keyProvider: () -> Data?
    private let portProvider: () -> UInt16

    init(keyProvider: @escaping () -> Data? = DirectInputSettings.readKey,
         portProvider: @escaping () -> UInt16 = { DirectInputSettings.port }) {
        self.keyProvider = keyProvider
        self.portProvider = portProvider
    }
    private var callback: ((Result<Void, Error>) -> Void)?
    private var timeout: DispatchWorkItem?

    func begin(completion: @escaping (Result<Void, Error>) -> Void) {
        cancel()
        guard let key = keyProvider() else {
            completion(.failure(DirectInputError.message("请先在菜单栏配置直输配对")))
            return
        }
        let configuredPort = portProvider()
        guard configuredPort > 0 else {
            completion(.failure(DirectInputError.message("请先配置自己的 UU 本地映射端口")))
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuredPort)!, using: .tcp)
        let channel = DirectInputChannel(connection: connection, key: key)
        self.channel = channel
        callback = completion
        phase = .waitingHello
        channel.onMessage = { [weak self] message in self?.receive(message) }
        channel.onFailure = { [weak self] error in self?.finish(.failure(error)) }
        armTimeout("无法连接 远端 Mac 接收端，请检查接收端和 UU 端口映射")
        channel.start()
    }
    func updatePreview(_ text: String) {
        guard phase == .ready, supportsPreview, queuedCommit == nil else { return }
        guard text.utf8.count <= DirectInputCodec.maximumTextBytes else {
            finish(.failure(DirectInputError.message("实时听写内容过长")))
            return
        }
        pendingPreview = text
        schedulePreview()
    }
    private func schedulePreview() {
        guard previewWork == nil, awaitingPreview == nil, pendingPreview != nil,
              phase == .ready, queuedCommit == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewWork = nil
            guard self.phase == .ready, let text = self.pendingPreview,
                  let session = self.session, let channel = self.channel else { return }
            self.pendingPreview = nil
            self.previewSequence += 1
            let sequence = self.previewSequence
            self.awaitingPreview = sequence
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(DirectInputError.message("实时更新回执超时，请检查远端内容后重试")))
            }
            self.previewTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            channel.send(DirectInputMessage(operation: "preview", session: session, text: text, sequence: sequence))
        }
        previewWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }
    func commit(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard phase == .ready, session != nil, channel != nil, queuedCommit == nil else {
            completion(.failure(DirectInputError.message("直输会话已失效，请重新听写")))
            return
        }
        guard !text.isEmpty, text.utf8.count <= DirectInputCodec.maximumTextBytes else {
            completion(.failure(DirectInputError.message("文字为空或过长")))
            return
        }
        previewWork?.cancel()
        previewWork = nil
        pendingPreview = nil
        callback = completion
        queuedCommit = text
        sendQueuedCommitIfReady()
    }
    private func sendQueuedCommitIfReady() {
        guard awaitingPreview == nil, let text = queuedCommit,
              let session, let channel else { return }
        queuedCommit = nil
        phase = .waitingAcceptance
        armTimeout("未收到接收端回执，请先检查远端文字，避免重复输入", after: 60)
        channel.send(DirectInputMessage(operation: "commit", session: session, text: text))
    }
    func cancel() {
        previewWork?.cancel()
        previewWork = nil
        previewTimeout?.cancel()
        previewTimeout = nil
        pendingPreview = nil
        awaitingPreview = nil
        queuedCommit = nil
        previewSequence = 0
        supportsPreview = false
        timeout?.cancel()
        timeout = nil
        callback = nil
        channel?.close()
        channel = nil
        session = nil
        phase = .idle
    }
    private func receive(_ message: DirectInputMessage) {
        if message.operation == "hello", phase == .waitingHello {
            session = message.session
            phase = .waitingReady
            channel?.send(DirectInputMessage(operation: "begin", session: message.session))
            return
        }
        guard message.session == session else {
            finish(.failure(DirectInputError.message("直输会话校验失败")))
            return
        }
        if let error = message.error {
            finish(.failure(DirectInputError.message(error)))
        } else if message.operation == "ready", phase == .waitingReady {
            supportsPreview = message.previewSupported == true
            logger.notice("Receiver preview capability=\(self.supportsPreview, privacy: .public)")
            phase = .ready
            timeout?.cancel()
            let completion = callback
            callback = nil
            completion?(.success(()))
        } else if message.operation == "previewed", phase == .ready,
                  let sequence = message.sequence, sequence == awaitingPreview {
            previewTimeout?.cancel()
            previewTimeout = nil
            awaitingPreview = nil
            logger.notice("Preview acknowledged sequence=\(sequence, privacy: .public)")
            if queuedCommit != nil { sendQueuedCommitIfReady() }
            else { schedulePreview() }
        } else if message.operation == "accepted", phase == .waitingAcceptance {
            finish(.success(()))
        } else {
            finish(.failure(DirectInputError.message("直输协议状态异常")))
        }
    }
    private func armTimeout(_ message: String, after seconds: TimeInterval = 5) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(DirectInputError.message(message)))
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func finish(_ result: Result<Void, Error>) {
        let completion = callback
        let notifySession = phase == .ready && completion == nil
        cancel()
        completion?(result)
        if notifySession, case .failure(let error) = result { onSessionFailure?(error) }
    }
}
